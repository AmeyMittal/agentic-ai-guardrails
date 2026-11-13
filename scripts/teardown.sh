#!/usr/bin/env bash
# Deletes the whole kind cluster (all namespaces, pods, secrets inside it).
# Leaves: .env (your keys), local Docker images, the repo. See TEARDOWN.md.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
pkill -f 'kubectl port-forward' 2>/dev/null || true
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME"
else
  info "cluster '$CLUSTER_NAME' not found (already deleted)"
fi
