#!/usr/bin/env bash
set -euo pipefail

# Manage OCI IAM Policy for OKE Workload Identity used by oci-anthropic-gateway and OpenClaw OCI CLI.
#
# Usage:
#   bash scripts/oci/11_workload_identity_policy.sh create-or-update --env scripts/oci/gateway.env
#   bash scripts/oci/11_workload_identity_policy.sh create --env scripts/oci/gateway.env
#   bash scripts/oci/11_workload_identity_policy.sh delete --env scripts/oci/gateway.env
#
# Defaults (match k8s manifests):
#   namespace: gateway-prod
#   service account: oci-gateway-sa
#   policy name: oke-gateway-workload-identity

ACTION="${1:-}"
shift || true

ENV_FILE="scripts/oci/gateway.env"
OCI_CLI_PROFILE="DEFAULT"
OCI_REGION=""
MODE="all"
POLICY_NAME="oke-gateway-workload-identity"
POLICY_DESC="OKE workload identity policy for gateway GenAI and OpenClaw Object Storage"
GATEWAY_NAMESPACE="gateway-prod"
GATEWAY_SERVICE_ACCOUNT="oci-gateway-sa"
OPENCLAW_NAMESPACE="openclaw-prod"
OPENCLAW_SERVICE_ACCOUNT="openclaw-sa"
NAMESPACE="$GATEWAY_NAMESPACE"
SERVICE_ACCOUNT="$GATEWAY_SERVICE_ACCOUNT"
COMPARTMENT_ID_OVERRIDE=""
CLUSTER_OCID_OVERRIDE=""

usage() {
  cat >&2 <<EOF
Usage:
  $0 <create|create-or-update|delete> --env path/to/gateway.env [options]

Modes:
  all                      (default) create/update both gateway GenAI and OpenClaw Object Storage statements together
  gateway-genai            policy for gateway to call OCI GenAI only
  openclaw-objectstorage   policy for OpenClaw pod-based OKE workload identity to manage Object Storage (buckets + objects only)

Options:
  --env <file>              Env file to source (default: scripts/oci/gateway.env)
  --profile <name>          OCI CLI profile (default: DEFAULT or OCI_CLI_PROFILE from env)
  --region <region>         OCI region (default: OCI_REGION from env)
  --compartment-id <ocid>   Override compartment OCID (default: OCI_COMPARTMENT_OCID from env)
  --cluster-id <ocid>       Override OKE cluster OCID (default: OCI_CLUSTER_OCID from env)
  --namespace <name>        Override namespace for single-mode runs
  --service-account <name>  Override serviceaccount for single-mode runs
  --mode <name>             Policy mode: all|gateway-genai|openclaw-objectstorage (default: all)
  --policy-name <name>      Policy name (default: oke-gateway-workload-identity)
  --policy-desc <text>      Policy description
EOF
}

if [[ -z "$ACTION" ]]; then
  usage
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_FILE="$2"; shift 2 ;;
    --profile)
      OCI_CLI_PROFILE="$2"; shift 2 ;;
    --region)
      OCI_REGION="$2"; shift 2 ;;
    --compartment-id)
      COMPARTMENT_ID_OVERRIDE="$2"; shift 2 ;;
    --cluster-id)
      CLUSTER_OCID_OVERRIDE="$2"; shift 2 ;;
    --namespace)
      NAMESPACE="$2"; shift 2 ;;
    --service-account)
      SERVICE_ACCOUNT="$2"; shift 2 ;;
    --policy-name)
      POLICY_NAME="$2"; shift 2 ;;
    --mode)
      MODE="$2"; shift 2 ;;
    --policy-desc)
      POLICY_DESC="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage
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

OCI_CLI_PROFILE="${OCI_CLI_PROFILE:-$OCI_CLI_PROFILE}"
OCI_REGION="${OCI_REGION:-$OCI_REGION}"
OCI_HOME_REGION="${OCI_HOME_REGION:-}"

COMPARTMENT_ID="${COMPARTMENT_ID_OVERRIDE:-${OCI_COMPARTMENT_OCID:-}}"
CLUSTER_OCID="${CLUSTER_OCID_OVERRIDE:-${OCI_CLUSTER_OCID:-}}"

: "${COMPARTMENT_ID:?OCI_COMPARTMENT_OCID (or --compartment-id) is required}"
: "${CLUSTER_OCID:?OCI_CLUSTER_OCID (or --cluster-id) is required}"

STATEMENTS=()

build_gateway_genai_statements() {
  local namespace="$1"
  local service_account="$2"
  STATEMENTS+=("Allow any-user to inspect generative-ai-model in compartment id ${COMPARTMENT_ID} where all {request.principal.type='workload',request.principal.namespace='${namespace}',request.principal.service_account='${service_account}',request.principal.cluster_id='${CLUSTER_OCID}'}")
  STATEMENTS+=("Allow any-user to use generative-ai-chat in compartment id ${COMPARTMENT_ID} where all {request.principal.type='workload',request.principal.namespace='${namespace}',request.principal.service_account='${service_account}',request.principal.cluster_id='${CLUSTER_OCID}'}")
}

build_openclaw_objectstorage_statements() {
  local namespace="$1"
  local service_account="$2"
  STATEMENTS+=("Allow any-user to manage buckets in compartment id ${COMPARTMENT_ID} where all {request.principal.type='workload',request.principal.namespace='${namespace}',request.principal.service_account='${service_account}',request.principal.cluster_id='${CLUSTER_OCID}'}")
  STATEMENTS+=("Allow any-user to manage objects in compartment id ${COMPARTMENT_ID} where all {request.principal.type='workload',request.principal.namespace='${namespace}',request.principal.service_account='${service_account}',request.principal.cluster_id='${CLUSTER_OCID}'}")
}

case "${MODE}" in
  all)
    build_gateway_genai_statements "$GATEWAY_NAMESPACE" "$GATEWAY_SERVICE_ACCOUNT"
    build_openclaw_objectstorage_statements "$OPENCLAW_NAMESPACE" "$OPENCLAW_SERVICE_ACCOUNT"
    ;;
  gateway-genai)
    build_gateway_genai_statements "$NAMESPACE" "$SERVICE_ACCOUNT"
    ;;
  openclaw-objectstorage)
    build_openclaw_objectstorage_statements "$NAMESPACE" "$SERVICE_ACCOUNT"
    ;;
  *)
    echo "[ERROR] Unknown mode: ${MODE}" >&2
    exit 1
    ;;
esac

STATEMENTS_JSON="["
for i in "${!STATEMENTS[@]}"; do
  if [[ "$i" -gt 0 ]]; then
    STATEMENTS_JSON+=","
  fi
  stmt_escaped="${STATEMENTS[$i]//\\/\\\\}"
  stmt_escaped="${stmt_escaped//\"/\\\"}"
  STATEMENTS_JSON+="\"${stmt_escaped}\""
done
STATEMENTS_JSON+="]"

REGION_ARGS=()
# IAM (Identity) CREATE/UPDATE/DELETE must be executed in the tenancy Home Region.
# Prefer OCI_HOME_REGION when mutating policies; fallback to OCI_REGION.
EFFECTIVE_REGION="$OCI_REGION"
if [[ "$ACTION" == "create" || "$ACTION" == "create-or-update" || "$ACTION" == "delete" ]]; then
  if [[ -n "$OCI_HOME_REGION" ]]; then
    EFFECTIVE_REGION="$OCI_HOME_REGION"
  fi
fi
if [[ -n "$EFFECTIVE_REGION" ]]; then
  REGION_ARGS+=(--region "$EFFECTIVE_REGION")
fi

PROFILE_ARGS=(--profile "$OCI_CLI_PROFILE")

lookup_policy_id() {
  # Returns policy OCID or empty.
  oci iam policy list \
    --compartment-id "$COMPARTMENT_ID" \
    --name "$POLICY_NAME" \
    --all \
    "${REGION_ARGS[@]}" \
    "${PROFILE_ARGS[@]}" \
    --query 'data[0].id' \
    --raw-output 2>/dev/null | awk 'NF && $0!="null" {print $0}' || true
}

lookup_policy_version_date_ymd() {
  local policy_id="$1"
  # OCI policy update expects yyyy-MM-dd. Prefer version-date, then fall back to time-updated/time-created.
  local v
  v="$(oci iam policy get \
    --policy-id "$policy_id" \
    "${REGION_ARGS[@]}" \
    "${PROFILE_ARGS[@]}" \
    --query 'data."version-date"' \
    --raw-output 2>/dev/null || true)"
  v="${v%%\r}"
  v="${v%%\n}"
  if [[ -z "$v" || "$v" == "null" ]]; then
    v="$(oci iam policy get \
      --policy-id "$policy_id" \
      "${REGION_ARGS[@]}" \
      "${PROFILE_ARGS[@]}" \
      --query 'data."time-updated"' \
      --raw-output 2>/dev/null || true)"
    v="${v%%\r}"
    v="${v%%\n}"
  fi
  if [[ -z "$v" || "$v" == "null" ]]; then
    v="$(oci iam policy get \
      --policy-id "$policy_id" \
      "${REGION_ARGS[@]}" \
      "${PROFILE_ARGS[@]}" \
      --query 'data."time-created"' \
      --raw-output 2>/dev/null || true)"
    v="${v%%\r}"
    v="${v%%\n}"
  fi
  if [[ -z "$v" || "$v" == "null" ]]; then
    return 0
  fi
  echo "${v:0:10}"
}

case "$ACTION" in
  create)
    echo "[INFO] Creating policy '${POLICY_NAME}' in compartment ${COMPARTMENT_ID}"
    echo "[INFO] Statements:"
    for stmt in "${STATEMENTS[@]}"; do
      echo "  - $stmt"
    done
    oci iam policy create \
      --compartment-id "$COMPARTMENT_ID" \
      --name "$POLICY_NAME" \
      --description "$POLICY_DESC" \
      --statements "$STATEMENTS_JSON" \
      "${REGION_ARGS[@]}" \
      "${PROFILE_ARGS[@]}" \
      --wait-for-state ACTIVE
    ;;

  create-or-update)
    POLICY_ID="$(lookup_policy_id)"
    if [[ -n "$POLICY_ID" ]]; then
      echo "[INFO] Policy exists. Updating: $POLICY_ID"
      VERSION_DATE_YMD="$(lookup_policy_version_date_ymd "$POLICY_ID")"
      if [[ -n "$VERSION_DATE_YMD" ]]; then
        oci iam policy update \
          --policy-id "$POLICY_ID" \
          --version-date "$VERSION_DATE_YMD" \
          --statements "$STATEMENTS_JSON" \
          --force \
          "${REGION_ARGS[@]}" \
          "${PROFILE_ARGS[@]}"
      else
        echo "[WARN] Policy version-date is null; updating without --version-date: $POLICY_ID" >&2
        oci iam policy update \
          --policy-id "$POLICY_ID" \
          --statements "$STATEMENTS_JSON" \
          --force \
          "${REGION_ARGS[@]}" \
          "${PROFILE_ARGS[@]}"
      fi
      echo "[INFO] Updated policy: $POLICY_ID"
    else
      echo "[INFO] Policy not found. Creating '${POLICY_NAME}'"
      oci iam policy create \
        --compartment-id "$COMPARTMENT_ID" \
        --name "$POLICY_NAME" \
        --description "$POLICY_DESC" \
        --statements "$STATEMENTS_JSON" \
        "${REGION_ARGS[@]}" \
        "${PROFILE_ARGS[@]}" \
        --wait-for-state ACTIVE
    fi
    ;;

  delete)
    POLICY_ID="$(lookup_policy_id)"
    if [[ -z "$POLICY_ID" ]]; then
      echo "[INFO] Policy not found: ${POLICY_NAME} (nothing to delete)"
      exit 0
    fi
    echo "[INFO] Deleting policy: $POLICY_ID"
    oci iam policy delete \
      --policy-id "$POLICY_ID" \
      --force \
      "${REGION_ARGS[@]}" \
      "${PROFILE_ARGS[@]}"
    echo "[INFO] Delete requested for: $POLICY_ID"
    ;;

  *)
    echo "[ERROR] Unknown action: $ACTION" >&2
    usage
    exit 1
    ;;
esac
