# OKE 部署 openclaw workload Identity

# 0 基础环境

OKE v1.33.1

OpenClaw v3.8

# 1 Workload Identity signer OKE 配置

```yaml
### 1 创建 namespace oci-genai
### 2 创建 ServiceAccount genai-sa

### ns-sa.yaml

apiVersion: v1
kind: Namespace
metadata:
  name: oci-genai
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: genai-sa
  namespace: oci-genai
automountServiceAccountToken: true
```

# 1 Workload Identity配置

**OKE Pod** 里直接调用 **OCI Generative AI**

```bash
# 在 OCI 中配置 Polices

Identity & Security --> Identity --> Policies

# 创建 Polices 

Police name: oke-cluster-sa
Policy Statements

####  需要配置的信息
#### compartment id
#### request.principal.namespace  容器所在Namespace, 示例中： oci-genai
#### request.principal.service_account  使用的 SA，  示例中， genai-sa
#### Cluster OKE OCID request.principal.cluster_id 

##### 模型的查看权限
Allow any-user to inspect generative-ai-model in compartment id compartmentOCID where all {request.principal.type='workload',request.principal.namespace='oci-genai namespace',request.principal.service_account='genai-sa Service Account',request.principal.cluster_id='OKE Cluster OCID'}

##### GenAI Chat 的交互权限
Allow any-user to use generative-ai-chat in compartment id compartmentOCID where all {request.principal.type='workload',request.principal.namespace='oci-genai namespace',request.principal.service_account='genai-sa Service Account',request.principal.cluster_id='OKE Cluster OCID'}
```

# 2 构建 oci-anthropic-gateway  镜像

## 2.1 构建Docker file

```yaml
### DockerFile 
# OCI Anthropic Gateway Docker Image
# Python 3.12 slim image for minimal footprint
#
# If Docker Hub is slow, try using a mirror:
#   docker build --build-arg PYTHON_IMAGE=python:3.12-slim .

ARG PYTHON_IMAGE=python:3.12-slim
FROM ${PYTHON_IMAGE}

LABEL maintainer="OCI Anthropic Gateway"
LABEL description="Translation layer for OCI GenAI models with Anthropic API compatibility"

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Set working directory
WORKDIR /app

# Install system dependencies (if needed for OCI SDK)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better caching
COPY requirements.txt .

# Install Python dependencies using Tsinghua mirror (faster in China)
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY main.py .
COPY src/ ./src/
COPY web/ ./web/

# Copy entrypoint script
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# Create directory for debug dumps (if enabled)
RUN mkdir -p /app/debug_dumps

# Expose default port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/debug/ || exit 1

# Run the application
ENTRYPOINT ["./entrypoint.sh"]
```

## 2.2 打包并上传至镜像仓库

```yaml
### 打包
docker build -t <your-registry>/oci-anthropic-gateway:v1.0.0 .

### 推送
docker push <your-registry>/oci-anthropic-gateway:v1.0.0
```

## 2.3 OKE 配置容器仓库认证

```bash
## 通过 kubectl 配置认证 secret
kubectl create secret docker-registry ocir-regcred --docker-server=eu-frankfurt-1.ocir.io --docker-username='namespace/username' --docker-password='token password' --docker-email='coxxx@xx.com.cn' -n oci-genai
```

# 3 部署 oci-anthropic-gateway

```yaml
## vim genai-gateway.yaml
#### 其中 configmap 调用的 json, 请填写自己的 compartment_id": "compartmentOCID",
apiVersion: v1
kind: Namespace
metadata:
  name: oci-genai
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: genai-sa
  namespace: oci-genai
automountServiceAccountToken: true
imagePullSecrets:
  - name: ocir-regcred
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: oci-anthropic-gateway-config
  namespace: oci-genai
data:
  config.json: |
    {
      "compartment_id": "compartmentOCID",
      "endpoint": "https://inference.generativeai.eu-frankfurt-1.oci.oraclecloud.com",
      "model_aliases": {
        "gpt-oss-20b": "openai.gpt-oss-20b"
      },
      "model_definitions": {
        "openai.gpt-oss-20b": {
          "ocid": "ocid1.generativeaimodel.oc1.eu-frankfurt-1.amaaaaaask7dceyaafixcmjazfuvcupl2i6wkpu4ocm7673uokskvftn4mna",
          "model_types": ["text"],
          "max_tokens_key": "max_completion_tokens",
          "temperature": 0.7
        }
      },
      "default_model": "openai.gpt-oss-20b",
      "debug": false,
      "debug_redact_media": true,
      "enable_nl_tool_fallback": false,
      "messages_max_items": 200,
      "rate_limit": {
        "enabled": false,
        "requests": 60,
        "window_sec": 60
      },
      "debug_ui": {
        "enabled": false
      },
      "server": {
        "host": "0.0.0.0",
        "port": 8000,
        "log_level": "warning"
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oci-anthropic-gateway
  namespace: oci-genai
spec:
  replicas: 1
  selector:
    matchLabels:
      app: oci-anthropic-gateway
  template:
    metadata:
      labels:
        app: oci-anthropic-gateway
    spec:
      serviceAccountName: genai-sa
      automountServiceAccountToken: true
      containers:
        - name: gateway
          image: eu-frankfurt-1.ocir.io/sehubjapacprod/oci-anthropic-gateway-genai:v1.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8000
              protocol: TCP
          env:
            - name: GATEWAY_CONFIG_PATH
              value: /app/config.json
            - name: OCI_RESOURCE_PRINCIPAL_VERSION
              value: "2.2"
            - name: OCI_RESOURCE_PRINCIPAL_REGION
              value: "eu-frankfurt-1"
          volumeMounts:
            - name: gateway-config
              mountPath: /app/config.json
              subPath: config.json
              readOnly: true
          readinessProbe:
            tcpSocket:
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 6
          livenessProbe:
            tcpSocket:
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 20
            timeoutSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
      volumes:
        - name: gateway-config
          configMap:
            name: oci-anthropic-gateway-config
---
apiVersion: v1
kind: Service
metadata:
  name: oci-anthropic-gateway
  namespace: oci-genai
spec:
  type: ClusterIP
  selector:
    app: oci-anthropic-gateway
  ports:
    - name: http
      port: 8000
      targetPort: 8000
      protocol: TCP

```

# 4 部署 Open Claw

```bash
## vim openclaw-gateway.yaml

apiVersion: v1
kind: Namespace
metadata:
  name: oci-genai

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: genai-sa
  namespace: oci-genai
automountServiceAccountToken: true

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: openclaw-config-template
  namespace: oci-genai
data:
  base-openclaw.json: |
    {
      "agents": {
        "defaults": {
          "compaction": {
            "mode": "safeguard"
          },
          "model": {
            "primary": "oci-gateway/command-a"
          }
        },
        "list": [
          {
            "id": "main",
            "name": "main"
          }
        ]
      },
      "commands": {
        "native": "auto",
        "nativeSkills": "auto",
        "restart": true,
        "ownerDisplay": "raw"
      },
      "gateway": {
        "port": 18789,
        "mode": "local",
        "bind": "lan",
        "controlUi": {
          "allowedOrigins": [
            "http://localhost:18789",
            "http://127.0.0.1:18789"
          ],
          "dangerouslyAllowHostHeaderOriginFallback": true
        },
        "tailscale": {
          "mode": "off",
          "resetOnExit": false
        }
      },
      "models": {
        "mode": "merge",
        "providers": {
          "oci-gateway": {
            "baseUrl": "http://oci-anthropic-gateway:8000",
            "apiKey": "__OCI_GATEWAY_API_KEY__",
            "api": "anthropic-messages",
            "models": [
              {
                "id": "command-a",
                "name": "Command A (OCI)",
                "contextWindow": 200000,
                "maxTokens": 8192
              }
            ]
          }
        }
      },
      "logging": {
        "level": "debug"
      }
    }

---
apiVersion: v1
kind: Secret
metadata:
  name: openclaw-provider-secrets
  namespace: oci-genai
type: Opaque
stringData:
  OCI_GATEWAY_API_KEY: "local-docker-token"

---
apiVersion: v1
kind: Service
metadata:
  name: openclaw-headless
  namespace: oci-genai
spec:
  clusterIP: None
  selector:
    app: openclaw
  ports:
    - name: gateway
      port: 18789
      targetPort: gateway
    - name: bridge
      port: 18790
      targetPort: bridge

---
apiVersion: v1
kind: Service
metadata:
  name: openclaw
  namespace: oci-genai
spec:
  type: ClusterIP
  selector:
    app: openclaw
  ports:
    - name: gateway
      port: 18789
      targetPort: gateway
    - name: bridge
      port: 18790
      targetPort: bridge

---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: openclaw
  namespace: oci-genai
spec:
  serviceName: openclaw-headless
  replicas: 1
  selector:
    matchLabels:
      app: openclaw
  template:
    metadata:
      labels:
        app: openclaw
    spec:
      serviceAccountName: genai-sa
      automountServiceAccountToken: true
      enableServiceLinks: false
      terminationGracePeriodSeconds: 30
      securityContext:
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch

      initContainers:
        - name: init-openclaw-config
          image: python:3.12-alpine
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - -lc
            - |
              set -eu

              STATE_DIR=/home/node/.openclaw
              WORKSPACE_DIR="${STATE_DIR}/workspace"
              TOKEN_FILE="${STATE_DIR}/gateway-token"
              CONFIG_FILE="${STATE_DIR}/openclaw.json"
              TEMPLATE_FILE=/config/base-openclaw.json
              APIKEY_FILE=/secrets/OCI_GATEWAY_API_KEY

              mkdir -p "${WORKSPACE_DIR}"
              umask 077

              if [ -s "${TOKEN_FILE}" ]; then
                TOKEN="$(cat "${TOKEN_FILE}")"
              else
                TOKEN="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)"
                printf '%s' "${TOKEN}" > "${TOKEN_FILE}"
              fi

              export TOKEN TEMPLATE_FILE APIKEY_FILE CONFIG_FILE

              python3 <<'PY'
              import json
              import os
              from pathlib import Path

              template_file = Path(os.environ["TEMPLATE_FILE"])
              apikey_file = Path(os.environ["APIKEY_FILE"])
              config_file = Path(os.environ["CONFIG_FILE"])
              token = os.environ["TOKEN"]

              data = json.loads(template_file.read_text())

              api_key = apikey_file.read_text().strip()

              data.setdefault("gateway", {})
              data["gateway"]["auth"] = {
                  "mode": "token",
                  "token": token
              }

              # 这里保留 remote.token，方便你后面如果有 remote / pairing / 相关场景继续沿用同一 token
              data["gateway"]["remote"] = {
                  "token": token
              }

              data.setdefault("models", {}).setdefault("providers", {}).setdefault("oci-gateway", {})
              data["models"]["providers"]["oci-gateway"]["apiKey"] = api_key

              config_file.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
              PY

              chown -R 1000:1000 "${STATE_DIR}"
              chmod 700 "${STATE_DIR}"
              [ -f "${TOKEN_FILE}" ] && chmod 600 "${TOKEN_FILE}"
              [ -f "${CONFIG_FILE}" ] && chmod 600 "${CONFIG_FILE}"
          securityContext:
            runAsUser: 0
          volumeMounts:
            - name: openclaw-data
              mountPath: /home/node/.openclaw
            - name: openclaw-config-template
              mountPath: /config
              readOnly: true
            - name: openclaw-provider-secrets
              mountPath: /secrets
              readOnly: true

      containers:
        - name: gateway
          image: ghcr.io/openclaw/openclaw:2026.3.8
          imagePullPolicy: IfNotPresent
          command:
            - node
            - dist/index.js
            - gateway
            - --bind
            - lan
            - --port
            - "18789"
          env:
            - name: HOME
              value: /home/node
          ports:
            - name: gateway
              containerPort: 18789
            - name: bridge
              containerPort: 18790
          startupProbe:
            httpGet:
              path: /healthz
              port: gateway
            periodSeconds: 5
            timeoutSeconds: 5
            failureThreshold: 24
          livenessProbe:
            httpGet:
              path: /healthz
              port: gateway
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 5
          readinessProbe:
            httpGet:
              path: /readyz
              port: gateway
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 5
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: "2"
              memory: 4Gi
          volumeMounts:
            - name: openclaw-data
              mountPath: /home/node/.openclaw

        - name: cli
          image: ghcr.io/openclaw/openclaw:2026.3.8
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - -lc
            - sleep infinity
          stdin: true
          tty: true
          env:
            - name: HOME
              value: /home/node
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 1Gi
          volumeMounts:
            - name: openclaw-data
              mountPath: /home/node/.openclaw

      volumes:
        - name: openclaw-config-template
          configMap:
            name: openclaw-config-template
        - name: openclaw-provider-secrets
          secret:
            secretName: openclaw-provider-secrets

  volumeClaimTemplates:
    - metadata:
        name: openclaw-data
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: oci-bv
        resources:
          requests:
            storage: 50Gi

```

# 5 添加token到OpenClaw UI

## 5.1 从 openclaw 容器中获取 Token

```bash
### 从 openclaw 容器中获取 Token
kubectl -n oci-genai exec -it openclaw-0 -c cli -- cat /home/node/.openclaw/gateway-token
```

## 5.2 openclaw 打开端口转发

```bash
### 打开端口转发功能
kubectl -n oci-genai port-forward svc/openclaw 18789:18789
```

## 5.3 将键入到 OpenClaw UI

添加网关令牌

![image.png](image.png)

![image.png](image%201.png)

## 5.4 聊天窗口测试

![image.png](image%202.png)
