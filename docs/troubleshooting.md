# Troubleshooting（故障排查）

## 1) `gateway.env` 语法错误（Auth Token 含特殊字符）
现象：
```text
scripts/oci/gateway.env: line XX: syntax error near unexpected token '>'
```
根因：
- `OCI_AUTH_TOKEN` 包含 `>`、`[` 等特殊字符，未加引号。

修复：
```bash
OCI_AUTH_TOKEN="..."
```

## 2) 自动建 OKE 时进程被杀（`exit 137` / `zsh: killed`）
现象：
```text
[INFO] Creating OKE cluster ...
zsh: killed oci ce cluster create ...
```
修复（推荐路径）：
1. 在 OCI 控制台手工创建 OKE 集群。
2. 把 `OCI_CLUSTER_OCID` 回填到 `scripts/oci/gateway.env`。
3. 跳过建集群继续部署：
```bash
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --skip-create-cluster
```

## 3) `kubectl` 超时访问 `10.x.x.x:6443`
现象：
```text
dial tcp 10.x.x.x:6443: i/o timeout
```
根因：
- kubeconfig 使用了 `PRIVATE_ENDPOINT`，本机不在 OCI 私网/VPN。

修复：
- 设置：`OKE_KUBE_ENDPOINT=PUBLIC_ENDPOINT`
- 重新生成 kubeconfig：
```bash
bash scripts/oci/01_prepare_oke_kubeconfig.sh scripts/oci/gateway.env --apply
```

## 4) `config.json` 的模型 OCID 未填写
现象：
```text
[ERROR] config.json model_definitions contains invalid ocid values
```
修复：
- 填写 `config.json` 中每个 `model_definitions.<model>.ocid` 为真实 `ocid1.generativeaimodel...`

## 5) OpenClaw：Model context window too small (8192). Minimum is 16000
现象：
```text
Agent failed before reply: Model context window too small (8192 tokens). Minimum is 16000.
```
修复：
1) 调整 `k8s/openclaw/01-configmap-openclaw-config-template.yaml` 中模型 `contextWindow`（>= 16000，例如 128000）。
2) apply 并重启 OpenClaw StatefulSet：
```bash
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply
kubectl -n openclaw-prod rollout restart statefulset/openclaw
kubectl -n openclaw-prod rollout status statefulset/openclaw --timeout=300s
```
3) 验证日志：
```bash
kubectl -n openclaw-prod logs pod/openclaw-0 -c openclaw --tail=200
```
