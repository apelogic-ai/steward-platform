#!/usr/bin/env bash
# Build github-oidc-exchange's keyring-tool from the product source at the BOM
# commit. The released image does not ship it
# (apelogic-ai/github-oidc-exchange#55), and the task-auth end-to-end test
# needs it to create the exchange's ES256 keyring and export its public JWKS,
# as the product's own guides do (`cargo run --locked --bin keyring-tool`).
#
# Reproducible inputs: the source at the pinned commit (checked against the
# release tag), the product's rust-toolchain.toml (rustup installs exactly that
# toolchain), and its Cargo.lock (--locked).
#
# Usage: scripts/ci/build-keyring-tool.sh OUTPUT_PATH
# Needs: git, jq, rustup and cargo.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bom="${BOM:-${repo_root}/bom/bom.json}"
output="${1:?usage: $0 OUTPUT_PATH}"

for tool in git jq rustup cargo; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

source_url="$(jq -er '.products["github-oidc-exchange"].source' "${bom}")"
commit="$(jq -er '.products["github-oidc-exchange"].commit' "${bom}")"
tag="$(jq -er '.products["github-oidc-exchange"].release | split("/releases/tag/")[1]' "${bom}")"

tagged="$(git ls-remote --tags "${source_url}" "refs/tags/${tag}" "refs/tags/${tag}^{}" | awk '{print $1}' | tail -1)"
if [[ "${tagged}" != "${commit}" ]]; then
  echo "tag ${tag} of ${source_url} is ${tagged:-missing}, BOM pins ${commit}" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
git -C "${work}" init --quiet
git -C "${work}" fetch --quiet --depth 1 "${source_url}" "${commit}"
git -C "${work}" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
[[ "$(git -C "${work}" rev-parse HEAD)" == "${commit}" ]] || { echo "checkout is not ${commit}" >&2; exit 1; }

# rust-toolchain.toml selects the exact toolchain; show it and install it.
(cd "${work}" && rustup toolchain install && rustup show active-toolchain)
(cd "${work}" && cargo build --quiet --locked --release --bin keyring-tool)

mkdir -p "$(dirname "${output}")"
install -m 0755 "${work}/target/release/keyring-tool" "${output}"
echo "built keyring-tool from ${source_url} at ${commit} (${tag}) into ${output}"
