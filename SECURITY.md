# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub private vulnerability
reporting for this repository:

<https://github.com/apelogic-ai/steward-platform/security/advisories/new>

Do not open a public issue, pull request, or discussion for a suspected
vulnerability.

Include what you found, how to reproduce it, and which BOM version
(`platformVersion` in `bom/bom.json`) or commit it affects.

## Scope

This repository covers the BOM, its schema, the end-to-end tests, the CI that
verifies them, and the platform documentation. Examples of in-scope reports:

- a BOM entry that pins an artifact other than the one the product released;
- CI that accepts an artifact whose digest or attestation does not verify;
- test or reference configuration that weakens a product's security defaults
  without saying so.

A vulnerability in a product itself belongs to that product. Report it through
the product repository's own security reporting:

- [apelogic-ai/steward](https://github.com/apelogic-ai/steward/security)
- [apelogic-ai/steward-run](https://github.com/apelogic-ai/steward-run/security)
- [apelogic-ai/github-oidc-exchange](https://github.com/apelogic-ai/github-oidc-exchange/security)
- [apelogic-ai/mcp-gw](https://github.com/apelogic-ai/mcp-gw/security)

If you are not sure where a report belongs, report it here and we will route it.

## Supported versions

There are no platform releases yet. Until there are, only the BOM on the
default branch is supported.
