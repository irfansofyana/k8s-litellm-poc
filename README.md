# k8s-litellm-poc

A POC for deploying LiteLLM Proxy on Kubernetes using the official LiteLLM Helm chart with HashiCorp Vault Agent Injector for secret injection. Config is rendered by Vault Agent from inline Helm values (no ConfigMap volume).

## TL;DR - Quick Deploy

```bash
# 1. Pull charts locally
./scripts/pull-charts.sh

# 2. Create namespace
kubectl create namespace litellm

# 3. Install Vault
helm install vault ./charts/vault -n litellm -f vault/vault-values.yaml
kubectl -n litellm wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=300s

# 4. Initialize Vault (replace with your OpenRouter API key)
export OPENROUTER_API_KEY="sk-or-v1-..."
./vault/init-vault-secrets.sh

# 5. Deploy LiteLLM
helm install litellm ./charts/litellm-helm -n litellm -f litellm/litellm-values.yaml
kubectl -n litellm rollout status deploy/litellm --timeout=300s

# 6. Test
kubectl -n litellm port-forward svc/litellm 4000:4000 &
curl http://127.0.0.1:4000/chat/completions \
  -H "Authorization: Bearer poc-master-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai-gpt-4","messages":[{"role":"user","content":"Hello!"}]}'
```

## Prerequisites
- A local Kubernetes cluster (OrbStack, Kind, Minikube, Docker Desktop, k3d, etc.)
- kubectl, Helm 3.8+, vault CLI, jq
- OpenRouter API key

## Architecture

This POC deploys:
- **HashiCorp Vault** (dev mode) with Agent Injector
- **LiteLLM Proxy** with OpenRouter integration
- **Vault Agent Injector** renders config.yaml from inline Helm values template (no ConfigMap volume)
- **Secret management** via Vault KV v2 at `secret/litellm/openrouter`

## Quick start

### 1) Pull Helm charts locally

**Option A: Use the helper script (recommended)**

```bash
./scripts/pull-charts.sh
```

**Option B: Manual pull**

```bash
# Add Vault Helm repository
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Pull both charts to local directory
mkdir -p charts
helm pull hashicorp/vault --untar --untardir ./charts
helm pull oci://ghcr.io/berriai/litellm-helm --untar --untardir ./charts
```

This creates:
- `charts/vault/` - HashiCorp Vault chart
- `charts/litellm-helm/` - LiteLLM chart

### 2) Create namespace

```bash
kubectl create namespace litellm
```

### 3) Install Vault (dev mode) with Injector

```bash
helm install vault ./charts/vault -n litellm -f vault/vault-values.yaml
kubectl -n litellm wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=300s
```

### 4) Initialize Vault and store OpenRouter API key

```bash
export OPENROUTER_API_KEY="sk-or-v1-..."
./vault/init-vault-secrets.sh
```

This script:
- Enables KV v2 secrets engine at `secret/`
- Stores OpenRouter API key at `secret/litellm/openrouter`
- Creates policy `litellm-policy` for read access
- Configures Kubernetes auth and creates role `litellm-role`

### 5) Deploy LiteLLM with inline config (no ConfigMap mount)

```bash
helm install litellm ./charts/litellm-helm -n litellm -f litellm/litellm-values.yaml
kubectl -n litellm rollout status deploy/litellm --timeout=300s
```

### 6) Test the proxy

```bash
# Port-forward to access LiteLLM
kubectl -n litellm port-forward svc/litellm 4000:4000
```

In another terminal, send a test request:
```bash
curl -sS http://127.0.0.1:4000/chat/completions \
  -H "Authorization: Bearer poc-master-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai-gpt-4",
    "messages": [{"role": "user", "content": "Hello via OpenRouter + LiteLLM!"}]
  }' | jq
```

### 7) Verify Vault injection

```bash
# Check that config.yaml was injected by Vault Agent
kubectl -n litellm exec deploy/litellm -c litellm -- cat /vault/secrets/config.yaml

# Check pod has vault-agent sidecar
kubectl -n litellm get pods -o jsonpath='{.items[0].spec.containers[*].name}'
# Should show: vault-agent litellm
```

## Design notes

### No ConfigMap Volume Mount
- The full LiteLLM config is embedded in Helm values as a Vault Agent template
- Vault Agent Injector renders it to `/vault/secrets/config.yaml` at pod startup
- No separate ConfigMap resource or volume mount needed

### Secret Management
- OpenRouter API key stored in Vault at `secret/litellm/openrouter`
- Vault Agent injects the key directly into config.yaml using template functions
- No secrets in plain text in ConfigMaps or environment variables

### Local Charts
- Charts are pulled locally to `charts/` directory for offline deployment
- Version control friendly (add `charts/` to `.gitignore`)
- No internet dependency after initial pull

## Troubleshooting

### LiteLLM pod not starting

Check Vault Agent injection:
```bash
kubectl -n litellm describe pod -l app.kubernetes.io/name=litellm
```

Check logs:
```bash
# Vault Agent logs
kubectl -n litellm logs deploy/litellm -c vault-agent

# LiteLLM logs
kubectl -n litellm logs deploy/litellm -c litellm
```

### Config not rendered

Verify Vault role and policy:
```bash
# Port-forward to Vault
kubectl -n litellm port-forward svc/vault 8200:8200

# In another terminal
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root

vault read auth/kubernetes/role/litellm-role
vault policy read litellm-policy
vault kv get secret/litellm/openrouter
```

### Testing specific models

List available models:
```bash
curl -sS http://127.0.0.1:4000/models \
  -H "Authorization: Bearer poc-master-key" | jq '.data[].id'
```

Test Claude:
```bash
curl -sS http://127.0.0.1:4000/chat/completions \
  -H "Authorization: Bearer poc-master-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-3-opus",
    "messages": [{"role": "user", "content": "Hi Claude!"}]
  }' | jq
```

## Updating charts

Pull latest versions:
```bash
rm -rf charts/vault charts/litellm-helm
helm pull hashicorp/vault --untar --untardir ./charts
helm pull oci://ghcr.io/berriai/litellm-helm --untar --untardir ./charts

# Upgrade deployments
helm upgrade vault ./charts/vault -n litellm -f vault/vault-values.yaml
helm upgrade litellm ./charts/litellm-helm -n litellm -f litellm/litellm-values.yaml
```

## Adding more models

Edit `litellm/litellm-values.yaml` and add models to the Vault template:

```yaml
vault.hashicorp.com/agent-inject-template-litellm-config: |
  {{- with secret "secret/data/litellm/openrouter" -}}
  # ... existing config ...
  model_list:
    # ... existing models ...
    - model_name: gemini-pro
      litellm_params:
        model: openrouter/google/gemini-pro
        api_base: https://openrouter.ai/api/v1
        api_key: "{{ index .Data.data "api-key" }}"
  {{- end -}}
```

Then upgrade:
```bash
helm upgrade litellm ./charts/litellm-helm -n litellm -f litellm/litellm-values.yaml
```

## Production considerations

⚠️ **This is a POC setup. For production:**

1. **Vault**: Use persistent storage, HA mode, proper TLS, and real authentication (not dev mode)
2. **Secrets**: Use Vault's dynamic secrets or rotate keys regularly
3. **Master Key**: Store `LITELLM_MASTER_KEY` in Vault, not hardcoded
4. **Resources**: Adjust CPU/memory limits based on load
5. **Monitoring**: Add Prometheus/Grafana for metrics
6. **Database**: Enable PostgreSQL for request logging and caching
7. **Redis**: Enable for rate limiting and caching
8. **Ingress**: Add proper ingress with TLS termination
9. **Network Policies**: Restrict pod-to-pod communication
10. **RBAC**: Tighten service account permissions

## Cleanup

```bash
./scripts/cleanup.sh
```

This will:
- Uninstall litellm and vault Helm releases
- Optionally delete the `litellm` namespace
- Optionally remove the `hashicorp` Helm repository

## Project structure

```
k8s-litellm-poc/
├── README.md                      # This file
├── .gitignore                     # Git ignore (charts/, logs, etc.)
├── vault/
│   ├── vault-values.yaml          # Vault Helm values (dev mode + injector)
│   ├── vault-policy.hcl           # Vault policy for LiteLLM
│   └── init-vault-secrets.sh      # Script to initialize Vault
├── litellm/
│   ├── litellm-values.yaml        # LiteLLM Helm values with Vault annotations
│   └── config.yaml                # Reference config (not mounted)
├── scripts/
│   ├── pull-charts.sh             # Script to pull Helm charts locally
│   └── cleanup.sh                 # Cleanup script
└── charts/                        # Local Helm charts (gitignored)
    ├── vault/
    └── litellm-helm/
```
