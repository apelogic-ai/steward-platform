# Contributing

## The rule: link, don't copy

Products own their contract specs. This repository links to them and tests
them. It never copies them.

In practice:

- Do not paste product chart values, API schemas, CRDs, configuration
  references, or upgrade steps into this repository. Link to the product
  document at a tag or commit.
- Where a test needs product configuration, set only what the test needs and
  link to the product document that defines it.
- If a product document is wrong, missing, or unclear, open an issue or pull
  request on that product. Link it from here if it affects the platform.
- Platform documents cover only what follows from combining the products:
  prerequisites, versions that are tested together, install order, and the
  seams between products.

## Changing the BOM

`bom/bom.json` pins exact product releases and dependency versions by digest.
It must validate against [`schemas/bom/v1.schema.json`](schemas/bom/v1.schema.json).

BOM bumps are manual for now. Automated bump pull requests from product
releases are planned in
[#4](https://github.com/apelogic-ai/steward-platform/issues/4).

To bump a product:

1. Take the coordinates from the product's own release metadata, not from a
   tag lookup: `release-handoff.json` for Steward, `release-manifest.json` for
   github-oidc-exchange and `oss-release-manifest.json` for steward-run (its
   `actionCommit` is `action.commit`), all on the GitHub release. Verify the
   metadata first, as the release notes describe.
2. Update the product entry: `version`, `commit`, `release`, the chart version
   and digest, every image reference, and `provenance.sourceRef`.
3. Bump `platformVersion`. The platform uses calendar versions
   (`YYYY.M.PATCH`, with an optional `-alpha.N`, `-beta.N` or `-rc.N`
   pre-release suffix).
4. Regenerate the Flux example, which is generated from the BOM:
   `scripts/generate-examples.sh`. If the product's chart values changed,
   update [`scripts/lib/platform.jq`](scripts/lib/platform.jq) and the chart
   links in [docs/platform-values.md](docs/platform-values.md).
5. Run the local checks:

   ```sh
   scripts/validate-bom.sh
   scripts/verify-digests.sh
   GH_TOKEN=... scripts/verify-attestations.sh
   scripts/verify-signatures.sh
   tests/generate/run.sh
   FLUX_SCHEMAS_DIR=... tests/flux/run.sh
   ```

6. Open a pull request. CI repeats those checks and runs the end-to-end tests
   against the new BOM. Merge only when every check is green.

To add or change a tested Kubernetes version, edit `kubernetes.tested`. The CI
end-to-end matrix is generated from that list, so the BOM and the test coverage
cannot drift apart.

## Scripts

- Bash with `set -euo pipefail`, clean under `shellcheck`.
- Small scripts that do one thing. Read inputs from the BOM rather than
  hard-coding versions or digests.
- Third-party GitHub Actions are pinned to full commit SHAs. Downloaded tools
  are pinned by version and checksum.

## Commits and pull requests

- Conventional commit subjects (`feat:`, `fix:`, `docs:`, `ci:`, `test:`,
  `chore:`).
- One logical change per commit.
- Fill in the pull request template.
- Do not commit credentials, private hostnames, account identifiers, or
  internal ticket references.
