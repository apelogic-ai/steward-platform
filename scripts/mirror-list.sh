#!/usr/bin/env bash
# List every artifact in the BOM, or in one BOM profile, with its source and
# the target the platform values' registry block mirrors it to, as JSON. This
# is the whole-platform copy list: the products (charts and images), the
# external dependencies (charts, images and CRD manifests), the Git sources the
# Flux output reads (the Gateway API CRDs and this repository's
# charts/steward-edge), for every product including those planned for a later
# profile. Kubernetes node images (kind, for tests) are not listed.
#
# Usage: scripts/mirror-list.sh [--bom PATH] [--profile NAME] [--installed] [--mirrored] PLATFORM_VALUES
#   --profile    only the artifacts of that BOM profile (its products and
#                dependencies, and charts/steward-edge for task-auth)
#   --installed  only the artifacts that the install generated from
#                PLATFORM_VALUES pulls (scripts/generate.sh): for example, of
#                Steward's images only the apiserver and controller for core,
#                and the evaluation PostgreSQL image only with the evaluation
#                database
#   --mirrored   only the artifacts whose class the platform values mirror
#
# Platform values in built mode (artifacts.source built, docs/fork-and-build.md)
# take the products their built-artifacts lock lists from the operator's own
# registry, never from upstream, so those products' charts and images are left
# out of the list; everything else, steward-run included, is listed as above.
#
# Output (steward-platform/mirror-list/v1):
#   {
#     "apiVersion": "steward-platform/mirror-list/v1",
#     "platformVersion": "...", "profile": "core" or null, "installed": false,
#     "artifacts": [
#       {"id": "products.steward.images.apiserver", "class": "productImages",
#        "type": "oci", "artifact": "image",
#        "source": "ghcr.io/apelogic-ai/steward:0.3.15-apiserver",
#        "digest": "sha256:...", "sourceRef": "ghcr.io/apelogic-ai/steward@sha256:...",
#        "target": "<mirror>/apelogic-ai/steward:0.3.15-apiserver",
#        "targetRef": "<mirror>/apelogic-ai/steward@sha256:...", "mirrored": true},
#       {"id": "...manifests.0", "class": "manifests", "type": "http",
#        "source": URL, "digest": "sha256:...", "target": URL, ...},
#       {"id": "...fluxSource.git", "class": "gitSources", "type": "git",
#        "source": URL, "ref": {"tag": ..., "commit": ...}, "target": URL, ...}
#     ]
#   }
# An "oci" entry is copied with its digest intact by copying sourceRef to
# target, for example: crane copy SOURCE_REF TARGET, oras cp -r SOURCE_REF
# TARGET, or skopeo copy --all --preserve-digests docker://SOURCE_REF
# docker://TARGET. See docs/registry-mirroring.md. A class the values do not
# mirror has "mirrored": false and target equal to source.
#
# Needs: jq 1.7+, yq (mikefarah) v4, check-jsonschema.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bom="${repo_root}/bom/bom.json"
schema="${repo_root}/schemas/platform-values/v1.schema.json"
profile=""
installed_only=false
mirrored_only=false
values_file=""

usage() { echo "usage: $0 [--bom PATH] [--profile NAME] [--installed] [--mirrored] PLATFORM_VALUES" >&2; exit 2; }
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --bom) [[ "$#" -ge 2 ]] || usage; bom="$2"; shift 2 ;;
    --profile) [[ "$#" -ge 2 ]] || usage; profile="$2"; shift 2 ;;
    --installed) installed_only=true; shift ;;
    --mirrored) mirrored_only=true; shift ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) [[ -z "${values_file}" ]] || usage; values_file="$1"; shift ;;
  esac
done
[[ -n "${values_file}" ]] || usage

for tool in jq yq check-jsonschema; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

check-jsonschema --schemafile "${schema}" "${values_file}" >/dev/null || {
  check-jsonschema --schemafile "${schema}" "${values_file}" >&2 || true
  echo "error: ${values_file} does not match ${schema#"${repo_root}/"}" >&2
  exit 1
}

# Built mode: the products of the lock (relative to the values file unless
# absolute, as scripts/generate.sh reads it), which are not copied.
built='[]'
if [[ "$(yq -r '.artifacts.source // "bom"' "${values_file}")" == built ]]; then
  built_lock="$(yq -r '.artifacts.builtLock' "${values_file}")"
  [[ "${built_lock}" == /* ]] || built_lock="$(dirname "${values_file}")/${built_lock}"
  built="$(jq -c '.products | keys' "${built_lock}")" || {
    echo "error: artifacts.builtLock ${built_lock} is not a readable built-artifacts lock" >&2
    exit 1
  }
fi

yq -o=json '.' "${values_file}" | jq --slurpfile bom "${bom}" --arg profile "${profile}" \
  --argjson installed_only "${installed_only}" --argjson mirrored_only "${mirrored_only}" \
  --argjson built "${built}" -L "${repo_root}/scripts/lib" '
  include "platform";
  ($profile | if . == "" then null else . end) as $p
  | mirror_collisions($bom[0]) as $_
  | (if $installed_only then [installed_artifacts($bom[0])[].id] else null end) as $installed
  | {
      apiVersion: "steward-platform/mirror-list/v1",
      platformVersion: $bom[0].platformVersion,
      profile: $p,
      installed: $installed_only,
      artifacts: [mirror_list($bom[0]; $p)[]
        | select(($installed == null) or (.id as $id | any($installed[]; . == $id)))
        | select(($mirrored_only | not) or .mirrored)
        | select(.id | split(".") as $id | $id[0] == "products" and ($built | index($id[1])) != null | not)]
    }'
