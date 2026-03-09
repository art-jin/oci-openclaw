# OKE 目标架构与落地计划（openclaw + oci-anthropic-gateway）

## 1. 目标

在 OCI OKE 中部署两套工作负载：
- `openclaw`：上游 Anthropic 兼容应用
- `oci-anthropic-gateway`：网关，仅允许访问 OCI GenAI

强约束：
- openclaw 只能通过集群内 DNS 访问 gateway。
- gateway 对外 egress 默认拒绝，只放行 OCI GenAI 所需 HTTPS 与 DNS。
- `/debug` 仅管理员可访问（Bearer Token + 网络入口限制）。

## 2. 仓库职责拆分（重构后）

本仓库为“部署仓库”，不再假设与 `oci-anthropic-gateway` 源码同仓。

- 部署仓库（当前仓库）负责：
  - `k8s/`：Kubernetes 清单模板
  - `scripts/oci/`：OKE 部署/验证/清理脚本
  - `docs/`：部署操作手册
- 业务源码仓库负责：
  - `oci-anthropic-gateway` 代码与 Dockerfile
  - `openclaw` 应用代码与其上游发布清单

## 3. 目标拓扑（To-Be）

```text
User -> Openclaw (ns=openclaw-prod)
                  |
                  v
         Gateway Service (ns=gateway-prod, :8000)
                  |
                  v
             OCI GenAI Endpoint

Admin -> VPN/Bastion -> Gateway /debug
```

## 4. 关键部署原则

1. 命名空间隔离：`gateway-prod` 与 `openclaw-prod`。
2. 网关 Service 默认使用 `ClusterIP`，避免不必要暴露。
3. 若必须经 LB 访问 `/debug`，使用内网 LB 或公网白名单，并保留 Bearer Token。
4. Gateway Deployment 固定镜像 tag，不使用 `latest`。
5. Openclaw 的 Anthropic provider `baseUrl` 指向：
   - `http://oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000`

## 5. 推荐执行顺序

1. 准备 `scripts/oci/gateway.env`（从 `gateway.env.example` 复制）。
2. 生成 kubeconfig：`scripts/oci/01_prepare_oke_kubeconfig.sh`。
3. 部署 gateway：`scripts/oci/02_deploy_gateway_oke.sh --apply`。
4. 部署 openclaw：`scripts/oci/02_deploy_gateway_oke.sh --deploy-openclaw --apply`。
5. 联调验证：`scripts/oci/03_verify_gateway.sh`。
6. 清理 gateway 资源：`scripts/oci/04_cleanup_gateway_oke.sh`。

## 6. 镜像策略（与源码仓库解耦）

`02_deploy_gateway_oke.sh` 支持两种模式：
- `GATEWAY_IMAGE_MODE=prebuilt`：直接使用已存在镜像（推荐生产）。
- `GATEWAY_IMAGE_MODE=build`：从 `GATEWAY_REPO_DIR` 指向的外部源码目录构建并推送 OCIR。

## 7. 完成标准（DoD）

- Openclaw 在 OKE 内稳定调用 gateway（流式与非流式）。
- `/debug/api/*` 未授权访问返回 `401/403`。
- Gateway Pod 无法访问非授权外网（策略收敛）。
- Gateway 与 Openclaw 升级互不依赖同仓提交。
