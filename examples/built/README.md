# Built-artifacts lock example

[`built-lock.json`](built-lock.json) is a complete built-artifacts lock for
the current BOM: Steward and github-oidc-exchange, the products the core,
task-auth and browser-admin profiles deploy, built from forks under
`github.com/example-org` at the BOM's release commits and pushed to
`registry.example.com`. The digests are placeholders; none of these
references resolve.

Use it with any platform values file:

```yaml
artifacts:
  source: built
  builtLock: ../../examples/built/built-lock.json
```

`tests/built/run.sh` generates every committed environment with it, and
checks that it is what
[`scripts/built-lock-from-digests.sh`](../../scripts/built-lock-from-digests.sh)
writes for the BOM (`tests/built/run.sh --update` rewrites it after a BOM
bump). See [fork and build from source](../../docs/fork-and-build.md).
