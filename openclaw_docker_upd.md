# 外部 ../openclaw 仓库需要单独提交的改动说明和清单

## 背景
本次 OKE workload identity 相关主线改动已经在当前 deployment repo 完成并提交。

但还有一项运行时镜像能力增强，修改发生在外部 OpenClaw 源仓库：
- `../openclaw`

因此这部分需要在外部仓库单独提交，而不应混入当前 deployment repo 的正式交付边界。

## 变更文件
- `../openclaw/Dockerfile`

## 已做改动
在 OpenClaw runtime image 中新增了 `kubectl` 安装能力。

### 新增构建参数
- `OPENCLAW_KUBECTL_VERSION="v1.35.0"`
- `OPENCLAW_KUBECTL_SHA256=""`

### 安装逻辑调整
在原有 OCI CLI 安装步骤中，追加了以下逻辑：
- 下载 `kubectl`
- 写入 `/usr/local/bin/kubectl`
- 设置执行权限 `chmod 0755 /usr/local/bin/kubectl`

## 改动目的
该改动的目的不是实现 OKE workload identity 本身，而是增强 OpenClaw runtime image 的基础运维能力：
- 让 pod 内 agent 具备直接执行 `kubectl` 的前提
- 配合 deployment repo 中已经支持的 kubeconfig 挂载能力，可支持后续 agent 驱动的 Kubernetes 操作场景

## 与本次主成果的关系
需要明确区分：

### 本次主成果
OpenClaw agent 在 pod 内通过 `oke_workload_identity` 成功调用 OCI CLI，并成功创建 Object Storage bucket。

### 该 Dockerfile 改动的角色
`kubectl` 安装属于**附加运行时能力增强**，不是本次 workload identity 创建桶成功的必要条件。

也就是说：
- workload identity 成功创建 bucket：主线成果
- 镜像内加入 `kubectl`：后续 agent/K8s 运维能力增强

## 当前状态
- `../openclaw/Dockerfile` 已完成本地修改
- 已基于新内容构建出包含 `kubectl` 的镜像
- 但该改动**尚未在 `../openclaw` 仓库单独提交**

## 建议在外部仓库中的提交说明
建议 commit message：

```text
Add kubectl to OpenClaw runtime image
```

## 建议提交内容边界
外部 `../openclaw` 仓库提交中，建议只包含：
- `Dockerfile` 中 runtime image 安装 `kubectl` 的改动

不建议混入：
- deployment repo 的 env / manifest / IAM / README 改动
- workload identity 的部署说明文档
- 临时验证记录文件

## 仓库职责建议
### 当前 deployment repo
负责：
- OKE 部署脚本
- Kubernetes manifests
- IAM policy
- env 配置
- 部署文档

### 外部 `../openclaw` repo
负责：
- runtime image 组成
- 容器内基础工具链（如 `oci` CLI、`kubectl`）
- OpenClaw runtime 本身的 Dockerfile 维护

## 交付建议
建议将该文件作为 handoff 记录保存在当前 repo 中，方便后续在 `../openclaw` 仓库中补做独立提交时直接参考。
