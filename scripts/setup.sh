#!/usr/bin/env bash
# Idempotent setup: safe to re-run. Each step creates or updates in place.
# Usage: scripts/setup.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

# Pinned versions (change here only)
GWAPI_VERSION="1.6.3"        # Kubernetes Gateway API CRDs
AGW_VERSION="v1.7.0"         # agentgateway Helm charts

section "1. kind cluster"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  info "cluster '$CLUSTER_NAME' already exists"
else
  kind create cluster --config kind-config.yaml
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=180s

section "2. Gateway API CRDs v$GWAPI_VERSION"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/standard-install.yaml" >/dev/null
info "applied"

section "3. agentgateway $AGW_VERSION (CRDs + control plane)"
kubectl apply -f manifests/00-namespaces.yaml
# Network lockdown FIRST: policies are label-based and can exist before their pods, so the
# agent and MCP server never run unrestricted, not even on first boot of a fresh cluster.
kubectl apply -f manifests/50-networkpolicy.yaml
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace "$GW_NS" --version "$AGW_VERSION"
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "$GW_NS" --version "$AGW_VERSION" --wait --timeout 5m

section "4. Gateway (proxy)"
kubectl apply -f manifests/10-gateway.yaml
kubectl wait gateway/"$GW_NAME" -n "$GW_NS" --for=condition=Programmed --timeout=180s
kubectl rollout status deploy/"$GW_NAME" -n "$GW_NS" --timeout=180s

section "5. LLM route (OpenAI)"
require_key   # loads .env; checks length only, never prints the key
# Secret built from the env var and piped straight to the API: no file, no echo.
# --server-side: plain apply would copy the key into a last-applied annotation.
# printf is a shell builtin: the key never appears in `ps` (unlike --from-literal), and no trailing newline.
printf '%s' "$OPENAI_API_KEY" | kubectl create secret generic openai-secret -n "$GW_NS" \
  --from-file=Authorization=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply --server-side --field-manager=setup-sh -f - >/dev/null
info "secret openai-secret applied (value not shown)"
kubectl apply -f manifests/20-llm-openai.yaml
kubectl apply -f manifests/21-gateway-endpoint-allowlist.yaml

section "6. MCP server (tools namespace) + route via gateway"
# Build the pinned MCP server image locally and load it into the kind node (no registry needed).
# --provenance=false: no timestamped attestation, so the image ID is stable and kind load can skip re-copying
docker build -q --provenance=false -t mcp-everything:2.1.0 mcp-server/ >/dev/null
kind load docker-image mcp-everything:2.1.0 --name "$CLUSTER_NAME" >/dev/null
kubectl apply -f manifests/30-mcp-server.yaml
kubectl rollout status deploy/mcp-everything -n tools --timeout=180s
kubectl apply -f manifests/31-mcp-backend-route.yaml
kubectl apply -f manifests/32-mcp-authz.yaml     # tool allowlist (M5)

section "7. Hermes agent (agents namespace)"
HERMES_IMAGE="nousresearch/hermes-agent:v0.22.5"
# Agent API key: generated once into .env if missing (never printed). Add a newline first if
# .env doesn't end with one, so the new line can't be glued onto the previous one.
if ! grep -q '^HERMES_API_SERVER_KEY=..' .env 2>/dev/null; then
  [ -s .env ] && [ -n "$(tail -c1 .env)" ] && echo >> .env
  echo "HERMES_API_SERVER_KEY=$(openssl rand -hex 32)" >> .env
  info "generated HERMES_API_SERVER_KEY into .env (value not shown)"
fi
load_env
printf '%s' "$HERMES_API_SERVER_KEY" | kubectl create secret generic hermes-api-key -n agents \
  --from-file=API_SERVER_KEY=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply --server-side --field-manager=setup-sh -f - >/dev/null
info "secret hermes-api-key applied (value not shown)"
# Large multi-arch image (~4 GB). `kind load` fails on multi-arch images with Docker Desktop's
# containerd store (it asks for every platform's layers; only arm64 is local), so the kind node
# pulls it itself (its own arch only). Pre-pulled here so the rollout isn't waiting on it.
if ! docker exec "$CLUSTER_NAME-control-plane" crictl inspecti "docker.io/$HERMES_IMAGE" >/dev/null 2>&1; then
  info "pulling $HERMES_IMAGE into the kind node (one-time, several minutes)..."
  docker exec "$CLUSTER_NAME-control-plane" crictl pull "docker.io/$HERMES_IMAGE" >/dev/null
fi
kubectl apply -f manifests/40-hermes.yaml
# Config changes live in the ConfigMap; restart so the initContainer copies the new version.
kubectl rollout restart deploy/hermes -n agents >/dev/null
kubectl rollout status deploy/hermes -n agents --timeout=300s

section "Done"
info "next: scripts/verify.sh all"
