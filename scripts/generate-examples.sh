#!/usr/bin/env bash
# Regenerate the committed Flux examples, examples/flux/<profile>, each from
# its production-shaped platform values and the BOM. With --check, change
# nothing and fail if the committed files differ from a fresh generation.
#
#   examples/flux/core           environments/production
#   examples/flux/task-auth      environments/production-task-auth
#   examples/flux/browser-admin  environments/production-browser-admin
#
# Usage: scripts/generate-examples.sh [--check]
# Needs: what scripts/generate.sh needs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
examples=(
  "core production"
  "task-auth production-task-auth"
  "browser-admin production-browser-admin"
)
check=0
case "${1:-}" in
  --check) check=1 ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
stale=0
for entry in "${examples[@]}"; do
  read -r name environment <<<"${entry}"
  source_values="${repo_root}/environments/${environment}/platform-values.yaml"
  example="${repo_root}/examples/flux/${name}"
  "${repo_root}/scripts/generate.sh" --out "${work}/${name}" "${source_values}" >/dev/null
  [[ -d "${work}/${name}/flux" ]] || { echo "the generator emitted no Flux output for ${source_values}" >&2; exit 1; }
  if [[ "$(yq -r .profile "${source_values}")" != "${name}" ]]; then
    echo "${source_values} is not the ${name} profile" >&2
    exit 1
  fi

  if [[ "${check}" == 1 ]]; then
    # Compare the generated YAML files only; README.md is hand-written.
    if diff -r -x README.md "${work}/${name}/flux" "${example}"; then
      echo "ok: examples/flux/${name} matches a fresh generation"
    else
      echo "examples/flux/${name} is stale; run scripts/generate-examples.sh and commit the result" >&2
      stale=1
    fi
    continue
  fi

  mkdir -p "${example}"
  find "${example}" -maxdepth 1 -type f -name '*.yaml' -delete
  cp "${work}/${name}/flux/"*.yaml "${example}/"
  echo "regenerated examples/flux/${name}"
done
exit "${stale}"
