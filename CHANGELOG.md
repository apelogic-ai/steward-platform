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
