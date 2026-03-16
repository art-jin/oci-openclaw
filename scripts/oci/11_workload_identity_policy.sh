#!/usr/bin/env bash
set -euo pipefail

# Manage OCI IAM Policy for OKE Workload Identity used by oci-anthropic-gateway.
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
POLICY_NAME="oke-gateway-workload-identity"
POLICY_DESC="OKE workload identity policy for oci-anthropic-gateway"
NAMESPACE="gateway-prod"
SERVICE_ACCOUNT="oci-gateway-sa"
COMPARTMENT_ID_OVERRIDE=""
CLUSTER_OCID_OVERRIDE=""

usage() {
  cat >&2 <<EOF
Usage:
  $0 <create|create-or-update|delete> --env path/to/gateway.env [options]

Options:
  --env <file>              Env file to source (default: scripts/oci/gateway.env)
  --profile <name>          OCI CLI profile (default: DEFAULT or OCI_CLI_PROFILE from env)
  --region <region>         OCI region (default: OCI_REGION from env)
  --compartment-id <ocid>   Override compartment OCID (default: OCI_COMPARTMENT_OCID from env)
  --cluster-id <ocid>       Override OKE cluster OCID (default: OCI_CLUSTER_OCID from env)
  --namespace <name>        Kubernetes namespace (default: gateway-prod)
  --service-account <name>  Kubernetes serviceaccount (default: oci-gateway-sa)
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

STMT1="Allow any-user to inspect generative-ai-model in compartment id ${COMPARTMENT_ID} where all {request.principal.type='workload',request.principal.namespace='${NAMESPACE}',request.principal.service_account='${SERVICE_ACCOUNT}',request.principal.cluster_id='${CLUSTER_OCID}'}"
STMT2="Allow any-user to use generative-ai-chat in compartment id ${COMPARTMENT_ID} where all {request.principal.type='workload',request.principal.namespace='${NAMESPACE}',request.principal.service_account='${SERVICE_ACCOUNT}',request.principal.cluster_id='${CLUSTER_OCID}'}"

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
  # OCI returns data."version-date" as RFC3339. Policy update expects yyyy-MM-dd.
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
    return 0
  fi
  echo "${v:0:10}"
}

case "$ACTION" in
  create)
    echo "[INFO] Creating policy '${POLICY_NAME}' in compartment ${COMPARTMENT_ID}"
    echo "[INFO] Statements:"
    echo "  - $STMT1"
    echo "  - $STMT2"
    oci iam policy create \
      --compartment-id "$COMPARTMENT_ID" \
      --name "$POLICY_NAME" \
      --description "$POLICY_DESC" \
      --statements "[\"$STMT1\",\"$STMT2\"]" \
      "${REGION_ARGS[@]}" \
      "${PROFILE_ARGS[@]}" \
      --wait-for-state ACTIVE
    ;;

  create-or-update)
    POLICY_ID="$(lookup_policy_id)"
    if [[ -n "$POLICY_ID" ]]; then
      echo "[INFO] Policy exists. Updating: $POLICY_ID"
      VERSION_DATE_YMD="$(lookup_policy_version_date_ymd "$POLICY_ID")"
      if [[ -z "$VERSION_DATE_YMD" ]]; then
        echo "[ERROR] Failed to lookup policy version-date for: $POLICY_ID" >&2
        exit 1
      fi
      oci iam policy update \
        --policy-id "$POLICY_ID" \
        --version-date "$VERSION_DATE_YMD" \
        --statements "[\"$STMT1\",\"$STMT2\"]" \
        --force \
        "${REGION_ARGS[@]}" \
        "${PROFILE_ARGS[@]}"
      echo "[INFO] Updated policy: $POLICY_ID"
    else
      echo "[INFO] Policy not found. Creating '${POLICY_NAME}'"
      oci iam policy create \
        --compartment-id "$COMPARTMENT_ID" \
        --name "$POLICY_NAME" \
        --description "$POLICY_DESC" \
        --statements "[\"$STMT1\",\"$STMT2\"]" \
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
