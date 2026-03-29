#!/usr/bin/env bash
set -euo pipefail

# Manage OCI Dynamic Group for OpenClaw instance principal experiments.
#
# Usage:
#   bash scripts/oci/12a_openclaw_instance_principal_dynamic_group.sh create-or-update --env scripts/oci/gateway.env
#   bash scripts/oci/12a_openclaw_instance_principal_dynamic_group.sh create --env scripts/oci/gateway.env
#   bash scripts/oci/12a_openclaw_instance_principal_dynamic_group.sh delete --env scripts/oci/gateway.env
#
# Notes:
#   - IAM operations default to OCI_HOME_REGION when available.
#   - Default Dynamic Group name comes from OPENCLAW_INSTANCE_PRINCIPAL_DYNAMIC_GROUP_NAME.
#   - Default matching rule uses OCI_COMPARTMENT_OCID for the simplest experiment path.
#   - Creating/updating Dynamic Groups requires IAM permission in the tenancy.

ACTION="${1:-}"
shift || true

ENV_FILE="scripts/oci/gateway.env"
OCI_CLI_PROFILE="DEFAULT"
OCI_REGION=""
DYNAMIC_GROUP_NAME=""
DYNAMIC_GROUP_DESC="Dynamic group for OpenClaw instance principal worker nodes"
MATCHING_RULE=""
COMPARTMENT_ID_OVERRIDE=""
REGION_OVERRIDE=""

usage() {
  cat >&2 <<EOF
Usage:
  $0 <create|create-or-update|delete> --env path/to/gateway.env [options]

Options:
  --env <file>               Env file to source (default: scripts/oci/gateway.env)
  --profile <name>           OCI CLI profile (default: DEFAULT or OCI_CLI_PROFILE from env)
  --region <region>          OCI region (default: OCI_HOME_REGION or OCI_REGION from env)
  --compartment-id <ocid>    Override OCI_COMPARTMENT_OCID used in default matching rule
  --dynamic-group-name <n>   Dynamic Group name (default: OPENCLAW_INSTANCE_PRINCIPAL_DYNAMIC_GROUP_NAME)
  --description <text>       Dynamic Group description
  --matching-rule <text>     Override matching rule (default: ALL {instance.compartment.id = '<OCI_COMPARTMENT_OCID>'})
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
      REGION_OVERRIDE="$2"; shift 2 ;;
    --compartment-id)
      COMPARTMENT_ID_OVERRIDE="$2"; shift 2 ;;
    --dynamic-group-name)
      DYNAMIC_GROUP_NAME="$2"; shift 2 ;;
    --description)
      DYNAMIC_GROUP_DESC="$2"; shift 2 ;;
    --matching-rule)
      MATCHING_RULE="$2"; shift 2 ;;
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
ENV_OCI_REGION="${OCI_REGION:-}"
OCI_HOME_REGION="${OCI_HOME_REGION:-}"
if [[ -n "$REGION_OVERRIDE" ]]; then
  OCI_REGION="$REGION_OVERRIDE"
elif [[ -n "$OCI_HOME_REGION" ]]; then
  OCI_REGION="$OCI_HOME_REGION"
else
  OCI_REGION="$ENV_OCI_REGION"
fi
COMPARTMENT_ID="${COMPARTMENT_ID_OVERRIDE:-${OCI_COMPARTMENT_OCID:-}}"
DYNAMIC_GROUP_NAME="${DYNAMIC_GROUP_NAME:-${OPENCLAW_INSTANCE_PRINCIPAL_DYNAMIC_GROUP_NAME:-}}"
MATCHING_RULE="${MATCHING_RULE:-ALL {instance.compartment.id = '${COMPARTMENT_ID}'}}"

: "${OCI_REGION:?OCI_HOME_REGION or OCI_REGION is required}"
: "${COMPARTMENT_ID:?OCI_COMPARTMENT_OCID (or --compartment-id) is required}"
: "${DYNAMIC_GROUP_NAME:?OPENCLAW_INSTANCE_PRINCIPAL_DYNAMIC_GROUP_NAME (or --dynamic-group-name) is required}"

REGION_ARGS=(--region "$OCI_REGION")
PROFILE_ARGS=(--profile "$OCI_CLI_PROFILE")
TENANCY_OCID="$(oci iam compartment list --all --access-level ACCESSIBLE --compartment-id-in-subtree true "${REGION_ARGS[@]}" "${PROFILE_ARGS[@]}" --query 'data[?contains("compartment-id", `tenancy`)][0]."compartment-id"' --raw-output 2>/dev/null || true)"
: "${TENANCY_OCID:?Unable to determine tenancy OCID; pass credentials with IAM read access or create the dynamic group manually}"

lookup_dynamic_group_id() {
  oci iam dynamic-group list \
    --all \
    "${REGION_ARGS[@]}" \
    "${PROFILE_ARGS[@]}" \
    --query "data[?name=='${DYNAMIC_GROUP_NAME}'][0].id" \
    --raw-output 2>/dev/null | awk 'NF && $0!="null" && $0!="[]" {print $0}' || true
}

case "$ACTION" in
  create)
    echo "[INFO] Creating Dynamic Group '${DYNAMIC_GROUP_NAME}'"
    echo "[INFO] Matching rule: ${MATCHING_RULE}"
    oci iam dynamic-group create \
      --compartment-id "$TENANCY_OCID" \
      --name "$DYNAMIC_GROUP_NAME" \
      --description "$DYNAMIC_GROUP_DESC" \
      --matching-rule "$MATCHING_RULE" \
      "${REGION_ARGS[@]}" \
      "${PROFILE_ARGS[@]}"
    ;;
  create-or-update)
    DYNAMIC_GROUP_ID="$(lookup_dynamic_group_id)"
    if [[ -n "$DYNAMIC_GROUP_ID" ]]; then
      echo "[INFO] Dynamic Group exists. Updating: $DYNAMIC_GROUP_ID"
      oci iam dynamic-group update \
        --dynamic-group-id "$DYNAMIC_GROUP_ID" \
        --description "$DYNAMIC_GROUP_DESC" \
        --matching-rule "$MATCHING_RULE" \
        --force \
        "${REGION_ARGS[@]}" \
        "${PROFILE_ARGS[@]}"
      echo "[INFO] Updated Dynamic Group: $DYNAMIC_GROUP_ID"
    else
      echo "[INFO] Dynamic Group not found. Creating '${DYNAMIC_GROUP_NAME}'"
      oci iam dynamic-group create \
        --compartment-id "$TENANCY_OCID" \
        --name "$DYNAMIC_GROUP_NAME" \
        --description "$DYNAMIC_GROUP_DESC" \
        --matching-rule "$MATCHING_RULE" \
        "${REGION_ARGS[@]}" \
        "${PROFILE_ARGS[@]}"
    fi
    ;;
  delete)
    DYNAMIC_GROUP_ID="$(lookup_dynamic_group_id)"
    if [[ -z "$DYNAMIC_GROUP_ID" ]]; then
      echo "[INFO] Dynamic Group not found: ${DYNAMIC_GROUP_NAME} (nothing to delete)"
      exit 0
    fi
    echo "[INFO] Deleting Dynamic Group: $DYNAMIC_GROUP_ID"
    oci iam dynamic-group delete \
      --dynamic-group-id "$DYNAMIC_GROUP_ID" \
      --force \
      "${REGION_ARGS[@]}" \
      "${PROFILE_ARGS[@]}"
    echo "[INFO] Delete requested for: $DYNAMIC_GROUP_ID"
    ;;
  *)
    echo "[ERROR] Unknown action: $ACTION" >&2
    usage
    exit 1
    ;;
esac
