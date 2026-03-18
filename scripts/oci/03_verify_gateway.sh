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
K8S_OC_APP_NAMESPACE="${K8S_OC_APP_NAMESPACE:-oc-app-prod}"
K8S_OPENCLAW_NAMESPACE="${K8S_OPENCLAW_NAMESPACE:-openclaw-prod}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"
SERVICE_NAME="${SERVICE_NAME:-oci-anthropic-gateway}"
VERIFY_MODEL_ID="${VERIFY_MODEL_ID:-openai.gpt-oss-20b}"

echo "[INFO] Gateway resources"
kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$K8S_GATEWAY_NAMESPACE" get pods,svc

echo "[INFO] Verify gateway locally via port-forward (cluster admission blocks non-OCIR images)"

echo "[INFO] Starting port-forward to service/${SERVICE_NAME} (127.0.0.1:8000)"
kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$K8S_GATEWAY_NAMESPACE" port-forward "svc/${SERVICE_NAME}" 18000:8000 >/tmp/gateway-portforward.log 2>&1 &
PF_PID=$!
cleanup_pf() {
  kill "$PF_PID" >/dev/null 2>&1 || true
}
trap cleanup_pf EXIT
sleep 2

echo "[INFO] Verify /debug/api/sessions without token"
# Accept:
# - 401/403 when debug is enabled and bearer auth is enforced
# - 404 when debug is disabled
resp_file="/tmp/gateway-debug-sessions.json"
code=$(curl -sS -o "$resp_file" -w '%{http_code}' http://127.0.0.1:18000/debug/api/sessions || true)
echo "debug_http_code=$code"
if [[ "$code" == "404" ]]; then
  if grep -q "Debug UI is disabled" "$resp_file"; then
    echo "[INFO] Debug UI disabled (expected)"
  else
    echo "[ERROR] /debug returned 404 but unexpected body:" >&2
    head -c 400 "$resp_file" >&2; echo >&2
    exit 1
  fi
elif [[ "$code" == "401" || "$code" == "403" ]]; then
  echo "[INFO] Debug UI enabled and protected (expected)"
else
  echo "[ERROR] Unexpected /debug status: $code" >&2
  head -c 400 "$resp_file" >&2; echo >&2
  exit 1
fi

echo "[INFO] Verify /healthz"
curl -sS http://127.0.0.1:18000/healthz

echo "[INFO] Verify gateway /v1/messages (local, through port-forward)"
curl -sS -X POST http://127.0.0.1:18000/v1/messages \
  -H 'Content-Type: application/json' \
  -H 'x-api-key: verify' \
  -d '{"model":"'"${VERIFY_MODEL_ID}"'","max_tokens":8,"messages":[{"role":"user","content":"ping"}]}' | head -c 400

echo

echo "[INFO] OpenClaw resources"
kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$K8S_OPENCLAW_NAMESPACE" get pods,svc -o wide

echo "[INFO] Verify OpenClaw /healthz and /readyz via port-forward"
# Avoid creating ephemeral pods (cluster policies may block non-OCIR images or default SAs).
PORT_FWD_OPENCLAW_LOG=/tmp/openclaw-portforward.log
kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$K8S_OPENCLAW_NAMESPACE" port-forward svc/openclaw 18789:18789 >"$PORT_FWD_OPENCLAW_LOG" 2>&1 &
PF2_PID=$!
cleanup_pf2() { kill "$PF2_PID" >/dev/null 2>&1 || true; }
trap cleanup_pf2 EXIT
sleep 2
curl -sS http://127.0.0.1:18789/healthz
echo
curl -sS http://127.0.0.1:18789/readyz
echo
