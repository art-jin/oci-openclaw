# oci-openclaw：在 OCI OKE 上部署 oci-anthropic-gateway + OpenClaw（Workload Identity）

> 本仓库是**部署仓库**：只包含 Kubernetes manifests、Shell 脚本与文档；镜像源码分别在相邻目录：
> - `../oci-anthropic-gateway`（gateway 源码与 Dockerfile）
> - `../openclaw`（OpenClaw 源码与镜像构建）
>
本文档整理了本次安装部署所需的配置、脚本、执行过程、目标架构/网络拓扑与测试方法。

---

## 1. 目标架构（最终形态）

### 1.1 组件与调用链路

- **Pod A：oci-anthropic-gateway**（Namespace: `gateway-prod`）
  - 通过 **OKE Workload Identity**（OCI Resource Principal）访问 **OCI Generative AI**
  - 仅在集群内提供服务（ClusterIP）
  - 端口：`8000`

- **Pod B：OpenClaw**（Namespace: `openclaw-prod`）
  - 通过集群内 DNS 访问 gateway：
    `http://oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000`
  - **不能直接访问 OCI GenAI**：通过 NetworkPolicy 限制 egress，仅允许到 gateway（以及必要的 DNS）
  - 对外访问方式：不创建 LoadBalancer；运维侧通过 **kubectl port-forward** 或 **SSH 本地端口转发**访问 UI
  - 端口：`18789`

### 1.2 实现架构（ASCII 图，含端口转发访问路径）

> README 通常描述“目标架构”；这里补充本仓库落地后的“实现架构”，把**集群内调用链路**与**外部访问路径**放在一张图里。

```
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

**请求流：**

```
Mac 浏览器/终端
  └─(SSH -L)→ OCI VM(inst_art_claw):127.0.0.1:18789
                 └─(kubectl port-forward)→ svc/openclaw:18789 (ClusterIP)
                       └→ OpenClaw Pod
                            └→ oci-anthropic-gateway (ClusterIP:8000)
                                 └→ OCI Generative AI HTTPS endpoint
```

### 1.2 安全边界与暴露面

- gateway：**ClusterIP**（不对公网暴露）
- OpenClaw：**ClusterIP**（不对公网暴露）
- 外部访问 OpenClaw UI：
  - 在 OCI VM 上 `kubectl port-forward` 暴露到 VM 的 loopback
  - 再由 Mac 使用 `ssh -L` 转发到本机 loopback
- 授权：
  - gateway 使用 Workload Identity 访问 OCI GenAI（通过 IAM Policy statement 约束：namespace/serviceAccount/cluster_id）
  - OpenClaw 与 gateway 的访问通过集群内网络+NetworkPolicy约束；OpenClaw 使用“provider apiKey”（对 gateway 侧可选）

---

## 2. 环境与前置条件

### 2.1 必需工具

在执行部署脚本的主机（本次为 OCI VM：`inst_art_claw`）需要：
- `oci` CLI
- `kubectl`
- `docker`（如果需要 build/push 镜像；本次配置为 prebuilt）

### 2.2 已知环境信息（本次部署的实际值）

- Region：`us-chicago-1`
- IAM Home Region（Identity 操作必须在 home region）：`us-ashburn-1`
- Tenancy namespace：`sehubjapacprod`（由 `oci os ns get` 获得）
- OKE Cluster OCID：
  - `<OKE_CLUSTER_OCID>`
- 运行部署脚本的 VM：`inst_art_claw`
  - VM 内网 IP（用于白名单示例）：`10.0.0.246`

镜像（OCIR）：
- gateway：`ord.ocir.io/sehubjapacprod/oci-gateway:v1.0.0`
- openclaw：`ord.ocir.io/sehubjapacprod/openclaw:2026.3.8`

---

## 3. 配置文件与关键参数

### 3.1 `scripts/oci/gateway.env`（本次实际部署 env）

核心字段（摘录要点）：
- OCI 基本信息：
  - `OCI_REGION=us-chicago-1`
  - `OCI_HOME_REGION=us-ashburn-1`
  - `OCI_COMPARTMENT_OCID=...`
  - `OCI_CLUSTER_OCID=...`
  - `KUBECONFIG_PATH=${HOME}/.kube/config`
- gateway：
  - `AUTH_MODE=workload_identity`
  - `GATEWAY_IMAGE_MODE=prebuilt`
  - `GATEWAY_IMAGE=ord.ocir.io/sehubjapacprod/oci-gateway:v1.0.0`
  - `GATEWAY_CONFIG_JSON_FILE=./config.json`
  - `DEBUG_UI_AUTH_TOKEN=...`
- OpenClaw：
  - `OPENCLAW_IMAGE_MODE=prebuilt`
  - `OPENCLAW_IMAGE=ord.ocir.io/sehubjapacprod/openclaw:2026.3.8`
  - `OPENCLAW_GATEWAY_BASE_URL=http://oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000`
  - `OPENCLAW_GATEWAY_API_KEY=any-value-works`
  - `OPENCLAW_PUBLIC_EXPOSE=0`

> 注意：包含特殊字符的值（如 `OCI_AUTH_TOKEN`）必须在 env 文件中用引号包住。

### 3.2 `config.json`（gateway runtime config）

该文件用于告诉 gateway：
- `compartment_id`
- `endpoint`（OCI GenAI inference endpoint）
- `model_definitions.*.ocid`（模型 OCID）
- `default_model`

本次你已经提供了 `compartment_id/endpoint/default_model/ocid`，并使用 `gpt-oss-20b`（以及与之匹配的 model alias/definition）。

### 3.3 Kubernetes manifests

#### gateway（目录：`k8s/`）
按顺序应用：
1. `k8s/00-namespace.yaml`
2. `k8s/01-configmap-gateway-config.yaml`（脚本里实际用 `kubectl create configmap --from-file=config.json`）
3. `k8s/02-secret-debug-auth.yaml`（脚本里实际用 `kubectl create secret generic gateway-debug-auth`）
4. `k8s/04-deployment.yaml`
5. `k8s/05-service-internal-lb.yaml`（本次为 ClusterIP 版本的 service 文件名保持不变）
6. `k8s/06-networkpolicy-egress-template.yaml`

#### OpenClaw（目录：`k8s/openclaw/`）
- `00-namespace.yaml`
- `00-serviceaccount.yaml`
- `01-configmap-openclaw-config-template.yaml`
- `02-secret-openclaw-provider.yaml`
- `03-service-headless.yaml`
- `04-service-clusterip.yaml`
- `05-statefulset.yaml`
- `07-networkpolicy-egress.yaml`

> 关键点：本次最终形态**不使用** `06-service-internal-lb.yaml`（LoadBalancer），避免对外暴露。

---

## 4. Workload Identity（OKE）授权配置

参考同事文档：`oke-sh/okeopenclawWorkloadIdentity.md` 的原则：
- 以 namespace + serviceAccount + clusterOCID 为条件约束 workload principal

### 4.1 gateway 的 IAM Policy（最终使用的 statements）

Policy 名称：`oke-gateway-workload-identity`

最终生效 statements（两条）：

1) 模型可见/查询：
```
Allow any-user to inspect generative-ai-model in compartment id <COMPARTMENT_OCID> where all {request.principal.type='workload',request.principal.namespace='gateway-prod',request.principal.service_account='oci-gateway-sa',request.principal.cluster_id='<OKE_CLUSTER_OCID>'}
```

2) Chat 调用：
```
Allow any-user to use generative-ai-chat in compartment id <COMPARTMENT_OCID> where all {request.principal.type='workload',request.principal.namespace='gateway-prod',request.principal.service_account='oci-gateway-sa',request.principal.cluster_id='<OKE_CLUSTER_OCID>'}
```

> 说明：部署过程中曾尝试在脚本中加入 `generative-ai-inference`，OCI Identity API 返回 400 `No permissions found`，因此按文档与可用权限集合收敛为上述两条。

### 4.2 Policy 管理脚本

脚本：`scripts/oci/11_workload_identity_policy.sh`

用法：
```bash
bash scripts/oci/11_workload_identity_policy.sh create-or-update --env scripts/oci/gateway.env
```

要点：
- Identity（IAM）策略更新必须在 tenancy home region 执行，因此脚本使用 `OCI_HOME_REGION`（本次为 `us-ashburn-1`）

---

## 5. 部署过程（本次实际操作顺序）

> 说明：以下为“已验证可行”的最小闭环流程；脚本默认支持 dry-run（不加 `--apply`）。

### 5.1 准备 kubeconfig（如果需要）
脚本中会调用：
```bash
oci ce cluster create-kubeconfig \
  --cluster-id "$OCI_CLUSTER_OCID" \
  --file "$KUBECONFIG_PATH" \
  --region "$OCI_REGION" \
  --token-version 2.0.0 \
  --kube-endpoint "${OKE_KUBE_ENDPOINT:-PRIVATE_ENDPOINT}" \
  --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
  --overwrite
```

### 5.2 部署 gateway + OpenClaw

```bash
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply
```

### 5.3 验证

```bash
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env
```

输出期望：
- gateway Pod Running
- gateway service ClusterIP
- `/v1/messages` 通过 port-forward 返回 `pong`（或正常模型响应）
- openclaw Pod Running
- openclaw `/healthz` 和 `/readyz` 返回 OK

---

## 6. 关键修正记录（本次部署中发生过的实际问题与处理）

### 6.1 IAM Policy 更新失败：`No permissions found`

现象：运行 `11_workload_identity_policy.sh create-or-update` 时报错：
- `InvalidParameter: No permissions found`

原因：脚本包含了 OCI 不认可的 statement（`use generative-ai-inference`），导致整个 update 请求被判定为“无有效权限语句”。

处理：修改脚本仅保留两条 statement（inspect model + use chat），再执行更新成功。

### 6.2 gateway `/v1/messages` initial internal_error

现象：验证脚本中 `/v1/messages` 返回 internal_error；gateway 日志显示 OCI GenAI 返回 404（authorization failed or resource not found）。

处理：确认并更新 policy 为有效 statements 后，重新验证 `/v1/messages` 返回成功。

### 6.3 OpenClaw 对外暴露收敛

现象：存在 `svc/openclaw-internal`（LoadBalancer），出现 external IP。

目标：按最终架构不创建 LB，仅通过 port-forward 访问。

处理：
- 删除 service：
  ```bash
  kubectl -n openclaw-prod delete svc openclaw-internal
  ```
- 修改部署脚本 `scripts/oci/02_deploy_gateway_oke.sh`，OpenClaw 部署流程不再 apply `k8s/openclaw/06-service-internal-lb.yaml`

---

## 7. 访问方式（无浏览器的 SSH 场景与 Mac 访问）

### 7.1 在 OCI VM 上启动 port-forward（推荐绑定 loopback）

在 VM（inst_art_claw）上：
```bash
kubectl --kubeconfig /home/ubuntu/.kube/config -n openclaw-prod port-forward svc/openclaw 18789:18789
```

这样 OpenClaw UI 在 VM 上可通过：
- `http://127.0.0.1:18789`

### 7.2 从 Mac 访问 VM 上的 UI（SSH 本地端口转发）

在 Mac 上：
```bash
ssh -N -L 18789:127.0.0.1:18789 ubuntu@<VM公网IP或可达地址>
```
然后 Mac 浏览器打开：
- `http://127.0.0.1:18789`

> 注意：Mac 浏览器里访问 `127.0.0.1` 默认指向 Mac 本机，因此必须通过 `ssh -L` 把远端端口转发到本机。

---

## 8. 测试方式说明

### 8.1 gateway 基本可用性（通过 port-forward）

脚本 `03_verify_gateway.sh` 会做 service port-forward 并测试：
- `/healthz`（注意：GET 可能返回 405，不致命）
- `/v1/messages`（关键：必须成功返回）

手工验证示例：
```bash
kubectl -n gateway-prod port-forward svc/oci-anthropic-gateway 8000:8000
curl -sS http://127.0.0.1:8000/v1/messages \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-oss-20b","max_tokens":8,"messages":[{"role":"user","content":"ping"}]}'
```

### 8.2 OpenClaw 健康检查

```bash
# VM 上（或通过 ssh -L 到本机）
curl -sS http://127.0.0.1:18789/healthz
curl -sS http://127.0.0.1:18789/readyz
```

### 8.3 OpenClaw UI Token（用于 UI 登录/控制）

从 Pod 读取 token：
```bash
kubectl -n openclaw-prod exec openclaw-0 -c cli -- cat /home/node/.openclaw/gateway-token
```

本次读到的 token：
- `<OPENCLAW_GATEWAY_TOKEN>`

> 安全提示：该 token 等价于 UI 会话凭证，建议仅在受控终端使用，必要时轮换。

### 8.4 端到端对话验证（OpenClaw → gateway → OCI GenAI）

推荐使用 OpenClaw CLI 在 Pod 内直接跑一次 agent turn（不依赖浏览器）：

1) 查看帮助：
```bash
kubectl -n openclaw-prod exec -it openclaw-0 -c cli -- openclaw agent --help
```

2) 发送消息（根据 `--help` 的实际参数填写）：
```bash
kubectl -n openclaw-prod exec -it openclaw-0 -c cli -- openclaw agent \
  --message "hello" \
  --json
```

> 说明：OpenClaw 2026.3.x 的 HTTP 18789 端口默认服务于控制台 UI/网关，与 OpenAI/Anthropic 兼容 HTTP API 的 POST 路由并不保证开放；
> 因此用内置 CLI 是最稳的端到端验证方式。

---

## 9. 变更点汇总（相对仓库默认内容）

### 9.1 `scripts/oci/11_workload_identity_policy.sh`
- 移除第三条不存在/不被 OCI 接受的 statement
- `--statements` 仅保留 STMT1+STMT2

### 9.2 `scripts/oci/02_deploy_gateway_oke.sh`
- OpenClaw 部署流程不再渲染/应用 `k8s/openclaw/06-service-internal-lb.yaml`
- 不再 `get svc openclaw-internal`

### 9.3 集群状态变更
- 删除 `svc/openclaw-internal`（LoadBalancer）

---

## 10. 日常运维流程（推荐：新建集群 vs 复用集群）

下面给出两种常见工作模式的“最推荐流程”，并明确哪些参数需要改、哪些通常不动。

### 10.1 模式 A：每次都新建 OKE 集群（一次性环境/演示环境）

**适用场景：** PoC、演示、隔离测试环境。

**你通常需要改的内容：**

1) `scripts/oci/gateway.env`
- 集群相关（每次新集群必变）：
  - `OCI_CLUSTER_OCID`（新集群 OCID）
  - 若你使用脚本创建集群，还会涉及 `OKE_*` 一系列参数（如 VCN/Subnet/NodePool 等）
- Workload Identity 相关（跟集群绑定）：
  - `OCI_CLUSTER_OCID`（会进入 IAM policy statement 的 `request.principal.cluster_id`）
- OCI 基本信息（通常不变）：
  - `OCI_REGION`、`OCI_HOME_REGION`、`OCI_COMPARTMENT_OCID`
- 镜像（通常不变，除非你换 tag）：
  - `GATEWAY_IMAGE`、`OPENCLAW_IMAGE`
- OCIR 拉取凭据（通常不变，但注意有效期/轮换）：
  - `OCI_USERNAME`、`OCI_AUTH_TOKEN`、`OCIR_REGION_KEY`、`OCIR_NAMESPACE`

2) `config.json`
- 通常不变：`compartment_id`、`endpoint`、`model_definitions.*.ocid`、`default_model`
- 仅当你切换模型/compartment 时需要改。

3) Kubernetes side（可能需要改）：
- StorageClass：若新集群没有 `oci-bv`，需要在集群先创建该 StorageClass 或修改 `k8s/openclaw/05-statefulset.yaml` 使用已有 StorageClass。

**推荐执行步骤（最短闭环）：**

```bash
# (1) 如果需要：创建/准备 kubeconfig（你也可以用 02_deploy_gateway_oke.sh 内置的 create-kubeconfig）
oci ce cluster create-kubeconfig \
  --cluster-id "<NEW_OKE_CLUSTER_OCID>" \
  --file "$HOME/.kube/config" \
  --region "<OCI_REGION>" \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT \
  --profile "<PROFILE>" \
  --overwrite

# (2) 更新 Workload Identity policy（必须针对新 cluster_id）
bash scripts/oci/11_workload_identity_policy.sh create-or-update --env scripts/oci/gateway.env

# (3) 部署（gateway + openclaw）
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply

# (4) 验证
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env
```

**哪些内容你通常不用动：**
- `k8s/openclaw/06-service-internal-lb.yaml`：即便存在文件，也不再被脚本 apply（我们推荐不暴露 LB）。
- 绝大部分 `k8s/` 与 `k8s/openclaw/` manifests（除非你要调整资源/存储类/网络策略）。

---

### 10.2 模式 B：复用同一个 OKE 集群，只更新镜像/配置（长期环境）

**适用场景：** 日常迭代、稳定环境（dev/staging/prod）。

**你通常需要改的内容：**

1) `scripts/oci/gateway.env`
- 若只是发版：
  - `GATEWAY_IMAGE`（新 tag）
  - `OPENCLAW_IMAGE`（新 tag）
- 若只是改模型映射：
  - 不一定要改 env；主要改 `config.json`
- 通常不变：
  - `OCI_CLUSTER_OCID`（集群不变）
  - `OCI_REGION`、`OCI_COMPARTMENT_OCID`

2) `config.json`
- 你更换模型（OCID）/默认模型/alias 时修改。

3) IAM policy
- **通常不需要改**（因为 cluster_id/namespace/sa 不变）。
- 只有当你改了以下任一项才需要更新 policy：
  - namespace（`gateway-prod`）
  - service account（`oci-gateway-sa`）
  - OKE cluster OCID
  - compartment

**推荐执行步骤（最短闭环）：**

```bash
# (1) 如需要：更新 policy（多数情况下可跳过）
bash scripts/oci/11_workload_identity_policy.sh create-or-update --env scripts/oci/gateway.env

# (2) 部署 apply（会滚动更新 deployment/statefulset）
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply

# (3) 验证
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env
```

**建议习惯：**
- 更新镜像 tag 后，优先观察滚动发布：
  ```bash
  kubectl -n gateway-prod rollout status deploy/oci-anthropic-gateway
  kubectl -n openclaw-prod rollout status statefulset/openclaw
  ```
- 如果只改了 `config.json`（gateway ConfigMap），deployment 会被 apply 更新；但是否触发重启取决于 manifest 是否带了 checksum/重启策略。
  若你发现 ConfigMap 变更未生效，可手工滚动重启：
  ```bash
  kubectl -n gateway-prod rollout restart deploy/oci-anthropic-gateway
  ```

---

## 11. 故障排查（速查）

### 10.1 `/v1/messages` internal_error
- 看 gateway 日志：
  ```bash
  kubectl -n gateway-prod logs deploy/oci-anthropic-gateway --tail=200
  ```
- 重点检查：
  - policy statements 是否正确（namespace/sa/cluster_id/compartment）
  - `config.json` 模型 OCID 是否正确、模型是否在同一 compartment
  - `endpoint` region 是否匹配

### 10.2 OpenClaw Pod 运行但 UI 不可访问
- 确认 port-forward 是否还在：
  - VM 上 `kubectl port-forward ...` 前台不要退出
- 检查 service/pod：
  ```bash
  kubectl -n openclaw-prod get pods,svc -o wide
  ```

### 10.3 OpenClaw PVC Pending
- 检查 storageClass `oci-bv` 是否存在（同事文档示例使用）：
  ```bash
  kubectl get storageclass
  kubectl -n openclaw-prod get pvc
  ```

---

# 附录 A：目录文档与脚本列表（说明）

## A.1 仓库顶层关键文件
- `CLAUDE.md`
  - 本仓库用途、架构说明、脚本入口、配置要求与注意事项
- `config.json.template`
  - gateway config 模板（实际部署使用 gitignored 的 `config.json`）
- `config.json`（本次存在于工作区，通常 gitignored）
  - 实际 gateway runtime config
- `scripts/oci/gateway.env.example`
  - env 模板
- `scripts/oci/gateway.env`（本次实际使用，通常 gitignored）
  - 部署参数

## A.2 主要脚本（`scripts/oci/`）
- `01_prepare_oke_kubeconfig.sh`
  - 生成 kubeconfig
- `02_deploy_gateway_oke.sh`
  - 部署 gateway（可选部署 OpenClaw / oc-app）
- `03_verify_gateway.sh`
  - 验证 gateway 与 OpenClaw
- `04_cleanup_gateway_oke.sh`
  - 清理资源
- `10_deploy_all_in_one.sh`
  - 一键部署入口
- `11_workload_identity_policy.sh`
  - 创建/更新/删除 OKE Workload Identity IAM policy
- `02_build_push_openclaw_ocir.sh`
  - （可选）构建并推送 OpenClaw 镜像到 OCIR

## A.3 Kubernetes manifests
- `k8s/`：gateway 相关 manifests
- `k8s/openclaw/`：OpenClaw 相关 manifests（本次采用 workload identity + egress policy）
- `oke-sh/`：同事手工部署的参考材料（包含 workload identity 的关键 policy statement 示例）

---

# 附录 B：与本次目标无关/未采用的内容（记录）

- `local-docker/`
  - 用于 MacOS Docker Desktop 本地双容器联调，不作为 OKE 部署路径
- `k8s/05b-service-public-lb-whitelist.yaml`
  - gateway 公网/对外 LB（可选），本次目标要求 gateway 不对外，因此未启用
- `k8s/openclaw/06-service-internal-lb.yaml`
  - OpenClaw internal LB（LoadBalancer），本次最终架构要求不创建 LB，因此禁用并删除了已创建的 service

---

# 附录 C：网络拓扑补充说明

- OKE Pod 网络：10.0.0.0/16（示例，实际以 VCN/Subnet 为准）
- `oci-anthropic-gateway` egress：
  - DNS（53）
  - HTTPS（443）到 OCI GenAI endpoint
- `openclaw` egress：
  - DNS（53）
  - 到 gateway service（8000）
  -（按需）阻断直达 OCI GenAI 的 HTTPS（通过 NetworkPolicy 实现）

---

# 附录 D：可复制粘贴的 Runbook（脱敏版：从零到上线，含回滚/清理）

> 面向同事：默认你已经有一个可用的 OKE 集群（或有权限创建），并在一台“运维跳板机/OCI VM”上执行命令。
> 本 Runbook 不包含任何 OCID、token、IP 等敏感信息；请按注释替换为你自己的值。

---

## D.0 最短路径：10 条命令上线（适合贴群）

> 假设：你已经在本机/跳板机上拿到可用的 kubeconfig（`kubectl get nodes` 能通）。

```bash
# 1) 进入部署仓库
cd oci-openclaw

# 2) 准备 env
cp -n scripts/oci/gateway.env.example scripts/oci/gateway.env

# 3) 编辑 env（填 region/home-region/compartment/cluster、镜像、OCIR、DEBUG token 等）
vim scripts/oci/gateway.env

# 4) 准备 gateway config
cp -n config.json.template config.json

# 5) 编辑 config.json（填 compartment_id / endpoint / model ocid / default_model）
vim config.json

# 6) 创建/更新 Workload Identity policy（会在 home region 更新 IAM）
bash scripts/oci/11_workload_identity_policy.sh create-or-update --env scripts/oci/gateway.env

# 7) 部署 gateway + openclaw（dry-run 可先去掉 --apply 预览）
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply

# 8) 验证（gateway /v1/messages + openclaw health）
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env

# 9) 本机启动 OpenClaw UI 端口转发（保持前台运行）
kubectl -n openclaw-prod port-forward svc/openclaw 18789:18789

# 10) 取 UI token（新开终端）
kubectl -n openclaw-prod exec openclaw-0 -c cli -- cat /home/node/.openclaw/gateway-token
```

打开 UI：`http://127.0.0.1:18789`，填入第 10 步 token。

> 如果你是从 Mac SSH 到跳板机：在 Mac 上执行 `ssh -N -L 18789:127.0.0.1:18789 <user>@<vm>`，然后浏览器打开同样的地址。

---

## D.1 前置检查（一次性）

## D.0 约定与变量

- 运行目录：本部署仓库根目录（即 `oci-openclaw/`）
- 使用的命名空间：
  - gateway：`gateway-prod`
  - openclaw：`openclaw-prod`

---

## D.1 前置检查（一次性）

### D.1.1 工具版本

```bash
oci -v
kubectl version --client
docker version
```

### D.1.2 确认能访问 OKE

如果你已有 kubeconfig：
```bash
kubectl get nodes
```

若需要生成 kubeconfig（需要 OCI CLI 权限）：
```bash
# 需替换：<OCI_REGION> <OKE_CLUSTER_OCID> <KUBECONFIG_PATH> <PROFILE>
oci ce cluster create-kubeconfig \
  --cluster-id "<OKE_CLUSTER_OCID>" \
  --file "<KUBECONFIG_PATH>" \
  --region "<OCI_REGION>" \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT \
  --profile "<PROFILE>" \
  --overwrite

kubectl --kubeconfig "<KUBECONFIG_PATH>" get nodes
```

---

## D.2 配置文件准备

### D.2.1 准备 env 文件

```bash
cp scripts/oci/gateway.env.example scripts/oci/gateway.env
vim scripts/oci/gateway.env
```

需要填写/确认的字段（示例）：

```bash
# OCI
OCI_REGION=<region>
OCI_HOME_REGION=<home-region>
OCI_COMPARTMENT_OCID=<compartment-ocid>
OCI_CLUSTER_OCID=<oke-cluster-ocid>
KUBECONFIG_PATH=$HOME/.kube/config

# Auth
AUTH_MODE=workload_identity

# Gateway image
GATEWAY_IMAGE_MODE=prebuilt
GATEWAY_IMAGE=<regionKey>.ocir.io/<tenancyNamespace>/<repo>:<tag>

# OCIR pull secret（如果镜像私有需要）
CREATE_OCIR_PULL_SECRET=1
OCIR_REGION_KEY=<regionKey>
OCI_USERNAME=<idcs-user>
OCI_AUTH_TOKEN="<auth-token>"
OCIR_NAMESPACE=<tenancy-namespace>

# Gateway config
GATEWAY_CONFIG_JSON_FILE=./config.json
DEBUG_UI_AUTH_TOKEN=<random-hex>

# OpenClaw
OPENCLAW_IMAGE_MODE=prebuilt
OPENCLAW_IMAGE=<regionKey>.ocir.io/<tenancyNamespace>/openclaw:<tag>
OPENCLAW_GATEWAY_BASE_URL=http://oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000
OPENCLAW_GATEWAY_API_KEY=any-value-works
OPENCLAW_PUBLIC_EXPOSE=0
```

### D.2.2 准备 gateway 的 `config.json`

```bash
cp config.json.template config.json
vim config.json
```

必须填写：
- `compartment_id`
- `endpoint`（形如 `https://inference.generativeai.<region>.oci.oraclecloud.com`）
- `model_definitions.*.ocid`
- `default_model`

---

## D.3 IAM：Workload Identity Policy（必须在 Home Region）

### D.3.1 创建/更新 policy

```bash
bash scripts/oci/11_workload_identity_policy.sh create-or-update \
  --env scripts/oci/gateway.env
```

期望输出：Policy ACTIVE，statements 包含：
- inspect generative-ai-model
- use generative-ai-chat

> 注意：如出现 `No permissions found`，通常是 statement 写了 OCI 不认可的资源/动词。

---

## D.4 部署（上线）

### D.4.1 Dry-run（建议先跑一次）

```bash
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw
```

### D.4.2 Apply

```bash
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply
```

---

## D.5 验证

### D.5.1 一键验证脚本

```bash
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env
```

### D.5.2 手工验证 gateway（port-forward）

```bash
kubectl -n gateway-prod port-forward svc/oci-anthropic-gateway 8000:8000

# 新开一个终端执行
curl -sS http://127.0.0.1:8000/v1/messages \
  -H 'Content-Type: application/json' \
  -d '{"model":"<your-default-model>","max_tokens":8,"messages":[{"role":"user","content":"ping"}]}'
```

### D.5.3 OpenClaw UI 访问（推荐：仅本机）

在运维机上：
```bash
kubectl -n openclaw-prod port-forward svc/openclaw 18789:18789
```

在运维机本机打开：
- `http://127.0.0.1:18789`

若你是从 Mac SSH 到运维机：在 Mac 上执行 SSH 本地端口转发：
```bash
ssh -N -L 18789:127.0.0.1:18789 <user>@<bastion-or-vm>
```
然后 Mac 打开：
- `http://127.0.0.1:18789`

### D.5.4 获取 OpenClaw UI token（用于 UI 登录/控制）

```bash
kubectl -n openclaw-prod exec openclaw-0 -c cli -- cat /home/node/.openclaw/gateway-token
```

---

## D.6 回滚 / 清理（下线）

### D.6.1 删除工作负载（保留 namespace 可选）

```bash
# gateway
kubectl -n gateway-prod delete deploy/oci-anthropic-gateway || true
kubectl -n gateway-prod delete svc/oci-anthropic-gateway || true
kubectl -n gateway-prod delete configmap/gateway-config || true
kubectl -n gateway-prod delete secret/gateway-debug-auth || true
kubectl -n gateway-prod delete networkpolicy --all || true

# openclaw
kubectl -n openclaw-prod delete statefulset/openclaw || true
kubectl -n openclaw-prod delete svc/openclaw svc/openclaw-headless || true
kubectl -n openclaw-prod delete configmap --all || true
kubectl -n openclaw-prod delete secret --all || true
kubectl -n openclaw-prod delete networkpolicy --all || true

# 如需删除 PVC（不可逆，会丢数据）：
# kubectl -n openclaw-prod delete pvc --all
```

### D.6.2 删除 namespace（更彻底）

```bash
kubectl delete ns gateway-prod || true
kubectl delete ns openclaw-prod || true
```

### D.6.3 删除 IAM policy（可选）

```bash
bash scripts/oci/11_workload_identity_policy.sh delete --env scripts/oci/gateway.env
```

---

## D.7 常见故障与快速定位

- gateway `/v1/messages` 返回 internal_error：
  ```bash
  kubectl -n gateway-prod logs deploy/oci-anthropic-gateway --tail=200
  ```
  检查 policy statements（namespace/sa/cluster_id/compartment）与 `config.json` 模型 OCID。

- OpenClaw PVC Pending：
  ```bash
  kubectl get storageclass
  kubectl -n openclaw-prod get pvc
  kubectl -n openclaw-prod describe pvc <name>
  ```

- port-forward 断开：重新运行 port-forward；或用 `screen/tmux` 保持会话。

---

# 附录 E：本次会话中的关键操作摘录（脱敏版）

- 更新 policy：
  ```bash
  bash scripts/oci/11_workload_identity_policy.sh create-or-update --env scripts/oci/gateway.env
  ```

- 验证：
  ```bash
  bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env
  ```

- 删除 OpenClaw LoadBalancer service（如曾创建）：
  ```bash
  kubectl -n openclaw-prod delete svc openclaw-internal
  ```

- 读取 OpenClaw UI token：
  ```bash
  kubectl -n openclaw-prod exec openclaw-0 -c cli -- cat /home/node/.openclaw/gateway-token
  ```
