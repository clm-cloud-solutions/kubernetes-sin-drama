#!/usr/bin/env bash
# Las comprobaciones del artículo, en orden.
set -uo pipefail
SA=system:serviceaccount:agentes:agente-lector

echo "== Bloque 1 · qué puede hacer el ServiceAccount"
printf '%-34s %s\n' "get secrets -n default"  "$(kubectl auth can-i get secrets -n default --as=$SA)"
printf '%-34s %s\n' "delete pods -n default"  "$(kubectl auth can-i delete pods -n default --as=$SA)"
printf '%-34s %s\n' "get pods/log -n default" "$(kubectl auth can-i get pods --subresource=log -n default --as=$SA)"
printf '%-34s %s\n' "get configmaps -n default" "$(kubectl auth can-i get configmaps -n default --as=$SA)"
printf '%-34s %s\n' "get nodes" "$(kubectl auth can-i get nodes --as=$SA 2>/dev/null)"

# Se ejecuta dentro de cada pod de prueba.
read -r -d '' PRUEBAS <<'SH'
T=/var/run/secrets/kubernetes.io/serviceaccount/token
p() {
  l=$1; shift
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$@"); rc=$?
  if [ $rc -eq 0 ]; then printf '%-40s HTTP %s\n' "$l" "$c"; else printf '%-40s bloqueado (curl %s)\n' "$l" "$rc"; fi
}
p "modelo (ollama.modelos:11434)"   http://ollama.modelos:11434/
p "señuelo (otro ns, misma etiqueta)" http://senuelo.otro:11434/
p "API: listar pods"                -k -H "Authorization: Bearer $(cat $T)" https://kubernetes.default.svc/api/v1/namespaces/default/pods
p "API: listar secrets"             -k -H "Authorization: Bearer $(cat $T)" https://kubernetes.default.svc/api/v1/namespaces/default/secrets
p "internet (https://www.google.com)" https://www.google.com
p "internet por IP (http://1.1.1.1)"  http://1.1.1.1
SH

echo
echo "== Bloque 2 · desde el agente (app=agente)"
kubectl exec -n agentes agente-prueba -- sh -c "$PRUEBAS"
echo
echo "== Bloque 2 · control, sin la política"
kubectl exec -n agentes control-sin-politica -- sh -c "$PRUEBAS"

echo
echo "== Bloque 3 · Pod Security y cuota (--dry-run=server: no crea nada)"
intenta() { # $1 etiqueta, $2 manifiesto
  out=$(echo "$2" | kubectl apply --dry-run=server -f - 2>&1)
  printf '%-34s %s\n' "$1" "$(echo "$out" | sed -E 's/.*(violates PodSecurity "[^"]*"|failed quota: [^:]*: must specify [^;]*).*/rechazado: \1/' | head -c 120)"
}
intenta "pod como root, sin seccomp" '
apiVersion: v1
kind: Pod
metadata: {name: como-root, namespace: agentes}
spec:
  containers:
    - name: c
      image: busybox:1.37
      resources: {limits: {cpu: 50m, memory: 32Mi}}'
intenta "pod sin limits" '
apiVersion: v1
kind: Pod
metadata: {name: sin-limits, namespace: agentes}
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: busybox:1.37
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}'
kubectl get resourcequota tope-agentes -n agentes

echo
echo "== Bloque 3 · el Job"
inicio=$(kubectl get job investigacion-001 -n agentes -o jsonpath='{.status.startTime}')
fin=$(kubectl get job investigacion-001 -n agentes \
  -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason} {.status.conditions[?(@.type=="Failed")].lastTransitionTime}')
if [ -n "${fin// /}" ]; then
  echo "empezó $inicio · terminó: $fin"
else
  echo "empezó $inicio · sigue activo: se corta a los 300 s (vuelve a ejecutar probar.sh)"
fi
