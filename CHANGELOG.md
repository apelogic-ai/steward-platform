# Changelog

Platform versions of the Steward platform BOM. Each entry is one
`platformVersion` of [`bom/bom.json`](bom/bom.json); the BOM at that version
is authoritative for every pinned version and digest.

## Unreleased

- **Safety fix: the Envoy Gateway CRD hook no longer writes to the current
  kubeconfig context.** The helmfile's `envoy-gateway` presync hook
  (`scripts/apply-manifests.sh`) ignored helmfile's `--kube-context` and, unless
  `PLATFORM_KUBE_CONTEXT` was set, server-side applied the Gateway API and
  Envoy Gateway CRDs to whatever context was current, so
  `helmfile --kube-context A sync` with current context B wrote CRDs to
  cluster B. The hook now receives the release's kube context from helmfile
  (`--kube-context`, `HELMFILE_KUBE_CONTEXT`, or a release or environment
  `kubeContext`) and refuses to run without one, when the context is not in
  the kubeconfig, when `PLATFORM_KUBE_CONTEXT` names a different context, or
  when helmfile was given `--kubeconfig` (which it does not pass to hooks; use
  `KUBECONFIG`). `PLATFORM_KUBE_CONTEXT` still works when it agrees. Run the
  task-auth and browser-admin syncs with `--kube-context`; see
  [the CRD hook and the kube context](helmfile/README.md#the-crd-hook-and-the-kube-context).
  New test: [`tests/hooks/run.sh`](tests/hooks/run.sh).

## 2026.10.0-alpha.5

First tagged pre-release. Release notes:
[docs/releases/2026.10.0-alpha.5.md](docs/releases/2026.10.0-alpha.5.md).

- Steward 0.3.2, github-oidc-exchange 0.7.2 and steward-run 0.7.2.
- mcp-gw 0.5.0 pinned for the planned governed profile (`plannedFor`), not
  installed by any profile.
- Profiles core, task-auth and browser-admin, tested on Kubernetes 1.32 to
  1.34.

## Earlier versions

Untagged BOM iterations on `main`, before the first pre-release:

- **2026.10.0-alpha.4**: the browser-admin profile, and steward-run's
  workflow coordinates.
- **2026.10.0-alpha.3**: the task-auth profile, with github-oidc-exchange and
  steward-run.
- **2026.10.0-alpha.2**: Steward 0.3.1.
- **2026.10.0-alpha.1**: the core profile, Steward 0.3.0.
