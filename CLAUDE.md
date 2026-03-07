# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **deployment repository** for deploying two systems to OCI OKE (Oracle Cloud Infrastructure Kubernetes Engine):
- **openclaw**: Upstream Anthropic-compatible application
- **oci-anthropic-gateway**: Gateway that proxies requests to OCI Generative AI

The repository contains only deployment assets: Kubernetes manifests, shell scripts, and documentation. Source code and image building happen in external repositories.

## Architecture

```
User Request → openclaw (OKE) → gateway (OKE ClusterIP) → OCI GenAI (HTTPS)
Admin → VPN/Bastion → gateway /debug (Bearer Token)
```

The gateway uses internal cluster DNS (`oci-anthropic-gateway.gateway-prod.svc.cluster.local:8000`) and is not exposed publicly by default.

## Prerequisites

Required CLI tools:
- `oci` - OCI CLI
- `kubectl` - Kubernetes CLI
- `docker` - For building gateway images (if using build mode)

## Key Commands

### All-in-one deployment
```bash
# Dry run (preview changes)
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env

# Apply changes
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply

# Skip cluster creation (use existing OKE)
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --skip-create-cluster
```

### Step-by-step deployment
```bash
# 1. Generate kubeconfig
bash scripts/oci/01_prepare_oke_kubeconfig.sh scripts/oci/gateway.env --apply

# 2. Deploy gateway
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --apply

# 3. Deploy openclaw (optional)
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply

# 4. Verify deployment
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env

# 5. Cleanup (optional)
bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env --apply
```

### Manual kubectl verification
```bash
kubectl -n gateway-prod get pods,svc
kubectl -n gateway-prod logs deploy/oci-anthropic-gateway --tail=200
kubectl -n openclaw-prod get svc openclaw-public -o wide
```

## Configuration Files

### Environment Configuration
- `scripts/oci/gateway.env.example` - Template for environment variables
- `scripts/oci/gateway.env` - Actual configuration (gitignored, create from example)

Required parameters to replace:
- `OCI_REGION`, `OCI_COMPARTMENT_OCID`, `OCI_CLUSTER_OCID`
- `GATEWAY_IMAGE` (or use `GATEWAY_IMAGE_MODE=build` with `GATEWAY_REPO_DIR`)
- `OCI_USERNAME`, `OCI_AUTH_TOKEN` (OCIR credentials)
- `DEBUG_UI_AUTH_TOKEN` (Bearer token for /debug endpoint)

### Gateway Runtime Configuration
- `config.json.template` - Template for gateway config
- `config.json` - Actual config (gitignored, create from template)

Must fill in:
- `compartment_id`
- `model_definitions.*.ocid` - OCI GenAI model OCIDs

## Kubernetes Manifests (k8s/)

Applied in order:
1. `00-namespace.yaml` - Creates `gateway-prod` namespace
2. `01-configmap-gateway-config.yaml` - Gateway config.json
3. `02-secret-debug-auth.yaml` - DEBUG_UI_AUTH_TOKEN secret
4. `03-secret-oci-sdk.yaml` - OCI SDK credentials
5. `04-deployment.yaml` - Gateway deployment (2 replicas)
6. `05-service-internal-lb.yaml` - ClusterIP service
7. `05b-service-public-lb-whitelist.yaml` - Optional public LB with whitelist
8. `06-networkpolicy-egress-template.yaml` - Egress restriction (DNS + HTTPS only)

## Important Notes

- All deployment scripts support dry-run mode (omit `--apply` flag)
- Gateway egress is restricted to DNS (port 53) and HTTPS (port 443) via NetworkPolicy
- `/debug` endpoint requires Bearer token authentication
- Use `PUBLIC_ENDPOINT` for kubeconfig when running from outside OCI private network
- Values with special characters in `gateway.env` must be quoted (e.g., `OCI_AUTH_TOKEN`)
