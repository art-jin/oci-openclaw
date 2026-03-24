# OCI OKE 部署（openclaw + oci-anthropic-gateway）

本仓库用于将以下组件部署到 OCI OKE：
- `oci-anthropic-gateway`：集群内网关（对接 OCI GenAI）
- `openclaw`：上游 Anthropic 兼容应用（通过集群内 DNS 调用 gateway）

## 1. 架构（OKE）

### 1.1 目标调用链路

```text
User -> openclaw (openclaw-prod) -> gateway (gateway-prod/ClusterIP) -> OCI GenAI (HTTPS)
Admin -> VPN/Bastion -> gateway /debug (Bearer Token)
```

### 1.2 实现架构（ASCII 图，含端口转发访问路径）

```text
(External access: no LoadBalancer)

Mac Browser/Terminal
  │  http://127.0.0.1:18789
  │
  ├─ ssh -L 18789:127.0.0.1:18789 <user>@<oci-vm>
  │
OCI VM (bastion/admin)
  │  kubectl -n openclaw-prod port-forward svc/openclaw 18789:18789
  │
  └─ forwards to ClusterIP svc/openclaw:18789 → openclaw Pod
                         │
                  (Cluster: OCI OKE)
┌───────────────────────────────────────────────────────────────────────────┐
│                                                                           │
│  Namespace: openclaw-prod                   Namespace: gateway-prod       │
│  ┌─────────────────────────────┐           ┌───────────────────────────┐ │
│  │ Pod: openclaw-0             │           │ Pod: oci-anthropic-gateway│ │
│  │  - UI/Gateway :18789        │           │  - Anthropic API :8000     │ │
│  │  - egress: only to gateway  │  HTTP     │  - WI -> OCI GenAI HTTPS   │ │
│  └───────────────┬─────────────┘  :8000    └──────────────┬────────────┘ │
│                  │        via Cluster DNS/service          │              │
│                  │  http://oci-anthropic-gateway...:8000   │              │
│                  v                                         v              │
│          ┌───────────────────┐                   ┌────────────────────┐  │
│          │ SVC openclaw      │                   │ OCI Generative AI   │  │
│          │  ClusterIP :18789 │                   │  inference endpoint │  │
│          └─────────┬─────────┘                   └────────────────────┘  │
│                    │                                                       │
│          ┌─────────v─────────┐                                             │
│          │ SVC oci-anthropic │                                             │
│          │ -gateway ClusterIP│                                             │
│          │ :8000             │                                             │
│          └───────────────────┘                                             │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘

```

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

```bash
# 仅部署（默认不修改 IAM）
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply

# 可选：同时创建/更新 Workload Identity 所需 IAM Policy（推荐首次部署执行一次）
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --apply-iam-policy

# 使用已有 OKE（跳过建集群）
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --skip-create-cluster
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

# IAM policy（Workload Identity）
bash scripts/oci/11_workload_identity_policy.sh create-or-update --env scripts/oci/gateway.env

# 清理 gateway（可选）
bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env --apply
```

## 4. 文档
- 故障排查：`docs/troubleshooting.md`
- IAM / Workload Identity：`docs/iam-workload-identity.md`
- Go-Live checklist：`docs/go-live-checklist.md`
- Local Docker：`docs/local-docker.md`（详细步骤见 `local-docker/README.md`）
- Archive（历史记录/计划草稿）：`docs/archive/`

## 5. 相关文件
- `scripts/oci/gateway.env.example` / `scripts/oci/gateway.env`
- `config.json.template` / `config.json`
- `k8s/`（Kubernetes manifests）
- `local-docker/`
