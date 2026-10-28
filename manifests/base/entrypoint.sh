#!/usr/bin/env bash
set -euo pipefail

# Start the server, pull the model into the cache volume only if it is
# missing (so restarts work offline), then keep the server in the foreground.
# Readiness is gated on the model being present (see the readinessProbe in
# deployment.yaml).
ollama serve &
server_pid=$!
trap 'kill "${server_pid}"' TERM INT

until ollama list >/dev/null 2>&1; do
  sleep 1
done

if ! ollama list | grep -q "^${MODEL_NAME}"; then
  ollama pull "${MODEL_NAME}"
fi

wait "${server_pid}"
