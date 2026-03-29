# OCI OKE Deployment (openclaw + oci-anthropic-gateway)

This repository is used to deploy the following components to OCI OKE:
- `oci-anthropic-gateway`: In-cluster gateway (integrates with OCI GenAI)
- `openclaw`: Upstream Anthropic-compatible application (calls gateway via in-cluster DNS)

## 1. Architecture (OKE)

### 1.1 Target Call Chain

```text
User -> openclaw (openclaw-prod) -> gateway (gateway-prod/ClusterIP) -> OCI GenAI (HTTPS)
Admin -> VPN/Bastion -> gateway /debug (Bearer Token)
```

### 1.2 Implementation Architecture (ASCII Diagram with Port Forwarding Access Path)

```text
Mac Browser/Terminal
  |  http://127.0.0.1:18789
  |
  +-- ssh -L 18789:127.0.0.1:18789 <user>@<oci-vm>                  (2.4-2)
  |
OCI VM (bastion/admin)
  |  kubectl -n openclaw-prod port-forward svc/openclaw 18789:18789 (2.4-1)
  |
  +-- forwards to ClusterIP svc/openclaw:18789 -> openclaw Pod
                         |
                         |(External access: no LoadBalancer)
                         |
                  (Cluster: OCI OKE)
+---------------------------------------------------------------------------+
|                                                                           |
|  Namespace: openclaw-prod                   Namespace: gateway-prod       |
|  +-----------------------------+           +---------------------------+ |
|  | Pod: openclaw-0             |           | Pod: oci-anthropic-gateway| |
|  |  - UI/Gateway :18789        |           |  - Anthropic API :8000     | |
|  |  - egress: only to gateway  |  HTTP     |  - WI -> OCI GenAI HTTPS   | |
|  +---------------+-------------+  :8000    +--------------+------------+ |
|                  |        via Cluster DNS/service          |              |
|                  |  http://oci-anthropic-gateway...:8000   |              |
|                  v                                         v              |
|          +-------------------+                   +--------------------+  |
|          | SVC openclaw      |                   | OCI Generative AI   |  |
|          |  ClusterIP :18789 |                   |  inference endpoint |  |
|          +---------+---------+                   +--------------------+  |
|                    |                                                       |
|          +---------v---------+                                             |
|          | SVC oci-anthropic |                                             |
|          | -gateway ClusterIP|                                             |
|          | :8000             |                                             |
|          +-------------------+                                             |
|                                                                           |
+---------------------------------------------------------------------------+


```

## 2. Quick Start

### 2.1 Prepare Configuration Files

```bash
cp scripts/oci/gateway.env.example scripts/oci/gateway.env
cp -f config.json.template config.json

vi scripts/oci/gateway.env
vi config.json
```

Required fields:
- `scripts/oci/gateway.env`: `OCI_REGION`, `OCI_COMPARTMENT_OCID`, `OCI_CLUSTER_OCID` (or leave empty to trigger cluster creation), `GATEWAY_IMAGE*`, `OCI_USERNAME`, `OCI_AUTH_TOKEN`, `DEBUG_UI_AUTH_TOKEN`
- `config.json`: `compartment_id`, `model_definitions.*.ocid`

> Note: If `OCI_AUTH_TOKEN` contains special characters, it must be enclosed in double quotes.

### 2.2 One-Click Deployment

```bash
# Deploy only (does not modify IAM by default)
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply

# Optional: Also create/update IAM Policy for Workload Identity
# Default mode is "all": gateway GenAI + OpenClaw workload-identity Object Storage policy
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --apply-iam-policy

# Use existing OKE (skip cluster creation)
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --skip-create-cluster

# If you already have an existing Dynamic Group for worker nodes, you can also apply
# the separate instance principal Object Storage policy for OpenClaw
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --apply-instance-principal-policy
```

### 2.3 Verification

```bash
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env
```

### 2.4 Access OpenClaw UI (SSH Scenario / Mac Access)

1) Start port-forward on OCI VM (bastion/admin) (recommended to run in foreground or use tmux/screen):
```bash
kubectl -n openclaw-prod port-forward svc/openclaw 18789:18789
```
Access on the VM: `http://127.0.0.1:18789`

2) Access from Mac (SSH local port forwarding):
```bash
ssh -N -L 18789:127.0.0.1:18789 ubuntu@<VM_PUBLIC_IP_OR_REACHABLE_ADDRESS>
```
Then open in Mac browser: `http://127.0.0.1:18789`

### 2.5 Get OpenClaw UI Token (for UI Login/Control)

```bash
kubectl -n openclaw-prod exec openclaw-0 -c cli -- cat /home/node/.openclaw/gateway-token
```

> Security Note: This token is equivalent to UI session credentials. Use only in controlled terminals and rotate when necessary.

## 3. Common Commands

```bash
# Gateway deployment (can be run independently)
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --apply

# OpenClaw deployment (optional)
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply

# IAM policy (Workload Identity, default mode: all)
bash scripts/oci/11_workload_identity_policy.sh create-or-update --env scripts/oci/gateway.env

# IAM policy (OpenClaw instance principal Object Storage; requires an existing Dynamic Group)
bash scripts/oci/12_openclaw_instance_principal_policy.sh create-or-update --env scripts/oci/gateway.env

# Dynamic Group helper for quick experiments (requires IAM permission; default matching rule uses OCI_COMPARTMENT_OCID)
bash scripts/oci/12a_openclaw_instance_principal_dynamic_group.sh create-or-update --env scripts/oci/gateway.env

# Cleanup gateway (optional)
bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env --apply
```

## 4. OpenClaw OCI CLI authentication notes

- Gateway and OpenClaw are now documented as two separate OCI access paths:
  - gateway: OKE Workload Identity / OCI SDK path
  - openclaw pod OCI CLI: instance principal path for current cluster experiments
- `scripts/oci/gateway.env` supports:
  - `OPENCLAW_OCI_CLI_AUTH_MODE=instance_principal`
- In the current verified cluster state:
  - `oci` wrapper exists at `/home/node/.openclaw/bin/oci`
  - `/home/node/.openclaw/bin/oci os ns get` succeeds
  - `/home/node/.openclaw/bin/oci os bucket list --compartment-id <OCI_COMPARTMENT_OCID>` succeeds
  - test bucket creation via instance principal also succeeded
- Note: an interactive `kubectl exec ... sh -lc` shell may reset `PATH` and resolve `oci` to `/usr/local/bin/oci` instead of the wrapper. In that case either:
  - run `/home/node/.openclaw/bin/oci ...`, or
  - explicitly add `--auth instance_principal`

## 5. Documentation

## 4. Documentation
- Troubleshooting: `docs/troubleshooting.md`
- IAM / Workload Identity: `docs/iam-workload-identity.md`
- Go-Live checklist: `docs/go-live-checklist.md`
- Local Docker: `docs/local-docker.md` (detailed steps in `local-docker/README.md`)
- Archive (historical records/planning drafts): `docs/archive/`

## 5. Related Files
- `scripts/oci/gateway.env.example` / `scripts/oci/gateway.env`
- `config.json.template` / `config.json`
- `k8s/` (Kubernetes manifests)
- `local-docker/`

## License

This project is licensed under the [Apache License 2.0](LICENSE).

```
Copyright 2024 Contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
