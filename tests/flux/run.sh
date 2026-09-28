#!/usr/bin/env bash
# Checks for the Flux examples, examples/flux/<profile>. No cluster needed.
#
# For each example (core, task-auth, browser-admin, and mirrored: task-auth
# from a registry mirror):
#   - the committed files match a fresh generation from the BOM, so they cannot
#     drift from it;
#   - every object validates against the Flux CRD schemas (kubeconform, strict),
#     and kustomization.yaml lists every file;
#   - the HelmReleases are the helmfile's releases for the same environment,
#     each dependsOn is exactly that release's helmfile needs, and each
#     HelmRelease carries exactly the generated values the helmfile installs;
#   - each OCIRepository points at its BOM chart and pins only its BOM digest,
#     and each chart, pulled at that digest, renders with the HelmRelease
#     values and uses the BOM image digests;
#   - with a registry mirror in the platform values, every source (each
#     OCIRepository and GitRepository) and every workload image points at the
#     mirror, with its BOM digest or commit unchanged, and each source carries
#     its class's credentials by reference (secretRef, provider, certSecretRef);
#   - Steward's CRD is created on install and skipped on upgrade;
#   - where the helmfile's presync hook server-side applies BOM manifests, a
#     Flux Kustomization applies each, in the same order, from the manifest's
#     BOM fluxSource; that source, at its pin, holds exactly the objects of
#     the manifest, downloaded and checked against its BOM SHA-256; the
#     releases that need those CRDs retry instead of remediating, and
#     envoy-gateway never manages CRDs;
#   - charts/steward-edge comes from this repository at the tag of the
#     platform version, and the chart at that tag is this checkout's.
#
# Usage: tests/flux/run.sh
# Env:   FLUX_SCHEMAS_DIR  directory holding Flux's crd-schemas.tar.gz contents
#                          (scripts/ci/install-tools.sh flux-schemas)
# Needs: kubeconform, helm, helmfile, git, curl, jq, yq (mikefarah v4), and what
#        scripts/generate.sh needs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bom="${repo_root}/bom/bom.json"
schemas="${FLUX_SCHEMAS_DIR:?set FLUX_SCHEMAS_DIR to the extracted Flux crd-schemas}"
# example <space> environment it is generated from
examples=(
  "core production"
  "task-auth production-task-auth"
  "browser-admin production-browser-admin"
  "mirrored production-mirrored"
)

for tool in kubeconform helm helmfile git curl jq yq; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done
[[ -f "${schemas}/helmrelease-helm-v2.json" ]] || { echo "no Flux CRD schemas in ${schemas}" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export DOCKER_CONFIG="${work}/docker"
mkdir -p "${DOCKER_CONFIG}"
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok   $*"; }
# shellcheck source=tests/lib/mirror.sh
. "${repo_root}/tests/lib/mirror.sh"

# The Flux access fields a source of CLASS must carry: the class's flux
# settings in the platform values, as spec fields.
expected_access() { yq -o=json -I=0 ".registry.$2.flux // {}" "$1" | jq -cS .; }
actual_access() { jq -cS '.spec | {secretRef, provider, certSecretRef} | with_entries(select(.value != null))'; }
sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
# The objects of YAML files, one sorted canonical JSON line each.
objects_of() {
  yq -o=json -I=0 'select(. != null)' "$@" | jq -cS . | sort
}

if "${repo_root}/scripts/generate-examples.sh" --check; then
  pass "the Flux examples are generated from the BOM and up to date"
else
  fail "a Flux example is stale"
fi

# BOM charts by HelmRelease name: BOM entry <TAB> image components it deploys.
bom_chart() {
  case "$1" in
    steward) printf '%s\t%s\n' '.products.steward' '.apiserver, .controller' ;;
    cert-manager) printf '%s\t%s\n' '.dependencies["cert-manager"]' '.controller, .webhook, .cainjector, .startupapicheck' ;;
    envoy-gateway) printf '%s\t%s\n' '.dependencies["envoy-gateway"]' '.controller, .proxy' ;;
    github-oidc-exchange) printf '%s\t%s\n' '.products["github-oidc-exchange"]' '.exchange' ;;
    *) return 1 ;;
  esac
}

# A BOM chart pulled at its digest, once.
pull_chart() {
  local reference="$1" digest="$2" dir="${work}/charts/${2#sha256:}"
  if [[ ! -d "${dir}" ]]; then
    mkdir -p "${dir}"
    helm pull "${reference}@${digest}" --destination "${dir}" >/dev/null 2>&1 || return 1
  fi
  find "${dir}" -maxdepth 1 -name '*.tgz' -print -quit
}

# The objects of a BOM manifest, downloaded and checked against its digest,
# once per dependency.
manifest_objects() {
  local dependency="$1" out="${work}/manifests/$1.objects"
  if [[ ! -f "${out}" ]]; then
    local url digest file
    url="$(jq -r --arg d "${dependency}" '.dependencies[$d].manifests[0].url' "${bom}")"
    digest="$(jq -r --arg d "${dependency}" '.dependencies[$d].manifests[0].digest' "${bom}")"
    file="${work}/manifests/${dependency}.yaml"
    mkdir -p "${work}/manifests"
    curl --fail --silent --show-error --location --retry 3 --output "${file}" "${url}" || return 1
    [[ "sha256:$(sha256_of "${file}")" == "${digest}" ]] || { echo "${url} does not match ${digest}" >&2; return 1; }
    objects_of "${file}" > "${out}"
  fi
  cat "${out}"
}

# The objects Flux applies from a directory: every YAML file below it.
directory_objects() {
  local files=()
  while IFS= read -r file; do files+=("${file}"); done \
    < <(find "$1" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
  [[ "${#files[@]}" -gt 0 ]] || return 1
  objects_of "${files[@]}"
}

check_example() {
  local name="$1" environment="$2" example="${repo_root}/examples/flux/$1"
  local objects="${work}/${name}-objects.json"
  local values="${repo_root}/environments/${environment}/platform-values.yaml"

  local manifests=()
  while IFS= read -r manifest; do manifests+=("${manifest}"); done \
    < <(find "${example}" -maxdepth 1 -name '*.yaml' ! -name kustomization.yaml | sort)
  if kubeconform -strict -summary \
    -schema-location "${schemas}/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
    "${manifests[@]}"; then
    pass "${name}: manifests validate against the Flux CRD schemas"
  else
    fail "${name}: manifests do not validate against the Flux CRD schemas"
  fi

  # Every YAML file listed in kustomization.yaml, and nothing else.
  local listed present
  listed="$(yq -r '.resources[]' "${example}/kustomization.yaml" | sort)"
  present="$(for m in "${manifests[@]}"; do basename "${m}"; done | sort)"
  if [[ "${listed}" == "${present}" ]]; then
    pass "${name}: kustomization.yaml lists every manifest"
  else
    fail "${name}: kustomization.yaml lists [${listed//$'\n'/ }], directory has [${present//$'\n'/ }]"
  fi

  yq -o=json '.' "${manifests[@]}" | jq -s '[.[] | select(. != null)]' > "${objects}"
  object() { jq -c --arg k "$1" --arg n "$2" '[.[] | select(.kind == $k and .metadata.name == $n)] | if length == 1 then .[0] else null end' "${objects}"; }

  # With a registry mirror for every class, every source is in a mirror.
  if [[ "$(yq -r 'has("registry")' "${values}")" == true ]]; then
    local prefixes outside
    prefixes="$(yq -o=json '.registry' "${values}" | jq -c '[(.productCharts.prefix, .dependencyCharts.prefix) // empty | "oci://\(.)/"]
      + [.gitSources.prefix // empty | "\(.)/"] + [.gitSources.repositories // {} | .[]]')"
    outside="$(jq -r --argjson p "${prefixes}" '.[] | select(.kind == "OCIRepository" or .kind == "GitRepository")
      | select(.spec.url as $u | any($p[]; . as $prefix | $u | startswith($prefix)) | not) | "\(.kind)/\(.metadata.name) \(.spec.url)"' "${objects}")"
    if [[ -z "${outside}" ]]; then
      pass "${name}: every OCIRepository and GitRepository points at the mirror"
    else
      fail "${name}: sources outside the mirror: ${outside//$'\n'/, }"
    fi
  fi

  # The helmfile for the same environment, from the same generated values.
  local generated="${work}/generated" helmfile_out="${work}/${name}-helmfile.yaml"
  "${repo_root}/scripts/generate.sh" --out "${generated}/${environment}" \
    "${repo_root}/environments/${environment}/platform-values.yaml" >/dev/null
  local helmfile_env=("PLATFORM_GENERATED_DIR=${generated}")
  if [[ "$(yq -r 'has("registry")' "${values}")" == true ]]; then
    seed_helmfile_cache "${work}/helmfile-cache-${name}" "${generated}/${environment}/helmfile.yaml"
    helmfile_env+=("HELMFILE_CACHE_HOME=${work}/helmfile-cache-${name}")
  fi
  if ! env "${helmfile_env[@]}" helmfile --file "${repo_root}/helmfile/helmfile.yaml.gotmpl" \
    --environment "${environment}" build > "${helmfile_out}" 2>"${work}/helmfile.log"; then
    cat "${work}/helmfile.log" >&2
    fail "${name}: helmfile build failed"
    return
  fi
  local releases="${work}/${name}-releases.json"
  yq -o=json 'select(.releases) | .releases' "${helmfile_out}" > "${releases}"

  local flux_names helmfile_names
  flux_names="$(jq -r '.[] | select(.kind == "HelmRelease") | .metadata.name' "${objects}" | sort | tr '\n' ' ')"
  helmfile_names="$(jq -r '.[].name' "${releases}" | sort | tr '\n' ' ')"
  if [[ "${flux_names}" == "${helmfile_names}" ]]; then
    pass "${name}: HelmReleases are the helmfile releases (${flux_names% })"
  else
    fail "${name}: HelmReleases [${flux_names% }], helmfile releases [${helmfile_names% }]"
  fi

  # Kustomizations that apply CRDs, from the helmfile's presync hook.
  local hook_dependencies
  hook_dependencies="$(jq -r '.[] | .hooks // [] | .[]
    | select((.events | index("presync")) and .command == "../scripts/apply-manifests.sh")
    | .args | . as $a
    | [range(0; length) | select(($a[.] | IN("--context", "--url") | not) and (. == 0 or ($a[. - 1] | IN("--context", "--url") | not))) | $a[.]]
    | .[]' "${releases}")"
  local crd_kustomizations=0

  local release
  for release in ${flux_names}; do
    local hr expected_needs actual_needs
    hr="$(object HelmRelease "${release}")"
    actual_needs="$(jq -r '[.spec.dependsOn // [] | .[].name] | sort | join(" ")' <<<"${hr}")"
    expected_needs="$(jq -r --arg r "${release}" '.[] | select(.name == $r) | [.needs // [] | .[] | split("/") | last] | sort | join(" ")' "${releases}")"
    if [[ "${actual_needs}" == "${expected_needs}" ]]; then
      pass "${name}: ${release} dependsOn [${actual_needs}], the helmfile needs"
    else
      fail "${name}: ${release} dependsOn [${actual_needs}], helmfile needs [${expected_needs}]"
    fi

    local values_file="${generated}/${environment}/values/${release}.yaml"
    if [[ -f "${values_file}" ]] \
      && [[ "$(jq -S '.spec.values' <<<"${hr}")" == "$(yq -o=json '.' "${values_file}" | jq -S .)" ]] \
      && [[ "$(jq -r --arg r "${release}" '.[] | select(.name == $r) | .values | map(split("/") | last) | join(" ")' "${releases}")" == "${release}.yaml" ]]; then
      pass "${name}: ${release} values are the helmfile's values/${release}.yaml"
    else
      fail "${name}: ${release} values differ from the helmfile's values/${release}.yaml"
    fi
    local namespace
    namespace="$(jq -r --arg r "${release}" '.[] | select(.name == $r) | .namespace' "${releases}")"
    if jq -e --arg ns "${namespace}" '.spec.targetNamespace == $ns and .spec.storageNamespace == $ns' <<<"${hr}" >/dev/null; then
      pass "${name}: ${release} installs into ${namespace}, as the helmfile does"
    else
      fail "${name}: ${release} does not install into the helmfile namespace ${namespace}"
    fi

    local chart_info bom_path components archive rendered="${work}/${name}-${release}-rendered.yaml"
    if chart_info="$(bom_chart "${release}")"; then
      IFS=$'\t' read -r bom_path components <<<"${chart_info}"
      local reference digest repository chart_class image_class url
      reference="$(jq -r "${bom_path}.chart.reference" "${bom}")"
      digest="$(jq -r "${bom_path}.chart.digest" "${bom}")"
      repository="$(object OCIRepository "${release}")"
      if [[ "${bom_path}" == .products* ]]; then chart_class=productCharts image_class=productImages
      else chart_class=dependencyCharts image_class=dependencyImages; fi
      url="$(mirrored "${values}" "${chart_class}" "${reference}")"
      if jq -e --arg url "${url}" --arg digest "${digest}" \
        '.spec.url == $url and .spec.ref == {digest: $digest} and .spec.layerSelector.operation == "copy"' \
        <<<"${repository}" >/dev/null \
        && [[ "$(actual_access <<<"${repository}")" == "$(expected_access "${values}" "${chart_class}")" ]]; then
        pass "${name}: ${release} OCIRepository pins ${url}@${digest}$([[ "${url}" != "${reference}" ]] && echo ", the BOM chart from the mirror")"
      else
        fail "${name}: ${release} OCIRepository does not pin the BOM chart ${url}@${digest} with the ${chart_class} access settings"
      fi
      if jq -e --arg n "${release}" '.spec.chartRef == {kind: "OCIRepository", name: $n} and (.spec | has("chart") | not)' <<<"${hr}" >/dev/null; then
        pass "${name}: ${release} HelmRelease uses that OCIRepository"
      else
        fail "${name}: ${release} HelmRelease does not use the ${release} OCIRepository"
      fi
      archive="$(pull_chart "${reference}" "${digest}")" || { fail "${name}: cannot pull ${reference}@${digest}"; continue; }
      [[ "$(jq -r '.spec.values.web.enabled // false' <<<"${hr}")" == true ]] && components+=", .web"
    elif [[ "${release}" == steward-edge ]]; then
      check_steward_edge "${name}" "${values}" "${hr}" "$(object GitRepository steward-platform)"
      archive="${repo_root}/charts/steward-edge"
      components=""
    else
      fail "${name}: ${release} is neither a BOM chart nor charts/steward-edge"
      continue
    fi

    jq '.spec.values' <<<"${hr}" > "${work}/values.json"
    if ! helm template "${release}" "${archive}" --namespace "${namespace}" \
      -f "${work}/values.json" > "${rendered}" 2>"${work}/template.log"; then
      cat "${work}/template.log" >&2
      fail "${name}: ${release} HelmRelease values do not render with the chart"
      continue
    fi
    local missing=0 ref
    if [[ -n "${components}" ]]; then
      while IFS= read -r ref; do
        ref="$(mirrored "${values}" "${image_class}" "${ref}")"
        grep -Fq -- "${ref}" "${rendered}" || { fail "${name}: ${release} does not render BOM image ${ref}"; missing=1; }
      done < <(jq -r "${bom_path}.images | ${components}" "${bom}")
    fi
    [[ "${missing}" == 0 ]] && pass "${name}: ${release} renders with the chart${components:+ and the BOM image digests}"
    # With a mirror, nothing the release runs comes from anywhere else.
    if [[ "$(yq -r 'has("registry")' "${values}")" == true && -n "${components}" ]]; then
      local expected_images workload image count=0 bad=0
      expected_images="$(mirrored_bom_images "${values}")"
      while IFS=$'\t' read -r workload image _; do
        count=$((count + 1))
        grep -Fxq -- "${image}" <<<"${expected_images}" \
          || { fail "${name}: ${release} ${workload} runs ${image}, not a BOM image from the mirror"; bad=1; }
      done < <(workload_images "${rendered}")
      [[ "${bad}" == 0 ]] && pass "${name}: ${release} runs only BOM images from the mirror (${count} containers)"
    fi

    # Releases that create Gateway API objects, or the controller that needs
    # the CRDs, retry while the CRD Kustomizations apply them.
    if [[ -n "${hook_dependencies}" ]] \
      && { [[ "${release}" == envoy-gateway ]] || grep -q '^apiVersion: gateway.networking.k8s.io/' "${rendered}"; }; then
      if jq -e '.spec.install.strategy.name == "RetryOnFailure" and .spec.upgrade.strategy.name == "RetryOnFailure"' <<<"${hr}" >/dev/null; then
        pass "${name}: ${release} needs the edge CRDs and retries until they are applied"
      else
        fail "${name}: ${release} needs the edge CRDs, which Flux cannot order it after, but does not retry"
      fi
    fi
  done

  # Steward's CRD: Helm's behaviour, created on install, never on upgrade.
  if jq -e '.spec.install.crds == "Create" and .spec.upgrade.crds == "Skip"' <<<"$(object HelmRelease steward)" >/dev/null; then
    pass "${name}: Steward's CRD is created on install and skipped on upgrade"
  else
    fail "${name}: Steward's HelmRelease must keep install.crds Create and upgrade.crds Skip"
  fi

  # The presync hook's manifests, in hook order, each as a Kustomization.
  local previous="" dependency
  for dependency in ${hook_dependencies}; do
    crd_kustomizations=$((crd_kustomizations + 1))
    check_manifest_kustomization "${name}" "${values}" "${dependency}" "${previous}" \
      "$(object Kustomization "${dependency%-crds}-crds")" \
      "$(object GitRepository "${dependency%-crds}-crds")" \
      "$(object OCIRepository "${dependency%-crds}-crds")"
    previous="${dependency%-crds}-crds"
  done
  local all_kustomizations
  all_kustomizations="$(jq '[.[] | select(.kind == "Kustomization")] | length' "${objects}")"
  if [[ "${all_kustomizations}" == "${crd_kustomizations}" ]]; then
    pass "${name}: ${all_kustomizations} Kustomizations, one per manifest the helmfile hook applies"
  else
    fail "${name}: ${all_kustomizations} Kustomizations, but the helmfile hook applies ${crd_kustomizations} manifests"
  fi
  if [[ -n "${hook_dependencies}" ]]; then
    if jq -e '.spec.install.crds == "Skip" and .spec.upgrade.crds == "Skip"' <<<"$(object HelmRelease envoy-gateway)" >/dev/null; then
      pass "${name}: envoy-gateway leaves its CRDs to the Kustomizations"
    else
      fail "${name}: envoy-gateway must skip CRDs on install and upgrade"
    fi
  fi
}

# One BOM manifest as a Kustomization over its fluxSource.
check_manifest_kustomization() {
  local name="$1" values="$2" dependency="$3" previous="$4" kustomization="$5" git="$6" oci="$7"
  local label="${name}: ${dependency} CRDs" source path dir="${work}/sources/${dependency}"
  source="$(jq -c --arg d "${dependency}" '.dependencies[$d].manifests | if length == 1 then .[0].fluxSource else null end' "${bom}")"
  if [[ "${kustomization}" == null || "${source}" == null ]]; then
    fail "${label}: no Kustomization, or the BOM pins no single manifest with a fluxSource"
    return
  fi
  if jq -e --arg prev "${previous}" '.spec.prune == false and .spec.wait == true
      and (.spec.dependsOn // [] | map(.name)) == (if $prev == "" then [] else [$prev] end)' <<<"${kustomization}" >/dev/null; then
    pass "${label}: Kustomization never prunes, waits, and follows [${previous}] as in the hook"
  else
    fail "${label}: Kustomization must set prune false, wait true and dependsOn [${previous}]"
  fi

  if jq -e '.git' <<<"${source}" >/dev/null; then
    path="$(jq -r '.git.path' <<<"${source}")"
    local url
    url="$(mirrored "${values}" gitSources "$(jq -r '.git.repository' <<<"${source}")")"
    if jq -e --argjson s "${source}" --arg url "${url}" \
        '.spec.url == $url and .spec.ref == {commit: $s.git.commit}' <<<"${git}" >/dev/null \
      && [[ "$(actual_access <<<"${git}")" == "$(expected_access "${values}" gitSources)" ]] \
      && jq -e --arg name "${dependency%-crds}-crds" --arg path "./${path}" \
        '.spec.sourceRef == {kind: "GitRepository", name: $name} and .spec.path == $path' <<<"${kustomization}" >/dev/null; then
      pass "${label}: from ${url} at the BOM commit, ${path}"
    else
      fail "${label}: the GitRepository and Kustomization do not match the BOM fluxSource ${source}"
    fi
    if [[ ! -d "${dir}" ]]; then
      mkdir -p "${dir}"
      git init -q "${dir}/repo"
      if ! git -C "${dir}/repo" fetch -q --depth 1 --filter=blob:none \
        "$(jq -r '.git.repository' <<<"${source}")" "$(jq -r '.git.commit' <<<"${source}")"; then
        fail "${label}: cannot fetch the BOM commit"
        return
      fi
      git -C "${dir}/repo" archive FETCH_HEAD "${path}" | tar -x -C "${dir}"
    fi
  else
    path="$(jq -r '.chart.path' <<<"${source}")"
    local reference digest archive
    reference="$(jq -r --arg d "${dependency}" '.dependencies[$d].chart.reference' "${bom}")"
    digest="$(jq -r --arg d "${dependency}" '.dependencies[$d].chart.digest' "${bom}")"
    local url
    url="$(mirrored "${values}" dependencyCharts "${reference}")"
    if jq -e --arg url "${url}" --arg digest "${digest}" \
        '.spec.url == $url and .spec.ref == {digest: $digest} and .spec.layerSelector.operation == "extract"' <<<"${oci}" >/dev/null \
      && [[ "$(actual_access <<<"${oci}")" == "$(expected_access "${values}" dependencyCharts)" ]] \
      && jq -e --arg name "${dependency%-crds}-crds" --arg path "./${path}" \
        '.spec.sourceRef == {kind: "OCIRepository", name: $name} and .spec.path == $path' <<<"${kustomization}" >/dev/null; then
      pass "${label}: from the BOM chart ${url}@${digest}, ${path}"
    else
      fail "${label}: the OCIRepository and Kustomization do not match the BOM chart and fluxSource ${source}"
    fi
    if [[ ! -d "${dir}" ]]; then
      mkdir -p "${dir}"
      if ! archive="$(pull_chart "${reference}" "${digest}")"; then
        fail "${label}: cannot pull ${reference}@${digest}"
        return
      fi
      tar -xzf "${archive}" -C "${dir}"
    fi
  fi

  local expected actual
  if ! expected="$(manifest_objects "${dependency}")"; then
    fail "${label}: cannot download the BOM manifest at its digest"
    return
  fi
  actual="$(directory_objects "${dir}/${path}")" || actual=""
  if [[ -n "${actual}" && "${actual}" == "${expected}" ]]; then
    pass "${label}: the source holds exactly the $(wc -l <<<"${expected}" | tr -d ' ') objects of the BOM manifest"
  else
    fail "${label}: the source does not hold exactly the objects of the BOM manifest"
  fi
}

# charts/steward-edge from this repository, at the tag of the platform version.
check_steward_edge() {
  local name="$1" values="$2" hr="$3" git="$4" tag url upstream=https://github.com/apelogic-ai/steward-platform
  tag="$(jq -r .platformVersion "${bom}")"
  url="$(mirrored "${values}" gitSources "${upstream}")"
  if jq -e --arg tag "${tag}" --arg url "${url}" '.spec.ref == {tag: $tag} and .spec.url == $url' <<<"${git}" >/dev/null \
    && [[ "$(actual_access <<<"${git}")" == "$(expected_access "${values}" gitSources)" ]] \
    && jq -e '.spec.chart.spec.chart == "./charts/steward-edge" and .spec.chart.spec.sourceRef == {kind: "GitRepository", name: "steward-platform"}
        and (.spec | has("chartRef") | not)' <<<"${hr}" >/dev/null; then
    pass "${name}: steward-edge is built from this repository at tag ${tag}$([[ "${url}" != "${upstream}" ]] && echo ", from the mirror ${url}")"
  else
    fail "${name}: steward-edge must come from this repository at tag ${tag}"
    return
  fi
  local dir="${work}/steward-platform-${tag}"
  if [[ ! -d "${dir}" ]]; then
    git init -q "${dir}"
    # From upstream: the mirror holds the same tag.
    if ! git -C "${dir}" fetch -q --depth 1 "${upstream}" "refs/tags/${tag}" 2>/dev/null; then
      # A platform version is tagged when it is released.
      echo "note ${name}: tag ${tag} is not published yet; steward-edge resolves once this platform version is released"
      return
    fi
    git -C "${dir}" archive FETCH_HEAD charts/steward-edge | tar -x -C "${dir}"
  fi
  if diff -r "${dir}/charts/steward-edge" "${repo_root}/charts/steward-edge" >/dev/null; then
    pass "${name}: charts/steward-edge at tag ${tag} is this checkout's chart"
  else
    fail "${name}: charts/steward-edge changed since tag ${tag}; bump platformVersion so the Flux output installs this chart"
  fi
}

for entry in "${examples[@]}"; do
  read -r example_name example_environment <<<"${entry}"
  check_example "${example_name}" "${example_environment}"
done

if [[ "${failures}" != 0 ]]; then
  echo "${failures} Flux example checks failed" >&2
  exit 1
fi
echo "Flux example checks passed"
