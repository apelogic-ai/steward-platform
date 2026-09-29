#!/usr/bin/env bash
# Check a built-artifacts lock (schemas/built-lock/v1.schema.json): the
# products an operator built from source and pushed to their own registry.
#   - the lock matches its schema and the BOM: each product's version, its
#     commit (unless allowSourceDrift, which warns), its chart version and
#     every chart and image the BOM pins; with --profile, every product that
#     profile deploys;
#   - unless --offline: every chart and image resolves in the operator's
#     registry at its lock digest, and each chart is a Helm chart. A tag given
#     with a digest that now points elsewhere warns; the digest is what gets
#     installed.
# Registry access uses the caller's own credentials (the Docker config that
# crane reads), since the operator's registry is usually private.
#
# Upstream signatures and attestations do not apply to artifacts you built:
# they name the upstream digests. See docs/fork-and-build.md#verification.
#
# Usage: scripts/verify-built-lock.sh [--bom PATH] [--profile PROFILE] [--offline] LOCK
# Needs: jq, check-jsonschema, and crane unless --offline.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bom="${repo_root}/bom/bom.json"
schema="${repo_root}/schemas/built-lock/v1.schema.json"
profile=""
offline=0
lock=""

usage() { echo "usage: $0 [--bom PATH] [--profile PROFILE] [--offline] LOCK" >&2; exit 2; }
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --bom) [[ "$#" -ge 2 ]] || usage; bom="$2"; shift 2 ;;
    --profile) [[ "$#" -ge 2 ]] || usage; profile="$2"; shift 2 ;;
    --offline) offline=1; shift ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) [[ -z "${lock}" ]] || usage; lock="$1"; shift ;;
  esac
done
[[ -n "${lock}" ]] || usage

tools=(jq check-jsonschema)
[[ "${offline}" == 1 ]] || tools+=(crane)
for tool in "${tools[@]}"; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

[[ -s "${lock}" ]] || { echo "error: ${lock} is missing or empty" >&2; exit 1; }
if ! check-jsonschema --schemafile "${schema}" "${lock}" >/dev/null; then
  check-jsonschema --schemafile "${schema}" "${lock}" >&2 || true
  echo "FAIL ${lock} does not match ${schema#"${repo_root}/"}" >&2
  exit 1
fi

failures=0
checked=0
problems="$(jq -r --slurpfile bom "${bom}" --arg profile "${profile}" -L "${repo_root}/scripts/lib" \
  'include "built"; built_lock_problems($bom[0]; if $profile == "" then null else $profile end) | .[]' "${lock}")"
if [[ -n "${problems}" ]]; then
  while IFS= read -r problem; do
    echo "FAIL ${problem}" >&2
    failures=$((failures + 1))
  done <<<"${problems}"
else
  echo "ok   the lock matches the BOM$([[ -z "${profile}" ]] || echo " and covers the ${profile} profile")"
fi
jq -r --slurpfile bom "${bom}" -L "${repo_root}/scripts/lib" \
  'include "built"; built_lock_drift($bom[0]) | .[] | "warn \(.)"' "${lock}"

if [[ "${offline}" == 1 ]]; then
  echo "skip registry checks (--offline): the lock's digests were not resolved"
else
  while IFS=$'\t' read -r kind label repository tag digest; do
    checked=$((checked + 1))
    if ! manifest="$(crane manifest "${repository}@${digest}" 2>&1)"; then
      echo "FAIL ${label}: ${repository}@${digest} does not resolve: ${manifest}" >&2
      failures=$((failures + 1))
      continue
    fi
    if [[ "${kind}" == chart ]] \
      && ! jq -e '.config.mediaType == "application/vnd.cncf.helm.config.v1+json"' <<<"${manifest}" >/dev/null; then
      echo "FAIL ${label}: ${repository}@${digest} is not a Helm chart" >&2
      failures=$((failures + 1))
      continue
    fi
    if [[ "${tag}" == - ]]; then
      echo "ok   ${label}: ${repository}@${digest}"
    elif ! tagged="$(crane digest "${repository}:${tag}" 2>&1)"; then
      echo "warn ${label}: tag ${repository}:${tag} does not resolve (${tagged}); the lock digest ${digest} does"
    elif [[ "${tagged}" != "${digest}" ]]; then
      echo "warn ${label}: tag ${repository}:${tag} points at ${tagged}; the lock digest ${digest} is what gets installed"
    else
      echo "ok   ${label}: ${repository}:${tag}@${digest}"
    fi
  done < <(jq -r -L "${repo_root}/scripts/lib" 'include "built"; built_lock_artifacts' "${lock}")
fi

echo "info upstream signatures and attestations do not apply to built artifacts: verify your own build provenance (docs/fork-and-build.md#verification)"
if [[ "${failures}" != 0 ]]; then
  echo "${failures} built-artifacts lock checks failed" >&2
  exit 1
fi
if [[ "${offline}" == 1 ]]; then
  echo "the built-artifacts lock matches its schema and the BOM"
else
  echo "the built-artifacts lock matches the BOM and all ${checked} artifacts resolve at their lock digests"
fi
