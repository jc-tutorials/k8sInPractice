#!/usr/bin/env bash
# Run this BEFORE the session, on a laptop using Docker Desktop. (Podman: use ../podman.)
# Windows: use WSL or Git Bash.
set -uo pipefail
G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; N=$'\033[0m'
ok(){ echo "${G}  PASS${N}  $1"; }; bad(){ echo "${R}  FAIL${N}  $1"; F=1; }; warn(){ echo "${Y}  WARN${N}  $1"; }
F=0
echo; echo "=============================================="
echo " Kubernetes lab pre-flight - Docker"
echo "=============================================="; echo
echo "1. Tools"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ok "docker ($(docker --version | sed 's/,.*//')) and the daemon is running"
else bad "docker not found, or the daemon is not running - start Docker Desktop"; fi
command -v k3d     >/dev/null 2>&1 && ok "k3d     $(k3d version | head -1)"     || bad "k3d not found - brew install k3d"
command -v kubectl >/dev/null 2>&1 && ok "kubectl present"                      || bad "kubectl not found"
command -v kubeconform >/dev/null 2>&1 && ok "kubeconform present"              || warn "kubeconform not found - brew install kubeconform (used to validate manifests)"
command -v k9s     >/dev/null 2>&1 && ok "k9s present"                          || warn "k9s not found - brew install k9s (optional but useful)"

# Capture first: piping into grep -q under pipefail makes this test fail silently.
DOCKER_VERSION="$(docker version 2>/dev/null || true)"
case "$DOCKER_VERSION" in
  *[Pp]odman*) bad "this machine runs Podman, not Docker - use lab/podman instead" ;;
esac

echo; echo "2. Ports"
for p in 8088; do
  lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && warn "port $p is in use - see Troubleshooting in README.md" || ok "port $p is free"
done

echo; echo "3. Pre-pulling images (the slow bit)"
for img in node:22-alpine; do
  printf "  pulling %s ... " "$img"
  docker pull -q "$img" >/dev/null 2>&1 && echo "${G}done${N}" || { echo "${R}failed${N}"; F=1; }
done

echo; echo "4. Dress rehearsal - build a cluster, then remove it"
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
