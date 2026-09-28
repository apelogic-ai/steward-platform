#!/usr/bin/env bash
# Tests for scripts/generate.sh. No cluster needed.
#
# For every environments/*/platform-values.yaml, and for a customerSecret TLS
# variant built here, check that:
#   - the generator output is deterministic;
#   - the generated values pass `helm lint` and `helm template` with the
#     BOM-pinned charts, pulled by digest, so each chart's values schema applies;
#   - the rendered Steward chart uses the BOM image digests.
# Then check that the generator rejects inputs it must refuse.
#
# Usage: tests/generate/run.sh
# Needs: jq, yq (mikefarah v4), check-jsonschema, helm, openssl.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bom="${repo_root}/bom/bom.json"
generate="${repo_root}/scripts/generate.sh"

for tool in jq yq check-jsonschema helm openssl; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok   $*"; }

# Charts, pulled by digest into a clean cache, anonymously.
export DOCKER_CONFIG="${work}/docker"
mkdir -p "${DOCKER_CONFIG}"
pull_chart() {
  local reference="$1" digest="$2" version="$3" dir="${work}/charts/$4"
  mkdir -p "${dir}"
  helm pull "${reference}@${digest}" --destination "${dir}" >/dev/null 2>&1
  local archive
  archive="$(find "${dir}" -maxdepth 1 -type f -name '*.tgz' -print -quit)"
  [[ -s "${archive}" ]] || { echo "could not pull ${reference}@${digest}" >&2; exit 1; }
  tar -xzOf "${archive}" "$4/Chart.yaml" | grep -Eq "^version: ['\"]?${version}['\"]?$" \
    || { echo "${reference}@${digest} is not version ${version}" >&2; exit 1; }
  echo "${archive}"
}
steward_chart="$(pull_chart "$(jq -r .products.steward.chart.reference "${bom}")" \
  "$(jq -r .products.steward.chart.digest "${bom}")" \
  "$(jq -r .products.steward.chart.version "${bom}")" steward)"
cert_manager_chart="$(pull_chart "$(jq -r '.dependencies["cert-manager"].chart.reference' "${bom}")" \
  "$(jq -r '.dependencies["cert-manager"].chart.digest' "${bom}")" \
  "$(jq -r '.dependencies["cert-manager"].chart.version' "${bom}")" cert-manager)"

# Render one generated environment with every chart it configures.
check_environment() {
  local name="$1" values="$2" out="${work}/out/$1" again="${work}/again/$1"
  if ! "${generate}" --out "${out}" "${values}" >/dev/null; then
    fail "${name}: generator failed"
    return
  fi
  "${generate}" --out "${again}" "${values}" >/dev/null
  if diff -r "${out}" "${again}" >/dev/null; then
    pass "${name}: output is deterministic"
  else
    fail "${name}: two runs differ"
  fi

  local namespace
  namespace="$(yq -r .namespaces.steward "${out}/helmfile.yaml")"
  if helm lint "${steward_chart}" -f "${out}/values/steward.yaml" >"${work}/lint.log" 2>&1 \
    && helm template steward "${steward_chart}" --namespace "${namespace}" \
      -f "${out}/values/steward.yaml" >"${work}/steward-${name}.yaml" 2>"${work}/template.log"; then
    pass "${name}: Steward values pass the chart schema"
  else
    cat "${work}/lint.log" "${work}/template.log" >&2
    fail "${name}: Steward values rejected by the chart"
    return
  fi
  local component ref
  for component in apiserver controller; do
    ref="$(jq -r ".products.steward.images.${component}" "${bom}")"
    if grep -Fq "image: ${ref}" "${work}/steward-${name}.yaml"; then
      pass "${name}: Steward ${component} renders the BOM image"
    else
      fail "${name}: Steward ${component} does not render ${ref}"
    fi
  done

  if [[ -f "${out}/values/cert-manager.yaml" ]]; then
    if helm template cert-manager "${cert_manager_chart}" --namespace cert-manager \
      -f "${out}/values/cert-manager.yaml" >"${work}/cert-manager-${name}.yaml" 2>"${work}/template.log"; then
      pass "${name}: cert-manager values pass the chart schema"
    else
      cat "${work}/template.log" >&2
      fail "${name}: cert-manager values rejected by the chart"
    fi
    for component in controller webhook cainjector startupapicheck; do
      ref="$(jq -r ".dependencies[\"cert-manager\"].images.${component}" "${bom}")"
      grep -Fq "image: \"${ref}\"" "${work}/cert-manager-${name}.yaml" \
        || fail "${name}: cert-manager ${component} does not render ${ref}"
    done
  fi
}

for values in "${repo_root}"/environments/*/platform-values.yaml; do
  check_environment "$(basename "$(dirname "${values}")")" "${values}"
done

# A customerSecret TLS variant of the production shape, with a throwaway CA.
mkdir -p "${work}/customer"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=generator test CA' \
  -keyout "${work}/customer/ca.key" -out "${work}/customer/webhook-ca.pem" >/dev/null 2>&1
yq '.environment = "customer-secret" | .tls = {"mode": "customerSecret", "customerSecret": {"caBundleFile": "webhook-ca.pem"}}' \
  "${repo_root}/environments/production/platform-values.yaml" > "${work}/customer/platform-values.yaml"
check_environment customer-secret "${work}/customer/platform-values.yaml"
if yq -e '.tls.webhook.caBundlePem | test("BEGIN CERTIFICATE")' \
  "${work}/out/customer-secret/values/steward.yaml" >/dev/null; then
  pass "customer-secret: the CA bundle file is embedded"
else
  fail "customer-secret: the CA bundle file is not embedded"
fi

# Inputs the generator must refuse.
reject() {
  local label="$1" expression="$2" expected="$3" input="${work}/reject.yaml"
  yq "${expression}" "${repo_root}/environments/kind/platform-values.yaml" > "${input}"
  if "${generate}" --out "${work}/reject-out" "${input}" >"${work}/reject.log" 2>&1; then
    fail "rejects ${label}: generator accepted it"
  elif grep -Fq "${expected}" "${work}/reject.log"; then
    pass "rejects ${label}"
  else
    cat "${work}/reject.log" >&2
    fail "rejects ${label}: expected '${expected}'"
  fi
}
reject "a reserved governed field" '.spiffe.trustDomain = "example.org"' "spiffe is reserved for governed mode"
reject "a reserved namespace" '.namespaces.mcpGateway = "mcp-gw"' "namespaces.mcpGateway is reserved for governed mode"
reject "the governed profile" '.profile = "governed"' "profile governed is not implemented yet"
reject "evaluation PostgreSQL in production" '.purpose = "production"' "does not match"
reject "an unknown field" '.clusterDomain = "cluster.local"' "does not match"
reject "a hostname as a CIDR" '.database.cidrs = ["db.example.test"]' "does not match"
cat "${work}/customer/webhook-ca.pem" "${work}/customer/ca.key" > "${work}/customer/with-key.pem"
reject "a private key in the CA bundle" \
  '.tls = {"mode": "customerSecret", "customerSecret": {"caBundleFile": "'"${work}"'/customer/with-key.pem"}}' \
  "contains a private key"

if [[ "${failures}" != 0 ]]; then
  echo "${failures} generator checks failed" >&2
  exit 1
fi
echo "generator checks passed"
