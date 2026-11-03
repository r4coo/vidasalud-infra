#!/bin/bash
# Une rabbit2 al clúster de rabbit1 la primera vez que arranca; luego solo inicia el nodo.
set -e
COOKIE_FILE=/var/lib/rabbitmq/.erlang.cookie
echo -n "${RABBITMQ_ERLANG_COOKIE}" > "$COOKIE_FILE"
chmod 600 "$COOKIE_FILE"

if [ ! -f /var/lib/rabbitmq/.joined ]; then
  rabbitmq-server -detached
  rabbitmqctl await_startup --timeout 90
  rabbitmqctl stop_app
  rabbitmqctl reset
  rabbitmqctl join_cluster rabbit@rabbit1
  rabbitmqctl stop
  touch /var/lib/rabbitmq/.joined
  sleep 3
fi

exec rabbitmq-server
