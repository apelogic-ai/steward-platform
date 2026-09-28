# shellcheck shell=bash
# Helpers for the registry mirror checks of tests/generate/run.sh and
# tests/flux/run.sh. Source it after setting bom to the BOM path.
# Needs: jq, yq (mikefarah v4), helm.
# shellcheck disable=SC2154 # bom is set by the sourcing script.

# A BOM reference as the platform values' registry block mirrors it, computed
# here independently of the generator: the class's prefix replaces the
# registry or host, or with keepSourceHost precedes it; the tag and digest
# stay. A Git repository listed in registry.gitSources.repositories maps to
# its entry. Unchanged when the class is not mirrored.
#   mirrored VALUES CLASS REFERENCE   (host/path..., oci://host/path... or https://host/path...)
mirrored() {
  local values="$1" class="$2" ref="$3" prefix keep exact scheme=""
  if [[ "${class}" == gitSources ]]; then
    exact="$(yq -r ".registry.gitSources.repositories[\"${ref}\"] // \"\"" "${values}")"
    if [[ -n "${exact}" ]]; then echo "${exact}"; return; fi
  fi
  prefix="$(yq -r ".registry.${class}.prefix // \"\"" "${values}")"
  if [[ -z "${prefix}" ]]; then echo "${ref}"; return; fi
  keep="$(yq -r ".registry.${class}.keepSourceHost // false" "${values}")"
  case "${ref}" in
    oci://*) scheme=oci://; ref="${ref#oci://}" ;;
    https://*) ref="${ref#https://}" ;;
  esac
  if [[ "${keep}" == true ]]; then echo "${scheme}${prefix}/${ref}"; else echo "${scheme}${prefix}/${ref#*/}"; fi
}

# Every BOM image, tested dependency versions included, mirrored for VALUES,
# one per line.
mirrored_bom_images() {
  local ref
  while IFS= read -r ref; do mirrored "$1" productImages "${ref}"; done < <(jq -r '.products[].images[]' "${bom}")
  while IFS= read -r ref; do mirrored "$1" dependencyImages "${ref}"; done \
    < <(jq -r '.dependencies[] | (.images // {} | .[]), ((.tested // [])[] | .images[])' "${bom}" | sort -u)
}

# The container images of the workloads in rendered manifests:
# name <TAB> image <TAB> the image pull secrets of the pod and of its
# ServiceAccount (some charts, cert-manager among them, put them there),
# sorted and comma-separated.
workload_images() {
  yq -o=json -I=0 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet"
      or .kind == "Job" or .kind == "ServiceAccount")' "$@" \
    | jq -rs '(map(select(.kind == "ServiceAccount") | {(.metadata.name): [.imagePullSecrets // [] | .[].name]}) | add // {}) as $accounts
        | .[] | select(.kind != "ServiceAccount")
        | .metadata.name as $n | .spec.template.spec as $s
        | ([$s.imagePullSecrets // [] | .[].name] + ($accounts[$s.serviceAccountName // "default"] // []) | unique | join(",")) as $pulls
        | (($s.initContainers // []) + $s.containers)[]
        | [$n, .image, $pulls] | @tsv'
}

# helmfile pulls every OCI chart into its cache before it renders anything,
# even for `helmfile build`, and the mirror of a committed example environment
# is a placeholder. Seed a private cache (HELMFILE_CACHE_HOME) with each chart
# the generated helmfile inputs name, pulled from upstream at the same BOM
# digest, at the path helmfile derives from the mirror reference (pkg/state
# getOCIChartPath in the helmfile pinned in scripts/ci/install-tools.sh), so
# that helmfile renders it without pulling.
#   seed_helmfile_cache CACHE_DIR GENERATED_HELMFILE_YAML
seed_helmfile_cache() {
  local cache="$1" chart digest reference tmp archive
  while IFS= read -r chart; do
    digest="${chart##*@}"
    reference="$(jq -r --arg d "${digest}" '[.products[], .dependencies[] | .chart // empty
      | select(.digest == $d) | .reference][0] // ""' "${bom}")"
    [[ -n "${reference}" ]] || { echo "no BOM chart has digest ${digest}" >&2; return 1; }
    tmp="$(mktemp -d)"
    if ! helm pull "${reference}@${digest}" --destination "${tmp}" >/dev/null 2>&1; then
      rm -rf "${tmp}"
      echo "cannot pull ${reference}@${digest}" >&2
      return 1
    fi
    archive="$(find "${tmp}" -maxdepth 1 -name '*.tgz' -print -quit)"
    mkdir -p "${cache}/$(sed -e 's/[:.&]/_/g' -e 's|//|_|g' <<<"${chart}")"
    tar -xzf "${archive}" -C "${cache}/$(sed -e 's/[:.&]/_/g' -e 's|//|_|g' <<<"${chart}")"
    rm -rf "${tmp}"
  done < <(yq -r '.releases[] | select(.chart) | .chart' "$2")
}
