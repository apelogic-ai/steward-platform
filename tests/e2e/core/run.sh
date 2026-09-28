#!/usr/bin/env bash
# Core profile end-to-end test on a disposable kind cluster, through the
# reference install.
#
# Creates a kind cluster from environments/kind/kind-config.yaml and the BOM
# node image, runs scripts/generate.sh on environments/kind/platform-values.yaml,
# installs with helmfile/helmfile.yaml.gotmpl (cert-manager, the evaluation CA,
# evaluation PostgreSQL and Steward), then asserts that:
#   - helmfile installs each BOM chart at its BOM digest, and the Steward chart
#     at that digest has the BOM version;
#   - the rendered chart and the running pods use the exact image digests from
#     the BOM (Steward, cert-manager, PostgreSQL);
#   - every database migration applied;
#   - cert-manager issued both Steward certificates from the evaluation CA and
#     injected the CA into the webhook;
#   - the admission webhook denies an invalid AgentRuntime;
#   - the API answers over verified TLS (401 on an admin route).
#
# Usage: tests/e2e/core/run.sh
# Env:
#   BOM           path to the BOM (default: bom/bom.json)
#   K8S_VERSION   a version from kubernetes.tested (default: the highest)
#   KEEP_CLUSTER  set to 1 to keep the cluster and work directory for debugging
# Needs: docker (linux/amd64 engine), kind, helm, helmfile, kubectl, jq, yq
# (mikefarah v4), check-jsonschema, openssl, curl, tar.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
bom="${BOM:-${repo_root}/bom/bom.json}"
keep_cluster="${KEEP_CLUSTER:-0}"
environment_dir="${repo_root}/environments/kind"
platform_values="${environment_dir}/platform-values.yaml"
helmfile_file="${repo_root}/helmfile/helmfile.yaml.gotmpl"

stage=preflight
cluster_created=0
port_forward_pid=""
run_dir=""

for tool in docker kind helm helmfile kubectl jq yq check-jsonschema openssl curl tar; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

# --- Read every coordinate from the BOM and the platform values -------------

bom_get() { jq -er "$1" "${bom}"; }
values_get() { yq -er "$1" "${platform_values}"; }

for member in '.profiles.core.products | index("steward")' \
  '.profiles.core.dependencies | index("postgresql")' \
  '.profiles.core.dependencies | index("cert-manager")'; do
  bom_get "${member}" >/dev/null || { echo "BOM core profile lacks ${member}" >&2; exit 2; }
done

platform_version="$(bom_get .platformVersion)"
k8s_version="${K8S_VERSION:-$(bom_get '.kubernetes.tested | max_by(.version | split(".") | map(tonumber)) | .version')}"
node_image="$(jq -er --arg v "${k8s_version}" '.kubernetes.tested[] | select(.version == $v) | .nodeImage' "${bom}")" || {
  echo "Kubernetes ${k8s_version} is not in kubernetes.tested" >&2
  exit 2
}
chart_reference="$(bom_get .products.steward.chart.reference)"
chart_version="$(bom_get .products.steward.chart.version)"
chart_digest="$(bom_get .products.steward.chart.digest)"
cert_manager_chart="$(bom_get '.dependencies["cert-manager"].chart | "\(.reference)@\(.digest)"')"
steward_images=("$(bom_get .products.steward.images.apiserver)" "$(bom_get .products.steward.images.controller)")
cert_manager_images=()
for component in controller webhook cainjector; do
  cert_manager_images+=("$(bom_get ".dependencies[\"cert-manager\"].images.${component}")")
done
postgres_ref="$(bom_get .dependencies.postgresql.images.postgres)"

environment="$(values_get .environment)"
namespace="$(values_get .namespaces.steward)"
cert_manager_namespace="$(values_get .namespaces.certManager)"
postgres_name=postgresql-evaluation
ca_name=steward-platform-evaluation-ca

image_digest() { echo "${1#*@}"; }

# True when IPv4 address $1 is inside CIDR $2.
ipv4_in_cidr() {
  local ip="$1" network="${2%/*}" bits="${2#*/}" a b c d
  IFS=. read -r a b c d <<<"${ip}"
  local ip_n=$(((a << 24) | (b << 16) | (c << 8) | d))
  IFS=. read -r a b c d <<<"${network}"
  local net_n=$(((a << 24) | (b << 16) | (c << 8) | d))
  local mask=$(((0xffffffff << (32 - bits)) & 0xffffffff))
  (((ip_n & mask) == (net_n & mask)))
}
ip_in_any() {
  local ip="$1" cidr
  shift
  for cidr in "$@"; do
    [[ "${cidr}" == */* && "${cidr}" != *:* ]] || continue
    ipv4_in_cidr "${ip}" "${cidr}" && return 0
  done
  return 1
}

# --- Disposable resources and cleanup ---------------------------------------

run_id="core-$(date -u +%Y%m%d%H%M%S)-$$"
cluster="spf-${run_id}"
context="kind-${cluster}"
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
run_dir="$(mktemp -d "${temp_root%/}/spf-${run_id}.XXXXXX")"
chmod 700 "${run_dir}"
kubeconfig="${run_dir}/kubeconfig"
generated="${run_dir}/generated"
K=(kubectl --kubeconfig "${kubeconfig}" --context "${context}")
KN=("${K[@]}" -n "${namespace}")
HF=(env "KUBECONFIG=${kubeconfig}" "PLATFORM_GENERATED_DIR=${generated}"
  helmfile --file "${helmfile_file}" --environment "${environment}" --kube-context "${context}")

diagnostics() {
  echo "--- diagnostics" >&2
  "${K[@]}" get pods -A -o wide >&2 2>/dev/null
  "${KN[@]}" get certificates,issuers,certificaterequests -o wide >&2 2>/dev/null
  "${K[@]}" get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -40 >&2
  for deployment in steward-apiserver steward-controller "${postgres_name}"; do
    echo "--- logs: ${deployment}" >&2
    "${KN[@]}" logs "deployment/${deployment}" --all-containers --tail=60 >&2 2>/dev/null
  done
  echo "--- logs: cert-manager" >&2
  "${K[@]}" -n "${cert_manager_namespace}" logs deployment/cert-manager --tail=40 >&2 2>/dev/null
}

cleanup() {
  local status="$?"
  trap - EXIT INT TERM
  set +e
  if [[ "${status}" != 0 ]]; then
    echo "core e2e failed at stage ${stage} (exit ${status})" >&2
    [[ "${cluster_created}" == 1 ]] && diagnostics
  fi
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" >/dev/null 2>&1
    wait "${port_forward_pid}" >/dev/null 2>&1
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
  echo "Run on an amd64 host. See tests/e2e/core/README.md." >&2
  exit 2
fi

echo "platform ${platform_version}: Steward chart ${chart_version}, Kubernetes ${k8s_version}, environment ${environment}"
echo "owned cluster ${cluster}, work directory ${run_dir}"

# --- Generate and check the reference install inputs ------------------------

stage=generate
"${repo_root}/scripts/generate.sh" --bom "${bom}" --out "${generated}/${environment}" "${platform_values}"
"${HF[@]}" build > "${run_dir}/helmfile-build.yaml"
for pinned in "${chart_reference}@${chart_digest}" "${cert_manager_chart}"; do
  release="${pinned%@*}"
  release="${release##*/}"
  actual="$(yq -r "select(.releases) | .releases[] | select(.name == \"${release}\") | .chart" "${run_dir}/helmfile-build.yaml")"
  if [[ "${actual}" != "${pinned}" ]]; then
    echo "helmfile installs ${release} from '${actual}', BOM pins ${pinned}" >&2
    exit 1
  fi
done
echo "pass: helmfile installs Steward and cert-manager at their BOM chart digests"

# The Steward chart at the BOM digest is the BOM version.
stage=chart
helm pull "${chart_reference}@${chart_digest}" --destination "${run_dir}" >/dev/null
chart_archive="$(find "${run_dir}" -maxdepth 1 -type f -name 'steward*.tgz' -print -quit)"
test -s "${chart_archive}"
tar -xOf "${chart_archive}" steward/Chart.yaml > "${run_dir}/Chart.yaml"
grep -Fxq "version: ${chart_version}" "${run_dir}/Chart.yaml" || {
  echo "chart at ${chart_digest} is not version ${chart_version}" >&2
  exit 1
}

stage=render
"${HF[@]}" --selector name=steward template > "${run_dir}/rendered.yaml"
for ref in "${steward_images[@]}"; do
  grep -Fq "image: ${ref}" "${run_dir}/rendered.yaml" || {
    echo "rendered chart does not use BOM image ${ref}" >&2
    exit 1
  }
done
echo "pass: rendered Steward chart uses the BOM image digests"

# --- Cluster ----------------------------------------------------------------

stage=cluster
cluster_created=1
kind create cluster --name "${cluster}" --kubeconfig "${kubeconfig}" \
  --config "${environment_dir}/kind-config.yaml" --image "${node_image}" --wait 180s
chmod 600 "${kubeconfig}"
server_version="$("${K[@]}" version -o json | jq -r .serverVersion.gitVersion)"
if [[ "${server_version}" != "v${k8s_version}" ]]; then
  echo "cluster runs ${server_version}, expected v${k8s_version}" >&2
  exit 1
fi

# The kind platform values describe this cluster: check before installing.
stage=cluster_facts
kube_api_cidrs=()
while IFS= read -r cidr; do kube_api_cidrs+=("${cidr}"); done < <(values_get '.cluster.kubeApi.cidrs[]')
kube_api_ip="$("${K[@]}" -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')"
ip_in_any "${kube_api_ip}" "${kube_api_cidrs[@]}" || {
  echo "kubernetes Service IP ${kube_api_ip} is outside cluster.kubeApi.cidrs (${kube_api_cidrs[*]})" >&2
  exit 1
}
token_audience="$("${K[@]}" get --raw /.well-known/openid-configuration | jq -er .issuer)"
if [[ "${token_audience}" != "$(values_get .cluster.serviceAccountTokenAudience)" ]]; then
  echo "cluster issuer ${token_audience} is not cluster.serviceAccountTokenAudience" >&2
  exit 1
fi
echo "pass: cluster matches the kind platform values (API ${kube_api_ip}, audience ${token_audience})"

# --- Install ----------------------------------------------------------------

stage=install
"${HF[@]}" sync
"${KN[@]}" rollout status deployment/steward-apiserver --timeout=180s
"${KN[@]}" rollout status deployment/steward-controller --timeout=180s

# --- Assertions -------------------------------------------------------------

stage=assert-images
running_digests() {
  "${K[@]}" -n "$1" get pods -l "$2" \
    -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}'
}
assert_running() {
  local namespace="$1" selector="$2" ids ref
  shift 2
  ids="$(running_digests "${namespace}" "${selector}")"
  for ref in "$@"; do
    grep -Fq "@$(image_digest "${ref}")" <<<"${ids}" || {
      echo "no running container in ${namespace} (${selector}) uses BOM image ${ref}; running: ${ids}" >&2
      exit 1
    }
  done
}
assert_running "${namespace}" app.kubernetes.io/name=steward "${steward_images[@]}"
assert_running "${cert_manager_namespace}" app.kubernetes.io/instance=cert-manager "${cert_manager_images[@]}"
assert_running "${namespace}" app.kubernetes.io/name=postgresql-evaluation "${postgres_ref}"
echo "pass: running Steward, cert-manager and PostgreSQL pods use the BOM image digests"

stage=assert-network
postgres_ip="$("${KN[@]}" get pod -l app.kubernetes.io/name=postgresql-evaluation -o jsonpath='{.items[0].status.podIP}')"
postgres_cidrs=()
while IFS= read -r cidr; do postgres_cidrs+=("${cidr}"); done < <(values_get '.database.cidrs[]')
ip_in_any "${postgres_ip}" "${postgres_cidrs[@]}" || {
  echo "PostgreSQL pod IP ${postgres_ip} is outside database.cidrs (${postgres_cidrs[*]})" >&2
  exit 1
}
echo "pass: PostgreSQL pod ${postgres_ip} is inside the NetworkPolicy database CIDRs"

stage=assert-migrations
migration_counts="$("${KN[@]}" exec "deployment/${postgres_name}" -- \
  psql -U steward -d steward -Atc \
  "SELECT count(*)::text || ':' || (count(*) FILTER (WHERE success))::text FROM _sqlx_migrations")"
if [[ ! "${migration_counts}" =~ ^([0-9]+):([0-9]+)$ ]] \
  || [[ "${BASH_REMATCH[1]}" == 0 ]] \
  || [[ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[2]}" ]]; then
  echo "database migrations are incomplete (total:successful = ${migration_counts})" >&2
  exit 1
fi
echo "pass: ${BASH_REMATCH[1]} migrations applied"

stage=assert-certificates
"${KN[@]}" wait --for=condition=Ready --timeout=120s \
  certificate/steward-apiserver-tls certificate/steward-webhook-tls >/dev/null
"${KN[@]}" get secret "${ca_name}" -o jsonpath='{.data.tls\.crt}' | base64 -d > "${run_dir}/ca.crt"
openssl x509 -in "${run_dir}/ca.crt" -noout >/dev/null
for secret in steward-apiserver-tls steward-webhook-tls; do
  "${KN[@]}" get secret "${secret}" -o jsonpath='{.data.tls\.crt}' | base64 -d > "${run_dir}/${secret}.crt"
  openssl verify -CAfile "${run_dir}/ca.crt" "${run_dir}/${secret}.crt" >/dev/null || {
    echo "${secret} is not issued by the evaluation CA" >&2
    exit 1
  }
done
echo "pass: cert-manager issued both Steward certificates from the evaluation CA"

stage=assert-admission
"${K[@]}" get crd agentruntimes.agents.apelogic.ai -o json |
  jq -e 'any(.status.conditions[]?; .type == "Established" and .status == "True")' >/dev/null
# cert-manager's CA injector fills the webhook CA bundle asynchronously.
injected=0
for _ in {1..60}; do
  if "${K[@]}" get validatingwebhookconfiguration steward-agentruntime -o json |
    jq -e 'all(.webhooks[]; (.clientConfig.caBundle // "") | length > 0)' >/dev/null; then
    injected=1
    break
  fi
  sleep 2
done
[[ "${injected}" == 1 ]] || { echo "cert-manager did not inject the webhook CA bundle" >&2; exit 1; }
"${K[@]}" get validatingwebhookconfiguration steward-agentruntime -o json |
  jq -e 'all(.webhooks[]; .failurePolicy == "Fail" and
      .clientConfig.service.name == "steward-webhook")' >/dev/null
"${K[@]}" get validatingwebhookconfiguration steward-agentruntime \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d > "${run_dir}/webhook-ca.crt"
cmp -s <(openssl x509 -in "${run_dir}/ca.crt" -outform der) \
  <(openssl x509 -in "${run_dir}/webhook-ca.crt" -outform der) || {
  echo "the webhook CA bundle is not the evaluation CA" >&2
  exit 1
}
if "${KN[@]}" create --dry-run=server -f - > "${run_dir}/admission.log" 2>&1 <<YAML
apiVersion: agents.apelogic.ai/v1alpha1
kind: AgentRuntime
metadata:
  name: core-invalid-admission-probe
  namespace: ${namespace}
spec:
  principal: {kind: service, name: core-e2e-probe}
  owner: probe@example.test
  agentType: {name: core-e2e-probe}
  llms: []
  tools: []
  budget: {monthlyLimit: "0", currency: USD}
  ttl: forever
YAML
then
  echo "invalid AgentRuntime passed server-side dry-run admission" >&2
  exit 1
fi
if ! grep -Fq 'admission webhook "agentruntime.steward.agents.apelogic.ai" denied the request' \
  "${run_dir}/admission.log"; then
  echo "invalid AgentRuntime was not rejected by the Steward webhook:" >&2
  cat "${run_dir}/admission.log" >&2
  exit 1
fi
echo "pass: admission webhook denied an invalid AgentRuntime"

stage=assert-tls
"${KN[@]}" port-forward service/steward-apiserver :443 --address 127.0.0.1 \
  > "${run_dir}/port-forward.log" 2>&1 &
port_forward_pid="$!"
forward_port=""
for _ in {1..30}; do
  forward_port="$(sed -nE 's/.*127\.0\.0\.1:([0-9]+) ->.*/\1/p' "${run_dir}/port-forward.log" | head -1)"
  [[ -n "${forward_port}" ]] && break
  sleep 1
done
if [[ ! "${forward_port}" =~ ^[0-9]+$ ]]; then
  echo "API port-forward did not become ready" >&2
  exit 1
fi
api_host="steward-apiserver.${namespace}.svc.$(values_get .cluster.domain)"
api_status="$(curl --silent --show-error --noproxy '*' \
  --cacert "${run_dir}/ca.crt" \
  --connect-to "${api_host}:443:127.0.0.1:${forward_port}" \
  --output /dev/null --write-out '%{http_code}' \
  "https://${api_host}/admin/api/v1/runs")"
if [[ "${api_status}" != 401 ]]; then
  echo "admin route returned ${api_status}, expected 401 over verified TLS" >&2
  exit 1
fi
echo "pass: API answered 401 on an admin route over TLS verified against the evaluation CA"

stage=complete
echo "core e2e passed: platform ${platform_version}, Kubernetes ${k8s_version}, reference install (${environment})"
