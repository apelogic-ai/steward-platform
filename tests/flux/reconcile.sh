#!/usr/bin/env bash
# Reconcile the edge part of the task-auth Flux example with real Flux
# controllers on a disposable kind cluster.
#
# The static checks (tests/flux/run.sh) prove that the example is the
# helmfile's install; this proves that Flux accepts and reconciles the parts
# that have no helmfile counterpart: the CRD sources and Kustomizations, the
# Envoy Gateway release that races them (RetryOnFailure), and
# charts/steward-edge built from this repository's platform tag. It applies,
# unchanged, gateway-api-crds.yaml, envoy-gateway-crds.yaml and
# envoy-gateway.yaml from examples/flux/task-auth, and steward-edge.yaml with
# its dependency on the steward release removed (Steward, cert-manager and the
# exchange need operator inputs and are not installed here). Then it asserts
# that:
#   - both Kustomizations are ready, and every object of each BOM manifest
#     (downloaded and checked against its SHA-256) exists on the cluster,
#     server-side applied by its Kustomization, CRDs with the manifest's
#     versions;
#   - envoy-gateway is ready and runs the BOM controller image;
#   - steward-edge is ready and created Steward's task API HTTPRoute and
#     BackendTLSPolicy.
#
# A new platform version is tagged only when it is released, after its release
# pull request merges. Until the tag of the BOM platformVersion is published,
# steward-edge is built from STEWARD_EDGE_REF instead: a Git reference of this
# repository that holds the chart under test (in GitHub Actions, GITHUB_REF).
#
# Usage: tests/flux/reconcile.sh
# Env:
#   FLUX_INSTALL_MANIFEST  Flux's install.yaml (scripts/ci/install-tools.sh flux-install)
#   STEWARD_EDGE_REF       the reference to build steward-edge from while the
#                          platform tag is unpublished (default: GITHUB_REF)
#   K8S_VERSION            a version from kubernetes.tested (default: the highest)
#   KEEP_CLUSTER           set to 1 to keep the cluster for debugging
# Needs: docker, kind, kubectl, jq, yq (mikefarah v4), curl, git.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bom="${repo_root}/bom/bom.json"
example="${repo_root}/examples/flux/task-auth"
flux_install="${FLUX_INSTALL_MANIFEST:?set FLUX_INSTALL_MANIFEST to Flux install.yaml}"
cluster=steward-flux
context="kind-${cluster}"

for tool in docker kind kubectl jq yq curl git; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

k8s_version="${K8S_VERSION:-$(jq -er '.kubernetes.tested | max_by(.version | split(".") | map(tonumber)) | .version' "${bom}")}"
node_image="$(jq -er --arg v "${k8s_version}" '.kubernetes.tested[] | select(.version == $v) | .nodeImage' "${bom}")" || {
  echo "Kubernetes ${k8s_version} is not in kubernetes.tested" >&2
  exit 2
}

work="$(mktemp -d)"
cluster_created=0
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok   $*"; }
k() { kubectl --context "${context}" "$@"; }
sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

cleanup() {
  local status=$?
  if [[ "${status}" != 0 || "${failures}" != 0 ]] && [[ "${cluster_created}" == 1 ]]; then
    echo "--- Flux objects" >&2
    k get gitrepositories,ocirepositories,helmcharts,kustomizations,helmreleases -A >&2 || true
    k -n flux-system get events --sort-by=.lastTimestamp >&2 || true
    k -n flux-system logs deploy/kustomize-controller --tail=50 >&2 || true
    k -n flux-system logs deploy/helm-controller --tail=50 >&2 || true
  fi
  if [[ "${cluster_created}" == 1 && "${KEEP_CLUSTER:-0}" != 1 ]]; then
    kind delete cluster --name "${cluster}" >/dev/null 2>&1 || true
  fi
  rm -rf "${work}"
}
trap cleanup EXIT

echo "== kind ${k8s_version}, Flux from ${flux_install}"
kind create cluster --name "${cluster}" --image "${node_image}" --wait 120s
cluster_created=1
k apply --server-side -f "${flux_install}" >/dev/null
k -n flux-system wait --for=condition=Available deployment --all --timeout=5m

echo "== apply the task-auth edge objects"
cp "${example}/gateway-api-crds.yaml" "${example}/envoy-gateway-crds.yaml" \
  "${example}/envoy-gateway.yaml" "${work}/"
yq '(select(.kind == "HelmRelease") | .spec.dependsOn) |= map(select(.name != "steward"))' \
  "${example}/steward-edge.yaml" > "${work}/steward-edge.yaml"
platform_tag="$(yq -r 'select(.kind == "GitRepository") | .spec.ref.tag' "${work}/steward-edge.yaml")"
platform_url="$(yq -r 'select(.kind == "GitRepository") | .spec.url' "${work}/steward-edge.yaml")"
edge_source="this repository's platform tag ${platform_tag}"
if ! git ls-remote --exit-code --tags "${platform_url}" "refs/tags/${platform_tag}" >/dev/null 2>&1; then
  edge_ref="${STEWARD_EDGE_REF:-${GITHUB_REF:-}}"
  if [[ -z "${edge_ref}" ]]; then
    echo "tag ${platform_tag} is not published yet; set STEWARD_EDGE_REF to a reference of ${platform_url} that holds this chart" >&2
    exit 2
  fi
  echo "note: tag ${platform_tag} is not published yet; building steward-edge from ${edge_ref} until this platform version is released"
  EDGE_REF="${edge_ref}" yq -i '(select(.kind == "GitRepository") | .spec.ref) = {"name": strenv(EDGE_REF)}' "${work}/steward-edge.yaml"
  edge_source="${edge_ref} (tag ${platform_tag} not published yet)"
fi
k apply --server-side -f "${work}/gateway-api-crds.yaml" -f "${work}/envoy-gateway-crds.yaml" \
  -f "${work}/envoy-gateway.yaml" -f "${work}/steward-edge.yaml"

wait_ready() {
  local kind="$1" name="$2" timeout="$3"
  if k -n flux-system wait --for=condition=Ready "${kind}/${name}" --timeout="${timeout}" >/dev/null; then
    pass "${kind} ${name} is ready"
  else
    fail "${kind} ${name} is not ready after ${timeout}"
  fi
}
wait_ready kustomization gateway-api-crds 5m
wait_ready kustomization envoy-gateway-crds 5m
wait_ready helmrelease envoy-gateway 10m
wait_ready helmrelease steward-edge 5m

# Every object of each BOM manifest, applied by kustomize-controller.
for dependency in gateway-api-crds envoy-gateway; do
  url="$(jq -r --arg d "${dependency}" '.dependencies[$d].manifests[0].url' "${bom}")"
  digest="$(jq -r --arg d "${dependency}" '.dependencies[$d].manifests[0].digest' "${bom}")"
  file="${work}/${dependency}-manifest.yaml"
  curl --fail --silent --show-error --location --retry 3 --output "${file}" "${url}"
  if [[ "sha256:$(sha256_of "${file}")" != "${digest}" ]]; then
    fail "${url} does not match its BOM digest"
    continue
  fi
  count=0
  missing=0
  while IFS=$'\t' read -r kind api_version name versions; do
    count=$((count + 1))
    resource="$(tr "[:upper:]" "[:lower:]" <<<"${kind}").${api_version%/*}"
    if ! live="$(k get "${resource}" "${name}" --show-managed-fields -o json 2>/dev/null)"; then
      fail "${dependency}: ${kind} ${name} is not on the cluster"
      missing=1
      continue
    fi
    if ! jq -e --arg ks "${dependency%-crds}-crds" '.metadata.labels["kustomize.toolkit.fluxcd.io/name"] == $ks
        and ([.metadata.managedFields[].manager] | index("kustomize-controller"))' <<<"${live}" >/dev/null; then
      fail "${dependency}: ${kind} ${name} was not applied by the ${dependency%-crds}-crds Kustomization"
      missing=1
    fi
    if [[ "${kind}" == CustomResourceDefinition && "$(jq -c '[.spec.versions[].name]' <<<"${live}")" != "${versions}" ]]; then
      fail "${dependency}: CRD ${name} serves $(jq -c '[.spec.versions[].name]' <<<"${live}"), the manifest ${versions}"
      missing=1
    fi
  done < <(yq -o=json -I=0 'select(. != null)' "${file}" \
    | jq -r '[.kind, .apiVersion, .metadata.name, ([.spec.versions // [] | .[].name] | tojson)] | @tsv')
  [[ "${missing}" == 0 ]] && pass "${dependency}: all ${count} objects of the BOM manifest applied by the ${dependency%-crds}-crds Kustomization"
done

controller="$(jq -r '.dependencies["envoy-gateway"].images.controller' "${bom}")"
namespace="$(yq -r 'select(.kind == "HelmRelease") | .spec.targetNamespace' "${example}/envoy-gateway.yaml")"
if [[ "$(k -n "${namespace}" get deployment envoy-gateway -o jsonpath='{.spec.template.spec.containers[0].image}')" == "${controller}" ]] \
  && k -n "${namespace}" wait --for=condition=Available deployment/envoy-gateway --timeout=2m >/dev/null; then
  pass "envoy-gateway runs the BOM controller image ${controller}"
else
  fail "envoy-gateway does not run ${controller}"
fi

namespace="$(yq -r 'select(.kind == "HelmRelease") | .spec.targetNamespace' "${example}/steward-edge.yaml")"
if k -n "${namespace}" get httproute steward-task-api >/dev/null && k -n "${namespace}" get backendtlspolicy steward-apiserver >/dev/null; then
  pass "steward-edge, from ${edge_source}, created the task API HTTPRoute and BackendTLSPolicy"
else
  fail "steward-edge did not create its HTTPRoute and BackendTLSPolicy"
fi

if [[ "${failures}" != 0 ]]; then
  echo "${failures} Flux reconcile checks failed" >&2
  exit 1
fi
echo "Flux reconcile checks passed"
