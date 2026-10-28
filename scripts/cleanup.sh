#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OVERLAY="${1:-cpu}"
[[ -d "${REPO_ROOT}/manifests/overlays/${OVERLAY}" ]] ||
  die "unknown overlay '${OVERLAY}' (expected cpu or gpu)"

resolve_target
describe_target

ctx="$(target_context_name)"
echo
echo "This DELETES the llm-inference namespace and everything in it"
echo "(including the model cache PVC) from the target above."
echo "It does NOT delete cloud instances. For the lab, run 'pulumi destroy'."
echo
read -r -p "Type the context name '${ctx}' to continue: " answer
[[ "${answer}" == "${ctx}" ]] || die "aborted"

"${KUBECTL[@]}" delete -k "${REPO_ROOT}/manifests/overlays/${OVERLAY}"
