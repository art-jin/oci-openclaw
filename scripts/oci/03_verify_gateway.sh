#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-scripts/oci/gateway.env.example}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] env file not found: $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

K8S_GATEWAY_NAMESPACE="${K8S_GATEWAY_NAMESPACE:-${K8S_NAMESPACE:-gateway-prod}}"
K8S_OPENCLAW_NAMESPACE="${K8S_OPENCLAW_NAMESPACE:-openclaw-prod}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"
SERVICE_NAME="${SERVICE_NAME:-oci-anthropic-gateway}"

echo "[INFO] Gateway resources"
kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$K8S_GATEWAY_NAMESPACE" get pods,svc

echo "[INFO] Verify /debug/api/sessions without token should be 401 or 403"
kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$K8S_GATEWAY_NAMESPACE" run gateway-curl-check \
  --image=curlimages/curl:8.7.1 \
  --restart=Never \
  --rm -i \
  --command -- sh -c "
    code=\$(curl -s -o /dev/null -w '%{http_code}' http://${SERVICE_NAME}:8000/debug/api/sessions);
    echo unauthorized_http_code=\$code;
    test \"\$code\" = \"401\" -o \"\$code\" = \"403\";
  "

echo "[INFO] Verify /healthz"
kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$K8S_GATEWAY_NAMESPACE" run gateway-healthz-check \
  --image=curlimages/curl:8.7.1 \
  --restart=Never \
  --rm -i \
  --command -- sh -c "curl -sS http://${SERVICE_NAME}:8000/healthz"

echo "[INFO] Verify Openclaw namespace can reach gateway service"
kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$K8S_OPENCLAW_NAMESPACE" run openclaw-to-gateway-check \
  --image=curlimages/curl:8.7.1 \
  --restart=Never \
  --rm -i \
  --command -- sh -c "curl -sS http://${SERVICE_NAME}.${K8S_GATEWAY_NAMESPACE}.svc.cluster.local:8000/healthz"
