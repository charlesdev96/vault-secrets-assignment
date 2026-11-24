#!/bin/bash
# vault-config.sh
# Configures Vault AFTER it has been installed with Helm.
#
# Run it from the project folder:   bash vault-setup/vault-config.sh
# (On Windows use Git Bash or WSL.)
#
# What it does:
#   1. Enables the KV v2 secrets engine at secret/
#   2. Stores a sample secret at secret/app/database
#   3. Enables the Kubernetes auth method
#   4. Creates the policy app-read-policy
#   5. Creates a Kubernetes auth role that links the ServiceAccount to the policy

set -e                       # stop the script if any command fails
export MSYS_NO_PATHCONV=1    # stops Git Bash on Windows from rewriting paths

# ---- Names used in this lab (they must match app-deployment.yaml) ----
VAULT_NS="vault"
APP_NS="app"
SA_NAME="app-sa"
ROLE_NAME="app-role"
POLICY_NAME="app-read-policy"
ROOT_TOKEN="root"            # the dev-mode root token from vault-values.yaml

# Run a vault command inside the vault-0 pod
vault_cmd() {
  kubectl exec -n "$VAULT_NS" vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" vault "$@"
}

echo "Waiting for the vault-0 pod to be ready..."
kubectl wait --for=condition=Ready pod/vault-0 -n "$VAULT_NS" --timeout=180s

# ---------------------------------------------------------------
echo ""
echo "STEP 1: Enable the KV v2 secrets engine at secret/"
# Dev mode already creates a KV v2 engine at secret/, so we only enable it if it is missing.
if vault_cmd secrets list | grep -q "^secret/"; then
  echo "  secret/ already exists (dev mode creates it), nothing to do"
else
  vault_cmd secrets enable -path=secret kv-v2
fi

# ---------------------------------------------------------------
echo ""
echo "STEP 2: Store the sample database secret at secret/app/database"
vault_cmd kv put secret/app/database username=dbadmin password=ChangeMe-Sample-123

# ---------------------------------------------------------------
echo ""
echo "STEP 3: Enable the Kubernetes auth method"
if vault_cmd auth list | grep -q "^kubernetes/"; then
  echo "  kubernetes auth is already enabled"
else
  vault_cmd auth enable kubernetes
fi

# Tell Vault where the Kubernetes API is. Vault runs inside the cluster, so it
# uses its own ServiceAccount token and the cluster CA certificate automatically.
vault_cmd write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"

# ---------------------------------------------------------------
echo ""
echo "STEP 4: Create the policy $POLICY_NAME (read-only on secret/data/app/*)"
# -i lets us pass the policy text to the command through standard input
kubectl exec -i -n "$VAULT_NS" vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" vault policy write "$POLICY_NAME" - <<'POLICY'
path "secret/data/app/*" {
  capabilities = ["read"]
}
POLICY

# ---------------------------------------------------------------
echo ""
echo "STEP 5: Create the Kubernetes auth role $ROLE_NAME"
# Only pods that run as ServiceAccount app-sa in namespace app can use this role,
# and they get the policy above (and nothing else).
vault_cmd write auth/kubernetes/role/"$ROLE_NAME" \
  bound_service_account_names="$SA_NAME" \
  bound_service_account_namespaces="$APP_NS" \
  policies="$POLICY_NAME" \
  ttl=1h

# ---------------------------------------------------------------
echo ""
echo "DONE. Quick check of what was created:"
vault_cmd policy read "$POLICY_NAME"
vault_cmd read auth/kubernetes/role/"$ROLE_NAME"
echo ""
echo "Next step: kubectl create -f app-deployment.yaml"
