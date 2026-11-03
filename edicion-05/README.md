# Edición 5 · Cuándo empezó de verdad un incidente

Un evento de Kubernetes que se repite no se borra a la hora: cada repetición le renueva el TTL. Si el mismo fallo vuelve antes de que pase esa hora, el evento mezcla los dos episodios. `count` sigue sumando y `firstTimestamp` sigue apuntando al primero.

Este laboratorio lo reproduce con un solo pod y compara cuatro lecturas del mismo momento.

## Qué necesitas

- Un clúster de laboratorio (kind, k3d, minikube o uno gestionado) y `kubectl` apuntando a él.
- Una hora libre: el experimento tiene dos episodios con 40 minutos de pausa entre ellos.

## Cómo se ejecuta

```
bash experimento.sh      # crea el namespace ksd-05 y lanza los dos episodios
bash leer.sh             # las cuatro lecturas, cuando quieras
bash limpiar.sh          # borra el namespace
```

`experimento.sh` guarda la lectura a los dos minutos del episodio 2 en `lectura-durante-episodio-2.txt`, y la hora real de cada episodio en `marcas.log`.

## Qué mirar

| Lectura | Qué dice | ¿Sirve para saber cuándo empezó el episodio actual? |
|---|---|---|
| `kubectl get events` | Última vez que se vio | No |
| `kubectl describe pod` | `(xN over Mm)` | No: es la vida del objeto |
| `count` y `firstTimestamp` | Suma y primer fallo de todos los episodios | No |
| Condición `Ready` del pod | `lastTransitionTime` del último cambio | Sí |

## Resultado de referencia

Así salió en un clúster local el 3 de noviembre de 2026 (horas en UTC). Episodio 1 de 07:31:32 a 07:41:33, 40 minutos de pausa y episodio 2 desde las 08:21:33. La lectura, a las 08:23:33:

| Lectura | Resultado |
|---|---|
| `kubectl get events` | `LAST SEEN 40s` |
| `kubectl describe pod` | `Unhealthy  40s (x74 over 51m)` |
| `count` / `firstTimestamp` / `lastTimestamp` | `74` / `07:31:42` / `08:22:53` |
| Condición `Ready` | `False` desde `08:21:43` |

Tus números van a variar un poco según cuándo arranque cada sonda.

## Archivos

- `01-app.yaml`: namespace y Deployment cuyo readiness depende de `/tmp/listo`.
- `episodio.sh`: borra el archivo durante N minutos y lo restaura.
- `experimento.sh`: dos episodios con 40 minutos de pausa.
- `leer.sh`: las cuatro lecturas y las marcas reales.
- `limpiar.sh`: borra todo.

## Por qué pasa

- client-go agrupa los eventos iguales (mismo objeto, tipo, motivo y mensaje): sube `count`, actualiza `lastTimestamp` y deja `firstTimestamp`. Ver `tools/record/events_cache.go`.
- El API server aplica `--event-ttl` en cada escritura, también en las actualizaciones. Ver `pkg/registry/core/event/storage/storage.go`.
