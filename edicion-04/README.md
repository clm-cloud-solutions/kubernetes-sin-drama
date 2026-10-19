# Laboratorio de la edición 4 · Cambios del clúster en Grafana

«Kubernetes sin drama», edición 4. Montado y probado el 15 de octubre de 2026 en
el clúster kind `kind-kubebolt-dev`, que ya tenía Argo CD. Toda la suite es OSS
autoinstalada con Helm; no se usa Grafana Cloud.

Resultado: en un mismo dashboard de Grafana, «Qué cambió en la última hora», se
ven a la vez:

1. la **anotación** de cada sync de Argo CD (pieza 1);
2. los **eventos de Kubernetes**, guardados en Loki por Grafana Alloy (pieza 2);
3. los **ReplicaSets creados en la última hora** (pieza 3).

Capturas: `captura-dashboard-oscuro.png` (minuto 1,6 tras el rollout) y
`captura-dashboard-claro.png` (minuto 26).

## Contenido de la carpeta

| Archivo | Qué es |
|---|---|
| `values-kube-prometheus-stack.yaml` | Prometheus + Grafana. La contraseña de admin sale de un Secret |
| `values-loki.yaml` | Loki SingleBinary, filesystem, sin multi-tenant, 72 h de retención |
| `values-alloy.yaml` | Alloy como Deployment de 1 réplica con `loki.source.kubernetes_events` |
| `argocd-notifications-cm.patch.yaml` | `service.grafana` + `context.argocdUrl`, para fusionar (sin token) |
| `dashboard-que-cambio.json` | El dashboard (uid `que-cambio-1h`) |
| `captura-dashboard-*.png` | Capturas headless (Chrome + Playwright) |
| `dashboard-graficos-articulo.json` | Dashboard aparte con los gráficos del artículo (uid `ed04-graficos`) |
| `grafico-0*.png` | Gráficos y capturas para el artículo (ver «Gráficos para el artículo») |

## Versiones exactas

| Componente | Versión |
|---|---|
| Kubernetes (kind) | v1.35.0 (kind v0.31.0, CNI Cilium 1.19.1) |
| Argo CD | v3.4.5 (`quay.io/argoproj/argocd:v3.4.5`) |
| Catálogo de notificaciones de Argo CD | `notifications_catalog/install.yaml` del tag v3.4.5 |
| Chart `prometheus-community/kube-prometheus-stack` | **92.8.0** (prometheus-operator v0.94.1) |
| ↳ Prometheus | v3.15.0 (`quay.io/prometheus/prometheus:v3.15.0-distroless`) |
| ↳ kube-state-metrics | v2.20.0 |
| ↳ node-exporter | v1.12.1 |
| ↳ chart de Grafana (subchart) | 13.7.0 |
| ↳ **Imagen de Grafana** | **`docker.io/grafana/grafana:13.2.4-distroless`** |
| Chart `grafana/loki` | **7.3.0** (appVersion 3.6.12; imagen real `grafana/loki:3.6.11`, ver problemas) |
| Chart `grafana/alloy` | **1.13.1** (`grafana/alloy:v1.20.1`) |
| Cliente | Helm v3.18.6, kubectl v1.37.1 |

## Reproducirlo desde cero

Requisitos: un clúster kind con Argo CD instalado y una `Application` de demo
cuyo repo Git puedas modificar. En este lab: `sm-store-backend`
(`github.com/clm-cloud-solutions/sm-store-backend`, path `manifests`, autosync).

Antes de cada `kubectl`/`helm`, comprueba el contexto:

```bash
kubectl config use-context kind-kubebolt-dev
[[ "$(kubectl config current-context)" == kind-* ]] || echo "¡No es kind!"
```

### 1 · Repos de Helm

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### 2 · Prometheus y Grafana

```bash
kubectl create namespace monitoring
# Contraseña aleatoria directamente al Secret: no pasa por ningún archivo
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24 | tr -d '/+=')"

helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
  --version 92.8.0 -n monitoring -f values-kube-prometheus-stack.yaml --wait

# Comprobar que existe la métrica de la pieza 3
kubectl -n monitoring port-forward svc/kube-prom-kube-prometheus-prometheus 9090 &
curl -s 'localhost:9090/api/v1/query?query=count(kube_replicaset_created)'
```

> **Si ya tienes kube-prometheus-stack instalado** con otra versión (aquí había
> un 84.5.0 sin Grafana), Helm no actualiza los CRDs. Aplícalos antes del
> upgrade desde el propio chart:
>
> ```bash
> helm pull prometheus-community/kube-prometheus-stack --version 92.8.0 --untar
> kubectl apply --server-side --force-conflicts \
>   -f kube-prometheus-stack/charts/crds/crds/
> ```

### 3 · Loki

```bash
helm upgrade --install loki grafana/loki --version 7.3.0 \
  -n loki --create-namespace -f values-loki.yaml --wait
```

URL interna de push (gateway):
`http://loki-gateway.loki.svc.cluster.local/loki/api/v1/push`.
El datasource de Grafana apunta a `http://loki-gateway.loki.svc.cluster.local`
(uid `loki`).

### 4 · Alloy con los eventos de Kubernetes

```bash
helm upgrade --install alloy grafana/alloy --version 1.13.1 \
  -n monitoring -f values-alloy.yaml --wait

# RBAC: el ClusterRole del chart ya cubre events
kubectl auth can-i watch events -A --as=system:serviceaccount:monitoring:alloy
```

Labels reales del stream (para las consultas):
`job="loki.source.kubernetes_events"`, `namespace`, `instance`, `service_name`.
El tipo de evento **no** es un label: va dentro de la línea logfmt
(`type=Warning`, `reason=...`, `kind=...`, `name=...`, `msg="..."`).

### 5 · Dashboard

Se provisiona con un ConfigMap que lee el sidecar de Grafana, así sobrevive a
reinicios y no necesita credenciales:

```bash
kubectl -n monitoring create configmap dashboard-que-cambio \
  --from-file=dashboard-que-cambio.json --dry-run=client -o yaml \
| kubectl label --local -f - grafana_dashboard=1 -o yaml \
| kubectl apply -f -
```

### 6 · Token de Grafana para Argo CD

Cuenta de servicio `argocd-annotations` con rol Editor y token guardado
directamente en `argocd-notifications-secret`. Ni el token ni la contraseña se
imprimen ni se escriben en disco:

```bash
kubectl -n monitoring port-forward svc/kube-prom-grafana 13000:80 &
PASS=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
g() { curl -sf -K <(printf 'user = "admin:%s"\n' "$PASS") -H 'Content-Type: application/json' "$@"; }

SA_ID=$(g -X POST localhost:13000/api/serviceaccounts \
  -d '{"name":"argocd-annotations","role":"Editor"}' | jq -r .id)

g -X POST "localhost:13000/api/serviceaccounts/$SA_ID/tokens" -d '{"name":"argocd-notifications"}' \
  | jq -r .key \
  | jq -Rc '{stringData:{"grafana-api-key":.}}' \
  | kubectl -n argocd patch secret argocd-notifications-secret --type merge --patch-file /dev/stdin
unset PASS
```

### 7 · Notificaciones de Argo CD → Grafana

Las dos operaciones **fusionan** con lo que ya hubiera en el ConfigMap, nunca lo
reemplazan:

```bash
# Catálogo oficial (triggers y templates), solo su .data
curl -sL https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.5/notifications_catalog/install.yaml \
| yq -o json '{"data": .data}' \
| kubectl -n argocd patch configmap argocd-notifications-cm --type merge --patch-file /dev/stdin

# service.grafana + context.argocdUrl
kubectl -n argocd patch configmap argocd-notifications-cm \
  --type merge --patch-file argocd-notifications-cm.patch.yaml

# Suscribir UNA app
kubectl -n argocd annotate application sm-store-backend \
  'notifications.argoproj.io/subscribe.on-sync-succeeded.grafana=argocd|sm-store-backend'
```

Comprobación (Grafana): `GET /api/annotations?tags=argocd`.

### 8 · El cambio para la captura

En el repo de la app, un commit pequeño que provoque un rollout. Aquí se añadió
`DEPENDENCY_TIMEOUT_MS: "1000"` al Deployment (la app lo lee; por defecto son
5000 ms):

```bash
git commit -am "chore: lower DEPENDENCY_TIMEOUT_MS to 1000 ms" && git push
kubectl -n argocd annotate application sm-store-backend argocd.argoproj.io/refresh=normal --overwrite
```

Resultado medido: push → sync de Argo CD a las 16:25:07Z → anotación `id 2` en
Grafana a las 16:25:07Z → eventos `ScalingReplicaSet`, `SuccessfulCreate`,
`Scheduled`, `Pulled`, `Started` y `Killing` en Loki → ReplicaSet
`store-backend-6cd96cd665` en la tabla con 0,5 min.

## El dashboard

Rango por defecto: última hora. Refresco: 30 s. Variables: `namespace` (de Loki,
por defecto `sm-store`) y `tipo` (Warning, Normal; por defecto ambos).

1. **Serie temporal** «store-backend · CPU por pod». La app no expone métricas
   HTTP, así que se usa CPU. Lleva una capa de anotaciones «Syncs de Argo CD»
   filtrada por el tag `argocd` y limitada a este panel.
   ```promql
   sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="sm-store", pod=~"store-backend-.*", container="app"}[2m]))
   ```
2. **Logs** «Eventos de Kubernetes (Loki)». Los Warning salen en amarillo y los
   Normal como info:
   ```logql
   {job="loki.source.kubernetes_events", namespace=~"$namespace"}
     | logfmt | type=~"$tipo"
     | drop detected_level
     | label_format level=`{{ if eq .type "Warning" }}warning{{ else }}info{{ end }}`
     | line_format `{{ .type }}  {{ .kind }}/{{ .name }}  {{ .reason }}: {{ .msg }}`
   ```
3. **Tabla** «ReplicaSets creados en la última hora», con el Deployment dueño y
   la antigüedad en minutos (en naranja si tiene menos de 15 min):
   ```promql
   max by (namespace, owner_kind, owner_name, replicaset) (
     round((time() - kube_replicaset_created{namespace=~"$namespace"}) / 60, 0.1)
     * on (namespace, replicaset) group_left (owner_kind, owner_name)
     kube_replicaset_owner
   ) < 60
   ```

## Gráficos para el artículo

Sacados con datos reales del lab, de un dashboard aparte
(`dashboard-graficos-articulo.json`, uid `ed04-graficos`, cargado por la API de
Grafana), con un navegador headless a 2x. Las horas que se ven son de Madrid
(CEST): las 18:25 de las imágenes son las 16:25Z de este README.

| Archivo | Qué muestra | Rango |
|---|---|---|
| `grafico-01-anotacion-tooltip.png` | La anotación de Argo CD con su tooltip («Application sm-store-backend has been successfully synced…», tags `argocd` y `sm-store-backend`) sobre los eventos del rollout | 16:24:30–16:26Z |
| `grafico-02-rollout-eventos.png` | El mismo rollout, sin tooltip: 18 eventos en 25 s, apilados por motivo. Azules: arranca el pod nuevo; verde y naranja: ReplicaSet y Deployment; rojos: se va el pod viejo. Se ven las tres oleadas (pod 1, pod 2, limpieza) | 16:24:30–16:26Z |
| `grafico-03-api-server-vs-loki.png` | Eventos guardados: el API server (`apiserver_storage_objects{resource="events"}`) se queda en 240–780 porque los borra a la hora; Loki (`count_over_time(...[72h])`) solo crece, de ~2.400 a ~4.000 | 18:00–20:45Z |
| `grafico-04-eventos-por-namespace.png` | Eventos cada 10 min por namespace. La app (`sm-store`, en rojo) es una franja mínima bajo la anotación; el volumen es de Trivy (escaneos), `monitoring` y `kube-system` | 16:00–20:45Z |
| `grafico-05-warnings-por-motivo.png` | Los Warning de esas casi 5 horas: PolicyViolation 758 (Kyverno), Unhealthy 203 (196 son probes de Grafana durante el problema 7), BackoffLimitExceeded 33 (Jobs de Trivy) | 16:00–20:45Z |
| `grafico-06-pieza2-api-server-vs-loki.png` | La pieza 2 en una imagen: arriba, `kubectl get events -n sm-store` vacío a las 22:51 CEST con los pods del rollout aún corriendo (4 h 26 min); abajo, Grafana Explore devolviendo los 18 eventos del rollout desde Loki | — |

Notas:

- **No hay latencia en ningún gráfico.** La app de demo no expone métricas HTTP
  (problema 23), así que la anotación va sobre la CPU por pod en
  `captura-dashboard-*.png` y sobre los eventos del rollout en
  `grafico-01`/`02`. Con una app que exponga latencia, la misma capa de
  anotaciones (tag `argocd`) funciona igual sobre ese panel.
- En `grafico-01`, Grafana ancla el tooltip de la anotación abajo, en el
  marcador. Para que no tape las barras, esa captura sale del panel 5, un gemelo
  del 4 con el eje Y desde −2 (las etiquetas negativas se ocultan con un value
  mapping) y `decimals: 0`. Los datos son los mismos.
- La serie del API server empieza a las 18:00Z porque Prometheus no conserva nada
  anterior (problema 27). Por eso el tooltip va sobre un panel de eventos de
  Loki y no sobre la CPU: la CPU de las 16:25Z ya no está en Prometheus.
- El panel de Warnings usa una consulta de rango en buckets de 10 min y un bar
  gauge que suma, con `max: 800` fijo. Con una consulta instantánea, Grafana
  13.2.4 pintaba una sola barra; sin `max`, cada barra se escalaba contra su
  bucket más alto.
- Cada gráfico se abre con `/d-solo/ed04-graficos/x?panelId=N&from=…&to=…`.

## Problemas encontrados

Todo lo que no funcionó a la primera, en el orden en que apareció.

### Antes de empezar: el clúster

1. **Argo CD no sincronizaba: `lookup argocd-redis: i/o timeout`.** Las tres
   apps estaban en `Unknown`. El origen fue el disco del Mac al 97 %: Docker se
   reinició y los contenedores de kind **cambiaron de IP** (el worker pasó de
   172.18.0.4 a 172.18.0.2, y la .4 se la quedó otro clúster kind). Cilium se
   quedó con 50 de 57 `CiliumEndpoints` apuntando a IPs viejas y aplicaba
   identidades y NetworkPolicies a los pods equivocados. El agente lo decía:
   `cannot take ownership of CEP that is not local: pod's hostIP "172.18.0.4",
   cilium nodeIP "172.18.0.2"`. **Solución:** liberar disco y reiniciar Cilium y
   todos los pods. Lección: con varios clústeres kind levantados, un reinicio de
   Docker puede barajar las IPs de los nodos.

### Paso 1 · Prometheus y Grafana

2. **Ya había un kube-prometheus-stack (84.5.0, sin Grafana).** Se reutilizó y
   se actualizó a 92.8.0: ocho versiones mayores de salto. Helm no actualiza
   CRDs, así que se aplicaron antes con `--server-side --force-conflicts` desde
   `charts/crds/crds/` del chart. Hubo que conservar el
   `prometheus-node-exporter.nameOverride` del release original, porque
   cambiarlo cambia el selector del DaemonSet (inmutable) y el upgrade falla.
3. **Las NOTES del chart mienten con `existingSecret`.** Dicen que la contraseña
   está en el Secret `kube-prom-grafana`, que no existe. Está en el Secret que
   tú le pasas (`grafana-admin`).
4. **Datasource fantasma de Alertmanager.** Con `alertmanager.enabled: false`,
   el chart sigue provisionando un datasource «Alertmanager» que apunta a un
   servicio inexistente. Solución: `grafana.sidecar.datasources.alertmanager.enabled: false`
   más `grafana.deleteDatasources`.
5. **Grafana sin persistencia pierde la cuenta de servicio y el token** en cada
   reinicio (SQLite en emptyDir). Se activó `grafana.persistence` (1 Gi).
6. **Prometheus pierde el histórico en el upgrade** porque no tiene volumen. El
   panel de CPU empieza a las 17:55. En kind se aceptó; en un entorno real usa
   `prometheus.prometheusSpec.storageSpec`.
7. **Grafana 13.2.4 se queda sin CPU al navegar. Causa: el GC de Go con 512Mi
   de memoria (resuelto).** Al pasar por la home, la lista de dashboards o la
   búsqueda, Grafana se pone al máximo de CPU (~12 cores sin límite; 1,00 con
   `limits.cpu: 1`) durante 3–6 minutos. Ningún dashboard carga, ni en un
   navegador normal ni en uno headless: los JS estáticos tardan 80 s, cada
   refresco de 30 s deja dos `/api/annotations` sin terminar, y fallan la
   readiness y la liveness (el kubelet llegó a reiniciar el contenedor).

   **Causa.** El chart fija `GOMEMLIMIT` al 90 % del límite de memoria: con
   `limits.memory: 512Mi` queda en 460MiB. Navegar sube el heap de Go de
   ~115 MiB en reposo a 300–470 MiB. Al rozar ese límite, el GC se ejecuta sin
   parar y se come la CPU. Cómo se comprobó:
   - en cada pico, el working set estaba pegado a 450–463Mi;
   - se repitió el mismo recorrido (home → `/dashboards` → búsqueda →
     dashboard) con un navegador headless. Con 512Mi: pico, pprof sin responder
     ni con 4 cores y reinicio por la liveness. Con 1Gi (`GOMEMLIMIT=921MiB`):
     cada pantalla carga en 1–2 s y la CPU no pasa de 0,12 cores, tanto con
     4 cores como con 1. El heap llegó a 472 MiB, más que el límite anterior;
   - sin navegador no hay picos (3 horas planas a 0,01–0,03 cores).

   Pistas falsas por el camino: el endpoint `/dto` y `/api/annotations` (en
   reposo responden en 13–90 ms), Grafana Live (`live.max_connections: 0` no
   cambia nada) y la búsqueda bleve del volcado de goroutines
   (`permissionScopedQuery`). La búsqueda asigna memoria, pero no es un bucle.

   **Solución:** `limits.memory: 1Gi` y `requests.memory: 256Mi`. El
   `limits.cpu: 1` se mantiene para que un pico no se coma el host. Si el heap
   vivo crece con más dashboards o usuarios, vigila
   `go_memstats_heap_inuse_bytes` frente a `go_gc_gomemlimit_bytes`.

### Paso 2 · Loki

8. **El chart 7.3.0 dice Loki 3.6.12, pero despliega la imagen `grafana/loki:3.6.11`.**
   Se anota la imagen real.
9. **Los cachés memcached (`chunksCache`, `resultsCache`) piden varios GB por
   defecto.** Se desactivaron para kind.
10. Al arrancar, Loki avisa `Failed to resolve loki-memberlist...: no such host`.
    Es normal en SingleBinary mientras el pod no está Ready; desaparece solo.
11. **La imagen de Loki es distroless** (no tiene `sh` ni `du`): el tamaño se
    mide desde el nodo kind (`docker exec <nodo> du -sh /var/local-path-provisioner/<pv>`).

### Paso 3 · Alloy

12. **El RBAC ya estaba bien.** El ClusterRole por defecto del chart incluye
    `get/list/watch` sobre `events`; no hubo errores de permisos.
13. **`type` no es un label.** Los labels reales son `job`, `namespace`,
    `instance` y `service_name` (este último lo añade Loki). Para filtrar por
    Warning/Normal hace falta `| logfmt | type=~"..."`.
14. **`detected_level=unknown` tapa el nivel.** Loki 3.x añade `detected_level`
    como metadata estructurada y, como la línea no tiene `level=`, vale
    `unknown`. Grafana lo prefiere a un `level` calculado, así que todo salía
    como `UNK`. Solución: `| drop detected_level` antes del
    `label_format level=...`.
15. **Los eventos de objetos sin namespace llegan sin label `namespace`** (por
    ejemplo `PolicyViolation` de las ClusterPolicy de Kyverno). Con `All = .+`
    quedaban fuera; la variable usa `allValue: ".*"`.
16. Los timestamps de los eventos tienen precisión de segundo: muchos eventos de
    un mismo rollout comparten marca de tiempo.

### Paso 4 · Anotaciones de Argo CD

17. **«API key» en la documentación de Argo CD, token de cuenta de servicio en
    Grafana.** Grafana ya no tiene API keys (desde 11.6). El campo sigue
    llamándose `apiKey` en `service.grafana`, pero lo que va ahí es el token de
    una cuenta de servicio (`glsa_...`) con rol Editor.
18. **`argocd-notifications-cm` estaba vacío**: ni triggers ni templates. Se
    fusionó el catálogo oficial del mismo tag que Argo CD (v3.4.5).
19. **`<no value>` en el texto de la anotación.** Los templates del catálogo usan
    `{{.context.argocdUrl}}` y no estaba definido. Solución: `context:
    argocdUrl: https://localhost:8080` en el ConfigMap (incluido en el parche).
20. **Al suscribir la app, la anotación sale al momento**, por la *última* sync
    que hubo (una de julio). Grafana la pone a la hora de la notificación, no a
    la de la sync. Se ve como la primera línea naranja de las capturas (18:20).
21. **Forzar una sync no crea anotación.** El trigger `on-sync-succeeded` del
    catálogo tiene `oncePer: app.status.operationState.syncResult.revision`.
    Una sync forzada sobre el mismo commit registra `already sent` y no
    notifica. Para ver la anotación hace falta un **commit nuevo**: el paso 6 es
    la prueba real, no el `argocd app sync`.
22. Las anotaciones se crean a nivel de organización (`dashboardUID: ""`): el
    dashboard las encuentra por tag, no por dashboard.

### Paso 5 · Dashboard

23. **La app de demo no expone métricas HTTP** y su contenedor se llama `app`,
    no `store-backend`. El panel usa la CPU de sus pods.
24. **`kube_replicaset_created` trae labels del propio kube-state-metrics**
    (`pod`, `container`, `instance`) que confunden en la tabla. Solución:
    `max by (...)` y un join con `kube_replicaset_owner` para añadir el
    Deployment dueño.
25. Los ReplicaSets de reinicios anteriores (aquí, el `rollout restart` de todo
    el clúster de las 17:46) llenan la tabla hasta que cumplen 60 minutos.

### Notas del proceso (Claude Code)

26. El lab se montó con Claude Code. Su clasificador de permisos **bloqueó dos
    acciones**: escribir el token en `argocd-notifications-secret` y hacer push
    al repo público de la app. Las ejecutó el operador a mano con un script
    preparado (los comandos son los de los pasos 6 y 8).

### Después del lab

27. **Prometheus perdió todo lo anterior a las 18:00Z.** El recurso Prometheus
    del clúster tiene `retentionSize: 512MB`, y la retención por tamaño borró
    bloques dos veces (`prometheus_tsdb_size_retentions_total = 2`): con unos
    75 pods, 512 MB dan para ~3 horas. No sale de estos values ni del chart
    (los dos lo dejan vacío): venía de la instalación original del clúster y
    Helm no lo quitó al actualizar. Se dejó así porque protege el disco del
    Mac. Las capturas del dashboard se hicieron antes y no se ven afectadas.
    Si reproduces el lab, comprueba
    `kubectl get prometheus -A -o jsonpath='{..retentionSize}'` y súbelo o
    pon `storageSpec` si quieres más historia.
28. **Un `line_format` sin el mensaje hace que Loki se coma eventos.** Con
    `| line_format "{{.kind}}/{{.name}} {{.reason}}"`, los dos
    `ScalingReplicaSet` del Deployment a las 16:25:19 («Scaled up … from 1 to
    2» y «Scaled down … from 2 to 1») quedan como la misma línea con el mismo
    timestamp, y Loki los devuelve como uno: 17 eventos en vez de 18. Sin
    `line_format`, con el del dashboard (que incluye `{{.msg}}`) o con
    `count_over_time`, salen 18. Para contar, usa `count_over_time`; para
    leer, deja el mensaje en la línea.

## Cuánto ocupa Loki

Solo eventos de Kubernetes de un clúster kind con unos 75 pods y bastante ruido
(Kyverno, Trivy, Falco, Cilium):

| Momento | Líneas recibidas | Bytes recibidos (sin comprimir) | En disco (PVC) |
|---|---|---|---|
| +56 min | 2.153 | 807 KB | 768 KB (WAL 540 KB, chunks 88 KB) |
| +1 h 35 min | 2.307 | 875 KB | 428 KB (chunks 176 KB, WAL 112 KB, índice TSDB 52 KB) |
| +4 h | 3.440 | 1.334 KB | 524 KB (26 chunks volcados; Loki y Alloy sin reinicios) |

El disco **baja** entre la primera y la segunda medida. Al volcarse a chunks
comprimidos, el WAL se trunca: pasa de 540 KB a 112 KB.

El primer bloque de líneas no es representativo. Al arrancar, Alloy recoge todos
los eventos que el API server aún guardaba (hasta 1 h hacia atrás), y en este
caso coincidió con un reinicio de todos los pods del clúster. Entre la primera y
la segunda medida entraron 154 líneas en 35 minutos (unas 4–5 por minuto), con el
clúster tranquilo.

Entre +1 h 35 min y +4 h entraron 1.133 líneas en 145 minutos: **7,8 por
minuto**, a unos 405 bytes por línea. Casi la mitad (506) son de `trivy-system`:
entre las 18:05 y las 19:54Z, Trivy lanzó 49 Jobs `scan-vulnerabilityreport-*`
(5 acabaron en `BackoffLimitExceeded`) y cada uno deja 5–6 eventos (Scheduled,
Pulled, Created, Started, Completed). El resto es ruido de fondo: `default` 227,
sin namespace 189, `kube-system` 153 y `monitoring` 50.

Estimación con los dos ritmos medidos, 4,4 líneas por minuto (tranquilo) y 7,8
(con escaneos de Trivy):

| | Por día | Retención de 72 h |
|---|---|---|
| Líneas | 6.300–11.200 | 19.000–34.000 |
| Bytes recibidos (sin comprimir) | 2,6–4,6 MB | 7,7–13,7 MB |
| En disco (≈ 0,39 × recibido, la proporción a +4 h) | 1–1,8 MB | 3–5,3 MB |

Es una extrapolación de 4 horas en un clúster sin incidentes; un CrashLoopBackOff
o una tanda de despliegues la sube. Aun así, el PVC de 5Gi tiene unas mil veces
más espacio del necesario: guardar solo eventos en Loki con filesystem cabe en
cualquier clúster pequeño.

## Si usas Grafana Cloud (NO VERIFICADO)

No se ha probado en este lab: son las dos diferencias esperadas según la
documentación.

1. **`apiUrl` de Argo CD** apunta al stack de Grafana Cloud, con el token de una
   cuenta de servicio de ese stack:
   ```yaml
   service.grafana: |
     apiUrl: https://<tu-stack>.grafana.net/api
     apiKey: $grafana-api-key
   ```
2. **`loki.write` de Alloy** usa el endpoint de Loki de tu stack, con el usuario
   numérico de Loki y un token de Access Policy con scope `logs:write`, leído de
   una variable de entorno (nunca escrito en la config):
   ```alloy
   loki.write "cloud" {
     endpoint {
       url = "https://logs-prod-<región>.grafana.net/loki/api/v1/push"
       basic_auth {
         username = "<id numérico de Loki>"
         password = sys.env("GRAFANA_CLOUD_LOGS_TOKEN")
       }
     }
   }
   ```

## Comprobación final

- [x] Una sincronización de Argo CD aparece como anotación sobre el panel de
      métricas (anotación `id 2`, 16:25:07Z, sobre el panel de CPU).
- [x] Los eventos de un rollout se ven en Loki más de una hora después. A las
      17:31Z (66 min tras el rollout), el API server ya no tenía **ningún**
      evento en `sm-store` (`kubectl get events` → `No resources found`, por el
      `--event-ttl` de 1 h). Loki seguía devolviendo los **18 eventos** del
      rollout, todos entre 16:25:07 y 16:25:32Z (`Scheduled`,
      `ScalingReplicaSet`, `SuccessfulCreate`, `Pulled`, `Created`, `Started`,
      `Killing`, `SuccessfulDelete`). La consulta de esta comprobación contó 17
      por el problema 28; la cifra buena es 18.
- [x] La tabla muestra el ReplicaSet nuevo con su antigüedad
      (`store-backend-6cd96cd665`, 0,5 → 1,6 → 26,5 min).
- [x] Ningún archivo de `edicion-04-lab/` contiene el token ni la contraseña de
      Grafana (comprobado con `grep -F` contra los valores reales de los dos
      Secrets y contra el patrón `glsa_…`: 0 coincidencias en los 15 archivos
      de la carpeta). `grep` no lee el texto pintado en un PNG, así que las 8
      imágenes se revisaron también a ojo: ninguna muestra la contraseña ni el
      token.
- [x] El contexto de kubectl sigue siendo `kind-kubebolt-dev`; no se ha tocado
      ningún AKS.
