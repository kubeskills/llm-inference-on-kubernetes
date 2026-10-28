#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NAMESPACE="${NAMESPACE:-llm-inference}"
LOCAL_PORT="${LOCAL_PORT:-18434}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-900s}"
BASE_URL="http://127.0.0.1:${LOCAL_PORT}"

for bin in kubectl curl jq; do
  command -v "${bin}" >/dev/null 2>&1 || die "missing: ${bin}"
done

resolve_target
describe_target

echo "waiting for rollout (up to ${ROLLOUT_TIMEOUT})"
"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deploy/llm-inference \
  --timeout="${ROLLOUT_TIMEOUT}"

model="$("${KUBECTL[@]}" -n "${NAMESPACE}" exec deploy/llm-inference -- \
  printenv MODEL_NAME)"
echo "model: ${model}"

"${KUBECTL[@]}" -n "${NAMESPACE}" port-forward svc/llm-inference \
  "${LOCAL_PORT}:80" >/dev/null &
pf_pid=$!
trap 'kill "${pf_pid}" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  kill -0 "${pf_pid}" 2>/dev/null || die "port-forward exited (is port ${LOCAL_PORT} in use?)"
  curl -fsS --max-time 2 "${BASE_URL}/api/version" >/dev/null 2>&1 && break
  sleep 1
done

echo "--- model listing"
tags="$(curl -fsS --max-time 10 "${BASE_URL}/api/tags")"
jq -e --arg m "${model}" '[.models[].name] | index($m) != null' \
  <<<"${tags}" >/dev/null || die "model ${model} not listed by /api/tags"
jq -r '.models[].name' <<<"${tags}"

echo "--- bounded inference (num_predict=16)"
payload="$(jq -n --arg m "${model}" \
  '{model: $m, prompt: "Reply with one short word.", stream: false, options: {num_predict: 16}}')"
resp="$(curl -fsS --max-time 300 -H 'Content-Type: application/json' \
  -d "${payload}" "${BASE_URL}/api/generate")"
jq -e '.response | length > 0' <<<"${resp}" >/dev/null ||
  die "empty inference response"
jq -r '"response: \(.response)"' <<<"${resp}"

echo "smoke test PASSED"
