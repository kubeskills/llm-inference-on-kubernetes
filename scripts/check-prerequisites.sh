#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for bin in kubectl curl jq; do
  command -v "${bin}" >/dev/null 2>&1 || die "missing: ${bin}"
done

resolve_target
describe_target

"${KUBECTL[@]}" cluster-info >/dev/null || die "cluster is not reachable"

client_minor="$(kubectl version --client -o json | jq -r '.clientVersion.minor' | tr -dc '0-9')"
server_minor="$("${KUBECTL[@]}" version -o json | jq -r '.serverVersion.minor' | tr -dc '0-9')"
if [[ -n "${client_minor}" && -n "${server_minor}" ]]; then
  skew=$((client_minor - server_minor))
  if [[ "${skew#-}" -gt 1 ]]; then
    echo "warning: kubectl 1.${client_minor} vs server 1.${server_minor} is outside the supported +/-1 minor skew" >&2
  fi
fi

default_sc="$("${KUBECTL[@]}" get storageclass -o json |
  jq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")] | length')"
if [[ "${default_sc}" -lt 1 ]]; then
  echo "warning: no default StorageClass; set storageClassName in manifests/base/model-cache.yaml" >&2
fi

echo "prerequisites OK"
