# 外部 ../openclaw/Dockerfile 最终修改说明

## 背景
本次 OKE workload identity 相关主线改动已经在当前 deployment repo 完成并提交。

但 OpenClaw Pod 内需要具备两类容器工具能力，这部分不属于 deployment repo，而属于外部 OpenClaw 源仓库：
- `oci` CLI：供 agent runtime 和人工 `kubectl exec` 进入容器后直接调用 OCI API
- `kubectl`：供 pod 内 agent 执行 Kubernetes 运维操作

因此，和运行时镜像组成相关的改动发生在外部仓库：
- `../openclaw`

这部分应在外部仓库单独提交，而不应混入当前 deployment repo 的正式交付边界。

## 变更文件
- `../openclaw/Dockerfile`

## 最终修改位置
修改发生在 `../openclaw/Dockerfile` 的 **runtime stage**，即最终运行镜像阶段。

具体是在这段安装逻辑中完成：
- 先安装 OCI CLI
- 再在同一段 runtime 工具安装步骤中追加 `kubectl`

从当前 `../openclaw/Dockerfile` 可确认，关键位置包括：
- OCI CLI 相关：`../openclaw/Dockerfile:148` 到 `../openclaw/Dockerfile:165`
- kubectl 相关：`../openclaw/Dockerfile:152` 到 `../openclaw/Dockerfile:169`

## 最终修改内容

### 1. OCI CLI 的安装方式
`oci` 命令不是在 deployment 阶段注入，也不是在 K8s manifest 中安装的，而是在 OpenClaw 镜像构建阶段就安装进 runtime image。

当前 Dockerfile 中的安装方式为：
- 定义版本参数：`OPENCLAW_OCI_CLI_VERSION="3.67.0"`
- 定义虚拟环境目录：`OPENCLAW_OCI_CLI_VENV_DIR="/opt/oci-cli-venv"`
- 通过 `python3 -m venv` 创建 OCI CLI 虚拟环境
- 通过 `pip install "oci-cli==${OPENCLAW_OCI_CLI_VERSION}"` 安装 OCI CLI
- 通过软链接暴露为全局命令：
  - `/usr/local/bin/oci -> ${OPENCLAW_OCI_CLI_VENV_DIR}/bin/oci`

也就是说，OpenClaw 容器内 `oci` 的来源是：
- **`../openclaw/Dockerfile` 构建阶段安装**
- **运行时以 `/usr/local/bin/oci` 形式可用**

### 2. kubectl 的新增安装方式
在保留原有 OCI CLI 安装逻辑的基础上，又在同一段 runtime 工具安装步骤中新增了 `kubectl` 安装。

新增内容包括：
- 新增构建参数：
  - `OPENCLAW_KUBECTL_VERSION="v1.35.0"`
  - `OPENCLAW_KUBECTL_SHA256=""`
- 通过 `curl` 下载 `kubectl` 二进制到：
  - `/usr/local/bin/kubectl`
- 若提供 `OPENCLAW_KUBECTL_SHA256`，则执行校验
- 设置执行权限：
  - `chmod 0755 /usr/local/bin/kubectl`

也就是说，OpenClaw 容器内 `kubectl` 的来源同样是：
- **`../openclaw/Dockerfile` 构建阶段安装**
- **运行时以 `/usr/local/bin/kubectl` 形式可用**

## 与 deployment repo 的配合关系
需要明确区分“镜像中具备命令”与“部署时启用命令所需认证/配置”是两层不同职责。

### 外部 `../openclaw` repo 负责
- runtime image 组成
- 容器内基础工具链
- `oci` CLI 安装
- `kubectl` 安装
- OpenClaw Dockerfile 维护

### 当前 deployment repo 负责
- OKE 部署脚本
- Kubernetes manifests
- ServiceAccount / Secret / ConfigMap 注入
- Workload Identity 相关环境变量注入
- kubeconfig 挂载能力
- IAM policy 和部署文档

换句话说：
- `oci` / `kubectl` **是否存在于容器内**：由 `../openclaw/Dockerfile` 决定
- `oci` **运行时用什么身份认证**：由当前 deployment repo 的 K8s 部署方式决定
- `kubectl` **运行时连哪个集群**：由当前 deployment repo 是否挂载 kubeconfig 决定

## 与本次主成果的关系

### 本次主成果
OpenClaw agent 在 pod 内通过 `oke_workload_identity` 成功调用 OCI CLI，并成功创建 Object Storage bucket。

### Dockerfile 改动在其中的作用
这次关于 `../openclaw/Dockerfile` 的最终状态，需要分成两部分理解：

1. `oci` CLI 安装
- 这是 OpenClaw pod 内执行 `oci ...` 的前提条件
- 如果镜像里没有 `oci`，就无法在 exec tool 中直接运行 OCI 命令

2. `kubectl` 安装
- 这是附加运行时能力增强
- 它不是本次 workload identity 创建 bucket 成功的必要条件
- 它的价值在于后续 agent/Kubernetes 运维场景

因此可以明确区分为：
- workload identity 成功创建 bucket：依赖 pod 内存在 `oci` CLI + 正确的运行时身份配置
- 镜像内加入 `kubectl`：属于后续 K8s 运维能力增强

## 运行时实际调用链说明
当前部署下，OpenClaw Pod 内执行 `oci` 命令时，链路不是“deployment repo 安装 OCI CLI”，而是：

1. `../openclaw/Dockerfile` 在镜像构建阶段安装 `/usr/local/bin/oci`
2. 当前 deployment repo 的 `k8s/openclaw/05-statefulset.yaml` 在容器启动后生成 wrapper：
   - `/home/node/.openclaw/bin/oci`
3. `PATH` 优先命中这个 wrapper
4. wrapper 再调用真实的 `/usr/local/bin/oci`
5. 并自动补上：
   - `--auth oke_workload_identity`
   - 或其他由 `OPENCLAW_OCI_CLI_AUTH_MODE` 指定的认证模式

因此：
- **命令本体来自镜像构建**
- **认证方式来自运行时部署配置**

## 当前状态
- `../openclaw/Dockerfile` 已在本地确认当前最终状态，其中保留既有 OCI CLI 安装，并新增 kubectl 安装
- 当前最终状态已包含：
  - OCI CLI 安装
  - kubectl 安装
- 已可基于该 Dockerfile 构建出同时包含 `oci` 与 `kubectl` 的 OpenClaw 镜像
- 但与本次 handoff 对应的外部仓库改动仍应在 `../openclaw` 仓库中单独审视和提交

## 建议在外部仓库中的提交说明
如果只针对本次新增部分（即 `kubectl`）补做独立提交，建议 commit message：

```text
Add kubectl to OpenClaw runtime image
```

如果后续希望把“runtime image 同时包含 oci 与 kubectl”作为更完整说明，也可考虑：

```text
Document runtime image tooling for OCI and Kubernetes operations
```

但从当前代码边界看，更适合独立提交的是前者。

## 建议提交内容边界
外部 `../openclaw` 仓库提交中，建议只包含：
- `Dockerfile` 中 runtime image 工具链相关改动
- 尤其是 `kubectl` 安装的新增逻辑

不建议混入：
- deployment repo 的 env / manifest / IAM / README 改动
- workload identity 的部署说明文档
- 临时验证记录文件
- 当前 repo 中的 handoff 文档本身

## 交付建议
建议将本文件保留在当前 deployment repo 中，作为对外部 `../openclaw/Dockerfile` 最终修改方式的说明和 handoff 记录，方便后续：
- 在 `../openclaw` 仓库中补做独立提交
- 向同事说明 `oci` / `kubectl` 分别是在什么阶段进入容器的
- 区分镜像构建职责与运行时部署职责
