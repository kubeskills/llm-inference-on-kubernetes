#!/usr/bin/env bash
set -euo pipefail

# Build an Ansible inventory from Pulumi stack outputs.
#   generate-inventory.sh [OUT]                 base inventory (server only)
#   generate-inventory.sh --session ID [OUT]    session inventory (server + gpu)
# Stacks are always passed explicitly; the "current" stack is never used.
# Base stack: BASE_STACK (default: lab).
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SESSION=""
if [[ "${1:-}" == "--session" ]]; then
  SESSION="${2:?usage: generate-inventory.sh --session ID [OUT]}"
  shift 2
fi

BASE_STACK="${BASE_STACK:-lab}"
if [[ -n "${SESSION}" ]]; then
  OUT="${1:-${LAB_DIR}/sessions/${SESSION}/inventory.yml}"
else
  OUT="${1:-${REPO_ROOT}/infra/ansible/inventory.yml}"
fi
KNOWN_HOSTS="${LAB_DIR}/known_hosts"

for bin in pulumi jq; do
  command -v "${bin}" >/dev/null 2>&1 || die "missing: ${bin}"
done

base="$(cd "${REPO_ROOT}/infra/pulumi/base" && pulumi stack output --json --stack "${BASE_STACK}")"
server_ip="$(jq -re '.server_ip' <<<"${base}")" ||
  die "base stack '${BASE_STACK}' has no server_ip; has 'pulumi up' completed?"
server_vpc_ip="$(jq -re '.server_vpc_ip' <<<"${base}")" ||
  die "base stack '${BASE_STACK}' has no server_vpc_ip"

gpu_ip="" gpu_vpc_ip=""
if [[ -n "${SESSION}" ]]; then
  gpu="$(cd "${REPO_ROOT}/infra/pulumi/gpu" && pulumi stack output --json --stack "gpu-${SESSION}")"
  gpu_ip="$(jq -re '.gpu_ip' <<<"${gpu}")" || die "stack gpu-${SESSION} has no gpu_ip"
  gpu_vpc_ip="$(jq -re '.gpu_vpc_ip' <<<"${gpu}")" || die "stack gpu-${SESSION} has no gpu_vpc_ip"
fi

mkdir -p "${LAB_DIR}" "$(dirname "${OUT}")"
chmod 700 "${LAB_DIR}"

# Ansible loads group_vars from next to the inventory file. A session inventory
# lives outside infra/ansible, so link the shared group_vars next to it;
# without this every variable (k3s_version, lab_hostname, ...) is undefined.
out_dir="$(cd "$(dirname "${OUT}")" && pwd)"
if [[ "${out_dir}" != "${REPO_ROOT}/infra/ansible" ]]; then
  ln -sfn "${REPO_ROOT}/infra/ansible/group_vars" "${out_dir}/group_vars"
fi

# Lab-only known_hosts. accept-new trusts a host on first connect only;
# Linode does not expose host keys out of band, so first contact is TOFU.
ssh_args="-o StrictHostKeyChecking=accept-new -o 'UserKnownHostsFile \"${KNOWN_HOSTS}\"'"
key_line=""
if [[ -n "${LAB_SSH_KEY:-}" ]]; then
  key_line="    ansible_ssh_private_key_file: $(jq -n --arg v "${LAB_SSH_KEY}" '$v')"
fi

{
  echo "---"
  echo "all:"
  echo "  vars:"
  echo "    ansible_user: root"
  [[ -n "${key_line}" ]] && echo "${key_line}"
  # A JSON string is a valid YAML scalar and handles quotes and spaces.
  echo "    ansible_ssh_common_args: $(jq -n --arg v "${ssh_args}" '$v')"
  echo "  children:"
  echo "    k3s_server:"
  echo "      hosts:"
  echo "        server-0:"
  echo "          ansible_host: ${server_ip}"
  echo "          k3s_node_ip: ${server_vpc_ip}"
  echo "    k3s_agent:"
  if [[ -n "${gpu_ip}" ]]; then
    echo "      hosts:"
    echo "        gpu-0:"
    echo "          ansible_host: ${gpu_ip}"
    echo "          k3s_node_ip: ${gpu_vpc_ip}"
  else
    echo "      hosts: {}"
  fi
  echo "    gpu:"
  if [[ -n "${gpu_ip}" ]]; then
    echo "      hosts:"
    echo "        gpu-0: {}"
  else
    echo "      hosts: {}"
  fi
} >"${OUT}"

echo "wrote ${OUT}"
