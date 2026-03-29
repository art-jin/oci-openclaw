#!/usr/bin/env bash
set -euo pipefail

# Manage OCI IAM Policy for OpenClaw instance principal Object Storage access.
#
# Usage:
#   bash scripts/oci/12_openclaw_instance_principal_policy.sh create-or-update --env scripts/oci/gateway.env
#   bash scripts/oci/12_openclaw_instance_principal_policy.sh create --env scripts/oci/gateway.env
#   bash scripts/oci/12_openclaw_instance_principal_policy.sh delete --env scripts/oci/gateway.env
#
# Notes:
#   - Requires an existing Dynamic Group for the worker nodes.
#   - Defaults to OPENCLAW_INSTANCE_PRINCIPAL_DYNAMIC_GROUP_NAME from gateway.env.
#   - Applies Object Storage bucket/object permissions in OCI_COMPARTMENT_OCID.

ACTION="${1:-}"
shift || true

ENV_FILE="scripts/oci/gateway.env"
OCI_CLI_PROFILE="DEFAULT"
OCI_REGION=""
POLICY_NAME="openclaw-instance-principal-objectstorage"
POLICY_DESC="Instance principal policy for OpenClaw worker nodes to access Object Storage"
DYNAMIC_GROUP_NAME=""
COMPARTMENT_ID_OVERRIDE=""

usage() {
  cat >&2 <<EOF
Usage:
  $0 <create|create-or-update|delete> --env path/to/gateway.env [options]

Options:
  --env <file>               Env file to source (default: scripts/oci/gateway.env)
  --profile <name>           OCI CLI profile (default: DEFAULT or OCI_CLI_PROFILE from env)
  --region <region>          OCI region (default: OCI_REGION from env)
  --compartment-id <ocid>    Override compartment OCID (default: OCI_COMPARTMENT_OCID from env)
  --dynamic-group-name <n>   Existing Dynamic Group name for worker nodes
  --policy-name <name>       Policy name (default: openclaw-instance-principal-objectstorage)
  --policy-desc <text>       Policy description
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
    --dynamic-group-name)
      DYNAMIC_GROUP_NAME="$2"; shift 2 ;;
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
DYNAMIC_GROUP_NAME="${DYNAMIC_GROUP_NAME:-${OPENCLAW_INSTANCE_PRINCIPAL_DYNAMIC_GROUP_NAME:-}}"

: "${COMPARTMENT_ID:?OCI_COMPARTMENT_OCID (or --compartment-id) is required}"
: "${DYNAMIC_GROUP_NAME:?OPENCLAW_INSTANCE_PRINCIPAL_DYNAMIC_GROUP_NAME (or --dynamic-group-name) is required}"

STATEMENTS=(
  "Allow dynamic-group ${DYNAMIC_GROUP_NAME} to manage buckets in compartment id ${COMPARTMENT_ID}"
  "Allow dynamic-group ${DYNAMIC_GROUP_NAME} to manage objects in compartment id ${COMPARTMENT_ID}"
)

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
