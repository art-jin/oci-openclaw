# IAM: OKE Workload Identity（Gateway / OpenClaw）

本仓库默认使用 OKE Workload Identity（Resource Principal / workload principal）让工作负载在不挂载 OCI API key 的情况下访问 OCI 服务。

## 1. 脚本

- 创建/更新 policy：
```bash
bash scripts/oci/11_workload_identity_policy.sh create-or-update --env scripts/oci/gateway.env
```

- 删除 policy（谨慎）：
```bash
bash scripts/oci/11_workload_identity_policy.sh delete --env scripts/oci/gateway.env
```

- 一键部署时可选执行（会在部署流程中调用 create-or-update）：
```bash
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --apply-iam-policy
```

## 2. 为什么这个步骤默认不自动执行
IAM policy 的创建/修改属于租户级可见变更，通常涉及审批与合规要求。因此 `10_deploy_all_in_one.sh` 默认不会修改 IAM，需要显式加 `--apply-iam-policy`。

## 3. Home Region 注意事项
OCI IAM（Identity）相关的 create/update/delete 操作必须在租户 **Home Region** 执行。

- `scripts/oci/gateway.env` 里建议设置：
  - `OCI_HOME_REGION=<tenancy home region>`

脚本会优先使用 `OCI_HOME_REGION` 来执行 policy 变更。

## 4. Policy 作用范围与绑定条件
脚本生成的 policy 使用 `any-user ... where all { request.principal.type='workload', ... }` 的条件约束进行授权（不要求你手工创建 dynamic group）。

默认绑定条件：
- namespace：`gateway-prod`
- serviceaccount：`oci-gateway-sa`
- cluster_id：`OCI_CLUSTER_OCID`

可通过脚本参数覆盖：
```bash
bash scripts/oci/11_workload_identity_policy.sh create-or-update \
  --env scripts/oci/gateway.env \
  --namespace gateway-prod \
  --service-account oci-gateway-sa
```

## 5. Policy mode
脚本支持三种 policy 模式（`--mode`）：

### 5.1 `all`（默认）
一次性创建/更新两组 statement：
- gateway 调用 OCI Generative AI：
  - inspect generative-ai-model
  - use generative-ai-chat
- OpenClaw workload identity Object Storage：
  - manage buckets
  - manage objects

默认会使用两组主体：
- `gateway-prod` / `oci-gateway-sa`
- `openclaw-prod` / `openclaw-sa`

### 5.2 `gateway-genai`
仅用于 gateway 调用 OCI Generative AI。

### 5.3 `openclaw-objectstorage`
仅用于 OpenClaw workload identity 访问 Object Storage（buckets + objects）。

示例：
```bash
bash scripts/oci/11_workload_identity_policy.sh create-or-update \
  --env scripts/oci/gateway.env \
  --mode openclaw-objectstorage \
  --namespace openclaw-prod \
  --service-account openclaw-sa
```

## 6. 与 instance principal 的关系

需要区分两条路径：

- workload identity policy（本文件）
  - 是当前仓库的首选路径
  - 适用于 gateway
  - 也适用于 OpenClaw pod 内 OCI CLI 的首选路线
- instance principal policy（单独脚本）
  - 是 OpenClaw OCI CLI 的备选 / fallback 路线
  - 适用于 OKE Workload Identity 不可用、未打通或需要临时绕行的场景
  - 脚本：
  ```bash
  bash scripts/oci/12_openclaw_instance_principal_policy.sh create-or-update --env scripts/oci/gateway.env
  ```

如果没有 IAM 权限创建 Dynamic Group，也不影响部署本身；只会影响 OpenClaw 通过 instance principal 访问 OCI 资源的 fallback 授权配置。

## 7. 验证

## 6. 验证
部署完成后，如果 gateway `/v1/messages` 返回 internal_error，通常需要查看日志确认是 IAM（401/403）还是模型/OCID 配置问题：

```bash
kubectl -n gateway-prod logs deploy/oci-anthropic-gateway --tail=200
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env
```
