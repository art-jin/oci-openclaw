#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="scripts/oci/gateway.env.example"
APPLY=0
DEPLOY_OC_APP=0
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
    --deploy-oc-app)
      DEPLOY_OC_APP=1
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
OCI_ARTIFACTS_COMPARTMENT_OCID="${OCI_ARTIFACTS_COMPARTMENT_OCID:-$OCI_COMPARTMENT_OCID}"
: "${DEBUG_UI_AUTH_TOKEN:?DEBUG_UI_AUTH_TOKEN is required}"
: "${GATEWAY_CONFIG_JSON_FILE:?GATEWAY_CONFIG_JSON_FILE is required}"

AUTH_MODE="${AUTH_MODE:-workload_identity}"
if [[ "$AUTH_MODE" != "workload_identity" && "$AUTH_MODE" != "oci_config_secret" ]]; then
  echo "[ERROR] AUTH_MODE must be workload_identity or oci_config_secret" >&2
  exit 1
fi

K8S_GATEWAY_NAMESPACE="${K8S_GATEWAY_NAMESPACE:-${K8S_NAMESPACE:-gateway-prod}}"
K8S_OC_APP_NAMESPACE="${K8S_OC_APP_NAMESPACE:-oc-app-prod}"
K8S_OPENCLAW_NAMESPACE="${K8S_OPENCLAW_NAMESPACE:-openclaw-prod}"
AUTH_MODE="${AUTH_MODE:-workload_identity}"
OCI_RESOURCE_PRINCIPAL_REGION="${OCI_RESOURCE_PRINCIPAL_REGION:-${OCI_REGION}}"

OPENCLAW_MANIFEST_DIR="${OPENCLAW_MANIFEST_DIR:-k8s/openclaw}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-}"
OPENCLAW_GATEWAY_BASE_URL="${OPENCLAW_GATEWAY_BASE_URL:-http://oci-anthropic-gateway.${K8S_GATEWAY_NAMESPACE}.svc.cluster.local:8000}"
OPENCLAW_GATEWAY_API_KEY="${OPENCLAW_GATEWAY_API_KEY:-any-value-works}"
OPENCLAW_OCI_CLI_AUTH_MODE="${OPENCLAW_OCI_CLI_AUTH_MODE:-oke_workload_identity}"
OPENCLAW_MOUNT_KUBECONFIG="${OPENCLAW_MOUNT_KUBECONFIG:-0}"
OPENCLAW_KUBECONFIG_FILE="${OPENCLAW_KUBECONFIG_FILE:-}"
OPENCLAW_KUBECONFIG_SECRET_NAME="${OPENCLAW_KUBECONFIG_SECRET_NAME:-openclaw-kubeconfig}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"

if [[ "$OPENCLAW_OCI_CLI_AUTH_MODE" != "oke_workload_identity" && "$OPENCLAW_OCI_CLI_AUTH_MODE" != "instance_principal" && "$OPENCLAW_OCI_CLI_AUTH_MODE" != "explicit" ]]; then
  echo "[ERROR] OPENCLAW_OCI_CLI_AUTH_MODE must be oke_workload_identity, instance_principal, or explicit" >&2
  exit 1
fi

if [[ "$OPENCLAW_MOUNT_KUBECONFIG" != "0" && "$OPENCLAW_MOUNT_KUBECONFIG" != "1" ]]; then
  echo "[ERROR] OPENCLAW_MOUNT_KUBECONFIG must be 0 or 1" >&2
  exit 1
fi

if [[ "$OPENCLAW_MOUNT_KUBECONFIG" == "1" && -z "$OPENCLAW_KUBECONFIG_FILE" ]]; then
  echo "[ERROR] OPENCLAW_KUBECONFIG_FILE is required when OPENCLAW_MOUNT_KUBECONFIG=1" >&2
  exit 1
fi

GATEWAY_IMAGE_MODE="${GATEWAY_IMAGE_MODE:-prebuilt}"
CREATE_OCIR_PULL_SECRET="${CREATE_OCIR_PULL_SECRET:-1}"

NAMESPACE_MANIFEST="${NAMESPACE_MANIFEST:-k8s/00-namespace.yaml}"
DEPLOYMENT_MANIFEST="${DEPLOYMENT_MANIFEST:-k8s/04-deployment.yaml}"
SERVICE_MANIFEST="${SERVICE_MANIFEST:-k8s/05-service-internal-lb.yaml}"
NETWORK_POLICY_EGRESS_MANIFEST="${NETWORK_POLICY_EGRESS_MANIFEST:-k8s/06-networkpolicy-egress-template.yaml}"
NETWORK_POLICY_INGRESS_MANIFEST="${NETWORK_POLICY_INGRESS_MANIFEST:-}"

OC_APP_MANIFEST_DIR="${OC_APP_MANIFEST_DIR:-k8s/oc-app}"
OC_APP_DEPLOYMENT_MANIFEST="${OC_APP_DEPLOYMENT_MANIFEST:-${OC_APP_MANIFEST_DIR}/08-deployment.yaml}"
OC_APP_SERVICE_MANIFEST="${OC_APP_SERVICE_MANIFEST:-${OC_APP_MANIFEST_DIR}/09-service-clusterip.yaml}"
OC_APP_DEPLOYMENT_NAME="${OC_APP_DEPLOYMENT_NAME:-oc-app}"
OC_APP_IMAGE="${OC_APP_IMAGE:-}"
OC_APP_CONFIG_JSON_FILE="${OC_APP_CONFIG_JSON_FILE:-scripts/oci/app-config.json.example}"
OC_APP_GATEWAY_BASE_URL="${OC_APP_GATEWAY_BASE_URL:-http://oci-anthropic-gateway.${K8S_GATEWAY_NAMESPACE}.svc.cluster.local:8000}"
OC_APP_GATEWAY_TOKEN="${OC_APP_GATEWAY_TOKEN:-}"
OC_APP_PUBLIC_EXPOSE="${OC_APP_PUBLIC_EXPOSE:-1}"
OC_APP_PUBLIC_SERVICE_NAME="${OC_APP_PUBLIC_SERVICE_NAME:-oc-app-public}"
OC_APP_PUBLIC_SERVICE_PORT="${OC_APP_PUBLIC_SERVICE_PORT:-18789}"
OC_APP_PUBLIC_TARGET_PORT="${OC_APP_PUBLIC_TARGET_PORT:-18987}"

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

validate_oc_app_config_json() {
  local cfg="$1"

  python3 - "$cfg" <<'PYOC'
import json
import sys
from pathlib import Path

cfg_path = Path(sys.argv[1])
try:
    data = json.loads(cfg_path.read_text())
except Exception as e:
    print(f"[ERROR] invalid JSON in {cfg_path}: {e}", file=sys.stderr)
    sys.exit(1)

providers = data.get("models", {}).get("providers", {})
if "oci-gateway" not in providers:
    print("[ERROR] app config must include models.providers.oci-gateway", file=sys.stderr)
    sys.exit(1)

primary = data.get("agents", {}).get("defaults", {}).get("model", {}).get("primary")
if not isinstance(primary, str) or not primary.startswith("oci-gateway/"):
    print("[ERROR] app config agents.defaults.model.primary must start with oci-gateway/", file=sys.stderr)
    sys.exit(1)

print("[INFO] app config validated")
PYOC
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

assert_image_exists() {
  local image_ref="$1"

  if ! command -v docker >/dev/null 2>&1; then
    echo "[ERROR] docker is required to verify that OPENCLAW_IMAGE exists (docker manifest inspect)." >&2
    echo "[ERROR] Either install docker, set OPENCLAW_IMAGE_MODE=build, or ensure the image exists in registry: $image_ref" >&2
    exit 1
  fi

  # This checks for manifest existence without pulling layers.
  if ! docker manifest inspect "$image_ref" >/dev/null 2>&1; then
    echo "[ERROR] OPENCLAW_IMAGE does not exist or is not accessible: $image_ref" >&2
    echo "[ERROR] Fix by either:" >&2
    echo "  - Set OPENCLAW_IMAGE_MODE=build to auto build+push" >&2
    echo "  - Or push the image and/or correct OPENCLAW_IMAGE" >&2
    echo "  - Or docker login to the registry (e.g., ${OCIR_REGION_KEY:-<regionKey>}.ocir.io)" >&2
    exit 1
  fi

  echo "[INFO] OpenClaw image exists: $image_ref"
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
    # Note: OCI CLI does not consistently support "repository get by name" across versions.
    # Use list+filter to determine existence.
    if oci artifacts container repository list \
      --compartment-id "$OCI_ARTIFACTS_COMPARTMENT_OCID" \
      --region "$OCI_REGION" \
      --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
      --all \
      --query "length(data[?\"display-name\"=='${OCIR_NAMESPACE}/${OCIR_REPO}'])" \
      --raw-output 2>/dev/null | grep -qx "0"; then
      run_cmd "oci artifacts container repository create \
        --compartment-id \"$OCI_ARTIFACTS_COMPARTMENT_OCID\" \
        --display-name \"${OCIR_REPO}\" \
        --is-immutable false \
        --region \"$OCI_REGION\" \
        --profile \"${OCI_CLI_PROFILE:-DEFAULT}\""
    else
      echo "[INFO] OCIR repository exists: ${OCIR_NAMESPACE}/${OCIR_REPO}"
    fi
  else
    echo "+ oci artifacts container repository list --compartment-id \"$OCI_ARTIFACTS_COMPARTMENT_OCID\" --all ... (filter display-name == ${OCIR_NAMESPACE}/${OCIR_REPO})"
    echo "+ (if not exists) oci artifacts container repository create --display-name \"${OCIR_REPO}\" ..."
  fi

  run_cmd "docker login ${OCIR_REGION_KEY}.ocir.io -u \"${OCIR_NAMESPACE}/${OCI_USERNAME}\" -p \"$OCI_AUTH_TOKEN\""
  run_cmd "docker build -t \"$IMAGE_FULL\" -f \"$GATEWAY_REPO_DIR/Dockerfile\" \"$GATEWAY_REPO_DIR\""
  run_cmd "docker push \"$IMAGE_FULL\""
}

render_manifest() {
  local src="$1"
  local out="$2"

  # Escape replacement strings for sed (at least '&' which otherwise expands to the matched text).
  local image_esc oc_app_image_esc rp_region_esc openclaw_image_esc openclaw_base_url_esc openclaw_api_key_esc openclaw_oci_cli_auth_mode_esc openclaw_mount_kubeconfig_esc openclaw_kubeconfig_secret_name_esc
  image_esc="${IMAGE_FULL//&/\\&}"
  oc_app_image_esc="${OC_APP_IMAGE//&/\\&}"
  rp_region_esc="${OCI_RESOURCE_PRINCIPAL_REGION//&/\\&}"
  openclaw_image_esc="${OPENCLAW_IMAGE//&/\\&}"
  openclaw_base_url_esc="${OPENCLAW_GATEWAY_BASE_URL//&/\\&}"
  openclaw_api_key_esc="${OPENCLAW_GATEWAY_API_KEY//&/\\&}"
  openclaw_oci_cli_auth_mode_esc="${OPENCLAW_OCI_CLI_AUTH_MODE//&/\\&}"
  openclaw_mount_kubeconfig_esc="${OPENCLAW_MOUNT_KUBECONFIG//&/\\&}"
  openclaw_kubeconfig_secret_name_esc="${OPENCLAW_KUBECONFIG_SECRET_NAME//&/\\&}"

  sed \
    -e "s#namespace: gateway-prod#namespace: ${K8S_GATEWAY_NAMESPACE}#g" \
    -e "s#namespace: OC_APP_NS#namespace: ${K8S_OC_APP_NAMESPACE}#g" \
    -e "s#namespace: openclaw-prod#namespace: ${K8S_OPENCLAW_NAMESPACE}#g" \
    -e "s#iad.ocir.io/replace-namespace/oci-gateway:replace-tag#${image_esc//\//\\/}#g" \
    -e "s#ghcr.io/oc-app/oc-app:replace-tag#${oc_app_image_esc//\//\\/}#g" \
    -e "s#OC_APP#oc-app#g" \
    -e "s#__OC_GATEWAY_TOKEN_ENV__#\$(OC_APP_GATEWAY_TOKEN)#g" \
    -e "s#__OCI_RESOURCE_PRINCIPAL_REGION__#${rp_region_esc//\//\\/}#g" \
    -e "s#__OPENCLAW_IMAGE__#${openclaw_image_esc//\//\\/}#g" \
    -e "s#__OPENCLAW_GATEWAY_BASE_URL__#${openclaw_base_url_esc//\//\\/}#g" \
    -e "s#__OPENCLAW_GATEWAY_API_KEY__#${openclaw_api_key_esc//\//\\/}#g" \
    -e "s#__OPENCLAW_OCI_CLI_AUTH_MODE__#${openclaw_oci_cli_auth_mode_esc//\//\\/}#g" \
    -e "s#__OPENCLAW_MOUNT_KUBECONFIG__#${openclaw_mount_kubeconfig_esc//\//\\/}#g" \
    -e "s#__OPENCLAW_KUBECONFIG_SECRET_NAME__#${openclaw_kubeconfig_secret_name_esc//\//\\/}#g" \
    -e "s#__OPENCLAW_PUBLIC_EXPOSE__#0#g" \
    "$src" > "$out"
}

render_oc_app_config() {
  local src="$1"
  local out="$2"

  sed \
    -e "s#__OC_GATEWAY_BASE_URL__#${OC_APP_GATEWAY_BASE_URL//\//\\/}#g" \
    -e "s#__OC_GATEWAY_TOKEN__#${OC_APP_GATEWAY_TOKEN//\//\\/}#g" \
    "$src" > "$out"
}

deploy_openclaw_if_requested() {
  if [[ "$DEPLOY_OPENCLAW" -ne 1 ]]; then
    return
  fi

  # If requested, build/push OpenClaw to OCIR and use the resulting image reference.
  if [[ "${OPENCLAW_IMAGE_MODE:-}" == "build" ]]; then
    echo "[INFO] OPENCLAW_IMAGE_MODE=build; building/pushing OpenClaw to OCIR"
    if [[ "$APPLY" -eq 1 ]]; then
      OPENCLAW_IMAGE="$(bash scripts/oci/02_build_push_openclaw_ocir.sh "$ENV_FILE" --apply | tail -n 1)"
    else
      OPENCLAW_IMAGE="$(bash scripts/oci/02_build_push_openclaw_ocir.sh "$ENV_FILE" | tail -n 1)"
    fi
    echo "[INFO] OpenClaw image: ${OPENCLAW_IMAGE}"
  fi

  : "${OPENCLAW_IMAGE:?OPENCLAW_IMAGE is required when --deploy-openclaw is set}"

  # Fail fast: if we're not building OpenClaw, verify the image exists before creating workloads.
  if [[ "${OPENCLAW_IMAGE_MODE:-}" != "build" && "$APPLY" -eq 1 ]]; then
    assert_image_exists "$OPENCLAW_IMAGE"
  fi

  ensure_dir_exists "$OPENCLAW_MANIFEST_DIR"

  local ns_manifest="$OPENCLAW_MANIFEST_DIR/00-namespace.yaml"
  local sa_manifest="$OPENCLAW_MANIFEST_DIR/00-serviceaccount.yaml"
  local cm_manifest="$OPENCLAW_MANIFEST_DIR/01-configmap-openclaw-config-template.yaml"
  local secret_manifest="$OPENCLAW_MANIFEST_DIR/02-secret-openclaw-provider.yaml"
  local headless_svc_manifest="$OPENCLAW_MANIFEST_DIR/03-service-headless.yaml"
  local svc_manifest="$OPENCLAW_MANIFEST_DIR/04-service-clusterip.yaml"
  local sts_manifest="$OPENCLAW_MANIFEST_DIR/05-statefulset.yaml"
  local np_egress_manifest="$OPENCLAW_MANIFEST_DIR/07-networkpolicy-egress.yaml"

  ensure_file_exists "$ns_manifest"
  ensure_file_exists "$sa_manifest"
  ensure_file_exists "$cm_manifest"
  ensure_file_exists "$secret_manifest"
  ensure_file_exists "$headless_svc_manifest"
  ensure_file_exists "$svc_manifest"
  ensure_file_exists "$sts_manifest"
  ensure_file_exists "$np_egress_manifest"

  echo "[INFO] Deploying openclaw manifests from: $OPENCLAW_MANIFEST_DIR"
  echo "[INFO] OpenClaw OCI CLI auth mode: $OPENCLAW_OCI_CLI_AUTH_MODE"
  echo "[INFO] OpenClaw kubeconfig mount: $OPENCLAW_MOUNT_KUBECONFIG"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local ns_out="$tmp_dir/00-namespace.rendered.yaml"
  local sa_out="$tmp_dir/00-serviceaccount.rendered.yaml"
  local cm_out="$tmp_dir/01-configmap.rendered.yaml"
  local secret_out="$tmp_dir/02-secret.rendered.yaml"
  local headless_svc_out="$tmp_dir/03-service-headless.rendered.yaml"
  local svc_out="$tmp_dir/04-service.rendered.yaml"
  local sts_out="$tmp_dir/05-statefulset.rendered.yaml"
  local np_egress_out="$tmp_dir/07-networkpolicy-egress.rendered.yaml"

  render_manifest "$ns_manifest" "$ns_out"
  render_manifest "$sa_manifest" "$sa_out"
  render_manifest "$cm_manifest" "$cm_out"
  render_manifest "$secret_manifest" "$secret_out"
  render_manifest "$headless_svc_manifest" "$headless_svc_out"
  render_manifest "$svc_manifest" "$svc_out"
  render_manifest "$sts_manifest" "$sts_out"
  render_manifest "$np_egress_manifest" "$np_egress_out"

  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$ns_out\""
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$sa_out\""
  if [[ "$OPENCLAW_MOUNT_KUBECONFIG" == "1" ]]; then
    ensure_file_exists "$OPENCLAW_KUBECONFIG_FILE"
    run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OPENCLAW_NAMESPACE\" create secret generic \"$OPENCLAW_KUBECONFIG_SECRET_NAME\" --from-file=config=\"$OPENCLAW_KUBECONFIG_FILE\" --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"
  fi
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$cm_out\""
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$secret_out\""
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$headless_svc_out\""
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$svc_out\""
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$np_egress_out\""
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$sts_out\""

  if ! run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OPENCLAW_NAMESPACE\" rollout status statefulset/openclaw --timeout=600s"; then
    run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OPENCLAW_NAMESPACE\" get pods -o wide"
    run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OPENCLAW_NAMESPACE\" describe pod openclaw-0 || true"
    run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OPENCLAW_NAMESPACE\" get events --sort-by=.lastTimestamp | tail -n 60 || true"
    exit 1
  fi

  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OPENCLAW_NAMESPACE\" get pods,svc -o wide"

  run_cmd "rm -rf \"$tmp_dir\""
}

deploy_oc_app_if_requested() {
  if [[ "$DEPLOY_OC_APP" -ne 1 ]]; then
    return
  fi

  : "${OC_APP_IMAGE:?OC_APP_IMAGE is required when --deploy-oc-app is set}"
  : "${OC_APP_CONFIG_JSON_FILE:?OC_APP_CONFIG_JSON_FILE is required when --deploy-oc-app is set}"
  : "${OC_APP_GATEWAY_TOKEN:?OC_APP_GATEWAY_TOKEN is required when --deploy-oc-app is set}"

  ensure_dir_exists "$OC_APP_MANIFEST_DIR"
  ensure_file_exists "$OC_APP_DEPLOYMENT_MANIFEST"
  ensure_file_exists "$OC_APP_SERVICE_MANIFEST"
  ensure_file_exists "$OC_APP_CONFIG_JSON_FILE"
  validate_oc_app_config_json "$OC_APP_CONFIG_JSON_FILE"

  echo "[INFO] Deploying oc-app manifests from: $OC_APP_MANIFEST_DIR"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local oc_cfg_out="$tmp_dir/oc-app.rendered.json"
  local oc_dep_out="$tmp_dir/oc-app-deployment.rendered.yaml"
  local oc_svc_out="$tmp_dir/oc-app-service.rendered.yaml"

  render_oc_app_config "$OC_APP_CONFIG_JSON_FILE" "$oc_cfg_out"
  render_manifest "$OC_APP_DEPLOYMENT_MANIFEST" "$oc_dep_out"
  render_manifest "$OC_APP_SERVICE_MANIFEST" "$oc_svc_out"

  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" create namespace \"$K8S_OC_APP_NAMESPACE\" --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"

  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OC_APP_NAMESPACE\" create secret generic oc-app-gateway-auth \
    --from-literal=OC_APP_GATEWAY_TOKEN=\"$OC_APP_GATEWAY_TOKEN\" \
    --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"

  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OC_APP_NAMESPACE\" create configmap oc-app-config \
    --from-file=oc-app.json=\"$oc_cfg_out\" \
    --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"

  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$oc_dep_out\""
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$oc_svc_out\""

  if [[ "$OC_APP_PUBLIC_EXPOSE" == "1" ]]; then
    run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OC_APP_NAMESPACE\" expose deployment \"$OC_APP_DEPLOYMENT_NAME\" \
      --name \"$OC_APP_PUBLIC_SERVICE_NAME\" \
      --type LoadBalancer \
      --port \"$OC_APP_PUBLIC_SERVICE_PORT\" \
      --target-port \"$OC_APP_PUBLIC_TARGET_PORT\" \
      --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"

    run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OC_APP_NAMESPACE\" get svc \"$OC_APP_PUBLIC_SERVICE_NAME\" -o wide"
  fi

  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OC_APP_NAMESPACE\" rollout status deployment/\"$OC_APP_DEPLOYMENT_NAME\" --timeout=300s"
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OC_APP_NAMESPACE\" get pods,svc -o wide"
  run_cmd "rm -rf \"$tmp_dir\""
}

echo "[INFO] Purpose: deploy gateway to OKE namespace ${K8S_GATEWAY_NAMESPACE} from deployment repository."

ensure_file_exists "$GATEWAY_CONFIG_JSON_FILE"
validate_gateway_config_json "$GATEWAY_CONFIG_JSON_FILE"
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
  --kube-endpoint \"${OKE_KUBE_ENDPOINT:-PRIVATE_ENDPOINT}\" \
  --profile \"${OCI_CLI_PROFILE:-DEFAULT}\" \
  --overwrite"

run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f \"$NAMESPACE_MANIFEST\""

run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_GATEWAY_NAMESPACE\" create serviceaccount oci-gateway-sa --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"
if [[ "$CREATE_OCIR_PULL_SECRET" == "1" ]]; then
  : "${OCIR_REGION_KEY:?OCIR_REGION_KEY is required when CREATE_OCIR_PULL_SECRET=1}"
  : "${OCI_USERNAME:?OCI_USERNAME is required when CREATE_OCIR_PULL_SECRET=1}"
  : "${OCI_AUTH_TOKEN:?OCI_AUTH_TOKEN is required when CREATE_OCIR_PULL_SECRET=1}"
  ensure_ocir_namespace

  # Gateway namespace pull secret
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_GATEWAY_NAMESPACE\" create secret docker-registry ocir-cred \
    --docker-server=\"${OCIR_REGION_KEY}.ocir.io\" \
    --docker-username=\"${OCIR_NAMESPACE}/${OCI_USERNAME}\" \
    --docker-password=\"$OCI_AUTH_TOKEN\" \
    --docker-email=\"ops@example.com\" \
    --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"

  # OpenClaw namespace pull secret (needed if OpenClaw is in private OCIR)
  if [[ "$DEPLOY_OPENCLAW" -eq 1 ]]; then
    run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" create namespace \"$K8S_OPENCLAW_NAMESPACE\" --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"
    run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_OPENCLAW_NAMESPACE\" create secret docker-registry ocir-cred \
      --docker-server=\"${OCIR_REGION_KEY}.ocir.io\" \
      --docker-username=\"${OCIR_NAMESPACE}/${OCI_USERNAME}\" \
      --docker-password=\"$OCI_AUTH_TOKEN\" \
      --docker-email=\"ops@example.com\" \
      --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"
  fi
fi

run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_GATEWAY_NAMESPACE\" create configmap gateway-config \
  --from-file=config.json=\"$GATEWAY_CONFIG_JSON_FILE\" \
  --dry-run=client -o yaml | kubectl --kubeconfig \"$KUBECONFIG_PATH\" apply -f -"

run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_GATEWAY_NAMESPACE\" create secret generic gateway-debug-auth \
  --from-literal=DEBUG_UI_AUTH_TOKEN=\"$DEBUG_UI_AUTH_TOKEN\" \
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
run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_GATEWAY_NAMESPACE\" rollout status deploy/oci-anthropic-gateway --timeout=300s"
run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_GATEWAY_NAMESPACE\" get pods,svc -o wide"

deploy_openclaw_if_requested

deploy_oc_app_if_requested

if [[ "$APPLY" -eq 0 ]]; then
  echo "[INFO] Dry run only. Add --apply to execute commands."
else
  echo "[INFO] Deployment completed."
fi
