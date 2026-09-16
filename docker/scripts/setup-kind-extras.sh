#!/usr/bin/env bash
# Only needed if you are using kind instead of k3d.
# k3s gives you Traefik and metrics-server for free; kind gives you neither.
set -euo pipefail
CTX="kind-exchange"
echo "Installing ingress-nginx ..."
kubectl --context "$CTX" apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "Pinning the controller to the node that has the host port mapping ..."
kubectl --context "$CTX" patch deployment ingress-nginx-controller -n ingress-nginx --type=strategic -p '{
  "spec":{"template":{"spec":{
    "nodeSelector":{"kubernetes.io/os":"linux","ingress-ready":"true"},
    "tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Equal","effect":"NoSchedule"}]
  }}}}'

echo "Installing metrics-server ..."
kubectl --context "$CTX" apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl --context "$CTX" patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

echo "Waiting ..."
kubectl --context "$CTX" wait --namespace ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=300s
kubectl --context "$CTX" wait --namespace kube-system --for=condition=available \
  deployment/metrics-server --timeout=300s
echo "Ready. Metrics can take another minute to start reporting."
