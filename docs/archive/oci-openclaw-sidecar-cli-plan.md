# oci-openclaw Sidecar/Job + Workload Identity 验证与对象存储操作改造计划

> 目标：**不改 OpenClaw 镜像** 的前提下，在 OKE 集群中通过 **Workload Identity**（Resource Principal）让一个 Sidecar/Job 具备对当前 compartment 下 Object Storage 的完整验证能力：
> - 创建/删除 Bucket
> - Put/Get/Delete Object
> - 列举 Bucket/Object
>
> 说明：这里的“openclaw 可以…”按你的约束理解为：OpenClaw 同 namespace/同 ServiceAccount 的工作负载**具备同等身份与网络条件**，因此验证 Job/Sidecar 成功即可证明 OpenClaw 若后续增加相同客户端能力也能完成这些动作。

---

## 一、现状与约束

### 已知事实
- OpenClaw 镜像内安装了 `oci-cli==3.67.0`（通过 venv 安装并软链到 `/usr/local/bin/oci`）。
- OpenClaw 镜像内未安装 OCI Python SDK `oci`（因此无法使用 `get_oke_workload_identity_resource_principal_signer()`）。
- 在 Pod 内使用 `oci --auth resource_principal` 报错：`session_token was not provided`，说明 RP token 获取链路在该运行时不可用/未满足条件。
- 集群子网为 **private**。

### 关键约束
- **不改 OpenClaw 镜像内容**（不在 OpenClaw Dockerfile 中新增依赖）。

### 推导结论
- 需引入一个单独的 **Job** 或 **Sidecar**（推荐 Job）用于：
  1) 以 Workload Identity 方式拿到身份
  2) 直接调用 Object Storage API/SDK 完成端到端 bucket/object 操作

---

## 二、总体方案选择

### 方案 A（推荐）：K8s Job 验证（同 SA/同 NS）
- 在 `openclaw-prod`（或你指定 namespace）里创建一个临时 Job。
- Job 使用 **与 OpenClaw 相同的 ServiceAccount**（或一个专用 SA，但映射到相同 WI/动态组策略）。
- Job 容器镜像选择：
  - **OCI Python SDK** 方式：自带 Python + `pip install oci` 的轻量镜像；或
  - **官方 OCI CLI 镜像**（若存在且支持 WI 环境）；或
  - 自建小镜像（仅用于验证，不影响 OpenClaw 镜像）。

优点：与 OpenClaw 解耦；一次性运行、可重复执行、日志可追溯。

### 方案 B：Sidecar 附着到 OpenClaw Pod
- 在 OpenClaw Deployment 中额外注入 sidecar 容器（工具容器）。
- sidecar 共享 Pod 的 ServiceAccount 与网络策略。

优点：证明“同一个 Pod 内”也可访问。
缺点：需要改 OpenClaw 的 k8s manifest（但仍不改镜像），且会长期运行/增加复杂度。

> 本计划默认走 **方案 A：Job**。若你更希望 Sidecar，我可以在后续把 Job 方案等价迁移为 Sidecar 注入。

---

## 三、需要修改/新增的内容清单（oci-openclaw repo）

> 原则：尽量最小变更。新增文件集中放在 `k8s/verify/`（如目录不存在则新增）。

1) 新增：`k8s/verify/00-serviceaccount.yaml`（可选）
   - 若直接复用 OpenClaw 现有 SA，则不需要。
   - 若创建专用 SA：命名如 `openclaw-objstore-verify`。

2) 新增：`k8s/verify/01-configmap-verify-script.yaml`
   - 放验证脚本（建议 Python）与参数模板。

3) 新增：`k8s/verify/02-job-objstore-verify.yaml`
   - 定义 Job：
     - namespace：`openclaw-prod`
     - serviceAccountName：复用 OpenClaw 的 SA
     - env：region、compartment OCID、bucket 名、前缀、是否 cleanup
     - restartPolicy：Never
     - ttlSecondsAfterFinished：自动清理

4) 修改（可能需要）：`k8s/openclaw/*` 或 `k8s/` 下 NetworkPolicy
   - 若 openclaw namespace 有 egress 限制：需要允许到 Object Storage（443）与 DNS。

5) 修改（可能需要）：`scripts/oci/03_verify_gateway.sh` 或新增 `scripts/oci/verify_objstore_wi.sh`
   - 增加一个脚本，自动 apply Job + 等待完成 + 打印日志。

---

## 四、OCI 侧（IAM + 网络）前置检查与改动

### 4.1 Workload Identity / Dynamic Group / Policy
你需要确认 Job 使用的身份与 OpenClaw 一致。核心检查项：

- **Dynamic Group** 是否能匹配到该 workload（OKE WI 的匹配方式取决于你们采用的 WI 方案：按 cluster OCID、namespace、serviceAccount、pod labels 等）。
- **Policy** 是否授予该 dynamic group 对 Object Storage 的权限。

建议最小策略（按 compartment）：
- 允许管理 bucket：
  - `Allow dynamic-group <DG> to manage buckets in compartment <COMP>`
- 允许管理 objects：
  - `Allow dynamic-group <DG> to manage objects in compartment <COMP>`

如需更严格，可改为 `read`/`use`/`manage` 的最小集合，但验证“创建/删除 bucket + put/get object”通常需要 `manage`。

### 4.2 网络（private 子网）
Job/Sidecar 访问 Object Storage 需要出站路径：

- 推荐：**Service Gateway**
  - VCN：创建 Service Gateway，选择 “Object Storage” service
  - Route Table：为 Pod 所在子网路由表添加到 Service Gateway
  - Security Lists/NSG：允许出站 443（到 service CIDR/前缀）

- 或：NAT Gateway（走公网）

> 若网络不通，Job 会表现为 DNS 解析失败或 HTTPS 超时。

---

## 五、实现步骤（按顺序执行）

### Step 0：已确认的集群现状（来自现场 kubectl 输出）
- Namespace：`openclaw-prod`
- OpenClaw 工作负载：`statefulset.apps/openclaw`，Pod：`openclaw-0`
- ServiceAccount：`openclaw-sa`（StatefulSet `.spec.template.spec.serviceAccountName=openclaw-sa`）
- Pod 标签：`app=openclaw`
- 现有 NetworkPolicy：`openclaw-egress-restrict`
  - 仅允许 egress：
    - DNS → kube-system/kube-dns 53 TCP/UDP
    - 到 `gateway-prod` 中 `app=oci-anthropic-gateway` 的 8000/TCP
  - 因此：**当前任何 `app=openclaw` 的 Pod 都无法访问 Object Storage 443**。

### Step 1：确定验证目标与安全边界（执行前必须确认）
**重要：所有 OCID/region 等值都不得写死在 YAML/脚本中**。你今天会删除 OKE、明天重建，所有 OCID 都可能变化；执行时必须以 `scripts/oci/gateway.env` 为唯一事实来源。

需要你在 `scripts/oci/gateway.env` 中提供/确认以下变量：
- `OCI_REGION`
- `OCI_COMPARTMENT_OCID`
- （可选）`OCI_CLUSTER_OCID`（用于脚本做一致性检查）

以及确认是否允许真实执行 destructive 操作：
- 创建测试 bucket
- put/get/delete object
- 删除测试 bucket（默认会删除，bucket 名会强制带前缀以防误删）

Bucket 命名规则：
- `openclaw-wi-verify-<YYYYMMDD>-<rand>`
- 只对该前缀的 bucket 执行删除。

### Step 2：新增一个“最小放通”NetworkPolicy（仅用于验证 Object Storage）
目的：在不破坏现有 egress 限制前提下，为 `app=openclaw` 增加一条 443/TCP 的出口。

实施策略（两档，先宽后严）：
- **验证档（最省事）**：允许 `0.0.0.0/0:443`（仅验证阶段使用，跑通后再收敛）
- **收敛档（推荐）**：仅允许到 OCI Object Storage 的 service CIDR/前缀（需要你提供 region 对应的前缀，或通过你们网络团队/VCN 路由配置确认）

将要新增的 manifest（计划文件中仅记录，未 apply）：

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: openclaw-egress-allow-https
  namespace: openclaw-prod
spec:
  podSelector:
    matchLabels:
      app: openclaw
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - protocol: TCP
          port: 443
```

> 备注：这条 NP 与现有 `openclaw-egress-restrict` 是“并集”生效：仍然只允许明确列出的 egress（DNS、到 gateway:8000、以及新增的 443）。

### Step 3：创建一次性 Job（同 SA、同标签，等价验证）
关键点：为了证明“OpenClaw 同等条件也能访问”，验证 Job 必须：
- `namespace=openclaw-prod`
- `serviceAccountName=openclaw-sa`
- `labels: {app: openclaw}`（让它被同一条 egress NP 限制）

Job 镜像选择：
- 推荐：`python:3.12-slim`（或 3.11-slim）
- 容器启动时 `pip install oci` 后运行脚本
  - 这是验证用 Job 镜像/运行时，不改 OpenClaw 镜像，满足约束。

将要新增的 ConfigMap（脚本）与 Job（计划文件中仅记录，未 apply）：

**ConfigMap：objstore-wi-verify-script**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: objstore-wi-verify-script
  namespace: openclaw-prod
data:
  verify.py: |
    import os
    import time
    import random
    import string

    import oci
    from oci.object_storage import ObjectStorageClient
    from oci.object_storage.models import CreateBucketDetails

    region = os.environ["OCI_REGION"]
    compartment_id = os.environ["OCI_COMPARTMENT_OCID"]
    cleanup = os.environ.get("CLEANUP", "1") == "1"
    prefix = os.environ.get("BUCKET_PREFIX", "openclaw-wi-verify")

    def rand(n=6):
        return "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(n))

    bucket_name = os.environ.get("BUCKET_NAME")
    if not bucket_name:
        bucket_name = f"{prefix}-{time.strftime('%Y%m%d')}-{rand()}"

    object_name = os.environ.get("OBJECT_NAME", "hello.txt")
    object_body = os.environ.get("OBJECT_BODY", "hello from openclaw wi verify\n").encode("utf-8")

    signer = oci.auth.signers.get_oke_workload_identity_resource_principal_signer()
    client = ObjectStorageClient(config={"region": region}, signer=signer)

    ns = client.get_namespace().data
    print(f"objectstorage namespace: {ns}")
    print(f"bucket: {bucket_name}")

    # Create bucket
    try:
        client.create_bucket(
            namespace_name=ns,
            create_bucket_details=CreateBucketDetails(
                name=bucket_name,
                compartment_id=compartment_id,
            ),
        )
        print("created bucket")
    except oci.exceptions.ServiceError as e:
        if e.status == 409:
            print("bucket already exists (409), continuing")
        else:
            raise

    # Put object
    client.put_object(ns, bucket_name, object_name, object_body)
    print("put object")

    # Get object
    obj = client.get_object(ns, bucket_name, object_name)
    got = obj.data.content
    if got != object_body:
        raise RuntimeError(f"object body mismatch: got={got!r}")
    print("get object (verified)")

    # Delete object
    client.delete_object(ns, bucket_name, object_name)
    print("deleted object")

    if cleanup:
        client.delete_bucket(ns, bucket_name)
        print("deleted bucket")
    else:
        print("cleanup disabled; leaving bucket")
```

**Job：objstore-wi-verify**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: objstore-wi-verify
  namespace: openclaw-prod
spec:
  ttlSecondsAfterFinished: 3600
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: openclaw
    spec:
      restartPolicy: Never
      serviceAccountName: openclaw-sa
      containers:
        - name: verify
          image: python:3.12-slim
          command: ["sh", "-lc"]
          args:
            - |
              set -eux
              pip install --no-cache-dir oci
              python /scripts/verify.py
          env:
            - name: OCI_REGION
              value: "${OCI_REGION}"
            - name: OCI_COMPARTMENT_OCID
              value: "${OCI_COMPARTMENT_OCID}"
            - name: CLEANUP
              value: "1"
          volumeMounts:
            - name: scripts
              mountPath: /scripts
      volumes:
        - name: scripts
          configMap:
            name: objstore-wi-verify-script
```

> 说明：`OCI_REGION`/`OCI_COMPARTMENT_OCID` 在真正 apply 前需要替换为实际值，或改为从 Secret/ConfigMap 注入。

### Step 4：执行顺序（真正执行时）
1) `kubectl apply -f k8s/verify/openclaw-egress-allow-https.yaml`
2) `kubectl apply -f k8s/verify/objstore-wi-verify-script.yaml`
3) `kubectl apply -f k8s/verify/objstore-wi-verify-job.yaml`
4) `kubectl -n openclaw-prod wait --for=condition=complete job/objstore-wi-verify --timeout=10m`
5) `kubectl -n openclaw-prod logs job/objstore-wi-verify`

回滚顺序：
- `kubectl -n openclaw-prod delete job objstore-wi-verify --ignore-not-found`
- `kubectl -n openclaw-prod delete configmap objstore-wi-verify-script --ignore-not-found`
- `kubectl -n openclaw-prod delete networkpolicy openclaw-egress-allow-https --ignore-not-found`

### Step 5：常见失败与定位
- `403`：Dynamic Group/Policy 不足（缺 manage buckets/objects 等）
- DNS 失败：kube-dns selector/labels 不匹配（但你们当前 DNS 已放通）
- HTTPS 超时：VCN 无 Service Gateway/NAT，或 NP 仍未放通 443
- signer 初始化失败：Workload Identity 绑定/集群 WI 配置问题

---

## 六、风险控制与清理策略

1) Bucket 命名必须带前缀：`openclaw-wi-verify-`，避免误删。
2) Job 默认启用 cleanup（删除 object 与 bucket）。
3) 使用 `ttlSecondsAfterFinished` 自动删除 Job 对象。
4) 若你希望保留 bucket 便于人工检查：提供 `CLEANUP=0` 参数。

---

## 七、验收标准

当 Job 日志出现以下结果即视为通过：
- 成功获取 object storage namespace
- 成功创建 bucket
- 成功 put/get/delete object
- 成功删除 bucket

失败分类：
- 401/403：IAM Dynamic Group / Policy 问题
- 超时/解析失败：网络路径（Service Gateway/NAT）或 NetworkPolicy egress 问题
- signer 初始化失败：Workload Identity 绑定/环境变量/SA 映射问题

---

## 八、后续：让 OpenClaw “真正直接”访问 Object Storage 的路线（不在本次约束内）

如果未来你要让 OpenClaw 业务逻辑直接操作 Object Storage，而不是靠外部 Job 验证：
- 需要在 OpenClaw 镜像内引入可用 SDK（Node 的 OCI SDK 或 Python `oci`），或
- 将对象存储操作封装为集群内单独服务（OpenClaw 调用该服务）。

本计划仅证明：在当前 OKE/WI/IAM/网络条件下，同一身份的工作负载可以完成对象存储 CRUD。
