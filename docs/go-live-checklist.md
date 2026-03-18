# Go-Live Checklist（生产上线检查清单）

## 1. 发布前（Pre-Flight）
- [ ] `scripts/oci/gateway.env` 已替换全部 `REPLACE_*` 占位符。
- [ ] `GATEWAY_IMAGE` 为固定版本 tag（不是 `latest`）。
- [ ] `DEBUG_UI_AUTH_TOKEN` 已设置高强度随机值。
- [ ] 执行机工具齐全：`oci`、`kubectl`、`docker`。
- [ ] `config.json` 已填写：`compartment_id`、`model_definitions.*.ocid`。
- [ ] OKE 节点资源满足 openclaw + gateway 双工作负载需求。

## 2. 网络与安全
- [ ] Gateway Service 为 `ClusterIP`（若非必要不暴露 LB）。
- [ ] `06-networkpolicy-egress-template.yaml` 已生效。
- [ ] 已确认 gateway egress 仅允许 DNS + HTTPS 出口。
- [ ] `/debug` / debug API 未授权访问返回 `401/403`。
- [ ] 管理员访问 `/debug` 经过 VPN/Bastion 或白名单入口。

## 3. 功能联调
- [ ] openclaw -> gateway 内网连通：
  - `oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000`
- [ ] `/v1/messages` 请求成功。
- [ ] 流式请求（SSE）稳定。
- [ ] 工具调用（tool calls）端到端正常。
- [ ] 模型映射（gateway config）与预期一致。

## 4. 观测与告警
- [ ] 可查看 gateway / openclaw Pod 日志。
- [ ] 监控错误率（4xx/5xx）、P95/P99 延迟、重启次数。
- [ ] 关键告警策略已开启（连续失败、错误率、不可用）。

## 5. 切流步骤
1. 先部署 gateway 并通过 `03_verify_gateway.sh`。
2. 部署 openclaw 并确认 rollout 成功。
3. 执行小流量验证（灰度请求）。
4. 逐步提升流量到目标比例。
5. 发布后 30 分钟重点观察错误率和延迟。

## 6. 回滚条件与动作
### 6.1 触发条件（任一满足即回滚）
- 错误率持续超过基线阈值。
- SSE 频繁中断或超时。
- 上游调用大面积失败。

### 6.2 回滚动作
1. 回滚 openclaw 到上一个稳定版本（或回滚 gateway 版本）。
2. 复测 `/v1/messages`、debug 鉴权、端到端请求。
3. 记录故障窗口与根因，冻结异常版本。
