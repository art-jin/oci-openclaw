# OCI OKE 部署（openclaw + oci-anthropic-gateway）

本仓库用于将以下组件部署到 OCI OKE：
- `oci-anthropic-gateway`：集群内网关（对接 OCI GenAI）
- `openclaw`：上游 Anthropic 兼容应用（通过集群内 DNS 调用 gateway）

## 1. 架构（OKE）

### 1.1 目标调用链路与认证边界

```text
User -> openclaw (openclaw-prod) -> gateway (gateway-prod/ClusterIP) -> OCI GenAI (HTTPS)
Admin -> VPN/Bastion -> gateway /debug (Bearer Token)

OCI 认证边界：
- openclaw pod：
  - 首选：OKE Workload Identity，用于 pod 内 OCI CLI
  - 备选：Instance Principal，用于 pod 内 OCI CLI
  - explicit 模式：每次 OCI CLI 调用由调用方显式传入 --auth
- gateway pod：
  - 首选：OKE Workload Identity，用于 OCI SDK 调用 OCI GenAI
  - 当前文档化的备选：oci_config_secret
```

### 1.2 实现架构（ASCII 图，含端口转发、认证与 IAM 路径）

```text
Mac Browser/Terminal
  |  http://127.0.0.1:18789
  |
  +-- ssh -L 18789:127.0.0.1:18789 <user>@<oci-vm>                       (2.4-2)
  |
OCI VM (bastion/admin)
  |  kubectl -n openclaw-prod port-forward svc/openclaw 18789:18789      (2.4-1)
  |
  +-- forwards to ClusterIP svc/openclaw:18789 -> openclaw Pod

                               (Cluster: OCI OKE)
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                              │
│  Namespace: openclaw-prod                               Namespace: gateway-prod              │
│                                                                                              │
│  ┌────────────────────────────────────┐               ┌───────────────────────────────────┐ │
│  │ Pod: openclaw-0                    │               │ Pod: oci-anthropic-gateway        │ │
│  │  containers: openclaw gateway + cli│               │                                   │ │
│  │  serviceAccount: openclaw-sa       │               │  serviceAccount: oci-gateway-sa   │ │
│  │                                    │               │                                   │ │
│  │  用户/UI 流量                      │               │  集群内 API                        │ │
│  │  - UI/Gateway :18789               │               │  - Anthropic-compatible API :8000 │ │
│  │                                    │               │                                   │ │
│  │  Pod 内 OCI CLI 认证               │               │  Pod 内 OCI SDK 认证              │ │
│  │  - 首选: oke_workload_identity     │               │  - 首选: workload_identity        │ │
│  │  - 备选: instance_principal        │               │  - 当前文档化备选: oci_config_secret│ │
│  │  - explicit: 调用方显式传 --auth   │               │                                   │ │
│  │                                    │               │                                   │ │
│  │  注入 / 运行时辅助                 │               │  注入 / 运行时配置                │ │
│  │  - OCI_RESOURCE_PRINCIPAL_*        │               │  - OCI_RESOURCE_PRINCIPAL_*       │ │
│  │  - OCI_CLI_AUTH                    │               │  - gateway config.json            │ │
│  │  - /home/node/.openclaw/bin/oci    │               │  - DEBUG_UI_AUTH_TOKEN            │ │
│  │    wrapper 自动补 --auth           │               │                                   │ │
│  │                                    │               │                                   │ │
│  │  网络出口                          │               │  网络出口                          │ │
│  │  - DNS                             │               │  - DNS                            │ │
│  │  - gateway service :8000           │               │  - OCI GenAI HTTPS :443          │ │
│  └───────────────┬────────────────────┘               └──────────────────┬────────────────┘ │
│                  │   通过 Cluster DNS / Service 的 HTTP                   │                  │
│                  │   http://oci-anthropic-gateway...:8000                │                  │
│                  v                                                       v                  │
│          ┌─────────────────────┐                                 ┌──────────────────────┐  │
│          │ SVC openclaw        │                                 │ OCI Generative AI    │  │
│          │ ClusterIP :18789    │                                 │ inference endpoint   │  │
│          └──────────┬──────────┘                                 └──────────────────────┘  │
│                     │                                                                        │
│          ┌──────────v──────────┐                                                             │
│          │ SVC oci-anthropic   │                                                             │
│          │ -gateway ClusterIP  │                                                             │
│          │ :8000               │                                                             │
│          └─────────────────────┘                                                             │
│                                                                                              │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

IAM / 授权模型：
- Gateway Workload Identity policy：
  - 主体 = 受 namespace + service account + cluster_id 约束的 workload principal
  - 权限 = inspect generative-ai-model, use generative-ai-chat
- OpenClaw Workload Identity policy：
  - 主体 = 受 namespace + service account + cluster_id 约束的 workload principal
  - 权限 = manage buckets, manage objects
- OpenClaw Instance Principal fallback policy：
  - 主体 = worker-node Dynamic Group
  - 权限 = manage buckets, manage objects
```

### 1.3 架构说明

- `openclaw` 与 `oci-anthropic-gateway` 是两个独立 pod，对应独立的 service account、独立的 IAM 主体、独立的 OCI 访问路径。
- `openclaw` 不直接调用 OCI GenAI 做模型推理；它通过 ClusterIP 调用集群内 gateway 服务。
- 真正调用 OCI Generative AI 的组件是 `gateway`。
- `openclaw` 对 OCI 的访问主要面向 pod 内 OCI CLI 使用场景，例如 agent exec tools 或人工运维操作。
- 首选认证模型：
  - gateway -> OKE Workload Identity
  - openclaw OCI CLI -> OKE Workload Identity
- 当前仓库文档化的备选认证模型：
  - openclaw OCI CLI -> Instance Principal
  - gateway -> 如果不能使用 Workload Identity，则回退到 `oci_config_secret`
- `explicit` 不是单独的 IAM 模型；它表示每次 OCI CLI 调用都需要显式传 `--auth`。
- 默认架构下不需要公网 LoadBalancer；管理员访问 OpenClaw UI 通过 port-forward + 可选 SSH 本地端口转发完成。

## 2. 快速开始

### 2.1 准备配置文件

```bash
cp scripts/oci/gateway.env.example scripts/oci/gateway.env
cp -f config.json.template config.json

vi scripts/oci/gateway.env
vi config.json
```

必须填写：
- `scripts/oci/gateway.env`：`OCI_REGION`、`OCI_COMPARTMENT_OCID`、`OCI_CLUSTER_OCID`（或不填以触发建集群流程）、`GATEWAY_IMAGE*`、`OCI_USERNAME`、`OCI_AUTH_TOKEN`、`DEBUG_UI_AUTH_TOKEN`
- `config.json`：`compartment_id`、`model_definitions.*.ocid`

> 注意：`OCI_AUTH_TOKEN` 若包含特殊字符必须加双引号。

### 2.2 一键部署

推荐路径：首选使用 OKE Workload Identity 作为认证方式。

```bash
# 推荐：部署并同时创建/更新 Workload Identity 所需 IAM Policy
# 默认 mode 为 all：同时覆盖 gateway GenAI + OpenClaw workload-identity Object Storage 授权
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --apply-iam-policy

# 使用已有 OKE（跳过建集群）
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --apply-iam-policy --skip-create-cluster

# 仅部署（不修改 IAM）
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply

# 备选方案：创建/更新 worker-node Dynamic Group，并应用
# OpenClaw 的 instance principal Object Storage policy
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply \
  --create-instance-principal-dynamic-group \
  --apply-instance-principal-policy
```

### 2.3 验证

```bash
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env
```

### 2.4 访问 OpenClaw UI（SSH 场景 / Mac 访问）

1) 在 OCI VM（bastion/admin）上启动 port-forward（建议前台运行或用 tmux/screen）：
```bash
kubectl -n openclaw-prod port-forward svc/openclaw 18789:18789
```
在 VM 本机访问：`http://127.0.0.1:18789`

2) 从 Mac 访问（SSH 本地端口转发）：
```bash
ssh -N -L 18789:127.0.0.1:18789 ubuntu@<VM公网IP或可达地址>
```
然后在 Mac 浏览器打开：`http://127.0.0.1:18789`

### 2.5 获取 OpenClaw UI Token（用于 UI 登录/控制）

```bash
kubectl -n openclaw-prod exec openclaw-0 -c cli -- cat /home/node/.openclaw/gateway-token
```

> 安全提示：该 token 等价于 UI 会话凭证，建议仅在受控终端使用，必要时轮换。

## 3. 常用命令

```bash
# gateway 部署（可独立执行）
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --apply

# openclaw 部署（可选）
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply

# 首选 IAM policy 路径：Workload Identity（默认 mode=all）
bash scripts/oci/11_workload_identity_policy.sh create-or-update --env scripts/oci/gateway.env

# 备选 IAM policy 路径：OpenClaw instance principal Object Storage
# 需要已有 Dynamic Group
bash scripts/oci/12_openclaw_instance_principal_policy.sh create-or-update --env scripts/oci/gateway.env

# Dynamic Group 辅助脚本（适合快速实验；需要 IAM 权限；默认 matching rule 使用 OCI_COMPARTMENT_OCID）
bash scripts/oci/12a_openclaw_instance_principal_dynamic_group.sh create-or-update --env scripts/oci/gateway.env

# 清理 gateway（可选）
bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env --apply
```

## 4. gateway 与 openclaw 的 OCI 认证模式

gateway 和 openclaw 是两个独立的 pod，也对应两条独立的 OCI 访问路径：
- `oci-anthropic-gateway` pod：通过 OCI SDK 调用 OCI Generative AI
- `openclaw` pod：通过 OCI CLI 供 agent exec tools 或人工 `kubectl exec` 使用

这两条路径可以独立授权、独立配置。

### 4.1 首选路径：OKE Workload Identity

#### 4.1.1 Gateway 使用 Workload Identity

推荐配置：
- `AUTH_MODE=workload_identity`
- 在 `scripts/oci/gateway.env` 中设置 `OCI_RESOURCE_PRINCIPAL_REGION`

Pod 侧注入：
- `k8s/04-deployment.yaml` 中会设置：
  - `serviceAccountName: oci-gateway-sa`
  - `OCI_RESOURCE_PRINCIPAL_VERSION`
  - `OCI_RESOURCE_PRINCIPAL_REGION`

授权方式：
- 主脚本：`scripts/oci/11_workload_identity_policy.sh`
- 常见一键流程：
  ```bash
  bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --apply-iam-policy
  ```
- Policy 通过以下条件进行绑定：
  - namespace
  - service account
  - cluster OCID
- 如果只给 gateway 配置 GenAI 授权：
  ```bash
  bash scripts/oci/11_workload_identity_policy.sh create-or-update \
    --env scripts/oci/gateway.env \
    --mode gateway-genai
  ```

默认授予的能力：
- `inspect generative-ai-model`
- `use generative-ai-chat`

优点：
- 不需要把 OCI API key 挂载进 pod
- pod 级身份边界比 node 级身份更细
- IAM 条件可以精确约束到 namespace + service account + cluster
- 更符合 gateway pod 的最小权限访问模型

#### 4.1.2 OpenClaw 使用 Workload Identity

推荐配置：
- `OPENCLAW_OCI_CLI_AUTH_MODE=oke_workload_identity`（默认）

Pod 侧注入：
- `k8s/openclaw/05-statefulset.yaml` 中会设置：
  - `serviceAccountName: openclaw-sa`
  - `OCI_RESOURCE_PRINCIPAL_VERSION`
  - `OCI_RESOURCE_PRINCIPAL_REGION`
  - `OCI_CLI_AUTH=oke_workload_identity`
- 同一个 manifest 还会生成 OCI CLI wrapper：`/home/node/.openclaw/bin/oci`
- 该 wrapper 会自动补上 `--auth oke_workload_identity`，除非模式设为 `explicit`

授权方式：
- 主脚本：`scripts/oci/11_workload_identity_policy.sh`
- 仅给 OpenClaw 配置 Object Storage policy：
  ```bash
  bash scripts/oci/11_workload_identity_policy.sh create-or-update \
    --env scripts/oci/gateway.env \
    --mode openclaw-objectstorage \
    --namespace openclaw-prod \
    --service-account openclaw-sa
  ```
- 默认 `--apply-iam-policy` 路径使用 mode `all`，同时包含：
  - gateway 的 GenAI 权限
  - OpenClaw 的 workload-identity Object Storage 权限

OpenClaw 默认授予的能力：
- `manage buckets`
- `manage objects`

优点：
- 使用 pod 级身份，而不是 node 级身份
- 更适合 agent 驱动的 OCI CLI 调用安全边界
- 不需要在 pod 中放置 OCI config/key secret
- 最适合作为 OpenClaw exec tools 的默认 OCI 路线

当前集群已验证结果：
- openclaw 容器内已注入 `OCI_CLI_AUTH=oke_workload_identity`
- `/home/node/.openclaw/bin/oci os ns get --debug` 会显示 `auth: oke_workload_identity`
- OpenClaw agent 已通过 OKE workload identity 成功调用 OCI CLI，并成功创建 Object Storage bucket
- 已验证测试桶 `test-bucket-20260329-1119z` 的 `created-by=ocid1.workload...`，说明创建者是 OKE workload principal，而不是个人用户或 instance principal

### 4.2 备选路径：Instance Principal

#### 4.2.1 OpenClaw 使用 Instance Principal

备选配置：
- `OPENCLAW_OCI_CLI_AUTH_MODE=instance_principal`

Pod 侧行为：
- `k8s/openclaw/05-statefulset.yaml` 中的 OCI CLI wrapper 会自动补上：
  - `--auth instance_principal`

授权前提：
1. 需要一个匹配 worker nodes 的 OCI Dynamic Group
2. 需要一个授予该 Dynamic Group 的 IAM policy

相关脚本：
- Dynamic Group 辅助脚本：
  ```bash
  bash scripts/oci/12a_openclaw_instance_principal_dynamic_group.sh create-or-update --env scripts/oci/gateway.env
  ```
- Instance principal policy：
  ```bash
  bash scripts/oci/12_openclaw_instance_principal_policy.sh create-or-update --env scripts/oci/gateway.env
  ```
- 一键 fallback 方式：
  ```bash
  bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply \
    --create-instance-principal-dynamic-group \
    --apply-instance-principal-policy
  ```

OpenClaw 当前默认授予的 instance principal 能力：
- `manage buckets`
- `manage objects`

为什么保留这条路径：
- 当当前集群中的 OKE Workload Identity 不可用或不稳定时，可作为 fallback
- 在某些已经接受 node identity 的环境里更容易快速打通

代价 / 局限：
- node 级身份边界比 pod 级更粗
- 需要额外管理 Dynamic Group
- 同一节点上的多个 pod 可能共享同一个节点身份边界
- 应作为备选路径，而不是首选路径

#### 4.2.2 Gateway 与 Instance Principal

当前仓库**没有**把 gateway instance principal 作为正式的一等脚本化部署路径来说明。

对 gateway 而言，当前仓库正式记录的认证方式是：
- `AUTH_MODE=workload_identity`（首选）
- `AUTH_MODE=oci_config_secret`（legacy 显式凭据路径）

因此在本仓库中的实际建议是：
- gateway 首选 Workload Identity
- 如果不能使用 Workload Identity，则回退到 `oci_config_secret`
- 不建议把 gateway instance principal 视为本仓库的标准文档化路径

### 4.3 OpenClaw OCI CLI 的 explicit 模式

支持配置：
- `OPENCLAW_OCI_CLI_AUTH_MODE=explicit`

行为：
- OpenClaw 的 OCI wrapper **不会**自动补 `--auth`
- 每次调用 OCI CLI 都必须显式指定认证方式，例如：
  ```bash
  /home/node/.openclaw/bin/oci os ns get --auth oke_workload_identity
  /home/node/.openclaw/bin/oci os ns get --auth instance_principal
  ```

适用场景：
- 调试
- 受控实验
- 有意验证多种 auth 路线

重要注意事项：
- 如果忘记写 `--auth`，OCI CLI 可能回退到默认的 config-file 行为
- 这会产生具有误导性的报错，例如找不到 `~/.oci/config`
- 某些 `kubectl exec ... sh -lc` 交互 shell 会重置 `PATH`，导致 `oci` 命中 `/usr/local/bin/oci` 而不是 wrapper
- 最稳妥的形式是：
  - `/home/node/.openclaw/bin/oci ... --auth <mode>`

建议总结：
- 默认使用 `oke_workload_identity`
- `instance_principal` 仅作为 fallback
- `explicit` 只用于你明确希望按命令逐次控制 `--auth` 的场景

## 5. 可选：为 agent 驱动的 kubectl 挂载 kubeconfig

- `scripts/oci/gateway.env` 也支持把 kubeconfig 挂载进 openclaw pod：
  - `OPENCLAW_MOUNT_KUBECONFIG=1`
  - `OPENCLAW_KUBECONFIG_FILE=/path/to/kubeconfig`
  - `OPENCLAW_KUBECONFIG_SECRET_NAME=openclaw-kubeconfig`
- 启用后，部署脚本会创建并填充 Secret，pod 内通过 `/home/node/.kube/config` 暴露，并设置 `KUBECONFIG=/home/node/.kube/config`。
- 这是一个可选增强能力，可作为 agent 在 pod 内执行 `kubectl` 的辅助前提；它不是 OpenClaw 通过 `oke_workload_identity` 访问 OCI Object Storage 的必要条件。
- 挂载进去的 kubeconfig 必须是**在 pod 运行时内部也可直接使用**的 kubeconfig。宿主机生成的 kubeconfig 可能仍依赖外部凭据或 exec 登录流程，未必能在容器内直接使用。
- 如果不需要 pod 内 `kubectl`，可以设为 `OPENCLAW_MOUNT_KUBECONFIG=0`。
- 最佳实践：使用最小权限、专用的 kubeconfig，而不是个人 admin kubeconfig。

## 6. 文档
- 故障排查：`docs/troubleshooting.md`
- IAM / Workload Identity：`docs/iam-workload-identity.md`
- Go-Live checklist：`docs/go-live-checklist.md`
- Local Docker：`docs/local-docker.md`（详细步骤见 `local-docker/README.md`）
- Archive（历史记录/计划草稿）：`docs/archive/`

## 7. 相关文件
- `scripts/oci/gateway.env.example` / `scripts/oci/gateway.env`
- `config.json.template` / `config.json`
- `k8s/`（Kubernetes manifests）
- `local-docker/`
