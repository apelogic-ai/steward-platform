# Changelog

Platform versions of the Steward platform BOM. Each entry is one
`platformVersion` of [`bom/bom.json`](bom/bom.json); the BOM at that version
is authoritative for every pinned version and digest.

## Unreleased

## 2026.10.0-alpha.10

Release notes:
[docs/releases/2026.10.0-alpha.10.md](docs/releases/2026.10.0-alpha.10.md).
No breaking changes for the implemented profiles. A BOM bump to Steward 0.3.8
and mcp-gw 0.5.7; the generator, helmfile, Flux output and platform values
schema are unchanged.

- Steward 0.3.8 (from 0.3.5; 0.3.6 and 0.3.7 were incomplete publications):
  Next.js 16.3.6 for the critical advisory `GHSA-vcvr-r3jv-pc5j`, browser Run
  now, member administration, automatic GitHub identity association through
  Connect (governed only), `403 task_identity_unknown_user` for a verified v2
  credential with an unknown canonical user, and additive migrations 0052 to
  0063. Back up the database before upgrading; rolling back to 0.3.5 needs a
  restore. Governed installs must set `spire.className` and choose one owner
  for the OpenShell sandbox `ClusterSPIFFEID`. The generated values change only
  in image tags and digests.
- mcp-gw 0.5.7 (from 0.5.4; 0.5.5 published no chart), still
  `plannedFor: governed`: numeric GitHub account ID in opt-in connection-status
  v2 with forward-only migration 008, stable lifecycle error codes, and an
  attested GitHub governance catalog asset that the BOM does not pin.
- github-oidc-exchange 0.7.5 and steward-run 0.7.6 are unchanged.
- The Flux examples and the example built-artifacts lock are regenerated for
  the new coordinates, and Steward documentation links move to the v0.3.8 tag
  with recomputed source line anchors. The walkthrough mentions the new member
  page for identity association, and the task-auth profile page reflects the
  new unknown-user answer. The migration runbook adds the alpha.10 upgrade
  notes.
- Kubernetes: the tested window stays 1.32 to 1.34 (#34).

## 2026.10.0-alpha.9

Release notes:
[docs/releases/2026.10.0-alpha.9.md](docs/releases/2026.10.0-alpha.9.md).
No breaking changes for the implemented profiles. A BOM bump to the Steward
0.3.5 security patch and mcp-gw 0.5.4; the generator, helmfile, Flux output
and platform values schema are unchanged.

- Steward 0.3.5 (from 0.3.4): security patch. The apiserver and controller
  ClusterRoles no longer grant Kubernetes user and group impersonation;
  AgentRuntime writes use the exact Steward service-account identities and
  stay subject to the webhook checks. No migration, no provider-profile
  transition and no chart value change; the v0.3.4 contracts are retained.
  During a rolling upgrade, retry rejected writes once the apiserver and
  controller have converged (Steward changelog upgrade note).
- mcp-gw 0.5.4 (from 0.5.1), still `plannedFor: governed`: restores the
  Google Workspace tools broken in 0.5.2 (apelogic-ai/mcp-gw#100), recovers
  the HOP-1 JWKS without an agentgateway restart, and resolves wrapper apt
  packages from a dated snapshot. 0.5.3 was never published.
- github-oidc-exchange 0.7.5 and steward-run 0.7.6 are unchanged.
- The Flux examples and the example built-artifacts lock are regenerated for
  the new coordinates, and Steward documentation links move to the v0.3.5
  tag. The migration runbook points to the alpha.7, alpha.8 and alpha.9
  upgrade notes in order.
- The dogfood release summary workflow pins steward-run 0.7.6's self-hosted
  reusable workflow (commit `fbfd6c0`, from 0.7.5); its inputs are
  unchanged.
- Kubernetes: the tested window stays 1.32 to 1.34 (#34).

## 2026.10.0-alpha.8

Release notes:
[docs/releases/2026.10.0-alpha.8.md](docs/releases/2026.10.0-alpha.8.md).
No breaking changes for the implemented profiles. A BOM bump to the current
Steward, github-oidc-exchange and steward-run patch releases; the generator,
helmfile, Flux output and platform values schema are unchanged.

- Steward 0.3.4 (from 0.3.3): no migration. **Required action** for
  execution-enabled installs, which no profile here is: the
  `steward-workflows` namespace must exist and be in `runtimeNamespaces`, or
  the chart refuses the values. Fixes the 0.3.3 known issues (the apiserver
  crash-loop on an empty `anthropicInferenceEndpoint`,
  apelogic-ai/steward#212, and the HTTPS-only LiteLLM management URL that the
  chart NetworkPolicy could not reach, apelogic-ai/steward#213) and restores
  the HyperShell branding in the web UI. Governed installs move to
  provider-profile bundle 1.2.2.
- github-oidc-exchange 0.7.5 (from 0.7.4): non-breaking. Policy v6 gains
  opt-in owner-wide admission (`repository_id: "*"`) and reusable-workflow
  selectors; readiness also checks the GitHub JWKS age and the Lease API. The
  new `config.githubJwksMaxStalenessSeconds` keeps its default. Audit reasons
  are unchanged.
- steward-run 0.7.6 (from 0.7.5): a vendorable reusable workflow
  (`steward-task-vendored.yml`) for callers of a private fork, exchange
  `4xx` failures classified instead of retried, and signed job container
  publication. Action inputs are unchanged; the action and workflow commits
  are the tag commit, so Steward's projected `stewardRunRelease` changes, and
  the signer identity moves to `refs/tags/v0.7.6`.
- mcp-gw stays at 0.5.1 (`plannedFor: governed`); 0.5.4 follows in a later
  alpha once its release is complete.
- The Flux examples and the example built-artifacts lock are regenerated for
  the new coordinates, and product documentation links move to the new
  release tags. The task-auth profile page and test comment note the new v6
  selectors, which the test does not use. The migration runbook points to the
  alpha.7 and alpha.8 upgrade notes in order.
- Kubernetes: the tested window stays 1.32 to 1.34 (#34).

## 2026.10.0-alpha.7

Release notes:
[docs/releases/2026.10.0-alpha.7.md](docs/releases/2026.10.0-alpha.7.md).
No breaking changes for the implemented profiles. A BOM bump to the current
product patch releases; the generator, helmfile, Flux output and platform
values schema are unchanged.

- Steward 0.3.3 (from 0.3.2): no migration and no chart change apart from the
  version. Governed execution, which no profile here runs, gets a stricter
  preflight and requires provider-profile bundle 1.2.1.
- github-oidc-exchange 0.7.4 (from 0.7.2): the default egress policy allows
  the API server on TCP 443 and 6443 over IPv4 and IPv6
  (apelogic-ai/github-oidc-exchange#58), DNS replies are admitted from the
  DNS peers, and `keyring-tool` ships in the image. The new chart values keep
  their defaults.
- steward-run 0.7.5 (from 0.7.2): fixes CVE-2026-75803 in the runner image and
  re-pins the job container; action inputs are unchanged. The action and
  workflow commits are both the tag commit, so Steward's projected
  `stewardRunRelease` changes, and the signer identity is now
  `portable-release.yml` at the release tag.
- mcp-gw 0.5.1 (from 0.5.0), still `plannedFor: governed`; not 0.5.2, because
  of apelogic-ai/mcp-gw#100.
- The Flux examples and the example built-artifacts lock are regenerated for
  the new coordinates, and product documentation links move to the new
  release tags. The migration runbook still targets the alpha.6 product set
  and points to the alpha.7 upgrade notes.
- Kubernetes: the tested window stays 1.32 to 1.34; 1.35 is not tested again
  yet (#34).

## 2026.10.0-alpha.6

Release notes:
[docs/releases/2026.10.0-alpha.6.md](docs/releases/2026.10.0-alpha.6.md).
No breaking changes, and the same product releases as 2026.10.0-alpha.5:
Steward 0.3.2, github-oidc-exchange 0.7.2, steward-run 0.7.2 and mcp-gw
0.5.0 (`plannedFor`), with the same digests.

- Flux output for the task-auth and browser-admin profiles, next to core:
  new examples [`examples/flux/task-auth`](examples/flux/task-auth) and
  [`examples/flux/browser-admin`](examples/flux/browser-admin). The helmfile's
  Gateway API and Envoy Gateway CRD hook becomes Flux `Kustomization`s from a
  pinned `fluxSource` that each BOM manifest now carries, and
  `charts/steward-edge` is built from this repository at the tag of the
  `platformVersion`.
- PostgreSQL 17 tested. The BOM states a minimum PostgreSQL version (16) and
  the exact tested versions, 16.14 (the default, unchanged) and 17.11, each
  pinned by digest; the core end-to-end test runs on both. The optional
  platform values field `database.evaluationVersion` picks the version the
  evaluation database runs.
- Documentation: a migration runbook from pre-platform (0.2.6-era) installs,
  [docs/upgrades/from-pre-platform.md](docs/upgrades/from-pre-platform.md),
  and the
  [known security limitations](docs/prerequisites.md#known-security-limitations).
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
