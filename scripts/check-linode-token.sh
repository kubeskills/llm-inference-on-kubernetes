#!/usr/bin/env bash
set -euo pipefail

# Pre-flight for `pulumi up`: is LINODE_TOKEN set, valid, and allowed to create
# what the base stack creates (instance, VPC, firewall)? Run it first, because
# `pulumi preview` passes even with no token or a fake one.
#
# Write access is probed by POSTing an INVALID body. An authorized token gets a
# 400 validation error and nothing is created; a bad or under-scoped token gets
# a 401. The token is never printed.
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v curl >/dev/null 2>&1 || die "missing: curl"
[[ -n "${LINODE_TOKEN:-}" ]] ||
  die "LINODE_TOKEN is not set in this shell. Export your Linode API token first (each terminal starts without it)."
[[ "${LINODE_TOKEN}" != *"..."* ]] ||
  die "LINODE_TOKEN still contains the '...' placeholder from the docs; use your real token."

failed=0
row() { printf '  %-34s %-5s %s\n' "$1" "$2" "$3"; }

read_check() { # LABEL PATH
  local code
  code="$(api_code GET "$2")"
  case "${code}" in
    200) row "$1" OK "read allowed" ;;
    401) row "$1" FAIL "HTTP 401: token invalid, expired, or missing this scope"; failed=1 ;;
    *) row "$1" FAIL "HTTP ${code}"; failed=1 ;;
  esac
}

write_check() { # LABEL PATH
  local code
  code="$(api_post_code "$2" '{}')"
  case "${code}" in
    400) row "$1" OK "create allowed (invalid probe rejected, nothing created)" ;;
    401|403) row "$1" FAIL "HTTP ${code}: token cannot create this; add read/write for it"; failed=1 ;;
    2??) row "$1" WARN "HTTP ${code}: probe unexpectedly succeeded; check the account for a stray object"; failed=1 ;;
    *) row "$1" FAIL "HTTP ${code}"; failed=1 ;;
  esac
}

echo "checking LINODE_TOKEN against ${LINODE_API}"
read_check "token valid (list instances)" "/linode/instances?page_size=25"
write_check "create instances" "/linode/instances"
write_check "create VPCs" "/vpcs"
write_check "create firewalls" "/networking/firewalls"

# Needed only by `gpu-session.sh verify` (tag listing); not by the base stack.
code="$(api_code GET /tags/llm-inference-lab)"
if [[ "${code}" == 200 ]]; then
  row "list tags (GPU verify only)" OK "read allowed"
else
  row "list tags (GPU verify only)" WARN "HTTP ${code}: gpu-session.sh verify will fail without account read access"
fi

if [[ "${failed}" -ne 0 ]]; then
  echo "token check FAILED: fix the token before running pulumi up" >&2
  exit 1
fi
echo "token check passed"
