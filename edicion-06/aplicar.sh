#!/usr/bin/env bash
# Aplica los tres bloques y el banco de pruebas.
# Lee la IP de la API del clúster y la pone en lugar de 172.18.0.2.
set -euo pipefail
cd "$(dirname "$0")"

API_IP=$(kubectl get endpointslice -l kubernetes.io/service-name=kubernetes \
  -o jsonpath='{.items[0].endpoints[0].addresses[0]}')
echo "API de Kubernetes en ${API_IP}"

kubectl apply -f 01-identidad.yaml
sed "s#172.18.0.2/32#${API_IP}/32#" 02-red.yaml | kubectl apply -f -
kubectl apply -f 03-limites.yaml
kubectl apply -f banco-de-pruebas.yaml

kubectl wait --for=condition=Ready pod/ollama -n modelos --timeout=180s
kubectl wait --for=condition=Ready pod/senuelo -n otro --timeout=180s
kubectl wait --for=condition=Ready pod/agente-prueba pod/control-sin-politica -n agentes --timeout=180s
