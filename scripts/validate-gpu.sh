#!/usr/bin/env bash
set -euo pipefail

# End-to-end validation for the two-node K3s GPU lab. Run AFTER deploying
# manifests/overlays/gpu. Every check must PASS before success is documented.
#   EXPECTED_K3S_VERSION=v1.36.5+k3s1 ./scripts/validate-gpu.sh
# Default namespace is llm-inference-gpu (the GPU overlay's namespace).
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NAMESPACE="${NAMESPACE:-llm-inference-gpu}"
EXPECTED_K3S_VERSION="${EXPECTED_K3S_VERSION:-}"
GPU_LABEL_KEY="nvidia.com/gpu.present"
LOCAL_PORT="${LOCAL_PORT:-19400}"

for bin in kubectl curl jq; do
  command -v "${bin}" >/dev/null 2>&1 || die "missing: ${bin}"
done

resolve_target
describe_target

failed=0
record() {
  printf '%-26s %-5s %s\n' "$1" "$2" "$3"
  [[ "$2" == PASS ]] || failed=1
}
run_check() {
  local name="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    record "${name}" PASS "${out//$'\n'/ | }"
  else
    record "${name}" FAIL "${out//$'\n'/ | }"
  fi
}

kc() { "${KUBECTL[@]}" "$@"; }

# [*] (not [0]) so an empty result is an empty string, not a jsonpath error.
gpu_nodes="$(kc get nodes -l "${GPU_LABEL_KEY}=true" -o jsonpath='{.items[*].metadata.name}')"
cpu_nodes="$(kc get nodes -l "!${GPU_LABEL_KEY}" -o jsonpath='{.items[*].metadata.name}')"
GPU_NODE="${gpu_nodes%% *}"
CPU_NODE="${cpu_nodes%% *}"
echo
echo "gpu node: ${GPU_NODE:-<none>}   non-gpu node: ${CPU_NODE:-<none>}"
echo

check_versions() {
  local versions count not_ready
  versions="$(kc get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | sort -u)"
  count="$(grep -c . <<<"${versions}")"
  [[ "${count}" -eq 1 ]] || { echo "nodes run different versions: ${versions//$'\n'/ }"; return 1; }
  [[ -z "${EXPECTED_K3S_VERSION}" || "${versions}" == "${EXPECTED_K3S_VERSION}" ]] ||
    { echo "expected ${EXPECTED_K3S_VERSION}, nodes run ${versions}"; return 1; }
  not_ready="$(kc get nodes --no-headers | awk '$2 != "Ready"' | wc -l | tr -d ' ')"
  [[ "${not_ready}" -eq 0 ]] || { echo "${not_ready} node(s) not Ready"; return 1; }
  [[ "$(kc get nodes --no-headers | wc -l | tr -d ' ')" -ge 2 ]] || { echo "need >= 2 nodes"; return 1; }
  echo "all nodes Ready on ${versions}"
}

check_runtimeclass() {
  local handler
  handler="$(kc get runtimeclass nvidia -o jsonpath='{.handler}')"
  [[ "${handler}" == "nvidia" ]] || { echo "RuntimeClass nvidia handler='${handler}'"; return 1; }
  echo "RuntimeClass nvidia present"
}

check_allocatable() {
  local n
  n="$(kc get node "${GPU_NODE}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')"
  [[ "${n:-0}" -ge 1 ]] || { echo "allocatable nvidia.com/gpu='${n}' on ${GPU_NODE}"; return 1; }
  echo "${GPU_NODE} advertises nvidia.com/gpu=${n}"
}

check_device_plugin() {
  kc -n nvidia-device-plugin get pods -o wide --no-headers --field-selector "spec.nodeName=${GPU_NODE}" |
    awk '$3 == "Running" {found=1} END {exit !found}' ||
    { echo "no Running device-plugin pod on ${GPU_NODE}"; return 1; }
  echo "device plugin Running on ${GPU_NODE}"
}

check_workload_placement() {
  local node limit allocated
  node="$(kc -n "${NAMESPACE}" get pod -l app=llm-inference -o jsonpath='{.items[0].spec.nodeName}')"
  [[ "${node}" == "${GPU_NODE}" ]] || { echo "inference pod on '${node}', expected ${GPU_NODE}"; return 1; }
  limit="$(kc -n "${NAMESPACE}" get pod -l app=llm-inference -o jsonpath='{.items[0].spec.containers[0].resources.limits.nvidia\.com/gpu}')"
  [[ "${limit}" == "1" ]] || { echo "pod gpu limit='${limit}'"; return 1; }
  allocated="$(kc describe node "${GPU_NODE}" | sed -n '/Allocated resources/,/Events/p' | awk '/nvidia.com\/gpu/ {print $2}')"
  [[ "${allocated}" == "1" ]] || { echo "node shows allocated nvidia.com/gpu='${allocated}'"; return 1; }
  echo "pod on ${GPU_NODE}, 1 GPU requested and allocated"
}

check_gpu_in_pod() {
  kc -n "${NAMESPACE}" exec deploy/llm-inference -- nvidia-smi -L | grep -m1 'GPU 0'
}

check_inference() {
  NAMESPACE="${NAMESPACE}" "$(dirname "${BASH_SOURCE[0]}")/smoke-test.sh" | tail -2
}

check_gpu_used() {
  local ps
  ps="$(kc -n "${NAMESPACE}" exec deploy/llm-inference -- ollama ps)"
  grep -q 'GPU' <<<"${ps}" || { echo "model not on GPU: ${ps//$'\n'/ | }"; return 1; }
  ! grep -q '100% CPU' <<<"${ps}" || { echo "model on CPU: ${ps//$'\n'/ | }"; return 1; }
  sed -n '2p' <<<"${ps}"
}

check_cross_node() {
  local name manifest pod_node svc_node model
  name="xnode-$(date +%s)"
  manifest="$(sed -e "s/__NAME__/${name}/" -e "s/__NODE__/${CPU_NODE}/" -e "s/__NAMESPACE__/${NAMESPACE}/" "${REPO_ROOT}/manifests/validation/cross-node-job.yaml")"
  kc -n "${NAMESPACE}" apply -f - <<<"${manifest}" >/dev/null
  kc -n "${NAMESPACE}" wait --for=condition=complete "job/${name}" --timeout=300s >/dev/null ||
    { kc -n "${NAMESPACE}" logs "job/${name}" 2>&1 | tail -3; return 1; }
  pod_node="$(kc -n "${NAMESPACE}" get pod -l "job-name=${name}" -o jsonpath='{.items[0].spec.nodeName}')"
  svc_node="$(kc -n "${NAMESPACE}" get pod -l app=llm-inference -o jsonpath='{.items[0].spec.nodeName}')"
  [[ "${pod_node}" != "${svc_node}" ]] || { echo "client and server on same node ${pod_node}"; return 1; }
  model="$(kc -n "${NAMESPACE}" exec deploy/llm-inference -- printenv MODEL_NAME)"
  kc -n "${NAMESPACE}" logs "job/${name}" | grep -q "^${model}" ||
    { echo "client on ${pod_node} did not list ${model}"; return 1; }
  echo "client on ${pod_node} reached service on ${svc_node}"
}

check_metrics_server() {
  local lines
  lines="$(kc top nodes --no-headers)"
  [[ "$(wc -l <<<"${lines}" | tr -d ' ')" -ge 2 ]] || { echo "kubectl top returned <2 nodes"; return 1; }
  echo "kubectl top nodes OK"
}

check_dcgm() {
  local pf_pid metrics util used
  kc -n gpu-monitoring port-forward svc/dcgm-exporter "${LOCAL_PORT}:9400" >/dev/null 2>&1 &
  pf_pid=$!
  # shellcheck disable=SC2064
  trap "kill ${pf_pid} 2>/dev/null || true" RETURN
  for _ in $(seq 1 30); do
    kill -0 "${pf_pid}" 2>/dev/null || { echo "port-forward exited"; return 1; }
    metrics="$(curl -fsS --max-time 3 "http://127.0.0.1:${LOCAL_PORT}/metrics" 2>/dev/null)" && break
    sleep 1
  done
  [[ -n "${metrics:-}" ]] || { echo "no response from dcgm-exporter"; return 1; }
  util="$(grep -m1 '^DCGM_FI_DEV_GPU_UTIL' <<<"${metrics}" || true)"
  used="$(grep -m1 '^DCGM_FI_DEV_FB_USED' <<<"${metrics}" || true)"
  [[ -n "${util}" && -n "${used}" ]] || { echo "missing DCGM_FI_DEV_GPU_UTIL / FB_USED series"; return 1; }
  echo "${util##* } util, ${used##* } MiB framebuffer used"
}

if [[ -z "${GPU_NODE}" || -z "${CPU_NODE}" ]]; then
  record "nodes" FAIL "need one node labelled ${GPU_LABEL_KEY}=true and one without"
else
  run_check "1 versions-and-ready" check_versions
  run_check "2 gpu-runtimeclass" check_runtimeclass
  run_check "3 gpu-allocatable" check_allocatable
  run_check "4 device-plugin" check_device_plugin
  run_check "5 workload-placement" check_workload_placement
  run_check "6 gpu-in-pod" check_gpu_in_pod
  run_check "7 inference" check_inference
  run_check "8 model-on-gpu" check_gpu_used
  run_check "9 cross-node-network" check_cross_node
  run_check "10 metrics-server" check_metrics_server
  run_check "11 dcgm-metrics" check_dcgm
fi

echo
if [[ "${failed}" -eq 0 ]]; then
  echo "GPU VALIDATION PASSED"
else
  echo "GPU VALIDATION FAILED" >&2
  exit 1
fi
