#!/usr/bin/env bash
# jq filters are deliberately single-quoted: $vars in them belong to jq.
# shellcheck disable=SC2016
set -euo pipefail

# On-demand GPU session lifecycle. The GPU worker is EPHEMERAL: it is created
# only by `up` after you approve the cost, and `down` deletes the instance.
# The control plane and shared network (the base Pulumi stack) are never
# modified or deleted by anything in this script.
#
#   gpu-session.sh plan   --plan SLUG --hours N
#   gpu-session.sh up     --session ID --plan SLUG --hours N \
#                         --base-stack ORG/PROJECT/STACK --admin-cidr CIDR \
#                         --ssh-public-key 'ssh-ed25519 AAAA...'
#   gpu-session.sh status --session ID
#   gpu-session.sh verify --session ID
#   gpu-session.sh down   --session ID
#
# Every command names the session explicitly. The Pulumi stack is always
# gpu-<session> and is always passed with --stack; the "current" stack is never
# used. Requires LINODE_TOKEN (up/down/verify/status).
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GPU_MAX_HOURS="${GPU_MAX_HOURS:-12}"
GPU_NAMESPACE="llm-inference-gpu"
BASE_STACK_NAME="${BASE_STACK:-lab}"
SESSIONS_DIR="${LAB_DIR}/sessions"
PULUMI_GPU_DIR="${PULUMI_GPU_DIR:-${REPO_ROOT}/infra/pulumi/gpu}"
PULUMI_BASE_DIR="${PULUMI_BASE_DIR:-${REPO_ROOT}/infra/pulumi/base}"

usage() {
  sed -n '/^# On-demand/,/^# used (/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

# ---------------------------------------------------------------- arguments
SESSION="" PLAN="" HOURS="" BASE_STACK_REF="" ADMIN_CIDR="" SSH_KEY=""
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session) SESSION="${2:?}"; shift ;;
      --plan) PLAN="${2:?}"; shift ;;
      --hours) HOURS="${2:?}"; shift ;;
      --base-stack) BASE_STACK_REF="${2:?}"; shift ;;
      --admin-cidr) ADMIN_CIDR="${2:?}"; shift ;;
      --ssh-public-key) SSH_KEY="${2:?}"; shift ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
}

need_session() {
  [[ -n "${SESSION}" ]] || die "--session ID is required"
  [[ "${SESSION}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && ${#SESSION} -le 24 ]] ||
    die "session id must be lowercase letters/digits/dashes, max 24 chars"
  STACK="gpu-${SESSION}"
  SESSION_DIR="${SESSIONS_DIR}/${SESSION}"
  SESSION_FILE="${SESSION_DIR}/session.json"
}

need_tools() {
  local bin
  for bin in "$@"; do
    command -v "${bin}" >/dev/null 2>&1 || die "missing: ${bin}"
  done
}

session_update() { # JQ_FILTER [jq args...]
  local filter="$1" tmp
  shift
  tmp="$(mktemp)"
  jq "$@" "${filter}" "${SESSION_FILE}" >"${tmp}" && mv "${tmp}" "${SESSION_FILE}"
  chmod 600 "${SESSION_FILE}"
}

session_get() { jq -r ".$1 // empty" "${SESSION_FILE}"; }

# ------------------------------------------------------------- plan and cost
PLAN_LABEL="" PLAN_RATE="" PLAN_GPUS="" PLAN_VCPUS="" PLAN_RAM_MB="" EST_COST=""
load_plan() {
  [[ -n "${PLAN}" ]] || die "--plan SLUG is required"
  [[ -n "${HOURS}" ]] || die "--hours N is required (requested session duration)"
  [[ "${HOURS}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--hours must be a positive number"
  awk -v h="${HOURS}" -v m="${GPU_MAX_HOURS}" 'BEGIN{exit !(h>0 && h<=m)}' ||
    die "--hours must be > 0 and <= ${GPU_MAX_HOURS} (GPU_MAX_HOURS)"

  local t
  t="$(api_public_get "/linode/types/${PLAN}")" ||
    die "unknown Linode plan '${PLAN}'"
  PLAN_LABEL="$(jq -r '.label' <<<"${t}")"
  PLAN_RATE="$(jq -r '.price.hourly' <<<"${t}")"
  PLAN_GPUS="$(jq -r '.gpus // 0' <<<"${t}")"
  PLAN_VCPUS="$(jq -r '.vcpus' <<<"${t}")"
  PLAN_RAM_MB="$(jq -r '.memory' <<<"${t}")"
  [[ "${PLAN_GPUS}" -ge 1 ]] || die "plan '${PLAN}' has no GPU"
  EST_COST="$(awk -v r="${PLAN_RATE}" -v h="${HOURS}" 'BEGIN{printf "%.2f", r*h}')"
}

show_cost() {
  local expires="${1:-}"
  cat <<EOF

  GPU session cost summary
  ------------------------
  plan:               ${PLAN}  (${PLAN_LABEL})
  resources:          ${PLAN_GPUS} GPU, ${PLAN_VCPUS} vCPU, $((PLAN_RAM_MB / 1024)) GB RAM
  hourly rate:        \$${PLAN_RATE}/hr   (Linode public API)
  requested duration: ${HOURS} h
  ESTIMATED COST:     \$${EST_COST}   (compute only)
EOF
  [[ -z "${expires}" ]] || echo "  policy expiry:      $(fmt_epoch "${expires}")"
  cat <<EOF
  not included:       network transfer overage, taxes, the base server
  note:               billing runs until the instance is DELETED, not stopped.

EOF
}

# -------------------------------------------------------------------- report
STAGE="start"
REPORTED=0
report_failure() {
  local rc="$1"
  [[ "${REPORTED}" -eq 0 ]] || return 0
  REPORTED=1
  {
    echo
    echo "!! FAILED during stage: ${STAGE} (exit ${rc})"
    if [[ -f "${SESSION_FILE:-/nonexistent}" && "$(session_get status)" == "planned" ]]; then
      echo "!! Failure happened BEFORE provisioning: no cloud resources were created."
    else
      echo "!! Resources may already exist and ARE BILLING until deleted."
    fi
    echo "   session:      ${SESSION}"
    echo "   stack:        ${STACK}"
    if [[ -f "${SESSION_FILE:-/nonexistent}" ]]; then
      echo "   session file: ${SESSION_FILE}"
      echo "   instance id:  $(session_get instance_id)"
    fi
    echo "   Resources in the stack:"
    (cd "${PULUMI_GPU_DIR}" && pulumi stack --stack "${STACK}" --show-urns 2>&1 |
      grep -E 'linode:|URN|urn:' | sed 's/^/     /') || echo "     (could not read the stack)"
    echo
    echo "   Cleanup path:   ${0} down --session ${SESSION}"
    echo "   Check state:    ${0} status --session ${SESSION}"
    echo "   Backstop:       the reaper deletes it after expiry:"
    echo "                   ${REPO_ROOT}/scripts/gpu-reaper.sh --execute"
  } >&2
}

# Stages run as plain commands so errexit applies inside them; the ERR trap
# (armed in cmd_up once resources may exist) reports what was created.
stage() { # NAME COMMAND...
  STAGE="$1"
  shift
  echo ">> ${STAGE}"
  "$@"
}

confirm_typed() { # EXPECTED PROMPT
  [[ -t 0 && -r /dev/tty ]] ||
    die "approval must be given interactively on a terminal; refusing to continue"
  local answer=""
  STAGE="awaiting approval"
  read -r -p "$2" answer </dev/tty || { echo "error: no approval received" >&2; return 1; }
  [[ "${answer}" == "$1" ]] || { echo "error: not approved (expected '$1')" >&2; return 1; }
}

# Declined before provisioning: remove only LOCAL state (empty stack, session
# record). No cloud resource exists at this point.
discard_unapproved() {
  trap - ERR
  pulumi_gpu stack rm "${STACK}" --yes --non-interactive >/dev/null 2>&1 || true
  rm -rf "${SESSION_DIR}"
  die "not approved; nothing was provisioned and local session state was discarded"
}

# Expiry is a policy requirement and tags enforce nothing: refuse to create a
# billable GPU worker unless the independent reaper timer is active on the
# control plane. There is no bypass flag.
check_reaper_active() {
  local inv="${BASE_INVENTORY:-${REPO_ROOT}/infra/ansible/inventory.yml}"
  [[ -f "${inv}" ]] ||
    die "base inventory ${inv} not found; run scripts/generate-inventory.sh first"
  if ! (cd "${REPO_ROOT}/infra/ansible" &&
    ansible -i "${inv}" k3s_server -m ansible.builtin.command \
      -a 'systemctl is-active llm-gpu-reaper.timer' >/dev/null 2>&1); then
    die "the expiry reaper is not active on the control plane. Install it first: REAPER_LINODE_TOKEN=... ansible-playbook playbooks/reaper.yml (in infra/ansible)"
  fi
  echo "reaper: llm-gpu-reaper.timer is active on the control plane"
}

# ------------------------------------------------------------------ commands
cmd_plan() {
  need_tools curl jq awk
  load_plan
  show_cost ""
  echo "(plan only: nothing was created and no approval was requested)"
}

ensure_gpu_venv() {
  if [[ ! -x "${PULUMI_GPU_DIR}/venv/bin/python" ]]; then
    echo "creating ${PULUMI_GPU_DIR}/venv (one-time)"
    python3 -m venv "${PULUMI_GPU_DIR}/venv"
    "${PULUMI_GPU_DIR}/venv/bin/pip" install -q -r "${PULUMI_GPU_DIR}/requirements.txt"
  fi
}

pulumi_gpu() { (cd "${PULUMI_GPU_DIR}" && pulumi "$@"); }

setup_stack() {
  pulumi_gpu stack init "${STACK}" --non-interactive
  pulumi_gpu config set --stack "${STACK}" baseStack "${BASE_STACK_REF}"
  pulumi_gpu config set --stack "${STACK}" sessionId "${SESSION}"
  pulumi_gpu config set --stack "${STACK}" expiresEpoch "${EXPIRES}"
  pulumi_gpu config set --stack "${STACK}" gpuType "${PLAN}"
  pulumi_gpu config set --stack "${STACK}" adminCidr "${ADMIN_CIDR}"
  pulumi_gpu config set --stack "${STACK}" sshPublicKey "${SSH_KEY}"
}

provision() {
  pulumi_gpu up --stack "${STACK}" --yes --non-interactive
}

record_outputs() {
  local out
  out="$(pulumi_gpu stack output --stack "${STACK}" --json)"
  session_update '.instance_id=$i | .gpu_ip=$ip | .status="provisioned"' \
    --arg i "$(jq -r '.gpu_instance_id' <<<"${out}")" \
    --arg ip "$(jq -r '.gpu_ip' <<<"${out}")"
}

bootstrap() {
  BASE_STACK="${BASE_STACK_NAME}" "${REPO_ROOT}/scripts/generate-inventory.sh" --session "${SESSION}"
  (cd "${REPO_ROOT}/infra/ansible" &&
    ansible-playbook -i "${SESSION_DIR}/inventory.yml" playbooks/gpu-session.yml)
}

deploy_workload() {
  "${KUBECTL[@]}" apply -k "${REPO_ROOT}/manifests/overlays/gpu"
}

validate() {
  local ver node
  ver="$(awk -F': ' '/^k3s_version:/ {print $2}' "${REPO_ROOT}/infra/ansible/group_vars/all.yml")"
  node="$("${KUBECTL[@]}" get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[*].metadata.name}')"
  session_update '.node_name=$n' --arg n "${node%% *}"
  NAMESPACE="${GPU_NAMESPACE}" EXPECTED_K3S_VERSION="${ver}" \
    "${REPO_ROOT}/scripts/validate-gpu.sh"
}

cmd_up() {
  need_session
  # Fail fast, before creating anything: approval needs a human at a terminal.
  [[ -t 0 && -r /dev/tty ]] ||
    die "up must be run interactively on a terminal (approval is typed); refusing"
  need_tools curl jq awk pulumi ansible ansible-playbook kubectl python3
  [[ -n "${BASE_STACK_REF}" ]] || die "--base-stack ORG/PROJECT/STACK is required"
  [[ -n "${ADMIN_CIDR}" && -n "${SSH_KEY}" ]] || die "--admin-cidr and --ssh-public-key are required"
  [[ -f "${LAB_KUBECONFIG}" ]] ||
    die "base cluster kubeconfig not found at ${LAB_KUBECONFIG}; bootstrap the base lab first"
  [[ -n "${LINODE_TOKEN:-}" ]] || die "LINODE_TOKEN is not set"
  [[ ! -e "${SESSION_FILE}" ]] || die "session ${SESSION} already exists (${SESSION_FILE}); choose a new id or run down"
  load_plan

  # One GPU worker at a time (its VPC address is fixed).
  local other
  for other in "${SESSIONS_DIR}"/*/session.json; do
    [[ -e "${other}" ]] || continue
    if [[ "$(jq -r '.status' "${other}")" != "destroyed" ]]; then
      die "another session is not destroyed: $(jq -r '.session' "${other}"). Run: ${0} down --session $(jq -r '.session' "${other}")"
    fi
  done

  check_reaper_active

  # The GPU worker joins the lab cluster only.
  KUBE_CONTEXT="" resolve_target
  [[ "${KUBECTL[*]}" == *"${LAB_KUBECONFIG}"* ]] || die "GPU sessions must target the lab kubeconfig"
  describe_target

  local now
  now="$(date +%s)"
  EXPIRES="$(awk -v n="${now}" -v h="${HOURS}" 'BEGIN{printf "%d", n + h*3600}')"
  show_cost "${EXPIRES}"

  mkdir -p "${SESSION_DIR}"
  chmod 700 "${LAB_DIR}" "${SESSIONS_DIR}" "${SESSION_DIR}"
  set -E
  trap 'report_failure $?' ERR
  jq -n --arg s "${SESSION}" --arg st "${STACK}" --arg p "${PLAN}" \
    --arg r "${PLAN_RATE}" --arg h "${HOURS}" --arg c "${EST_COST}" \
    --arg b "${BASE_STACK_REF}" --argjson now "${now}" --argjson exp "${EXPIRES}" \
    '{session:$s, stack:$st, plan:$p, hourly:($r|tonumber), hours:($h|tonumber),
      estimated_cost:($c|tonumber), base_stack:$b, created_epoch:$now,
      expires_epoch:$exp, status:"planned", instance_id:"", gpu_ip:"", node_name:""}' \
    >"${SESSION_FILE}"
  chmod 600 "${SESSION_FILE}"

  ensure_gpu_venv
  stage "create stack ${STACK}" setup_stack
  stage "preview (read-only)" pulumi_gpu preview --stack "${STACK}" --non-interactive

  confirm_typed "${SESSION}" "Type the session id '${SESSION}' to APPROVE provisioning ~\$${EST_COST} of GPU compute: " ||
    discard_unapproved

  session_update '.status="provisioning"'
  stage "provision GPU instance" provision
  stage "record outputs" record_outputs
  stage "bootstrap (join K3s, GPU runtime)" bootstrap
  stage "deploy GPU workload" deploy_workload
  stage "validate (network, GPU allocation, inference)" validate
  session_update '.status="active"'
  trap - ERR

  cat <<EOF

GPU session ${SESSION} is ACTIVE and validated.
  instance id:  $(session_get instance_id)
  expires:      $(fmt_epoch "${EXPIRES}") (enforced by scripts/gpu-reaper.sh, not by this tag)
  tear down:    ${0} down --session ${SESSION}
EOF
}

cmd_status() {
  need_session
  need_tools jq pulumi
  [[ -f "${SESSION_FILE}" ]] || die "no session file at ${SESSION_FILE}"
  local exp now id code="n/a"
  exp="$(session_get expires_epoch)"
  now="$(date +%s)"
  id="$(session_get instance_id)"
  echo "session:     ${SESSION}   status: $(session_get status)"
  echo "plan:        $(session_get plan)  \$$(session_get hourly)/hr  est \$$(session_get estimated_cost)"
  echo "stack:       ${STACK}"
  echo "instance id: ${id:-<none yet>}"
  if [[ "${exp}" -gt "${now}" ]]; then
    echo "expires:     $(fmt_epoch "${exp}") (in $(((exp - now) / 60)) min)"
  else
    echo "expires:     $(fmt_epoch "${exp}") (EXPIRED $(((now - exp) / 60)) min ago)"
  fi
  if [[ -n "${id}" && -n "${LINODE_TOKEN:-}" ]]; then
    code="$(api_code GET "/linode/instances/${id}")"
    echo "cloud:       GET instance ${id} -> HTTP ${code} ($([[ "${code}" == 200 ]] && echo EXISTS-BILLING || echo gone))"
  fi
  echo "pulumi:      $(pulumi_gpu stack export --stack "${STACK}" 2>/dev/null | jq '[.deployment.resources[]? | select(.type|startswith("linode:"))] | length' 2>/dev/null || echo '?') linode resource(s) in state"
}

# Verifies that nothing session-owned is still billable and the base survived.
cmd_verify() {
  need_session
  need_tools curl jq pulumi
  [[ -f "${SESSION_FILE}" ]] || die "no session file at ${SESSION_FILE}"
  [[ -n "${LINODE_TOKEN:-}" ]] || die "LINODE_TOKEN is not set"
  local id code count tagged res exported server_id bad=0
  id="$(session_get instance_id)"

  chk() { printf '%-30s %-5s %s\n' "$1" "$2" "$3"; [[ "$2" == PASS ]] || bad=1; }

  if [[ -n "${id}" ]]; then
    code="$(api_code GET "/linode/instances/${id}")"
    if [[ "${code}" == "404" ]]; then
      chk "gpu instance deleted" PASS "GET ${id} -> 404"
    else
      chk "gpu instance deleted" FAIL "GET ${id} -> HTTP ${code} (still exists/billing)"
    fi
  else
    chk "gpu instance deleted" PASS "no instance id was ever recorded"
  fi

  if tagged="$(api_get "/tags/llm-session-${SESSION}" 2>/dev/null)"; then
    count="$(jq '.data | length' <<<"${tagged}")"
    if [[ "${count}" -eq 0 ]]; then
      chk "no tagged billable objects" PASS "tag llm-session-${SESSION}: 0 objects"
    else
      chk "no tagged billable objects" FAIL "$(jq -r '[.data[] | "\(.type) \(.data.id // .data.label)"] | join(", ")' <<<"${tagged}")"
    fi
  else
    chk "no tagged billable objects" FAIL "tag listing unavailable (needs account:read_only); verify manually"
  fi

  if exported="$(pulumi_gpu stack export --stack "${STACK}" 2>/dev/null)"; then
    res="$(jq '[.deployment.resources[]? | select(.type|startswith("linode:"))] | length' <<<"${exported}")"
  else
    res="gone"
  fi
  if [[ "${res}" == "gone" || "${res}" == "0" ]]; then
    chk "stack holds no resources" PASS "${res}"
  else
    chk "stack holds no resources" FAIL "${res} linode resource(s) still in ${STACK}"
  fi

  server_id="$(cd "${PULUMI_BASE_DIR}" && pulumi stack output server_instance_id --stack "${BASE_STACK_NAME}" 2>/dev/null || true)"
  if [[ -n "${server_id}" ]]; then
    code="$(api_code GET "/linode/instances/${server_id}")"
    if [[ "${code}" == "200" ]]; then
      chk "base control plane intact" PASS "server ${server_id} -> 200"
    else
      chk "base control plane intact" FAIL "server ${server_id} -> HTTP ${code}"
    fi
  else
    chk "base control plane intact" FAIL "could not read base server_instance_id"
  fi
  unset -f chk
  [[ "${bad}" -eq 0 ]] || { echo "VERIFY FAILED" >&2; return 1; }
  echo "VERIFIED: no session-owned billable resources remain; base preserved"
}

cmd_down() {
  need_session
  need_tools curl jq pulumi kubectl
  [[ -f "${SESSION_FILE}" ]] || die "no session file at ${SESSION_FILE}; refusing to guess what to delete"
  [[ -n "${LINODE_TOKEN:-}" ]] || die "LINODE_TOKEN is not set"
  local id node out_id
  id="$(session_get instance_id)"
  node="$(session_get node_name)"

  # The stack and the session record must agree before anything is deleted.
  out_id="$(pulumi_gpu stack output gpu_instance_id --stack "${STACK}" 2>/dev/null || true)"
  if [[ -n "${id}" && -n "${out_id}" && "${id}" != "${out_id}" ]]; then
    die "instance id mismatch: session file ${id} vs stack ${out_id}; refusing"
  fi

  cat <<EOF

TEARDOWN of GPU session ${SESSION}
  deletes:   Linode instance ${id:-<unknown>} and the session firewall (stack ${STACK})
  deletes:   Kubernetes namespace ${GPU_NAMESPACE} (and its PVC) and node '${node:-<unknown>}'
  preserves: the base stack (control plane, VPC, subnet, base firewall)
  cloud instance is DELETED, not stopped.

EOF
  confirm_typed "${SESSION}" "Type the session id '${SESSION}' to approve this teardown: " ||
    die "teardown not approved; nothing was changed"

  if [[ -f "${LAB_KUBECONFIG}" ]]; then
    KUBE_CONTEXT="" resolve_target
  fi
  echo ">> delete namespace ${GPU_NAMESPACE} (while the node is still alive, so the volume is cleaned)"
  if [[ -f "${LAB_KUBECONFIG}" ]]; then
    "${KUBECTL[@]}" delete namespace "${GPU_NAMESPACE}" --ignore-not-found --timeout=180s ||
      echo "   warning: namespace delete did not finish; continuing (the PV dies with the instance)" >&2
  fi

  echo ">> destroy stack ${STACK} (deletes the instance and firewall)"
  pulumi_gpu destroy --stack "${STACK}" --yes --non-interactive ||
    { echo "!! destroy failed; the instance may still be billing. Re-run: ${0} down --session ${SESSION}" >&2; exit 1; }

  if [[ -n "${node}" && -f "${LAB_KUBECONFIG}" ]]; then
    echo ">> delete stale node object ${node}"
    "${KUBECTL[@]}" delete node "${node}" --ignore-not-found --timeout=60s || true
  fi

  echo ">> remove stack ${STACK}"
  pulumi_gpu stack rm "${STACK}" --yes --non-interactive || true

  session_update '.status="destroyed" | .destroyed_epoch=$t' --argjson t "$(date +%s)"
  cmd_verify
}

# ---------------------------------------------------------------------- main
[[ $# -ge 1 ]] || usage
CMD="$1"
shift
parse_args "$@"
case "${CMD}" in
  plan) cmd_plan ;;
  up) cmd_up ;;
  status) cmd_status ;;
  verify) cmd_verify ;;
  down) cmd_down ;;
  *) usage ;;
esac
