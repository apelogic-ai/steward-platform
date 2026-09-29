#!/usr/bin/env bash
# Generate per-chart values and helmfile inputs from one platform values file
# and the BOM.
#
# Usage: scripts/generate.sh [--bom PATH] [--out DIR] PLATFORM_VALUES
#
# PLATFORM_VALUES must validate against schemas/platform-values/v1.schema.json.
# Output goes to DIR (default: generated/<environment>), which is replaced:
#   helmfile.yaml                       environment values for helmfile/helmfile.yaml.gotmpl
#   values/steward.yaml                 Steward chart values
#   values/cert-manager.yaml            when tls.certManager.install is true
#   values/evaluation-ca.yaml           when the evaluation CA issuer is used
#   values/postgresql-evaluation.yaml   when the evaluation database is used
#   values/github-oidc-exchange.yaml    task-auth, browser-admin: github-oidc-exchange chart values
#   values/steward-edge.yaml            task-auth: Steward's task API routes (charts/steward-edge);
#                                       browser-admin uses Steward's own web.httpRoute
#   values/envoy-gateway.yaml           task-auth, browser-admin, when edge.install is true
#   values/edge-evaluation-ca.yaml      task-auth, browser-admin, when the evaluation Gateway is used
#   values/evaluation-edge.yaml         task-auth, browser-admin, when the evaluation Gateway is used
#   flux/                               Flux objects for the same install, when no
#                                       evaluation piece is used: OCIRepository and
#                                       HelmRelease per release; for task-auth and
#                                       browser-admin with edge.install, also the CRD
#                                       sources and Kustomizations, and for task-auth
#                                       charts/steward-edge from this repository
#                                       (examples/flux/<profile> is this, for the
#                                       production-shaped environments)
#
# With artifacts.source built in PLATFORM_VALUES, the product charts and images
# come from the built-artifacts lock that artifacts.builtLock names (products
# built from source and pushed to the operator's registry), checked against
# the BOM; everything else is generated exactly as from the BOM alone. See
# docs/fork-and-build.md.
#
# The output depends only on the inputs: the same inputs give the same
# bytes. Needs: jq 1.7+, yq (mikefarah) v4, check-jsonschema.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bom="${repo_root}/bom/bom.json"
schema="${repo_root}/schemas/platform-values/v1.schema.json"
built_lock_schema="${repo_root}/schemas/built-lock/v1.schema.json"
out=""
values_file=""

usage() { echo "usage: $0 [--bom PATH] [--out DIR] PLATFORM_VALUES" >&2; exit 2; }
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --bom) [[ "$#" -ge 2 ]] || usage; bom="$2"; shift 2 ;;
    --out) [[ "$#" -ge 2 ]] || usage; out="$2"; shift 2 ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) [[ -z "${values_file}" ]] || usage; values_file="$1"; shift ;;
  esac
done
[[ -n "${values_file}" ]] || usage

for tool in jq yq check-jsonschema; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done
if ! yq --version 2>&1 | grep -q 'mikefarah.* v4\.'; then
  echo "yq must be mikefarah/yq v4 (see scripts/ci/install-tools.sh for the pinned version)" >&2
  exit 2
fi

# Paths in generated headers are relative to the repository, so the output does
# not depend on where the repository is checked out.
display_path() {
  local absolute
  absolute="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  case "${absolute}" in
    "${repo_root}"/*) echo "${absolute#"${repo_root}/"}" ;;
    *) basename "${absolute}" ;;
  esac
}

fail() { echo "error: $*" >&2; exit 1; }

# --- Validate the input ------------------------------------------------------

check-jsonschema --schemafile "${schema}" "${values_file}" >/dev/null || {
  check-jsonschema --schemafile "${schema}" "${values_file}" >&2 || true
  fail "${values_file} does not match ${schema#"${repo_root}/"}"
}
values_json="$(yq -o=json '.' "${values_file}")"

reserved="$(jq -r --slurpfile schema "${schema}" \
  -L "${repo_root}/scripts/lib" 'include "platform"; reserved_in_use($schema[0]) | .[]' <<<"${values_json}")"
if [[ -n "${reserved}" ]]; then
  while IFS= read -r field; do
    echo "error: ${field} is reserved for governed mode" >&2
  done <<<"${reserved}"
  fail "the v1 generator implements the core, task-auth and browser-admin profiles; governed mode is tracked in https://github.com/apelogic-ai/steward-platform/issues/3"
fi

profile="$(jq -r .profile <<<"${values_json}")"
members=('.products | index("steward")' '.dependencies | index("postgresql")' '.dependencies | index("cert-manager")')
case "${profile}" in
  core) ;;
  task-auth | browser-admin)
    # browser-admin is task-auth plus Steward's web UI and browser login;
    # Steward also takes steward-run's release coordinates.
    members+=('.products | index("github-oidc-exchange")' '.products | index("steward-run")')
    if jq -e '.edge.install' <<<"${values_json}" >/dev/null; then
      members+=('.dependencies | index("gateway-api-crds")' '.dependencies | index("envoy-gateway")')
    fi
    if jq -e '.edge.gateway.source == "evaluation"' <<<"${values_json}" >/dev/null; then
      # The evaluation Gateway is an Envoy Gateway one, its certificate comes
      # from cert-manager, and it publishes the evaluation Steward CA.
      jq -e '.edge.install and .tls.mode == "certManager" and .tls.certManager.issuer.source == "evaluation"' \
        <<<"${values_json}" >/dev/null \
        || fail "edge.gateway.source evaluation needs edge.install true and the evaluation cert-manager issuer (tls.certManager.issuer.source evaluation)"
    fi
    ;;
  *) fail "profile ${profile} is not implemented yet; see https://github.com/apelogic-ai/steward-platform/issues/3" ;;
esac
jq -e --arg p "${profile}" '.profiles[$p] != null' "${bom}" >/dev/null \
  || fail "the BOM has no ${profile} profile"
for member in "${members[@]}"; do
  jq -e --arg p "${profile}" ".profiles[\$p] | ${member}" "${bom}" >/dev/null \
    || fail "the BOM ${profile} profile lacks ${member}"
done

if jq -e '.database.evaluationVersion != null' <<<"${values_json}" >/dev/null; then
  wanted="$(jq -r .database.evaluationVersion <<<"${values_json}")"
  matches="$(jq -r --slurpfile bom "${bom}" -L "${repo_root}/scripts/lib" \
    'include "platform"; evaluation_postgres_matches($bom[0]) | length' <<<"${values_json}")"
  [[ "${matches}" == 1 ]] || fail "database.evaluationVersion ${wanted} names ${matches} of the BOM's tested PostgreSQL versions ($(jq -r '[.dependencies.postgresql.tested // [] | .[].version] | join(", ")' "${bom}")); it must name exactly one"
fi

ca_bundle=""
if [[ "$(jq -r .tls.mode <<<"${values_json}")" == customerSecret ]]; then
  ca_file="$(jq -r .tls.customerSecret.caBundleFile <<<"${values_json}")"
  [[ "${ca_file}" == /* ]] || ca_file="$(dirname "${values_file}")/${ca_file}"
  [[ -s "${ca_file}" ]] || fail "tls.customerSecret.caBundleFile ${ca_file} is missing or empty"
  grep -q -- '-----BEGIN CERTIFICATE-----' "${ca_file}" || fail "${ca_file} has no PEM certificate"
  if grep -q -- 'PRIVATE KEY-----' "${ca_file}"; then
    fail "${ca_file} contains a private key; the webhook CA bundle must be public"
  fi
  ca_bundle="$(cat "${ca_file}")"
fi

environment="$(jq -r .environment <<<"${values_json}")"
out="${out:-${repo_root}/generated/${environment}}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# Source-built products: the lock replaces each product's chart and images in
# the BOM the generator reads, after checking that it covers the install.
generator_bom="${bom}"
built_lock=""
if [[ "$(jq -r '.artifacts.source // "bom"' <<<"${values_json}")" == built ]]; then
  built_lock="$(jq -r .artifacts.builtLock <<<"${values_json}")"
  [[ "${built_lock}" == /* ]] || built_lock="$(dirname "${values_file}")/${built_lock}"
  [[ -s "${built_lock}" ]] || fail "artifacts.builtLock ${built_lock} is missing or empty"
  check-jsonschema --schemafile "${built_lock_schema}" "${built_lock}" >/dev/null || {
    check-jsonschema --schemafile "${built_lock_schema}" "${built_lock}" >&2 || true
    fail "${built_lock} does not match ${built_lock_schema#"${repo_root}/"}"
  }
  problems="$(jq -r --slurpfile bom "${bom}" --arg profile "${profile}" -L "${repo_root}/scripts/lib" \
    'include "built"; built_lock_problems($bom[0]; $profile) | .[]' "${built_lock}")"
  if [[ -n "${problems}" ]]; then
    while IFS= read -r problem; do
      echo "error: ${problem}" >&2
    done <<<"${problems}"
    fail "the built-artifacts lock $(display_path "${built_lock}") does not match the BOM for the ${profile} profile; see docs/fork-and-build.md"
  fi
  drift="$(jq -r --slurpfile bom "${bom}" -L "${repo_root}/scripts/lib" \
    'include "built"; built_lock_drift($bom[0]) | .[]' "${built_lock}")"
  if [[ -n "${drift}" ]]; then
    while IFS= read -r line; do
      echo "warning: ${line}" >&2
    done <<<"${drift}"
  fi
  generator_bom="${work}/bom.json"
  jq --slurpfile lock "${built_lock}" -L "${repo_root}/scripts/lib" \
    'include "built"; apply_built_lock($lock[0])' "${bom}" > "${generator_bom}"
fi

# --- Generate ----------------------------------------------------------------

files_json="$(jq --slurpfile bom "${generator_bom}" --arg ca_bundle "${ca_bundle}" \
  -L "${repo_root}/scripts/lib" 'include "platform"; generate($bom[0]; $ca_bundle)' <<<"${values_json}")"

stage="${work}/stage"
mkdir "${stage}"
header="# Generated by scripts/generate.sh from $(display_path "${values_file}") and $(display_path "${bom}")
# (platform $(jq -r .platformVersion "${bom}")). Do not edit; change the inputs and regenerate."
if [[ -n "${built_lock}" ]]; then
  header="${header}
# Product charts and images from the built-artifacts lock $(display_path "${built_lock}")."
fi
while IFS= read -r path; do
  mkdir -p "${stage}/$(dirname "${path}")"
  # A list becomes a multi-document YAML file.
  expression='.'
  if jq -e --arg path "${path}" '.[$path] | type == "array"' <<<"${files_json}" >/dev/null; then
    expression='.[] | split_doc'
  fi
  {
    echo "${header}"
    jq --arg path "${path}" '.[$path]' <<<"${files_json}" | yq -P -o=yaml "${expression}"
  } > "${stage}/${path}"
done < <(jq -r 'keys[]' <<<"${files_json}")
touch "${stage}/.steward-platform-generated"

# Replace the output directory, but only one this script created.
if [[ -e "${out}" ]]; then
  [[ -d "${out}" && ( -e "${out}/.steward-platform-generated" || -z "$(ls -A "${out}")" ) ]] \
    || fail "${out} exists and was not created by this script; refusing to replace it"
  rm -rf "${out}"
fi
mkdir -p "$(dirname "${out}")"
cp -R "${stage}" "${out}"
chmod -R u+rwX,go+rX,go-w "${out}"
echo "generated ${environment} (${profile}, $(jq -r .purpose <<<"${values_json}")$([[ -z "${built_lock}" ]] || echo ", built artifacts")) into $(display_path "${out}")"
