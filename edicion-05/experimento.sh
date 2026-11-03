#!/usr/bin/env bash
# Dos episodios separados por una pausa menor que el TTL de los eventos (1 h por defecto).
# Duración total: unos 60 minutos. Ejecútalo en un clúster de laboratorio.
set -euo pipefail
cd "$(dirname "$0")"
: > marcas.log
kubectl apply -f 01-app.yaml
kubectl -n ksd-05 rollout status deploy/orders-api --timeout=120s
bash episodio.sh 10      # episodio 1
echo "$(date -u +%FT%TZ) pausa de 40 min, todo sano" | tee -a marcas.log
sleep 2400
bash episodio.sh 5 &     # episodio 2, en segundo plano
sleep 120             # a los 2 minutos del episodio 2, mira lo que ve el de guardia
bash leer.sh | tee lectura-durante-episodio-2.txt
wait
