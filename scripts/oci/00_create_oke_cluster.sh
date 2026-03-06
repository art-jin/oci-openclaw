#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="scripts/oci/gateway.env"
APPLY=0

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
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      echo "Usage: $0 [--env path/to/gateway.env] [--apply]" >&2
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
: "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID is required}"

OKE_CLUSTER_NAME="${OKE_CLUSTER_NAME:-openclaw-oke}"
OKE_K8S_VERSION="${OKE_K8S_VERSION:-v1.30.1}"
OKE_API_ENDPOINT_VISIBILITY="${OKE_API_ENDPOINT_VISIBILITY:-PUBLIC}"

VCN_MODE="${OKE_VCN_MODE:-new}"
OKE_VCN_OCID="${OKE_VCN_OCID:-}"
OKE_ENDPOINT_SUBNET_OCID="${OKE_ENDPOINT_SUBNET_OCID:-}"
OKE_WORKER_SUBNET_OCID="${OKE_WORKER_SUBNET_OCID:-}"
OKE_LB_SUBNET_OCID="${OKE_LB_SUBNET_OCID:-}"

OKE_VCN_CIDR="${OKE_VCN_CIDR:-10.0.0.0/16}"
OKE_ENDPOINT_SUBNET_CIDR="${OKE_ENDPOINT_SUBNET_CIDR:-10.0.10.0/24}"
OKE_WORKER_SUBNET_CIDR="${OKE_WORKER_SUBNET_CIDR:-10.0.20.0/24}"
OKE_LB_SUBNET_CIDR="${OKE_LB_SUBNET_CIDR:-10.0.30.0/24}"

OKE_NODEPOOL_NAME="${OKE_NODEPOOL_NAME:-openclaw-nodepool}"
OKE_NODE_SHAPE="${OKE_NODE_SHAPE:-VM.Standard.E5.Flex}"
OKE_NODE_OCPUS="${OKE_NODE_OCPUS:-1}"
OKE_NODE_MEMORY_GB="${OKE_NODE_MEMORY_GB:-8}"
OKE_NODE_COUNT="${OKE_NODE_COUNT:-2}"
OKE_NODE_IMAGE_OCID="${OKE_NODE_IMAGE_OCID:-}"

run_cmd() {
  local cmd="$1"
  echo "+ $cmd"
  if [[ "$APPLY" -eq 1 ]]; then
    bash -lc "$cmd"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/"/\\"/g'
}

if [[ "$VCN_MODE" != "new" && "$VCN_MODE" != "existing" ]]; then
  echo "[ERROR] OKE_VCN_MODE must be new or existing" >&2
  exit 1
fi

if [[ "$VCN_MODE" == "existing" ]]; then
  : "${OKE_VCN_OCID:?OKE_VCN_OCID is required when OKE_VCN_MODE=existing}"
  : "${OKE_ENDPOINT_SUBNET_OCID:?OKE_ENDPOINT_SUBNET_OCID is required when OKE_VCN_MODE=existing}"
  : "${OKE_WORKER_SUBNET_OCID:?OKE_WORKER_SUBNET_OCID is required when OKE_VCN_MODE=existing}"
  : "${OKE_LB_SUBNET_OCID:?OKE_LB_SUBNET_OCID is required when OKE_VCN_MODE=existing}"
fi

echo "[INFO] Creating OKE cluster bootstrap resources (mode=${VCN_MODE})."

if [[ "$VCN_MODE" == "new" ]]; then
  OKE_DNS_LABEL="${OKE_DNS_LABEL:-oketf}"
  OKE_VCN_NAME="${OKE_VCN_NAME:-openclaw-oke-vcn}"
  OKE_IGW_NAME="${OKE_IGW_NAME:-openclaw-oke-igw}"
  OKE_ENDPOINT_SUBNET_NAME="${OKE_ENDPOINT_SUBNET_NAME:-openclaw-oke-endpoint-subnet}"
  OKE_WORKER_SUBNET_NAME="${OKE_WORKER_SUBNET_NAME:-openclaw-oke-worker-subnet}"
  OKE_LB_SUBNET_NAME="${OKE_LB_SUBNET_NAME:-openclaw-oke-lb-subnet}"

  if [[ "$APPLY" -eq 1 ]]; then
    OKE_VCN_OCID="$(oci network vcn create \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --cidr-block "$OKE_VCN_CIDR" \
      --display-name "$OKE_VCN_NAME" \
      --dns-label "$OKE_DNS_LABEL" \
      --region "$OCI_REGION" \
      --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
      --query 'data.id' --raw-output)"

    OKE_IGW_OCID="$(oci network internet-gateway create \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --vcn-id "$OKE_VCN_OCID" \
      --is-enabled true \
      --display-name "$OKE_IGW_NAME" \
      --region "$OCI_REGION" \
      --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
      --query 'data.id' --raw-output)"

    OKE_ROUTE_TABLE_OCID="$(oci network vcn get \
      --vcn-id "$OKE_VCN_OCID" \
      --region "$OCI_REGION" \
      --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
      --query 'data."default-route-table-id"' --raw-output)"

    oci network route-table update \
      --rt-id "$OKE_ROUTE_TABLE_OCID" \
      --force \
      --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$OKE_IGW_OCID\"}]" \
      --region "$OCI_REGION" \
      --profile "${OCI_CLI_PROFILE:-DEFAULT}" >/dev/null

    OKE_ENDPOINT_SUBNET_OCID="$(oci network subnet create \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --vcn-id "$OKE_VCN_OCID" \
      --cidr-block "$OKE_ENDPOINT_SUBNET_CIDR" \
      --display-name "$OKE_ENDPOINT_SUBNET_NAME" \
      --prohibit-public-ip-on-vnic false \
      --region "$OCI_REGION" \
      --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
      --query 'data.id' --raw-output)"

    OKE_WORKER_SUBNET_OCID="$(oci network subnet create \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --vcn-id "$OKE_VCN_OCID" \
      --cidr-block "$OKE_WORKER_SUBNET_CIDR" \
      --display-name "$OKE_WORKER_SUBNET_NAME" \
      --prohibit-public-ip-on-vnic false \
      --region "$OCI_REGION" \
      --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
      --query 'data.id' --raw-output)"

    OKE_LB_SUBNET_OCID="$(oci network subnet create \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --vcn-id "$OKE_VCN_OCID" \
      --cidr-block "$OKE_LB_SUBNET_CIDR" \
      --display-name "$OKE_LB_SUBNET_NAME" \
      --prohibit-public-ip-on-vnic false \
      --region "$OCI_REGION" \
      --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
      --query 'data.id' --raw-output)"
  else
    echo "+ oci network vcn create ..."
    echo "+ oci network internet-gateway create ..."
    echo "+ oci network subnet create (endpoint/worker/lb) ..."
    OKE_VCN_OCID="ocid1.vcn.oc1..replace"
    OKE_ENDPOINT_SUBNET_OCID="ocid1.subnet.oc1..replace-endpoint"
    OKE_WORKER_SUBNET_OCID="ocid1.subnet.oc1..replace-worker"
    OKE_LB_SUBNET_OCID="ocid1.subnet.oc1..replace-lb"
  fi
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ "$OKE_API_ENDPOINT_VISIBILITY" == "PUBLIC" ]]; then
  ENDPOINT_PUBLIC=true
else
  ENDPOINT_PUBLIC=false
fi

cat > "$TMP_DIR/endpoint-config.json" <<EOF
{
  "isPublicIpEnabled": ${ENDPOINT_PUBLIC},
  "subnetId": "$(json_escape "$OKE_ENDPOINT_SUBNET_OCID")"
}
EOF

cat > "$TMP_DIR/options.json" <<EOF
{
  "serviceLbSubnetIds": ["$(json_escape "$OKE_LB_SUBNET_OCID")"]
}
EOF

echo "[INFO] Creating OKE cluster: ${OKE_CLUSTER_NAME}"
if [[ "$APPLY" -eq 1 ]]; then
  OCI_CLUSTER_OCID="$(oci ce cluster create \
    --compartment-id "$OCI_COMPARTMENT_OCID" \
    --name "$OKE_CLUSTER_NAME" \
    --vcn-id "$OKE_VCN_OCID" \
    --kubernetes-version "$OKE_K8S_VERSION" \
    --endpoint-config "file://$TMP_DIR/endpoint-config.json" \
    --options "file://$TMP_DIR/options.json" \
    --region "$OCI_REGION" \
    --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
    --query 'data.id' --raw-output)"

  echo "[INFO] Waiting for cluster ACTIVE: $OCI_CLUSTER_OCID"
  oci ce cluster get \
    --cluster-id "$OCI_CLUSTER_OCID" \
    --region "$OCI_REGION" \
    --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
    --wait-for-state ACTIVE >/dev/null
else
  echo "+ oci ce cluster create --compartment-id ... --name ... --vcn-id ..."
  OCI_CLUSTER_OCID="ocid1.cluster.oc1..replace"
fi

if [[ -z "$OKE_NODE_IMAGE_OCID" ]]; then
  if [[ "$APPLY" -eq 1 ]]; then
    OKE_NODE_IMAGE_OCID="$(oci ce node-pool-options get \
      --node-pool-option-id all \
      --region "$OCI_REGION" \
      --profile "${OCI_CLI_PROFILE:-DEFAULT}" \
      --query 'data.sources[0].image-id' --raw-output)"
  else
    echo "+ oci ce node-pool-options get --node-pool-option-id all ..."
    OKE_NODE_IMAGE_OCID="ocid1.image.oc1..replace"
  fi
fi

echo "[INFO] Creating OKE node pool: ${OKE_NODEPOOL_NAME}"
if [[ "$APPLY" -eq 1 ]]; then
  oci ce node-pool create \
    --compartment-id "$OCI_COMPARTMENT_OCID" \
    --cluster-id "$OCI_CLUSTER_OCID" \
    --name "$OKE_NODEPOOL_NAME" \
    --kubernetes-version "$OKE_K8S_VERSION" \
    --node-shape "$OKE_NODE_SHAPE" \
    --node-shape-config "{\"ocpus\":${OKE_NODE_OCPUS},\"memoryInGBs\":${OKE_NODE_MEMORY_GB}}" \
    --node-source-details "{\"sourceType\":\"IMAGE\",\"imageId\":\"$OKE_NODE_IMAGE_OCID\"}" \
    --subnet-ids "[\"$OKE_WORKER_SUBNET_OCID\"]" \
    --size "$OKE_NODE_COUNT" \
    --region "$OCI_REGION" \
    --profile "${OCI_CLI_PROFILE:-DEFAULT}" >/dev/null
else
  echo "+ oci ce node-pool create --cluster-id "$OCI_CLUSTER_OCID" --size "$OKE_NODE_COUNT" ..."
fi

cat <<EOF
[INFO] OKE bootstrap done.
[INFO] Cluster OCID: ${OCI_CLUSTER_OCID}
[INFO] VCN OCID: ${OKE_VCN_OCID}
[INFO] Endpoint Subnet: ${OKE_ENDPOINT_SUBNET_OCID}
[INFO] Worker Subnet: ${OKE_WORKER_SUBNET_OCID}
[INFO] LB Subnet: ${OKE_LB_SUBNET_OCID}

[INFO] Update scripts/oci/gateway.env with:
OCI_CLUSTER_OCID=${OCI_CLUSTER_OCID}
OKE_VCN_OCID=${OKE_VCN_OCID}
OKE_ENDPOINT_SUBNET_OCID=${OKE_ENDPOINT_SUBNET_OCID}
OKE_WORKER_SUBNET_OCID=${OKE_WORKER_SUBNET_OCID}
OKE_LB_SUBNET_OCID=${OKE_LB_SUBNET_OCID}
EOF

if [[ "$APPLY" -eq 0 ]]; then
  echo "[INFO] Dry run only. Add --apply to execute commands."
fi
