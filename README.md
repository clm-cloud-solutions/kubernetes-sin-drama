# Kubernetes sin drama · laboratorios

Material reproducible de la newsletter **Kubernetes sin drama**, de Leafar Maina (CLM Cloud Solutions).

Cada carpeta corresponde a una edición: los values de Helm, los manifiestos, los dashboards y un README con las versiones exactas, los comandos en orden y todo lo que no funcionó a la primera.

| Edición | Tema | Carpeta |
|---|---|---|
| 4 · 20 oct 2026 | Qué cambió en tu clúster: syncs de Argo CD, eventos de Kubernetes en Loki y ReplicaSets recientes en un mismo dashboard de Grafana | [`edicion-04`](edicion-04/) |

La edición 3 (decisiones que no se dejan en manos de un modelo) tiene su propio repositorio: [agentic-patterns-k8s](https://github.com/clm-cloud-solutions/agentic-patterns-k8s).

## Antes de copiar nada

- Todo se probó en un clúster **kind** local. Revisa recursos, retención y almacenamiento antes de llevarlo a un clúster real.
- Ningún archivo contiene tokens ni contraseñas: se crean con `kubectl` y van directo a un Secret.
- Si encuentras un error, abre un issue. Se corrige en la siguiente edición, con crédito.
