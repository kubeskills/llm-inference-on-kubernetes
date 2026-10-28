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

# Linode reuses public IPs: a rebuilt machine can inherit a destroyed one's
# address while the lab's known_hosts still pins the old key, and SSH then
# refuses with "REMOTE HOST IDENTIFICATION HAS CHANGED". Pins are therefore tied
# to the INSTANCE ID. The pin for an address is kept while the same instance owns
# it (so a swapped host is still caught) and forgotten only when the instance
# behind that address changed, or was never recorded.
PIN_RECORD="${LAB_DIR}/known_host_instances"
forget_pin_if_instance_changed() { # IP INSTANCE_ID
  local ip="$1" id="$2" recorded="" tmp
  [[ -n "${id}" ]] || return 0
  if [[ -f "${PIN_RECORD}" ]]; then
    recorded="$(awk -v ip="${ip}" '$1 == ip {print $2}' "${PIN_RECORD}" | tail -1)"
  fi
  [[ "${recorded}" != "${id}" ]] || return 0
  if [[ -f "${KNOWN_HOSTS}" ]] && ssh-keygen -F "${ip}" -f "${KNOWN_HOSTS}" >/dev/null 2>&1; then
    ssh-keygen -R "${ip}" -f "${KNOWN_HOSTS}" >/dev/null 2>&1
    echo "forgot the old SSH host key pinned for ${ip} (instance ${recorded:-unrecorded} -> ${id}; Linode reuses addresses)"
  fi
  tmp="$(mktemp)"
  { [[ -f "${PIN_RECORD}" ]] && grep -v "^${ip} " "${PIN_RECORD}" || true; echo "${ip} ${id}"; } >"${tmp}"
  mv "${tmp}" "${PIN_RECORD}"
  chmod 600 "${PIN_RECORD}"
}
forget_pin_if_instance_changed "${server_ip}" "$(jq -r '.server_instance_id // empty' <<<"${base}")"
if [[ -n "${gpu_ip}" ]]; then
  forget_pin_if_instance_changed "${gpu_ip}" "$(jq -r '.gpu_instance_id // empty' <<<"${gpu}")"
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
