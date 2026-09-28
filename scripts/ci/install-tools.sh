#!/usr/bin/env bash
# Install pinned CI tools into a directory and put it on the GitHub Actions PATH.
# Each download is checked against a pinned SHA-256. Linux amd64 only.
#
# Usage: scripts/ci/install-tools.sh TOOL...   (TOOL: crane, helm, helmfile, kind, kubectl, yq)
# Env:   TOOLS_DIR (default: ${RUNNER_TEMP}/tools/bin)
set -euo pipefail

crane_version=v0.22.1
crane_sha256=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
helm_version=v3.22.0
helm_sha256=1e4ab49e429626cf6c6958d914248b78c9730803c2751b87627e171dc800e7bb
helmfile_version=v1.8.0
helmfile_sha256=35d5d39fc608342b23fc7ce1dd0c3bf0c96cc07ec3796507ab6894a5d172bf20
kind_version=v0.31.0
kind_sha256=eb244cbafcc157dff60cf68693c14c9a75c4e6e6fedaf9cd71c58117cb93e3fa
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
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fetch() {
  local url="$1" sha256="$2" out="$3"
  curl --fail --silent --show-error --location --retry 3 --output "${out}" "${url}"
  echo "${sha256}  ${out}" | sha256sum --check --quiet
}

for tool in "$@"; do
  case "${tool}" in
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
    kind)
      fetch "https://github.com/kubernetes-sigs/kind/releases/download/${kind_version}/kind-linux-amd64" \
        "${kind_sha256}" "${work}/kind"
      install -m 0755 "${work}/kind" "${tools_dir}/kind"
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
