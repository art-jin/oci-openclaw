# oci-openclaw：OpenClaw 镜像内置 oci-cli + Workload Identity + Object Storage 权限（计划）

> 说明：本文档为**修改计划**（Plan Only），用于后续实施。
> - **不包含任何实际代码/脚本/manifest 的修改**。
> - 目标是让 **Pod B（OpenClaw）** 在运行时通过 bash/tool 执行 `oci ...` 命令，并且在 OKE 内通过 **Workload Identity（Resource Principal）** 成功访问 OCI API。

## 0. 目标与边界（明确约束）

### 0.1 目标
1) **OpenClaw 运行容器内默认存在 `oci` 可执行文件**，满足 agent runtime 的 bash/tool 调用需求（对应 README 9.x）。
2) OpenClaw 在 OKE 内通过 **Workload Identity / Resource Principal** 认证成功，可调用 OCI API。
3) 仅授予 **当前 Compartment 下 Object Storage 的完整操作能力**：
   - 允许创建/删除 bucket
   - 允许对象完整操作（put/get/list/delete 等）
4) OpenClaw 允许 egress 到 OCI endpoints 的 HTTPS 443（否则 `oci` 无法真正调用成功）。

### 0.2 明确禁止
- 禁止授予 Compute / Network / Block Volume / IAM 等其它权限（policy 中不出现相关 statements）。
- 不把任何凭证（OCI config/key/token）固化到 OpenClaw 镜像或写入仓库。

### 0.3 已确认的固定值
- Namespace：`openclaw-prod`
- ServiceAccount：`openclaw-sa`

---

## 1) 外部仓库（`../openclaw`）：重做 OpenClaw 镜像，默认安装 `oci-cli`

> 该步骤发生在 OpenClaw 源码/镜像仓库（相邻目录 `../openclaw`），本部署仓库仅消费镜像 tag。

### 1.1 Dockerfile：在 runtime stage 安装 `oci-cli`
- 按 README 的 9.x 推荐片段：使用 `install.sh` 安装。
- 放置位置：
  - `FROM base-${OPENCLAW_VARIANT}` 之后
  - `USER node` 之前
- 期望结果：`/usr/local/bin/oci` 存在（通过 symlink 指向 `/opt/oci-cli/bin/oci`）。

### 1.2 构建可复现/供应链可控
- 将 `OPENCLAW_OCI_CLI_INSTALL_REF` 从 `master` 固定为：
  - release tag（推荐）或 commit SHA。
- 在 OpenClaw 镜像发布记录中记录：
  - install ref（tag/SHA）
  - 新镜像 tag（用于本仓库更新 `OPENCLAW_IMAGE`）。

### 1.3 构建并推送到 OCIR
- 构建新镜像并推送到 OCIR，生成新 tag。
- 建议 tag 体现 ocicli 信息，便于回滚/审计（例如 `...:2026.3.8-ocicli-<ref>`）。

---

## 2) 本部署仓库（`oci-openclaw`）：OpenClaw WI env + NetworkPolicy 放开 443 + 使用新镜像

### 2.1 `k8s/openclaw/05-statefulset.yaml`：注入 Resource Principal env
目的：让 OpenClaw Pod 内 `oci-cli`/OCI SDK 能以 Resource Principal 身份认证。

计划改动：在 OpenClaw Pod 的两个容器都加入 env：
- `OCI_RESOURCE_PRINCIPAL_VERSION="2.2"`
- `OCI_RESOURCE_PRINCIPAL_REGION="__OCI_RESOURCE_PRINCIPAL_REGION__"`

容器范围：
- `containers: name: gateway`（agent runtime bash/tool 的执行容器）
- `containers: name: cli`（人工 `kubectl exec` 验证与排障）

占位符渲染：
- 复用现有脚本渲染逻辑（`__OCI_RESOURCE_PRINCIPAL_REGION__`）。

### 2.2 `k8s/openclaw/07-networkpolicy-egress.yaml`：放开 OCI API HTTPS 443 egress
目的：满足“OpenClaw 真的能访问 OCI API”。

计划改动：在现有 egress（DNS + 到 gateway:8000）基础上新增：
- 允许 `TCP 443` 到 `0.0.0.0/0`

备注：
- 该规则会扩大 OpenClaw 出站面；如需更严格的目的地收敛，需在 OCI 网络侧（NSG/防火墙/路由）进一步控制（不在本计划内）。

### 2.3 `scripts/oci/gateway.env`：更新 OpenClaw 镜像 tag
计划改动：
- `OPENCLAW_IMAGE=<new OCIR image tag>`（指向已内置 `oci-cli` 的镜像）。

---

## 3) 本部署仓库：扩展 `scripts/oci/11_workload_identity_policy.sh`（脚本化策略管理）

目标：在不影响现有 gateway WI policy 的前提下，新增一个专用模式为 OpenClaw 生成/更新 policy，且仅包含 Object Storage 权限。

### 3.1 新增模式与参数（计划）
- 新增参数：`--mode gateway-genai|openclaw-objectstorage`
  - 默认：`gateway-genai`（保持现状不变）
- 支持指定（用于 OpenClaw）：
  - `--namespace openclaw-prod`
  - `--service-account openclaw-sa`
  - `--policy-name oke-openclaw-objectstorage-wi`

### 3.2 `openclaw-objectstorage` 模式 statements（严格仅两条）
在 compartment id `<OCI_COMPARTMENT_OCID>` 下：

1) bucket 完整管理（允许 create/delete）：
```
Allow any-user to manage buckets in compartment id <OCI_COMPARTMENT_OCID> where all {request.principal.type='workload',request.principal.namespace='openclaw-prod',request.principal.service_account='openclaw-sa',request.principal.cluster_id='<OCI_CLUSTER_OCID>'}
```

2) object 完整管理：
```
Allow any-user to manage objects in compartment id <OCI_COMPARTMENT_OCID> where all {request.principal.type='workload',request.principal.namespace='openclaw-prod',request.principal.service_account='openclaw-sa',request.principal.cluster_id='<OCI_CLUSTER_OCID>'}
```

显式不包含：
- compute/network/volume/IAM 等任何 statements。

### 3.3 计划使用命令（创建/更新）
```
bash scripts/oci/11_workload_identity_policy.sh create-or-update \
  --env scripts/oci/gateway.env \
  --mode openclaw-objectstorage \
  --namespace openclaw-prod \
  --service-account openclaw-sa \
  --policy-name oke-openclaw-objectstorage-wi
```

### 3.4 删除/回滚命令（避免误伤 gateway）
```
bash scripts/oci/11_workload_identity_policy.sh delete \
  --env scripts/oci/gateway.env \
  --policy-name oke-openclaw-objectstorage-wi
```

计划要求：
- `delete` 必须支持 `--policy-name`，防止默认删错 policy。

---

## 4) 验收 Runbook（实施后执行）

### 4.1 验证 `oci` 在容器内可执行
```
kubectl -n openclaw-prod exec -it statefulset/openclaw -c gateway -- oci --version
kubectl -n openclaw-prod exec -it statefulset/openclaw -c cli -- oci --version
```

### 4.2 验证 Resource Principal + OCI API 可达
```
kubectl -n openclaw-prod exec -it statefulset/openclaw -c cli -- oci os ns get
```

### 4.3 验证 Object Storage 权限（包含 bucket 创建/删除）
建议使用临时 bucket（执行完清理）：
- create bucket
- put/get/list/delete object
- delete bucket

（待实施时可补充一份可复制粘贴的命令清单：包含随机后缀命名规范与清理顺序。）

---

## 5) 回滚策略（计划层面）

- 镜像回滚：`OPENCLAW_IMAGE` 指回旧 tag。
- NetworkPolicy 回滚：撤销新增的 443 egress rule（恢复仅 DNS + 到 gateway）。
- IAM 回滚：删除 `oke-openclaw-objectstorage-wi` policy（不影响 gateway policy）。
