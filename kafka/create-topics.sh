#!/usr/bin/env bash
# Crea los tópicos de VidaSalud (idempotente). Se ejecuta una vez desde el servicio kafka-init.
# 3 particiones y 3 réplicas: una réplica por broker; min.insync.replicas=2 tolera la caída de un broker.
set -euo pipefail

BOOTSTRAP="${KAFKA_BOOTSTRAP_SERVERS:-kafka1:9092,kafka2:9092,kafka3:9092}"

echo "Esperando a que el clúster Kafka responda..."
for i in $(seq 1 40); do
  if kafka-topics --bootstrap-server "$BOOTSTRAP" --list >/dev/null 2>&1; then break; fi
  sleep 3
done

# 1) Eventos del ciclo de vida de la atención. Retención 7 días; la clave es el id de la atención,
#    por lo que todos los eventos de una misma atención van a la misma partición y conservan su orden.
kafka-topics --bootstrap-server "$BOOTSTRAP" --create --if-not-exists \
  --topic vidasalud.atenciones.eventos \
  --partitions 3 --replication-factor 3 \
  --config cleanup.policy=delete \
  --config retention.ms=604800000 \
  --config min.insync.replicas=2

# 2) Disponibilidad de cupos por prestación/fecha/hora. Compactado: se conserva el último valor de cada clave.
kafka-topics --bootstrap-server "$BOOTSTRAP" --create --if-not-exists \
  --topic vidasalud.catalogo.cupos \
  --partitions 3 --replication-factor 3 \
  --config cleanup.policy=compact \
  --config min.cleanable.dirty.ratio=0.1 \
  --config segment.ms=60000 \
  --config delete.retention.ms=86400000 \
  --config min.insync.replicas=2

echo "--- Tópicos creados ---"
kafka-topics --bootstrap-server "$BOOTSTRAP" --describe --topic vidasalud.atenciones.eventos
kafka-topics --bootstrap-server "$BOOTSTRAP" --describe --topic vidasalud.catalogo.cupos
