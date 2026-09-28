#!/usr/bin/env bash
# Checks for the Flux example, examples/flux/core. No cluster needed.
#
#   - the committed files match a fresh generation from the BOM, so they cannot
#     drift from it;
#   - every object validates against the Flux CRD schemas (kubeconform, strict);
#   - each OCIRepository points at its BOM chart and pins its BOM digest, and
#     each HelmRelease takes its chart from that OCIRepository;
#   - each chart, pulled at that digest, renders with the HelmRelease values
#     and uses the BOM image digests.
#
# Usage: tests/flux/run.sh
# Env:   FLUX_SCHEMAS_DIR  directory holding Flux's crd-schemas.tar.gz contents
#                          (scripts/ci/install-tools.sh flux-schemas)
# Needs: kubeconform, helm, jq, yq (mikefarah v4), and what scripts/generate.sh needs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bom="${repo_root}/bom/bom.json"
example="${repo_root}/examples/flux/core"
schemas="${FLUX_SCHEMAS_DIR:?set FLUX_SCHEMAS_DIR to the extracted Flux crd-schemas}"

for tool in kubeconform helm jq yq; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done
[[ -f "${schemas}/helmrelease-helm-v2.json" ]] || { echo "no Flux CRD schemas in ${schemas}" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export DOCKER_CONFIG="${work}/docker"
mkdir -p "${DOCKER_CONFIG}"
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok   $*"; }

if "${repo_root}/scripts/generate-examples.sh" --check; then
  pass "examples/flux/core is generated from the BOM and up to date"
else
  fail "examples/flux/core is stale"
fi

manifests=()
while IFS= read -r manifest; do manifests+=("${manifest}"); done \
  < <(find "${example}" -maxdepth 1 -name '*.yaml' ! -name kustomization.yaml | sort)
if kubeconform -strict -summary \
  -schema-location "${schemas}/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  "${manifests[@]}"; then
  pass "manifests validate against the Flux CRD schemas"
else
  fail "manifests do not validate against the Flux CRD schemas"
fi

# Every YAML file listed in kustomization.yaml, and nothing else.
listed="$(yq -r '.resources[]' "${example}/kustomization.yaml" | sort)"
present="$(for m in "${manifests[@]}"; do basename "${m}"; done | sort)"
if [[ "${listed}" == "${present}" ]]; then
  pass "kustomization.yaml lists every manifest"
else
  fail "kustomization.yaml lists [${listed//$'\n'/ }], directory has [${present//$'\n'/ }]"
fi

yq -o=json '.' "${manifests[@]}" | jq -s '.' > "${work}/objects.json"

# name <TAB> BOM entry <TAB> image components the chart deploys
charts=$'steward\t.products.steward\t.apiserver, .controller\n'
charts+=$'cert-manager\t.dependencies["cert-manager"]\t.controller, .webhook, .cainjector, .startupapicheck'
while IFS=$'\t' read -r name bom_path components; do
  reference="$(jq -r "${bom_path}.chart.reference" "${bom}")"
  digest="$(jq -r "${bom_path}.chart.digest" "${bom}")"
  repository="$(jq -c --arg n "${name}" '[.[] | select(.kind == "OCIRepository" and .metadata.name == $n)]' "${work}/objects.json")"
  release="$(jq -c --arg n "${name}" '[.[] | select(.kind == "HelmRelease" and .metadata.name == $n)]' "${work}/objects.json")"
  if [[ "$(jq length <<<"${repository}")" != 1 || "$(jq length <<<"${release}")" != 1 ]]; then
    fail "${name}: expected one OCIRepository and one HelmRelease"
    continue
  fi
  if jq -e --arg url "${reference}" --arg digest "${digest}" \
    '.[0].spec.url == $url and .[0].spec.ref.digest == $digest and (.[0].spec.ref | keys) == ["digest"]' \
    <<<"${repository}" >/dev/null; then
    pass "${name}: OCIRepository pins ${reference}@${digest}"
  else
    fail "${name}: OCIRepository does not pin the BOM chart ${reference}@${digest}"
  fi
  if jq -e --arg n "${name}" '.[0].spec.chartRef == {kind: "OCIRepository", name: $n}' <<<"${release}" >/dev/null; then
    pass "${name}: HelmRelease uses that OCIRepository"
  else
    fail "${name}: HelmRelease does not use the ${name} OCIRepository"
  fi

  mkdir -p "${work}/${name}"
  helm pull "${reference}@${digest}" --destination "${work}/${name}" >/dev/null 2>&1 || {
    fail "${name}: cannot pull ${reference}@${digest}"
    continue
  }
  archive="$(find "${work}/${name}" -maxdepth 1 -name '*.tgz' -print -quit)"
  jq '.[0].spec.values' <<<"${release}" > "${work}/${name}-values.json"
  namespace="$(jq -r '.[0].spec.targetNamespace' <<<"${release}")"
  if ! helm template "${name}" "${archive}" --namespace "${namespace}" \
    -f "${work}/${name}-values.json" > "${work}/${name}-rendered.yaml" 2>"${work}/template.log"; then
    cat "${work}/template.log" >&2
    fail "${name}: HelmRelease values do not render with the chart"
    continue
  fi
  missing=0
  while IFS= read -r ref; do
    grep -Eq "image: \"?${ref//./\\.}\"?$" "${work}/${name}-rendered.yaml" || {
      fail "${name}: rendered chart does not use BOM image ${ref}"
      missing=1
    }
  done < <(jq -r "${bom_path}.images | ${components}" "${bom}")
  [[ "${missing}" == 0 ]] && pass "${name}: HelmRelease values render with the chart and the BOM image digests"
done <<<"${charts}"

if [[ "${failures}" != 0 ]]; then
  echo "${failures} Flux example checks failed" >&2
  exit 1
fi
echo "Flux example checks passed"
