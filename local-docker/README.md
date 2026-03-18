# Local Docker 部署

本目录用于在本地 Docker Desktop 环境中部署 OpenClaw + OCI Anthropic Gateway。

## 架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    Docker Desktop (本地)                         │
│                                                                 │
│  ┌─────────────────┐         ┌─────────────────────────────┐   │
│  │    OpenClaw     │  HTTP   │   OCI Anthropic Gateway     │   │
│  │   Port: 18789   │ ──────► │   Port: 8000                │   │
│  │                 │         │                             │   │
│  │  baseUrl:       │         │   服务名: gateway           │   │
│  │  http://gateway │         │   (或容器名: oci-anthropic- │   │
│  │  :8000          │         │    gateway)                 │   │
│  └─────────────────┘         └──────────────┬──────────────┘   │
│                                             │                  │
│                                             │ HTTPS 443        │
│                                             ▼                  │
│                                  ┌───────────────────────┐     │
│                                  │    OCI GenAI          │     │
│                                  │  (Oracle Cloud)       │     │
│                                  └───────────────────────┘     │
│                                                                 │
│  网络: gateway-network (bridge)                                 │
└─────────────────────────────────────────────────────────────────┘
```

## 前置条件

- Docker Desktop 已安装并运行
- OCI 账户已配置，有访问 GenAI 的权限
- OpenClaw 镜像已构建（见下文）

## 快速开始

### 1. 构建 OpenClaw 镜像

```bash
# 在 openclaw 源码目录构建
cd /path/to/openclaw-source
docker build -t openclaw:local .
```

### 2. 准备配置文件

```bash
cd local-docker

# 复制环境配置模板
cp .env.example .env

# 复制 gateway 配置模板
cp gateway-config.json.example gateway-config.json

# 创建 openclaw 配置目录
mkdir -p openclaw-config

# 创建 OCI 凭证目录
mkdir -p oci-credentials
```

### 3. 配置 OCI 凭证

**本地 Docker 开发**：直接使用宿主机的 `~/.oci` 目录，无需复制文件。

Docker Compose 会自动挂载：
- `~/.oci/config` → `/root/.oci/config`
- `~/.oci/oci_api_key.pem` → `/root/.oci/oci_api_key.pem`

**注意**：如果需要修改 `~/.oci/config` 中的路径，确保 `key_file` 指向正确位置。

<details>
<summary>旧方案：复制凭证到项目目录（已废弃）</summary>

```bash
# 创建 oci-credentials 目录并复制凭证
mkdir -p oci-credentials
cp ~/.oci/config oci-credentials/
cp ~/.oci/oci_api_key.pem oci-credentials/

# 修改 oci-credentials/config 中的 key_file 路径
# key_file=/root/.oci/oci_api_key.pem
```

</details>

**重要**: 修改 `oci-credentials/config` 文件，将 `key_file` 路径改为容器内路径：

```
key_file=/root/.oci/oci_api_key.pem
```

### 4. 编辑配置文件

#### 4.1 Gateway 配置 (`gateway-config.json`)

填写以下必填项：

```json
{
  "compartment_id": "ocid1.compartment.oc1..YOUR_COMPARTMENT_ID",
  "endpoint": "https://inference.generativeai.us-chicago-1.oci.oraclecloud.com",

  "model_definitions": {
    "openai.gpt-oss-20b": {
      "ocid": "ocid1.generativeaimodel.oc1.us-chicago-1.YOUR_MODEL_OCID",
      "max_tokens_key": "max_completion_tokens",
      "temperature": 1.0
    }
  },

  "default_model": "openai.gpt-oss-20b"
}
```

**必填字段**:
- `compartment_id`: OCI Compartment OCID
- `model_definitions.*.ocid`: OCI GenAI 模型 OCID
- `endpoint`: OCI GenAI 区域端点

#### 4.2 OpenClaw 配置 (`openclaw-config/openclaw.json`)

**关键配置要点**：

```json
{
  "models": {
    "mode": "merge",
    "providers": {
      "oci-gateway": {
        "baseUrl": "http://gateway:8000",
        "apiKey": "any-value-works",
        "api": "anthropic-messages",
        "models": [
          {
            "id": "openai.gpt-oss-20b",
            "name": "GPT 5.2 (OCI)",
            "contextWindow": 200000,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "oci-gateway/openai.gpt-oss-20b"
      }
    }
  },
  "gateway": {
    "port": 18789,
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "your-secure-token"
    }
  }
}
```

**配置注意事项**：

| 配置项 | 说明 |
|--------|------|
| `baseUrl` | 使用 **服务名** `gateway`（不是容器名），因为在 Docker Compose 网络中服务名解析更可靠 |
| `apiKey` | Gateway 默认不验证 API Key，可以是任意值 |
| `api` | 必须是 `"anthropic-messages"`，OpenClaw 会自动追加 `/v1/messages` |
| `agents.defaults.model.primary` | 格式为 `provider-name/model-id` |

### 5. 启动服务

```bash
# 使用 docker-compose
docker compose up -d

# 或使用部署脚本
./deploy.sh --apply
```

### 6. 验证部署

```bash
# 检查容器状态
docker compose ps

# 检查 Gateway
curl http://localhost:8000/debug/

# 测试 Gateway API
curl -X POST http://localhost:8000/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: test" \
  -d '{"model":"openai.gpt-oss-20b","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'

# 检查 OpenClaw 日志
docker compose logs openclaw --tail=50
```

## 目录结构

```
local-docker/
├── docker-compose.yml              # Docker Compose 配置
├── deploy.sh                       # 部署脚本
├── .env.example                    # 环境变量模板
├── .env                            # 环境变量（需创建，gitignored）
├── gateway-config.json.example     # Gateway 配置模板
├── gateway-config.json             # Gateway 配置（需创建，gitignored）
├── openclaw.json.example           # OpenClaw 配置模板
├── openclaw-config/                # OpenClaw 配置目录
│   └── openclaw.json               # OpenClaw 配置（需创建）
├── oci-credentials/                # OCI 凭证目录（gitignored）
│   ├── config                      # OCI SDK 配置
│   └── oci_api_key.pem             # OCI API 密钥
├── debug_dumps/                    # Gateway 调试日志（自动创建）
└── workspace/                      # OpenClaw 工作空间（自动创建）
```

## 常用命令

```bash
# 启动服务
docker compose up -d

# 查看日志
docker compose logs -f
docker compose logs openclaw --tail=100
docker compose logs gateway --tail=50

# 重启服务
docker compose restart openclaw
docker compose restart gateway

# 停止服务
docker compose down

# 进入容器调试
docker compose exec openclaw sh
docker compose exec gateway sh

# 测试容器间网络连通性
docker compose exec openclaw curl http://gateway:8000/debug/
```

## 访问地址

| 服务 | 地址 | 说明 |
|------|------|------|
| OpenClaw Gateway | http://localhost:18789 | OpenClaw API 端点 |
| OCI Gateway API | http://localhost:8000 | Anthropic 兼容 API |
| Gateway Debug UI | http://localhost:8000/debug/ | 调试界面（需启用） |

**注意**: OpenClaw Bridge 端口 (18790) 用于本地直接运行，不在 Docker 中配置。

## 故障排查

### 问题 1: OpenClaw 报 "Connection error"

**症状**: OpenClaw 日志显示 `embedded run agent end ... error=Connection error`

**排查步骤**:

1. 检查 `openclaw.json` 中的 `baseUrl`：
   ```bash
   # 错误：使用 localhost（在容器内指向容器自身）
   "baseUrl": "http://localhost:8000"

   # 正确：使用 Docker 服务名
   "baseUrl": "http://gateway:8000"
   ```

2. 测试容器间网络连通性：
   ```bash
   docker compose exec openclaw curl http://gateway:8000/debug/
   ```

3. 确认两个容器在同一网络：
   ```bash
   docker network inspect gateway-network
   ```

### 问题 2: Gateway 认证失败

**症状**: Gateway 返回 401 或 OCI API 错误

**排查步骤**:

1. 检查 OCI 凭证文件：
   ```bash
   ls -la oci-credentials/
   ```

2. 确认 `config` 文件中 `key_file` 路径正确：
   ```
   key_file=/root/.oci/oci_api_key.pem
   ```

3. 检查 Compartment ID 和模型 OCID 是否正确

### 问题 3: OpenClaw 设备认证

**症状**: 需要批准设备登录

**解决方案**:
```bash
# 查看待批准设备
docker compose exec openclaw node dist/index.js devices list --token your-token

# 批准设备
docker compose exec openclaw node dist/index.js devices approve <device-uuid> --token your-token
```

## OKE 迁移注意事项

从本地 Docker 迁移到 OCI OKE 时，需要注意以下配置变更：

| 配置项 | 本地 Docker | OKE |
|--------|-------------|-----|
| Gateway baseUrl | `http://gateway:8000` | `http://oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000` |
| 网络模式 | bridge | ClusterIP |
| OCI 凭证 | 挂载文件 | Kubernetes Secret |
| 配置管理 | 本地文件 | ConfigMap + Secret |
| 镜像来源 | 本地构建 | OCIR (OCI Registry) |

详见 `../k8s/` 目录下的 Kubernetes manifests。

## 配置模板

### 完整的 openclaw.json 示例

```json
{
  "models": {
    "mode": "merge",
    "providers": {
      "oci-gateway": {
        "baseUrl": "http://gateway:8000",
        "apiKey": "local-docker-token",
        "api": "anthropic-messages",
        "models": [
          {
            "id": "openai.gpt-oss-20b",
            "name": "GPT 5.2 (OCI)",
            "contextWindow": 200000,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "oci-gateway/openai.gpt-oss-20b"
      }
    },
    "list": [
      { "id": "main", "name": "main" }
    ]
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "change-me-in-production"
    }
  },
  "logging": {
    "level": "info"
  }
}
```
