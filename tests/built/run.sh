#!/usr/bin/env bash
# Tests for source-built products (docs/fork-and-build.md): the built-artifacts
# lock, scripts/generate.sh with artifacts.source built, the lock helper and
# the verifiers' built-lock mode. No cluster, registry or network needed.
#
# For every environments/*/platform-values.yaml:
#   - artifacts.source bom generates exactly what no artifacts block does;
#   - built mode with an identity lock (the BOM's own references) generates
#     exactly the BOM-mode output, apart from one header line naming the lock:
#     built mode changes nothing but the product references;
#   - built mode with examples/built/built-lock.json generates the BOM-mode
#     output with each product chart and image reference replaced by the
#     lock's, and no upstream digest of a built product left.
# Then: the example lock is what scripts/built-lock-from-digests.sh writes for
# the BOM; the generator, the helper and scripts/verify-built-lock.sh refuse
# locks they must refuse; and verify-signatures.sh and verify-attestations.sh
# skip built products with a notice.
#
# With --base REF, also generate every environment with the generator at Git
# REF (for example origin/main) and require byte-identical BOM-mode output:
# the before/after check for a change to the generator. It is not part of the
# default run because an intended output change, or a BOM bump, would fail it.
#
# Usage: tests/built/run.sh [--base REF]
#        tests/built/run.sh --update   rewrite examples/built/built-lock.json
# Needs: jq, yq (mikefarah v4), check-jsonschema, git (for --base).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bom="${repo_root}/bom/bom.json"
generate="${repo_root}/scripts/generate.sh"
helper="${repo_root}/scripts/built-lock-from-digests.sh"
example_lock="${repo_root}/examples/built/built-lock.json"
base_ref=""
update=0
case "${1:-}" in
  --base) [[ "$#" == 2 ]] || { echo "usage: $0 [--base REF | --update]" >&2; exit 2; }; base_ref="$2" ;;
  --update) update=1 ;;
  "") ;;
  *) echo "usage: $0 [--base REF | --update]" >&2; exit 2 ;;
esac

for tool in jq yq check-jsonschema; do
  command -v "${tool}" >/dev/null || { echo "missing ${tool}" >&2; exit 2; }
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok   $*"; }

# Products a lock covers: those some profile deploys.
built_products=(steward github-oidc-exchange)

# name=value pairs for the helper, per built product. identity: the BOM's own
# references and commits. example: registry.example.com references with
# placeholder digests; one image of each product without a tag, to show that
# the tag is optional.
lock_pairs() {
  local mode="$1" product base=0
  for product in "${built_products[@]}"; do
    jq -r --arg mode "${mode}" --arg product "${product}" --argjson base "${base}" '
      # Obvious placeholders, unique per artifact: sha256:00...0<n>.
      def fake($n): "sha256:" + ("0" * 60) + ("\(1000 + $base + $n)" | .[0:4]);
      .products[$product] as $p
      | "\($product).source=\(if $mode == "identity" then $p.source else "https://github.com/example-org/\($product)" end)",
        "\($product).commit=\($p.commit)",
        ($p.chart // empty
          | if $mode == "identity" then "\($product).chart=\(.reference):\(.version)@\(.digest)"
            else "\($product).chart=oci://registry.example.com/steward-platform/charts/\(.reference | split("/") | last)@\(fake(0))" end),
        ($p.images | to_entries | sort_by(.key) | to_entries[] | .key as $n | .value | .key as $component
          | (.value | capture("^(?<repository>[^@]+):(?<tag>[^:@/]+)@(?<digest>.*)$")) as $ref
          | if $mode == "identity" then "\($product).images.\($component)=\(.value)"
            else "\($product).images.\($component)=registry.example.com/steward-platform/\($ref.repository | split("/") | last)"
              + (if $component == ($p.images | keys | last) then "" else ":\($ref.tag)" end)
              + "@\(fake($n + 1))" end)
    ' "${bom}"
    base=$((base + 100))
  done
}

write_lock() {
  local mode="$1" out="$2" pairs=()
  while IFS= read -r pair; do pairs+=("${pair}"); done < <(lock_pairs "${mode}")
  "${helper}" "${pairs[@]}" > "${out}"
}

if [[ "${update}" == 1 ]]; then
  write_lock example "${work}/example.json"
  jq --indent 2 '{"$schema": "../../schemas/built-lock/v1.schema.json"} + .' "${work}/example.json" > "${example_lock}"
  echo "rewrote examples/built/built-lock.json"
  exit 0
fi

# --- The example lock --------------------------------------------------------

write_lock example "${work}/example.json"
if jq --indent 2 '{"$schema": "../../schemas/built-lock/v1.schema.json"} + .' "${work}/example.json" \
  | diff -u "${example_lock}" - >"${work}/example.diff"; then
  pass "examples/built/built-lock.json is what the helper writes for the BOM"
else
  cat "${work}/example.diff" >&2
  fail "examples/built/built-lock.json is stale; run tests/built/run.sh --update and commit the result"
fi
if "${repo_root}/scripts/verify-built-lock.sh" --offline --profile browser-admin "${example_lock}" >"${work}/verify.log" 2>&1; then
  pass "verify-built-lock.sh --offline accepts the example lock for browser-admin"
else
  cat "${work}/verify.log" >&2
  fail "verify-built-lock.sh --offline rejects the example lock"
fi
write_lock identity "${work}/identity.json"

# --- Every environment -------------------------------------------------------

# The environment's values edited by the yq expression $2. The committed
# environments reference no files, so the copy can live anywhere.
variant() {
  local values="$1" expression="$2" out="$3"
  yq "${expression}" "${values}" > "${out}"
}

# BOM-mode output with each product reference of the lock ($2) substituted:
# chart references, repositories and digests, each only as a whole reference
# (followed by a separator), so that ghcr.io/example/steward never rewrites
# ghcr.io/example/steward-run.
substitute() {
  local dir="$1" lock="$2" script="${work}/substitute.sed"
  jq -r --slurpfile bom "${bom}" -L "${repo_root}/scripts/lib" '
    include "built";
    def esc: gsub("(?<c>[.#/\\[\\]*^$])"; "\\\(.c)");
    .products | to_entries[] | .key as $name | .value as $built | $bom[0].products[$name] as $pinned
    | ([ ($pinned.chart // empty | [.reference, $built.chart.reference], [.digest, $built.chart.digest]),
         ($pinned.images | to_entries[] | (.value | lock_image_parts) as $from
           | ($built.images[.key] | lock_image_parts) as $to
           | [$from.repository, $to.repository], [$from.digest, $to.digest]) ]
       | unique | sort_by(.[0] | -length)[])
    | "s#\(.[0] | esc)([@:\"'"'"' ]|$)#\(.[1] | esc)\\1#g"
  ' "${lock}" > "${script}"
  find "${dir}" -type f -name '*.yaml' -exec sed -E -i.orig -f "${script}" {} +
  find "${dir}" -type f -name '*.orig' -delete
}

# Drop the one header line that built mode adds.
strip_lock_header() {
  find "$1" -type f -name '*.yaml' -exec sed -i.orig '/^# Product charts and images from the built-artifacts lock /d' {} +
  find "$1" -type f -name '*.orig' -delete
}

for values in "${repo_root}"/environments/*/platform-values.yaml; do
  name="$(basename "$(dirname "${values}")")"
  out="${work}/out/${name}"
  mkdir -p "${out}"
  if ! "${generate}" --out "${out}/bom" "${values}" >/dev/null; then
    fail "${name}: BOM-mode generation failed"
    continue
  fi

  variant "${values}" '.artifacts = {"source": "bom"}' "${work}/values.yaml"
  "${generate}" --out "${out}/explicit" "${work}/values.yaml" >/dev/null 2>"${work}/err" || cat "${work}/err" >&2
  # The header names the values file, which is a copy here; nothing else may differ.
  if [[ -d "${out}/explicit" ]] && diff -r -I '^# Generated by scripts/generate.sh from ' "${out}/bom" "${out}/explicit" >"${work}/diff"; then
    pass "${name}: artifacts.source bom generates the BOM-mode output"
  else
    cat "${work}/diff" >&2
    fail "${name}: artifacts.source bom changes the output"
  fi

  variant "${values}" ".artifacts = {\"source\": \"built\", \"builtLock\": \"${work}/identity.json\"}" "${work}/values.yaml"
  "${generate}" --out "${out}/identity" "${work}/values.yaml" >/dev/null 2>"${work}/err" || cat "${work}/err" >&2
  variant "${values}" ".artifacts = {\"source\": \"built\", \"builtLock\": \"${example_lock}\"}" "${work}/values.yaml"
  "${generate}" --out "${out}/example" "${work}/values.yaml" >/dev/null 2>"${work}/err" || cat "${work}/err" >&2
  "${generate}" --out "${out}/example-again" "${work}/values.yaml" >/dev/null 2>&1 || true

  if [[ ! -d "${out}/identity" ]]; then
    fail "${name}: built mode with the identity lock failed"
  elif ! grep -rqF "# Product charts and images from the built-artifacts lock identity.json" "${out}/identity/values/steward.yaml"; then
    fail "${name}: built-mode output does not name its lock"
  else
    strip_lock_header "${out}/identity"
    if diff -r -I '^# Generated by scripts/generate.sh from ' "${out}/bom" "${out}/identity" >"${work}/diff"; then
      pass "${name}: built mode with the BOM's own references generates the BOM-mode output"
    else
      cat "${work}/diff" >&2
      fail "${name}: built mode with the BOM's own references changes more than the references"
    fi
  fi

  if [[ ! -d "${out}/example" ]]; then
    fail "${name}: built mode with the example lock failed"
    continue
  fi
  if diff -r "${out}/example" "${out}/example-again" >/dev/null; then
    pass "${name}: built-mode output is deterministic"
  else
    fail "${name}: two built-mode runs differ"
  fi
  cp -R "${out}/bom" "${out}/expected"
  substitute "${out}/expected" "${example_lock}"
  strip_lock_header "${out}/example"
  if diff -r -I '^# Generated by scripts/generate.sh from ' "${out}/expected" "${out}/example" >"${work}/diff"; then
    pass "${name}: built mode replaces exactly the product references with the example lock's"
  else
    cat "${work}/diff" >&2
    fail "${name}: built-mode output is not the BOM-mode output with the lock's references"
  fi
  if diff -r -q "${out}/bom" "${out}/example" >/dev/null; then
    fail "${name}: built mode left the output unchanged"
  fi
  leftover="$(jq -r --slurpfile lock "${example_lock}" '
      .products | to_entries[] | select($lock[0].products[.key] != null) | .value
      | (.chart.digest // empty), (.images[] | split("@")[1])' "${bom}" \
    | while IFS= read -r digest; do grep -rlF "${digest}" "${out}/example" || true; done)"
  if [[ -z "${leftover}" ]]; then
    pass "${name}: no upstream digest of a built product is left"
  else
    fail "${name}: upstream digests of built products left in ${leftover}"
  fi
  # browser-admin: steward-run's release coordinates stay the signed BOM ones.
  if [[ "$(yq -r .profile "${values}")" == browser-admin ]]; then
    expected="$(jq -cS -n --slurpfile bom "${bom}" -L "${repo_root}/scripts/lib" \
      'include "platform"; steward_run_release($bom[0])')"
    actual="$(yq -o=json '.config.apiserver.stewardRunRelease' "${out}/example/values/steward.yaml" | jq -cS .)"
    if [[ "${actual}" == "${expected}" ]]; then
      pass "${name}: stewardRunRelease keeps steward-run's signed BOM coordinates"
    else
      fail "${name}: stewardRunRelease is ${actual}, expected ${expected}"
    fi
  fi
done

# --- Refusals ----------------------------------------------------------------

base_values="${repo_root}/environments/production-task-auth/platform-values.yaml"

# Generate production-task-auth in built mode with the example lock edited by
# the jq expression $2; expect failure with message $3, or success with
# warning $3 when $4 is "warns".
built_case() {
  local label="$1" expression="$2" expected="$3" outcome="${4:-fails}" values_expression="${5:-}"
  local lock="${work}/case-lock.json" values="${work}/case-values.yaml"
  jq "${expression}" "${example_lock}" > "${lock}"
  yq ".artifacts = {\"source\": \"built\", \"builtLock\": \"${lock}\"}${values_expression:+ | ${values_expression}}" \
    "${base_values}" > "${values}"
  local status=0
  "${generate}" --out "${work}/case-out" "${values}" >"${work}/case.log" 2>&1 || status=$?
  if [[ "${outcome}" == fails && "${status}" == 0 ]]; then
    fail "refuses ${label}: generator accepted it"
  elif [[ "${outcome}" != fails && "${status}" != 0 ]]; then
    cat "${work}/case.log" >&2
    fail "accepts ${label}: generator failed"
  elif grep -Fq -- "${expected}" "${work}/case.log"; then
    pass "$([[ "${outcome}" == fails ]] && echo refuses || echo accepts) ${label}"
  else
    cat "${work}/case.log" >&2
    fail "${label}: expected '${expected}'"
  fi
}

built_case "a lock without a product the profile deploys" 'del(.products["github-oidc-exchange"])' \
  "products.github-oidc-exchange.images.exchange is missing (the task-auth profile deploys github-oidc-exchange)"
built_case "a lock without a product's chart" 'del(.products["github-oidc-exchange"].chart)' \
  "products.github-oidc-exchange.chart is missing"
built_case "a lock without one image" 'del(.products.steward.images.mint)' \
  "products.steward.images.mint is missing"
built_case "a lock that lists every missing component" 'del(.products.steward.images.mint, .products.steward.images.bridge)' \
  "products.steward.images.bridge is missing"
built_case "a commit other than the BOM's" '.products.steward.commit = ("1" * 40)' \
  "products.steward.commit is 1111111111111111111111111111111111111111, not the BOM commit"
built_case "a documented fork (allowSourceDrift), with a warning" \
  '.products.steward.commit = ("1" * 40) | .products.steward.allowSourceDrift = true' \
  "warning: products.steward is built from https://github.com/example-org/steward at 1111111111111111111111111111111111111111" warns
built_case "another product version" '.products.steward.version = "9.9.9"' \
  "products.steward.version is 9.9.9; the BOM pins"
built_case "another chart version" '.products.steward.chart.version = "9.9.9"' \
  "products.steward.chart.version is 9.9.9; the BOM pins"
built_case "an image the BOM does not pin" '.products.steward.images.extra = .products.steward.images.web' \
  "products.steward.images.extra is not an image the BOM pins for steward"
built_case "a product the BOM does not have" '.products.other = .products.steward' \
  "products.other is not a product of the BOM"
built_case "steward-run, which the platform does not deploy" \
  '.products["steward-run"] = {version: "0.7.2", source: "https://github.com/example-org/steward-run", commit: ("1" * 40), images: {runner: "registry.example.com/steward-run@sha256:\("a" * 64)"}}' \
  "the platform does not deploy steward-run's artifacts"
built_case "Steward images split across repositories" \
  '.products.steward.images.web = "registry.example.com/other/steward@sha256:\("a" * 64)"' \
  "apiserver, controller and web must share one repository"
built_case "an image pinned by tag only" '.products.steward.images.web = "registry.example.com/steward-platform/steward:0.3.2-web"' \
  "does not match schemas/built-lock/v1.schema.json"
built_case "a lock for core without the task-auth products" 'del(.products["github-oidc-exchange"])' \
  "generated" accepts '.profile = "core" | del(.publicEndpoints, .audiences, .edge, .identityExchange, .namespaces.identityExchange, .serviceAccounts.identityExchange, .networkPolicy.edgeNamespace)'

values_case() {
  local label="$1" expression="$2" expected="$3" values="${work}/case-values.yaml"
  yq "${expression}" "${base_values}" > "${values}"
  if "${generate}" --out "${work}/case-out" "${values}" >"${work}/case.log" 2>&1; then
    fail "refuses ${label}: generator accepted it"
  elif grep -Fq -- "${expected}" "${work}/case.log"; then
    pass "refuses ${label}"
  else
    cat "${work}/case.log" >&2
    fail "refuses ${label}: expected '${expected}'"
  fi
}
values_case "source built without a lock" '.artifacts = {"source": "built"}' "does not match"
values_case "a lock with source bom" ".artifacts = {\"source\": \"bom\", \"builtLock\": \"${example_lock}\"}" "does not match"
values_case "a lock file that does not exist" '.artifacts = {"source": "built", "builtLock": "no-such-lock.json"}' \
  "no-such-lock.json is missing or empty"

# --- The helper --------------------------------------------------------------

helper_case() {
  local label="$1" expected="$2"; shift 2
  if "${helper}" "$@" >"${work}/helper.json" 2>"${work}/helper.log"; then
    fail "helper refuses ${label}: it accepted it"
  elif grep -Fq -- "${expected}" "${work}/helper.log"; then
    pass "helper refuses ${label}"
  else
    cat "${work}/helper.log" >&2
    fail "helper refuses ${label}: expected '${expected}'"
  fi
}
digest="sha256:$(printf 'a%.0s' {1..64})"
steward_commit="$(jq -r .products.steward.commit "${bom}")"
helper_case "a product without its commit" "products.steward.commit is not set" \
  steward.source=https://github.com/example-org/steward "steward.images.apiserver=registry.example.com/steward@${digest}"
helper_case "an unknown field" "not PRODUCT.source, .commit, .allowSourceDrift, .chart or .images.COMPONENT" \
  steward.sources=https://github.com/example-org/steward
helper_case "a chart without a digest" "not oci://REGISTRY/REPOSITORY[:VERSION]@sha256:DIGEST" \
  steward.chart=oci://registry.example.com/charts/steward:0.3.2
helper_case "a lock that does not cover the profile" "products.github-oidc-exchange.chart is missing" \
  --profile task-auth steward.source=https://github.com/example-org/steward "steward.commit=${steward_commit}" \
  "steward.images.apiserver=registry.example.com/steward@${digest}"
if jq -e --slurpfile bom "${bom}" '.products.steward.chart.version == $bom[0].products.steward.chart.version' \
  "${work}/example.json" >/dev/null; then
  pass "helper takes the BOM chart version when the chart reference has none"
else
  fail "helper did not take the BOM chart version"
fi

# --- The verifiers skip built products with a notice --------------------------

# Stand-ins that fail if called: nothing may be verified upstream for a built
# product. The BOM keeps only what a built lock skips, so no network is used.
stubs="${work}/stubs"
mkdir -p "${stubs}"
for tool in cosign gh; do
  printf '#!/bin/sh\necho "%s must not be called" >&2\nexit 99\n' "${tool}" > "${stubs}/${tool}"
  chmod +x "${stubs}/${tool}"
done
jq 'del(.products["steward-run"], .products["mcp-gw"])' "${bom}" > "${work}/built-bom.json"
if PATH="${stubs}:${PATH}" "${repo_root}/scripts/verify-signatures.sh" --built-lock "${example_lock}" "${work}/built-bom.json" \
    >"${work}/signatures.log" 2>&1 \
  && grep -Fq "SKIP products.github-oidc-exchange: built from source" "${work}/signatures.log" \
  && grep -Fq "skipped 1 built-from-source products" "${work}/signatures.log"; then
  pass "verify-signatures.sh skips built products with a notice"
else
  cat "${work}/signatures.log" >&2
  fail "verify-signatures.sh does not skip built products with a notice"
fi
if PATH="${stubs}:${PATH}" "${repo_root}/scripts/verify-attestations.sh" --built-lock "${example_lock}" "${work}/built-bom.json" \
    >"${work}/attestations.log" 2>&1 \
  && grep -Fq "SKIP products.steward.apiserver: built from source" "${work}/attestations.log" \
  && grep -Fq "skipped 9 built-from-source artifacts" "${work}/attestations.log"; then
  pass "verify-attestations.sh skips built products with a notice"
else
  cat "${work}/attestations.log" >&2
  fail "verify-attestations.sh does not skip built products with a notice"
fi

# --- Before and after (--base) ------------------------------------------------

if [[ -n "${base_ref}" ]]; then
  command -v git >/dev/null || { echo "missing git" >&2; exit 2; }
  base="${work}/base"
  git -C "${repo_root}" worktree add --detach --quiet "${base}" "${base_ref}"
  for values in "${repo_root}"/environments/*/platform-values.yaml; do
    name="$(basename "$(dirname "${values}")")"
    if [[ ! -f "${base}/environments/${name}/platform-values.yaml" ]]; then
      echo "skip ${name}: not in ${base_ref}"
      continue
    fi
    # Each side generates from its own checkout: generator, BOM and values.
    "${base}/scripts/generate.sh" --out "${work}/before/${name}" "${base}/environments/${name}/platform-values.yaml" >/dev/null
    "${generate}" --out "${work}/after/${name}" "${values}" >/dev/null
    if diff -r "${work}/before/${name}" "${work}/after/${name}"; then
      pass "${name}: BOM-mode output is byte-identical to the generator at ${base_ref}"
    else
      fail "${name}: BOM-mode output differs from the generator at ${base_ref}"
    fi
  done
  git -C "${repo_root}" worktree remove --force "${base}"
fi

if [[ "${failures}" != 0 ]]; then
  echo "${failures} built-mode checks failed" >&2
  exit 1
fi
echo "built-mode checks passed"
