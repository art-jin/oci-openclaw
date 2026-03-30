# OpenClaw OKE Workload Identity 简版汇报

## 结论
本次已完成 OpenClaw 在 OKE 上通过 **pod 级 OKE Workload Identity** 调用 OCI CLI 的验证闭环。

已确认：
- OpenClaw pod 内 `oci` CLI 默认走 `oke_workload_identity`
- Agent 已在 pod 内成功执行 Object Storage 操作并创建 bucket
- OCI 侧 bucket 元数据中的 `created-by` 为 **workload OCID**，证明创建者是 workload principal，而不是个人用户或 instance principal

## 已验证结果
### 1. 认证路径验证通过
在 openclaw pod 内执行 `oci os ns get --debug`，已确认输出：
- `auth: oke_workload_identity`

说明 OpenClaw pod 内 OCI CLI 已实际通过 OKE Workload Identity 完成认证。

### 2. Object Storage 创建验证通过
Agent 已成功创建测试 bucket：
- `test-bucket-20260329-1119z`

对应 bucket OCID：
- `ocid1.bucket.oc1.us-chicago-1.aaaa...q4a`

### 3. 创建者身份验证通过
查询 bucket 元数据结果显示：
- `created-by = ocid1.workload.oc1.ord.c4bp...zmnm`

这说明该 bucket 的创建者是：
- **OKE workload principal / workload identity**

而不是：
- 个人用户 OCID
- instance principal

## 本次交付范围内已完成内容
当前 deployment repo 已完成并推送：
- OpenClaw 默认 OCI CLI auth 改为 `oke_workload_identity`
- OpenClaw pod 注入 `OCI_CLI_AUTH=oke_workload_identity`
- `oci` wrapper 默认自动补 `--auth oke_workload_identity`
- 部署脚本、IAM policy 文案、README/README_CN 已更新
- instance principal 明确降级为 fallback 路线

已推送提交：
- `c4a5b92` — `Default OpenClaw OCI auth to OKE workload identity`
- `ff57021` — `Document OpenClaw workload identity verification`

## 说明
- 可选的 kubeconfig 挂载能力已保留，但它不是本次 bucket 创建成功的必要条件。
- 本次核心成果是：**OpenClaw agent 在 pod 内通过 OKE workload identity 成功调用 OCI CLI 并创建 Object Storage bucket。**

## 外部 ../openclaw/Dockerfile 最终修改说明
以下改动不在当前 deployment repo 中，而是在外部 OpenClaw 源仓库 `../openclaw`：

- 变更文件：`../openclaw/Dockerfile`
- 当前最终状态：runtime image 已包含 `oci` CLI，并新增了 `kubectl`
- 其中：
  - `oci` CLI 是 OpenClaw pod 内执行 `oci ...` 的前提
  - `kubectl` 是后续 pod 内 Kubernetes 运维能力增强
- 这部分改动应在 `../openclaw` 仓库中单独审视和提交，不应混入当前 deployment repo 的正式交付边界

关于这部分外部 Dockerfile 改动的最终说明，包括：
- 修改位置
- `oci` CLI 的安装方式
- `kubectl` 的新增方式
- 与 deployment repo 的职责边界
- 运行时调用链说明

请参考：
- `openclaw_docker_upd.md`

当前状态：
- 已在本地 `../openclaw/Dockerfile` 完成 `kubectl` 相关修改，并确认当前最终状态包含 `oci` 与 `kubectl`
- 已可构建出包含 `oci` 与 `kubectl` 的镜像
- 若仅针对本次新增部分补做独立提交，建议 commit message：
  - `Add kubectl to OpenClaw runtime image`
