# OKE Deployment YAML (Gateway)

该目录提供 gateway 在 OKE 的清单模板。

## Files

- `00-namespace.yaml`: namespace
- `01-configmap-gateway-config.yaml`: `config.json` 模板
- `02-secret-debug-auth.yaml`: `DEBUG_UI_AUTH_TOKEN` secret 模板
- `03-secret-oci-sdk.yaml`: OCI SDK config/key secret 模板（`/root/.oci/*`）
- `04-deployment.yaml`: gateway deployment（镜像占位）
- `05-service-internal-lb.yaml`: 默认 `ClusterIP`（最小暴露）
- `05b-service-public-lb-whitelist.yaml`: 如需公网 LB，使用源地址白名单
- `06-networkpolicy-egress-template.yaml`: egress 策略模板（DNS + 443）

## 推荐方式

优先使用脚本：
- `scripts/oci/02_deploy_gateway_oke.sh`

脚本会自动：
- 渲染 namespace / image 占位符
- 创建 ConfigMap 与 Secret
- 应用 deployment / service / networkpolicy

## 手工应用（仅调试）

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/04-deployment.yaml
kubectl apply -f k8s/05-service-internal-lb.yaml
kubectl apply -f k8s/06-networkpolicy-egress-template.yaml
```

## 验证

```bash
kubectl -n gateway-prod get pods,svc
kubectl -n gateway-prod logs deploy/oci-anthropic-gateway --tail=200
```
