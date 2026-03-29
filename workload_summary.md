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
- `ocid1.bucket.oc1.us-chicago-1.aaaaaaaapbfcfrd5wlzfyj5x4nunih6ypze2xxjhizrmqntz3oqmsbcc4q4a`

### 3. 创建者身份验证通过
查询 bucket 元数据结果显示：
- `created-by = ocid1.workload.oc1.ord.c4bpwo4ouha.mdawmdrmmdrmy2q5owjinzrhmjy5nduymjvhyzzkmme3zmnm`

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

## 外部 ../openclaw 仓库需要单独提交的改动说明和清单
以下改动不在当前 deployment repo 中，而是在外部 OpenClaw 源仓库 `../openclaw`：

### 变更文件
- `../openclaw/Dockerfile`

### 已做改动
在 runtime image 中新增了 `kubectl` 安装能力，具体包括：
- 新增构建参数：
  - `OPENCLAW_KUBECTL_VERSION="v1.35.0"`
  - `OPENCLAW_KUBECTL_SHA256=""`
- 在 OCI CLI 安装步骤中增加：
  - 下载 `kubectl`
  - 写入 `/usr/local/bin/kubectl`
  - `chmod 0755 /usr/local/bin/kubectl`

### 目的
让 OpenClaw pod 内运行的 agent 具备直接执行 `kubectl` 的基础能力，配合已支持的 kubeconfig 挂载，可用于后续 agent 驱动的 Kubernetes 操作场景。

### 这部分改动的状态
- 已在本地 `../openclaw/Dockerfile` 完成修改
- 已通过新的 image tag 构建出包含 `kubectl` 的镜像
- **但尚未在 `../openclaw` 对应 git 仓库中单独提交**

### 建议在外部仓库单独提交时的说明
建议提交说明可写为：
- Add kubectl to OpenClaw runtime image

建议提交内容应聚焦：
- runtime image 现在同时包含 `oci` CLI 与 `kubectl`
- 为 OKE pod 内 agent 场景补齐 K8s 命令执行基础能力
- 不把 workload identity deployment repo 的改动混进这个提交

### 建议交付边界
- 当前 deployment repo：负责 OKE 部署、manifest、env、IAM、文档
- `../openclaw` repo：负责 runtime image 内容（如 `kubectl`、`oci` CLI 等工具链）
