#!/usr/bin/env bash
set -euo pipefail

# Independent expiry enforcement for GPU sessions. It needs ONLY a Linode token
# (curl + jq): no Pulumi, no Ansible, no session files, no cluster access.
#
# Expiry tags (llm-exp-<epoch>) are policy metadata; they delete nothing by
# themselves. THIS script is the enforcement. Run it on a schedule from a host
# that stays up (see infra/README.md). Default is a dry run.
#   gpu-reaper.sh              list what would be deleted
#   gpu-reaper.sh --execute    delete expired GPU session instances, by ID
#
# An instance is only ever deleted if ALL hold: it has the llm-gpu-session
# marker tag AND the llm-inference-lab tag, its label starts with "llm-gpu-",
# it is not tagged k3s-server, and its llm-exp-<epoch> tag has passed. The
# label and lab-tag checks exist because this account also holds unrelated
# resources (for example Kubernetes worker nodes); a wrongly tagged foreign
# instance is reported and left alone.
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXECUTE=0
NOW="$(date +%s)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) EXECUTE=1 ;;
    --now) NOW="${2:?--now needs an epoch}"; shift ;;
    *) die "usage: gpu-reaper.sh [--execute] [--now EPOCH]" ;;
  esac
  shift
done

if [[ -z "${LINODE_TOKEN:-}" && -n "${LINODE_TOKEN_CMD:-}" ]]; then
  LINODE_TOKEN="$(eval "${LINODE_TOKEN_CMD}")"
  export LINODE_TOKEN
fi
for bin in curl jq; do
  command -v "${bin}" >/dev/null 2>&1 || die "missing: ${bin}"
done

log() { printf '%s reaper: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

# Collect every instance (paginated).
all='[]'
page=1
while :; do
  resp="$(api_get "/linode/instances?page=${page}&page_size=100")"
  all="$(jq -c --argjson more "$(jq -c '.data' <<<"${resp}")" '. + $more' <<<"${all}")"
  pages="$(jq -r '.pages // 1' <<<"${resp}")"
  [[ "${page}" -lt "${pages}" ]] || break
  page=$((page + 1))
done

candidates="$(jq -c '
  [ .[]
    | select(.tags | index("llm-gpu-session"))
    | select((.tags | index("k3s-server")) | not)
    | { id, label, tags,
        session: ([.tags[] | select(startswith("llm-session-")) | sub("^llm-session-"; "")] | first // ""),
        expires: ([.tags[] | select(test("^llm-exp-[0-9]+$")) | sub("^llm-exp-"; "") | tonumber] | first // null) } ]' <<<"${all}")"

total="$(jq 'length' <<<"${candidates}")"
log "now=${NOW} ($(fmt_epoch "${NOW}")); ${total} GPU session instance(s) found; mode=$([[ "${EXECUTE}" -eq 1 ]] && echo EXECUTE || echo dry-run)"

failures=0
while IFS= read -r row; do
  [[ -n "${row}" ]] || continue
  id="$(jq -r '.id' <<<"${row}")"
  label="$(jq -r '.label' <<<"${row}")"
  session="$(jq -r '.session' <<<"${row}")"
  exp="$(jq -r '.expires // empty' <<<"${row}")"
  if [[ "${label}" != llm-gpu-* ]] || ! jq -e '.tags | index("llm-inference-lab")' <<<"${row}" >/dev/null; then
    log "WARN instance ${id} (${label}) carries the session marker but is not a lab GPU instance (label/lab-tag guard); NOT deleting, needs a human"
    continue
  fi
  if [[ -z "${exp}" ]]; then
    log "WARN instance ${id} (${label}) has no valid llm-exp-<epoch> tag; NOT deleting, needs a human"
    continue
  fi
  if [[ "${exp}" -gt "${NOW}" ]]; then
    log "ok   instance ${id} (${label}) session=${session} expires in $(((exp - NOW) / 60)) min"
    continue
  fi
  log "EXPIRED instance ${id} (${label}) session=${session} expired $(((NOW - exp) / 60)) min ago"
  if [[ "${EXECUTE}" -ne 1 ]]; then
    log "  dry-run: would DELETE /linode/instances/${id}"
    continue
  fi
  code="$(api_code DELETE "/linode/instances/${id}")"
  if [[ "${code}" != 2* ]]; then
    log "  FAILED to delete ${id}: HTTP ${code}"
    failures=$((failures + 1))
    continue
  fi
  after="$(api_code GET "/linode/instances/${id}")"
  if [[ "${after}" == "404" ]]; then
    log "  deleted ${id} (verified: GET returns 404)"
  else
    log "  deleted ${id} but GET still returns HTTP ${after}"
    failures=$((failures + 1))
  fi
  log "  reconcile Pulumi/K8s state later: scripts/gpu-session.sh down --session ${session}"
done < <(jq -c '.[]' <<<"${candidates}")

[[ "${failures}" -eq 0 ]] || exit 1
