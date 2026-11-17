# Edición 6 · Un agente de IA en tu clúster, sin darle las llaves

Un sandbox aísla el proceso del agente. Lo que hace con sus permisos se decide en otra capa: qué puede ver, a dónde puede salir, cuánto puede gastar y qué queda registrado.

Este laboratorio monta esa capa con objetos nativos de Kubernetes y la comprueba desde dentro de un pod.

## Qué necesitas

- `kind` (probado con v0.31.0) y `kubectl`.
- Un clúster con **un nodo worker**: `kind-2-nodos.yaml`. Con un solo nodo, la regla de la API del bloque 2 no se puede comprobar (más abajo, el porqué).
- Diez minutos. El Job del bloque 3 tarda cinco en cortarse.

## Cómo se ejecuta

```
kind create cluster --name ksd-06 --config kind-2-nodos.yaml
bash aplicar.sh     # los tres bloques y el banco de pruebas
bash probar.sh      # las comprobaciones del artículo
bash limpiar.sh     # borra los namespaces y el ClusterRoleBinding
kind delete cluster --name ksd-06
```

`aplicar.sh` lee la IP de la API de tu clúster y la pone en lugar de la del ejemplo (`172.18.0.2`). Si aplicas `02-red.yaml` a mano, cámbiala tú:

```
kubectl get endpointslice -l kubernetes.io/service-name=kubernetes
```

## Qué mirar

| Bloque | Comprobación | Esperado |
|---|---|---|
| 1 · Identidad | `can-i get secrets` / `delete pods` / `get pods/log` | `no` / `no` / `yes` |
| 1 · Identidad | `can-i get configmaps` | `yes`: view los lee, revisa que no haya contraseñas ahí |
| 2 · Red | Desde `agente-prueba` al modelo | HTTP 200 |
| 2 · Red | Al señuelo (misma etiqueta y puerto, otro namespace) | Bloqueado |
| 2 · Red | A la API: pods / secrets | HTTP 200 / HTTP 403 (la red deja pasar, el RBAC decide) |
| 2 · Red | A internet, por nombre y por IP | Bloqueado |
| 2 · Red | Lo mismo desde `control-sin-politica` | Sale a internet: el bloqueo viene de la política |
| 3 · Límites | Un pod como root o sin `seccompProfile` | Rechazado por Pod Security `restricted` |
| 3 · Límites | Un pod sin `limits` (o un sexto pod) | Rechazado por la cuota |
| 3 · Límites | El Job a los 5 minutos | `Failed`, `DeadlineExceeded`, sin pod |

## Resultado de referencia

Así salió el 17 de noviembre de 2026 en un kind v0.31.0 con dos nodos (Kubernetes v1.35.0, kindnet por defecto). Salida de `probar.sh`, recortada:

```
== Bloque 1 · qué puede hacer el ServiceAccount
get secrets -n default             no
delete pods -n default             no
get pods/log -n default            yes
get configmaps -n default          yes
get nodes                          no

== Bloque 2 · desde el agente (app=agente)
modelo (ollama.modelos:11434)            HTTP 200
señuelo (otro ns, misma etiqueta)        bloqueado (curl 28)
API: listar pods                         HTTP 200
API: listar secrets                      HTTP 403
internet (https://www.google.com)        bloqueado (curl 28)
internet por IP (http://1.1.1.1)         bloqueado (curl 28)

== Bloque 2 · control, sin la política
señuelo (otro ns, misma etiqueta)        HTTP 200
internet (https://www.google.com)        HTTP 200

== Bloque 3 · Pod Security y cuota (--dry-run=server: no crea nada)
pod como root, sin seccomp         rechazado: violates PodSecurity "restricted:latest"
pod sin limits                     rechazado: failed quota: tope-agentes: must specify limits.cpu for: c

== Bloque 3 · el Job
empezó 2026-11-17T12:50:43Z · terminó: DeadlineExceeded 2026-11-17T12:55:44Z
```

`curl 28` es un timeout: la política descarta los paquetes, no responde con un rechazo. Lo mismo pasó con un Job cuya imagen sí arranca (`busybox`, `sleep 600`): se cortó a los cinco minutos, con un fallo y sin reintento.

## Lo que no funcionó a la primera

**La IP de la API no siempre es la `.2`.** En kind, la API es el nodo de control en la red `kind` de Docker. Si ya tienes otro kind levantado, tu clúster nuevo recibe otra IP (en la prueba fue la `.7`). Con la IP del ejemplo, el agente se queda sin API: las llamadas expiran sin error de permisos.

**Con un solo nodo, la regla de la API no se nota.** kindnet no filtra el tráfico de un pod hacia el nodo en el que corre. En un kind de un nodo, la API corre en ese mismo nodo, así que el agente llega a ella aunque borres la regla o pongas una IP equivocada. Con un worker, el agente corre en el worker y su tráfico hacia la API pasa por la política.

Lo mismo vale para cualquier puerto del propio nodo: desde `agente-prueba` se llega al kubelet del worker (`:10250`). Responde 401 sin credenciales, pero la NetworkPolicy no lo corta.

**La regla de la API va con el puerto 6443, no con el 443.** El agente llama a `kubernetes.default.svc:443`, pero kindnet evalúa la política después de que el Service traduce la dirección, sobre la IP y el puerto reales de la API (`6443`). Otros CNI pueden comportarse distinto: prueba con el tuyo.

**La cuota obliga a declarar `limits`.** Como `tope-agentes` fija `limits.cpu` y `limits.memory`, un `kubectl run` sin `limits` en el namespace `agentes` falla con `must specify limits.cpu`.

## Bloque 4 · auditoría

`04-consulta-logs-insights.txt` es la consulta de CloudWatch Logs Insights para EKS, con los logs de auditoría del control plane activados. No se puede probar en kind: allí la auditoría viene apagada. Para ver todo lo que puede hacer el agente:

```
kubectl auth can-i --list --as=system:serviceaccount:agentes:agente-lector
```

## Antes de llevarlo a otro clúster

- **EKS:** `kubectl get endpointslice -l kubernetes.io/service-name=kubernetes` devuelve varias IPs (normalmente dos, las interfaces del control plane en tu VPC), y pueden cambiar cuando AWS actualiza el clúster. Necesitas una regla `ipBlock` por cada una y revisarlas después de cada actualización. La política solo se aplica si activaste el soporte de network policy del VPC CNI.
- **Modelo externo:** una NetworkPolicy estándar filtra por IP, no por dominio. Para limitar la salida a la API de un proveedor hace falta una política de Cilium con `toFQDNs` o un proxy de salida.

## Archivos

- `kind-2-nodos.yaml`: kind con control-plane y un worker.
- `01-identidad.yaml`: namespace `agentes` con Pod Security `restricted`, ServiceAccount y ClusterRoleBinding a `view`.
- `02-red.yaml`: NetworkPolicy de salida. Cambia la IP de la API.
- `03-limites.yaml`: ResourceQuota y el Job con fecha de caducidad. La imagen es un marcador.
- `04-consulta-logs-insights.txt`: consulta de auditoría para EKS.
- `banco-de-pruebas.yaml`: un sustituto del modelo, un señuelo y dos pods de prueba. No forma parte del arnés.
- `aplicar.sh`, `probar.sh`, `limpiar.sh`.
