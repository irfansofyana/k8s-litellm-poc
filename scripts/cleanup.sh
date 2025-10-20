#!/usr/bin/env bash
set -euo pipefail
NS="${1:-litellm}"

echo "This will uninstall Helm releases (litellm, vault) in namespace '$NS' and optionally delete the namespace."
read -r -p "Continue? (y/N) " CONFIRM
[[ "${CONFIRM:-N}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

helm -n "$NS" uninstall litellm 2>/dev/null || echo "[INFO] litellm not installed."
helm -n "$NS" uninstall vault 2>/dev/null || echo "[INFO] vault not installed."

read -r -p "Delete namespace '$NS'? (y/N) " DELNS
[[ "${DELNS:-N}" =~ ^[Yy]$ ]] && kubectl delete ns "$NS" --wait=true || true

read -r -p "Remove Helm repo 'hashicorp'? (y/N) " DELREPO
if [[ "${DELREPO:-N}" =~ ^[Yy]$ ]]; then
  helm repo remove hashicorp 2>/dev/null || true
fi

echo "[SUCCESS] Cleanup complete."
