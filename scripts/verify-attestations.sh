#!/usr/bin/env bash
# Verify the GitHub artifact attestations that products publish for their BOM
# artifacts. For every subject in products.<name>.provenance, require an
# attestation signed by the declared workflow at the declared tag, built on a
# GitHub-hosted runner, from the product's source repository at the pinned
# commit. Artifacts a product does not attest are reported, not failed.
#
# Usage: scripts/verify-attestations.sh [path/to/bom.json]
# Needs: gh (authenticated, for example GH_TOKEN), jq.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bom="${1:-${repo_root}/bom/bom.json}"

for tool in gh jq; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

# One line per artifact:
# product <TAB> subject <TAB> oci-uri <TAB> owner <TAB> identity <TAB> predicate <TAB> source <TAB> commit <TAB> attested
entries="$(jq -r '
  .products | to_entries[] | .key as $product | .value as $p
  | ($p.provenance // null) as $prov
  | (
      ($p.chart // empty | {subject: "chart", uri: "oci://\(.reference | ltrimstr("oci://"))@\(.digest)"}),
      (($p.images // {}) | to_entries[]
        | {subject: .key, uri: "oci://\(.value | sub(":[^:/@]+@"; "@"))"})
    )
  | .subject as $subject
  | [
      $product, $subject, .uri,
      ($p.source | split("/")[3]),
      (if $prov then "https://github.com/\($prov.signerWorkflow)@\($prov.sourceRef)" else "-" end),
      (if $prov then $prov.predicateType else "-" end),
      $p.source, $p.commit,
      (if $prov and ($prov.subjects | index($subject)) then "yes" else "no" end)
    ]
  | @tsv
' "${bom}")"

failures=0
verified=0
unattested=()
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

while IFS=$'\t' read -r product subject uri owner identity predicate source commit attested; do
  label="products.${product}.${subject}"
  if [[ "${attested}" != yes ]]; then
    unattested+=("${label} (${uri})")
    continue
  fi
  if ! gh attestation verify "${uri}" \
    --owner "${owner}" \
    --cert-identity "${identity}" \
    --predicate-type "${predicate}" \
    --deny-self-hosted-runners \
    --format json > "${work}/result.json" 2> "${work}/stderr"; then
    echo "FAIL ${label}: no valid attestation for ${uri}" >&2
    sed 's/^/     /' "${work}/stderr" >&2
    failures=$((failures + 1))
    continue
  fi
  if ! jq -e --arg source "${source}" --arg commit "${commit}" '
      length > 0 and all(.[].verificationResult.signature.certificate;
        .sourceRepositoryURI == $source and .sourceRepositoryDigest == $commit)
    ' "${work}/result.json" >/dev/null; then
    echo "FAIL ${label}: attestation for ${uri} does not name ${source} at ${commit}" >&2
    failures=$((failures + 1))
    continue
  fi
  verified=$((verified + 1))
  echo "ok   ${label}: ${identity}, commit ${commit}"
done <<<"${entries}"

if [[ "${#unattested[@]}" != 0 ]]; then
  printf 'info not attested upstream, not verified: %s\n' "${unattested[@]}"
fi
if [[ "${failures}" != 0 ]]; then
  echo "${failures} attestation checks failed" >&2
  exit 1
fi
if [[ "${verified}" == 0 ]]; then
  echo "no attested artifacts found in ${bom}" >&2
  exit 1
fi
echo "verified ${verified} attestations"
