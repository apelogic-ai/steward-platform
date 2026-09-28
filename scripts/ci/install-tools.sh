#!/usr/bin/env bash
# Install pinned CI tools into a directory and put it on the GitHub Actions PATH.
# Each download is checked against a pinned SHA-256. Linux amd64 only.
#
# Usage: scripts/ci/install-tools.sh TOOL...
#        TOOL: cosign, crane, flux-install, flux-schemas, helm, helmfile, kind,
#              kubeconform, kubectl, yq
#        flux-schemas is Flux's CRD JSON schemas for kubeconform, extracted into
#        FLUX_SCHEMAS_DIR (also exported to later GitHub Actions steps).
#        flux-install is Flux's install manifest, saved as FLUX_INSTALL_MANIFEST
#        (also exported).
# Env:   TOOLS_DIR (default: ${RUNNER_TEMP}/tools/bin)
#        FLUX_SCHEMAS_DIR (default: TOOLS_DIR/../flux-crd-schemas)
#        FLUX_INSTALL_MANIFEST (default: TOOLS_DIR/../flux-install.yaml)
set -euo pipefail

cosign_version=v3.1.3
cosign_sha256=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
crane_version=v0.22.1
crane_sha256=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
# The Flux release whose CRD schemas validate examples/flux, and whose
# controllers reconcile them in tests/flux/reconcile.sh.
flux_version=v2.9.5
flux_schemas_sha256=3c6c976df251e5a7e8c1c6a0ee63e6c28026d568b14ffa2f13cc32a6a564f238
flux_install_sha256=cc3dcd743af16215838b6937e1fce83745bf24c0dcc6c59737c59df15429caaf
helm_version=v3.22.0
helm_sha256=1e4ab49e429626cf6c6958d914248b78c9730803c2751b87627e171dc800e7bb
helmfile_version=v1.8.0
helmfile_sha256=35d5d39fc608342b23fc7ce1dd0c3bf0c96cc07ec3796507ab6894a5d172bf20
kind_version=v0.31.0
kind_sha256=eb244cbafcc157dff60cf68693c14c9a75c4e6e6fedaf9cd71c58117cb93e3fa
kubeconform_version=v0.8.0
kubeconform_sha256=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
# Matches the highest tested Kubernetes minor in the BOM.
kubectl_version=v1.34.3
kubectl_sha256=ab60ca5f0fd60c1eb81b52909e67060e3ba0bd27e55a8ac147cbc2172ff14212
yq_version=v4.53.6
yq_sha256=c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385

if [[ "$(uname -s)/$(uname -m)" != Linux/x86_64 ]]; then
  echo "install-tools.sh supports Linux x86_64 only" >&2
  exit 2
fi
if [[ "$#" == 0 ]]; then
  echo "usage: $0 TOOL..." >&2
  exit 2
fi

tools_dir="${TOOLS_DIR:-${RUNNER_TEMP:?RUNNER_TEMP or TOOLS_DIR is required}/tools/bin}"
mkdir -p "${tools_dir}"
flux_schemas_dir="${FLUX_SCHEMAS_DIR:-${tools_dir%/}/../flux-crd-schemas}"
flux_install_manifest="${FLUX_INSTALL_MANIFEST:-${tools_dir%/}/../flux-install.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fetch() {
  local url="$1" sha256="$2" out="$3"
  curl --fail --silent --show-error --location --retry 3 --output "${out}" "${url}"
  echo "${sha256}  ${out}" | sha256sum --check --quiet
}

for tool in "$@"; do
  case "${tool}" in
    cosign)
      fetch "https://github.com/sigstore/cosign/releases/download/${cosign_version}/cosign-linux-amd64" \
        "${cosign_sha256}" "${work}/cosign"
      install -m 0755 "${work}/cosign" "${tools_dir}/cosign"
      ;;
    crane)
      fetch "https://github.com/google/go-containerregistry/releases/download/${crane_version}/go-containerregistry_Linux_x86_64.tar.gz" \
        "${crane_sha256}" "${work}/crane.tar.gz"
      tar -xzf "${work}/crane.tar.gz" -C "${work}" crane
      install -m 0755 "${work}/crane" "${tools_dir}/crane"
      ;;
    helm)
      fetch "https://get.helm.sh/helm-${helm_version}-linux-amd64.tar.gz" \
        "${helm_sha256}" "${work}/helm.tar.gz"
      tar -xzf "${work}/helm.tar.gz" -C "${work}" linux-amd64/helm
      install -m 0755 "${work}/linux-amd64/helm" "${tools_dir}/helm"
      ;;
    helmfile)
      fetch "https://github.com/helmfile/helmfile/releases/download/${helmfile_version}/helmfile_${helmfile_version#v}_linux_amd64.tar.gz" \
        "${helmfile_sha256}" "${work}/helmfile.tar.gz"
      tar -xzf "${work}/helmfile.tar.gz" -C "${work}" helmfile
      install -m 0755 "${work}/helmfile" "${tools_dir}/helmfile"
      ;;
    flux-install)
      fetch "https://github.com/fluxcd/flux2/releases/download/${flux_version}/install.yaml" \
        "${flux_install_sha256}" "${work}/install.yaml"
      mkdir -p "$(dirname "${flux_install_manifest}")"
      install -m 0644 "${work}/install.yaml" "${flux_install_manifest}"
      if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "FLUX_INSTALL_MANIFEST=$(cd "$(dirname "${flux_install_manifest}")" && pwd)/$(basename "${flux_install_manifest}")" >> "${GITHUB_ENV}"
      fi
      ;;
    flux-schemas)
      fetch "https://github.com/fluxcd/flux2/releases/download/${flux_version}/crd-schemas.tar.gz" \
        "${flux_schemas_sha256}" "${work}/crd-schemas.tar.gz"
      mkdir -p "${flux_schemas_dir}"
      tar -xzf "${work}/crd-schemas.tar.gz" -C "${flux_schemas_dir}"
      if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "FLUX_SCHEMAS_DIR=$(cd "${flux_schemas_dir}" && pwd)" >> "${GITHUB_ENV}"
      fi
      ;;
    kind)
      fetch "https://github.com/kubernetes-sigs/kind/releases/download/${kind_version}/kind-linux-amd64" \
        "${kind_sha256}" "${work}/kind"
      install -m 0755 "${work}/kind" "${tools_dir}/kind"
      ;;
    kubeconform)
      fetch "https://github.com/yannh/kubeconform/releases/download/${kubeconform_version}/kubeconform-linux-amd64.tar.gz" \
        "${kubeconform_sha256}" "${work}/kubeconform.tar.gz"
      tar -xzf "${work}/kubeconform.tar.gz" -C "${work}" kubeconform
      install -m 0755 "${work}/kubeconform" "${tools_dir}/kubeconform"
      ;;
    kubectl)
      fetch "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl" \
        "${kubectl_sha256}" "${work}/kubectl"
      install -m 0755 "${work}/kubectl" "${tools_dir}/kubectl"
      ;;
    yq)
      fetch "https://github.com/mikefarah/yq/releases/download/${yq_version}/yq_linux_amd64" \
        "${yq_sha256}" "${work}/yq"
      install -m 0755 "${work}/yq" "${tools_dir}/yq"
      ;;
    *)
      echo "unknown tool ${tool}" >&2
      exit 2
      ;;
  esac
  echo "installed ${tool}"
done

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${tools_dir}" >> "${GITHUB_PATH}"
fi
