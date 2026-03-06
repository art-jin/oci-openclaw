#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="scripts/oci/gateway.env.example"
APPLY=0
DEPLOY_OPENCLAW=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_FILE="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --deploy-openclaw)
      DEPLOY_OPENCLAW=1
      shift
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      echo "Usage: $0 [--env path/to/gateway.env] [--apply] [--deploy-openclaw]" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] env file not found: $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

: "${OCI_REGION:?OCI_REGION is required}"
: "${OCI_CLUSTER_OCID:?OCI_CLUSTER_OCID is required}"
: "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID is required}"
: "${DEBUG_UI_AUTH_TOKEN:?DEBUG_UI_AUTH_TOKEN is required}"
: "${GATEWAY_CONFIG_JSON_FILE:?GATEWAY_CONFIG_JSON_FILE is required}"
: "${OCI_CONFIG_FILE:?OCI_CONFIG_FILE is required}"
: "${OCI_KEY_FILE:?OCI_KEY_FILE is required}"

K8S_NAMESPACE="${K8S_GATEWAY_NAMESPACE:-${K8S_NAMESPACE:-gateway-prod}}"
OPENCLAW_NAMESPACE="${K8S_OPENCLAW_NAMESPACE:-openclaw-prod}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"

GATEWAY_IMAGE_MODE="${GATEWAY_IMAGE_MODE:-prebuilt}"
CREATE_OCIR_PULL_SECRET="${CREATE_OCIR_PULL_SECRET:-1}"

NAMESPACE_MANIFEST="${NAMESPACE_MANIFEST:-k8s/00-namespace.yaml}"
DEPLOYMENT_MANIFEST="${DEPLOYMENT_MANIFEST:-k8s/04-deployment.yaml}"
SERVICE_MANIFEST="${SERVICE_MANIFEST:-k8s/05-service-internal-lb.yaml}"
NETWORK_POLICY_EGRESS_MANIFEST="${NETWORK_POLICY_EGRESS_MANIFEST:-k8s/06-networkpolicy-egress-template.yaml}"
NETWORK_POLICY_INGRESS_MANIFEST="${NETWORK_POLICY_INGRESS_MANIFEST:-}"

OPENCLAW_MANIFEST_DIR="${OPENCLAW_MANIFEST_DIR:-}"
OPENCLAW_DEPLOYMENT_NAME="${OPENCLAW_DEPLOYMENT_NAME:-openclaw}"
OPENCLAW_GATEWAY_BASE_URL="${OPENCLAW_GATEWAY_BASE_URL:-http://oci-anthropic-gateway.${K8S_NAMESPACE}.svc.cluster.local:8000}"
OPENCLAW_ENV_BASE_URL_KEY="${OPENCLAW_ENV_BASE_URL_KEY:-ANTHROPIC_BASE_URL}"
OPENCLAW_ENV_API_KEY_KEY="${OPENCLAW_ENV_API_KEY_KEY:-ANTHROPIC_API_KEY}"
OPENCLAW_GATEWAY_API_KEY="${OPENCLAW_GATEWAY_API_KEY:-}"
OPENCLAW_PUBLIC_EXPOSE="${OPENCLAW_PUBLIC_EXPOSE:-1}"
OPENCLAW_PUBLIC_SERVICE_NAME="${OPENCLAW_PUBLIC_SERVICE_NAME:-openclaw-public}"
OPENCLAW_PUBLIC_SERVICE_PORT="${OPENCLAW_PUBLIC_SERVICE_PORT:-80}"
OPENCLAW_PUBLIC_TARGET_PORT="${OPENCLAW_PUBLIC_TARGET_PORT:-3000}"

run_cmd() {
  local cmd="$1"
  echo "+ $cmd"
  if [[ "$APPLY" -eq 1 ]]; then
    bash -lc "$cmd"
  fi
}

ensure_file_exists() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "[ERROR] file not found: $f" >&2
    exit 1
  fi
}

ensure_dir_exists() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    echo "[ERROR] directory not found: $d" >&2
    exit 1
  fi
}

validate_gateway_config_json() {
  local cfg="$1"

  python3 - "$cfg" <<'PYCFG'
import json
import sys
from pathlib import Path

cfg_path = Path(sys.argv[1])
try:
    data = json.loads(cfg_path.read_text())
except Exception as e:
    print(f"[ERROR] invalid JSON in {cfg_path}: {e}", file=sys.stderr)
    sys.exit(1)

model_defs = data.get("model_definitions")
if not isinstance(model_defs, dict) or not model_defs:
    print("[ERROR] config.json missing non-empty model_definitions", file=sys.stderr)
    sys.exit(1)

bad = []
for name, conf in model_defs.items():
    if not isinstance(conf, dict):
        bad.append((name, "<invalid-object>"))
        continue
    ocid = str(conf.get("ocid", "")).strip()
    if not ocid or "your-model-ocid" in ocid or ocid.endswith("...") or not ocid.startswith("ocid1.generativeaimodel"):
        bad.append((name, ocid or "<empty>"))

if bad:
    print("[ERROR] config.json model_definitions contains invalid ocid values:", file=sys.stderr)
    for name, ocid in bad:
        print(f"  - {name}: {ocid}", file=sys.stderr)
    print("[ERROR] Fill each model_definitions.<model>.ocid with real OCI Generative AI model OCID before deploy.", file=sys.stderr)
    sys.exit(1)

print(f"[INFO] config.json model_definitions validated: {len(model_defs)} model(s)")
PYCFG
}

ensure_ocir_namespace() {
  if [[ -n "${OCIR_NAMESPACE:-}" ]]; then
    return
  fi
  if [[ "$APPLY" -eq 1 ]]; then
    OCIR_NAMESPACE="$(oci os ns get --region "$OCI_REGION" --profile "${OCI_CLI_PROFILE:-DEFAULT}" --query 'data' --raw-output)"
  else
    OCIR_NAMESPACE="replace-namespace"
  fi
}

build_and_push_image_if_needed() {
  if [[ "$GATEWAY_IMAGE_MODE" == "prebuilt" ]]; then
    : "${GATEWAY_IMAGE:?GATEWAY_IMAGE is required when GATEWAY_IMAGE_MODE=prebuilt}"
    IMAGE_FULL="$GATEWAY_IMAGE"
    return
  fi

  if [[ "$GATEWAY_IMAGE_MODE" != "build" ]]; then
    echo "[ERROR] GATEWAY_IMAGE_MODE must be prebuilt or build" >&2
    exit 1
  fi

  : "${OCIR_REGION_KEY:?OCIR_REGION_KEY is required when GATEWAY_IMAGE_MODE=build}"
  : "${OCI_USERNAME:?OCI_USERNAME is required when GATEWAY_IMAGE_MODE=build}"
  : "${OCI_AUTH_TOKEN:?OCI_AUTH_TOKEN is required when GATEWAY_IMAGE_MODE=build}"
  : "${GATEWAY_REPO_DIR:?GATEWAY_REPO_DIR is required when GATEWAY_IMAGE_MODE=build}"

  OCIR_REPO="${OCIR_REPO:-oci-gateway}"
  IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d%H%M%S)}"

  ensure_file_exists "$GATEWAY_REPO_DIR/Dockerfile"
  ensure_ocir_namespace
  IMAGE_FULL="${OCIR_REGION_KEY}.ocir.io/${OCIR_NAMESPACE}/${OCIR_REPO}:${IMAGE_TAG}"

  if [[ "$APPLY" -eq 1 ]]; then
    if ! oci artifacts container repository get \
      --repository-name "${OCIR_NAMESPACE}/${OCIR_REPO}" \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --region "$OCI_REGION" \
      --profile "${OCI_CLI_PROFILE:-DEFAULT}" >/dev/null 2>&1; then
      run_cmd "oci artifacts container repository create \\
        --compartment-id \"$OCI_COMPARTMENT_OCID\" \\
        --display-name \"${OCIR_NAMESPACE}/${OCIR_REPO}\" \\
        --is-immutable false \\
        --region \"$OCI_REGION\" \\
        --profile \"${OCI_CLI_PROFILE:-DEFAULT}\""
    else
      echo "[INFO] OCIR repository exists: ${OCIR_NAMESPACE}/${OCIR_REPO}"
    fi
  else
    echo "+ oci artifacts container repository get --repository-name \"${OCIR_NAMESPACE}/${OCIR_REPO}\" ..."
    echo "+ (if not exists) oci artifacts container repository create --display-name \"${OCIR_NAMESPACE}/${OCIR_REPO}\" ..."
  fi

  run_cmd "docker login ${OCIR_REGION_KEY}.ocir.io -u \"${OCIR_NAMESPACE}/${OCI_USERNAME}\" -p \"$OCI_AUTH_TOKEN\""
  run_cmd "docker build -t \"$IMAGE_FULL\" -f \"$GATEWAY_REPO_DIR/Dockerfile\" \"$GATEWAY_REPO_DIR\""
  run_cmd "docker push \"$IMAGE_FULL\""
}

render_manifest() {
  local src="$1"
  local out="$2"

  sed \
    -e "s#namespace: gateway-prod#namespace: ${K8S_NAMESPACE}#g" \
    -e "s#namespace: openclaw-prod#namespace: ${OPENCLAW_NAMESPACE}#g" \
    -e "s#iad.ocir.io/replace-namespace/oci-gateway:replace-tag#${IMAGE_FULL//\//\\/}#g" \
    "$src" > "$out"
}

deploy_openclaw_if_requested() {
  if [[ "$DEPLOY_OPENCLAW" -ne 1 ]]; then
    return
  fi

  : "${OPENCLAW_MANIFEST_DIR:?OPENCLAW_MANIFEST_DIR is required when --deploy-openclaw is set}"
  ensure_dir_exists "$OPENCLAW_MANIFEST_DIR"

  echo "[INFO] Deploying Openclaw manifests from: $OPENCLAW_MANIFEST_DIR"

  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" create namespace \"$OPENCLAW_NAMESPACE\" --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$OPENCLAW_NAMESPACE\" apply -f \"$OPENCLAW_MANIFEST_DIR\""

  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$OPENCLAW_NAMESPACE\" set env deployment/\"$OPENCLAW_DEPLOYMENT_NAME\" \"$OPENCLAW_ENV_BASE_URL_KEY\"=\"$OPENCLAW_GATEWAY_BASE_URL\""

  if [[ -n "$OPENCLAW_GATEWAY_API_KEY" ]]; then
    run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$OPENCLAW_NAMESPACE\" set env deployment/\"$OPENCLAW_DEPLOYMENT_NAME\" \"$OPENCLAW_ENV_API_KEY_KEY\"=\"$OPENCLAW_GATEWAY_API_KEY\""
  fi

  if [[ "$OPENCLAW_PUBLIC_EXPOSE" == "1" ]]; then
    run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$OPENCLAW_NAMESPACE\" expose deployment \"$OPENCLAW_DEPLOYMENT_NAME\" \
      --name \"$OPENCLAW_PUBLIC_SERVICE_NAME\" \
      --type LoadBalancer \
      --port \"$OPENCLAW_PUBLIC_SERVICE_PORT\" \
      --target-port \"$OPENCLAW_PUBLIC_TARGET_PORT\" \
      --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"

    run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$OPENCLAW_NAMESPACE\" get svc \"$OPENCLAW_PUBLIC_SERVICE_NAME\" -o wide"
  fi

  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$OPENCLAW_NAMESPACE\" rollout status deployment/\"$OPENCLAW_DEPLOYMENT_NAME\" --timeout=300s"
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$OPENCLAW_NAMESPACE\" get pods,svc -o wide"
}

echo "[INFO] Purpose: deploy gateway to OKE namespace ${K8S_NAMESPACE} from deployment repository."

ensure_file_exists "$GATEWAY_CONFIG_JSON_FILE"
validate_gateway_config_json "$GATEWAY_CONFIG_JSON_FILE"
ensure_file_exists "$OCI_CONFIG_FILE"
ensure_file_exists "$OCI_KEY_FILE"
ensure_file_exists "$NAMESPACE_MANIFEST"
ensure_file_exists "$DEPLOYMENT_MANIFEST"
ensure_file_exists "$SERVICE_MANIFEST"
ensure_file_exists "$NETWORK_POLICY_EGRESS_MANIFEST"
if [[ -n "$NETWORK_POLICY_INGRESS_MANIFEST" ]]; then
  ensure_file_exists "$NETWORK_POLICY_INGRESS_MANIFEST"
fi

build_and_push_image_if_needed

echo "[INFO] Using image: $IMAGE_FULL"

run_cmd "oci ce cluster create-kubeconfig \
  --cluster-id \"$OCI_CLUSTER_OCID\" \
  --file \"$KUBECONFIG_PATH\" \
  --region \"$OCI_REGION\" \
  --token-version 2.0.0 \
  --kube-endpoint "${OKE_KUBE_ENDPOINT:-PRIVATE_ENDPOINT}" \
  --profile \"${OCI_CLI_PROFILE:-DEFAULT}\" \
  --overwrite"

run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$NAMESPACE_MANIFEST\""

if [[ "$CREATE_OCIR_PULL_SECRET" == "1" ]]; then
  : "${OCIR_REGION_KEY:?OCIR_REGION_KEY is required when CREATE_OCIR_PULL_SECRET=1}"
  : "${OCI_USERNAME:?OCI_USERNAME is required when CREATE_OCIR_PULL_SECRET=1}"
  : "${OCI_AUTH_TOKEN:?OCI_AUTH_TOKEN is required when CREATE_OCIR_PULL_SECRET=1}"
  ensure_ocir_namespace
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_NAMESPACE\" create secret docker-registry ocir-cred \
    --docker-server=\"${OCIR_REGION_KEY}.ocir.io\" \
    --docker-username=\"${OCIR_NAMESPACE}/${OCI_USERNAME}\" \
    --docker-password=\"$OCI_AUTH_TOKEN\" \
    --docker-email=\"ops@example.com\" \
    --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"
fi

run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_NAMESPACE\" create configmap gateway-config \
  --from-file=config.json=\"$GATEWAY_CONFIG_JSON_FILE\" \
  --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"

run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_NAMESPACE\" create secret generic gateway-debug-auth \
  --from-literal=DEBUG_UI_AUTH_TOKEN=\"$DEBUG_UI_AUTH_TOKEN\" \
  --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"

run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_NAMESPACE\" create secret generic gateway-oci-sdk \
  --from-file=config=\"$OCI_CONFIG_FILE\" \
  --from-file=oci_api_key.pem=\"$OCI_KEY_FILE\" \
  --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DEPLOY_OUT="$TMP_DIR/04-deployment.rendered.yaml"
SERVICE_OUT="$TMP_DIR/05-service.rendered.yaml"
NP_EGRESS_OUT="$TMP_DIR/06-networkpolicy-egress.rendered.yaml"

render_manifest "$DEPLOYMENT_MANIFEST" "$DEPLOY_OUT"
render_manifest "$SERVICE_MANIFEST" "$SERVICE_OUT"
render_manifest "$NETWORK_POLICY_EGRESS_MANIFEST" "$NP_EGRESS_OUT"
if [[ -n "$NETWORK_POLICY_INGRESS_MANIFEST" ]]; then
  NP_INGRESS_OUT="$TMP_DIR/07-networkpolicy-ingress.rendered.yaml"
  render_manifest "$NETWORK_POLICY_INGRESS_MANIFEST" "$NP_INGRESS_OUT"
fi

run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$DEPLOY_OUT\""
run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$SERVICE_OUT\""
run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$NP_EGRESS_OUT\""
if [[ -n "$NETWORK_POLICY_INGRESS_MANIFEST" ]]; then
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$NP_INGRESS_OUT\""
fi
run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_NAMESPACE\" rollout status deploy/oci-anthropic-gateway --timeout=300s"
run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_NAMESPACE\" get pods,svc -o wide"

deploy_openclaw_if_requested

if [[ "$APPLY" -eq 0 ]]; then
  echo "[INFO] Dry run only. Add --apply to execute commands."
else
  echo "[INFO] Deployment completed."
fi
