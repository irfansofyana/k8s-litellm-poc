# k8s-litellm-poc

A POC for deploying LiteLLM Proxy on Kubernetes using the official LiteLLM Helm chart with HashiCorp Vault Agent Injector for secret management. Model configuration is stored in a Kubernetes ConfigMap, while secrets (API keys, master key, database credentials) are injected by Vault Agent as environment variables.

## TL;DR - Quick Deploy

```bash
# 0. Generate .env with secure credentials
./scripts/generate-env.sh
# Edit .env and set your actual OPENROUTER_API_KEY

# 1. Start local database
docker compose up -d

# 2. Create namespace
kubectl create namespace litellm

# 3. Install Vault
helm install vault ./charts/vault -n litellm -f vault/vault-values.yaml
kubectl -n litellm wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=300s

# 4. Initialize Vault with secrets from .env (stores all secrets: OpenRouter API key, database password, and master key)
./vault/init-vault-secrets.sh

# 5. Deploy LiteLLM
helm install litellm ./charts/litellm-helm -n litellm -f litellm/litellm-values.yaml
kubectl -n litellm rollout status deploy/litellm --timeout=300s

# 6. Test
kubectl -n litellm port-forward svc/litellm 4000:4000 &
source .env
curl http://127.0.0.1:4000/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai-gpt-4","messages":[{"role":"user","content":"Hello!"}]}'
```

## Prerequisites
- A local Kubernetes cluster (OrbStack, Kind, Minikube, Docker Desktop, k3d, etc.)
- Docker and Docker Compose (for local PostgreSQL)
- kubectl, Helm 3.8+, vault CLI, openssl
- jq (optional, for testing)
- OpenRouter API key from https://openrouter.ai/keys
- Helm charts are included in the repository (no need to pull separately)

## Environment Variables

All secrets are stored in a `.env` file. Use `./scripts/generate-env.sh` to create one with secure random passwords.

**Example `.env` file:**
```bash
# PostgreSQL password for docker-compose
POSTGRES_PASSWORD=your-secure-40-character-password-here

# LiteLLM master key for API authentication
LITELLM_MASTER_KEY=your-secure-40-character-master-key-here

# OpenRouter API key - Get yours from https://openrouter.ai/keys
OPENROUTER_API_KEY=sk-or-v1-your-actual-openrouter-api-key-here
```

The `generate-env.sh` script creates this file with random passwords and a placeholder for your OpenRouter API key.

## Architecture

This POC deploys:
- **HashiCorp Vault** (dev mode) with Agent Injector
- **LiteLLM Proxy** with OpenRouter integration
- **ConfigMap** holds model configuration (`config.yaml`) mounted at `/etc/litellm/config.yaml`
- **Vault Agent Injector** renders `/vault/secrets/app-credentials.sh` exporting secrets as environment variables
- **Secret management** via Vault KV v2 at `secret/litellm/secrets` storing:
  - `master_key` (LiteLLM proxy master key)
  - `openrouter_api_key` (OpenRouter API key)
  - `db_password` (PostgreSQL password)

## Quick start

### 1) Setup local database

**Generate secure credentials:**

```bash
# Generate .env with secure 40-character passwords and placeholder for OpenRouter API key
./scripts/generate-env.sh

# Edit .env and replace the OpenRouter API key placeholder with your actual key
# Get your key from https://openrouter.ai/keys
vim .env  # or use your preferred editor
```

The `.env` file will contain:
- `POSTGRES_PASSWORD` - 40-character random password for PostgreSQL
- `LITELLM_MASTER_KEY` - 40-character random master key for LiteLLM
- `OPENROUTER_API_KEY` - Placeholder that you must replace with your actual key

**Start PostgreSQL:**

```bash
# Start PostgreSQL (reads POSTGRES_PASSWORD from .env)
docker compose up -d

# Verify database is healthy
docker compose ps
```

**Note:** If you're using an external PostgreSQL instance instead of Docker Compose, you can skip `docker compose up -d`, but you must still have all three secrets in your `.env` file so that Vault can be populated.

### 2) Create namespace

```bash
kubectl create namespace litellm
```

### 3) Install Vault (dev mode) with Injector

```bash
helm install vault ./charts/vault -n litellm -f vault/vault-values.yaml
kubectl -n litellm wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=300s
```

### 4) Initialize Vault and store secrets

```bash
# Reads all secrets from .env file
./vault/init-vault-secrets.sh
```

This script:
- Loads all secrets from your `.env` file (OPENROUTER_API_KEY, POSTGRES_PASSWORD, LITELLM_MASTER_KEY)
- Enables KV v2 secrets engine at `secret/`
- Stores all secrets at `secret/litellm/secrets` (fields: `openrouter_api_key`, `master_key`, `db_password`)
- Creates policy `litellm-policy` for read access
- Configures Kubernetes auth and creates role `litellm-role`

**Note:** All secrets are now sourced from the `.env` file. No need to export individual environment variables.

### 5) Deploy LiteLLM

```bash
helm install litellm ./charts/litellm-helm -n litellm -f litellm/litellm-values.yaml
kubectl -n litellm rollout status deploy/litellm --timeout=300s
```

**What happens:**
- Chart creates a ConfigMap with model configuration from `proxy_config` values
- ConfigMap is mounted at `/etc/litellm/config.yaml`
- Vault Agent injects `/vault/secrets/app-credentials.sh` with secrets (master key, API keys, database URL)
- Container sources `app-credentials.sh` and runs `litellm --config /etc/litellm/config.yaml`

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

### 7) Verify setup

```bash
# Check that app-credentials.sh was injected by Vault Agent
kubectl -n litellm exec deploy/litellm -c litellm -- cat /vault/secrets/app-credentials.sh

# Check ConfigMap-mounted config
kubectl -n litellm exec deploy/litellm -c litellm -- cat /etc/litellm/config.yaml

# Check pod has vault-agent sidecar
kubectl -n litellm get pods -o jsonpath='{.items[0].spec.containers[*].name}'
# Should show: vault-agent litellm
```

## Design notes

### Configuration Management
- **Model configuration** stored in Kubernetes ConfigMap (from `proxy_config` in Helm values)
- ConfigMap mounted at `/etc/litellm/config.yaml`
- Config references secrets via `os.environ/VARIABLE_NAME` (e.g., `os.environ/PROXY_MASTER_KEY`)
- Easy to update models by changing Helm values and upgrading

### Secret Management
- All secrets stored securely in Vault at a single path: `secret/litellm/secrets`
  - `master_key` - LiteLLM proxy master key
  - `openrouter_api_key` - OpenRouter API key  
  - `db_password` - PostgreSQL password
- Vault Agent injects `/vault/secrets/app-credentials.sh` which exports:
  - `PROXY_MASTER_KEY` - from `master_key`
  - `OPENROUTER_API_KEY` - from `openrouter_api_key`
  - `DATABASE_URL` - constructed from `db_password`
- Container sources `app-credentials.sh` before starting LiteLLM
- No secrets in plain text in ConfigMaps
- When `vault.enabled=true`, no Kubernetes Secrets are created for master key

### Local Charts
- Charts are included in the repository in the `charts/` directory
- No need to pull charts separately - ready for offline deployment

## E2E verification (LiteLLM -> Postgres via Docker Compose)

1) Ensure local Postgres is running and healthy
```bash
docker compose ps
```

2) Verify pod-to-host connectivity
```bash
kubectl -n litellm run netcheck --rm -i --image=alpine:3.20 -- sh -c 'apk add --no-cache busybox-extras && nc -zv host.docker.internal 5432'
```

3) Port-forward LiteLLM and send a test request
```bash
kubectl -n litellm port-forward svc/litellm 4000:4000 &

# Load master key from .env
source .env

curl -sS http://127.0.0.1:4000/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai-gpt-4",
    "messages": [{"role": "user", "content": "Say hello from LiteLLM connected to Postgres."}]
  }' | jq -r '.id, .choices[0].message.content'
```

4) Confirm rows are written to Postgres
```bash
source .env
psql "postgresql://llmproxy:${POSTGRES_PASSWORD}@localhost:5432/litellm" \
  -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY 1;" \
  -c "SELECT table_name, n_live_tup AS row_count FROM pg_stat_user_tables ORDER BY row_count DESC LIMIT 10;"
```

Notes
- Vault Agent injects `/vault/secrets/app-credentials.sh` which exports all secrets as environment variables
- ConfigMap provides `/etc/litellm/config.yaml` with model configuration
- The container command sources `app-credentials.sh`, then runs:
  - `litellm --config /etc/litellm/config.yaml --port 4000`
- No Kubernetes Secrets are created when `vault.enabled=true`; all secrets rendered from Vault at runtime

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
vault kv get secret/litellm/secrets
```

### Testing specific models

List available models:
```bash
source .env
curl -sS http://127.0.0.1:4000/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.data[].id'
```

Test Claude:
```bash
source .env
curl -sS http://127.0.0.1:4000/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-3-opus",
    "messages": [{"role": "user", "content": "Hi Claude!"}]
  }' | jq
```

## Upgrading deployments

To upgrade existing deployments with updated values:
```bash
helm upgrade vault ./charts/vault -n litellm -f vault/vault-values.yaml
helm upgrade litellm ./charts/litellm-helm -n litellm -f litellm/litellm-values.yaml
```

## Adding more models

Edit `litellm/litellm-values.yaml` and add models to the `proxy_config` section:

```yaml
proxy_config:
  general_settings:
    master_key: os.environ/PROXY_MASTER_KEY
  model_list:
    # ... existing models ...
    - model_name: gemini-pro
      litellm_params:
        model: openrouter/google/gemini-pro
        api_base: https://openrouter.ai/api/v1
        api_key: os.environ/OPENROUTER_API_KEY
```

Then upgrade:
```bash
helm upgrade litellm ./charts/litellm-helm -n litellm -f litellm/litellm-values.yaml
```

The chart will update the ConfigMap and restart the pods automatically.

## Production considerations

⚠️ **This is a POC setup. For production:**

1. **Vault**: Use persistent storage, HA mode, proper TLS, and real authentication (not dev mode)
2. **Secrets**: Rotate keys regularly using Vault's secret rotation features
3. **Resources**: Adjust CPU/memory limits based on load
4. **Monitoring**: Add Prometheus/Grafana for metrics
5. **Database**: Use managed PostgreSQL (AWS RDS, Cloud SQL, etc.) for production
6. **Redis**: Enable for rate limiting and caching
7. **Ingress**: Add proper ingress with TLS termination
8. **Network Policies**: Restrict pod-to-pod communication
9. **RBAC**: Tighten service account permissions

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
├── DATABASE.md                    # PostgreSQL setup documentation
├── .gitignore                     # Git ignore (charts/, .env, logs, etc.)
├── .env                           # Secrets file (generated by generate-env.sh, not in git)
├── docker-compose.yml             # Local PostgreSQL database
├── vault/
│   ├── vault-values.yaml          # Vault Helm values (dev mode + injector)
│   ├── vault-policy.hcl           # Vault policy for LiteLLM
│   └── init-vault-secrets.sh      # Script to initialize Vault secrets
├── litellm/
│   ├── litellm-values.yaml        # LiteLLM Helm values (proxy_config + Vault annotations)
│   └── config.yaml                # Reference config (documentation only)
├── scripts/
│   ├── generate-env.sh            # Generate secure .env file
│   └── cleanup.sh                 # Cleanup script
└── charts/                        # Helm charts included in repository
    ├── vault/
    └── litellm-helm/
```
