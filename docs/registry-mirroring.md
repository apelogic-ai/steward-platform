# Registry mirroring

Install the platform from your own registry mirror instead of the upstream
registries, with the same digests the BOM pins. This page covers the whole
platform: the products, cert-manager, Envoy Gateway, the Gateway API CRDs and
the evaluation PostgreSQL. Steward's own
[registry mirroring](https://github.com/apelogic-ai/steward/blob/v0.3.13/docs/installation/registry-mirroring.md)
(`steward-registry-lock.sh`) covers only Steward's chart, images and reference
runtimes; see [Steward's registry lock](#stewards-registry-lock) below.

The steps:

1. Describe the mirror in the `registry` block of your
   [platform values](platform-values.md).
2. List the artifacts with [`scripts/mirror-list.sh`](../scripts/mirror-list.sh)
   and copy them, digests intact.
3. Check the mirror with `scripts/verify-digests.sh --mirror`.
4. Generate and install as usual. Every chart values file, the helmfile inputs
   and the Flux objects then reference the mirror.

[`environments/production-mirrored`](../environments/production-mirrored/platform-values.yaml)
is a complete example, and [`examples/flux/mirrored`](../examples/flux/mirrored/README.md)
is its Flux output.

## The registry block

One override per artifact class. A class that is not set is pulled from
upstream, as the BOM names it, so a partial mirror works too. Without a
`registry` block the generated output is exactly what it was before the block
existed.

| Class | Artifacts | Where the generator applies it |
|---|---|---|
| `productImages` | `products.<name>.images`: Steward, github-oidc-exchange (and steward-run and mcp-gw in the mirror list) | Steward `images.repository` (one repository for all its images), github-oidc-exchange `image.repository` |
| `productCharts` | `products.<name>.chart` | helmfile chart references; Flux `OCIRepository` |
| `dependencyImages` | `dependencies.<name>.images`, and the images of every other tested version (`dependencies.<name>.tested`): cert-manager, Envoy Gateway, PostgreSQL | cert-manager `*.image.repository`, Envoy Gateway `global.images.*.image`, evaluation PostgreSQL `image.repository` |
| `dependencyCharts` | `dependencies.<name>.chart`: cert-manager, Envoy Gateway | helmfile chart references; Flux `OCIRepository`, including the one the Envoy Gateway CRD `Kustomization` extracts its CRDs from |
| `gitSources` | the Git `fluxSource` of the Gateway API CRDs, and this repository at the platform tag for `charts/steward-edge` | Flux `GitRepository` |
| `manifests` | `dependencies.<name>.manifests[].url`: the Gateway API and Envoy Gateway CRD manifests | the helmfile's CRD hook (`scripts/apply-manifests.sh --url`) |

```yaml
registry:
  productImages:
    prefix: registry.example.test/steward-platform
  productCharts:
    prefix: registry.example.test/steward-platform
    flux:
      secretRef: {name: registry-example-test}
  dependencyImages:
    prefix: registry.example.test/steward-platform
    keepSourceHost: true
  dependencyCharts:
    prefix: registry.example.test/steward-platform
    keepSourceHost: true
    flux:
      secretRef: {name: registry-example-test}
  gitSources:
    prefix: https://git.example.test/mirrors
    keepSourceHost: true
    flux:
      secretRef: {name: git-example-test}
  manifests:
    prefix: https://files.example.test/mirrors
    keepSourceHost: true
  imagePullSecrets: [registry-example-test]
```

The schema is
[`schemas/platform-values/v1.schema.json`](../schemas/platform-values/v1.schema.json).

### The rewrite

An override changes only the registry or host and the leading path of a
reference. The tag, the digest and a Git commit stay exactly the BOM's, so
what you install is what CI tested.

| `keepSourceHost` | Upstream | Mirrored |
|---|---|---|
| `false` (default): the prefix replaces the upstream registry | `ghcr.io/apelogic-ai/steward:0.3.13-apiserver@sha256:9546…` | `registry.example.test/steward-platform/apelogic-ai/steward:0.3.13-apiserver@sha256:9546…` |
| `true`: the upstream host becomes the first path segment | `quay.io/jetstack/cert-manager-controller:v1.21.2@sha256:70f5…` | `registry.example.test/steward-platform/quay.io/jetstack/cert-manager-controller:v1.21.2@sha256:70f5…` |
| `true`, a Git source | `https://github.com/kubernetes-sigs/gateway-api` | `https://git.example.test/mirrors/github.com/kubernetes-sigs/gateway-api` |

`keepSourceHost: true` never collides, which matters for the dependencies:
they come from several registries (`quay.io`, `docker.io`). The generator
refuses a mirror that maps two different upstream artifacts onto one target.

An OCI prefix is a registry host with a dot (or `localhost`), an optional
port and an optional path, without a scheme: `registry.example.test/team`.
Git and manifest prefixes are `https://` URLs. For Git mirrors whose names do
not follow a prefix, `gitSources.repositories` maps each upstream repository
URL to its mirror URL exactly, and takes precedence over `prefix`.

### What is not rewritten

- **Steward's `stewardRunRelease.governedJobContainerImage`** (browser-admin).
  Steward requires its coordinates to be steward-run's signed release manifest,
  field for field
  ([compatibility contract](https://github.com/apelogic-ai/steward/blob/v0.3.13/docs/installation/governed-platform-compatibility.md)),
  so it keeps the upstream reference. The GitHub Actions job that runs it
  pulls it, not the cluster. The mirror list still lists the runner image.
- **Envoy Gateway's rate-limit image** (`global.images.ratelimit`). The BOM
  does not pin it and the platform does not enable rate limiting. If you
  enable it, pin and mirror that image yourself.
- **Kubernetes node images** (`kubernetes.tested[].nodeImage`). They are for
  the kind tests, not for installs, and are not in the mirror list.

## Credentials

Credentials are referenced by name, never written into the platform values.
The schema has no field for a credential value.

- **Workloads**: `registry.imagePullSecrets` names
  `kubernetes.io/dockerconfigjson` Secrets. Create them yourself in every
  namespace a chart installs into: Steward's, cert-manager's, the exchange's,
  and the edge namespace for Envoy Gateway. The generator passes them to each
  chart's own key: Steward `imagePullSecrets`, cert-manager
  `global.imagePullSecrets` (on its service accounts), github-oidc-exchange
  `image.pullSecrets`, and Envoy Gateway `global.imagePullSecrets`, which also
  reaches the Envoy proxies it creates. Leave the field out when the nodes
  already authenticate to the mirror, for example through a kubelet image
  credential provider.
- **Flux**: per chart class, `flux.secretRef` names a
  `kubernetes.io/dockerconfigjson` Secret in `flux-system`. Instead,
  `flux.provider: aws`, `azure` or `gcp` lets the source controller use its
  cloud workload identity (the schema refuses a Secret alongside a cloud
  provider). `flux.certSecretRef` names a Secret with the `ca.crt` of a mirror
  that uses a private certificate authority. For Git, `gitSources.flux.secretRef`
  names a Secret with the Git credentials. See Flux's
  [OCIRepository](https://fluxcd.io/flux/components/source/ocirepositories/)
  and [GitRepository](https://fluxcd.io/flux/components/source/gitrepositories/)
  references.
- **helmfile**: Helm pulls the charts with its own registry credentials:
  `helm registry login <host>`, a credentials file named by
  `HELM_REGISTRY_CONFIG`, or the Docker configuration. With a chart mirror, the
  generated helmfile also declares one OCI repository per chart class, and
  helmfile runs `helm registry login` for it when both of its variables are
  set in the environment: `STEWARD_PLATFORM_PRODUCT_CHARTS_USERNAME` and
  `_PASSWORD`, and `STEWARD_PLATFORM_DEPENDENCY_CHARTS_USERNAME` and
  `_PASSWORD`. The password goes to Helm on standard input.
- **CRD manifests** (helmfile): `scripts/apply-manifests.sh` passes
  `PLATFORM_NETRC_FILE`, a netrc file, to curl when it is set.
- **Copying and checking**: crane, oras and skopeo use your Docker
  configuration (`DOCKER_CONFIG`) or their own login. `verify-digests.sh
  --mirror` reads it too.

## Copy the artifacts

`scripts/mirror-list.sh PLATFORM_VALUES` prints every artifact in the BOM, with
its source and its target in your mirror, as JSON
(`steward-platform/mirror-list/v1`). It covers the product and dependency
charts and images, the images of every tested PostgreSQL version, the CRD
manifests and the Git sources, including mcp-gw, which is pinned for a later
profile. It narrows the list with these flags:

- `--profile NAME`: the artifacts of one BOM profile;
- `--installed`: only what the install generated from these platform values
  pulls. For core that is Steward's apiserver and controller images (not its
  other images), cert-manager, and the evaluation PostgreSQL image only with
  the evaluation database;
- `--mirrored`: only the classes the platform values mirror.

```json
{
  "id": "products.steward.images.apiserver",
  "class": "productImages",
  "type": "oci",
  "artifact": "image",
  "source": "ghcr.io/apelogic-ai/steward:0.3.13-apiserver",
  "digest": "sha256:95460e3997c86e976d319c1b9569121b737adad9fb4225c4fdbbc9e9054b5ea4",
  "sourceRef": "ghcr.io/apelogic-ai/steward@sha256:95460e3997c86e976d319c1b9569121b737adad9fb4225c4fdbbc9e9054b5ea4",
  "target": "registry.example.test/steward-platform/apelogic-ai/steward:0.3.13-apiserver",
  "targetRef": "registry.example.test/steward-platform/apelogic-ai/steward@sha256:95460e3997c86e976d319c1b9569121b737adad9fb4225c4fdbbc9e9054b5ea4",
  "mirrored": true
}
```

**OCI charts and images** (`"type": "oci"`). Copy `sourceRef` to `target`.
Copy the whole artifact, every platform of a multi-platform image included:
narrowing to one platform creates a new manifest with a different digest,
which the install would not find. Any of these works:

```sh
scripts/mirror-list.sh --mirrored environments/<name>/platform-values.yaml > mirror-list.json
jq -r '.artifacts[] | select(.type == "oci") | [.sourceRef, .target] | @tsv' mirror-list.json |
  while IFS=$'\t' read -r source target; do
    crane copy "${source}" "${target}"
    # or: oras cp -r "${source}" "${target}"   (also copies signatures and attestations)
    # or: skopeo copy --all --preserve-digests "docker://${source}" "docker://${target}"
  done
```

Before copying, check whether the target tag already exists. If it resolves
to the planned digest, skip it; if it resolves to another digest, stop, and
do not overwrite it. `verify-digests.sh --mirror` reports both cases.

**CRD manifests** (`"type": "http"`, helmfile). Download `source`, check its
SHA-256 against `digest`, and publish it at `target` on your file server or
generic artifact repository. The helmfile hook checks the digest again.

**Git sources** (`"type": "git"`, Flux). Mirror the repository with its tags,
for example `git clone --mirror SOURCE && git -C <dir> push --mirror TARGET`,
or let your Git server mirror it. The `GitRepository` pins the BOM commit
(`ref.commit`). For `charts/steward-edge` it pins this repository's platform
tag (`ref.tag`), so that tag must be in the mirror.

Git-sourced CRDs have two more options. Point `gitSources.repositories` at a
repository you already mirror under another name. Or, if you install with the
helmfile, you need no Git at all: it applies the same CRDs from the
`manifests` mirror. The Envoy Gateway CRDs need no Git source either: Flux
extracts them from the Envoy Gateway chart, so they come from the
`dependencyCharts` mirror.

## Check the mirror

```sh
scripts/verify-digests.sh --mirror environments/<name>/platform-values.yaml            # the whole BOM
scripts/verify-digests.sh --mirror environments/<name>/platform-values.yaml --installed # what this install pulls
```

For every mirrored artifact, it checks that:

- the chart or image resolves in the mirror at its BOM digest (crane verifies
  the manifest against the digest), and a chart is a Helm chart;
- the mirror's tag, when present, points at that digest (a tag that points
  elsewhere fails);
- a manifest downloads from the mirror with its BOM SHA-256;
- a Git mirror carries the tag at the BOM commit.

It authenticates with your own credentials, unlike the default mode, which
checks upstream anonymously. Classes that are not mirrored are skipped.

## Products built from source

With products built from source (`artifacts.source: built`,
[fork and build from source](fork-and-build.md#built-products-and-a-registry-mirror)),
the built-artifacts lock names where the products are, so the schema refuses
`registry.productImages` and `registry.productCharts`. The other classes and
`imagePullSecrets` still apply. `scripts/mirror-list.sh` then leaves the
built products out of the list, and `verify-digests.sh --mirror` checks them
against the lock instead.

## Steward's registry lock

Steward's `steward-registry-lock.sh` plans and copies Steward's own release
artifacts with ORAS, from a mapping (`steward.registry-mappings/v1`) that must
name exactly those artifacts. It records a deployment lock. It does not cover
github-oidc-exchange, steward-run, mcp-gw or any dependency. You can use it for
the Steward part of the mirror list: map each Steward artifact to the
`target` the mirror list gives, so that the generator references what the
tool copied. Do not use its `--platform` narrowing with this generator: a
narrowed copy has different digests from the BOM's.

## How CI tests it

- [`tests/generate/run.sh`](../tests/generate/run.sh) generates the mirrored
  environment and its variants. It checks that every workload image the
  charts render, and every chart the helmfile installs, is its BOM reference
  in the mirror with the BOM digest. It also checks the image pull Secrets,
  the CRD downloads from the manifests mirror, the registry logins, and the
  inputs the generator must refuse.
- [`tests/flux/run.sh`](../tests/flux/run.sh) runs every Flux example check on
  [`examples/flux/mirrored`](../examples/flux/mirrored/README.md). It checks
  that every `OCIRepository` and `GitRepository` points at the mirror with its
  class's credentials and the BOM digest or commit, and that the charts run
  only BOM images from the mirror.
- One [core end-to-end](../tests/e2e/core/README.md) run (`MIRROR=1`) installs
  from a real mirror. It runs a local registry, copies what the install pulls
  with the mirror list, checks the copy with `verify-digests.sh --mirror`, and
  installs core with the helmfile from the mirror. It then asserts that the
  pods run the BOM digests pulled from the mirror host.

## Limits

- The schema requires HTTPS for Git and manifest mirrors. A plain-HTTP OCI
  mirror works only on `localhost` (crane and Helm use HTTP there without extra
  flags), as in the end-to-end test. The generator has no Flux `insecure`
  setting.
- The evaluation database chart in this repository
  (`charts/postgresql-evaluation`) takes no image pull Secret. For an
  evaluation install from an authenticated mirror, give the nodes credentials
  for the mirror.
