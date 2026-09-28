## What and why

<!-- What does this change, and why? Link the issue: "Closes #N". -->

## Type

- [ ] BOM bump (product release or dependency version)
- [ ] BOM schema change
- [ ] Tests or CI
- [ ] Documentation
- [ ] Other

## BOM bumps

<!-- Delete this section if the BOM is unchanged. -->

- Product release(s) and the release metadata the coordinates came from:
- Previous and new `platformVersion`:
- [ ] Every digest was taken from the product's release metadata, not from a
      tag lookup.
- [ ] `scripts/validate-bom.sh`, `scripts/verify-digests.sh` and
      `scripts/verify-attestations.sh` pass locally.

## Checklist

- [ ] Product contracts are linked, not copied.
- [ ] Scripts are `shellcheck`-clean and use `set -euo pipefail`.
- [ ] New third-party actions are pinned to a full commit SHA.
- [ ] No credentials, private hostnames, account identifiers or internal
      references.
