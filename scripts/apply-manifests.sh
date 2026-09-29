#!/usr/bin/env bash
# Server-side apply the plain manifests that the BOM pins for one or more
# dependencies (dependencies.<name>.manifests), after checking each download
# against its pinned SHA-256. Server-side apply updates CRDs on upgrade and has
# no client-side annotation size limit, which the large Gateway API and Envoy
# Gateway CRDs would exceed.
#
# The helmfile runs it as a presync hook of the envoy-gateway release, with
# --context set to the kube context of that release.
#
# Usage: scripts/apply-manifests.sh [--context CONTEXT] [--url DEPENDENCY=URL]... DEPENDENCY...
#   --context  the kubeconfig context to apply to. The helmfile passes the
#              context its releases use: helmfile's --kube-context (or
#              HELMFILE_KUBE_CONTEXT), else the release's or the helmfile
#              environment's kubeContext. Empty is the same as absent.
#   --url      download the dependency's manifest from URL, a registry mirror
#              (registry.manifests in the platform values), instead of the BOM URL.
#              The download is still checked against the BOM SHA-256. Only for a
#              dependency that pins exactly one manifest.
# Env:   BOM (default: bom/bom.json); KUBECONFIG as usual.
#        PLATFORM_KUBE_CONTEXT  optional. With --context, the two must be equal.
#                               Without it, it must equal the current kubeconfig
#                               context, which is where helmfile installs the
#                               releases when it has no context of its own.
#        PLATFORM_NETRC_FILE  a netrc file with the mirror's credentials
#                             (curl --netrc-file), when it needs them.
# Needs: kubectl, jq, curl, sha256sum (or shasum).
#
# It never applies to an implicit context: with neither --context nor
# PLATFORM_KUBE_CONTEXT it refuses, and every kubectl call names the context.
# helmfile does not pass its --kubeconfig flag to hooks, so when the parent
# helmfile was given one the script refuses; select the kubeconfig file with
# the KUBECONFIG environment variable instead, which Helm and kubectl both read.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bom="${BOM:-${repo_root}/bom/bom.json}"
usage() { echo "usage: $0 [--context CONTEXT] [--url DEPENDENCY=URL]... DEPENDENCY..." >&2; exit 2; }
die() { echo "apply-manifests: $*" >&2; exit 1; }
context=""
overrides=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --context) [[ "$#" -ge 2 ]] || usage; context="$2"; shift 2 ;;
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

# --- The target cluster -------------------------------------------------------
# The command line of the parent process, one argument per line, when the
# parent is helmfile; nothing otherwise.
helmfile_parent_args() {
  local name=""
  if [[ -r "/proc/${PPID}/comm" ]]; then
    name="$(cat "/proc/${PPID}/comm" 2>/dev/null || true)"
  else
    name="$(ps -o comm= -p "${PPID}" 2>/dev/null || true)"
  fi
  [[ "${name##*/}" == helmfile* ]] || return 0
  if [[ -r "/proc/${PPID}/cmdline" ]]; then
    tr '\0' '\n' < "/proc/${PPID}/cmdline" 2>/dev/null || true
  else
    ps -ww -o args= -p "${PPID}" 2>/dev/null | tr ' ' '\n' || true
  fi
}
parent_args="$(helmfile_parent_args)"
if grep -Eq -- '^--kubeconfig(=|$)' <<<"${parent_args}"; then
  die "refusing to apply: helmfile was run with --kubeconfig, which it does not pass to hooks, so this hook could reach a different cluster than the releases. Run helmfile with KUBECONFIG=<file> in the environment instead of --kubeconfig."
fi

platform_context="${PLATFORM_KUBE_CONTEXT:-}"
if [[ -n "${context}" && -n "${platform_context}" && "${context}" != "${platform_context}" ]]; then
  die "refusing to apply: the release's kube context is '${context}' but PLATFORM_KUBE_CONTEXT is '${platform_context}'. Unset PLATFORM_KUBE_CONTEXT or make the two equal."
fi
if [[ -z "${context}" && -z "${platform_context}" ]]; then
  die "refusing to apply: no kube context. Run helmfile with --kube-context <context> (or set HELMFILE_KUBE_CONTEXT); this hook never falls back to the current kubeconfig context."
fi
if [[ -z "${context}" ]]; then
  # helmfile has no context of its own, so Helm installs the releases into the
  # current context. Apply only if that is PLATFORM_KUBE_CONTEXT.
  current="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "${current}" != "${platform_context}" ]]; then
    die "refusing to apply: PLATFORM_KUBE_CONTEXT is '${platform_context}', but helmfile was run without --kube-context, so its releases go to the current context '${current:-<none>}'. Run helmfile with --kube-context ${platform_context}."
  fi
  context="${platform_context}"
fi
kubectl config get-contexts "${context}" >/dev/null 2>&1 \
  || die "refusing to apply: kube context '${context}' is not in the kubeconfig (${KUBECONFIG:-the default kubeconfig})."
echo "applying to kube context ${context}"
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
    kubectl --context "${context}" apply --server-side --field-manager=steward-platform -f "${file}" >/dev/null
    echo "applied ${dependency} ${url} (${digest})"
  done <<<"${manifests}"
done
