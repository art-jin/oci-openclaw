# oci-openclaw：在 OCI OKE 上部署 oci-anthropic-gateway + OpenClaw（Workload Identity）

> 本仓库是**部署仓库**：只包含 Kubernetes manifests、Shell 脚本与文档；镜像源码分别在相邻目录：
> - `../oci-anthropic-gateway`（gateway 源码与 Dockerfile）
> - `../openclaw`（OpenClaw 源码与镜像构建）
>
> 最终实现架构与完整 runbook 以 [`oci-openclaw.md`](./oci-openclaw.md) 为准。

## 1. 目标架构（最终形态）

### 1.1 组件与调用链路

- **oci-anthropic-gateway**（Namespace: `gateway-prod`）
  - 通过 **OKE Workload Identity**（OCI Resource Principal）访问 **OCI Generative AI**
  - 集群内服务（ClusterIP），端口 `8000`

- **OpenClaw**（Namespace: `openclaw-prod`）
  - 通过集群内 DNS 访问 gateway：
    `http://oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000`
  - 通过 NetworkPolicy 限制 egress：仅允许到 gateway（以及必要的 DNS）
  - **不创建 LoadBalancer**；运维侧通过 **kubectl port-forward** / **SSH -L** 访问 UI
  - UI 端口 `18789`

### 1.2 实现架构（ASCII 图，含端口转发访问路径）

```text
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
```

## 2. 部署（最小闭环）

### 2.1 准备配置

```bash
cp -n scripts/oci/gateway.env.example scripts/oci/gateway.env
cp -n config.json.template config.json

vim scripts/oci/gateway.env
vim config.json
```

### 2.2 创建/更新 Workload Identity IAM Policy（必须在 Home Region）

```bash
bash scripts/oci/11_workload_identity_policy.sh create-or-update --env scripts/oci/gateway.env
```

### 2.3 部署 gateway + OpenClaw

```bash
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply
```

### 2.4 验证

```bash
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env
```

## 3. 访问 OpenClaw UI（不暴露公网）

在 OCI VM 上：

```bash
kubectl -n openclaw-prod port-forward svc/openclaw 18789:18789
```

在 Mac 上（可选）：

```bash
ssh -N -L 18789:127.0.0.1:18789 ubuntu@<VM公网IP或可达地址>
```

浏览器打开：`http://127.0.0.1:18789`

## 4. 目录速览

- `oci-openclaw.md`：最终实现架构与 runbook（推荐以此为准）
- `k8s/`：gateway manifests
- `k8s/openclaw/`：OpenClaw manifests
- `scripts/oci/`：部署/验证/清理/Workload Identity policy 脚本
- `docs/`：补充部署文档
