#!/usr/bin/env bash
# Check that every artifact pinned in the BOM resolves anonymously, and that
# each tag still points at the pinned digest. A moved tag fails for product
# artifacts, whose release tags are immutable, and warns for external
# dependencies and node images, whose upstreams may rebuild a tag. The pinned
# digest is what gets installed either way.
#
# Usage: scripts/verify-digests.sh [--built-lock LOCK] [path/to/bom.json]
#        scripts/verify-digests.sh --mirror PLATFORM_VALUES [--profile NAME] [--installed] [path/to/bom.json]
# The images of every tested version of a dependency are checked too (the
# default version's once).
# A manifest's Git fluxSource is checked the same way: its tag still names its
# commit, or a warning (Flux checks out the commit either way).
#
# --mirror checks a registry mirror instead of upstream: every artifact whose
# class the platform values mirror (scripts/mirror-list.sh: all of the BOM,
# one --profile, or with --installed what the install generated from the
# values pulls) resolves in the mirror at its BOM digest, with the caller's
# own registry credentials (the Docker config crane reads, DOCKER_CONFIG), and
# a mirrored tag that points elsewhere fails. A mirrored manifest must download
# with its BOM SHA-256 (PLATFORM_NETRC_FILE for credentials), and a mirrored Git
# repository must carry the tag at the BOM commit. Classes the values do not
# mirror are skipped; the default mode checks them upstream.
#
# With --built-lock LOCK (products built from source, docs/fork-and-build.md),
# the products the lock lists are checked against the lock instead, by
# scripts/verify-built-lock.sh with your own registry credentials; their
# upstream BOM artifacts are not checked. Everything else is checked as above.
# With --mirror, platform values in built mode (artifacts.source built) do the
# same with their artifacts.builtLock: the built products are checked against
# the lock and left out of the mirror list (they are never copied from
# upstream), and the mirrored classes of everything else, for example the
# dependency images, are checked in the mirror. --built-lock and --mirror are
# not combined; --mirror reads the lock from the platform values.
#
# Needs: crane, jq, curl, git, sha256sum (or shasum); with --mirror, also what
# scripts/mirror-list.sh needs; with a built-artifacts lock, also
# check-jsonschema.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bom="${repo_root}/bom/bom.json"
mirror_values=""
built_lock=""
list_options=()
usage() { echo "usage: $0 [--built-lock LOCK | --mirror PLATFORM_VALUES [--profile NAME] [--installed]] [path/to/bom.json]" >&2; exit 2; }
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --built-lock) [[ "$#" -ge 2 ]] || usage; built_lock="$2"; shift 2 ;;
    --mirror) [[ "$#" -ge 2 ]] || usage; mirror_values="$2"; shift 2 ;;
    --profile) [[ "$#" -ge 2 ]] || usage; list_options+=(--profile "$2"); shift 2 ;;
    --installed) list_options+=(--installed); shift ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) bom="$1"; shift ;;
  esac
done
[[ "${#list_options[@]}" == 0 || -n "${mirror_values}" ]] || usage
[[ -z "${built_lock}" || -z "${mirror_values}" ]] || usage

for tool in crane jq curl git; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# The commit a remote tag names (the peeled commit of an annotated tag), or
# nothing.
tag_commit() {
  local refs
  refs="$(git ls-remote "$1" "refs/tags/$2" "refs/tags/$2^{}")" || return 1
  awk -v tag="refs/tags/$2" '$2 == tag "^{}" { peeled = $1 } $2 == tag { plain = $1 }
    END { print (peeled != "" ? peeled : plain) }' <<<"${refs}"
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# Platform values in built mode name their lock, relative to the values file
# unless absolute (as scripts/generate.sh reads it).
if [[ -n "${mirror_values}" ]]; then
  command -v yq >/dev/null || { echo "missing yq" >&2; exit 2; }
  if [[ "$(yq -r '.artifacts.source // "bom"' "${mirror_values}")" == built ]]; then
    built_lock="$(yq -r '.artifacts.builtLock' "${mirror_values}")"
    [[ "${built_lock}" == /* ]] || built_lock="$(dirname "${mirror_values}")/${built_lock}"
  fi
fi

# Built products: check them against the lock, with the caller's registry
# credentials (before the anonymous Docker config of the default mode).
built_failed=0
built_note=""
if [[ -n "${built_lock}" ]]; then
  "${repo_root}/scripts/verify-built-lock.sh" --bom "${bom}" "${built_lock}" || built_failed=1
  built_note="; the built products resolve at their lock digests"
  echo "info products in ${built_lock} were checked against it, not against their upstream BOM artifacts"
fi

if [[ -n "${mirror_values}" ]]; then
  list="$("${repo_root}/scripts/mirror-list.sh" --bom "${bom}" ${list_options[@]+"${list_options[@]}"} "${mirror_values}")"
  failures=0
  checked=0
  skipped=0
  netrc=()
  [[ -n "${PLATFORM_NETRC_FILE:-}" ]] && netrc=(--netrc-file "${PLATFORM_NETRC_FILE}")
  while IFS= read -r entry; do
    field() { jq -r "$1" <<<"${entry}"; }
    id="$(field .id)"
    if [[ "$(field .mirrored)" != true ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    checked=$((checked + 1))
    case "$(field .type)" in
      oci)
        target_ref="$(field .targetRef)"
        target="$(field .target)"
        digest="$(field .digest)"
        # crane checks that a manifest fetched by digest hashes to it.
        if ! manifest="$(crane manifest "${target_ref}" 2>&1)"; then
          echo "FAIL ${id}: ${target_ref} does not resolve in the mirror: ${manifest}" >&2
          failures=$((failures + 1))
          continue
        fi
        if [[ "$(field .artifact)" == chart ]] \
          && ! jq -e '.config.mediaType == "application/vnd.cncf.helm.config.v1+json"' <<<"${manifest}" >/dev/null; then
          echo "FAIL ${id}: ${target_ref} is not a Helm chart" >&2
          failures=$((failures + 1))
          continue
        fi
        if ! tagged="$(crane digest "${target}" 2>&1)"; then
          echo "warn ${id}: ${target_ref} resolves, but the mirror has no tag ${target##*:}"
        elif [[ "${tagged}" != "${digest}" ]]; then
          echo "FAIL ${id}: mirror tag ${target} points at ${tagged}, BOM pins ${digest}" >&2
          failures=$((failures + 1))
        else
          echo "ok   ${id}: ${target_ref}"
        fi
        ;;
      http)
        target="$(field .target)"
        digest="$(field .digest)"
        if ! actual="sha256:$(curl --fail --silent --show-error --location --retry 3 ${netrc[@]+"${netrc[@]}"} "${target}" | sha256_of)"; then
          echo "FAIL ${id}: ${target} could not be downloaded" >&2
          failures=$((failures + 1))
        elif [[ "${actual}" != "${digest}" ]]; then
          echo "FAIL ${id}: ${target} has digest ${actual}, BOM pins ${digest}" >&2
          failures=$((failures + 1))
        else
          echo "ok   ${id}: ${target}"
        fi
        ;;
      git)
        target="$(field .target)"
        tag="$(field .ref.tag)"
        commit="$(field '.ref.commit // ""')"
        if ! tagged="$(tag_commit "${target}" "${tag}" 2>&1)"; then
          echo "FAIL ${id}: ${target} could not be listed: ${tagged}" >&2
          failures=$((failures + 1))
        elif [[ -z "${tagged}" ]]; then
          echo "FAIL ${id}: ${target} has no tag ${tag}" >&2
          failures=$((failures + 1))
        elif [[ -z "${commit}" ]]; then
          # The platform tag: the BOM pins no commit, so compare with upstream.
          upstream="$(tag_commit "$(field .source)" "${tag}" 2>/dev/null || true)"
          if [[ -n "${upstream}" && "${upstream}" != "${tagged}" ]]; then
            echo "FAIL ${id}: ${target} tag ${tag} names ${tagged}, upstream names ${upstream}" >&2
            failures=$((failures + 1))
          else
            echo "ok   ${id}: ${target} ${tag} at ${tagged}"
          fi
        elif [[ "${tagged}" != "${commit}" ]]; then
          echo "FAIL ${id}: ${target} tag ${tag} names ${tagged}, BOM pins ${commit}" >&2
          failures=$((failures + 1))
        else
          echo "ok   ${id}: ${target} ${tag} at ${commit}"
        fi
        ;;
    esac
  done < <(jq -c '.artifacts[]' <<<"${list}")
  if [[ "${checked}" == 0 ]]; then
    echo "${mirror_values} mirrors none of the ${skipped} artifacts; nothing to check" >&2
    exit 1
  fi
  if [[ "${failures}" != 0 ]]; then
    echo "${failures} of ${checked} mirrored artifacts failed" >&2
    exit 1
  fi
  if [[ "${built_failed}" != 0 ]]; then
    echo "the built-artifacts lock ${built_lock} failed its checks" >&2
    exit 1
  fi
  suffix=""
  [[ "${skipped}" != 0 ]] && suffix=" (${skipped} not mirrored, skipped)"
  echo "all ${checked} mirrored artifacts resolve in the mirror at their BOM digests${suffix}${built_note}"
  exit 0
fi

# Leave the built products out of the BOM checked anonymously below.
if [[ -n "${built_lock}" ]]; then
  jq --slurpfile lock "${built_lock}" '.products |= with_entries(select(.key as $name | $lock[0].products | has($name) | not))' \
    "${bom}" > "${work}/bom.json"
  bom="${work}/bom.json"
fi

# Anonymous access only: an empty Docker config hides any local credentials.
DOCKER_CONFIG="${work}/docker"
mkdir "${DOCKER_CONFIG}"
export DOCKER_CONFIG

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
      if ! tagged="$(tag_commit "${repository}" "${tag}" 2>&1)"; then
        echo "FAIL ${label}: ${repository} could not be listed: ${tagged}" >&2
        failures=$((failures + 1))
        continue
      fi
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
if [[ "${built_failed}" != 0 ]]; then
  echo "the built-artifacts lock ${built_lock} failed its checks" >&2
  exit 1
fi
echo "all ${checked} artifacts resolve anonymously at their pinned digests${built_note}"
