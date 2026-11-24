# Vault Secrets Management on Kubernetes

This project demonstrates how a Kubernetes application can get a database username and password from HashiCorp Vault instead of keeping them in a ConfigMap or Deployment environment variables.

Vault stores the secret. The Vault Agent Injector adds an agent to the app pod. The agent authenticates as the pod's Kubernetes ServiceAccount, reads only the secret it is allowed to read, and writes it to `/vault/secrets/database.txt`.

> **Learning lab only:** this project runs Vault in dev mode with in-memory storage, HTTP, and the fixed root token `root`. Restarting the Vault pod loses its data. Do not use these settings for real credentials or production.

## What is in the project?

```text
vault-secrets-project/
├── namespaces/
│   ├── vault-namespace.yaml   # Namespace for Vault
│   └── app-namespace.yaml     # Namespace for the demo app
├── vault-setup/
│   ├── vault-values.yaml      # Helm settings; Vault UI and Injector enabled
│   └── vault-config.sh        # Creates the KV secret, auth method, policy and role
├── app-deployment.yaml        # ServiceAccount and demo Deployment with Injector annotations
└── README.md                  # Setup and verification guide
```

## Before you start

You need:

- Docker Desktop with Kubernetes enabled and a working Kubernetes context.
- `kubectl`
- Helm 3
- Git for Windows / Git Bash (to run `vault-config.sh`)

Open **Git Bash** in the project folder. Check that Kubernetes is available:

```bash
kubectl config current-context
kubectl get nodes
helm version
```

The node should show `Ready`. If your existing project already creates the `app` namespace, you can use that namespace instead of applying the supplied app namespace file.

## Step 1 — Create the namespaces

Vault runs in its own `vault` namespace. The sample app runs in `app`.

```bash
kubectl apply -f namespaces/vault-namespace.yaml
kubectl apply -f namespaces/app-namespace.yaml
kubectl get namespaces
```

You should see both `vault` and `app`.

## Step 2 — Install Vault and the Agent Injector

Add the HashiCorp Helm repository and install Vault using the values file:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --values vault-setup/vault-values.yaml
```

Wait for the Vault server and Injector to start:

```bash
kubectl get pods -n vault
kubectl rollout status statefulset/vault -n vault --timeout=180s
kubectl get deployments -n vault
```

The Vault pod should become `Running`. The Injector deployment should also become ready. The Injector is a Kubernetes admission webhook; it adds Vault Agent containers to pods that have the correct annotations.

## Step 3 — Open the Vault UI

The UI is enabled in `vault-setup/vault-values.yaml`. Forward the Vault service to your computer:

```bash
kubectl port-forward -n vault svc/vault-ui 8200:8200
```

Keep this terminal open, then visit:

<http://localhost:8200>

Choose **Token** as the login method and enter:

```text
root
```

That is the development root token configured in the Helm values. The UI lets you explore Vault, including the secrets engine and policies after they are created. Keep the port-forward terminal open while using the UI.

**Important:** `root` is an all-powerful lab token. Never use it for an application or a real deployment.

## Step 4 — Configure Vault

In a second Git Bash terminal, still in the project folder, run:

```bash
bash vault-setup/vault-config.sh
```

The script configures Vault in this order:

1. Enables KV version 2 at `secret/` if it is not already enabled.
2. Stores a sample database secret at `secret/app/database` with `username` and `password` fields.
3. Enables Kubernetes authentication.
4. Creates `app-read-policy`, which allows read access to `secret/data/app/*`.
5. Creates the `app-role` role, bound to ServiceAccount `app-sa` in namespace `app`, and attaches the read policy.

The sample password is deliberately fake. Do not replace it with a real password in a file you plan to commit.

## Step 5 — Deploy the demo app

Apply the ServiceAccount and Deployment:

```bash
kubectl apply -f app-deployment.yaml
kubectl rollout status deployment/demo-app -n app --timeout=180s
kubectl get pods -n app
```

The pod should show `2/2 Running`: the demo container plus the injected Vault Agent sidecar. It may take a little time for the images to download.

## Step 6 — Confirm the secret was injected

Read the file from the demo container:

```bash
kubectl exec -n app deploy/demo-app -c demo-app -- cat /vault/secrets/database.txt
```

It should contain two lines in `KEY=VALUE` format, similar to:

```text
DB_USERNAME=dbadmin
DB_PASSWORD=ChangeMe-Sample-123
```

The exact sample values come from `vault-config.sh`. The file is created inside the pod; the password is not written into the Deployment manifest.

You can also check that the Injector added its containers:

```bash
kubectl get pod -n app -o jsonpath='{.items[0].spec.initContainers[*].name} {.items[0].spec.containers[*].name}'
```

Look for `vault-agent-init` and `vault-agent`.

## Step 7 — Try changing the secret

Update the sample value in Vault:

```bash
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=root vault kv put secret/app/database username=dbadmin password=NewPassword-456
```

The pod annotation sets a 30-second refresh interval for this demonstration. Wait about a minute, then read the file again:

```bash
kubectl exec -n app deploy/demo-app -c demo-app -- cat /vault/secrets/database.txt
```

The new password should appear without restarting the pod. A real application must reread or watch this file and refresh its database connection pool; Vault updating the file does not automatically make every application reload credentials.

## Step 8 — Explore the configuration in the UI

With the UI port-forward still running, refresh `http://localhost:8200` and log in with the lab token `root`.

You can inspect the KV secrets engine and the policy/role configuration. The CLI commands below are also useful for checking the setup:

```bash
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=root vault kv get secret/app/database
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=root vault policy read app-read-policy
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=root vault read auth/kubernetes/role/app-role
```

## What happens if Vault is unavailable?

A running pod may keep using a credential it already loaded, and the injected file can remain available for that pod. But the agent cannot fetch a newly rotated value while Vault is down. A new pod may be unable to authenticate and get its secret, so it may not become ready. In production, applications should fail safely if required credentials are missing, and Vault needs durable storage, TLS, backups, monitoring, and a tested recovery plan.

## Troubleshooting

| Symptom | Check |
|---|---|
| `vault-0` is missing | Confirm Step 2 completed and the `vault` namespace exists. |
| App pod has only one container | Check that the Injector pod/deployment is ready and that the Vault annotations are under `spec.template.metadata.annotations` in `app-deployment.yaml`. Delete the app pod after fixing the issue so it is recreated with injection. |
| App pod is stuck in init | Check the init agent logs: `kubectl logs -n app <pod-name> -c vault-agent-init`. Confirm the role binds `app-sa` in namespace `app`. |
| Secret file is missing | Check the pod events and Vault Agent logs: `kubectl logs -n app <pod-name> -c vault-agent`. Confirm the secret path is `secret/data/app/database`. |
| UI does not open | Keep the port-forward command running and check the service with `kubectl get svc -n vault`. |
| Secret disappears after Vault restarts | Expected in dev mode: its data is in memory. Rerun `bash vault-setup/vault-config.sh` and recreate the app pod. |

## Clean up

Delete the demo app and uninstall Vault:

```bash
kubectl delete -f app-deployment.yaml
helm uninstall vault -n vault
```

Delete the namespaces only if they were created for this lab and contain nothing else:

```bash
kubectl delete namespace app vault
```

## The key idea

The pod does not receive a broad, long-lived Vault root token. It proves its identity with its Kubernetes ServiceAccount, and Vault grants it a short-lived token with a narrowly scoped policy. Vault Agent uses that permission to render the specific secret into a file for the application.
