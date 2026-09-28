# Changelog

Platform versions of the Steward platform BOM. Each entry is one
`platformVersion` of [`bom/bom.json`](bom/bom.json); the BOM at that version
is authoritative for every pinned version and digest.

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
