# shellcheck shell=bash
# Shared helpers. Source from other scripts; do not execute directly.
#
# Target selection is always explicit, so scripts never act on whatever
# happens to be the current kubectl context:
#   1. KUBE_CONTEXT=<name>   existing-cluster mode (default kubeconfig)
#   2. .lab/kubeconfig       lab mode (written by the Ansible bootstrap)
# Otherwise the script refuses to run.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_DIR="${LAB_DIR:-${REPO_ROOT}/.lab}"
LAB_KUBECONFIG="${LAB_KUBECONFIG:-${LAB_DIR}/kubeconfig}"

KUBECTL=(kubectl)
TARGET_DESC=""

die() {
  echo "error: $*" >&2
  exit 1
}

resolve_target() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    kubectl config get-contexts -o name | grep -Fxq -- "${KUBE_CONTEXT}" ||
      die "context '${KUBE_CONTEXT}' not found in your kubeconfig"
    KUBECTL=(kubectl --context "${KUBE_CONTEXT}")
    TARGET_DESC="context '${KUBE_CONTEXT}'"
  elif [[ -f "${LAB_KUBECONFIG}" ]]; then
    # Only this file is used; any inherited KUBECONFIG is ignored.
    export KUBECONFIG="${LAB_KUBECONFIG}"
    KUBECTL=(kubectl --kubeconfig "${LAB_KUBECONFIG}")
    TARGET_DESC="lab kubeconfig ${LAB_KUBECONFIG}"
  else
    die "no target cluster selected. Set KUBE_CONTEXT=<context> to use an existing cluster, or build the lab first (creates ${LAB_KUBECONFIG})."
  fi
}

# Name and API server of the selected target, for display and confirmation.
target_context_name() {
  "${KUBECTL[@]}" config view --minify -o jsonpath='{.contexts[0].name}'
}

target_server() {
  "${KUBECTL[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}'
}

describe_target() {
  echo "target: ${TARGET_DESC}"
  echo "  context: $(target_context_name)"
  echo "  server:  $(target_server)"
}

# ---------------------------------------------------------------------------
# Linode API helpers (used by the GPU session and reaper scripts).
# The token is passed to curl on stdin, never in argv, so it does not show up
# in `ps`.
LINODE_API="${LINODE_API:-https://api.linode.com/v4}"

# api_code METHOD PATH  -> prints only the HTTP status code
api_code() {
  [[ -n "${LINODE_TOKEN:-}" ]] || die "LINODE_TOKEN is not set"
  printf 'header = "Authorization: Bearer %s"\n' "${LINODE_TOKEN}" |
    curl -K - -sS -o /dev/null -w '%{http_code}' --max-time 30 \
      -X "$1" "${LINODE_API}$2"
}

# api_post_code PATH JSON  -> prints only the HTTP status code of a POST.
# Used to probe write authorization with a deliberately INVALID body: an
# authorized caller gets 400 (validation), a bad or under-scoped token gets 401.
api_post_code() {
  [[ -n "${LINODE_TOKEN:-}" ]] || die "LINODE_TOKEN is not set"
  printf 'header = "Authorization: Bearer %s"\n' "${LINODE_TOKEN}" |
    curl -K - -sS -o /dev/null -w '%{http_code}' --max-time 30 \
      -X POST -H 'Content-Type: application/json' -d "$2" "${LINODE_API}$1"
}

# api_get PATH  -> prints the JSON body; non-zero on a non-2xx response
api_get() {
  [[ -n "${LINODE_TOKEN:-}" ]] || die "LINODE_TOKEN is not set"
  printf 'header = "Authorization: Bearer %s"\n' "${LINODE_TOKEN}" |
    curl -K - -fsS --max-time 30 "${LINODE_API}$1"
}

# api_public_get PATH  -> unauthenticated GET (plan/pricing data is public)
api_public_get() {
  curl -fsS --max-time 30 "${LINODE_API}$1"
}

fmt_epoch() {
  date -r "$1" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null ||
    date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z'
}
