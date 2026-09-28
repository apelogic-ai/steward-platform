#!/usr/bin/env bash
# Verify the Sigstore (cosign) bundles that products attach to their GitHub
# releases instead of publishing GitHub artifact attestations. For every
# product with a `signatures` entry in the BOM:
#   - the release tag resolves to the pinned commit;
#   - the release manifest verifies against its bundle, signed by the declared
#     workflow at the pinned commit;
#   - the signed manifest names the pinned version and commit, every pinned
#     chart and image digest, and the pinned action commit (when there is one);
#   - each listed subject's bundle verifies for the pinned digest, signed by the
#     same workflow at the same commit.
# Everything is fetched anonymously from the public release. Only BOM
# coordinates are printed, never manifest contents.
#
# Usage: scripts/verify-signatures.sh [path/to/bom.json]
# Needs: cosign v3, jq, curl, git.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bom="${1:-${repo_root}/bom/bom.json}"

for tool in cosign jq curl git; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fetch_asset() {
  curl --fail --silent --show-error --location --retry 3 --output "$2" "$1"
}

failures=0
verified=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

products="$(jq -r '.products | to_entries[] | select(.value.signatures != null) | .key' "${bom}")"
if [[ -z "${products}" ]]; then
  echo "no signed products in ${bom}" >&2
  exit 1
fi

for product in ${products}; do
  p="$(jq -c --arg p "${product}" '.products[$p]' "${bom}")"
  source="$(jq -r .source <<<"${p}")"
  repository="${source#https://github.com/}"
  commit="$(jq -r .commit <<<"${p}")"
  version="$(jq -r .version <<<"${p}")"
  tag="$(jq -r '.release | split("/releases/tag/")[1]' <<<"${p}")"
  identity="$(jq -r .signatures.certificateIdentity <<<"${p}")"
  issuer="$(jq -r .signatures.certificateOidcIssuer <<<"${p}")"
  download="${source}/releases/download/${tag}"
  dir="${work}/${product}"
  mkdir -p "${dir}"
  cosign_identity=(--certificate-identity "${identity}" --certificate-oidc-issuer "${issuer}"
    --certificate-github-workflow-repository "${repository}"
    --certificate-github-workflow-sha "${commit}")

  # The release tag is the pinned commit. The signing workflow may run on a
  # branch, so the certificate binds the commit, and this binds the tag to it.
  tagged="$(git ls-remote --tags "${source}" "refs/tags/${tag}" "refs/tags/${tag}^{}" \
    | awk '{print $1}' | tail -1)"
  if [[ "${tagged}" != "${commit}" ]]; then
    fail "products.${product}: tag ${tag} of ${source} is ${tagged:-missing}, BOM pins ${commit}"
    continue
  fi

  manifest_asset="$(jq -r .signatures.releaseManifest.asset <<<"${p}")"
  manifest_bundle="$(jq -r .signatures.releaseManifest.bundle <<<"${p}")"
  if ! fetch_asset "${download}/${manifest_asset}" "${dir}/manifest.json" \
    || ! fetch_asset "${download}/${manifest_bundle}" "${dir}/manifest.sigstore.json"; then
    fail "products.${product}: cannot download ${manifest_asset} and its bundle from ${download}"
    continue
  fi
  if ! cosign verify-blob --bundle "${dir}/manifest.sigstore.json" "${cosign_identity[@]}" \
    "${dir}/manifest.json" >"${dir}/cosign.log" 2>&1; then
    fail "products.${product}: ${manifest_asset} does not verify as signed by ${identity} at ${commit}"
    sed 's/^/     /' "${dir}/cosign.log" >&2
    continue
  fi
  echo "ok   products.${product}: ${manifest_asset} signed by ${identity} at ${commit}"
  verified=$((verified + 1))

  # The signed manifest must name every pinned coordinate. Digests may appear
  # bare or inside a reference; only the BOM side is ever printed.
  mismatches="$(jq -r --argjson p "${p}" '
    [.. | strings] as $strings
    | def names($digest): any($strings[]; . == $digest or endswith("@" + $digest));
    (select(.version != $p.version) | "version is not \($p.version)"),
    (select(.commit != $p.commit) | "commit is not \($p.commit)"),
    ($p.chart // empty | .digest | select(names(.) | not) | "chart digest \(.) is missing"),
    ($p.images // {} | to_entries[] | .key as $c | .value | split("@")[1]
      | select(names(.) | not) | "image \($c) digest \(.) is missing"),
    ($p.action // empty | .commit | select(any($strings[]; . == $p.action.commit) | not)
      | "action commit \(.) is missing")
  ' "${dir}/manifest.json")"
  if [[ -n "${mismatches}" ]]; then
    while IFS= read -r line; do fail "products.${product}: signed ${manifest_asset}: ${line}"; done <<<"${mismatches}"
    continue
  fi
  echo "ok   products.${product}: signed ${manifest_asset} names version ${version}, commit ${commit} and every pinned digest"

  while IFS=$'\t' read -r subject asset digest; do
    label="products.${product}.${subject}"
    if [[ -z "${digest}" ]]; then
      fail "${label}: no pinned digest for signature subject ${subject}"
      continue
    fi
    if ! fetch_asset "${download}/${asset}" "${dir}/${asset}"; then
      fail "${label}: cannot download ${asset} from ${download}"
      continue
    fi
    if ! cosign verify-blob-attestation --bundle "${dir}/${asset}" \
      --type https://sigstore.dev/cosign/sign/v1 \
      --digest "${digest#sha256:}" --digestAlg sha256 \
      "${cosign_identity[@]}" >"${dir}/cosign.log" 2>&1; then
      fail "${label}: ${asset} does not verify ${digest} as signed by ${identity} at ${commit}"
      sed 's/^/     /' "${dir}/cosign.log" >&2
      continue
    fi
    verified=$((verified + 1))
    echo "ok   ${label}: ${digest} signed by ${identity} at ${commit}"
  done < <(jq -r '
    . as $p | .signatures.subjects | to_entries[]
    | [.key, .value,
       (if .key == "chart" then ($p.chart.digest // "")
        else (($p.images // {})[.key] // "" | split("@")[1] // "") end)]
    | @tsv' <<<"${p}")

  unsigned="$(jq -r '. as $p
    | (["chart" | select($p.chart != null)] + ($p.images // {} | keys))
    - ($p.signatures.subjects | keys) | .[]' <<<"${p}")"
  for subject in ${unsigned}; do
    echo "info products.${product}.${subject}: no signature bundle listed, not verified"
  done
done

if [[ "${failures}" != 0 ]]; then
  echo "${failures} signature checks failed" >&2
  exit 1
fi
echo "verified ${verified} signature bundles"
