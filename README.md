# k8s-litellm-poc

A POC for deploying LiteLLM Proxy on Kubernetes using the official LiteLLM Helm chart with HashiCorp Vault Agent Injector for secret injection. Config is rendered by Vault Agent from inline Helm values (no ConfigMap volume).

## TL;DR - Quick Deploy

```bash
# 0. Generate .env and start local database
./scripts/generate-env.sh
docker compose up -d

# 1. Create namespace
kubectl create namespace litellm

# 2. Install Vault
helm install vault ./charts/vault -n litellm -f vault/vault-values.yaml
kubectl -n litellm wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=300s

# 3. Initialize Vault with secrets (stores OpenRouter API key, database password, and master key)
export OPENROUTER_API_KEY="sk-or-v1-..."
./vault/init-vault-secrets.sh

# 4. Deploy LiteLLM
helm install litellm ./charts/litellm-helm -n litellm -f litellm/litellm-values.yaml
kubectl -n litellm rollout status deploy/litellm --timeout=300s

# 5. Test
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
- OpenRouter API key
- Helm charts are included in the repository (no need to pull separately)

## Architecture

This POC deploys:
- **HashiCorp Vault** (dev mode) with Agent Injector
- **LiteLLM Proxy** with OpenRouter integration
- **Vault Agent Injector** renders config.yaml from inline Helm values template (no ConfigMap volume)
- **Secret management** via Vault KV v2 at `secret/litellm/openrouter`

## Quick start

### 1) Setup local database

**Generate secure credentials and start PostgreSQL:**

```bash
# Generate .env with a secure 40-character password
./scripts/generate-env.sh

# Start PostgreSQL (reads POSTGRES_PASSWORD from .env)
docker compose up -d

# Verify database is healthy
docker compose ps
```

**Note:** If you're using an external PostgreSQL instance instead of Docker Compose, you can skip `docker compose up -d`, but you must still provide the database password via `DB_PASSWORD`, `POSTGRES_PASSWORD`, or `.env` file so that Vault can be populated with the secret.

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
export OPENROUTER_API_KEY="sk-or-v1-..."
./vault/init-vault-secrets.sh
```

This script:
- Enables KV v2 secrets engine at `secret/`
- Stores combined app secrets at `secret/litellm/secretapps` (JSON fields: `openrouter_api_key`, `master_key`)
- Stores database password at `secret/litellm/database` (field: `password`)
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
- All secrets stored securely in Vault:
  - Combined app secrets at `secret/litellm/secretapps` (fields: `openrouter_api_key`, `master_key`)
  - Database password at `secret/litellm/database` (field: `password`)
- Vault Agent injects secrets directly into config.yaml and database env using template functions
- No secrets in plain text in ConfigMaps or environment variables

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
- Vault Agent injects two files into the LiteLLM pod under /vault/secrets:
  - config.yaml (OpenRouter models)
  - db_env.sh (exports DATABASE_URL)
- The container entrypoint is overridden to source db_env.sh, then run:
  - `litellm --config /vault/secrets/config.yaml --port 4000`
- No Kubernetes Secret is used for the database URL; it’s rendered from Vault at runtime.

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
vault kv get secret/litellm/secretapps
vault kv get secret/litellm/database
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

Edit `litellm/litellm-values.yaml` and add models to the Vault template:

```yaml
vault.hashicorp.com/agent-inject-template-litellm-config: |
  {{- with secret "secret/data/litellm/secretapps" -}}
  # ... existing config ...
  model_list:
    # ... existing models ...
    - model_name: gemini-pro
      litellm_params:
        model: openrouter/google/gemini-pro
        api_base: https://openrouter.ai/api/v1
        api_key: "{{ index .Data.data "openrouter_api_key" }}"
  {{- end -}}
```

Then upgrade:
```bash
helm upgrade litellm ./charts/litellm-helm -n litellm -f litellm/litellm-values.yaml
```

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
├── .env.example                   # Template for environment variables
├── docker-compose.yml             # Local PostgreSQL database
├── vault/
│   ├── vault-values.yaml          # Vault Helm values (dev mode + injector)
│   ├── vault-policy.hcl           # Vault policy for LiteLLM
│   └── init-vault-secrets.sh      # Script to initialize Vault secrets
├── litellm/
│   ├── litellm-values.yaml        # LiteLLM Helm values with Vault annotations
│   └── config.yaml                # Reference config (not mounted)
├── scripts/
│   ├── generate-env.sh            # Generate secure .env file
│   └── cleanup.sh                 # Cleanup script
└── charts/                        # Helm charts included in repository
    ├── vault/
    └── litellm-helm/
```
