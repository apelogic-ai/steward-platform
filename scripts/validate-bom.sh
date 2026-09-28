#!/usr/bin/env bash
# Validate the BOM against the JSON schema, then check the cross-references
# that a schema cannot express.
#
# Usage: scripts/validate-bom.sh [path/to/bom.json]
# Needs: check-jsonschema, jq.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bom="${1:-${repo_root}/bom/bom.json}"
schema="${repo_root}/schemas/bom/v1.schema.json"

for tool in check-jsonschema jq; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

echo "schema: validating ${bom}"
check-jsonschema --schemafile "${schema}" "${bom}"

echo "semantics: checking cross-references"
errors="$(jq -r '
  def core_version: split("-")[0] | split("+")[0] | split(".") | map(tonumber);
  def minor: split(".")[0:2] | map(tonumber);

  . as $bom
  | ($bom.profiles | to_entries) as $profiles
  | [
      # Profiles reference only entries that exist.
      ($profiles[] | .key as $p | .value.products[]
        | select($bom.products[.] == null)
        | "profile \($p) lists product \(.) that is not in products"),
      ($profiles[] | .key as $p | .value.dependencies[]
        | select($bom.dependencies[.] == null)
        | "profile \($p) lists dependency \(.) that is not in dependencies"),

      # Every product belongs to at least one profile, or is pinned for a
      # profile that is not implemented yet (plannedFor): never both, and
      # never for a profile the BOM already defines.
      ($bom.products | to_entries[] | .key as $name | .value as $p
        | ([$profiles[] | select(.value.products | index($name)) | .key]) as $listed
        | (
            (select(($listed | length) == 0 and $p.plannedFor == null)
              | "product \($name) is not in any profile and has no plannedFor"),
            (select(($listed | length) > 0 and $p.plannedFor != null)
              | "product \($name) is in profiles \($listed) and also has plannedFor \($p.plannedFor)"),
            ($p.plannedFor // [] | .[] | select($bom.profiles[.] != null)
              | "product \($name): plannedFor profile \(.) is defined; list the product in it instead")
          )),

      # requiredFor must match the profiles that list the dependency.
      ($bom.dependencies | to_entries[] | .key as $name
        | ([$profiles[] | select(.value.dependencies | index($name)) | .key] | sort) as $listed
        | select((.value.requiredFor | sort) != $listed)
        | "dependency \($name): requiredFor \(.value.requiredFor | sort) does not match profiles \($listed)"),

      # A manifest taken from the chart of its dependency needs that chart.
      ($bom.dependencies | to_entries[] | .key as $name | .value as $d
        | ($d.manifests // [])[] | select(.fluxSource.chart != null and $d.chart == null)
        | "dependency \($name): manifest \(.url) takes fluxSource.chart, but the dependency pins no chart"),

      # Products: release page and attestation subjects are consistent.
      ($bom.products | to_entries[] | .key as $name | .value as $p
        | (
            (select($p.release != null and ($p.release | startswith($p.source + "/releases/tag/") | not))
              | "product \($name): release \($p.release) is not a release of \($p.source)"),
            (select($p.provenance != null and $p.release != null)
              | select(($p.release | split("/releases/tag/")[1]) != ($p.provenance.sourceRef | ltrimstr("refs/tags/")))
              | "product \($name): provenance.sourceRef \($p.provenance.sourceRef) does not match release \($p.release)"),
            (select($p.provenance != null)
              | (["chart" | select($p.chart != null)] + ($p.images // {} | keys)) as $known
              | $p.provenance.subjects[] as $s
              | select($known | index($s) | not)
              | "product \($name): attestation subject \($s) is neither the chart nor an image component"),
            (select($p.signatures != null and $p.release == null)
              | "product \($name): signatures need the release that carries the bundles"),
            (select($p.signatures != null)
              | (["chart" | select($p.chart != null)] + ($p.images // {} | keys)) as $known
              | $p.signatures.subjects | keys[] as $s
              | select($known | index($s) | not)
              | "product \($name): signature subject \($s) is neither the chart nor an image component"),
            (select($p.signatures != null)
              | ($p.source | ltrimstr("https://github.com/")) as $repository
              | select($p.signatures.certificateIdentity | startswith("https://github.com/\($repository)/.github/workflows/") | not)
              | "product \($name): signatures.certificateIdentity is not a workflow of \($p.source)")
          )),

      # Dependencies tested at several versions: the default is one of them,
      # every tested version is at or above minVersion and minVersion itself
      # is tested, and each tested entry has the same image components, tagged
      # with its version.
      ($bom.dependencies | to_entries[] | select(.value.tested != null) | .key as $name | .value as $d
        | ($d.minVersion | split(".") | map(tonumber)) as $min
        | ($d.tested | map(.version)) as $versions
        | (
            (select(($versions | unique | length) != ($versions | length))
              | "dependency \($name): tested versions are not unique"),
            (select([$d.tested[] | select(.version == $d.version and .images == $d.images)] | length == 0)
              | "dependency \($name): version \($d.version) and its images are not one of the tested entries"),
            (select([$versions[] | select(split(".")[0:($min | length)] | map(tonumber) == $min)] | length == 0)
              | "dependency \($name): minVersion \($d.minVersion) is not tested"),
            ($d.tested[] | .version as $v
              | (
                  (select(($v | split(".")[0:($min | length)] | map(tonumber)) < $min)
                    | "dependency \($name): tested \($v) is below minVersion \($d.minVersion)"),
                  (select((.images | keys) != ($d.images | keys))
                    | "dependency \($name): tested \($v) has images \(.images | keys), not \($d.images | keys)"),
                  (.images | to_entries[] | (.value | capture(":(?<tag>[^:@/]+)@").tag) as $tag
                    | select($tag != $v and ($tag | startswith($v + "-") | not))
                    | "dependency \($name): tested \($v) image \(.key) is tagged \($tag)")
                ))
          )),

      # Declared minimum peer versions hold for peers that are in the BOM.
      ($bom.products | to_entries[] | .key as $name
        | (.value.minPeers // {}) | to_entries[]
        | select($bom.products[.key] != null)
        | select(($bom.products[.key].version | core_version) < (.value | core_version))
        | "product \($name) needs \(.key) >= \(.value), BOM has \($bom.products[.key].version)"),

      # Kubernetes: tested versions cover both ends of the range and nothing outside it.
      ($bom.kubernetes as $k
        | ($k.minVersion | minor) as $min
        | ($k.maxVersion | minor) as $max
        | ([$k.tested[].version | minor]) as $tested
        | (
            (select($min > $max) | "kubernetes: minVersion \($k.minVersion) is above maxVersion \($k.maxVersion)"),
            (select($tested | index([$min]) | not) | "kubernetes: minVersion \($k.minVersion) is not tested"),
            (select($tested | index([$max]) | not) | "kubernetes: maxVersion \($k.maxVersion) is not tested"),
            ($k.tested[] | select((.version | minor) < $min or (.version | minor) > $max)
              | "kubernetes: tested \(.version) is outside \($k.minVersion)-\($k.maxVersion)"),
            (select(($k.tested | map(.version) | unique | length) != ($k.tested | length))
              | "kubernetes: tested versions are not unique"),
            ($k.tested[] | . as $t | select($t.nodeImage | contains(":v\($t.version)@") | not)
              | "kubernetes: node image \($t.nodeImage) is not tagged v\($t.version)")
          ))
    ]
  | .[]
' "${bom}")"

if [[ -n "${errors}" ]]; then
  printf 'error: %s\n' "${errors}" >&2
  exit 1
fi
jq -r '.products | to_entries[] | select(.value.plannedFor != null)
  | "info: product \(.key) is pinned for \(.value.plannedFor | join(", ")), which this BOM does not implement: its artifacts are verified, but no profile installs it and no end-to-end test exercises it"' "${bom}"
echo "ok: $(jq -r .platformVersion "${bom}")"
