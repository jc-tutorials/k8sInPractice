#!/usr/bin/env bash
# Removes everything this lab created. Only ever touches the "exchange" cluster.
set -uo pipefail
echo "Deleting the exchange cluster (k3d) ..."; k3d cluster delete exchange 2>/dev/null
echo "Deleting the exchange cluster (kind, if you used it) ..."; kind delete cluster --name exchange 2>/dev/null
echo "Removing images ..."; podman rmi localhost/exchange-gateway:v1 localhost/exchange-gateway:v2 2>/dev/null
echo "Done."
