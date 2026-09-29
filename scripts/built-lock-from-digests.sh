#!/usr/bin/env bash
# Write a built-artifacts lock (schemas/built-lock/v1.schema.json) from
# name=value pairs: the products you built from source and pushed to your own
# registry. See docs/fork-and-build.md.
#
# Usage: scripts/built-lock-from-digests.sh [--bom PATH] [--profile PROFILE] PAIR...
#
#   PRODUCT.source=URL          the Git repository you built from (https)
#   PRODUCT.commit=SHA          the full commit you built from
#   PRODUCT.allowSourceDrift=true
#                               accept a commit other than the BOM's (a fork
#                               with local patches); optional
#   PRODUCT.chart=oci://REGISTRY/REPOSITORY[:VERSION]@sha256:DIGEST
#                               the pushed chart; without VERSION, the BOM's
#                               chart version
#   PRODUCT.images.COMPONENT=REGISTRY/REPOSITORY[:TAG]@sha256:DIGEST
#                               each pushed image, by the BOM's component name
#
# PRODUCT is a BOM product name (products.<name>); each product's version is
# the BOM's. The lock goes to standard output, after it is checked against its
# schema and the BOM: with --profile, it must also cover every product that
# profile deploys. Needs: jq 1.7+, check-jsonschema.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bom="${repo_root}/bom/bom.json"
schema="${repo_root}/schemas/built-lock/v1.schema.json"
profile=""
pairs=()

usage() { echo "usage: $0 [--bom PATH] [--profile PROFILE] PRODUCT.FIELD=VALUE..." >&2; exit 2; }
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --bom) [[ "$#" -ge 2 ]] || usage; bom="$2"; shift 2 ;;
    --profile) [[ "$#" -ge 2 ]] || usage; profile="$2"; shift 2 ;;
    -h | --help) usage ;;
    -*) usage ;;
    *=*) pairs+=("$1"); shift ;;
    *) usage ;;
  esac
done
[[ "${#pairs[@]}" -gt 0 ]] || usage

for tool in jq check-jsonschema; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

fail() { echo "error: $*" >&2; exit 1; }

# Build the lock. Malformed pairs are errors, reported by jq.
lock="$(jq -n --slurpfile bom "${bom}" '
  def fail($m): error($m);
  $bom[0].products as $products
  | reduce ($ARGS.positional[] | capture("^(?<key>[^=]+)=(?<value>.*)$")) as $pair ({products: {}};
      ($pair.key | split(".")) as $path
      | $path[0] as $name
      | if $products[$name] == null then fail("\($pair.key): \($name) is not a product of the BOM") else . end
      | .products[$name].version = $products[$name].version
      | if $path == [$name, "source"] or $path == [$name, "commit"] then
          .products[$name][$path[1]] = $pair.value
        elif $path == [$name, "allowSourceDrift"] then
          if $pair.value == "true" then .products[$name].allowSourceDrift = true
          else fail("\($pair.key): the only value is true") end
        elif $path == [$name, "chart"] then
          ($pair.value | capture("^(?<reference>oci://[^@]+?)(:(?<version>[^:@/]+))?@(?<digest>sha256:[a-f0-9]{64})$")
            // fail("\($pair.key): not oci://REGISTRY/REPOSITORY[:VERSION]@sha256:DIGEST: \($pair.value)")) as $chart
          | .products[$name].chart = {
              reference: $chart.reference,
              version: ($chart.version // $products[$name].chart.version
                // fail("\($pair.key): the BOM pins no chart for \($name); give its version")),
              digest: $chart.digest
            }
        elif ($path | length) == 3 and $path[1] == "images" then
          .products[$name].images[$path[2]] = $pair.value
        else
          fail("\($pair.key): not PRODUCT.source, .commit, .allowSourceDrift, .chart or .images.COMPONENT")
        end)
  | .products |= with_entries(.value |= (
      {version, source, commit, allowSourceDrift, chart, images} | with_entries(select(.value != null))))
' --args "${pairs[@]}")" || fail "could not build the lock"

# Name what a product lacks before the schema does, in lock terms.
missing="$(jq -r '.products | to_entries[] | .key as $name | .value
  | (["source", "commit", "images"] - keys)[] | "products.\($name).\(.)"' <<<"${lock}")"
if [[ -n "${missing}" ]]; then
  while IFS= read -r field; do
    echo "error: ${field} is not set; pass ${field#products.}=..." >&2
  done <<<"${missing}"
  fail "the lock is incomplete"
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
jq . <<<"${lock}" > "${work}/built-lock.json"
check-jsonschema --schemafile "${schema}" "${work}/built-lock.json" >/dev/null || {
  check-jsonschema --schemafile "${schema}" "${work}/built-lock.json" >&2 || true
  fail "the lock does not match ${schema#"${repo_root}/"}"
}
problems="$(jq -r --slurpfile bom "${bom}" --arg profile "${profile}" -L "${repo_root}/scripts/lib" \
  'include "built"; built_lock_problems($bom[0]; if $profile == "" then null else $profile end) | .[]' \
  "${work}/built-lock.json")"
if [[ -n "${problems}" ]]; then
  while IFS= read -r problem; do
    echo "error: ${problem}" >&2
  done <<<"${problems}"
  fail "the lock does not match the BOM"
fi
jq -r --slurpfile bom "${bom}" -L "${repo_root}/scripts/lib" \
  'include "built"; built_lock_drift($bom[0]) | .[] | "warning: \(.)"' "${work}/built-lock.json" >&2
cat "${work}/built-lock.json"
