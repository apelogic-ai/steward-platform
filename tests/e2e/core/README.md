# Core profile end-to-end test

[`run.sh`](run.sh) installs the core profile on a disposable kind cluster and
checks that it works. It reads every coordinate from
[`bom/bom.json`](../../../bom/bom.json): the Steward chart and image digests,
the PostgreSQL image, and the kind node image for the Kubernetes version under
test. A passing run therefore proves the BOM, not a hand-picked set of tags.

## What it checks

1. The chart pulled by digest has the version the BOM declares.
2. The cluster runs the Kubernetes version under test.
3. The rendered chart and the running pods use the exact image digests from
   the BOM.
4. Every database migration applied.
5. The `AgentRuntime` CRD is established, the validating webhook is wired with
   a CA bundle and `failurePolicy: Fail`, and it denies an invalid
   `AgentRuntime`.
6. The API answers `401` on an admin route over TLS verified against the test
   CA.

It deletes the cluster and its work directory when it finishes, pass or fail.

## Run it

Requirements: an **amd64** Docker engine, `kind`, `helm` 3.17 or later,
`kubectl`, `jq`, `openssl`, `curl` and `tar`.

```sh
tests/e2e/core/run.sh                     # highest tested Kubernetes version
K8S_VERSION=1.30.13 tests/e2e/core/run.sh # a specific entry in kubernetes.tested
KEEP_CLUSTER=1 tests/e2e/core/run.sh      # keep the cluster for debugging
```

CI runs it once per entry in `kubernetes.tested`, on GitHub-hosted
`ubuntu-latest` runners.

### Apple Silicon and other arm64 hosts

Steward images are published for linux/amd64 only
([apelogic-ai/steward#148](https://github.com/apelogic-ai/steward/issues/148)),
so kind needs amd64 nodes. On an arm64 host, kind creates arm64 nodes and the
Steward pods cannot start; the script stops early with a message. Run it on an
amd64 Linux machine or VM instead. A local kind evaluation guide is tracked in
[apelogic-ai/steward#172](https://github.com/apelogic-ai/steward/issues/172).

## Test-only configuration

The install sets only what the core profile needs on a throwaway cluster. Each
item is ordinary chart configuration documented by Steward:

- **PostgreSQL** runs in the cluster from the BOM image, without TLS
  (`sslmode=disable`). This is evaluation-only; production uses a separately
  operated PostgreSQL 16.
- **Service certificates** come from a one-day CA generated per run. The CA is
  passed to the webhook with `tls.webhook.caBundlePem`.
- **NetworkPolicy** stays enabled. It needs literal CIDRs, so the script passes
  the Kubernetes API service IP and the PostgreSQL pod IP as `/32` entries.
- **TokenReview audience** is set to the cluster's service account issuer. On
  kind that is `https://kubernetes.default.svc.cluster.local`, which differs
  from the chart default.
- The `AgentRuntime` CRD is installed from the chart's `crds/` directory.
- Browser login, governed execution, Mint, the web UI and the connections
  bridge stay off. If you enable browser login, `browserAuth.google.organizationId`
  must start with `org_`; the chart schema does not enforce it yet and the
  apiserver fails at startup otherwise
  ([apelogic-ai/steward#137](https://github.com/apelogic-ai/steward/issues/137)).

The script is ported from Steward's own
[`scripts/customer-core-install-e2e.sh`](https://github.com/apelogic-ai/steward/blob/v0.3.0/scripts/customer-core-install-e2e.sh)
at v0.3.0.
