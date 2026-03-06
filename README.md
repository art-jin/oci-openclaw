# OCI OKE 部署总览（openclaw + oci-anthropic-gateway）

本仓库是部署仓库，用于把以下两个系统部署到 OCI OKE：
- `openclaw`（上游 Anthropic 兼容应用）
- `oci-anthropic-gateway`（网关，仅允许访问 OCI GenAI）

## 1. 需求

### 1.1 业务需求
- 在同一个 OKE 集群内部署 openclaw 与 gateway。
- openclaw 作为上游，只通过集群内地址访问 gateway。
- gateway 作为唯一 OCI GenAI 出口。
- `/debug` 仅管理员可访问。

### 1.2 安全需求
- gateway egress 默认拒绝，仅允许 DNS 和 443（配合 OCI 网络侧进一步收敛）。
- gateway 默认 `ClusterIP`，不直接公网暴露。
- debug API 保持 Bearer Token 认证。

### 1.3 仓库职责需求
- 当前仓库仅负责部署资产：`k8s/`、`scripts/`、`docs/`。
- gateway/openclaw 源码与镜像构建可在外部仓库完成。

## 2. 架构

### 2.1 文字说明
- 用户访问 openclaw。
- openclaw 调用 gateway（集群内 DNS）。
- gateway 调 OCI GenAI。
- 管理员经 VPN/Bastion 访问 gateway `/debug`。

### 2.2 文字图（ASCII）

```text
                        +-----------------------------+
                        |       OCI OKE Cluster       |
                        |                             |
User Request ---------->|  Namespace: openclaw-prod   |
                        |  +-----------------------+  |
                        |  |  Openclaw Service     |  |
                        |  +-----------+-----------+  |
                        |              |              |
                        |              | HTTP (internal DNS)
                        |              v              |
                        |  Namespace: gateway-prod    |
                        |  +-----------------------+  |
                        |  | oci-anthropic-gateway |  |
                        |  | Service: ClusterIP    |  |
                        |  +-----------+-----------+  |
                        +--------------|--------------+
                                       |
                                       | HTTPS 443
                                       v
                        +-----------------------------+
                        |      OCI Generative AI      |
                        +-----------------------------+

Admin ---> VPN/Bastion ---> /debug (Bearer Token Auth)
```

## 3. 执行过程

### 第 0 步：准备参数文件

```bash
cp scripts/oci/gateway.env.example scripts/oci/gateway.env
vi scripts/oci/gateway.env
```
### 0.5 先准备模型配置（必做）

```bash
cp -f config.json.template config.json
vi config.json
```

必须填写：
- `compartment_id`
- `model_definitions` 下每个模型的 `ocid`

说明：`scripts/oci/02_deploy_gateway_oke.sh` 已增加校验。若 `ocid` 仍是模板占位值，部署会直接失败并提示具体模型名。


最少需要替换：
- `OCI_CLUSTER_OCID`
- `OCI_COMPARTMENT_OCID`
- `GATEWAY_IMAGE`（或改为 build 模式）
- `OCI_USERNAME`
- `OCI_AUTH_TOKEN`
- `DEBUG_UI_AUTH_TOKEN`
- `GATEWAY_CONFIG_JSON_FILE` 对应配置（默认 `./config.json`）里所有 `model_definitions.*.ocid`

### 第 1 步：生成 OKE kubeconfig

```bash
bash scripts/oci/01_prepare_oke_kubeconfig.sh scripts/oci/gateway.env
bash scripts/oci/01_prepare_oke_kubeconfig.sh scripts/oci/gateway.env --apply
```

输出示例：
```text
[INFO] Purpose: generate/update kubeconfig for OKE cluster ocid1.cluster...
+ oci ce cluster create-kubeconfig ...
+ kubectl --kubeconfig ... get nodes -o wide
```

### 第 2 步：部署 gateway

```bash
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --apply
```

输出示例：
```text
[INFO] Purpose: deploy gateway to OKE namespace gateway-prod from deployment repository.
[INFO] Using image: ord.ocir.io/<ns>/oci-gateway:v1.0.0
+ kubectl ... apply -f 00-namespace.yaml
+ kubectl ... create configmap gateway-config ...
+ kubectl ... rollout status deploy/oci-anthropic-gateway --timeout=300s
[INFO] Deployment completed.
```

### 第 3 步：部署 openclaw（可选）

```bash
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply
```

输出示例：
```text
[INFO] Deploying Openclaw manifests from: ../openclaw/k8s
+ kubectl ... create namespace openclaw-prod ...
+ kubectl ... -n openclaw-prod apply -f ../openclaw/k8s
+ kubectl ... set env deployment/openclaw ANTHROPIC_BASE_URL=http://oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000
+ kubectl ... rollout status deployment/openclaw --timeout=300s
```

### 第 4 步：联调验证

```bash
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env
```

输出示例：
```text
[INFO] Gateway resources
NAME ...
[INFO] Verify /debug/api/sessions without token should be 401 or 403
unauthorized_http_code=401
[INFO] Verify /healthz
ok
[INFO] Verify Openclaw namespace can reach gateway service
ok
```

### 第 5 步：清理 gateway 资源（可选）

```bash
bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env
bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env --apply
```

输出示例：
```text
[INFO] Purpose: cleanup gateway resources in namespace gateway-prod.
+ kubectl ... delete deployment oci-anthropic-gateway --ignore-not-found
+ kubectl ... delete service oci-anthropic-gateway --ignore-not-found
[INFO] Dry run only. Add --apply to execute cleanup.
```

## 4. 关键命令速查

```bash
# 1) kubeconfig
bash scripts/oci/01_prepare_oke_kubeconfig.sh scripts/oci/gateway.env --apply

# 2) gateway
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --apply

# 3) openclaw
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply

# 4) verify
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env

# 5) cleanup
bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env --apply
```

## 5. 相关文件
- `gate-docker.md`：需求与目标架构说明
- `docs/oci-deploy-guide.md`：部署手册
- `scripts/oci/gateway.env`：实际执行参数
- `k8s/`：gateway 清单模板

## 6. 生产上线检查清单（Go-Live Checklist）

### 6.1 发布前（Pre-Flight）
- [ ] `scripts/oci/gateway.env` 已替换全部 `REPLACE_*` 占位符。
- [ ] `GATEWAY_IMAGE` 为固定版本 tag（不是 `latest`）。
- [ ] `DEBUG_UI_AUTH_TOKEN` 已设置高强度随机值。
- [ ] `OCI_CONFIG_FILE` / `OCI_KEY_FILE` 路径在执行机可读。
- [ ] `OPENCLAW_MANIFEST_DIR` 指向正确版本清单。
- [ ] OKE 节点资源满足 openclaw + gateway 双工作负载需求。

### 6.2 网络与安全
- [ ] Gateway Service 为 `ClusterIP`（若非必要不暴露 LB）。
- [ ] `06-networkpolicy-egress-template.yaml` 已生效。
- [ ] 已确认 gateway egress 仅允许 DNS + HTTPS 出口。
- [ ] `/debug/api/*` 未授权访问返回 `401/403`。
- [ ] 管理员访问 `/debug` 经过 VPN/Bastion 或白名单入口。

### 6.3 功能联调
- [ ] openclaw 到 gateway 域名连通：
  `oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000`
- [ ] 非流式请求成功（`/v1/messages`）。
- [ ] 流式请求成功（SSE 不中断）。
- [ ] 工具调用（tool calls）端到端正常。
- [ ] 模型映射（gateway config）与预期一致。

### 6.4 观测与告警
- [ ] 可查看 gateway / openclaw Pod 日志。
- [ ] 监控 4xx/5xx 比例、P95/P99 延迟、重启次数。
- [ ] 关键告警策略已开启（连续失败、错误率、不可用）。

### 6.5 切流步骤
1. 先部署 gateway 并通过 `03_verify_gateway.sh`。
2. 部署 openclaw（`--deploy-openclaw`）并确认 rollout 成功。
3. 执行小流量验证（灰度请求）。
4. 逐步提升流量到目标比例。
5. 发布后 30 分钟重点观察错误率和延迟。

### 6.6 回滚条件与动作
触发条件（任一满足即回滚）：
- 错误率持续超过基线阈值。
- SSE 频繁中断或超时。
- 上游调用大面积失败。

回滚动作：
1. 将 openclaw 指向上一个稳定 gateway 版本（或回滚 openclaw Deployment）。
2. 回滚 gateway Deployment 到上一个稳定镜像 tag。
3. 复测 `/healthz`、`/debug` 鉴权、端到端消息请求。
4. 记录故障窗口与根因，冻结当前异常版本。

## 7. 极简模式（你只填必要参数）

目标：你只改少量参数，然后一条命令完成：
- （可选）创建 OKE 集群
- 准备 kubeconfig
- 部署 gateway
- 部署 openclaw
- 配置 openclaw -> gateway 连接
- 暴露 openclaw 到公网（OCI LoadBalancer）

### 7.1 你只需要改这些参数
编辑 [scripts/oci/gateway.env](/Users/arthurjin/PycharmProjects/oci-openclaw/scripts/oci/gateway.env)：

- `OCI_REGION`
- `OCI_COMPARTMENT_OCID`
- `OCI_CLUSTER_OCID`
: 如果你还没建 OKE，先保留 `REPLACE_ME`，脚本会先尝试建集群。
- `GATEWAY_IMAGE`
: 你的 `oci-anthropic-gateway` 镜像地址（固定 tag）。
- `OCI_USERNAME`
- `OCI_AUTH_TOKEN`
- `DEBUG_UI_AUTH_TOKEN`
- `GATEWAY_CONFIG_JSON_FILE` 对应配置（默认 `./config.json`）里所有 `model_definitions.*.ocid`

其余默认值已经按你要求设置：
- `OKE_NODE_SHAPE=VM.Standard.E5.Flex`
- `OKE_NODE_OCPUS=1`
- `OKE_NODE_MEMORY_GB=8`
- `OKE_NODE_COUNT=2`
- `OKE_API_ENDPOINT_VISIBILITY=PUBLIC`
- `OPENCLAW_PUBLIC_EXPOSE=1`

### 7.2 一条命令执行

```bash
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply
```

### 7.3 你会看到的关键输出

```text
[INFO] OCI_CLUSTER_OCID not set. Running OKE cluster bootstrap script.
[INFO] Creating OKE cluster: openclaw-oke
[INFO] Creating OKE node pool: openclaw-nodepool
...
[INFO] Using image: <your gateway image>
...
[INFO] Deploying Openclaw manifests from: ../openclaw/k8s
...
[INFO] Verify /debug/api/sessions without token should be 401 or 403
unauthorized_http_code=401
[INFO] All-in-one flow completed.
```

### 7.4 公网访问地址获取

部署完成后执行：

```bash
kubectl -n openclaw-prod get svc openclaw-public -o wide
```

当 `EXTERNAL-IP` 分配成功后，即可从公网访问 openclaw；
openclaw 内部再通过 gateway 调用 OCI GenAI。

### 7.5 脚本说明
- [00_create_oke_cluster.sh](/Users/arthurjin/PycharmProjects/oci-openclaw/scripts/oci/00_create_oke_cluster.sh)：创建 OKE（支持新建或复用 VCN）
- [10_deploy_all_in_one.sh](/Users/arthurjin/PycharmProjects/oci-openclaw/scripts/oci/10_deploy_all_in_one.sh)：一键串联执行
- [02_deploy_gateway_oke.sh](/Users/arthurjin/PycharmProjects/oci-openclaw/scripts/oci/02_deploy_gateway_oke.sh)：部署 gateway 并可选部署 openclaw + 公网 LB

## 8. 故障排查（本次实战问题汇总）

### 8.1 `gateway.env` 语法错误（Auth Token 含特殊字符）
现象：
```text
scripts/oci/gateway.env: line XX: syntax error near unexpected token '>'
```
根因：
- `OCI_AUTH_TOKEN` 包含 `>`、`[` 等特殊字符，未加引号。

修复：
```bash
# 错误示例
# OCI_AUTH_TOKEN=(X4Nap[_>rNp[[pC0_[6

# 正确示例
OCI_AUTH_TOKEN="(X4Nap[_>rNp[[pC0_[6"
```

### 8.2 自动建 OKE 时进程被杀（`exit 137` / `zsh: killed`）
现象：
```text
[INFO] Creating OKE cluster ...
zsh: killed oci ce cluster create ...
```
根因：
- 本机执行环境在 `oci ce cluster create` 阶段被系统中断（非脚本语法错误）。

修复（推荐路径）：
1. 在 OCI 控制台手工创建 OKE 集群。
2. 把 `OCI_CLUSTER_OCID` 回填到 `scripts/oci/gateway.env`。
3. 用以下命令继续（跳过建集群）：
```bash
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --skip-create-cluster
```

### 8.3 `kubectl` 超时访问 `10.x.x.x:6443`
现象：
```text
dial tcp 10.x.x.x:6443: i/o timeout
```
根因：
- kubeconfig 使用了 `PRIVATE_ENDPOINT`，本机不在私网。

修复：
- 使用公网 API endpoint 生成 kubeconfig：
```bash
OKE_KUBE_ENDPOINT=PUBLIC_ENDPOINT
```
- 脚本已支持可配置 `--kube-endpoint "${OKE_KUBE_ENDPOINT:-PRIVATE_ENDPOINT}"`。

### 8.4 缺少 `kubectl`
现象：
```text
bash: kubectl: command not found
```
修复：
```bash
brew install kubectl
```

### 8.5 `config.json` 的模型 OCID 未填写
现象：
```text
[ERROR] config.json model_definitions contains invalid ocid values
```
根因：
- `model_definitions.*.ocid` 仍是模板值。

修复：
```bash
cp -f config.json.template config.json
vi config.json
# 填写每个 model_definitions.<model>.ocid 为真实 ocid1.generativeaimodel...
```

说明：
- 部署脚本已内置校验，若未填真实 OCID 会直接阻断部署。

### 8.6 `GATEWAY_REPO_DIR` 路径错误或缺少 Dockerfile
现象：
```text
[ERROR] file not found: <path>/Dockerfile
```
根因：
- 指向了错误目录，或源码仓库中确实没有 Dockerfile。

修复：
1. 确认目录：
```bash
GATEWAY_REPO_DIR=/Users/arthurjin/PycharmProjects/oci-anthropic-gateway0222
```
2. 若仓库无 Dockerfile，创建最小可用版本：
```dockerfile
FROM python:3.11-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt
COPY . /app
EXPOSE 8000
CMD ["python", "main.py"]
```

### 8.7 本机缺少 Docker
现象：
```text
bash: docker: command not found
```
修复：
```bash
brew install --cask docker
open -a Docker
```
等待 Docker Engine 启动后重试部署。

### 8.8 只有 VCN OCID，不知道其他子网 OCID
处理方式：
- 用已有 `OCI_CLUSTER_OCID` 反查并回填以下字段：
  - `OKE_ENDPOINT_SUBNET_OCID`
  - `OKE_WORKER_SUBNET_OCID`
  - `OKE_LB_SUBNET_OCID`
- 已在本项目流程中按该方式处理。

## 9. 实践经验（本次落地总结）

### 9.1 先决条件要前置校验
- `config.json` 中 `model_definitions.*.ocid` 必须先填真实值，否则网关无法正确路由模型。
- `gateway.env` 中所有包含特殊字符的值（尤其 `OCI_AUTH_TOKEN`）必须加双引号。
- 在执行部署前，先确认本机工具齐全：`oci`、`kubectl`、`docker`。

### 9.2 建议的执行顺序
1. 先确认 OKE 集群状态 `ACTIVE`、NodePool `ACTIVE`。
2. 生成 kubeconfig 并验证：`kubectl get nodes`。
3. 再执行 gateway 与 openclaw 部署。
4. 最后做 `/debug` 未授权校验与 openclaw->gateway 连通性校验。

### 9.3 网络与访问经验
- 本机不在私网时，`PRIVATE_ENDPOINT` 会导致 `kubectl` 超时，应改为 `PUBLIC_ENDPOINT`。
- openclaw 对公网暴露建议通过 `LoadBalancer`，gateway 维持集群内访问（`ClusterIP`）更稳妥。

### 9.4 自动化脚本经验
- 自动创建 OKE 可能受本机执行环境影响（例如进程被系统 kill）；可改为控制台手工建集群后，用 `--skip-create-cluster` 继续自动化部署。
- `GATEWAY_IMAGE_MODE=build` 前提是 `GATEWAY_REPO_DIR` 存在且包含可构建的 `Dockerfile`。
- 若源码仓库无 Dockerfile，需要先补最小可运行 Dockerfile。

### 9.5 清理经验（cleanup 验证）
- 先删 K8s 应用资源，再删 NodePool，再删 Cluster，顺序更稳定。
- 删除 OKE 资源时状态会经历 `DELETING`，需轮询等待到 `DELETED`/`not found`。
- 若 VCN/子网是复用网络，清理时应保留，不要误删。

### 9.6 推荐的“可重复执行”命令
- 跳过建集群部署：
```bash
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --skip-create-cluster
```
- 仅清理 gateway 应用资源：
```bash
bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env --apply
```
