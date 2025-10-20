#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-litellm}"
VAULT_ADDR_LOCAL="http://127.0.0.1:8200"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
POLICY_FILE="$(cd "$(dirname "$0")" && pwd)/vault-policy.hcl"

usage() {
  cat <<'EOF'
Usage:
  OPENROUTER_API_KEY=<key> ./init-vault-secrets.sh
  # or
  OPENROUTER_API_KEY=<key> DB_PASSWORD=<pwd> ./init-vault-secrets.sh
  # or (reads POSTGRES_PASSWORD from environment or .env file)
  ./scripts/generate-env.sh && ./init-vault-secrets.sh

Env vars:
  NS                 Namespace where Vault is installed (default: litellm)
  VAULT_TOKEN        Dev root token (default: root)
  OPENROUTER_API_KEY OpenRouter API key (required)
  DB_PASSWORD        Database password (optional, auto-detected from POSTGRES_PASSWORD or .env)
  POSTGRES_PASSWORD  Alternative to DB_PASSWORD (read from env or .env)

This script:
  - Waits for Vault to be ready and port-forwards to 8200
  - Enables KV v2 at secret/ (if needed)
  - Writes secret at secret/litellm/openrouter with field api-key
  - Writes secret at secret/litellm/database with field password
  - Creates policy litellm-policy allowing read of secret/data/litellm/*
  - Enables Kubernetes auth and configures it with the cluster
  - Creates role 'litellm-role' bound to SA 'litellm' in namespace $NS
EOF
}

# Pre-req checks
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
command -v helm >/dev/null || { echo "helm not found"; exit 1; }
command -v vault >/dev/null || { echo "vault CLI not found"; exit 1; }

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage; exit 0
fi

: "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY is required in environment}"

# Detect database password from multiple sources (precedence: DB_PASSWORD > POSTGRES_PASSWORD > .env)
DB_PASS="${DB_PASSWORD:-}"
if [[ -z "$DB_PASS" ]]; then
  DB_PASS="${POSTGRES_PASSWORD:-}"
fi
if [[ -z "$DB_PASS" ]] && [[ -f ".env" ]]; then
  echo "Loading database password from .env file..."
  # shellcheck disable=SC1091
  set +u  # Allow unset variables while sourcing
  source .env
  set -u
  DB_PASS="${POSTGRES_PASSWORD:-}"
fi

if [[ -z "$DB_PASS" ]]; then
  echo "Error: Database password not found. Please provide one of:" >&2
  echo "  - DB_PASSWORD environment variable" >&2
  echo "  - POSTGRES_PASSWORD environment variable" >&2
  echo "  - .env file with POSTGRES_PASSWORD" >&2
  echo "  - Run ./scripts/generate-env.sh first" >&2
  exit 1
fi

if [[ ${#DB_PASS} -lt 12 ]]; then
  echo "Warning: Database password is less than 12 characters (${#DB_PASS}). Recommend using ./scripts/generate-env.sh" >&2
fi

# Ensure Vault is ready
echo "Waiting for Vault pod to be ready..."
kubectl -n "$NS" wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=300s

# Port-forward Vault service
kubectl -n "$NS" port-forward svc/vault 8200:8200 >/tmp/vault-pf.log 2>&1 &
PF_PID=$!
cleanup() { kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for Vault to respond
export VAULT_ADDR="$VAULT_ADDR_LOCAL"
export VAULT_TOKEN
for i in {1..30}; do
  if vault status >/dev/null 2>&1; then break; fi
  sleep 1
done
vault status

# Enable kv-v2 if missing
if ! vault secrets list -format=json | jq -e 'has("secret/")' >/dev/null 2>&1; then
  vault secrets enable -path=secret kv-v2
fi

# Write secrets
echo "Storing OpenRouter API key in Vault..."
vault kv put secret/litellm/openrouter api-key="$OPENROUTER_API_KEY"

echo "Storing database password in Vault..."
vault kv put secret/litellm/database password="$DB_PASS"

# Policy
vault policy write litellm-policy "$POLICY_FILE"

# Kubernetes auth
if ! vault auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null 2>&1; then
  vault auth enable kubernetes
fi

# Configure Kubernetes auth with token reviewer JWT
# Prefer "vault" SA token; fallback to secret-based if token API not available
TOKEN_REVIEWER_JWT="$(kubectl -n "$NS" create token vault 2>/dev/null || true)"
if [[ -z "$TOKEN_REVIEWER_JWT" ]]; then
  SA_SECRET="$(kubectl -n "$NS" get sa vault -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)"
  if [[ -n "$SA_SECRET" ]]; then
    TOKEN_REVIEWER_JWT="$(kubectl -n "$NS" get secret "$SA_SECRET" -o go-template='{{ .data.token | base64decode }}')"
  fi
fi
KUBE_HOST="https://kubernetes.default.svc:443"
KUBE_CA="$(kubectl -n "$NS" get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')"

vault write auth/kubernetes/config \
  token_reviewer_jwt="$TOKEN_REVIEWER_JWT" \
  kubernetes_host="$KUBE_HOST" \
  kubernetes_ca_cert="$KUBE_CA"

# Role for litellm service account in litellm namespace
vault write auth/kubernetes/role/litellm-role \
  bound_service_account_names="litellm" \
  bound_service_account_namespaces="$NS" \
  policies="litellm-policy" \
  ttl="24h"

echo "[SUCCESS] Vault initialized with the following secrets:"
echo "  - secret/litellm/openrouter (api-key)"
echo "  - secret/litellm/database (password)"
echo "Policy and Kubernetes auth role configured."
