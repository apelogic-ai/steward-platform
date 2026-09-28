#!/usr/bin/env bash
# Server-side apply the plain manifests that the BOM pins for one or more
# dependencies (dependencies.<name>.manifests), after checking each download
# against its pinned SHA-256. Server-side apply updates CRDs on upgrade and has
# no client-side annotation size limit, which the large Gateway API and Envoy
# Gateway CRDs would exceed.
#
# The helmfile runs it as a presync hook of the envoy-gateway release.
#
# Usage: scripts/apply-manifests.sh [--context CONTEXT] DEPENDENCY...
# Env:   BOM (default: bom/bom.json); KUBECONFIG as usual.
# Needs: kubectl, jq, curl, sha256sum (or shasum).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bom="${BOM:-${repo_root}/bom/bom.json}"
context=()
if [[ "${1:-}" == --context ]]; then
  [[ "$#" -ge 2 ]] || { echo "usage: $0 [--context CONTEXT] DEPENDENCY..." >&2; exit 2; }
  [[ -n "$2" ]] && context=(--context "$2")
  shift 2
fi
[[ "$#" -ge 1 ]] || { echo "usage: $0 [--context CONTEXT] DEPENDENCY..." >&2; exit 2; }

for tool in kubectl jq curl; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done
sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

for dependency in "$@"; do
  manifests="$(jq -r --arg d "${dependency}" '.dependencies[$d].manifests // [] | .[] | "\(.url)\t\(.digest)"' "${bom}")"
  [[ -n "${manifests}" ]] || { echo "the BOM pins no manifests for ${dependency}" >&2; exit 1; }
  index=0
  while IFS=$'\t' read -r url digest; do
    index=$((index + 1))
    file="${work}/${dependency}-${index}.yaml"
    curl --fail --silent --show-error --location --retry 3 --output "${file}" "${url}"
    actual="sha256:$(sha256_of "${file}")"
    if [[ "${actual}" != "${digest}" ]]; then
      echo "${url} has digest ${actual}, BOM pins ${digest}" >&2
      exit 1
    fi
    kubectl ${context[@]+"${context[@]}"} apply --server-side --field-manager=steward-platform -f "${file}" >/dev/null
    echo "applied ${dependency} ${url} (${digest})"
  done <<<"${manifests}"
done
