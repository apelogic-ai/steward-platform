#!/usr/bin/env bash
# Server-side apply the plain manifests that the BOM pins for one or more
# dependencies (dependencies.<name>.manifests), after checking each download
# against its pinned SHA-256. Server-side apply updates CRDs on upgrade and has
# no client-side annotation size limit, which the large Gateway API and Envoy
# Gateway CRDs would exceed.
#
# The helmfile runs it as a presync hook of the envoy-gateway release.
#
# Usage: scripts/apply-manifests.sh [--context CONTEXT] [--url DEPENDENCY=URL]... DEPENDENCY...
#   --url  download the dependency's manifest from URL, a registry mirror
#          (registry.manifests in the platform values), instead of the BOM URL.
#          The download is still checked against the BOM SHA-256. Only for a
#          dependency that pins exactly one manifest.
# Env:   BOM (default: bom/bom.json); KUBECONFIG as usual.
#        PLATFORM_NETRC_FILE  a netrc file with the mirror's credentials
#                             (curl --netrc-file), when it needs them.
# Needs: kubectl, jq, curl, sha256sum (or shasum).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bom="${BOM:-${repo_root}/bom/bom.json}"
usage() { echo "usage: $0 [--context CONTEXT] [--url DEPENDENCY=URL]... DEPENDENCY..." >&2; exit 2; }
context=()
overrides=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --context) [[ "$#" -ge 2 ]] || usage; [[ -n "$2" ]] && context=(--context "$2"); shift 2 ;;
    --url) [[ "$#" -ge 2 && "$2" == ?*=https://?* ]] || usage; overrides+=("$2"); shift 2 ;;
    -*) usage ;;
    *) break ;;
  esac
done
[[ "$#" -ge 1 ]] || usage
netrc=()
[[ -n "${PLATFORM_NETRC_FILE:-}" ]] && netrc=(--netrc-file "${PLATFORM_NETRC_FILE}")

# The mirror URL for a dependency, or nothing.
override_for() {
  local entry
  for entry in ${overrides[@]+"${overrides[@]}"}; do
    [[ "${entry%%=*}" == "$1" ]] && { echo "${entry#*=}"; return; }
  done
  return 0
}
for entry in ${overrides[@]+"${overrides[@]}"}; do
  dependency="${entry%%=*}"
  [[ " $* " == *" ${dependency} "* ]] || { echo "--url names ${dependency}, which is not applied" >&2; exit 2; }
  [[ "$(jq --arg d "${dependency}" '.dependencies[$d].manifests // [] | length' "${bom}")" == 1 ]] \
    || { echo "--url ${dependency}: the BOM must pin exactly one manifest for it" >&2; exit 2; }
done

for tool in kubectl jq curl; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done
sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

for dependency in "$@"; do
  manifests="$(jq -r --arg d "${dependency}" --arg url "$(override_for "${dependency}")" \
    '.dependencies[$d].manifests // [] | .[] | "\(if $url != "" then $url else .url end)\t\(.digest)"' "${bom}")"
  [[ -n "${manifests}" ]] || { echo "the BOM pins no manifests for ${dependency}" >&2; exit 1; }
  index=0
  while IFS=$'\t' read -r url digest; do
    index=$((index + 1))
    file="${work}/${dependency}-${index}.yaml"
    curl --fail --silent --show-error --location --retry 3 ${netrc[@]+"${netrc[@]}"} --output "${file}" "${url}"
    actual="sha256:$(sha256_of "${file}")"
    if [[ "${actual}" != "${digest}" ]]; then
      echo "${url} has digest ${actual}, BOM pins ${digest}" >&2
      exit 1
    fi
    kubectl ${context[@]+"${context[@]}"} apply --server-side --field-manager=steward-platform -f "${file}" >/dev/null
    echo "applied ${dependency} ${url} (${digest})"
  done <<<"${manifests}"
done
