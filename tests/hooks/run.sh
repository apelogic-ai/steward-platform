#!/usr/bin/env bash
# Tests that the helmfile's CRD hook, scripts/apply-manifests.sh, writes only
# to the kube context that helmfile uses for its releases. No cluster and no
# network: kubectl, curl and helm are fakes on PATH that record their
# arguments. The kubeconfig's current context is always "current", a
# different cluster from the target "target", so a hook that falls back to
# the current context shows up as a write to "current".
#
# 1. The script alone, for each combination of --context, PLATFORM_KUBE_CONTEXT
#    and current context: it applies to exactly one named context (with no
#    context at all, the current one, where Helm installs the releases, named
#    explicitly), or refuses before it downloads or applies anything.
# 2. Through helmfile (the pinned version; SKIP_HELMFILE=1 skips): `helmfile
#    sync` of the kind-task-auth envoy-gateway release passes the release's
#    context to the hook (--kube-context and HELMFILE_KUBE_CONTEXT); without
#    one, the hook and Helm both use the current context; with helmfile's
#    --kubeconfig flag, which helmfile does not pass to hooks, or a
#    disagreeing PLATFORM_KUBE_CONTEXT, the hook refuses and Helm installs
#    nothing.
#
# Usage: tests/hooks/run.sh
# Needs: jq, sha256sum (or shasum); for part 2 also helmfile and what
#        scripts/generate.sh needs (yq, check-jsonschema).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
apply="${repo_root}/scripts/apply-manifests.sh"

command -v jq >/dev/null || { echo "missing jq" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok   $*"; }
sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# --- Fakes ---------------------------------------------------------------------
fakes="${work}/bin"
logs="${work}/logs"
mkdir -p "${fakes}" "${logs}"

# kubectl: knows the contexts in FAKE_CONTEXTS, reports FAKE_CURRENT as the
# current context, and records every call.
cat > "${fakes}/kubectl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_LOGS}/kubectl"
case "${1:-} ${2:-}" in
  "config current-context")
    [[ -n "${FAKE_CURRENT:-}" ]] || { echo "error: current-context is not set" >&2; exit 1; }
    echo "${FAKE_CURRENT}" ;;
  "config get-contexts")
    [[ " ${FAKE_CONTEXTS} " == *" ${3:-} "* ]] || { echo "error: context ${3:-} not found" >&2; exit 1; } ;;
esac
exit 0
FAKE

# curl: writes the fixture manifest to --output and records the URL.
cat > "${fakes}/curl" <<'FAKE'
#!/usr/bin/env bash
out=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --netrc-file) shift 2 ;;
    -*) shift ;;
    *) printf '%s\n' "$1" >> "${FAKE_LOGS}/curl"; shift ;;
  esac
done
cp "${FAKE_MANIFEST}" "${out}"
FAKE

# helm: answers `version`, "pulls" a minimal chart where helmfile asks, and
# records every call; installs nothing.
cat > "${fakes}/helm" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_LOGS}/helm"
[[ "${1:-}" == version ]] && { echo "v3.19.0+gfake"; exit 0; }
args=("$@") reference="" destination=""
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == pull ]] && reference="${args[i + 1]:-}"
  [[ "${args[i]}" == --destination ]] && destination="${args[i + 1]:-}"
done
if [[ -n "${reference}" && -n "${destination}" ]]; then
  name="${reference##*/}"
  name="${name%%@*}"
  mkdir -p "${destination}/${name}"
  printf 'apiVersion: v2\nname: %s\nversion: 0.0.0\n' "${name}" > "${destination}/${name}/Chart.yaml"
fi
exit 0
FAKE
chmod +x "${fakes}"/*

# A BOM whose two CRD manifests are the fixture, at its digest.
manifest="${work}/manifest.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: fixture\n' > "${manifest}"
digest="sha256:$(sha256_of "${manifest}")"
test_bom="${work}/bom.json"
jq --arg digest "${digest}" '
  .dependencies["gateway-api-crds"].manifests = [{"url": "https://manifests.test/gateway-api-crds.yaml", "digest": $digest}]
  | .dependencies["envoy-gateway"].manifests = [{"url": "https://manifests.test/envoy-gateway.yaml", "digest": $digest}]
' "${repo_root}/bom/bom.json" > "${test_bom}"

export FAKE_LOGS="${logs}" FAKE_MANIFEST="${manifest}" FAKE_CONTEXTS="current target"
reset_logs() { rm -f "${logs}"/*; touch "${logs}/kubectl" "${logs}/curl" "${logs}/helm"; }
# The contexts `kubectl apply` wrote to, one per line; "<none>" for an apply
# without --context.
applied_contexts() {
  awk '/(^| )apply( |$)/ { c = "<none>"; for (i = 1; i < NF; i++) if ($i == "--context") c = $(i + 1); print c }' \
    "${logs}/kubectl" | sort -u
}

# --- 1. The script alone -------------------------------------------------------
# run_script NAME EXPECT [ENV=VALUE...] -- [ARG...]
#   EXPECT: a context name (every apply goes there, and something is applied)
#   or "refuse:<text>" (non-zero exit, <text> in stderr, nothing downloaded or
#   applied).
run_script() {
  local name="$1" expect="$2" status=0
  shift 2
  local envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  reset_logs
  env -u PLATFORM_KUBE_CONTEXT PATH="${fakes}:${PATH}" BOM="${test_bom}" FAKE_CURRENT=current \
    ${envs[@]+"${envs[@]}"} "${apply}" "$@" gateway-api-crds envoy-gateway \
    >"${work}/out" 2>"${work}/err" || status=$?
  local applied
  applied="$(applied_contexts)"
  if [[ "${expect}" == refuse:* ]]; then
    if [[ "${status}" != 0 && -z "${applied}" && ! -s "${logs}/curl" ]] && grep -qF -- "${expect#refuse:}" "${work}/err"; then
      pass "script: ${name}: refuses"
    else
      fail "script: ${name}: expected a refusal mentioning '${expect#refuse:}'; exit ${status}, applied to [${applied//$'\n'/ }]: $(cat "${work}/err")"
    fi
  else
    if [[ "${status}" == 0 && "${applied}" == "${expect}" && "$(grep -c ' apply ' "${logs}/kubectl")" == 2 ]]; then
      pass "script: ${name}: applies to ${expect} only"
    else
      fail "script: ${name}: expected both manifests applied to ${expect}; exit ${status}, applied to [${applied//$'\n'/ }]: $(cat "${work}/err")"
    fi
  fi
}

run_script "--context target, current context elsewhere" target -- --context target
run_script "no context at all: the current context, named" current --
run_script "empty --context (helmfile without a context): the current context, named" current -- --context ""
run_script "no context and no current context" "refuse:has no current context" FAKE_CURRENT= -- --context ""
run_script "--context and PLATFORM_KUBE_CONTEXT agree" target PLATFORM_KUBE_CONTEXT=target -- --context target
run_script "--context and PLATFORM_KUBE_CONTEXT differ" "refuse:PLATFORM_KUBE_CONTEXT is 'current'" \
  PLATFORM_KUBE_CONTEXT=current -- --context target
run_script "only PLATFORM_KUBE_CONTEXT, not the current context" "refuse:its releases go to the current context 'current'" \
  PLATFORM_KUBE_CONTEXT=target -- --context ""
run_script "only PLATFORM_KUBE_CONTEXT, no current context" "refuse:the current context '<none>'" \
  PLATFORM_KUBE_CONTEXT=target FAKE_CURRENT= --
run_script "only PLATFORM_KUBE_CONTEXT, equal to the current context" current PLATFORM_KUBE_CONTEXT=current --
run_script "a context the kubeconfig does not have" "refuse:is not in the kubeconfig" -- --context missing

# --- 2. Through helmfile -------------------------------------------------------
if [[ "${SKIP_HELMFILE:-0}" == 1 ]]; then
  echo "skip helmfile (SKIP_HELMFILE=1)"
elif ! command -v helmfile >/dev/null; then
  echo "missing helmfile (or set SKIP_HELMFILE=1)" >&2
  exit 2
else
  generated="${work}/generated"
  "${repo_root}/scripts/generate.sh" --out "${generated}/kind-task-auth" \
    "${repo_root}/environments/kind-task-auth/platform-values.yaml" >/dev/null
  # The kubeconfig given to helmfile --kubeconfig in one case; its contents do
  # not matter, as helmfile passes it only to the fake helm.
  printf 'apiVersion: v1\nkind: Config\n' > "${work}/other-kubeconfig"

  # run_helmfile NAME EXPECT [ENV=VALUE...] -- [HELMFILE ARG...]
  #   EXPECT: a context (the hook applies there and Helm installs the release
  #   there), "current-implicit" (helmfile has no context, so Helm runs without
  #   --kube-context, into the current context, and the hook applies to
  #   "current" by name, with a notice) or "refuse:<text>" (the sync fails,
  #   the hook's <text> is in the output, and nothing is applied or installed).
  run_helmfile() {
    local name="$1" expect="$2" status=0
    shift 2
    local envs=()
    while [[ "$1" != -- ]]; do envs+=("$1"); shift; done
    shift
    reset_logs
    env -u PLATFORM_KUBE_CONTEXT -u HELMFILE_KUBE_CONTEXT PATH="${fakes}:${PATH}" BOM="${test_bom}" \
      FAKE_CURRENT=current PLATFORM_GENERATED_DIR="${generated}" HELMFILE_CACHE_HOME="${work}/helmfile-cache" \
      ${envs[@]+"${envs[@]}"} helmfile --file "${repo_root}/helmfile/helmfile.yaml.gotmpl" \
      --environment kind-task-auth "$@" sync --selector name=envoy-gateway --skip-deps \
      >"${work}/out" 2>&1 || status=$?
    local applied installs
    applied="$(applied_contexts)"
    installs="$(grep -E '(^| )upgrade --install envoy-gateway ' "${logs}/helm" || true)"
    if [[ "${expect}" == refuse:* ]]; then
      if [[ "${status}" != 0 && -z "${applied}" && -z "${installs}" ]] && grep -qF -- "${expect#refuse:}" "${work}/out"; then
        pass "helmfile: ${name}: the hook refuses and nothing is installed"
      else
        fail "helmfile: ${name}: expected a refusal mentioning '${expect#refuse:}'; exit ${status}, applied to [${applied//$'\n'/ }]"
        cat "${work}/out" >&2
      fi
    elif [[ "${expect}" == current-implicit ]]; then
      if [[ "${status}" == 0 && "${applied}" == current && -n "${installs}" && "${installs}" != *--kube-context* ]] \
        && grep -qF "no kube context given; using current context current" "${work}/out"; then
        pass "helmfile: ${name}: the hook applies to the current context by name, where Helm installs the release"
      else
        fail "helmfile: ${name}: expected the hook on 'current' by name and Helm on the current context; exit ${status}, hook applied to [${applied//$'\n'/ }], helm: ${installs}"
        cat "${work}/out" >&2
      fi
    else
      if [[ "${status}" == 0 && "${applied}" == "${expect}" && "${installs}" == *"--kube-context ${expect} "* ]]; then
        pass "helmfile: ${name}: the hook and the release both target ${expect}"
      else
        fail "helmfile: ${name}: expected the hook and the release on ${expect}; exit ${status}, hook applied to [${applied//$'\n'/ }], helm: ${installs}"
        cat "${work}/out" >&2
      fi
    fi
  }

  run_helmfile "--kube-context target, current context elsewhere" target -- --kube-context target
  run_helmfile "HELMFILE_KUBE_CONTEXT=target" target HELMFILE_KUBE_CONTEXT=target --
  run_helmfile "--kube-context and PLATFORM_KUBE_CONTEXT agree" target PLATFORM_KUBE_CONTEXT=target -- --kube-context target
  run_helmfile "no context: the current context for both" current-implicit --
  run_helmfile "--kube-context and PLATFORM_KUBE_CONTEXT differ" "refuse:PLATFORM_KUBE_CONTEXT is 'current'" \
    PLATFORM_KUBE_CONTEXT=current -- --kube-context target
  run_helmfile "only PLATFORM_KUBE_CONTEXT, not the current context" "refuse:its releases go to the current context 'current'" \
    PLATFORM_KUBE_CONTEXT=target --
  run_helmfile "--kubeconfig" "refuse:helmfile was run with --kubeconfig" \
    -- --kubeconfig "${work}/other-kubeconfig" --kube-context target
fi

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} failure(s)" >&2
  exit 1
fi
echo "all hook checks passed"
