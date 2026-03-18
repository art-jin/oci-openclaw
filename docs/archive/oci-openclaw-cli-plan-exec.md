# oci-openclaw-cli-plan 执行记录（Exec Log）

> 目的：记录 `docs/archive/oci-openclaw-cli-plan.md` 的实际执行进度与关键产物，便于中断后从正确位置继续。
>
> 路径选择：**路径 A（OKE Workload Identity for Pods / Resource Principal）**
>
> 最后更新：2026-03-17

---

## 7. 今日排障与最终恢复（2026-03-17）——Gateway WI 权限修复 + OpenClaw E2E 验证

### 7.0 从 0 到可复用：最小部署与验证（以手动创建 OKE 集群为前提）

#### 7.0.1 前置：已手动创建 OKE 集群后，修改/准备 `scripts/oci/gateway.env`
关键点：本 repo 的脚本可跳过建集群，直接部署到你手动创建的集群。

最小需要确认/填写的变量（示例见本次实际值）：
- 基础：
  - `OCI_REGION=us-chicago-1`
  - `OCI_HOME_REGION=us-ashburn-1`（IAM 写操作必须在 home region）
  - `OCI_COMPARTMENT_OCID=...`
  - `OCI_CLUSTER_OCID=...`（你手动创建的集群 OCID）
  - `KUBECONFIG_PATH=...`
- 镜像（网关/可选 OpenClaw）：
  - `GATEWAY_IMAGE_MODE=build|prebuilt`
  - `GATEWAY_IMAGE=<region>.ocir.io/<ns>/<repo>:<tag>`
  - 若 build：`GATEWAY_REPO_DIR=/home/ubuntu/oci-anthropic-gateway`
  - `OPENCLAW_IMAGE=<region>.ocir.io/<ns>/openclaw:<tag>`（本次为 `ord.ocir.io/sehubjapacprod/openclaw:2026.3.8`）
- 认证：
  - `AUTH_MODE=workload_identity`
  - `DEBUG_UI_AUTH_TOKEN=...`
- OpenClaw 上游：
  - `OPENCLAW_GATEWAY_BASE_URL=http://oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000`
  - `OPENCLAW_GATEWAY_API_KEY=any-value-works`

> 注：OCIR/Artifacts 与 compartment 的区别已在 repo 文档中说明；本次使用 `OCI_ARTIFACTS_COMPARTMENT_OCID` 与 `OCI_COMPARTMENT_OCID` 相同。

#### 7.0.2 构建并推送镜像（可复用）
- 构建并推送 OpenClaw（镜像内置 `oci` CLI 的版本）：
  - `bash scripts/oci/02_build_push_openclaw_ocir.sh scripts/oci/gateway.env --apply`
- 构建并推送 gateway（若 `GATEWAY_IMAGE_MODE=build`）：
  - 由 `scripts/oci/10_deploy_all_in_one.sh`/相关脚本触发，或按你本地构建流程先 push，再在 env 中设置 `GATEWAY_IMAGE`。

#### 7.0.3 部署（跳过集群创建）
- 一键部署到已存在集群：
```bash
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --skip-create-cluster
```

#### 7.0.4 IAM（Workload Identity）授权：可复制命令（Runbook）
> 说明：IAM 的 create/update/delete 必须在 tenancy **home region** 执行（本次为 `us-ashburn-1`，见 `gateway.env: OCI_HOME_REGION`）。

1) 创建/重建 gateway 的 workload identity policy（推荐删除后重建，避免 version-date/update 限制）：
```bash
set -a; source scripts/oci/gateway.env; set +a
HOME_REGION="${OCI_HOME_REGION:-us-ashburn-1}"
POLICY_NAME="oke-gateway-workload-identity"

NS="gateway-prod"
SA="oci-gateway-sa"
COMP="$OCI_COMPARTMENT_OCID"
CLUSTER="$OCI_CLUSTER_OCID"

S1="Allow any-user to inspect generative-ai-model in compartment id ${COMP} where all {request.principal.type='workload',request.principal.namespace='${NS}',request.principal.service_account='${SA}',request.principal.cluster_id='${CLUSTER}'}"
S2="Allow any-user to use generative-ai-chat in compartment id ${COMP} where all {request.principal.type='workload',request.principal.namespace='${NS}',request.principal.service_account='${SA}',request.principal.cluster_id='${CLUSTER}'}"

OLD_ID=$(oci iam policy list --compartment-id "$COMP" --region "$HOME_REGION" --all \
  --query "data[?name=='$POLICY_NAME'].id | [0]" --raw-output)
if [ "$OLD_ID" != "null" ] && [ -n "$OLD_ID" ]; then
  oci iam policy delete --policy-id "$OLD_ID" --region "$HOME_REGION" --force
  sleep 2
fi

oci iam policy create --compartment-id "$COMP" --region "$HOME_REGION" \
  --name "$POLICY_NAME" \
  --description "Gateway WI policy: allow ${NS}/${SA} to call OCI GenAI inference" \
  --statements "[\"$S1\",\"$S2\"]"
```

2) 快速核对 policy statements（重点检查 `request.principal.cluster_id` 是否与当前集群一致）：
```bash
set -a; source scripts/oci/gateway.env; set +a
HOME_REGION="${OCI_HOME_REGION:-us-ashburn-1}"
COMP="$OCI_COMPARTMENT_OCID"

oci iam policy list --compartment-id "$COMP" --region "$HOME_REGION" --all \
  --query 'data[].{name:name,id:id,state:"lifecycle-state"}' --output table
```

#### 7.0.5 可复用的最小验证命令（Runbook）
1) 工作负载就绪：
```bash
kubectl -n gateway-prod get pods,svc -o wide
kubectl -n openclaw-prod get pods,svc,pvc -o wide
```

2) Gateway 本身可用（port-forward + messages 请求）：
```bash
kubectl -n gateway-prod port-forward svc/oci-anthropic-gateway 8000:8000
curl -sS http://127.0.0.1:8000/v1/messages \
  -H 'content-type: application/json' \
  -d '{"model":"openai.gpt-oss-20b","max_tokens":32,"messages":[{"role":"user","content":"Reply with OK"}]}'
```

3) OpenClaw -> gateway -> GenAI（集群内验证，避免本地网络差异）：
```bash
kubectl -n openclaw-prod exec openclaw-0 -c cli -- sh -lc '
URL="http://oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000/v1/messages"
BODY='\''{"model":"openai.gpt-oss-20b","max_tokens":32,"messages":[{"role":"user","content":"Reply with OK"}]} '\''
curl -sS -m 60 -w "\nHTTP_STATUS=%{http_code}\n" "$URL" -H "content-type: application/json" -d "$BODY"'
```

4) 发生 404/500 时快速看日志：
```bash
kubectl -n gateway-prod logs deploy/oci-anthropic-gateway --tail=200
kubectl -n openclaw-prod logs statefulset/openclaw -c gateway --tail=200
```

---

## 7. 今日排障与最终恢复（2026-03-17）——Gateway WI 权限修复 + OpenClaw E2E 验证

### 7.1 症状
- gateway 调用 OCI Generative AI Inference `chat` 持续失败：
  - `oci.exceptions.ServiceError`
  - HTTP `404`
  - message: `Authorization failed or requested resource not found.`
- OpenClaw 通过 gateway 调用 GenAI 失败（经由 gateway 返回 500 internal_error，根因仍是 gateway->OCI 404）。

### 7.2 关键验证结论（K8s + Pod 内实测）
- gateway Pod 内 python 实测 signer：
  - ✅ `get_oke_workload_identity_resource_principal_signer()` 成功（OKE Workload Identity signer 可用）
  - ❌ `get_resource_principals_signer()` 失败：`session_token was not provided`
  - ✅ `InstancePrincipalsSecurityTokenSigner()` 可用（但 gateway 代码不使用 instance principal）
- 因此问题不在 "env 没给齐" 或 "WI 不可用"，而是 **WI 对应的 IAM policy 条件不匹配/未命中**。

### 7.3 根因定位（IAM policy statements 比对）
在 compartment `OCI_COMPARTMENT_OCID` 下发现 policy：`oke-gateway-workload-identity`（ACTIVE）。
- policy 的条件中 `request.principal.cluster_id` 指向了 **错误的 cluster OCID**：
  - policy 内：`ocid1.cluster...gqzyplt...`（非当前集群）
  - 实际当前集群（来自 `scripts/oci/gateway.env` / `oci ce cluster get`）：`ocid1.cluster...basuwcy4...pza`
- 由于 cluster_id 条件不匹配，导致 `use generative-ai-chat` / `inspect generative-ai-model` 权限不生效，OCI 侧返回 404（未授权/不可见）。

### 7.4 修复动作（home region 执行 IAM 写操作）
- 依据 `scripts/oci/gateway.env`：`OCI_HOME_REGION=us-ashburn-1`，IAM 的 create/update/delete 必须在 home region 执行。
- 删除旧 policy（cluster_id 错误）：`oke-gateway-workload-identity`。
- 重新创建同名 policy（ACTIVE），使用正确 cluster_id：`ocid1.cluster...basuwcy4...pza`。
  - statements（两条）：
    - `Allow any-user to inspect generative-ai-model ... where all {request.principal.type='workload', request.principal.namespace='gateway-prod', request.principal.service_account='oci-gateway-sa', request.principal.cluster_id='<current cluster ocid>'}`
    - `Allow any-user to use generative-ai-chat ... where all {...}`

### 7.5 临时路线 B 资源（已清理）
为临时恢复曾创建 instance principal 动态组与 policy（后确认 gateway 代码不走 instance principal，故无效），现已删除：
- ✅ 已删除 policy：`oke-gateway-genai-instanceprincipal`
- ✅ 已删除 dynamic group：`oke-gateway-nodes-dg`
- ✅ 当前保留的有效 policy：`oke-gateway-workload-identity`（ACTIVE）

### 7.6 最终验收结果
- ✅ Gateway -> OCI GenAI：`/v1/messages` 返回 HTTP 200。
- ✅ OpenClaw -> gateway -> OCI GenAI（集群内调用）：
  - 从 `openclaw-0` 的 `cli` 容器调用 `http://oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000/v1/messages` 返回 HTTP 200，且响应内容文本为 `"OK"`。

> 结论：当前部署已恢复端到端推理能力；Workload Identity signer 可用且 IAM policy 条件已修正命中。

---

## 0. 当前状态总结

- OpenClaw 镜像已重新构建并推送到 OCIR，镜像内已包含 `oci` CLI。
- K8s 侧已注入 Resource Principal 相关 env（`OCI_RESOURCE_PRINCIPAL_*`、`OCI_CLI_AUTH=resource_principal`）。
- OpenClaw NetworkPolicy 已放开 egress 443（允许访问 OCI API endpoints）。
- OpenClaw 的 Workload Identity IAM policy（Object Storage buckets + objects）已创建并 ACTIVE。
- **阻塞点**：OKE 集群侧目前看起来未启用/未配置 Workload Identity for Pods，导致 Pod 内执行 `oci os ns get` 报 `session_token was not provided`。

下一步需要：在 OKE 集群启用 Workload Identity（路径 A），并按 OCI 要求将 K8s ServiceAccount 绑定到该身份机制（通常通过 SA annotation 或专用资源）。

---

## 1. Plan 1：OpenClaw 镜像内置 oci-cli（已完成）

### 1.1 Dockerfile
- 位置：`../openclaw/Dockerfile`
- 检查结果：Dockerfile 已包含 OCI CLI 安装（版本 `3.67.0`），并在运行时可通过 `/usr/local/bin/oci` 调用。

### 1.2 Build & Push 到 OCIR（已完成）
- 执行脚本：`bash scripts/oci/02_build_push_openclaw_ocir.sh scripts/oci/gateway.env --apply`
- 推送目标：
  - `ord.ocir.io/sehubjapacprod/openclaw:2026.3.8`
  - digest：`sha256:b651825fc50e7a9f05bc1f5b500c4009b000959e5cd776662337977907d90ace`

### 1.3 更新部署使用的镜像（已完成）
- 文件：`scripts/oci/gateway.env`
- 变更：
  - `OPENCLAW_IMAGE=ord.ocir.io/sehubjapacprod/openclaw:2026.3.8`

---

## 2. Plan 2：部署仓库注入 WI env + NetworkPolicy 443（已完成）

### 2.1 StatefulSet 注入 RP env（已完成）
- 文件：`k8s/openclaw/05-statefulset.yaml`
- 已包含：
  - `OCI_RESOURCE_PRINCIPAL_VERSION=2.2`
  - `OCI_RESOURCE_PRINCIPAL_REGION=__OCI_RESOURCE_PRINCIPAL_REGION__`
  - `OCI_CLI_AUTH=resource_principal`
- 容器范围：`gateway` + `cli`

### 2.2 NetworkPolicy 放开 443（已完成）
- 文件：`k8s/openclaw/07-networkpolicy-egress.yaml`
- 已新增：允许到 `0.0.0.0/0:443`（TCP）

### 2.3 渲染链路确认（已完成）
- 脚本：`scripts/oci/02_deploy_gateway_oke.sh`
- `render_manifest()` 已替换：
  - `__OCI_RESOURCE_PRINCIPAL_REGION__`
  - `__OPENCLAW_IMAGE__`
  - `__OPENCLAW_GATEWAY_BASE_URL__`
  - `__OPENCLAW_GATEWAY_API_KEY__`

---

## 3. Plan 3：Workload Identity policy 脚本（已完成，但遇到 version-date=null 行为）

### 3.1 openclaw-objectstorage 模式（已完成）
- 文件：`scripts/oci/11_workload_identity_policy.sh`
- `--mode openclaw-objectstorage` statements：
  - manage buckets
  - manage objects

### 3.2 OCI policy update 的阻塞与处理
- 现象：`oci iam policy get` 返回 `version-date: null`，而 update API 要求同时提供 statements + version-date。
- 处理：采用 **delete + create** 方式重建 policy。

### 3.3 最终创建的 policy（已完成，ACTIVE）
- policy name：`oke-openclaw-objectstorage-wi`
- policy id：`ocid1.policy.oc1..aaaaaaaasnssd3x4djxk7fu2p3w5co3urkik6fjmcnoxr6dehb47pl3rp27a`
- statements（2 条）：
  - Allow any-user to manage buckets ... where principal = workload/openclaw-prod/openclaw-sa + cluster_id
  - Allow any-user to manage objects ... where principal = workload/openclaw-prod/openclaw-sa + cluster_id

---

## 3.5 OCIR repo compartment 归属（已完成改造）

### 变更目的
- 让 OCIR/Artifacts 仓库创建/查询落在指定 compartment（`sehubjapacprod/ChinaInteractive/arthur.jin`）下。

### 代码变更
- `scripts/oci/02_deploy_gateway_oke.sh`：Artifacts repo list/create 使用 `OCI_ARTIFACTS_COMPARTMENT_OCID`（默认回退到 `OCI_COMPARTMENT_OCID`）
- `scripts/oci/02_build_push_openclaw_ocir.sh`：同上
- `scripts/oci/gateway.env.example`：新增变量说明
- `scripts/oci/gateway.env`：已设置
  - `OCI_ARTIFACTS_COMPARTMENT_OCID=ocid1.compartment.oc1..aaaaaaaakre3wvnmmhv474r2wrwlgunoeertbdi2v2tp3igwbu5sqyss3euq`
- `README.md`：新增“OCIR namespace ≠ compartment”说明与验证命令

> 注：OCIR 镜像 URL 的 `<tenancyNamespace>`（例如 `sehubjapacprod`）不是 compartment。

---

## 4. Plan 4：部署与验收（部署完成；验收被 WI 阻塞）

### 4.0 部署（已完成）
- 执行命令：
  - `bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --skip-create-cluster`
- 结果：
  - gateway 部署成功，pods Running
  - openclaw StatefulSet rollout 成功：`openclaw-0` 2/2 Running

### 4.1 验证 oci-cli 可执行（已完成）
- 命令：
  - `kubectl -n openclaw-prod exec statefulset/openclaw -c gateway -- oci --version`
  - `kubectl -n openclaw-prod exec statefulset/openclaw -c cli -- oci --version`
- 结果：均返回 `3.67.0`

### 4.2 验证 Resource Principal + OCI API 可达（阻塞）
- 命令：
  - `kubectl -n openclaw-prod exec statefulset/openclaw -c cli -- oci os ns get`
- 错误：
  - `ValueError: session_token was not provided ... Resource principals authentication ...`

### 4.3 初步排查（已完成）
- `openclaw-sa` ServiceAccount 无 WI 相关 annotations
- `oci-gateway-sa` ServiceAccount 同样无 WI 相关 annotations
- `oci ce cluster get` 输出中未发现 workload identity/pod identity 相关字段（推断集群侧尚未启用/配置 WI）

---

## 5. 路径 A（OKE Workload Identity）探测结论（阻塞原因已确认）

- Console 未发现 Workload Identity / Pod Identity 相关开关。
- `oci ce cluster get` 未显示任何 pod identity/workload identity 相关配置项（仅 OIDC discovery）。
- Kubernetes 集群内未发现相关 webhook/controller（仅 OCI CNI/CSI 相关组件）。
- 发现 `oci ce workload-mapping` 子命令，但对该集群调用 `list_workload_mappings` 返回 `404 NotAuthorizedOrNotFound`：
  - 对照调用 `oci ce node-pool list` 成功，说明并非 CE 全局权限缺失。
  - 结论：在当前 region/cluster 上 **workloadMappings 端点不可用**（功能未开放/不支持），因此无法为 Pod 注入 Resource Principal session token。

因此：按原计划在当前 OKE 集群上完成“Pod 内 Resource Principal 调 OCI”的验收不可行。

---

## 6. 决策：去掉 OpenClaw 的 Workload Identity / 直接 OCI 访问要求（选择 A）

- 新目标：OpenClaw 不再直接调用 OCI（不再要求 Pod 内 `oci os ...` 成功）。
- OpenClaw 仅通过集群内 DNS 调用 `oci-anthropic-gateway`（HTTP 8000）。

### 6.1 待执行的最小化收敛改动（已完成）
- ✅ 已从 OpenClaw Pod 移除 Resource Principal env（`k8s/openclaw/05-statefulset.yaml`），并完成 rollout。
- ✅ 已将 OpenClaw NetworkPolicy egress 收敛为仅 DNS(53) + gateway:8000（`k8s/openclaw/07-networkpolicy-egress.yaml`），并完成 apply。
- ✅ 已删除 OpenClaw Object Storage 的 IAM policy：`oke-openclaw-objectstorage-wi`（不再需要 OpenClaw 直连 OCI）。

验证结果：
- `kubectl -n openclaw-prod exec ... env | grep ^OCI_` 输出为空
- NetworkPolicy 不包含 443

### 6.2 继续验收（新的）
- 验证 OpenClaw -> gateway 连通与功能调用即可。

---

## 6. 关键命令摘录

### Build & push OpenClaw
```bash
bash scripts/oci/02_build_push_openclaw_ocir.sh scripts/oci/gateway.env --apply
```

### 重建 OpenClaw object storage policy（当 update 因 version-date=null 失败时）
```bash
bash scripts/oci/11_workload_identity_policy.sh delete \
  --env scripts/oci/gateway.env \
  --policy-name oke-openclaw-objectstorage-wi

bash scripts/oci/11_workload_identity_policy.sh create \
  --env scripts/oci/gateway.env \
  --mode openclaw-objectstorage \
  --namespace openclaw-prod \
  --service-account openclaw-sa \
  --policy-name oke-openclaw-objectstorage-wi
```

### Deploy all-in-one
```bash
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --skip-create-cluster
```

### Validate oci-cli in Pod
```bash
kubectl -n openclaw-prod exec statefulset/openclaw -c cli -- oci --version
kubectl -n openclaw-prod exec statefulset/openclaw -c cli -- oci os ns get
```
