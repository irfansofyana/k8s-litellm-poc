#!/usr/bin/env bash
set -euo pipefail

echo "==> Pulling Helm charts locally..."

# Ensure Helm repo is added
if ! helm repo list | grep -q "^hashicorp"; then
  echo "Adding HashiCorp Helm repository..."
  helm repo add hashicorp https://helm.releases.hashicorp.com
fi

echo "Updating Helm repositories..."
helm repo update

# Create charts directory
mkdir -p charts

echo "Pulling HashiCorp Vault chart..."
helm pull hashicorp/vault --untar --untardir ./charts

echo "Pulling LiteLLM chart from OCI registry..."
helm pull oci://ghcr.io/berriai/litellm-helm --untar --untardir ./charts

echo ""
echo "==> Charts pulled successfully!"
echo ""
echo "Charts location:"
echo "  - ./charts/vault/"
echo "  - ./charts/litellm-helm/"
echo ""
echo "Chart versions:"
helm show chart ./charts/vault | grep -E "^(name|version|appVersion):"
echo "---"
helm show chart ./charts/litellm-helm | grep -E "^(name|version|appVersion):"
echo ""
echo "Next steps:"
echo "  1. kubectl create namespace litellm"
echo "  2. helm install vault ./charts/vault -n litellm -f vault/vault-values.yaml"
echo "  3. OPENROUTER_API_KEY=\"sk-or-...\" ./vault/init-vault-secrets.sh"
echo "  4. helm install litellm ./charts/litellm-helm -n litellm -f litellm/litellm-values.yaml"
