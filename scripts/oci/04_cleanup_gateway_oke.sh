#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="scripts/oci/gateway.env.example"
APPLY=0
DELETE_NAMESPACE=0
DELETE_OCIR_IMAGE=0
DELETE_OCIR_REPO=0
DELETE_LOCAL_IMAGE=0

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
    --delete-namespace)
      DELETE_NAMESPACE=1
      shift
      ;;
    --delete-ocir-image)
      DELETE_OCIR_IMAGE=1
      shift
      ;;
    --delete-ocir-repo)
      DELETE_OCIR_REPO=1
      shift
      ;;
    --delete-local-image)
      DELETE_LOCAL_IMAGE=1
      shift
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      echo "Usage: $0 [--env path/to/gateway.env] [--apply] [--delete-namespace] [--delete-ocir-image] [--delete-ocir-repo] [--delete-local-image]" >&2
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

: "${K8S_GATEWAY_NAMESPACE:-${K8S_NAMESPACE:-}}"
K8S_NAMESPACE="${K8S_GATEWAY_NAMESPACE:-${K8S_NAMESPACE}}"
: "${K8S_NAMESPACE:?K8S_GATEWAY_NAMESPACE (or K8S_NAMESPACE) is required}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"
OCIR_REPO="${OCIR_REPO:-oci-gateway}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

run_cmd() {
  local cmd="$1"
  echo "+ $cmd"
  if [[ "$APPLY" -eq 1 ]]; then
    bash -lc "$cmd"
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

echo "[INFO] Purpose: cleanup gateway resources in namespace ${K8S_NAMESPACE}."

run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_NAMESPACE\" delete deployment oci-anthropic-gateway --ignore-not-found"
run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_NAMESPACE\" delete service oci-anthropic-gateway --ignore-not-found"
run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_NAMESPACE\" delete networkpolicy gateway-egress-restrict --ignore-not-found"
run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_NAMESPACE\" delete configmap gateway-config --ignore-not-found"
run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_NAMESPACE\" delete secret gateway-debug-auth ocir-cred --ignore-not-found"
# Legacy secret name (oci_config_secret mode)
run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" -n \"$K8S_NAMESPACE\" delete secret gateway-oci-sdk --ignore-not-found"

if [[ "$DELETE_NAMESPACE" -eq 1 ]]; then
  run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" delete namespace \"$K8S_NAMESPACE\" --ignore-not-found"
fi

if [[ "$DELETE_LOCAL_IMAGE" -eq 1 ]]; then
  ensure_ocir_namespace
  LOCAL_IMAGE="${OCIR_REGION_KEY}.ocir.io/${OCIR_NAMESPACE}/${OCIR_REPO}:${IMAGE_TAG}"
  run_cmd "docker rmi \"$LOCAL_IMAGE\" || true"
fi

if [[ "$DELETE_OCIR_IMAGE" -eq 1 || "$DELETE_OCIR_REPO" -eq 1 ]]; then
  : "${OCI_REGION:?OCI_REGION is required for OCIR cleanup}"
  : "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID is required for OCIR cleanup}"
  : "${OCIR_REGION_KEY:?OCIR_REGION_KEY is required for OCIR cleanup}"
  ensure_ocir_namespace
fi

if [[ "$DELETE_OCIR_IMAGE" -eq 1 ]]; then
  IMAGE_URI="${OCIR_NAMESPACE}/${OCIR_REPO}:${IMAGE_TAG}"
  if [[ "$APPLY" -eq 1 ]]; then
    IMAGE_ID="$(oci artifacts container image lookup \
      --image-uri "$IMAGE_URI" \
      --region "$OCI_REGION" \
      --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
      --query 'data.id' \
      --raw-output 2>/dev/null || true)"

    if [[ -n "$IMAGE_ID" && "$IMAGE_ID" != "null" ]]; then
      run_cmd "oci artifacts container image delete --image-id \"$IMAGE_ID\" --force --region \"$OCI_REGION\" --profile \"${OCI_CLI_PROFILE:-DEFAULT}\""
    else
      echo "[INFO] OCIR image not found: $IMAGE_URI"
    fi
  else
    echo "+ oci artifacts container image lookup --image-uri \"$IMAGE_URI\" --region \"$OCI_REGION\" --profile \"${OCI_CLI_PROFILE:-DEFAULT}\""
    echo "+ (if exists) oci artifacts container image delete --image-id \"<looked-up-image-id>\" --force --region \"$OCI_REGION\" --profile \"${OCI_CLI_PROFILE:-DEFAULT}\""
  fi
fi

if [[ "$DELETE_OCIR_REPO" -eq 1 ]]; then
  REPO_NAME="${OCIR_NAMESPACE}/${OCIR_REPO}"
  if [[ "$APPLY" -eq 1 ]]; then
    REPO_ID="$(oci artifacts container repository list \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --display-name "$REPO_NAME" \
      --region "$OCI_REGION" \
      --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
      --query 'data[0].id' \
      --raw-output 2>/dev/null || true)"

    if [[ -n "$REPO_ID" && "$REPO_ID" != "null" ]]; then
      run_cmd "oci artifacts container repository delete --repository-id \"$REPO_ID\" --force --region \"$OCI_REGION\" --profile \"${OCI_CLI_PROFILE:-DEFAULT}\""
    else
      echo "[INFO] OCIR repository not found: $REPO_NAME"
    fi
  else
    echo "+ oci artifacts container repository list --compartment-id \"$OCI_COMPARTMENT_OCID\" --display-name \"$REPO_NAME\" --region \"$OCI_REGION\" --profile \"${OCI_CLI_PROFILE:-DEFAULT}\""
    echo "+ (if exists) oci artifacts container repository delete --repository-id \"<looked-up-repo-id>\" --force --region \"$OCI_REGION\" --profile \"${OCI_CLI_PROFILE:-DEFAULT}\""
  fi
fi

if [[ "$APPLY" -eq 0 ]]; then
  echo "[INFO] Dry run only. Add --apply to execute cleanup."
fi
