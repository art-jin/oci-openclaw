#!/usr/bin/env bash
set -euo pipefail

# Build and push OpenClaw image to OCIR.
# Inputs come from sourced env file (same style as other scripts):
#   OCI_REGION, OCI_COMPARTMENT_OCID, OCI_CLI_PROFILE
#   OCIR_REGION_KEY, OCI_USERNAME, OCI_AUTH_TOKEN, OCIR_NAMESPACE(optional)
#   OPENCLAW_REPO_DIR, OPENCLAW_OCIR_REPO, OPENCLAW_IMAGE_TAG
# Output:
#   Prints the full image reference to stdout.

ENV_FILE="${1:-scripts/oci/gateway.env}"
APPLY=0
if [[ "${2:-}" == "--apply" || "${1:-}" == "--apply" ]]; then
  APPLY=1
fi
if [[ "${2:-}" == "--apply" ]]; then
  ENV_FILE="${1}"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] env file not found: $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

: "${OCI_REGION:?OCI_REGION is required}"
: "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID is required}"
OCI_ARTIFACTS_COMPARTMENT_OCID="${OCI_ARTIFACTS_COMPARTMENT_OCID:-$OCI_COMPARTMENT_OCID}"
: "${OCIR_REGION_KEY:?OCIR_REGION_KEY is required}"
: "${OCI_USERNAME:?OCI_USERNAME is required}"
: "${OCI_AUTH_TOKEN:?OCI_AUTH_TOKEN is required}"
: "${OPENCLAW_REPO_DIR:?OPENCLAW_REPO_DIR is required}"

OPENCLAW_OCIR_REPO="${OPENCLAW_OCIR_REPO:-openclaw}"
OPENCLAW_IMAGE_TAG="${OPENCLAW_IMAGE_TAG:-$(date +%Y%m%d%H%M%S)}"

run_cmd() {
  local cmd="$1"
  echo "+ $cmd" >&2
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

ensure_ocir_namespace

ensure_file_exists "$OPENCLAW_REPO_DIR/Dockerfile"

IMAGE_FULL="${OCIR_REGION_KEY}.ocir.io/${OCIR_NAMESPACE}/${OPENCLAW_OCIR_REPO}:${OPENCLAW_IMAGE_TAG}"

if [[ "$APPLY" -eq 1 ]]; then
  # Note: OCI CLI does not consistently support "repository get by name" across versions.
  # Use list+filter to determine existence.
  if oci artifacts container repository list \
    --compartment-id "$OCI_ARTIFACTS_COMPARTMENT_OCID" \
    --region "$OCI_REGION" \
    --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
    --all \
    --query "length(data[?\"display-name\"=='${OCIR_NAMESPACE}/${OPENCLAW_OCIR_REPO}'])" \
    --raw-output 2>/dev/null | grep -qx "0"; then
    run_cmd "oci artifacts container repository create \
      --compartment-id \"$OCI_ARTIFACTS_COMPARTMENT_OCID\" \
      --display-name \"${OPENCLAW_OCIR_REPO}\" \
      --is-immutable false \
      --region \"$OCI_REGION\" \
      --profile \"${OCI_CLI_PROFILE:-DEFAULT}\""
  else
    echo "[INFO] OCIR repository exists: ${OCIR_NAMESPACE}/${OPENCLAW_OCIR_REPO}"
  fi
else
  echo "+ oci artifacts container repository list --compartment-id \"$OCI_ARTIFACTS_COMPARTMENT_OCID\" --all ... (filter display-name == ${OCIR_NAMESPACE}/${OPENCLAW_OCIR_REPO})" >&2
  echo "+ (if not exists) oci artifacts container repository create --display-name \"${OPENCLAW_OCIR_REPO}\" ..." >&2
fi

run_cmd "docker login ${OCIR_REGION_KEY}.ocir.io -u \"${OCIR_NAMESPACE}/${OCI_USERNAME}\" -p \"$OCI_AUTH_TOKEN\""
run_cmd "docker build -t \"$IMAGE_FULL\" -f \"$OPENCLAW_REPO_DIR/Dockerfile\" \"$OPENCLAW_REPO_DIR\""
run_cmd "docker push \"$IMAGE_FULL\""

echo "$IMAGE_FULL"
