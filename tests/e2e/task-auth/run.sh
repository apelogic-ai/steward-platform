#!/usr/bin/env bash
# task-auth profile end-to-end test: Steward, github-oidc-exchange and the
# steward-run GitHub Action authenticate a Task submission with a real GitHub
# Actions OIDC token, through an Envoy Gateway edge on a disposable kind
# cluster. See tests/e2e/task-auth/README.md for what each phase asserts and
# why the final answer is `403 task_identity_unassociated`.
#
# It runs in three phases because the steward-run action is a workflow step
# between them (.github/workflows/ci.yml):
#
#   up      observe this job's signed GitHub claims; generate an exchange policy
#           that admits only them; build the keyring; create the cluster;
#           install the kind-task-auth reference install; check the edge and
#           the discovery documents; publish the edge on 127.0.0.1:443.
#   verify  check what the action's submission left behind, then drive the same
#           chain directly and assert each response, plus the negative cases:
#           replayed assertion, wrong audience, and a workflow the policy does
#           not admit.
#   down    remove the cluster, the port-forward and the hosts entries.
#
# Only a GitHub-hosted job with `permissions: id-token: write` can run it:
# `up` exits 3 when no OIDC token is available (for example, pull requests
# from forks).
#
# Usage: tests/e2e/task-auth/run.sh up|verify|down
#        tests/e2e/task-auth/run.sh check-node ACTION_PATH
# Env:
#   KEYRING_TOOL      path to github-oidc-exchange's keyring-tool
#                     (scripts/ci/build-keyring-tool.sh); up only
#   K8S_VERSION       a version from kubernetes.tested (default: the highest)
#   STEWARD_RUN_OUTCOME  outcome of the action step; verify only
#   STEWARD_RUN_ACTION_PATH  where the workflow checked out the action; verify only
#   TASK_AUTH_STATE   state directory (default: $RUNNER_TEMP/steward-platform-task-auth)
#   KEEP_CLUSTER      set to 1 to keep the cluster in down, for debugging
# Needs: docker (linux/amd64 engine), kind, helm, helmfile, kubectl, jq, yq,
# check-jsonschema, openssl, curl, sudo (for /etc/hosts and port 443).
# jq programs below take their arguments as $variables inside single quotes.
# shellcheck disable=SC2016
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
bom="${BOM:-${repo_root}/bom/bom.json}"
platform_values="${repo_root}/environments/kind-task-auth/platform-values.yaml"
kind_config="${repo_root}/environments/kind/kind-config.yaml"
helmfile_file="${repo_root}/helmfile/helmfile.yaml.gotmpl"
state="${TASK_AUTH_STATE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/steward-platform-task-auth}"
hosts_marker="# steward-platform task-auth e2e"
command="${1:-}"
stage="${command:-usage}"

# Fixed by the products, not by this repository:
# steward-run's Task source (Steward accepts it only with an Envelope; the
# request never gets that far), the exchange's v6 service group from its
# example policy, and the v3 token contract.
probe_workflow="task-auth-probe@1"
service_group="agents.apelogic.ai/service-principal:steward-run"
v6_contract="github-oidc-exchange.apelogic.io/v6"

# Workflow commands (::add-mask::) must reach the runner even from inside a
# command substitution.
exec 3>&1
mask() { [[ -z "${GITHUB_ACTIONS:-}" ]] || echo "::add-mask::$1" >&3; }

log() { echo "$*"; }
pass() { echo "pass: $*"; }
die() { echo "FAIL [${stage}]: $*" >&2; exit 1; }

bom_get() { jq -er "$1" "${bom}"; }
values_get() { yq -er "$1" "${platform_values}"; }

# --- Coordinates from the BOM and the platform values ------------------------

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
github_audience="$(values_get .identityExchange.githubAudience)"
task_audience="$(values_get .audiences.taskApi)"
policy_contract="$(values_get .identityExchange.policy.contract)"
policy_configmap="$(values_get .identityExchange.policy.configMapName)"
keyring_secret="$(values_get .identityExchange.keyring.secretName)"
jwks_configmap="$(values_get .identityExchange.publicJwksConfigMap.name)"
jwks_key="$(values_get .identityExchange.publicJwksConfigMap.key)"
identity_commit="$(bom_get '.products["github-oidc-exchange"].commit')"
identity_source="$(bom_get '.products["github-oidc-exchange"].source')"
action_commit="$(bom_get '.products["steward-run"].action.commit')"
identity_selector=app.kubernetes.io/name=github-oidc-exchange
edge_ca_secret=steward-platform-edge-ca
edge_port=443

# --- State shared between phases ---------------------------------------------

state_file="${state}/state.env"
save_state() {
  local key
  for key in "$@"; do printf '%s=%q\n' "${key}" "${!key}" >> "${state_file}"; done
}
load_state() {
  [[ -f "${state_file}" ]] || die "no state in ${state}; run 'up' first"
  # shellcheck disable=SC1090
  source "${state_file}"
  K=(kubectl --kubeconfig "${kubeconfig}" --context "${context}")
}

# --- GitHub OIDC -------------------------------------------------------------

have_oidc() { [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; }

# A fresh GitHub Actions OIDC token for an audience. Tokens are masked in the
# job log and never printed.
github_token() {
  local audience="$1" token
  token="$(curl --fail --silent --show-error --get \
    -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    --data-urlencode "audience=${audience}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}" | jq -er .value)" || die "could not mint a GitHub OIDC token"
  mask "${token}"
  printf '%s' "${token}"
}

# The payload of a JWT, as JSON. Its signature is checked by whoever verifies
# the token, not here.
jwt_claims() {
  local payload
  payload="$(cut -d. -f2 <<<"$1" | tr '_-' '/+')"
  while (( ${#payload} % 4 )); do payload+="="; done
  base64 -d <<<"${payload}" | jq -c .
}

# github-oidc-exchange logs only a hash of a GitHub assertion's jti: the first
# 8 bytes of its SHA-256, as hex.
jti_hash() { printf '%s' "$1" | sha256sum | cut -c1-16; }

# --- The edge ------------------------------------------------------------------

# curl through the edge on 127.0.0.1, verifying TLS against the edge CA.
edge_curl() {
  curl --silent --show-error --noproxy '*' --max-time 30 \
    --cacert "${state}/edge-ca.crt" \
    --resolve "${steward_host}:${edge_port}:127.0.0.1" \
    --resolve "${identity_host}:${edge_port}:127.0.0.1" "$@"
}

edge_alive() {
  [[ -n "${port_forward_pid:-}" ]] && kill -0 "${port_forward_pid}" 2>/dev/null \
    && edge_curl --output /dev/null "${identity_issuer}/.well-known/oauth-authorization-server"
}

start_port_forward() {
  local service
  service="$("${K[@]}" -n "${edge_ns}" get service \
    -l "gateway.envoyproxy.io/owning-gateway-name=${gateway_name},gateway.envoyproxy.io/owning-gateway-namespace=${gateway_ns}" \
    -o name)"
  [[ "$(wc -w <<<"${service}")" == 1 ]] || die "expected one Envoy Service for Gateway ${gateway_ns}/${gateway_name}, found: ${service:-none}"
  nohup "${K[@]}" -n "${edge_ns}" port-forward "${service}" "${edge_port}:443" --address 127.0.0.1 \
    > "${state}/port-forward.log" 2>&1 &
  port_forward_pid="$!"
  disown "${port_forward_pid}" 2>/dev/null || true
  local _
  for _ in {1..30}; do
    grep -q "Forwarding from 127.0.0.1:${edge_port}" "${state}/port-forward.log" 2>/dev/null && return 0
    sleep 1
  done
  cat "${state}/port-forward.log" >&2
  die "the edge port-forward did not start"
}

ensure_edge() {
  edge_alive && return 0
  log "the edge port-forward is not answering; restarting it"
  if [[ -n "${port_forward_pid:-}" ]]; then kill "${port_forward_pid}" 2>/dev/null || true; fi
  start_port_forward
  sed -i '/^port_forward_pid=/d' "${state_file}"
  save_state port_forward_pid
  local _
  for _ in {1..20}; do edge_alive && return 0; sleep 1; done
  die "the edge does not answer on 127.0.0.1:${edge_port}"
}

# A curl response written with --write-out '\n%{http_code}': its status line
# and its body.
http_status() { printf '%s' "${1##*$'\n'}"; }
http_body() { printf '%s' "${1%$'\n'*}"; }

# The exchange's documented answer to every rejected assertion.
expect_invalid_token() {
  local response="$1" what="$2"
  if [[ "$(http_status "${response}")" != 401 ]] \
    || ! jq -e '.error == "invalid_token"' <<<"$(http_body "${response}")" >/dev/null; then
    die "${what} returned $(http_status "${response}"): $(http_body "${response}")"
  fi
}

# --- Cluster reads -----------------------------------------------------------

psql_steward() {
  "${K[@]}" -n "${steward_ns}" exec deployment/postgresql-evaluation -- \
    psql -U steward -d steward -v ON_ERROR_STOP=1 -Atc "$1"
}
sql_quote() { printf "'%s'" "${1//\'/\'\'}"; }

# github-oidc-exchange audit events (JSON log lines) across its pods, as JSON
# objects with the event fields.
identity_events() {
  "${K[@]}" -n "${identity_ns}" logs -l "${identity_selector}" --tail=-1 --max-log-requests 10 2>/dev/null \
    | jq -cR 'fromjson? | select(type == "object") | (.fields // .) | select(.event != null)' || true
}
count_events() {
  local filter="$1"
  identity_events | jq -s --arg a "${2:-}" --arg b "${3:-}" "[.[] | select(${filter})] | length"
}

diagnostics() {
  [[ -n "${kubeconfig:-}" && -f "${kubeconfig}" ]] || return 0
  echo "--- diagnostics" >&2
  "${K[@]}" get pods -A -o wide >&2 2>/dev/null
  "${K[@]}" get gateways,httproutes,backendtlspolicies -A -o wide >&2 2>/dev/null
  "${K[@]}" -n "${gateway_ns}" get gateway "${gateway_name}" -o jsonpath='{.status}' >&2 2>/dev/null; echo >&2
  "${K[@]}" get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -40 >&2
  echo "--- logs: steward-apiserver" >&2
  "${K[@]}" -n "${steward_ns}" logs deployment/steward-apiserver --tail=60 >&2 2>/dev/null
  echo "--- logs: github-oidc-exchange" >&2
  "${K[@]}" -n "${identity_ns}" logs -l "${identity_selector}" --tail=40 --prefix >&2 2>/dev/null
  echo "--- logs: envoy-gateway" >&2
  "${K[@]}" -n "${edge_ns}" logs deployment/envoy-gateway --tail=40 >&2 2>/dev/null
}
on_error() {
  local status="$?"
  trap - EXIT
  if [[ "${status}" != 0 && "${status}" != 3 ]]; then
    echo "task-auth e2e ${command} failed at stage ${stage} (exit ${status})" >&2
    diagnostics
  fi
  exit "${status}"
}

# --- Policy ------------------------------------------------------------------

# A v6 policy with one repository rule for this job's exact signed claims:
# numeric owner and repository IDs, and the exact subject, event and ref.
# v6 has no selector for the workflow file itself; the workflow ref and SHA
# travel in the token's signed source provenance instead.
write_policy() {
  local subject="$1" out="$2"
  jq -n --arg version "${v6_contract}" --arg group "${service_group}" \
    --arg subject "${subject}" --slurpfile claims "${state}/claims.json" '
    $claims[0] as $c
    | {version: $version, service_group: $group,
       repositories: [{owner_id: $c.repository_owner_id, repository_id: $c.repository_id,
                       subjects: [$subject], events: [$c.event_name], refs: [$c.ref]}]}' > "${out}"
  check-jsonschema --schemafile "${state}/policy-v6.schema.json" "${out}" >/dev/null \
    || die "generated policy does not match the github-oidc-exchange v6 schema"
}

apply_policy() {
  "${K[@]}" -n "${identity_ns}" create configmap "${policy_configmap}" \
    --from-file=policy.json="$1" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
}

# =============================================================================

cmd_up() {
  stage=preflight
  if ! have_oidc; then
    echo "No GitHub Actions OIDC token is available (id-token: write is missing, or this is a pull request from a fork). Skipping the task-auth end-to-end test." >&2
    exit 3
  fi
  local tool
  for tool in docker kind helm helmfile kubectl jq yq check-jsonschema openssl curl sudo sha256sum; do
    command -v "${tool}" >/dev/null || die "missing ${tool}"
  done
  [[ -x "${KEYRING_TOOL:-}" ]] || die "set KEYRING_TOOL to github-oidc-exchange's keyring-tool (scripts/ci/build-keyring-tool.sh)"
  [[ "${policy_contract}" == "${v6_contract}" ]] || die "this test drives policy v6; the kind-task-auth values select ${policy_contract}"
  local member
  for member in steward github-oidc-exchange steward-run; do
    bom_get ".profiles[\"task-auth\"].products | index(\"${member}\")" >/dev/null || die "BOM task-auth profile lacks ${member}"
  done
  local docker_arch
  docker_arch="$(docker info --format '{{.Architecture}}')"
  [[ "${docker_arch}" == x86_64 || "${docker_arch}" == amd64 ]] \
    || die "Steward images are linux/amd64 only; this Docker engine is ${docker_arch}"

  rm -rf "${state}"
  mkdir -p "${state}"
  chmod 700 "${state}"
  : > "${state_file}"
  trap on_error EXIT

  local k8s_version node_image cluster context kubeconfig
  k8s_version="${K8S_VERSION:-$(bom_get '.kubernetes.tested | max_by(.version | split(".") | map(tonumber)) | .version')}"
  node_image="$(jq -er --arg v "${k8s_version}" '.kubernetes.tested[] | select(.version == $v) | .nodeImage' "${bom}")" \
    || die "Kubernetes ${k8s_version} is not in kubernetes.tested"
  cluster="spf-task-auth-$(date -u +%H%M%S)-$$"
  context="kind-${cluster}"
  kubeconfig="${state}/kubeconfig"
  save_state k8s_version cluster context kubeconfig
  K=(kubectl --kubeconfig "${kubeconfig}" --context "${context}")
  log "platform $(bom_get .platformVersion): task-auth on Kubernetes ${k8s_version}, environment ${environment}"

  # Observe this job's signed claims. The probe token has its own audience,
  # so it cannot be exchanged. Cross-check the claims against the job context.
  stage=claims
  local probe
  probe="$(github_token steward-platform-task-auth-claims-probe)"
  jwt_claims "${probe}" | jq '{iss, sub, ref, event_name, repository, repository_id,
    repository_owner_id, actor, actor_id, workflow_ref, workflow_sha, job_workflow_ref, job_workflow_sha}' \
    > "${state}/claims.json"
  jq -e --arg owner "${GITHUB_REPOSITORY_OWNER_ID:-}" --arg repo "${GITHUB_REPOSITORY_ID:-}" \
    --arg event "${GITHUB_EVENT_NAME:-}" --arg ref "${GITHUB_REF:-}" --arg actor "${GITHUB_ACTOR_ID:-}" \
    --arg workflow_ref "${GITHUB_WORKFLOW_REF:-}" --arg workflow_sha "${GITHUB_WORKFLOW_SHA:-}" '
      .iss == "https://token.actions.githubusercontent.com"
      and .repository_owner_id == $owner and .repository_id == $repo
      and .event_name == $event and .ref == $ref and .actor_id == $actor
      and .workflow_ref == $workflow_ref and .workflow_sha == $workflow_sha
      and (.sub | startswith("repo:"))' "${state}/claims.json" >/dev/null \
    || die "the GitHub OIDC claims do not match this job's context: $(jq -c . "${state}/claims.json")"
  pass "observed this job's signed GitHub claims: $(jq -c '{sub, event_name, ref, repository_id, repository_owner_id, job_workflow_ref}' "${state}/claims.json")"

  # The exchange policy: generated here, never committed, admitting only this
  # repository, subject, event and ref. Validated against the product's own
  # v6 schema at the BOM commit.
  stage=policy
  curl --fail --silent --show-error --location --retry 3 \
    "https://raw.githubusercontent.com/${identity_source#https://github.com/}/${identity_commit}/docs/policy-contract-v6.schema.json" \
    -o "${state}/policy-v6.schema.json"
  write_policy "$(jq -r .sub "${state}/claims.json")" "${state}/policy.json"
  pass "generated a v6 policy admitting only this job's subject, event and ref"

  # The ES256 keyring and its public JWKS, with the product's keyring-tool.
  stage=keyring
  (umask 077 && "${KEYRING_TOOL}" generate-es256 "${state}/keyring.json" "task-auth-e2e-$(date -u +%Y%m%d%H%M%S)" >/dev/null)
  "${KEYRING_TOOL}" validate-es256 "${state}/keyring.json" >/dev/null
  "${KEYRING_TOOL}" export-jwks "${state}/keyring.json" > "${state}/jwks.json"
  jq -e '[.keys[] | select(.alg == "ES256" and .use == "sig" and (has("d") | not))] | length == 1' \
    "${state}/jwks.json" >/dev/null || die "export-jwks did not produce one public ES256 signing key"
  pass "created the exchange keyring and exported its public JWKS"

  stage=cluster
  kind create cluster --name "${cluster}" --kubeconfig "${kubeconfig}" \
    --config "${kind_config}" --image "${node_image}" --wait 180s
  chmod 600 "${kubeconfig}"
  [[ "$("${K[@]}" version -o json | jq -r .serverVersion.gitVersion)" == "v${k8s_version}" ]] \
    || die "the cluster does not run v${k8s_version}"

  stage=generate
  local generated="${state}/generated"
  "${repo_root}/scripts/generate.sh" --bom "${bom}" --out "${generated}/${environment}" "${platform_values}"

  # The operator-owned inputs the charts only reference.
  stage=inputs
  local ns
  for ns in "${steward_ns}" "${identity_ns}"; do "${K[@]}" create namespace "${ns}" >/dev/null; done
  apply_policy "${state}/policy.json"
  "${K[@]}" -n "${identity_ns}" create secret generic "${keyring_secret}" \
    --from-file=keyring.json="${state}/keyring.json" >/dev/null
  "${K[@]}" -n "${steward_ns}" create configmap "${jwks_configmap}" \
    --from-file="${jwks_key}=${state}/jwks.json" >/dev/null
  rm -f "${state}/keyring.json"

  stage=install
  env "KUBECONFIG=${kubeconfig}" "PLATFORM_GENERATED_DIR=${generated}" "PLATFORM_KUBE_CONTEXT=${context}" "BOM=${bom}" \
    helmfile --file "${helmfile_file}" --environment "${environment}" --kube-context "${context}" sync
  "${K[@]}" -n "${steward_ns}" rollout status deployment/steward-apiserver --timeout=180s
  "${K[@]}" -n "${identity_ns}" rollout status deployment/github-oidc-exchange --timeout=180s

  stage=assert-install
  assert_install

  stage=edge
  "${K[@]}" -n "${gateway_ns}" get secret "${edge_ca_secret}" -o jsonpath='{.data.tls\.crt}' \
    | base64 -d > "${state}/edge-ca.crt"
  openssl x509 -in "${state}/edge-ca.crt" -noout
  if [[ "$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)" -gt "${edge_port}" ]]; then
    sudo sysctl -q -w "net.ipv4.ip_unprivileged_port_start=${edge_port}"
  fi
  local port_forward_pid=""
  start_port_forward
  save_state port_forward_pid
  sudo sed -i "/${hosts_marker}\$/d" /etc/hosts
  echo "127.0.0.1 ${steward_host} ${identity_host} ${hosts_marker}" | sudo tee -a /etc/hosts >/dev/null
  local _
  for _ in {1..30}; do edge_alive && break; sleep 2; done
  edge_alive || die "the edge does not answer on 127.0.0.1:${edge_port}"
  pass "the edge serves ${steward_host} and ${identity_host} on 127.0.0.1:${edge_port}"

  stage=assert-discovery
  assert_discovery

  # Baselines for verify.
  stage=baseline
  [[ "$(psql_steward 'SELECT count(*) FROM federated_subjects')" == 0 ]] || die "Steward already has federated subjects"
  [[ "$(psql_steward 'SELECT count(*) FROM task_submissions')" == 0 ]] || die "Steward already has Tasks"
  [[ "$(count_events '.event == "exchange_issued"')" == 0 ]] || die "the exchange has already issued a token"

  # The action's workspace input; the request never reaches upload.
  mkdir -p "${GITHUB_WORKSPACE:-${repo_root}}/task-auth-probe"
  echo "steward-platform task-auth probe" > "${GITHUB_WORKSPACE:-${repo_root}}/task-auth-probe/request.txt"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "steward-api-url=${steward_origin}"
      echo "edge-ca-file=${state}/edge-ca.crt"
      echo "action-commit=${action_commit}"
    } >> "${GITHUB_OUTPUT}"
  fi
  stage=complete
  trap - EXIT
  log "task-auth e2e up: ready for the steward-run action at ${action_commit}"
}

assert_install() {
  "${K[@]}" -n "${gateway_ns}" wait --for=condition=Programmed --timeout=180s "gateway/${gateway_name}" >/dev/null \
    || die "Gateway ${gateway_ns}/${gateway_name} is not Programmed"
  local route
  for route in "${steward_ns}/steward-task-api" "${identity_ns}/github-oidc-exchange"; do
    local accepted=0 _
    for _ in {1..30}; do
      if "${K[@]}" -n "${route%/*}" get httproute "${route#*/}" -o json | jq -e '
          [.status.parents[]?.conditions[]? | select((.type == "Accepted" or .type == "ResolvedRefs") and .status == "True")]
          | length >= 2' >/dev/null; then
        accepted=1
        break
      fi
      sleep 2
    done
    [[ "${accepted}" == 1 ]] || die "HTTPRoute ${route} is not Accepted with resolved references: $("${K[@]}" -n "${route%/*}" get httproute "${route#*/}" -o jsonpath='{.status}')"
  done
  local policy_ok=0 _
  for _ in {1..30}; do
    if "${K[@]}" -n "${steward_ns}" get backendtlspolicy steward-apiserver -o json | jq -e '
        [.status.ancestors[]?.conditions[]? | select(.type == "Accepted" and .status == "True")] | length >= 1' >/dev/null; then
      policy_ok=1
      break
    fi
    sleep 2
  done
  [[ "${policy_ok}" == 1 ]] || die "BackendTLSPolicy steward-apiserver is not Accepted: $("${K[@]}" -n "${steward_ns}" get backendtlspolicy steward-apiserver -o jsonpath='{.status}')"
  pass "Gateway Programmed; Steward and exchange HTTPRoutes Accepted with resolved references; BackendTLSPolicy Accepted"

  # Running pods use the BOM digests.
  local ids
  assert_digest() {
    ids="$("${K[@]}" -n "$1" get pods -l "$2" -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}')"
    grep -Fq "@${3#*@}" <<<"${ids}" || die "no pod in $1 ($2) runs BOM image $3; running: ${ids}"
  }
  assert_digest "${identity_ns}" "${identity_selector}" "$(bom_get '.products["github-oidc-exchange"].images.exchange')"
  assert_digest "${edge_ns}" app.kubernetes.io/name=gateway-helm "$(bom_get '.dependencies["envoy-gateway"].images.controller')"
  assert_digest "${edge_ns}" "gateway.envoyproxy.io/owning-gateway-name=${gateway_name}" \
    "$(bom_get '.dependencies["envoy-gateway"].images.proxy')"
  assert_digest "${steward_ns}" app.kubernetes.io/component=apiserver "$(bom_get .products.steward.images.apiserver)"
  pass "github-oidc-exchange, Envoy Gateway, Envoy and Steward run their BOM image digests"

  # Steward reads the exported JWKS; the exchange signs with the same key.
  "${K[@]}" -n "${steward_ns}" get deployment steward-apiserver -o json | jq -e --arg name "${jwks_configmap}" '
    [.spec.template.spec.volumes[] | select(.configMap.name == $name)] | length == 1' >/dev/null \
    || die "steward-apiserver does not mount the JWKS ConfigMap ${jwks_configmap}"
}

assert_discovery() {
  local body headers
  # Steward protected-resource metadata, through the edge and BackendTLSPolicy.
  headers="${state}/prm.headers"
  body="$(edge_curl --fail --dump-header "${headers}" "${steward_origin}/.well-known/oauth-protected-resource")" \
    || die "Steward protected-resource metadata is not reachable through the edge"
  jq -e --arg resource "${steward_origin}" --arg issuer "${identity_issuer}" '
    .resource == $resource and .authorization_servers == [$issuer]
    and .bearer_methods_supported == ["header"]
    and .steward_task_token_contracts == ["steward-task-v2", "steward-task-v3"]' <<<"${body}" >/dev/null \
    || die "unexpected Steward protected-resource metadata: ${body}"
  grep -iq '^cache-control: public, max-age=300' "${headers}" || die "protected-resource metadata is not cacheable for 300 s"
  pass "Steward protected-resource metadata names ${steward_origin}, issuer ${identity_issuer}, and steward-task-v2 and v3"

  # github-oidc-exchange metadata, on both discovery paths.
  local path first=""
  for path in /.well-known/oauth-authorization-server /.well-known/openid-configuration; do
    body="$(edge_curl --fail "${identity_issuer}${path}")" || die "${identity_issuer}${path} is not reachable through the edge"
    jq -e --arg issuer "${identity_issuer}" --arg audience "${github_audience}" '
      .issuer == $issuer and .jwks_uri == ($issuer + "/jwks.json")
      and .github_oidc_exchange_endpoint == ($issuer + "/v1/exchange")
      and .github_oidc_audience == $audience
      and (.identity_contracts_supported | index("steward-task-v3"))
      and (.policy_versions_supported | index("github-oidc-exchange.apelogic.io/v6"))' <<<"${body}" >/dev/null \
      || die "unexpected exchange metadata at ${path}: ${body}"
    if [[ -z "${first}" ]]; then first="${body}"; else
      [[ "$(jq -S . <<<"${first}")" == "$(jq -S . <<<"${body}")" ]] || die "the two exchange metadata documents differ"
    fi
  done
  pass "exchange metadata (RFC 8414 and OpenID paths agree): issuer, exchange endpoint, GitHub audience ${github_audience}, steward-task-v3, policy v6"

  # The issuer's public keys are the ones Steward holds.
  body="$(edge_curl --fail "${identity_issuer}/jwks.json")" || die "the exchange JWKS is not reachable"
  [[ "$(jq -c '[.keys[] | select(.alg == "ES256") | .kid] | sort' <<<"${body}")" \
    == "$(jq -c '[.keys[] | select(.alg == "ES256") | .kid] | sort' "${state}/jwks.json")" ]] \
    || die "the exchange publishes ES256 keys that differ from Steward's JWKS ConfigMap"
  pass "the exchange's published ES256 key IDs match the JWKS Steward verifies against"
}

# =============================================================================

cmd_verify() {
  stage=preflight
  have_oidc || die "no GitHub Actions OIDC token is available"
  load_state
  trap on_error EXIT
  ensure_edge

  local actor_id actor subject submission
  actor_id="$(jq -r .actor_id "${state}/claims.json")"
  actor="$(jq -r .actor "${state}/claims.json")"
  subject="github-actions:actor:${actor_id}"
  submission="$(jq -cn --arg w "${probe_workflow}" '{workflow: $w}')"

  # 1. The released action ran against Steward through the edge.
  stage=action
  if [[ -n "${STEWARD_RUN_ACTION_PATH:-}" ]]; then
    [[ "$(git -C "${STEWARD_RUN_ACTION_PATH}" rev-parse HEAD)" == "${action_commit}" ]] \
      || die "the action checkout is not the BOM action commit ${action_commit}"
  fi
  [[ "${STEWARD_RUN_OUTCOME:-}" == failure ]] \
    || die "the steward-run action outcome is '${STEWARD_RUN_OUTCOME:-unset}'; Steward must refuse the unassociated subject"
  [[ "$(count_events '.event == "exchange_issued" and .actor_id == $a and .job_workflow_ref == $b' \
      "${actor_id}" "$(jq -r .job_workflow_ref "${state}/claims.json")")" == 1 ]] \
    || die "the exchange did not issue exactly one token to the action for actor ${actor_id}"
  local observed
  observed="$(psql_steward "SELECT s.state || '|' || (s.canonical_user_id IS NULL)::text || '|' || coalesce(s.actor_login, '') || '|' || s.revision || '|' || a.action || '|' || a.actor
    FROM federated_subjects s JOIN federated_subject_audit a USING (subject_id)
    WHERE s.issuer = $(sql_quote "${identity_issuer}") AND s.subject = $(sql_quote "${subject}")")"
  [[ "${observed}" == "observed|true|${actor}|1|observed|task-auth" ]] \
    || die "Steward did not record exactly one unassociated observation of ${subject}: '${observed}'"
  [[ "$(psql_steward 'SELECT count(*) FROM federated_subjects')" == 1 ]] || die "Steward recorded other subjects"
  [[ "$(psql_steward 'SELECT count(*) FROM task_submissions')" == 0 ]] || die "Steward created a Task"
  pass "the steward-run action (${action_commit}) discovered, exchanged and submitted: the exchange issued its token, Steward authenticated it and recorded ${subject} as an unassociated observation, and created no Task"

  # 2. The same chain, driven directly, so each response can be asserted.
  stage=exchange
  local metadata exchange_url assertion response token claims
  metadata="$(edge_curl --fail "${identity_issuer}/.well-known/oauth-authorization-server")"
  exchange_url="$(jq -er .github_oidc_exchange_endpoint <<<"${metadata}")"
  assertion="$(github_token "$(jq -er .github_oidc_audience <<<"${metadata}")")"
  response="$(edge_curl --request POST --header "Authorization: Bearer ${assertion}" \
    --dump-header "${state}/exchange.headers" --write-out '\n%{http_code}' "${exchange_url}")"
  [[ "${response##*$'\n'}" == 200 ]] || die "the exchange returned ${response##*$'\n'}: ${response%$'\n'*}"
  response="${response%$'\n'*}"
  grep -iq '^cache-control: no-store' "${state}/exchange.headers" || die "the exchange response is cacheable"
  jq -e '.token_type == "Bearer" and .expires_in == 120 and (.access_token | type == "string")' <<<"${response}" >/dev/null \
    || die "unexpected exchange response shape: $(jq -c 'del(.access_token)' <<<"${response}")"
  token="$(jq -r .access_token <<<"${response}")"
  mask "${token}"
  claims="$(jwt_claims "${token}")"
  jq -e --arg iss "${identity_issuer}" --arg aud "${task_audience}" --arg sub "${subject}" --arg actor "${actor}" \
    --slurpfile c "${state}/claims.json" '
    $c[0] as $g
    | .iss == $iss and .aud == [$aud] and .sub == $sub and .identity_contract == "steward-task-v3"
      and .actor_login == $actor and (has("email") or has("email_verified") or has("groups") | not)
      and (.exp - .iat) == 120
      and .source_provenance.contractVersion == "steward.source-provenance/v1"
      and .source_provenance.repository.id == $g.repository_id
      and .source_provenance.repository.ownerId == $g.repository_owner_id
      and .source_provenance.event == $g.event_name and .source_provenance.ref == $g.ref
      and .source_provenance.actorId == $g.actor_id
      and .source_provenance.callerWorkflow.ref == $g.workflow_ref
      and .source_provenance.callerWorkflow.sha == ("git:sha1:" + $g.workflow_sha)
      and .source_provenance.reusableWorkflow.ref == $g.job_workflow_ref
      and .source_provenance.reusableWorkflow.sha == ("git:sha1:" + $g.job_workflow_sha)' <<<"${claims}" >/dev/null \
    || die "unexpected task token claims: $(jq -c 'del(.jti)' <<<"${claims}")"
  pass "exchange: 200, no-store, a 120-second steward-task-v3 bearer token for ${subject}, audience ${task_audience}, with this workflow's ref and SHA in signed provenance"

  # 3. Steward authenticates the token: the documented v3 answer for a valid
  # token whose subject no administrator has associated with a Steward user.
  stage=steward
  local seen_before
  seen_before="$(psql_steward "SELECT last_seen_at FROM federated_subjects WHERE subject = $(sql_quote "${subject}")")"
  response="$(edge_curl --request POST --header "Authorization: Bearer ${token}" \
    --header "Idempotency-Key: task-auth-e2e-$(date -u +%s)" --header 'Content-Type: application/json' \
    --data "${submission}" --write-out '\n%{http_code}' "${steward_origin}/v1/tasks")"
  [[ "${response##*$'\n'}" == 403 ]] || die "Steward returned ${response##*$'\n'}, expected 403: ${response%$'\n'*}"
  jq -e --arg issuer "${identity_issuer}" --arg subject "${subject}" '
    .error == "task_identity_unassociated" and .issuer == $issuer and .subject == $subject' \
    <<<"${response%$'\n'*}" >/dev/null || die "unexpected Steward 403 body: ${response%$'\n'*}"
  [[ "$(psql_steward "SELECT (last_seen_at > $(sql_quote "${seen_before}")::timestamptz)::text || '|' || revision FROM federated_subjects WHERE subject = $(sql_quote "${subject}")")" == "true|1" ]] \
    || die "Steward did not re-observe ${subject} on the direct submission"
  [[ "$(psql_steward 'SELECT count(*) FROM task_submissions')" == 0 ]] || die "Steward created a Task"
  pass "Steward: 403 task_identity_unassociated for issuer ${identity_issuer} and subject ${subject}; observation refreshed, no Task"

  # The same route without a valid token is a plain 401, so the 403 above is
  # the authenticated path, not the edge or a generic refusal.
  local status
  status="$(edge_curl --output /dev/null --write-out '%{http_code}' --request POST \
    --header 'Authorization: Bearer not-a-token' --header 'Idempotency-Key: task-auth-e2e-negative' \
    --header 'Content-Type: application/json' --data "${submission}" "${steward_origin}/v1/tasks")"
  [[ "${status}" == 401 ]] || die "Steward returned ${status} for an invalid bearer token, expected 401"
  status="$(edge_curl --output /dev/null --write-out '%{http_code}' --request POST \
    --header "Authorization: Bearer ${assertion}" --header 'Idempotency-Key: task-auth-e2e-raw' \
    --header 'Content-Type: application/json' --data "${submission}" "${steward_origin}/v1/tasks")"
  [[ "${status}" == 401 ]] || die "Steward returned ${status} for the raw GitHub token, expected 401"
  pass "Steward: 401 for an invalid bearer and for the raw GitHub OIDC token"

  # 4. Replay: the same GitHub assertion a second time.
  stage=replay
  local jti hash
  jti="$(jwt_claims "${assertion}" | jq -r .jti)"
  hash="$(jti_hash "${jti}")"
  response="$(edge_curl --request POST --header "Authorization: Bearer ${assertion}" --write-out '\n%{http_code}' "${exchange_url}")"
  expect_invalid_token "${response}" "a replayed assertion"
  [[ "$(count_events '.event == "exchange_replayed" and .reason == "replay" and .source_jti_hash == $a' "${hash}")" == 1 ]] \
    || die "the exchange did not record the replay of jti hash ${hash}"
  pass "replay: 401 invalid_token; the exchange recorded exchange_replayed for the assertion's jti"

  # 5. Wrong audience: a fresh GitHub token for another audience.
  stage=audience
  local denied_before
  denied_before="$(count_events '.event == "exchange_denied" and .reason == "assertion is invalid"')"
  assertion="$(github_token "${github_audience}-wrong")"
  response="$(edge_curl --request POST --header "Authorization: Bearer ${assertion}" --write-out '\n%{http_code}' "${exchange_url}")"
  expect_invalid_token "${response}" "a wrong-audience assertion"
  [[ "$(count_events '.event == "exchange_denied" and .reason == "assertion is invalid"')" == $((denied_before + 1)) ]] \
    || die "the exchange did not record the wrong-audience denial"
  pass "wrong audience: 401 invalid_token; the exchange denied the assertion at verification"

  # 6. A workflow the policy does not admit: the same repository, but a policy
  # whose subject selector names another branch's workflow. The exchange reads
  # its policy only at startup, so roll it.
  stage=policy
  write_policy "repo:$(jq -r .repository "${state}/claims.json"):ref:refs/heads/steward-platform-policy-mismatch" \
    "${state}/policy-mismatch.json"
  apply_policy "${state}/policy-mismatch.json"
  "${K[@]}" -n "${identity_ns}" rollout restart deployment/github-oidc-exchange >/dev/null
  "${K[@]}" -n "${identity_ns}" rollout status deployment/github-oidc-exchange --timeout=180s >/dev/null
  ensure_edge
  # The edge follows the new endpoints within seconds; until then it answers 503.
  local _
  metadata=""
  for _ in {1..30}; do
    metadata="$(edge_curl --fail "${identity_issuer}/.well-known/oauth-authorization-server" 2>/dev/null)" && break
    metadata=""
    sleep 2
  done
  [[ -n "${metadata}" ]] || die "the exchange did not come back behind the edge after the policy change"
  assertion="$(github_token "$(jq -er .github_oidc_audience <<<"${metadata}")")"
  hash="$(jti_hash "$(jwt_claims "${assertion}" | jq -r .jti)")"
  response="$(edge_curl --request POST --header "Authorization: Bearer ${assertion}" --write-out '\n%{http_code}' "${exchange_url}")"
  expect_invalid_token "${response}" "an assertion the policy does not admit"
  [[ "$(count_events '.event == "exchange_denied" and .reason == "identity is not authorized" and .source_jti_hash == $a' "${hash}")" == 1 ]] \
    || die "the exchange did not record a policy denial for jti hash ${hash}"
  pass "unadmitted workflow: 401 invalid_token; the exchange denied it by policy (identity is not authorized)"

  stage=complete
  trap - EXIT
  log "task-auth e2e passed: platform $(bom_get .platformVersion), Kubernetes ${k8s_version}"
}

# =============================================================================

cmd_down() {
  stage=down
  if [[ -f "${state_file}" ]]; then
    load_state
    if [[ -n "${port_forward_pid:-}" ]]; then kill "${port_forward_pid}" 2>/dev/null || true; fi
    if [[ "${KEEP_CLUSTER:-0}" == 1 ]]; then
      echo "kept cluster ${cluster} (kubeconfig ${kubeconfig}) and ${state}" >&2
    else
      kind delete cluster --name "${cluster}" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -w /etc/hosts ]] || command -v sudo >/dev/null; then
    sudo sed -i "/${hosts_marker}\$/d" /etc/hosts 2>/dev/null || true
  fi
  [[ "${KEEP_CLUSTER:-0}" == 1 ]] || rm -rf "${state}"
}

# The composite action runs `node` from PATH (apelogic-ai/steward-run#69):
# check that it satisfies the action's own engines range.
cmd_check_node() {
  stage=check-node
  local action_path="${1:?usage: $0 check-node ACTION_PATH}" range node_version major
  range="$(jq -er .engines.node "${action_path}/package.json")"
  node_version="$(node --version)"
  node_version="${node_version#v}"
  major="${node_version%%.*}"
  [[ "${range}" =~ ^\>=([0-9]+)\ \<([0-9]+)$ ]] || die "unrecognised engines.node range ${range}"
  (( major >= BASH_REMATCH[1] && major < BASH_REMATCH[2] )) \
    || die "Node ${node_version} does not satisfy the action's engines.node ${range}"
  pass "Node ${node_version} satisfies the action's engines.node ${range}"
}

case "${command}" in
  up) cmd_up ;;
  check-node) cmd_check_node "${2:-}" ;;
  verify) cmd_verify ;;
  down) cmd_down ;;
  *) echo "usage: $0 up|verify|down, or $0 check-node ACTION_PATH" >&2; exit 2 ;;
esac
