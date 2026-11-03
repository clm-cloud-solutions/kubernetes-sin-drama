#!/usr/bin/env bash
# Cuatro lecturas del mismo momento. Solo la condición Ready dice cuándo empezó el episodio actual.
NS=ksd-05
POD=$(kubectl -n "$NS" get pod -l app=orders-api -o jsonpath='{.items[0].metadata.name}')
echo "== Hora actual (UTC)"; date -u +%FT%TZ
echo
echo "== 1. Lo que muestra kubectl get events"
kubectl -n "$NS" get events --field-selector reason=Unhealthy
echo
echo "== 1b. Lo que muestra kubectl describe pod (sección Events)"
kubectl -n "$NS" describe pod "$POD" | sed -n '/^Events:/,$p'
echo
echo "== 2. El objeto del evento: count, firstTimestamp, lastTimestamp"
kubectl -n "$NS" get events --field-selector reason=Unhealthy \
  -o custom-columns=COUNT:.count,FIRST:.firstTimestamp,LAST:.lastTimestamp,MESSAGE:.message
echo
echo "== 3. Cuándo dejó de estar Ready el pod (condición Ready)"
kubectl -n "$NS" get pod "$POD" \
  -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}status={.status} desde={.lastTransitionTime}{"\n"}{end}'
echo
echo "== Marcas reales del experimento"
cat marcas.log 2>/dev/null || true
