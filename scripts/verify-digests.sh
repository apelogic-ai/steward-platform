#!/usr/bin/env bash
# Check that every artifact pinned in the BOM resolves anonymously, and that
# each tag still points at the pinned digest. A moved tag fails for product
# artifacts, whose release tags are immutable, and warns for external
# dependencies and node images, whose upstreams may rebuild a tag. The pinned
# digest is what gets installed either way.
#
# Usage: scripts/verify-digests.sh [path/to/bom.json]
# The images of every tested version of a dependency are checked too (the
# default version's once).
# A manifest's Git fluxSource is checked the same way: its tag still names its
# commit, or a warning (Flux checks out the commit either way).
#
# Needs: crane, jq, curl, git, sha256sum (or shasum).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bom="${1:-${repo_root}/bom/bom.json}"

for tool in crane jq curl git; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

# Anonymous access only: an empty Docker config hides any local credentials.
DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
trap 'rm -rf "${DOCKER_CONFIG}"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# One line per artifact: kind <TAB> label <TAB> name:tag <TAB> digest
# (for manifests: url in place of name:tag; for Git sources: repository and
# tag, and the commit in place of the digest).
entries="$(jq -r '
  def image($label): capture("^(?<name>[^@]+)@(?<digest>sha256:[a-f0-9]{64})$")
    | ["image", $label, .name, .digest];
  def artifacts($kind):
    to_entries[] | .key as $k | .value
    | ((.images // {}) | to_entries[] | .key as $c | .value | image("\($kind).\($k).images.\($c)"))
    , (.images as $default | (.tested // [])[] | .version as $v | .images | to_entries[]
        | select(.value != $default[.key])
        | .key as $c | .value | image("\($kind).\($k).tested.\($v).images.\($c)"))
    , (.chart // empty | ["chart", "\($kind).\($k).chart", "\(.reference | ltrimstr("oci://")):\(.version)", .digest])
    , ((.manifests // [])[] | ["manifest", "\($kind).\($k).manifests", .url, .digest])
    , ((.manifests // [])[] | .fluxSource.git // empty
        | ["git", "\($kind).\($k).manifests.fluxSource", "\(.repository) \(.tag)", .commit]);
  (.products | artifacts("products")),
  (.dependencies | artifacts("dependencies")),
  (.kubernetes.tested[] | .version as $v | .nodeImage | image("kubernetes.tested.\($v)"))
  | @tsv
' "${bom}")"

failures=0
checked=0
while IFS=$'\t' read -r kind label name digest; do
  checked=$((checked + 1))
  case "${kind}" in
    image | chart)
      repository="${name%:*}"
      if ! manifest="$(crane manifest "${repository}@${digest}" 2>&1)"; then
        echo "FAIL ${label}: ${repository}@${digest} does not resolve anonymously: ${manifest}" >&2
        failures=$((failures + 1))
        continue
      fi
      if [[ "${kind}" == chart ]] \
        && ! jq -e '.config.mediaType == "application/vnd.cncf.helm.config.v1+json"' <<<"${manifest}" >/dev/null; then
        echo "FAIL ${label}: ${repository}@${digest} is not a Helm chart" >&2
        failures=$((failures + 1))
        continue
      fi
      if ! tagged="$(crane digest "${name}" 2>&1)"; then
        echo "FAIL ${label}: ${name} does not resolve anonymously: ${tagged}" >&2
        failures=$((failures + 1))
      elif [[ "${tagged}" != "${digest}" && "${label}" == products.* ]]; then
        echo "FAIL ${label}: tag ${name} now points at ${tagged}, BOM pins ${digest}" >&2
        failures=$((failures + 1))
      elif [[ "${tagged}" != "${digest}" ]]; then
        echo "warn ${label}: tag ${name} now points at ${tagged}; the pinned ${digest} still resolves"
      else
        echo "ok   ${label}: ${name}@${digest}"
      fi
      ;;
    manifest)
      if ! actual="sha256:$(curl --fail --silent --show-error --location --retry 3 "${name}" | sha256_of)"; then
        echo "FAIL ${label}: ${name} could not be downloaded" >&2
        failures=$((failures + 1))
      elif [[ "${actual}" != "${digest}" ]]; then
        echo "FAIL ${label}: ${name} has digest ${actual}, BOM pins ${digest}" >&2
        failures=$((failures + 1))
      else
        echo "ok   ${label}: ${name}"
      fi
      ;;
    git)
      repository="${name% *}"
      tag="${name##* }"
      # An annotated tag lists its commit as the peeled ^{} ref.
      if ! refs="$(git ls-remote "${repository}" "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>&1)"; then
        echo "FAIL ${label}: ${repository} could not be listed: ${refs}" >&2
        failures=$((failures + 1))
        continue
      fi
      tagged="$(awk -v tag="refs/tags/${tag}" '$2 == tag "^{}" { peeled = $1 } $2 == tag { plain = $1 }
        END { print (peeled != "" ? peeled : plain) }' <<<"${refs}")"
      if [[ -z "${tagged}" ]]; then
        echo "FAIL ${label}: ${repository} has no tag ${tag}" >&2
        failures=$((failures + 1))
      elif [[ "${tagged}" != "${digest}" ]]; then
        echo "warn ${label}: tag ${tag} of ${repository} now names ${tagged}; Flux checks out the pinned ${digest}"
      else
        echo "ok   ${label}: ${repository} ${tag} at ${digest}"
      fi
      ;;
  esac
done <<<"${entries}"

if [[ "${checked}" == 0 ]]; then
  echo "no artifacts found in ${bom}" >&2
  exit 1
fi
if [[ "${failures}" != 0 ]]; then
  echo "${failures} of ${checked} artifacts failed" >&2
  exit 1
fi
echo "all ${checked} artifacts resolve anonymously at their pinned digests"
