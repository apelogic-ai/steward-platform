# Fork and build from source

By default the platform installs each product's released chart and images,
pinned in [`bom/bom.json`](../bom/bom.json) by their upstream digests. An
operator who builds the products themselves, from public source at the BOM's
release commits or from a fork, and pushes them to their own registry, gets
**different digests**: a rebuild is not bit-for-bit the upstream artifact.
This page is how the platform consumes those builds.

It covers only what the platform adds: which commits to build, the
**built-artifacts lock** that records what you pushed, and how generation and
verification change. How to build each product is the product's own
documentation; this page links to it and does not repeat it.

Copying the upstream artifacts into your registry unchanged, with the same
digests, is a different case: that is a
[registry mirror](registry-mirroring.md), not a build. The two combine: the
built products from your registry and the external dependencies from a
mirror ([built products and a registry mirror](#built-products-and-a-registry-mirror)).

## 1. Build each product at its BOM commit

The platform deploys the charts and images of these products. For each one the
BOM records the source repository (`products.<name>.source`), the release
(`products.<name>.release`) and the exact commit of its release tag
(`products.<name>.commit`):

```sh
jq -r '.products | to_entries[] | "\(.key)\t\(.value.version)\t\(.value.source)\t\(.value.commit)"' bom/bom.json
```

| Product | Deployed by | How to build it (product documentation, at the BOM release) |
|---|---|---|
| Steward | every profile | [Build and publish from a fork](https://github.com/apelogic-ai/steward/blob/v0.3.13/docs/installation/installation-guide.md#build-and-publish-from-a-fork); the Codex reference runtime image: [Codex reference runtime](https://github.com/apelogic-ai/steward/blob/v0.3.13/docs/installation/codex-reference-runtime.md) |
| github-oidc-exchange | task-auth, browser-admin | [Build/publish fork-owned image and chart](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.5/docs/installation.md#1-buildpublish-fork-owned-image-and-chart) |

Build from the BOM commit, not from a branch or from a tag you retag
yourself: the generator compares the commit you record with the BOM's. Keep
the product's version numbers: the lock's product version and chart version
must equal the BOM's, because the platform generates values for exactly that
chart version.

Build every chart and image the BOM pins for a deployed product, including
ones the profile does not run yet (for Steward: `mint`, `bridge` and
`codex-reference-runtime`). The lock records the whole product, so a later
profile change does not silently fall back to upstream artifacts.

Not built: **steward-run** and **mcp-gw**. The platform does not deploy
steward-run's artifacts; it projects steward-run's signed release coordinates
into Steward (`config.apiserver.stewardRunRelease`), and Steward's
[contract](https://github.com/apelogic-ai/steward/blob/v0.3.13/docs/installation/governed-platform-compatibility.md)
requires that projection to equal the signed BOM coordinates, so they stay
upstream. steward-run 0.8.1 documents its own
[fork rebuild](https://github.com/apelogic-ai/steward-run/blob/v0.8.1/docs/customer-rebuild.md)
and publishes a vendorable reusable workflow for callers of a private fork
([private fork consumed by another repository](https://github.com/apelogic-ai/steward-run/blob/v0.8.1/docs/installation.md#private-fork-consumed-by-another-repository));
how an operator who uses only their own builds would run governed jobs with a
steward-run build is not decided yet
([#35](https://github.com/apelogic-ai/steward-platform/issues/35)). mcp-gw is pinned for the planned governed profile and no profile
installs it. The external dependencies (cert-manager, Envoy Gateway, the
Gateway API CRDs, PostgreSQL) are never built: they keep the BOM's digests,
pulled from upstream or from a registry mirror of them
([below](#built-products-and-a-registry-mirror)).

**A fork with changes.** If you build from a commit other than the BOM's, set
`allowSourceDrift: true` on that product in the lock. The generator accepts it
and warns, on every run, that the product is not the release the BOM tested.
The product and chart versions must still equal the BOM's.

## 2. Push to your registry and record the digests

Push each chart to an OCI registry and each image to a container registry you
control, then record the digest the registry reports for each push. Take the
digest from the push itself (for example the output of `helm push`, or
`crane digest REF` right after the push); never reconstruct it from a tag.

For Steward, push the `apiserver`, `controller` and `web` images to **one
repository**: Steward's chart takes a single `images.repository` for them.

## 3. Write the lock

The built-artifacts lock is a JSON file that matches
[`schemas/built-lock/v1.schema.json`](../schemas/built-lock/v1.schema.json).
Per product: the version, the source repository you built from, the commit,
optionally `allowSourceDrift`, the chart (`reference`, `version`, `digest`)
and each image as `registry/repository@sha256:<digest>`, optionally with a tag
before the digest. [`examples/built/built-lock.json`](../examples/built/built-lock.json)
is a complete example with placeholder references under `registry.example.com`.

[`scripts/built-lock-from-digests.sh`](../scripts/built-lock-from-digests.sh)
writes one from `name=value` pairs, and checks it against the schema and the
BOM:

```sh
scripts/built-lock-from-digests.sh --profile task-auth \
  steward.source=https://github.com/example-org/steward \
  steward.commit="$(jq -r .products.steward.commit bom/bom.json)" \
  steward.chart=oci://registry.example.com/charts/steward@sha256:<digest> \
  steward.images.apiserver=registry.example.com/steward:0.3.13-apiserver@sha256:<digest> \
  steward.images.controller=registry.example.com/steward:0.3.13-controller@sha256:<digest> \
  ... \
  github-oidc-exchange.source=https://github.com/example-org/github-oidc-exchange \
  github-oidc-exchange.commit="$(jq -r '.products["github-oidc-exchange"].commit' bom/bom.json)" \
  github-oidc-exchange.chart=oci://registry.example.com/charts/github-oidc-exchange@sha256:<digest> \
  github-oidc-exchange.images.exchange=registry.example.com/github-oidc-exchange@sha256:<digest> \
  > built-lock.json
```

A chart reference without a version takes the BOM's chart version. Each
product's version is the BOM's. Pass `PRODUCT.allowSourceDrift=true` for a
fork with changes. With `--profile`, the helper fails, listing each missing
chart and image, unless the lock covers every product that profile deploys.

## 4. Generate in built mode

Add an `artifacts` block to your platform values:

```yaml
artifacts:
  source: built
  # Absolute, or relative to this platform values file.
  builtLock: built-lock.json
```

Then generate as usual:

```sh
scripts/generate.sh environments/<your-environment>/platform-values.yaml
```

The generator checks the lock against its schema and against the BOM before
it writes anything, and fails, listing every problem, when:

- a chart or image of a product the profile deploys is missing from the lock;
- a product's version or chart version is not the BOM's;
- a commit is not the BOM's, without `allowSourceDrift`;
- the lock lists an image, a product or a chart the BOM does not pin, or
  steward-run;
- Steward's `apiserver`, `controller` and `web` images are in different
  repositories.

The output is then exactly what BOM mode generates, with each product chart
and image reference replaced by the lock's, and one more header line in each
generated file naming the lock. Profiles, values, the helmfile, the Flux
objects, the external dependencies and steward-run's projected coordinates
are unchanged. `tests/built/run.sh` checks this for every committed
environment.

Without an `artifacts` block, or with `source: bom`, nothing changes: the
output is byte-identical to BOM mode.

**Pulling from a private registry.** The lock names references only, never
credentials. The nodes must be able to pull the images: with node-level
registry credentials, or with `registry.imagePullSecrets` in the platform
values, which every BOM chart's workloads pull with, the built products
included (a `registry` block may hold only that field; see
[registry mirroring](registry-mirroring.md#credentials)). The tool that
installs the charts must be able to pull them too: Helm's registry login
(`helm registry login`) for the helmfile, and access from Flux's source
controller for the Flux output. The generated product `OCIRepository`
objects carry no `secretRef`, because the `flux` settings of the platform
values belong to `registry.productCharts`, which built mode refuses (next
section); give the source controller access to your registry yourself, for
example with a Kustomize patch that adds `spec.secretRef` or `spec.provider`
to those two objects.

## Built products and a registry mirror

To pull the external dependencies from your own registry as well, mirror them
with the `registry` block of the platform values, next to `artifacts`: copy
them with their BOM digests and point the generator at the copy, as
[registry mirroring](registry-mirroring.md) describes.

```yaml
artifacts:
  source: built
  builtLock: built-lock.json
registry:
  dependencyImages:
    prefix: registry.example.com/steward-platform
    keepSourceHost: true
  dependencyCharts:
    prefix: registry.example.com/steward-platform
    keepSourceHost: true
  imagePullSecrets: [registry-example-com]
```

- **Product classes are refused.** The lock already names the final location
  of every product chart and image; `registry.productImages` or
  `registry.productCharts` would move them a second time, so the schema
  refuses either one with `source: built`. The other classes
  (`dependencyImages`, `dependencyCharts`, `gitSources`, `manifests`) and
  `imagePullSecrets` compose with built mode: the output is the mirrored
  BOM-mode output with only the product references replaced by the lock's.
- **The copy list leaves the built products out.** In built mode,
  `scripts/mirror-list.sh` does not list the charts and images of the
  products in the lock, since you push them yourself; it still lists
  everything else, steward-run included.
- **Checking.** `scripts/verify-digests.sh --mirror PLATFORM_VALUES` checks
  the built products against the lock that the values name, as
  `--built-lock` does, and every mirrored artifact in the mirror, both with
  your own registry credentials. `scripts/verify-digests.sh --built-lock
  built-lock.json` checks the same lock and the rest of the BOM upstream,
  anonymously. The two flags are not combined.

`tests/built/run.sh` runs its built-mode checks on
[`environments/production-mirrored`](../environments/production-mirrored/platform-values.yaml)
without its product classes, and checks the refusals, the copy list and
`verify-digests.sh --mirror` in built mode.

## Verification

The upstream checks prove properties of the **upstream** artifacts: an
attestation or a signature names an upstream digest, signed by the product's
release workflow. They say nothing about an artifact you built, so for built
products they do not apply, and the scripts say so instead of passing:

| Check | With `--built-lock built-lock.json` |
|---|---|
| [`scripts/verify-digests.sh`](../scripts/verify-digests.sh) | The built products are checked against the lock by [`scripts/verify-built-lock.sh`](../scripts/verify-built-lock.sh): the lock matches its schema and the BOM, every chart and image resolves in your registry at its lock digest (with your own registry credentials), and each chart is a Helm chart. A tag written before a digest that now points elsewhere warns; the digest is what gets installed. Their upstream BOM artifacts are not checked. Everything else in the BOM is checked anonymously, as without the flag. With `--mirror PLATFORM_VALUES` for platform values in built mode, the built products are checked against the values' lock the same way, and the mirrored artifacts in the mirror ([above](#built-products-and-a-registry-mirror)). |
| [`scripts/verify-attestations.sh`](../scripts/verify-attestations.sh) | Each artifact of a built product is reported as `SKIP ... built from source`, and the summary counts them. Other products are verified as usual. |
| [`scripts/verify-signatures.sh`](../scripts/verify-signatures.sh) | Each built product is reported as `SKIP ... built from source`, and the summary counts them. steward-run, which is never built, is still verified: its signed coordinates are what Steward receives. |

```sh
scripts/verify-built-lock.sh --profile task-auth built-lock.json
scripts/verify-digests.sh --built-lock built-lock.json
scripts/verify-attestations.sh --built-lock built-lock.json
scripts/verify-signatures.sh --built-lock built-lock.json
```

`scripts/verify-built-lock.sh --offline` runs only the schema and BOM checks,
without a registry.

What replaces the upstream checks is yours to provide: the provenance of your
own build (for example attestations from your build workflow for your
digests), which the products' build documentation describes for forks.

## Gotchas

- **Digest, not tag.** The digest is what gets installed. An image written
  without a tag renders with the BOM's tag in front of your digest; the
  container runtime ignores a tag when a digest is present.
- **Chart version, not application version.** `chart.version` is the chart's
  `Chart.yaml` version, which must equal the BOM's `products.<name>.chart.version`.
- **Rebuild on every BOM bump.** A new BOM moves the release commits and
  versions; a lock for the old BOM fails the checks until you rebuild and
  rewrite it.
