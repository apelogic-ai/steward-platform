#!/usr/bin/env bash
# Tests for scripts/generate.sh. No cluster needed.
#
# For every environments/*/platform-values.yaml, for a customerSecret TLS
# variant and for a kind variant per tested PostgreSQL version built here,
# check that:
#   - the generator output is deterministic;
#   - the generated values pass `helm lint` and `helm template` with the
#     BOM-pinned charts, pulled by digest, so each chart's values schema applies;
#   - the rendered Steward chart uses the BOM image digests.
# For an environment with a registry mirror (environments/production-mirrored,
# and variants built here), also that every workload image the charts render,
# and every chart the helmfile installs, is its BOM reference rewritten to the
# mirror with the BOM digest unchanged, that the workloads carry the image pull
# secrets, and that the helmfile's CRD manifest hook downloads from the mirror.
# Then check that the generator rejects inputs it must refuse.
#
# Also checks that helmfile/helmfile.yaml.gotmpl builds and renders every
# committed environment with each BOM chart at its BOM digest (writes
# generated/<environment>/; set SKIP_HELMFILE=1 to skip).
#
# Usage: tests/generate/run.sh
# Needs: jq, yq (mikefarah v4), check-jsonschema, helm, helmfile, openssl.
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
# shellcheck source=tests/lib/mirror.sh
. "${repo_root}/tests/lib/mirror.sh"

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
# task-auth BOM charts, keyed by the generated values file name.
bom_chart_names=(github-oidc-exchange envoy-gateway)
bom_chart_archives=()
while IFS=$'\t' read -r bom_path chart_name; do
  bom_chart_archives+=("$(pull_chart "$(jq -r "${bom_path}.chart.reference" "${bom}")" \
    "$(jq -r "${bom_path}.chart.digest" "${bom}")" \
    "$(jq -r "${bom_path}.chart.version" "${bom}")" "${chart_name}")")
done <<'CHARTS'
.products["github-oidc-exchange"]	github-oidc-exchange
.dependencies["envoy-gateway"]	gateway-helm
CHARTS
# In-repo charts: generated values file name -> chart directory under charts/.
local_chart() {
  case "$1" in
    evaluation-ca | edge-evaluation-ca) echo evaluation-ca ;;
    postgresql-evaluation | evaluation-edge | steward-edge) echo "$1" ;;
    *) return 1 ;;
  esac
}

# A mirrored environment: every workload image the charts render is a BOM
# image rewritten to the mirror, at its BOM digest, and pulls with the
# configured secrets.
check_mirrored_images() {
  local name="$1" values="$2" expected secrets workload image pulls count=0 bad=0
  shift 2
  expected="$(mirrored_bom_images "${values}")"
  secrets="$(yq -r '.registry.imagePullSecrets // [] | join(",")' "${values}")"
  while IFS=$'\t' read -r workload image pulls; do
    count=$((count + 1))
    if ! grep -Fxq -- "${image}" <<<"${expected}"; then
      fail "${name}: ${workload} runs ${image}, which is not a BOM image rewritten to the mirror"
      bad=1
    fi
    local secret
    for secret in ${secrets//,/ }; do
      if [[ ",${pulls}," != *",${secret},"* ]]; then
        fail "${name}: ${workload} pulls with [${pulls}], without the configured image pull secret ${secret}"
        bad=1
      fi
    done
  done < <(workload_images "$@")
  if [[ "${count}" == 0 ]]; then
    fail "${name}: no workload images rendered"
  elif [[ "${bad}" == 0 ]]; then
    pass "${name}: all ${count} workload images are BOM images from the mirror, at their BOM digests${secrets:+, pulled with ${secrets}}"
  fi
}

# The value of one environment variable of the rendered apiserver container.
apiserver_env() {
  yq -r "select(.kind == \"Deployment\" and .metadata.name == \"steward-apiserver\")
    | .spec.template.spec.containers[] | select(.name == \"apiserver\")
    | .env[] | select(.name == \"$2\") | .value" "$1"
}

# browser-admin: the rendered Steward chart carries browser login, the web UI
# at the BOM digest, and steward-run's release coordinates projected from the
# BOM with Steward's documented mapping.
check_browser_admin() {
  local name="$1" values="$2" rendered="$3" origin expected actual
  origin="$(yq -r .publicEndpoints.steward "${values}")"
  expected="$(jq -cS -n --slurpfile bom "${bom}" -L "${repo_root}/scripts/lib" \
    'include "platform"; steward_run_release($bom[0])')"
  actual="$(apiserver_env "${rendered}" STEWARD_RUN_RELEASE_JSON | jq -cS .)"
  if [[ "${actual}" == "${expected}" ]] && jq -e --slurpfile bom "${bom}" '
      $bom[0].products["steward-run"] as $r
      | .manifestSchemaVersion == $r.signatures.releaseManifest.schemaVersion
        and .version == $r.version and .actionCommit == $r.action.commit
        and .workflowRepository == $r.workflow.repository and .workflowCommit == $r.workflow.commit
        and .governedJobContainerImage == ($r.images.runner | sub(":[^:@/]+@"; "@"))' <<<"${actual}" >/dev/null; then
    pass "${name}: Steward renders stewardRunRelease projected from the BOM steward-run entry"
  else
    fail "${name}: stewardRunRelease is '${actual}', expected ${expected}"
  fi
  if [[ "$(apiserver_env "${rendered}" STEWARD_BROWSER_ORIGIN)" == "${origin}" \
    && "$(apiserver_env "${rendered}" STEWARD_GOOGLE_OIDC_CLIENT_ID)" == "$(yq -r .browserAuth.google.clientId "${values}")" \
    && "$(apiserver_env "${rendered}" STEWARD_GOOGLE_WORKSPACE_DOMAIN)" == "$(yq -r .browserAuth.google.workspaceDomain "${values}")" ]]; then
    pass "${name}: Steward renders browser login for origin ${origin}"
  else
    fail "${name}: Steward does not render the browser login settings"
  fi
  if grep -Fq "image: $(jq -r .products.steward.images.web "${bom}")" "${rendered}"; then
    pass "${name}: Steward web renders the BOM image"
  else
    fail "${name}: Steward web does not render the BOM image"
  fi
  # The edge: Steward's own routes carry every public API path to the
  # apiserver and the rest to the web UI; the platform's API-only route is
  # not generated.
  local host api_paths
  host="${origin#https://}"
  api_paths="$(jq -cn -L "${repo_root}/scripts/lib" 'include "platform"; steward_api_paths')"
  if yq -o=json -I=0 'select(.kind == "HTTPRoute" and .metadata.name == "steward-api")' "${rendered}" \
    | jq -e --arg host "${host}" --argjson paths "${api_paths}" '
        .spec.hostnames == [$host] and (.spec.rules | length) == 1
        and ([.spec.rules[0].matches[].path] == $paths)
        and .spec.rules[0].backendRefs == [{name: "steward-apiserver", port: 443}]' >/dev/null \
    && yq -o=json -I=0 'select(.kind == "HTTPRoute" and .metadata.name == "steward-web")' "${rendered}" \
    | jq -e --arg host "${host}" '
        .spec.hostnames == [$host]
        and [.spec.rules[0].matches[].path] == [{type: "PathPrefix", value: "/"}]
        and .spec.rules[0].backendRefs == [{name: "steward-web", port: 3000}]' >/dev/null \
    && yq -o=json -I=0 'select(.kind == "BackendTLSPolicy" and .metadata.name == "steward-apiserver")' "${rendered}" \
    | jq -e --arg ns "$(yq -r .namespaces.steward "${values}")" --arg cm "$(yq -r .edge.stewardBackendCaConfigMap "${values}")" '
        .spec.validation.hostname == "steward-apiserver.\($ns).svc.cluster.local"
        and .spec.validation.caCertificateRefs == [{group: "", kind: "ConfigMap", name: $cm}]' >/dev/null; then
    pass "${name}: Steward routes all $(jq length <<<"${api_paths}") public API paths to the apiserver over verified TLS, the rest to the web UI"
  else
    fail "${name}: Steward's own routes are not the full API path list, the web route and the BackendTLSPolicy"
  fi
  if [[ -e "${work}/out/${name}/values/steward-edge.yaml" ]]; then
    fail "${name}: the platform's API-only steward-edge route is generated too"
  fi
}

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

  # Flux output for the production shape only: none when an evaluation piece
  # (CA, PostgreSQL or Gateway) is used, since only the helmfile installs them.
  local evaluation
  evaluation="$(yq -r '.tls.certManager.issuer.source == "evaluation" or .database.source == "evaluation"
    or .edge.gateway.source == "evaluation"' "${values}")"
  if [[ "${evaluation}" == true && ! -e "${out}/flux" ]]; then
    pass "${name}: no Flux output, as the environment uses evaluation pieces"
  elif [[ "${evaluation}" == false && -f "${out}/flux/kustomization.yaml" ]]; then
    pass "${name}: Flux output generated"
  else
    fail "${name}: Flux output present is $([[ -e "${out}/flux" ]] && echo yes || echo no), evaluation pieces ${evaluation}"
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
    ref="$(mirrored "${values}" productImages "$(jq -r ".products.steward.images.${component}" "${bom}")")"
    if grep -Fq "image: ${ref}" "${work}/steward-${name}.yaml"; then
      pass "${name}: Steward ${component} renders the BOM image"
    else
      fail "${name}: Steward ${component} does not render ${ref}"
    fi
  done

  if [[ "$(yq -r .profile "${out}/helmfile.yaml")" == browser-admin ]]; then
    check_browser_admin "${name}" "${values}" "${work}/steward-${name}.yaml"
  fi

  if [[ -f "${out}/values/cert-manager.yaml" ]]; then
    if helm template cert-manager "${cert_manager_chart}" --namespace cert-manager \
      -f "${out}/values/cert-manager.yaml" >"${work}/cert-manager-${name}.yaml" 2>"${work}/template.log"; then
      pass "${name}: cert-manager values pass the chart schema"
    else
      cat "${work}/template.log" >&2
      fail "${name}: cert-manager values rejected by the chart"
    fi
    for component in controller webhook cainjector startupapicheck; do
      ref="$(mirrored "${values}" dependencyImages "$(jq -r ".dependencies[\"cert-manager\"].images.${component}" "${bom}")")"
      grep -Fq "image: \"${ref}\"" "${work}/cert-manager-${name}.yaml" \
        || fail "${name}: cert-manager ${component} does not render ${ref}"
    done
  fi

  local values_file values_name chart archive index
  for values_file in "${out}"/values/*.yaml; do
    values_name="$(basename "${values_file}" .yaml)"
    chart="$(local_chart "${values_name}")" || continue
    if helm lint "${repo_root}/charts/${chart}" -f "${values_file}" >"${work}/lint.log" 2>&1 \
      && helm template "${values_name}" "${repo_root}/charts/${chart}" --namespace "${namespace}" \
        -f "${values_file}" >/dev/null 2>"${work}/template.log"; then
      pass "${name}: ${values_name} values pass charts/${chart}"
    else
      cat "${work}/lint.log" "${work}/template.log" >&2
      fail "${name}: ${values_name} values rejected by charts/${chart}"
    fi
  done

  # task-auth BOM charts, by digest. github-oidc-exchange lints strictly, as
  # its own validate-chart-values.sh does.
  for index in "${!bom_chart_names[@]}"; do
    values_name="${bom_chart_names[${index}]}"
    archive="${bom_chart_archives[${index}]}"
    [[ -f "${out}/values/${values_name}.yaml" ]] || continue
    local lint_args=(--quiet)
    [[ "${values_name}" == github-oidc-exchange ]] && lint_args+=(--strict)
    if helm lint "${lint_args[@]}" "${archive}" -f "${out}/values/${values_name}.yaml" >"${work}/lint.log" 2>&1 \
      && helm template "${values_name}" "${archive}" --namespace "${namespace}" \
        -f "${out}/values/${values_name}.yaml" >"${work}/${values_name}-${name}.yaml" 2>"${work}/template.log"; then
      pass "${name}: ${values_name} values pass the chart schema"
    else
      cat "${work}/lint.log" "${work}/template.log" >&2
      fail "${name}: ${values_name} values rejected by the chart"
    fi
  done
  if [[ -f "${work}/github-oidc-exchange-${name}.yaml" ]]; then
    ref="$(mirrored "${values}" productImages "$(jq -r '.products["github-oidc-exchange"].images.exchange' "${bom}")")"
    if grep -Fq "${ref}" "${work}/github-oidc-exchange-${name}.yaml"; then
      pass "${name}: github-oidc-exchange renders the BOM image digest"
    else
      fail "${name}: github-oidc-exchange does not render ${ref}"
    fi
  fi
  if [[ -f "${work}/envoy-gateway-${name}.yaml" ]]; then
    for component in controller proxy; do
      ref="$(mirrored "${values}" dependencyImages "$(jq -r ".dependencies[\"envoy-gateway\"].images.${component}" "${bom}")")"
      if grep -Fq "${ref}" "${work}/envoy-gateway-${name}.yaml"; then
        pass "${name}: envoy-gateway renders the BOM ${component} image"
      else
        fail "${name}: envoy-gateway does not render ${ref}"
      fi
    done
    if grep -q 'kind: CustomResourceDefinition' "${work}/envoy-gateway-${name}.yaml"; then
      fail "${name}: envoy-gateway still renders its bundled CRDs"
    fi
  fi

  if [[ "$(yq -r 'has("registry")' "${values}")" == true ]]; then
    local rendered_files=("${work}/steward-${name}.yaml") file
    for file in "${work}/cert-manager-${name}.yaml" "${work}/github-oidc-exchange-${name}.yaml" "${work}/envoy-gateway-${name}.yaml"; do
      [[ -f "${file}" ]] && rendered_files+=("${file}")
    done
    check_mirrored_images "${name}" "${values}" "${rendered_files[@]}"
    # Envoy Gateway's own proxies take their image and pull secrets from its
    # configuration, not from a workload of the chart.
    if [[ -f "${work}/envoy-gateway-${name}.yaml" ]]; then
      local secret
      for secret in $(yq -r '.registry.imagePullSecrets // [] | .[]' "${values}"); do
        yq -r 'select(.kind == "ConfigMap" and .metadata.name == "envoy-gateway-config") | .data["envoy-gateway.yaml"]' \
            "${work}/envoy-gateway-${name}.yaml" \
          | yq -e ".envoyProxy.provider.kubernetes.envoyDeployment.pod.imagePullSecrets[] | select(.name == \"${secret}\")" >/dev/null 2>&1 \
          || fail "${name}: the Envoy proxies do not pull with ${secret}"
      done
    fi
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

# The evaluation database at each tested PostgreSQL version, named by its
# major version, runs that version's BOM image; without evaluationVersion it
# runs the BOM default.
postgres_image() { yq -r '.image | "\(.repository):\(.tag)@\(.digest)"' "${work}/out/$1/values/postgresql-evaluation.yaml"; }
if [[ "$(postgres_image kind)" == "$(jq -r .dependencies.postgresql.images.postgres "${bom}")" ]]; then
  pass "kind: evaluation PostgreSQL runs the BOM default image"
else
  fail "kind: evaluation PostgreSQL runs $(postgres_image kind), not the BOM default"
fi
while IFS=$'\t' read -r version ref; do
  name="kind-postgresql-${version%%.*}"
  mkdir -p "${work}/${name}"
  yq ".database.evaluationVersion = \"${version%%.*}\"" \
    "${repo_root}/environments/kind/platform-values.yaml" > "${work}/${name}/platform-values.yaml"
  check_environment "${name}" "${work}/${name}/platform-values.yaml"
  if [[ "$(postgres_image "${name}")" == "${ref}" ]]; then
    pass "${name}: evaluation PostgreSQL runs the BOM image of tested ${version}"
  else
    fail "${name}: evaluation PostgreSQL runs $(postgres_image "${name}"), not ${ref}"
  fi
done < <(jq -r '.dependencies.postgresql.tested[] | [.version, .images.postgres] | @tsv' "${bom}")

# A mirrored environment for the variants below: the committed one, changed
# by a yq expression.
mirrored_variant() {
  local label="$1" expression="$2" dir="${work}/variant-$1"
  mkdir -p "${dir}"
  yq "${expression}" "${repo_root}/environments/production-mirrored/platform-values.yaml" > "${dir}/platform-values.yaml"
  if "${generate}" --out "${dir}/out" "${dir}/platform-values.yaml" >"${dir}/generate.log" 2>&1; then
    echo "${dir}/out"
  else
    cat "${dir}/generate.log" >&2
    return 1
  fi
}
# A cloud provider identity for the dependency charts instead of a Secret.
if out="$(mirrored_variant provider '.registry.dependencyCharts.flux = {"provider": "aws"}')" \
  && yq -e 'select(.kind == "OCIRepository") | .spec.provider == "aws" and (.spec | has("secretRef") | not)' \
    "${out}/flux/cert-manager.yaml" >/dev/null \
  && yq -e 'select(.kind == "OCIRepository") | .spec.provider == "aws"' "${out}/flux/envoy-gateway-crds.yaml" >/dev/null \
  && yq -e 'select(.kind == "OCIRepository") | .spec.secretRef.name == "registry-example-test" and (.spec | has("provider") | not)' \
    "${out}/flux/steward.yaml" >/dev/null; then
  pass "mirrored: a class's Flux provider reaches its OCIRepositories only, the chart CRD source included"
else
  fail "mirrored: registry.dependencyCharts.flux.provider does not reach exactly its OCIRepositories"
fi
# An exact Git mirror URL for one repository; the other stays upstream.
if out="$(mirrored_variant git-repositories '.registry.gitSources = {"repositories": {"https://github.com/kubernetes-sigs/gateway-api": "https://git.example.test/k8s/gateway-api.git"}}')" \
  && yq -e 'select(.kind == "GitRepository") | .spec.url == "https://git.example.test/k8s/gateway-api.git" and (.spec | has("secretRef") | not)' \
    "${out}/flux/gateway-api-crds.yaml" >/dev/null \
  && yq -e 'select(.kind == "GitRepository") | .spec.url == "https://github.com/apelogic-ai/steward-platform"' \
    "${out}/flux/steward-edge.yaml" >/dev/null; then
  pass "mirrored: registry.gitSources.repositories maps one Git repository exactly and leaves the others upstream"
else
  fail "mirrored: registry.gitSources.repositories does not map exactly the named repository"
fi
# A partial mirror: only the product images come from the mirror.
if out="$(mirrored_variant partial '.registry = {"productImages": {"prefix": "registry.example.test/p"}}')" \
  && [[ "$(yq -r .images.repository "${out}/values/steward.yaml")" == registry.example.test/p/apelogic-ai/steward ]] \
  && [[ "$(yq -r .image.repository "${out}/values/cert-manager.yaml")" == quay.io/jetstack/cert-manager-controller ]] \
  && [[ "$(yq -r .releases.steward.chart "${out}/helmfile.yaml")" == "$(jq -r '.products.steward.chart | "\(.reference)@\(.digest)"' "${bom}")" ]] \
  && ! grep -rq imagePullSecrets "${out}/values" \
  && ! yq -e 'has("registryLogins")' "${out}/helmfile.yaml" >/dev/null 2>&1; then
  pass "mirrored: a partial mirror rewrites only its class; the rest stays the BOM's"
else
  fail "mirrored: a partial mirror changed more than its class"
fi
# Two upstream artifacts mapped onto one mirror repository are refused: a BOM
# with a second registry's image under the same path.
jq '.dependencies.postgresql.images.other = (.dependencies.postgresql.images.postgres | sub("^docker.io/"; "mirror.gcr.io/"))' \
  "${bom}" > "${work}/collision-bom.json"
yq '.registry = {"dependencyImages": {"prefix": "registry.example.test/p"}}' \
  "${repo_root}/environments/production/platform-values.yaml" > "${work}/collision.yaml"
if "${generate}" --bom "${work}/collision-bom.json" --out "${work}/collision-out" "${work}/collision.yaml" >"${work}/collision.log" 2>&1; then
  fail "rejects a mirror that maps two upstream repositories onto one: generator accepted it"
elif grep -Fq "both map to registry.example.test/p/library/postgres" "${work}/collision.log"; then
  pass "rejects a mirror that maps two upstream repositories onto one"
else
  cat "${work}/collision.log" >&2
  fail "rejects a mirror that maps two upstream repositories onto one: unexpected error"
fi


# The helmfile renders every committed environment, and installs each BOM
# chart by its BOM digest, from the mirror when the environment has one.
if [[ "${SKIP_HELMFILE:-0}" != 1 ]]; then
  command -v helmfile >/dev/null || { echo "missing helmfile (or set SKIP_HELMFILE=1)" >&2; exit 2; }
  for values in "${repo_root}"/environments/*/platform-values.yaml; do
    name="$(yq -r .environment "${values}")"
    "${generate}" "${values}" >/dev/null
    helmfile_env=()
    if [[ "$(yq -r 'has("registry")' "${values}")" == true ]]; then
      seed_helmfile_cache "${work}/helmfile-cache-${name}" "${repo_root}/generated/${name}/helmfile.yaml"
      helmfile_env=("HELMFILE_CACHE_HOME=${work}/helmfile-cache-${name}")
    fi
    if ! env ${helmfile_env[@]+"${helmfile_env[@]}"} helmfile --file "${repo_root}/helmfile/helmfile.yaml.gotmpl" --environment "${name}" \
      build > "${work}/helmfile-${name}.yaml" 2>"${work}/helmfile.log"; then
      cat "${work}/helmfile.log" >&2
      fail "${name}: helmfile build failed"
      continue
    fi
    # release <TAB> BOM chart, and whether the environment must install it.
    profile="$(yq -r .profile "${values}")"
    while IFS=$'\t' read -r release pinned class profiles; do
      expected="$(mirrored "${values}" "${class}" "$(jq -r "${pinned} | \"\\(.reference)@\\(.digest)\"" "${bom}")")"
      actual="$(yq -r "select(.releases) | .releases[] | select(.name == \"${release}\") | .chart" "${work}/helmfile-${name}.yaml")"
      if [[ -z "${actual}" ]]; then
        [[ " ${profiles} " == *" ${profile} "* ]] && fail "${name}: helmfile does not install ${release}"
        continue
      elif [[ "${actual}" == "${expected}" ]]; then
        pass "${name}: helmfile installs ${release} at the BOM digest$([[ "${actual}" == "$(jq -r "${pinned} | .reference" "${bom}")"@* ]] || echo ", from the mirror")"
      else
        fail "${name}: helmfile installs ${release} from ${actual}, BOM pins ${expected}"
      fi
    done <<'RELEASES'
steward	.products.steward.chart	productCharts	core task-auth browser-admin
cert-manager	.dependencies["cert-manager"].chart	dependencyCharts	core task-auth browser-admin
github-oidc-exchange	.products["github-oidc-exchange"].chart	productCharts	task-auth browser-admin
envoy-gateway	.dependencies["envoy-gateway"].chart	dependencyCharts	task-auth browser-admin
RELEASES
    # task-auth: the Gateway API and Envoy Gateway CRDs are the BOM manifests,
    # which a presync hook applies before the envoy-gateway release.
    if [[ "${profile}" == task-auth || "${profile}" == browser-admin ]]; then
      hook="$(yq -o=json -I=0 'select(.releases) | .releases[] | select(.name == "envoy-gateway") | .hooks[]
          | select((.events | contains(["presync"])) and .command == "../scripts/apply-manifests.sh") | .args' \
          "${work}/helmfile-${name}.yaml")"
      if jq -e 'index("gateway-api-crds") and index("envoy-gateway")' <<<"${hook:-null}" >/dev/null 2>&1; then
        pass "${name}: helmfile applies the BOM CRD manifests before envoy-gateway"
      else
        fail "${name}: the envoy-gateway release does not apply the BOM CRD manifests first"
      fi
      # With a manifests mirror, each download comes from it (the hook still
      # checks the BOM SHA-256); without one, from the BOM URL.
      expected_urls="$(for dependency in gateway-api-crds envoy-gateway; do
          url="$(jq -r --arg d "${dependency}" '.dependencies[$d].manifests[0].url' "${bom}")"
          mirrored_url="$(mirrored "${values}" manifests "${url}")"
          if [[ "${mirrored_url}" != "${url}" ]]; then echo "${dependency}=${mirrored_url}"; fi
        done | sort)"
      actual_urls="$(jq -r '[range(0; length) as $i | select(.[$i] == "--url") | .[$i + 1]] | .[]' <<<"${hook:-[]}" | sort)"
      if [[ "${actual_urls}" == "${expected_urls}" ]]; then
        pass "${name}: the CRD manifest hook downloads $([[ -n "${expected_urls}" ]] && echo "from the manifests mirror" || echo "the BOM URLs")"
      else
        fail "${name}: the CRD manifest hook downloads [${actual_urls//$'\n'/ }], expected [${expected_urls//$'\n'/ }]"
      fi
    fi
    # browser-admin: Steward renders its own Gateway API objects, so it waits
    # for the release that applies their CRDs, and steward-edge is not installed.
    if [[ "${profile}" == browser-admin ]]; then
      if yq -e 'select(.releases) | .releases[] | select(.name == "steward") | .needs[] | select(test("/envoy-gateway$"))' \
          "${work}/helmfile-${name}.yaml" >/dev/null 2>&1 \
        && ! yq -e 'select(.releases) | .releases[] | select(.name == "steward-edge")' "${work}/helmfile-${name}.yaml" >/dev/null 2>&1; then
        pass "${name}: helmfile installs Steward after envoy-gateway and without steward-edge"
      else
        fail "${name}: helmfile must install Steward after envoy-gateway, and not install steward-edge"
      fi
    fi
    # With a chart mirror, helmfile logs in to each chart registry with the
    # credentials of its own environment variables.
    logins="$(yq -r 'select(.releases) | [(.repositories // []) | .[] | select(.oci == true) | .name + "=" + .url] | join(" ")' "${work}/helmfile-${name}.yaml")"
    expected_logins="$(yq -r '(.registry // {}) | [(.productCharts.prefix | select(. != null) | "steward-platform-product-charts=" + (split("/") | .[0])),
      (.dependencyCharts.prefix | select(. != null) | "steward-platform-dependency-charts=" + (split("/") | .[0]))] | join(" ")' "${values}")"
    if [[ "${logins}" == "${expected_logins}" ]]; then
      if [[ -n "${logins}" ]]; then pass "${name}: helmfile logs in to the chart mirrors (${logins})"; fi
    else
      fail "${name}: helmfile OCI repositories [${logins}], expected [${expected_logins}]"
    fi
    if env ${helmfile_env[@]+"${helmfile_env[@]}"} helmfile --file "${repo_root}/helmfile/helmfile.yaml.gotmpl" --environment "${name}" \
      template > "${work}/helmfile-template-${name}.yaml" 2>"${work}/helmfile.log"; then
      pass "${name}: helmfile renders every release"
    else
      cat "${work}/helmfile.log" >&2
      fail "${name}: helmfile template failed"
    fi
  done
fi

# Inputs the generator must refuse.
reject() {
  local label="$1" expression="$2" expected="$3" base="${4:-kind}" input="${work}/reject.yaml"
  yq "${expression}" "${repo_root}/environments/${base}/platform-values.yaml" > "${input}"
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
reject "an untested PostgreSQL version" '.database.evaluationVersion = "15"' "names 0 of the BOM's tested PostgreSQL versions"
reject "a PostgreSQL version that is not a version" '.database.evaluationVersion = "latest"' "does not match"
reject "an evaluation PostgreSQL version for an operator database" \
  '.database.evaluationVersion = "17"' "does not match" production
reject "an unknown field" '.clusterDomain = "cluster.local"' "does not match"
reject "a hostname as a CIDR" '.database.cidrs = ["db.example.test"]' "does not match"
cat "${work}/customer/webhook-ca.pem" "${work}/customer/ca.key" > "${work}/customer/with-key.pem"
reject "a private key in the CA bundle" \
  '.tls = {"mode": "customerSecret", "customerSecret": {"caBundleFile": "'"${work}"'/customer/with-key.pem"}}' \
  "contains a private key"
reject "task-auth fields in the core profile" \
  '.edge = {"install": true}' "does not match"
reject "the task-auth profile without its edge" \
  'del(.edge)' "does not match" kind-task-auth
reject "a reserved field in the task-auth profile" \
  '.publicEndpoints.mintIssuer = "https://mint.platform.test"' \
  "publicEndpoints.mintIssuer is reserved for governed mode" kind-task-auth
reject "a task API audience the exchange cannot issue" \
  '.audiences.taskApi = "other-audience"' "does not match" kind-task-auth
reject "a public origin with a path" \
  '.publicEndpoints.steward = "https://steward.platform.test/api"' "does not match" kind-task-auth
reject "the evaluation Gateway in production" \
  '.purpose = "production" | .database.source = "operator" | .tls.certManager.issuer = {"source": "operator", "ref": {"name": "ca", "kind": "ClusterIssuer"}}' \
  "does not match" kind-task-auth
reject "browser login in the task-auth profile" \
  '.browserAuth = {"google": {"clientId": "x", "workspaceDomain": "example.com", "organizationId": "org_x", "clientSecret": {"name": "s", "key": "k"}}}' \
  "does not match" kind-task-auth
reject "the browser-admin profile without browser login" \
  'del(.browserAuth)' "does not match" kind-browser-admin
reject "the browser-admin profile without browser-auth egress CIDRs" \
  'del(.networkPolicy.egressCidrs)' "does not match" kind-browser-admin
reject "a personal Google account domain" \
  '.browserAuth.google.workspaceDomain = "gmail.com"' "does not match" kind-browser-admin
reject "an organization ID outside Steward's rule" \
  '.browserAuth.google.organizationId = "example"' "does not match" kind-browser-admin
reject "an organization ID with nothing after org_" \
  '.browserAuth.google.organizationId = "org_"' "does not match" kind-browser-admin
reject "unrestricted browser-auth egress in production" \
  '.purpose = "production" | .database.source = "operator" | .tls.certManager.issuer = {"source": "operator", "ref": {"name": "ca", "kind": "ClusterIssuer"}} | .edge.gateway.source = "operator"' \
  "does not match" kind-browser-admin
reject "a reserved egress CIDR list" \
  '.networkPolicy.egressCidrs.githubApi = ["192.0.2.0/24"]' \
  "networkPolicy.egressCidrs.githubApi is reserved for governed mode" kind-browser-admin
reject "an empty registry block" '.registry = {}' "does not match"
reject "a scheme in an OCI mirror prefix" \
  '.registry.productImages.prefix = "https://registry.example.test/p"' "does not match"
reject "a registry mirror prefix without a registry host" \
  '.registry.dependencyImages.prefix = "steward-platform"' "does not match"
reject "a trailing slash in a mirror prefix" \
  '.registry.productCharts.prefix = "registry.example.test/p/"' "does not match"
reject "a Git mirror over plain HTTP" \
  '.registry.gitSources.prefix = "http://git.example.test/mirrors"' "does not match" production-mirrored
reject "a cloud provider together with a Secret for Flux" \
  '.registry.productCharts.flux.provider = "aws"' "does not match" production-mirrored
reject "a credential value in the registry block" \
  '.registry.password = "hunter2"' "does not match" production-mirrored
reject "the evaluation Gateway without the evaluation Steward CA" \
  '.tls.certManager.issuer = {"source": "operator", "ref": {"name": "ca", "kind": "ClusterIssuer"}}' \
  "edge.gateway.source evaluation needs" kind-task-auth

if [[ "${failures}" != 0 ]]; then
  echo "${failures} generator checks failed" >&2
  exit 1
fi
echo "generator checks passed"
