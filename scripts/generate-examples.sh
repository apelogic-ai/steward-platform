#!/usr/bin/env bash
# Regenerate the committed Flux example, examples/flux/core, from the
# production-shaped platform values and the BOM. With --check, change nothing
# and fail if the committed files differ from a fresh generation.
#
# Usage: scripts/generate-examples.sh [--check]
# Needs: what scripts/generate.sh needs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_values="${repo_root}/environments/production/platform-values.yaml"
example="${repo_root}/examples/flux/core"
check=0
case "${1:-}" in
  --check) check=1 ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
"${repo_root}/scripts/generate.sh" --out "${work}/out" "${source_values}" >/dev/null
[[ -d "${work}/out/flux" ]] || { echo "the generator emitted no Flux output for ${source_values}" >&2; exit 1; }

if [[ "${check}" == 1 ]]; then
  # Compare the generated YAML files only; README.md is hand-written.
  if diff -r -x README.md "${work}/out/flux" "${example}"; then
    echo "ok: examples/flux/core matches a fresh generation"
  else
    echo "examples/flux/core is stale; run scripts/generate-examples.sh and commit the result" >&2
    exit 1
  fi
  exit 0
fi

mkdir -p "${example}"
find "${example}" -maxdepth 1 -type f -name '*.yaml' -delete
cp "${work}/out/flux/"*.yaml "${example}/"
echo "regenerated examples/flux/core"
