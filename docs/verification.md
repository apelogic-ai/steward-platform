# How the BOM is verified

CI runs these checks on every pull request, on every push to `main`, and
nightly. All of them run on GitHub-hosted `ubuntu-latest` (linux/amd64)
runners. You can run all of them locally; the end-to-end test needs an amd64
host.

| Check | Script | What it proves |
|---|---|---|
| Schema and cross-references | [`scripts/validate-bom.sh`](../scripts/validate-bom.sh) | The BOM matches [`schemas/bom/v1.schema.json`](../schemas/bom/v1.schema.json). Profiles reference only pinned entries, `requiredFor` matches the profiles, attestation subjects exist, declared minimum peer versions hold, and the tested Kubernetes versions cover both ends of the supported range. |
| Digests | [`scripts/verify-digests.sh`](../scripts/verify-digests.sh) | Every chart, image, node image and manifest pinned in the BOM resolves anonymously at its digest. A product tag that moved away from the pinned digest fails. A dependency or node image tag that moved only warns, because those upstreams rebuild tags; the pinned digest is still what gets installed. |
| Attestations | [`scripts/verify-attestations.sh`](../scripts/verify-attestations.sh) | Each artifact listed in `products.<name>.provenance.subjects` has a GitHub artifact attestation with the declared predicate type, signed by the declared workflow at the declared tag, built on a GitHub-hosted runner, from the product repository at the pinned commit. |
| Generator and helmfile | [`tests/generate/run.sh`](../tests/generate/run.sh) | Every `environments/*/platform-values.yaml`, plus a customer-supplied-TLS variant, generates deterministically, and the generated values pass `helm lint` and `helm template` with the BOM-pinned charts pulled by digest, so each chart's own values schema applies. The [helmfile](../helmfile/README.md) builds and renders every committed environment and installs each BOM chart at its BOM digest. The generator refuses reserved governed fields, the governed profile, evaluation pieces in production, and a CA bundle that contains a private key. See [platform values](platform-values.md). |
| Flux example | [`tests/flux/run.sh`](../tests/flux/run.sh) | [`examples/flux/core`](../examples/flux/core) matches a fresh generation from the BOM, validates strictly against the pinned Flux CRD schemas, pins each BOM chart by its BOM digest, and renders with the BOM image digests. |
| Core end-to-end | [`tests/e2e/core/run.sh`](../tests/e2e/core/run.sh) | The core profile installs through the reference install (generator and helmfile, kind environment) on every Kubernetes version in `kubernetes.tested`, installs the BOM chart digests, runs the BOM image digests, applies its migrations, gets its certificates from cert-manager, enforces admission, and serves verified TLS. Needs an amd64 Docker engine. See [`tests/e2e/core/README.md`](../tests/e2e/core/README.md). |

The attestation check needs a GitHub token (`GH_TOKEN`), because `gh
attestation verify` reads attestations through the GitHub API. The other checks
need no credentials.

## Attestation coverage: Steward 0.3.1

Steward publishes SLSA provenance attestations (`https://slsa.dev/provenance/v1`)
from `.github/workflows/release.yml` at the release tag. For 0.3.1:

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

- the chart archive release asset `steward-0.3.1.tgz` (install the attested
  OCI chart instead);
- `steward-registry-lock.sh` (its SHA-256 is in the attested
  `release-handoff.json` and in a `.sha256` asset);
- the SPDX SBOMs, vulnerability reports and `.digest` files, which are
  published as release assets rather than as attestations;
- the bridge attestation bundle and the `.sha256` checksum files.

Steward images and the chart carry only provenance attestations; there are no
SBOM attestations on the registry artifacts.
