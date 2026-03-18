# Local Docker（本地 Docker Desktop 部署）

本目录用于在本地 Docker Desktop 环境中部署 OpenClaw + OCI Anthropic Gateway。

## 架构（ASCII）

```text
┌─────────────────────────────────────────────────────────────────┐
│                    Docker Desktop (本地)                         │
│                                                                 │
│  ┌─────────────────┐         ┌─────────────────────────────┐   │
│  │    OpenClaw     │  HTTP   │   OCI Anthropic Gateway     │   │
│  │   Port: 18789   │ ──────► │   Port: 8000                │   │
│  │                 │         │                             │   │
│  │  baseUrl:       │         │   服务名: gateway           │   │
│  │  http://gateway │         │   (或容器名: oci-anthropic-  │   │
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

说明：更详细步骤请参考 `local-docker/README.md` 及目录内示例配置。
