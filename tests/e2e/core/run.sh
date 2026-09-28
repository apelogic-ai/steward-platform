#!/usr/bin/env bash
# Core profile end-to-end test on a disposable kind cluster.
#
# Installs the core profile (PostgreSQL for evaluation, service certificates,
# Steward) using only the chart, image and node-image coordinates in the BOM,
# then asserts that:
#   - the running pods use the exact image digests from the BOM;
#   - every database migration applied;
#   - the admission webhook denies an invalid AgentRuntime;
#   - the API answers over verified TLS (401 on an admin route).
#
# Usage: tests/e2e/core/run.sh
# Env:
#   BOM           path to the BOM (default: bom/bom.json)
#   K8S_VERSION   a version from kubernetes.tested (default: the highest)
#   KEEP_CLUSTER  set to 1 to keep the cluster and work directory for debugging
# Needs: docker (linux/amd64 engine), kind, helm, kubectl, jq, openssl, curl, tar.
#
# Ported from Steward's scripts/customer-core-install-e2e.sh at v0.3.0.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
bom="${BOM:-${repo_root}/bom/bom.json}"
keep_cluster="${KEEP_CLUSTER:-0}"
namespace=steward

stage=preflight
cluster_created=0
port_forward_pid=""
run_dir=""

for tool in docker kind helm kubectl jq openssl curl tar; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

# --- Read every coordinate from the BOM -------------------------------------

bom_get() { jq -er "$1" "${bom}"; }

for member in '.profiles.core.products | index("steward")' \
  '.profiles.core.dependencies | index("postgresql")'; do
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
apiserver_ref="$(bom_get .products.steward.images.apiserver)"
controller_ref="$(bom_get .products.steward.images.controller)"
postgres_ref="$(bom_get .dependencies.postgresql.images.postgres)"

# Split registry/repository:tag@sha256:digest.
image_repository() { local name="${1%@*}"; echo "${name%:*}"; }
image_tag() { local name="${1%@*}"; echo "${name##*:}"; }
image_digest() { echo "${1#*@}"; }

image_repo="$(image_repository "${apiserver_ref}")"
if [[ "$(image_repository "${controller_ref}")" != "${image_repo}" ]]; then
  echo "apiserver and controller images must share one repository for the chart" >&2
  exit 2
fi

# --- Disposable resources and cleanup ---------------------------------------

run_id="core-$(date -u +%Y%m%d%H%M%S)-$$"
cluster="spf-${run_id}"
context="kind-${cluster}"
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
run_dir="$(mktemp -d "${temp_root%/}/spf-${run_id}.XXXXXX")"
chmod 700 "${run_dir}"
kubeconfig="${run_dir}/kubeconfig"
K=(kubectl --kubeconfig "${kubeconfig}" --context "${context}")
KN=("${K[@]}" -n "${namespace}")

diagnostics() {
  echo "--- diagnostics" >&2
  "${KN[@]}" get pods -o wide >&2 2>/dev/null
  "${KN[@]}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -40 >&2
  for deployment in steward-apiserver steward-controller core-test-postgres; do
    echo "--- logs: ${deployment}" >&2
    "${KN[@]}" logs "deployment/${deployment}" --all-containers --tail=60 >&2 2>/dev/null
  done
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

echo "platform ${platform_version}: Steward chart ${chart_version}, Kubernetes ${k8s_version}"
echo "owned cluster ${cluster}, work directory ${run_dir}"

# --- Chart ------------------------------------------------------------------

stage=chart
helm pull "${chart_reference}@${chart_digest}" --destination "${run_dir}" >/dev/null
chart_archive="$(find "${run_dir}" -maxdepth 1 -type f -name 'steward*.tgz' -print -quit)"
test -s "${chart_archive}"
tar -xOf "${chart_archive}" steward/Chart.yaml > "${run_dir}/Chart.yaml"
grep -Fxq "version: ${chart_version}" "${run_dir}/Chart.yaml" || {
  echo "chart at ${chart_digest} is not version ${chart_version}" >&2
  exit 1
}

# --- Cluster ----------------------------------------------------------------

stage=cluster
cluster_created=1
kind create cluster --name "${cluster}" --kubeconfig "${kubeconfig}" \
  --image "${node_image}" --wait 180s
chmod 600 "${kubeconfig}"
server_version="$("${K[@]}" version -o json | jq -r .serverVersion.gitVersion)"
if [[ "${server_version}" != "v${k8s_version}" ]]; then
  echo "cluster runs ${server_version}, expected v${k8s_version}" >&2
  exit 1
fi
"${K[@]}" create namespace "${namespace}" >/dev/null

# --- Credentials and certificates -------------------------------------------

stage=credentials
umask 077
openssl rand -hex 24 | tr -d '\n' > "${run_dir}/postgres-password"
{
  printf 'postgres://steward:'
  cat "${run_dir}/postgres-password"
  printf '@core-test-postgres.%s.svc.cluster.local:5432/steward?sslmode=disable' "${namespace}"
} > "${run_dir}/database-url"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${run_dir}/ca.key" -out "${run_dir}/ca.crt" \
  -subj '/CN=steward-platform core e2e CA' >/dev/null 2>&1
for service in steward-apiserver steward-webhook; do
  openssl req -newkey rsa:2048 -nodes \
    -keyout "${run_dir}/${service}.key" -out "${run_dir}/${service}.csr" \
    -subj "/CN=${service}.${namespace}.svc" >/dev/null 2>&1
  printf 'subjectAltName=DNS:%s,DNS:%s.%s.svc,DNS:%s.%s.svc.cluster.local\n' \
    "${service}" "${service}" "${namespace}" "${service}" "${namespace}" > "${run_dir}/${service}.ext"
  openssl x509 -req -in "${run_dir}/${service}.csr" \
    -CA "${run_dir}/ca.crt" -CAkey "${run_dir}/ca.key" -CAcreateserial \
    -out "${run_dir}/${service}.crt" -days 1 -sha256 \
    -extfile "${run_dir}/${service}.ext" >/dev/null 2>&1
  openssl verify -CAfile "${run_dir}/ca.crt" "${run_dir}/${service}.crt" >/dev/null
done
"${KN[@]}" create secret generic steward-database \
  --from-file="url=${run_dir}/database-url" >/dev/null
"${KN[@]}" create secret generic core-test-postgres \
  --from-file="password=${run_dir}/postgres-password" >/dev/null
for service in steward-apiserver steward-webhook; do
  "${KN[@]}" create secret tls "${service}-tls" \
    --cert="${run_dir}/${service}.crt" --key="${run_dir}/${service}.key" >/dev/null
done

# --- PostgreSQL (evaluation only) -------------------------------------------

stage=postgres
"${KN[@]}" apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: core-test-postgres
spec:
  replicas: 1
  selector: {matchLabels: {app: core-test-postgres}}
  template:
    metadata:
      labels: {app: core-test-postgres}
    spec:
      containers:
        - name: postgres
          image: ${postgres_ref}
          env:
            - {name: POSTGRES_USER, value: steward}
            - {name: POSTGRES_DB, value: steward}
            - {name: POSTGRES_PASSWORD_FILE, value: /run/postgres/password}
          ports: [{containerPort: 5432}]
          volumeMounts: [{name: password, mountPath: /run/postgres, readOnly: true}]
          readinessProbe:
            exec: {command: [pg_isready, -U, steward]}
            periodSeconds: 3
      volumes:
        - name: password
          secret: {secretName: core-test-postgres}
---
apiVersion: v1
kind: Service
metadata:
  name: core-test-postgres
spec:
  selector: {app: core-test-postgres}
  ports: [{port: 5432, targetPort: 5432}]
YAML
"${KN[@]}" rollout status deployment/core-test-postgres --timeout=180s
postgres_ip="$("${KN[@]}" get pod -l app=core-test-postgres -o jsonpath='{.items[0].status.podIP}')"

# --- Steward ----------------------------------------------------------------

stage=install
# The chart's NetworkPolicy needs literal CIDRs for the Kubernetes API and
# PostgreSQL. TokenReview must use the audience this cluster's service account
# tokens carry, which on kind is not the chart default.
kube_api_ip="$("${K[@]}" -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')"
token_audience="$("${K[@]}" get --raw /.well-known/openid-configuration | jq -er .issuer)"
values=(
  --set-string "images.repository=${image_repo}"
  --set-string "images.apiserver.tag=$(image_tag "${apiserver_ref}")"
  --set-string "images.apiserver.digest=$(image_digest "${apiserver_ref}")"
  --set-string "images.controller.tag=$(image_tag "${controller_ref}")"
  --set-string "images.controller.digest=$(image_digest "${controller_ref}")"
  --set-string "networkPolicy.kubeApiCidrs[0]=${kube_api_ip}/32"
  --set-string "networkPolicy.postgresCidrs[0]=${postgres_ip}/32"
  --set-string "config.apiserver.kubernetesTokenReviewAudience=${token_audience}"
  --set-file "tls.webhook.caBundlePem=${run_dir}/ca.crt"
)
helm lint "${chart_archive}" "${values[@]}" >/dev/null
helm template steward "${chart_archive}" --namespace "${namespace}" \
  "${values[@]}" > "${run_dir}/rendered.yaml"
for ref in "${apiserver_ref}" "${controller_ref}"; do
  grep -Fq "image: ${ref}" "${run_dir}/rendered.yaml" || {
    echo "rendered chart does not use BOM image ${ref}" >&2
    exit 1
  }
done
helm --kubeconfig "${kubeconfig}" --kube-context "${context}" \
  upgrade --install steward "${chart_archive}" --namespace "${namespace}" \
  --atomic --wait --timeout 10m "${values[@]}" >/dev/null
"${KN[@]}" rollout status deployment/steward-apiserver --timeout=180s
"${KN[@]}" rollout status deployment/steward-controller --timeout=180s

# --- Assertions -------------------------------------------------------------

stage=assert-images
image_ids="$("${KN[@]}" get pods -l app.kubernetes.io/name=steward \
  -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}')"
for ref in "${apiserver_ref}" "${controller_ref}"; do
  grep -Fq "@$(image_digest "${ref}")" <<<"${image_ids}" || {
    echo "no running container uses BOM image ${ref}; running: ${image_ids}" >&2
    exit 1
  }
done
echo "pass: running pods use the BOM image digests"

stage=assert-migrations
migration_counts="$("${KN[@]}" exec deployment/core-test-postgres -- \
  psql -U steward -d steward -Atc \
  "SELECT count(*)::text || ':' || (count(*) FILTER (WHERE success))::text FROM _sqlx_migrations")"
if [[ ! "${migration_counts}" =~ ^([0-9]+):([0-9]+)$ ]] \
  || [[ "${BASH_REMATCH[1]}" == 0 ]] \
  || [[ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[2]}" ]]; then
  echo "database migrations are incomplete (total:successful = ${migration_counts})" >&2
  exit 1
fi
echo "pass: ${BASH_REMATCH[1]} migrations applied"

stage=assert-admission
"${K[@]}" get crd agentruntimes.agents.apelogic.ai -o json |
  jq -e 'any(.status.conditions[]?; .type == "Established" and .status == "True")' >/dev/null
"${K[@]}" get validatingwebhookconfiguration steward-agentruntime -o json |
  jq -e 'all(.webhooks[]; .failurePolicy == "Fail" and
      .clientConfig.service.name == "steward-webhook" and
      ((.clientConfig.caBundle // "") | length > 0))' >/dev/null
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
api_host="steward-apiserver.${namespace}.svc.cluster.local"
api_status="$(curl --silent --show-error --noproxy '*' \
  --cacert "${run_dir}/ca.crt" \
  --connect-to "${api_host}:443:127.0.0.1:${forward_port}" \
  --output /dev/null --write-out '%{http_code}' \
  "https://${api_host}/admin/api/v1/runs")"
if [[ "${api_status}" != 401 ]]; then
  echo "admin route returned ${api_status}, expected 401 over verified TLS" >&2
  exit 1
fi
echo "pass: API answered 401 on an admin route over verified TLS"

stage=complete
echo "core e2e passed: platform ${platform_version}, Kubernetes ${k8s_version}"
