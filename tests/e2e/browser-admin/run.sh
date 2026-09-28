#!/usr/bin/env bash
# browser-admin profile end-to-end test on a disposable kind cluster, through
# the reference install, without a real Google login.
#
# Creates a kind cluster, runs scripts/generate.sh on
# environments/kind-browser-admin/platform-values.yaml, creates the
# operator-owned inputs (a placeholder exchange policy, a fresh exchange
# keyring and its public JWKS, and a placeholder Google client Secret),
# installs with helmfile/helmfile.yaml.gotmpl, then asserts that:
#   - Steward (apiserver, controller, web UI), github-oidc-exchange, Envoy
#     Gateway and Envoy run their BOM image digests, and the web UI is ready;
#   - the apiserver carries the configured browser login and the steward-run
#     release coordinates projected from the BOM; the NetworkPolicies admit
#     the edge to the web UI and the apiserver, and the browser-auth egress
#     CIDRs on 443;
#   - the Gateway is Programmed; Steward's own steward-api and steward-web
#     HTTPRoutes and the exchange's route are Accepted with resolved
#     references; Steward's BackendTLSPolicy is Accepted; the steward-api
#     route matches exactly the generated public API path list, and the
#     platform's API-only route is absent;
#   - through the edge, with TLS verified against the edge CA, every public API
#     path answers exactly what the apiserver answers directly (and not what
#     the web UI answers), and the web paths answer what the web UI answers;
#   - GET /admin/auth/login redirects to accounts.google.com with the
#     configured client ID, the exact redirect URI (the origin plus
#     /admin/auth/callback), the hosted domain (hd), code flow with PKCE S256,
#     a fresh state and nonce per request, and a Secure, HttpOnly flow cookie;
#     nothing contacts Google;
#   - task discovery still works through Steward's routes.
#
# Usage: tests/e2e/browser-admin/run.sh
# Env:
#   KEYRING_TOOL  path to github-oidc-exchange's keyring-tool
#                 (scripts/ci/build-keyring-tool.sh)
#   BOM           path to the BOM (default: bom/bom.json)
#   K8S_VERSION   a version from kubernetes.tested (default: the highest)
#   KEEP_CLUSTER  set to 1 to keep the cluster and work directory for debugging
# Needs: docker (linux/amd64 engine), kind, helm, helmfile, kubectl, jq, yq
# (mikefarah v4), check-jsonschema, openssl, curl, sha256sum.
# jq programs below take their arguments as $variables inside single quotes.
# shellcheck disable=SC2016
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
bom="${BOM:-${repo_root}/bom/bom.json}"
keep_cluster="${KEEP_CLUSTER:-0}"
platform_values="${repo_root}/environments/kind-browser-admin/platform-values.yaml"
kind_config="${repo_root}/environments/kind/kind-config.yaml"
helmfile_file="${repo_root}/helmfile/helmfile.yaml.gotmpl"

# Steward's browser session contract v1: the login route, the callback path
# and the OAuth flow cookie (the Secure deployment name).
# https://github.com/apelogic-ai/steward/blob/v0.3.1/docs/browser-session-contract-v1.md
login_path=/admin/auth/login
callback_path=/admin/auth/callback
flow_cookie=__Secure-steward-oidc-flow
# A subpath no product serves, appended to each PathPrefix.
probe_suffix=/steward-platform-route-probe

stage=preflight
cluster_created=0

for tool in docker kind helm helmfile kubectl jq yq check-jsonschema openssl curl sha256sum; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done
[[ -x "${KEYRING_TOOL:-}" ]] || {
  echo "set KEYRING_TOOL to github-oidc-exchange's keyring-tool (scripts/ci/build-keyring-tool.sh)" >&2
  exit 2
}

pass() { echo "pass: $*"; }
die() { echo "FAIL [${stage}]: $*" >&2; exit 1; }
bom_get() { jq -er "$1" "${bom}"; }
values_get() { yq -er "$1" "${platform_values}"; }

# --- Coordinates from the BOM and the platform values ------------------------

for member in steward github-oidc-exchange steward-run; do
  bom_get ".profiles[\"browser-admin\"].products | index(\"${member}\")" >/dev/null \
    || { echo "BOM browser-admin profile lacks ${member}" >&2; exit 2; }
done
[[ "$(values_get .profile)" == browser-admin ]] || { echo "${platform_values} is not browser-admin" >&2; exit 2; }

platform_version="$(bom_get .platformVersion)"
k8s_version="${K8S_VERSION:-$(bom_get '.kubernetes.tested | max_by(.version | split(".") | map(tonumber)) | .version')}"
node_image="$(jq -er --arg v "${k8s_version}" '.kubernetes.tested[] | select(.version == $v) | .nodeImage' "${bom}")" || {
  echo "Kubernetes ${k8s_version} is not in kubernetes.tested" >&2
  exit 2
}
environment="$(values_get .environment)"
steward_ns="$(values_get .namespaces.steward)"
identity_ns="$(values_get .namespaces.identityExchange)"
edge_ns="$(values_get .networkPolicy.edgeNamespace)"
gateway_name="$(values_get .edge.gateway.name)"
gateway_ns="$(values_get .edge.gateway.namespace)"
steward_origin="$(values_get .publicEndpoints.steward)"
identity_issuer="$(values_get .publicEndpoints.identityIssuer)"
steward_host="${steward_origin#https://}"
identity_host="${identity_issuer#https://}"
client_id="$(values_get .browserAuth.google.clientId)"
workspace_domain="$(values_get .browserAuth.google.workspaceDomain)"
organization_id="$(values_get .browserAuth.google.organizationId)"
client_secret_name="$(values_get .browserAuth.google.clientSecret.name)"
client_secret_key="$(values_get .browserAuth.google.clientSecret.key)"
policy_contract="$(values_get .identityExchange.policy.contract)"
policy_configmap="$(values_get .identityExchange.policy.configMapName)"
keyring_secret="$(values_get .identityExchange.keyring.secretName)"
jwks_configmap="$(values_get .identityExchange.publicJwksConfigMap.name)"
jwks_key="$(values_get .identityExchange.publicJwksConfigMap.key)"
identity_commit="$(bom_get '.products["github-oidc-exchange"].commit')"
identity_source="$(bom_get '.products["github-oidc-exchange"].source')"
api_host="steward-apiserver.${steward_ns}.svc.$(values_get .cluster.domain)"
evaluation_ca=steward-platform-evaluation-ca
edge_ca=steward-platform-edge-ca

# --- Disposable resources and cleanup ---------------------------------------

run_id="browser-admin-$(date -u +%Y%m%d%H%M%S)-$$"
cluster="spf-ba-$(date -u +%H%M%S)-$$"
context="kind-${cluster}"
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
run_dir="$(mktemp -d "${temp_root%/}/spf-${run_id}.XXXXXX")"
chmod 700 "${run_dir}"
kubeconfig="${run_dir}/kubeconfig"
generated="${run_dir}/generated"
K=(kubectl --kubeconfig "${kubeconfig}" --context "${context}")
KS=("${K[@]}" -n "${steward_ns}")

diagnostics() {
  echo "--- diagnostics" >&2
  "${K[@]}" get pods -A -o wide >&2 2>/dev/null
  "${K[@]}" get gateways,httproutes,backendtlspolicies -A -o wide >&2 2>/dev/null
  "${K[@]}" -n "${steward_ns}" get httproutes,backendtlspolicies -o yaml 2>/dev/null | grep -A30 '^  status:' | head -80 >&2
  "${K[@]}" get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -40 >&2
  local deployment
  for deployment in steward-apiserver steward-controller steward-web; do
    echo "--- logs: ${deployment}" >&2
    "${KS[@]}" logs "deployment/${deployment}" --all-containers --tail=60 >&2 2>/dev/null
  done
  echo "--- logs: envoy-gateway" >&2
  "${K[@]}" -n "${edge_ns}" logs deployment/envoy-gateway --tail=40 >&2 2>/dev/null
}

cleanup() {
  local status="$?" pid
  trap - EXIT INT TERM
  set +e
  if [[ "${status}" != 0 ]]; then
    echo "browser-admin e2e failed at stage ${stage} (exit ${status})" >&2
    [[ "${cluster_created}" == 1 ]] && diagnostics
  fi
  if [[ -f "${run_dir}/forward.pids" ]]; then
    while read -r pid; do kill "${pid}" >/dev/null 2>&1; done < "${run_dir}/forward.pids"
  fi
  if [[ "${keep_cluster}" == 1 ]]; then
    echo "kept cluster ${cluster} (kubeconfig ${kubeconfig}); remove with:" >&2
    echo "  kind delete cluster --name ${cluster} && rm -rf ${run_dir}" >&2
    exit "${status}"
  fi
  if [[ "${cluster_created}" == 1 ]]; then
    kind delete cluster --name "${cluster}" >/dev/null 2>&1 || status=1
  fi
  rm -rf "${run_dir}" || status=1
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker_arch="$(docker info --format '{{.Architecture}}')"
if [[ "${docker_arch}" != x86_64 && "${docker_arch}" != amd64 ]]; then
  echo "Steward images are linux/amd64 only; this Docker engine is ${docker_arch}." >&2
  exit 2
fi

echo "platform ${platform_version}: browser-admin on Kubernetes ${k8s_version}, environment ${environment}"
echo "owned cluster ${cluster}, work directory ${run_dir}"

# --- Operator inputs, prepared locally ---------------------------------------

# A placeholder v6 policy: no GitHub token is exchanged in this test, so it
# admits only a repository and branch that do not exist. Validated against the
# exchange's own schema at the BOM commit.
stage=inputs
curl --fail --silent --show-error --location --retry 3 \
  "https://raw.githubusercontent.com/${identity_source#https://github.com/}/${identity_commit}/docs/policy-contract-v6.schema.json" \
  -o "${run_dir}/policy-v6.schema.json"
jq -n --arg version "${policy_contract}" '{
    version: $version,
    service_group: "agents.apelogic.ai/service-principal:steward-run",
    repositories: [{owner_id: "1", repository_id: "1",
      subjects: ["repo:steward-platform-placeholder/none:ref:refs/heads/none"],
      events: ["workflow_dispatch"], refs: ["refs/heads/none"]}]}' > "${run_dir}/policy.json"
check-jsonschema --schemafile "${run_dir}/policy-v6.schema.json" "${run_dir}/policy.json" >/dev/null \
  || die "the placeholder policy does not match the github-oidc-exchange v6 schema"
(umask 077 && "${KEYRING_TOOL}" generate-es256 "${run_dir}/keyring.json" "browser-admin-e2e-$(date -u +%Y%m%d%H%M%S)" >/dev/null)
"${KEYRING_TOOL}" export-jwks "${run_dir}/keyring.json" > "${run_dir}/jwks.json"
# A placeholder Google client secret: one raw value, no newline. It is never
# sent anywhere, because no login completes.
(umask 077 && openssl rand -hex 24 | tr -d '\n' > "${run_dir}/client-secret")

# --- Cluster, generation, install -------------------------------------------

stage=cluster
cluster_created=1
kind create cluster --name "${cluster}" --kubeconfig "${kubeconfig}" \
  --config "${kind_config}" --image "${node_image}" --wait 180s
chmod 600 "${kubeconfig}"
[[ "$("${K[@]}" version -o json | jq -r .serverVersion.gitVersion)" == "v${k8s_version}" ]] \
  || die "the cluster does not run v${k8s_version}"

stage=generate
"${repo_root}/scripts/generate.sh" --bom "${bom}" --out "${generated}/${environment}" "${platform_values}"
steward_values="${generated}/${environment}/values/steward.yaml"
[[ ! -e "${generated}/${environment}/values/steward-edge.yaml" ]] || die "the API-only steward-edge values were generated"

stage=operator-inputs
for ns in "${steward_ns}" "${identity_ns}"; do "${K[@]}" create namespace "${ns}" >/dev/null; done
"${K[@]}" -n "${identity_ns}" create configmap "${policy_configmap}" --from-file=policy.json="${run_dir}/policy.json" >/dev/null
"${K[@]}" -n "${identity_ns}" create secret generic "${keyring_secret}" --from-file=keyring.json="${run_dir}/keyring.json" >/dev/null
"${KS[@]}" create configmap "${jwks_configmap}" --from-file="${jwks_key}=${run_dir}/jwks.json" >/dev/null
"${KS[@]}" create secret generic "${client_secret_name}" \
  --from-file="${client_secret_key}=${run_dir}/client-secret" >/dev/null
rm -f "${run_dir}/keyring.json" "${run_dir}/client-secret"

stage=install
env "KUBECONFIG=${kubeconfig}" "PLATFORM_GENERATED_DIR=${generated}" "PLATFORM_KUBE_CONTEXT=${context}" "BOM=${bom}" \
  helmfile --file "${helmfile_file}" --environment "${environment}" --kube-context "${context}" sync
for deployment in steward-apiserver steward-controller steward-web; do
  "${KS[@]}" rollout status "deployment/${deployment}" --timeout=180s
done
"${K[@]}" -n "${identity_ns}" rollout status deployment/github-oidc-exchange --timeout=180s

# --- Assertions: what runs ---------------------------------------------------

stage=assert-images
assert_digest() {
  local ids
  ids="$("${K[@]}" -n "$1" get pods -l "$2" -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}')"
  grep -Fq "@${3#*@}" <<<"${ids}" || die "no pod in $1 ($2) runs BOM image $3; running: ${ids}"
}
assert_digest "${steward_ns}" app.kubernetes.io/component=apiserver "$(bom_get .products.steward.images.apiserver)"
assert_digest "${steward_ns}" app.kubernetes.io/component=controller "$(bom_get .products.steward.images.controller)"
assert_digest "${steward_ns}" app.kubernetes.io/component=web "$(bom_get .products.steward.images.web)"
assert_digest "${identity_ns}" app.kubernetes.io/name=github-oidc-exchange "$(bom_get '.products["github-oidc-exchange"].images.exchange')"
assert_digest "${edge_ns}" app.kubernetes.io/name=gateway-helm "$(bom_get '.dependencies["envoy-gateway"].images.controller')"
pass "Steward apiserver, controller and web UI, github-oidc-exchange and Envoy Gateway run their BOM image digests"

stage=assert-config
"${KS[@]}" get deployment steward-apiserver -o json > "${run_dir}/apiserver.json"
env_value() {
  jq -r --arg n "$1" '.spec.template.spec.containers[] | select(.name == "apiserver") | .env[] | select(.name == $n) | .value' \
    "${run_dir}/apiserver.json"
}
expected_release="$(jq -cS -n --slurpfile bom "${bom}" -L "${repo_root}/scripts/lib" 'include "platform"; steward_run_release($bom[0])')"
[[ "$(env_value STEWARD_RUN_RELEASE_JSON | jq -cS .)" == "${expected_release}" ]] \
  || die "the apiserver's steward-run release is $(env_value STEWARD_RUN_RELEASE_JSON), expected ${expected_release}"
[[ "$(env_value STEWARD_BROWSER_ORIGIN)" == "${steward_origin}" \
  && "$(env_value STEWARD_GOOGLE_OIDC_CLIENT_ID)" == "${client_id}" \
  && "$(env_value STEWARD_GOOGLE_WORKSPACE_DOMAIN)" == "${workspace_domain}" \
  && "$(env_value STEWARD_ORGANIZATION_ID)" == "${organization_id}" ]] \
  || die "the apiserver does not carry the configured browser login"
jq -e --arg name "${client_secret_name}" --arg key "${client_secret_key}" '
  .spec.template.spec.containers[] | select(.name == "apiserver") | .env[]
  | select(.name == "STEWARD_GOOGLE_OIDC_CLIENT_SECRET") | .valueFrom.secretKeyRef == {name: $name, key: $key}' \
  "${run_dir}/apiserver.json" >/dev/null || die "the client secret is not read from ${client_secret_name}/${client_secret_key}"
pass "the apiserver carries browser login for ${steward_origin} (Secret by reference) and the steward-run ${expected_release}"

"${KS[@]}" get networkpolicies -o json > "${run_dir}/networkpolicies.json"
jq -e --argjson cidrs "$(yq -o=json -I=0 '.networkPolicy.egressCidrs.browserAuth' "${platform_values}")" '
  .items[] | select(.metadata.name == "steward-apiserver-egress") | .spec.egress
  | any(.[]; ([.to[]?.ipBlock.cidr] == $cidrs) and .ports == [{protocol: "TCP", port: 443}])' \
  "${run_dir}/networkpolicies.json" >/dev/null || die "the apiserver egress policy does not open the browser-auth CIDRs on 443"
for policy in steward-apiserver-ingress steward-web-ingress; do
  jq -e --arg p "${policy}" --arg ns "${edge_ns}" '
    .items[] | select(.metadata.name == $p) | .spec.ingress
    | any(.[]; any(.from[]?; .namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == $ns))' \
    "${run_dir}/networkpolicies.json" >/dev/null || die "${policy} does not admit the edge namespace ${edge_ns}"
done
pass "NetworkPolicies admit the edge to the web UI and the apiserver, and open the browser-auth CIDRs on 443"

# --- Assertions: the edge objects -------------------------------------------

stage=assert-edge-objects
"${K[@]}" -n "${gateway_ns}" wait --for=condition=Programmed --timeout=180s "gateway/${gateway_name}" >/dev/null \
  || die "Gateway ${gateway_ns}/${gateway_name} is not Programmed"
assert_digest "${edge_ns}" "gateway.envoyproxy.io/owning-gateway-name=${gateway_name}" "$(bom_get '.dependencies["envoy-gateway"].images.proxy')"
route_ready() {
  "${K[@]}" -n "${1%/*}" get httproute "${1#*/}" -o json | jq -e '
    [.status.parents[]?.conditions[]? | select((.type == "Accepted" or .type == "ResolvedRefs") and .status == "True")]
    | length >= 2' >/dev/null
}
for route in "${steward_ns}/steward-api" "${steward_ns}/steward-web" "${identity_ns}/github-oidc-exchange"; do
  ready=0
  for _ in {1..30}; do route_ready "${route}" && { ready=1; break; }; sleep 2; done
  [[ "${ready}" == 1 ]] || die "HTTPRoute ${route} is not Accepted with resolved references"
done
ready=0
for _ in {1..30}; do
  if "${KS[@]}" get backendtlspolicy steward-apiserver -o json | jq -e '
      [.status.ancestors[]?.conditions[]? | select(.type == "Accepted" and .status == "True")] | length >= 1' >/dev/null; then
    ready=1
    break
  fi
  sleep 2
done
[[ "${ready}" == 1 ]] || die "BackendTLSPolicy steward-apiserver is not Accepted"
if "${KS[@]}" get httproute steward-task-api >/dev/null 2>&1; then
  die "the platform's API-only route steward-task-api is installed alongside Steward's routes"
fi
api_paths="$(yq -o=json -I=0 '.web.httpRoute.apiPaths' "${steward_values}")"
"${KS[@]}" get httproute steward-api -o json | jq -e --argjson paths "${api_paths}" '
  [.spec.rules[].matches[].path] == $paths' >/dev/null \
  || die "the steward-api route does not match exactly the generated API paths ${api_paths}"
pass "Gateway Programmed, its Envoy proxy on the BOM digest; Steward's steward-api and steward-web routes and the exchange route Accepted; BackendTLSPolicy Accepted; steward-api matches the $(jq length <<<"${api_paths}") generated API paths; no API-only route"

# --- The edge and the two backends, on local ports ---------------------------

stage=port_forwards
# A port-forward to a Service on a free local port; prints the port. Runs in a
# command substitution, so the PID goes to a file for cleanup.
forward() {
  local namespace="$1" target="$2" port="$3" log="${run_dir}/forward-${RANDOM}.log" local_port=""
  "${K[@]}" -n "${namespace}" port-forward "${target}" ":${port}" --address 127.0.0.1 > "${log}" 2>&1 &
  echo "$!" >> "${run_dir}/forward.pids"
  for _ in {1..30}; do
    local_port="$(sed -nE 's/.*127\.0\.0\.1:([0-9]+) ->.*/\1/p' "${log}" | head -1)"
    [[ -n "${local_port}" ]] && break
    sleep 1
  done
  [[ "${local_port}" =~ ^[0-9]+$ ]] || { cat "${log}" >&2; die "port-forward to ${namespace}/${target} did not start"; }
  echo "${local_port}"
}
envoy_service="$("${K[@]}" -n "${edge_ns}" get service \
  -l "gateway.envoyproxy.io/owning-gateway-name=${gateway_name},gateway.envoyproxy.io/owning-gateway-namespace=${gateway_ns}" -o name)"
[[ "$(wc -w <<<"${envoy_service}")" == 1 ]] || die "expected one Envoy Service for the Gateway, found: ${envoy_service:-none}"
edge_port="$(forward "${edge_ns}" "${envoy_service}" 443)"
api_port="$(forward "${steward_ns}" service/steward-apiserver 443)"
web_port="$(forward "${steward_ns}" service/steward-web "$(yq -r '.services.webPort // 3000' "${steward_values}")")"
"${K[@]}" -n "${gateway_ns}" get secret "${edge_ca}" -o jsonpath='{.data.tls\.crt}' | base64 -d > "${run_dir}/edge-ca.crt"
"${KS[@]}" get secret "${evaluation_ca}" -o jsonpath='{.data.tls\.crt}' | base64 -d > "${run_dir}/steward-ca.crt"
openssl x509 -in "${run_dir}/edge-ca.crt" -noout && openssl x509 -in "${run_dir}/steward-ca.crt" -noout

# One request; prints "status|content-type|location|sha256(body)" and keeps the
# headers in $run_dir/last.headers. Redirects are never followed.
fingerprint() {
  local status content_type location digest
  status="$(curl --silent --show-error --noproxy '*' --max-time 30 --dump-header "${run_dir}/last.headers" \
    --output "${run_dir}/last.body" --write-out '%{http_code}' "$@")" || return 1
  content_type="$(header_value content-type)"
  location="$(header_value location)"
  digest="$(sha256sum < "${run_dir}/last.body" | cut -c1-16)"
  echo "${status}|${content_type}|${location}|${digest}"
}
header_value() {
  tr -d '\r' < "${run_dir}/last.headers" | awk -v name="$1" '
    tolower($0) ~ "^" name ":" { sub(/^[^:]*:[ \t]*/, ""); value = $0 } END { print value }'
}
via_edge() {
  fingerprint --cacert "${run_dir}/edge-ca.crt" --connect-to "${steward_host}:443:127.0.0.1:${edge_port}" \
    "https://${steward_host}$1"
}
# Direct to the apiserver, verified against the Steward CA for its Service
# name, with the public Host header the edge forwards.
via_apiserver() {
  fingerprint --cacert "${run_dir}/steward-ca.crt" --connect-to "${api_host}:443:127.0.0.1:${api_port}" \
    --header "Host: ${steward_host}" "https://${api_host}$1"
}
via_web() {
  fingerprint --header "Host: ${steward_host}" --header 'X-Forwarded-Proto: https' "http://127.0.0.1:${web_port}$1"
}
# The web UI's pages may differ per request, so they are compared without
# the body.
without_body() { echo "${1%|*}"; }

stage=assert-web-ready
ready=0
for _ in {1..30}; do
  [[ "$(via_edge /health/ready 2>/dev/null || true)" == 204\|* ]] && { ready=1; break; }
  sleep 2
done
[[ "${ready}" == 1 ]] || die "the web UI's readiness route does not answer 204 through the edge"
pass "the web UI is ready: GET ${steward_origin}/health/ready answers 204 through the edge, TLS verified against the edge CA"

# --- Every public API path reaches the apiserver, the rest the web UI --------

stage=assert-routes
probes=()
while IFS=$'\t' read -r type value; do
  probes+=("${value}")
  [[ "${type}" == PathPrefix ]] && probes+=("${value}${probe_suffix}")
done < <(jq -r '.[] | [.type, .value] | @tsv' <<<"${api_paths}")
# Routes the apiserver serves behind three of the prefixes (browser session,
# operator bearer and application APIs, and the task API), so that some probes
# reach a handler rather than the apiserver's not-found answer.
probes+=(/admin/api/v1/session /admin/operator/v1/users /app/api/v1/envelope-templates /v1/tasks)
for path in "${probes[@]}"; do
  edge="$(via_edge "${path}")" || die "${path}: no answer through the edge"
  direct="$(via_apiserver "${path}")" || die "${path}: no answer from the apiserver"
  web="$(via_web "${path}")" || die "${path}: no answer from the web UI"
  [[ "${direct}" != "${web}" ]] || die "${path}: the apiserver and the web UI answer alike (${direct}); the probe cannot tell them apart"
  [[ "${edge}" == "${direct}" ]] || die "${path}: the edge answers ${edge}; the apiserver answers ${direct}, the web UI ${web}"
  echo "  ${path} -> apiserver (${edge%%|*})"
done
pass "all ${#probes[@]} probes under the $(jq length <<<"${api_paths}") public API paths reach the apiserver through the edge"

session="$(via_edge /admin/api/v1/session)"
[[ "${session%%|*}" == 401 ]] || die "GET /admin/api/v1/session without a session answered ${session%%|*}, expected 401"
pass "GET /admin/api/v1/session without a browser session: 401"

for path in / /admin/sign-in /admin/approvals /health/ready "/admin${probe_suffix}"; do
  edge="$(without_body "$(via_edge "${path}")")" || die "${path}: no answer through the edge"
  web="$(without_body "$(via_web "${path}")")" || die "${path}: no answer from the web UI"
  direct="$(without_body "$(via_apiserver "${path}")")" || die "${path}: no answer from the apiserver"
  [[ "${web}" != "${direct}" ]] || die "${path}: the web UI and the apiserver answer alike (${web})"
  [[ "${edge}" == "${web}" ]] || die "${path}: the edge answers ${edge}; the web UI answers ${web}, the apiserver ${direct}"
  echo "  ${path} -> web UI (${edge%%|*})"
done
pass "web paths reach the web UI through the edge"

# --- Google login starts, without Google -------------------------------------

stage=assert-login
urldecode() { local value="${1//+/ }"; printf '%b' "${value//%/\\x}"; }
login() {
  local result location query pair
  result="$(via_edge "${login_path}")" || die "no answer on ${login_path}"
  [[ "${result%%|*}" == 303 ]] || die "${login_path} answered ${result}, expected a 303 redirect"
  location="$(header_value location)"
  [[ "${location}" == https://accounts.google.com/*\?* ]] || die "${login_path} redirects to ${location%%\?*}, not https://accounts.google.com"
  login_base="${location%%\?*}"
  query="${location#*\?}"
  login_query="{}"
  IFS='&' read -ra pairs <<<"${query}"
  for pair in "${pairs[@]}"; do
    login_query="$(jq -c --arg k "$(urldecode "${pair%%=*}")" --arg v "$(urldecode "${pair#*=}")" '. + {($k): $v}' <<<"${login_query}")"
  done
  login_cookie="$(tr -d '\r' < "${run_dir}/last.headers" | grep -i '^set-cookie:' || true)"
}
login
first_state="$(jq -r .state <<<"${login_query}")"
jq -e --arg client "${client_id}" --arg redirect "${steward_origin}${callback_path}" --arg hd "${workspace_domain}" '
  .client_id == $client and .redirect_uri == $redirect and .hd == $hd
  and .response_type == "code" and .scope == "openid email profile"
  and .code_challenge_method == "S256" and (.code_challenge | test("^[A-Za-z0-9_-]{43}$"))
  and (.state | length) >= 16 and (.nonce | length) >= 16' <<<"${login_query}" >/dev/null \
  || die "unexpected Google authorization request: $(jq -c 'del(.state, .nonce, .code_challenge)' <<<"${login_query}")"
grep -Eiq "^set-cookie: ${flow_cookie}=[^;]+; Path=/admin/auth; HttpOnly; SameSite=Lax; Max-Age=[0-9]+; Secure$" <<<"${login_cookie}" \
  || die "the login did not set a Secure, HttpOnly ${flow_cookie} cookie scoped to /admin/auth"
login
[[ "$(jq -r .state <<<"${login_query}")" != "${first_state}" ]] || die "two logins reused one state"
pass "GET ${login_path}: 303 to ${login_base} with client_id ${client_id}, redirect_uri ${steward_origin}${callback_path}, hd ${workspace_domain}, code flow with PKCE S256, a fresh state and nonce per request, and a Secure HttpOnly ${flow_cookie} cookie"

# --- Task discovery through Steward's routes --------------------------------

stage=assert-discovery
body="$(curl --fail --silent --show-error --noproxy '*' --max-time 30 --cacert "${run_dir}/edge-ca.crt" \
  --connect-to "${steward_host}:443:127.0.0.1:${edge_port}" "${steward_origin}/.well-known/oauth-protected-resource")" \
  || die "the protected-resource metadata is not reachable through Steward's routes"
jq -e --arg resource "${steward_origin}" --arg issuer "${identity_issuer}" '
  .resource == $resource and .authorization_servers == [$issuer]' <<<"${body}" >/dev/null \
  || die "unexpected protected-resource metadata: ${body}"
curl --fail --silent --show-error --noproxy '*' --max-time 30 --cacert "${run_dir}/edge-ca.crt" --output /dev/null \
  --connect-to "${identity_host}:443:127.0.0.1:${edge_port}" "${identity_issuer}/.well-known/oauth-authorization-server" \
  || die "the exchange metadata is not reachable through the edge"
pass "task discovery through Steward's routes: resource ${steward_origin}, authorization server ${identity_issuer}"

stage=complete
echo "browser-admin e2e passed: platform ${platform_version}, Kubernetes ${k8s_version}, reference install (${environment})"
