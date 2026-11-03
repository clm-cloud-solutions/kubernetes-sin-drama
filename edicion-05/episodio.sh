#!/usr/bin/env bash
# Uso: ./episodio.sh <minutos>
# Rompe el readiness de orders-api durante <minutos> y lo restaura.
# Deja en marcas.log la hora real de inicio y fin, para comparar después.
set -euo pipefail
MIN="${1:?indica los minutos del episodio}"
NS=ksd-05
POD=$(kubectl -n "$NS" get pod -l app=orders-api -o jsonpath='{.items[0].metadata.name}')
echo "$(date -u +%FT%TZ) inicio episodio de ${MIN} min" | tee -a marcas.log
kubectl -n "$NS" exec "$POD" -- rm -f /tmp/listo
sleep $((MIN * 60))
kubectl -n "$NS" exec "$POD" -- touch /tmp/listo
echo "$(date -u +%FT%TZ) fin episodio" | tee -a marcas.log
