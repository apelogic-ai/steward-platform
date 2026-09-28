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
    ref="$(jq -r ".products.steward.images.${component}" "${bom}")"
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
      ref="$(jq -r ".dependencies[\"cert-manager\"].images.${component}" "${bom}")"
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
    ref="$(jq -r '.products["github-oidc-exchange"].images.exchange' "${bom}")"
    if grep -Fq "${ref}" "${work}/github-oidc-exchange-${name}.yaml"; then
      pass "${name}: github-oidc-exchange renders the BOM image digest"
    else
      fail "${name}: github-oidc-exchange does not render ${ref}"
    fi
  fi
  if [[ -f "${work}/envoy-gateway-${name}.yaml" ]]; then
    for component in controller proxy; do
      ref="$(jq -r ".dependencies[\"envoy-gateway\"].images.${component}" "${bom}")"
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

# The helmfile renders every committed environment, and installs each BOM
# chart by its BOM digest.
if [[ "${SKIP_HELMFILE:-0}" != 1 ]]; then
  command -v helmfile >/dev/null || { echo "missing helmfile (or set SKIP_HELMFILE=1)" >&2; exit 2; }
  for values in "${repo_root}"/environments/*/platform-values.yaml; do
    name="$(yq -r .environment "${values}")"
    "${generate}" "${values}" >/dev/null
    if ! helmfile --file "${repo_root}/helmfile/helmfile.yaml.gotmpl" --environment "${name}" \
      build > "${work}/helmfile-${name}.yaml" 2>"${work}/helmfile.log"; then
      cat "${work}/helmfile.log" >&2
      fail "${name}: helmfile build failed"
      continue
    fi
    # release <TAB> BOM chart, and whether the environment must install it.
    profile="$(yq -r .profile "${values}")"
    while IFS=$'\t' read -r release pinned profiles; do
      expected="$(jq -r "${pinned} | \"\\(.reference)@\\(.digest)\"" "${bom}")"
      actual="$(yq -r "select(.releases) | .releases[] | select(.name == \"${release}\") | .chart" "${work}/helmfile-${name}.yaml")"
      if [[ -z "${actual}" ]]; then
        [[ " ${profiles} " == *" ${profile} "* ]] && fail "${name}: helmfile does not install ${release}"
        continue
      elif [[ "${actual}" == "${expected}" ]]; then
        pass "${name}: helmfile installs ${release} at the BOM digest"
      else
        fail "${name}: helmfile installs ${release} from ${actual}, BOM pins ${expected}"
      fi
    done <<'RELEASES'
steward	.products.steward.chart	core task-auth browser-admin
cert-manager	.dependencies["cert-manager"].chart	core task-auth browser-admin
github-oidc-exchange	.products["github-oidc-exchange"].chart	task-auth browser-admin
envoy-gateway	.dependencies["envoy-gateway"].chart	task-auth browser-admin
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
    if helmfile --file "${repo_root}/helmfile/helmfile.yaml.gotmpl" --environment "${name}" \
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
reject "the evaluation Gateway without the evaluation Steward CA" \
  '.tls.certManager.issuer = {"source": "operator", "ref": {"name": "ca", "kind": "ClusterIssuer"}}' \
  "edge.gateway.source evaluation needs" kind-task-auth

if [[ "${failures}" != 0 ]]; then
  echo "${failures} generator checks failed" >&2
  exit 1
fi
echo "generator checks passed"
