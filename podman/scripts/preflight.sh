#!/usr/bin/env bash
# Run this BEFORE the session, on a laptop using Podman. (Docker Desktop: use ../docker.)
set -uo pipefail
G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; N=$'\033[0m'
ok(){ echo "${G}  PASS${N}  $1"; }; bad(){ echo "${R}  FAIL${N}  $1"; F=1; }; warn(){ echo "${Y}  WARN${N}  $1"; }
F=0
echo; echo "=============================================="
echo " Kubernetes lab pre-flight - Podman"
echo "=============================================="; echo

echo "1. Tools"
if command -v podman >/dev/null 2>&1; then ok "podman  $(podman --version)"; else bad "podman not found"; fi
command -v k3d         >/dev/null 2>&1 && ok "k3d     $(k3d version | head -1)" || bad "k3d not found - brew install k3d"
command -v kubectl     >/dev/null 2>&1 && ok "kubectl present"                  || bad "kubectl not found"
command -v kubeconform >/dev/null 2>&1 && ok "kubeconform present"              || warn "kubeconform not found - brew install kubeconform"
command -v k9s         >/dev/null 2>&1 && ok "k9s present"                      || warn "k9s not found - brew install k9s (optional)"

echo; echo "2. Podman setup (README section 0a)"
if podman info >/dev/null 2>&1; then ok "Podman machine is running"; else bad "Podman machine isn't running - podman machine start"; fi
case "$(podman machine inspect --format '{{.Rootful}}' 2>/dev/null)" in
  true)  ok "machine is rootful" ;;
  false) bad "machine isn't rootful - see 0a" ;;
  *)     warn "couldn't tell whether the machine is rootful" ;;
esac
if k3d cluster list >/dev/null 2>&1; then ok "k3d can reach Podman through the Docker socket"
else bad "k3d can't reach Podman - the Docker socket isn't set up, see 0a"; fi
if podman run --rm --add-host probe:host-gateway docker.io/library/alpine:3.20 true >/dev/null 2>&1; then
  ok "containers can resolve host-gateway"
else bad "containers can't resolve host-gateway, so k3d will fail - see 0a"; fi

echo; echo "3. Ports"
lsof -nP -iTCP:8088 -sTCP:LISTEN >/dev/null 2>&1 && warn "port 8088 is in use - see Troubleshooting" || ok "port 8088 is free"

echo; echo "4. Pre-pulling images (the slow bit)"
printf "  pulling node:22-alpine ... "
podman pull -q docker.io/library/node:22-alpine >/dev/null 2>&1 && echo "${G}done${N}" || { echo "${R}failed${N}"; F=1; }

echo; echo "5. Dress rehearsal - build a cluster, then remove it"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if k3d cluster list exchange >/dev/null 2>&1; then
  warn "skipped - an 'exchange' cluster already exists, and this step would delete it"
elif [ "$F" -eq 0 ]; then
  printf "  creating ... "
  if k3d cluster create --config "$HERE/k3d-config.yaml" >/dev/null 2>&1; then
    echo "${G}done${N}"
    printf "  talking to it ... "
    kubectl --context k3d-exchange get nodes >/dev/null 2>&1 && echo "${G}done${N}" || { echo "${R}failed${N}"; F=1; }
    printf "  deleting ... "; k3d cluster delete exchange >/dev/null 2>&1 && echo "${G}done${N}"
  else echo "${R}failed${N}"; F=1; fi
else warn "skipped - fix the failures above first"; fi

echo; echo "=============================================="
[ "$F" -eq 0 ] && echo "${G} Ready. See you at the session.${N}" || echo "${R} Something needs fixing - read the FAIL lines.${N}"
echo "=============================================="; echo
exit $F
