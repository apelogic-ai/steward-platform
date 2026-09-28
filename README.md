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

- **core**: Steward alone, with a PostgreSQL database. No agent execution.
- **governed**: core plus the other three products and the external
  dependencies that governed execution needs (workload identity, sandboxing,
  inference proxy, runners). Not yet covered; see
  [#3](https://github.com/apelogic-ai/steward-platform/issues/3).

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
- reference install tooling and install order (planned, see
  [#2](https://github.com/apelogic-ai/steward-platform/issues/2));
- the platform release train (planned, see
  [#4](https://github.com/apelogic-ai/steward-platform/issues/4)).

## Status

Pre-release. The first BOM pins the core profile only. There are no platform
releases yet.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
