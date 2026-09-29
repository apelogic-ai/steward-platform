# Changelog

Platform versions of the Steward platform BOM. Each entry is one
`platformVersion` of [`bom/bom.json`](bom/bom.json); the BOM at that version
is authoritative for every pinned version and digest.

## Unreleased

- Registry mirror override (no breaking changes). The optional platform
  values block `registry` pulls each artifact class from the operator's own
  mirror: product images and charts, dependency images and charts, the Git
  sources and CRD manifests of the Flux output and the helmfile, with image
  pull Secrets and Flux credentials referenced by name. Tags and digests stay
  the BOM's. `scripts/mirror-list.sh` lists the whole platform to copy and
  `scripts/verify-digests.sh --mirror` checks the copy with the operator's
  credentials. See [docs/registry-mirroring.md](docs/registry-mirroring.md).
  Without the block the generated output is byte-identical to before.
- Source-built products (no breaking changes). The optional platform values
  block `artifacts` (`source: built`, `builtLock`) takes each deployed
  product's chart and images from a built-artifacts lock
  ([`schemas/built-lock/v1.schema.json`](schemas/built-lock/v1.schema.json)):
  products built from source at the BOM's release commits, or from a fork
  with `allowSourceDrift`, and pushed to the operator's registry. The
  generator checks the lock against the BOM and lists every missing chart or
  image. `scripts/built-lock-from-digests.sh` writes a lock and
  `scripts/verify-built-lock.sh` checks one; `verify-digests.sh`,
  `verify-attestations.sh` and `verify-signatures.sh` take `--built-lock`.
  Built mode composes with a registry mirror of everything but the products:
  `registry.productImages` and `registry.productCharts` are refused with
  `source: built`, while the dependency classes and `imagePullSecrets` apply;
  `mirror-list.sh` then leaves the built products out, and
  `verify-digests.sh --mirror` checks them against the lock. See
  [docs/fork-and-build.md](docs/fork-and-build.md). Without the block the
  generated output is byte-identical to before.
- **Safety fix: the Envoy Gateway CRD hook no longer writes to a different
  cluster from the releases.** The helmfile's `envoy-gateway` presync hook
  (`scripts/apply-manifests.sh`) ignored helmfile's `--kube-context` and, unless
  `PLATFORM_KUBE_CONTEXT` was set, server-side applied the Gateway API and
  Envoy Gateway CRDs to whatever context was current, so
  `helmfile --kube-context A sync` with current context B wrote CRDs to
  cluster B. The hook now receives the release's kube context from helmfile
  (`--kube-context`, `HELMFILE_KUBE_CONTEXT`, or a release or environment
  `kubeContext`) and names it on every `kubectl` call. With no context at all
  it uses the current context, where Helm installs the releases too, and
  prints a notice. It refuses only where the CRDs and the releases could land
  on different clusters: `PLATFORM_KUBE_CONTEXT` naming a different context,
  a context missing from the kubeconfig, or helmfile's `--kubeconfig` (which
  helmfile does not pass to hooks; use `KUBECONFIG`). No breaking change for
  the documented invocations, with or without `--kube-context` or
  `PLATFORM_KUBE_CONTEXT`. `--kube-context` is the recommended form; see
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
