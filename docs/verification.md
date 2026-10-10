# How the BOM is verified

CI runs these checks on every pull request, on every push to `main`, and
nightly. All of them run on GitHub-hosted `ubuntu-latest` (linux/amd64)
runners. You can run all of them locally; the end-to-end test needs an amd64
host.

| Check | Script | What it proves |
|---|---|---|
| Schema and cross-references | [`scripts/validate-bom.sh`](../scripts/validate-bom.sh) | The BOM matches [`schemas/bom/v1.schema.json`](../schemas/bom/v1.schema.json). Profiles reference only pinned entries, every product is either in a profile or `plannedFor` a profile the BOM does not define yet (never both), `requiredFor` matches the profiles, attestation subjects exist, declared minimum peer versions hold, and the tested Kubernetes versions cover both ends of the supported range. |
| Digests | [`scripts/verify-digests.sh`](../scripts/verify-digests.sh) | Every chart, image, node image and manifest pinned in the BOM resolves anonymously at its digest. A product tag that moved away from the pinned digest fails. A dependency or node image tag that moved only warns, because those upstreams rebuild tags; the pinned digest is still what gets installed. With `--mirror PLATFORM_VALUES` it checks your registry mirror instead, with your credentials: every mirrored artifact resolves there at its BOM digest, and a mirror tag that points elsewhere fails ([registry mirroring](registry-mirroring.md#check-the-mirror)). With `--built-lock LOCK`, products built from source are checked against the lock instead of upstream ([fork and build from source](fork-and-build.md#verification)). |
| Attestations | [`scripts/verify-attestations.sh`](../scripts/verify-attestations.sh) | For products that publish GitHub artifact attestations (Steward and mcp-gw): each artifact listed in `products.<name>.provenance.subjects` has a GitHub artifact attestation with the declared predicate type, signed by the declared workflow at the declared tag, built on a GitHub-hosted runner, from the product repository at the pinned commit. |
| Signatures | [`scripts/verify-signatures.sh`](../scripts/verify-signatures.sh) | For products that sign with cosign instead of GitHub artifact attestations (github-oidc-exchange and steward-run): the release tag is the pinned commit; the release manifest verifies against its Sigstore bundle, signed by the declared workflow at the pinned commit; the signed manifest names the pinned version, commit, every pinned digest and, for steward-run, the pinned action commit, and carries exactly the pinned `workflow` repository and commit and `schemaVersion`, so that Steward's `stewardRunRelease` projection from the BOM equals the signed manifest field for field; and each listed chart and image bundle verifies for its pinned digest. |
| Generator and helmfile | [`tests/generate/run.sh`](../tests/generate/run.sh) | Every `environments/*/platform-values.yaml`, plus a customer-supplied-TLS variant, generates deterministically, and the generated values pass `helm lint` and `helm template` with the BOM-pinned charts pulled by digest, so each chart's own values schema applies. The [helmfile](../helmfile/README.md) builds and renders every committed environment and installs each BOM chart at its BOM digest. The generator refuses reserved governed fields, the governed profile, evaluation pieces in production, browser login outside the browser-admin profile, a personal Google domain, unrestricted browser-auth egress in production, and a CA bundle that contains a private key. For browser-admin it checks the rendered browser login, web image, steward-run release projection and Steward's routes. For a registry mirror, every workload image and helmfile chart is its BOM reference in the mirror at its BOM digest, with the image pull Secrets, the CRD downloads from the manifests mirror and the registry logins; colliding or malformed mirrors are refused. The platform values of every platform release tag still validate and generate byte-identically to that tag's generator. See [platform values](platform-values.md). |
| Built artifacts | [`tests/built/run.sh`](../tests/built/run.sh) | For every `environments/*/platform-values.yaml` (with a registry mirror, less its product classes, which built mode refuses): `artifacts.source: bom` generates exactly the output without an `artifacts` block; built mode with a lock of the BOM's own references generates exactly the BOM-mode output apart from one header line; and built mode with [`examples/built/built-lock.json`](../examples/built/built-lock.json) replaces exactly the product chart and image references, leaves no upstream digest of a built product, and keeps steward-run's signed coordinates. The generator refuses a lock that misses a chart or image of a deployed product, pins another version, chart version or (without `allowSourceDrift`) commit, lists steward-run or what the BOM does not pin, or splits Steward's images across repositories. With a registry mirror, built mode refuses a mirror of the product charts or images and keeps the dependency image mirror and image pull Secrets; `mirror-list.sh` leaves the built products out; and `verify-digests.sh --mirror`, with a stand-in registry client, checks the built products against the lock and the mirrored rest in the mirror. `verify-signatures.sh` and `verify-attestations.sh --built-lock` report built products as skipped. See [fork and build from source](fork-and-build.md). |
| Flux examples | [`tests/flux/run.sh`](../tests/flux/run.sh) | [`examples/flux/core`](../examples/flux/core/README.md), [`task-auth`](../examples/flux/task-auth/README.md), [`browser-admin`](../examples/flux/browser-admin/README.md) and [`mirrored`](../examples/flux/mirrored/README.md) match a fresh generation from the BOM and validate strictly against the pinned Flux CRD schemas. Each has exactly the helmfile's releases for the same environment, with `dependsOn` equal to the helmfile `needs` and the same generated values; each BOM chart is pinned by its BOM digest and renders with the BOM image digests; Steward's CRD is created on install and skipped on upgrade. Each CRD manifest of the helmfile's presync hook is a `Kustomization`, in hook order, whose BOM `fluxSource`, at its pin, holds exactly the objects of the manifest downloaded at its SHA-256; and `charts/steward-edge` at the platform tag is the checkout's chart. In the mirrored example, every source points at the mirror with its class's credentials and every workload image is a BOM image from the mirror. |
| Flux reconcile | [`tests/flux/reconcile.sh`](../tests/flux/reconcile.sh) | In kind, the pinned Flux release reconciles the edge part of the task-auth example: both CRD `Kustomization`s apply every object of their BOM manifests, Envoy Gateway runs its BOM image, and `steward-edge`, built from this repository's platform tag, creates its routes. Before a new platform version is tagged (its release pull request, and `main` until the tag is pushed), `steward-edge` is built from the branch under test instead. |
| task-auth end-to-end | [`tests/e2e/task-auth/run.sh`](../tests/e2e/task-auth/run.sh) | On every Kubernetes version in `kubernetes.tested`, with a real GitHub Actions OIDC token: the task-auth profile installs through the reference install; discovery works through the Envoy Gateway edge with verified TLS; the released steward-run action exchanges a token that Steward authenticates (`403 task_identity_unassociated`, no Task); and the exchange rejects a replayed assertion, a wrong audience and a workflow its policy does not admit. Skipped, with a notice, where no OIDC token is available (pull requests from forks). See [`tests/e2e/task-auth/README.md`](../tests/e2e/task-auth/README.md). |
| browser-admin end-to-end | [`tests/e2e/browser-admin/run.sh`](../tests/e2e/browser-admin/run.sh) | On every Kubernetes version in `kubernetes.tested`, without a real Google login: the browser-admin profile installs through the reference install with a placeholder OAuth client; the web UI is ready; the apiserver carries the configured browser login and steward-run's projected release coordinates; Steward's own routes carry every public API path to the apiserver (each answers through the edge exactly as the apiserver answers directly) and the rest to the web UI; and `/admin/auth/login` redirects to `accounts.google.com` with the configured client ID, the exact redirect URI and the hosted domain. See [`tests/e2e/browser-admin/README.md`](../tests/e2e/browser-admin/README.md). |
| Core end-to-end | [`tests/e2e/core/run.sh`](../tests/e2e/core/run.sh) | The core profile installs through the reference install (generator and helmfile, kind environment) on every Kubernetes version in `kubernetes.tested`, installs the BOM chart digests, runs the BOM image digests, applies its migrations, gets its certificates from cert-manager, enforces admission, and serves verified TLS. One more run installs it from a local registry mirror, copied with the mirror list and checked with `verify-digests.sh --mirror`, and asserts that the pods run the BOM digests from the mirror host. Needs an amd64 Docker engine. See [`tests/e2e/core/README.md`](../tests/e2e/core/README.md). |
| helmfile hooks | [`tests/hooks/run.sh`](../tests/hooks/run.sh) | The Envoy Gateway CRD hook writes only to the kube context helmfile uses for the releases. With fake `kubectl`, `curl` and `helm` and a current kubeconfig context that is a different cluster: the script applies to exactly one named context (with no context given, the current one, where Helm installs the releases), or refuses before downloading anything when `PLATFORM_KUBE_CONTEXT` disagrees or the context is not in the kubeconfig; and through the pinned helmfile, `--kube-context` and `HELMFILE_KUBE_CONTEXT` reach the hook, a sync without a context puts the hook and the release on the current context, and a sync with helmfile's `--kubeconfig` or a disagreeing `PLATFORM_KUBE_CONTEXT` fails before anything is applied or installed. See [the CRD hook and the kube context](../helmfile/README.md#the-crd-hook-and-the-kube-context). |

The attestation check needs a GitHub token (`GH_TOKEN`), because `gh
attestation verify` reads attestations through the GitHub API. The other checks
need no credentials. The signature check needs
[cosign](https://github.com/sigstore/cosign) v3 (CI pins the version and
checksum in [`scripts/ci/install-tools.sh`](../scripts/ci/install-tools.sh))
and network access to the public Sigstore trust root.

These checks verify the upstream artifacts the BOM pins. For products you
built from source, the digest check verifies your lock instead, and the
attestation and signature checks report those products as skipped: see
[fork and build from source](fork-and-build.md#verification).

## Attestation coverage: Steward 0.3.15

Steward publishes SLSA provenance attestations (`https://slsa.dev/provenance/v1`)
from `.github/workflows/release.yml` at the release tag. For 0.3.15:

Attested, and verified by CI because they are in the BOM:

- the OCI chart `oci://ghcr.io/apelogic-ai/charts/steward`;
- the `apiserver`, `controller`, `mint`, `bridge` and `web` images;
- the Codex reference runtime image.

Attested, but not in the BOM (verify them directly when you use them, as the
Steward release notes describe):

- `release-handoff.json`, the release metadata the BOM coordinates are taken
  from;
- the platform preflight bundle, the runtime provider-profile bundle and the
  product-compatibility manifest.

Not attested upstream, so CI does not verify them:

- the chart archive release asset `steward-0.3.15.tgz` (install the attested
  OCI chart instead);
- `steward-registry-lock.sh` (its SHA-256 is in the attested
  `release-handoff.json` and in a `.sha256` asset);
- the SPDX SBOMs, vulnerability reports and `.digest` files, which are
  published as release assets rather than as attestations;
- the bridge attestation bundle and the `.sha256` checksum files.

Steward images and the chart carry only provenance attestations; there are no
SBOM attestations on the registry artifacts.

## Attestation coverage: mcp-gw 0.5.7

mcp-gw publishes SLSA provenance attestations (`https://slsa.dev/provenance/v1`)
from `.github/workflows/release.yml` at the release tag `v0.5.7`, built on
GitHub-hosted runners. CI verifies all four BOM artifacts: the OCI chart
`oci://ghcr.io/apelogic-ai/charts/mcp-gateway` and the `agentgateway`,
`github-wrapper` and `google-workspace` images.

mcp-gw is in the BOM with `plannedFor: ["governed"]`: pinned and verified, but
no profile installs it and no end-to-end test exercises it until the governed
profile exists ([#3](https://github.com/apelogic-ai/steward-platform/issues/3)).
Its chart also references the upstream GitHub MCP Server image, which the BOM
does not pin. From 0.5.2 the release also mirrors that image, unchanged, into
`ghcr.io/apelogic-ai/mcp-gw-github-mcp-server`; mcp-gw did not build it, so it
carries no mcp-gw attestation. Its trust path is GitHub's upstream cosign
signature plus digest equality between the upstream and mirror coordinates,
as the release's `release-handoff.md` describes; verify both before using the
mirror. From 0.5.7 the release also publishes an attested GitHub governance
catalog (`github-governance-catalog.json`) for the pinned GitHub MCP Server; the
BOM does not pin it.

Not verified by CI: the SPDX SBOMs, vulnerability reports and `.digest` files
(including the per-architecture index digests), which are release assets
rather than attestations, and the chart archive release asset
`mcp-gateway-0.5.7.tgz` (install the attested OCI chart instead).

## Signature coverage: github-oidc-exchange 0.7.5 and steward-run 0.8.1

Neither product publishes GitHub artifact attestations for these releases
(`gh attestation verify` finds none). Both attach cosign Sigstore bundles to
the GitHub release instead, and the BOM's `signatures` entry lists them.

| Product | Signer | Verified |
|---|---|---|
| github-oidc-exchange | `.github/workflows/release.yml@refs/heads/main` | `release-manifest.json`; the OCI chart and the image (`public-chart-signature.sigstore.json`, `public-image-signature.sigstore.json`) |
| steward-run | `.github/workflows/portable-release.yml@refs/tags/v0.8.1` | `oss-release-manifest.json`, including its `actionCommit`; the ARC chart and the runner image (`chart-signature.sigstore.json`, `image-signature.sigstore.json`) |

github-oidc-exchange's release workflow runs on `main` (by
`workflow_dispatch`), so its signing certificate names `refs/heads/main`, not
the release tag. steward-run publishes from the release tag itself from 0.7.3,
so its certificate names `refs/tags/v0.8.1`. For both, the check binds the
certificate's workflow commit to the BOM commit, and separately checks that
the release tag points at that commit.

Not verified by CI: the SBOMs, scan reports, SLSA provenance JSON and checksum
files on those releases, the in-registry referrers (SLSA provenance and SPDX)
that github-oidc-exchange also publishes, the SLSA provenance and SPDX
attestations that steward-run embeds in its image (BuildKit), and
steward-run's vendored workflow assets (`steward-task-vendored.yml`, its
template and renderer). The signed `oss-release-manifest.json` lists their
SHA-256; the platform does not use them, so verify them against it when you
vendor the workflow.
