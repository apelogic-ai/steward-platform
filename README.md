# steward-platform

Coordination repository for installing the Steward governed-agent platform as a
whole. It holds a tested bill of materials (BOM) across the platform products and
their external dependencies, reference installs, end-to-end tests, and the
platform-level documentation that no single product owns.

## Scope

The platform is four independently released products:

| Product | Repository | Role |
|---|---|---|
| Steward | [apelogic-ai/steward](https://github.com/apelogic-ai/steward) | Kubernetes control plane: API, admission, controller, browser UI |
| steward-run | [apelogic-ai/steward-run](https://github.com/apelogic-ai/steward-run) | Governed job runner for GitHub Actions |
| github-oidc-exchange | [apelogic-ai/github-oidc-exchange](https://github.com/apelogic-ai/github-oidc-exchange) | Exchanges GitHub Actions OIDC tokens for task identity |
| mcp-gw | [apelogic-ai/mcp-gw](https://github.com/apelogic-ai/mcp-gw) | MCP gateway for governed tool access |

Two install profiles are defined:

- **core**: Steward alone, with a PostgreSQL database and cert-manager for its
  service certificates. No agent execution.
- **governed**: core plus the other three products and the external
  dependencies that governed execution needs (workload identity, sandboxing,
  inference proxy, runners). Not yet covered; see
  [#3](https://github.com/apelogic-ai/steward-platform/issues/3).

## Hard prerequisites

Check these before you start. Details and known gaps are in
[docs/prerequisites.md](docs/prerequisites.md).

- **amd64 nodes.** Steward images are linux/amd64 only.
- **Kubernetes 1.32 to 1.34**, the tested platform window.
- **A CNI that enforces NetworkPolicy**, with peers given as literal CIDRs.
- **PostgreSQL 16**, operated separately.
- **Google Workspace** for browser login, which is Google-only today. Governed
  use needs it.
- **GitHub.com** for governed jobs. GitHub Enterprise Server and GitLab are not
  supported.
- **PodSecurity `privileged` namespaces** for governed-mode runtimes and SPIRE.
- **A paid LLM API** for governed mode.

## Install

Read [docs/install-order.md](docs/install-order.md) for the sequence, then
use a reference install. Both install the core profile from the BOM, pinned by
digest, with every chart's values generated from one
[platform values](docs/platform-values.md) file.

- **helmfile** (the reference tool): [helmfile/README.md](helmfile/README.md).
  Evaluate on kind in three commands, or start from the production-shaped
  environment:

  ```sh
  kind create cluster --name steward --config environments/kind/kind-config.yaml \
    --image "$(jq -r '.kubernetes.tested | last | .nodeImage' bom/bom.json)"
  scripts/generate.sh environments/kind/platform-values.yaml
  helmfile --file helmfile/helmfile.yaml.gotmpl --environment kind \
    --kube-context kind-steward sync
  ```

  This is exactly what the core end-to-end test runs in CI, on an amd64 host.
- **Flux**: [examples/flux/core](examples/flux/core/README.md), the same
  install as `OCIRepository` and `HelmRelease` objects, generated from the BOM.

## What this repository owns, and what it does not

**Products own their contracts.** API shapes, chart values, CRDs, token formats,
configuration references, and upgrade notes live in the product repositories.
This repository links to them and tests them together. It never copies them. If
a product document is wrong or missing, the fix goes to that product.

This repository owns:

- the BOM: which exact product releases and dependency versions are tested
  together, pinned by digest;
- the BOM schema;
- end-to-end tests that install from the BOM and prove the combination works;
- platform prerequisites that follow from combining the products;
- the [platform values](docs/platform-values.md) file and the generator that
  turns it into every chart's values;
- reference installs (helmfile and Flux) and the
  [install order](docs/install-order.md);
- the platform release train (planned, see
  [#4](https://github.com/apelogic-ai/steward-platform/issues/4)).

## How to read the BOM

[`bom/bom.json`](bom/bom.json) is the tested bill of materials. Its format is
defined by [`schemas/bom/v1.schema.json`](schemas/bom/v1.schema.json).

| Field | Meaning |
|---|---|
| `platformVersion` | Calendar version of this combination, for example `2026.10.0`. Pre-releases carry `-alpha.N`, `-beta.N` or `-rc.N`. |
| `kubernetes` | Supported minor range (`minVersion`–`maxVersion`) and the exact versions and kind node images the end-to-end tests run on. |
| `products.<name>` | One product release: `version`, `source` repository, release `commit`, the `chart` (OCI reference, version, digest), `images` by component, the `provenance` (attestation signer and attested artifacts), and `minPeers` (minimum peer versions the product declares). |
| `dependencies.<name>` | One external dependency: upstream `version` and `source`, pinned `images`, `chart` or `manifests`, `usage` (`required`, `reference-install` or `evaluation-only`), and the profiles it is `requiredFor`. |
| `profiles.<name>` | Which products and dependencies an install profile includes. |

Install from the digests, not the tags. Tags are there for readers; the digest
is what was tested. For example, the core profile's Steward chart is
`products.steward.chart.reference` at `products.steward.chart.digest`, and each
image is the full `registry/repository:tag@sha256:...` string under
`products.steward.images`.

An `evaluation-only` dependency is used by tests and evaluation installs.
Production installs bring their own equivalent, for example a managed
PostgreSQL 16. A `reference-install` dependency, such as cert-manager, is
installed by the reference installs in every environment; an operator who
already runs it can keep their own.

CI validates the BOM, checks that every digest resolves anonymously, and
verifies the product attestations. See [docs/verification.md](docs/verification.md).

## Status

Pre-release. The current BOM (`2026.10.0-alpha.2`) pins the core profile only:
Steward 0.3.1, cert-manager for service TLS, and PostgreSQL 16 for evaluation.
There are no platform releases yet.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
