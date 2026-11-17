#!/usr/bin/env bash
kubectl delete namespace agentes modelos otro --ignore-not-found
kubectl delete clusterrolebinding agente-lector-view --ignore-not-found
