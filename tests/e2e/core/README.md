# Core profile end-to-end test

[`run.sh`](run.sh) installs the core profile on a disposable kind cluster
through the [reference install](../../../helmfile/README.md), then checks that
it works. It runs the same steps an evaluator runs:

1. create a kind cluster from
   [`environments/kind/kind-config.yaml`](../../../environments/kind/kind-config.yaml)
   and the BOM node image for the Kubernetes version under test;
2. run [`scripts/generate.sh`](../../../scripts/generate.sh) on
   [`environments/kind/platform-values.yaml`](../../../environments/kind/platform-values.yaml);
3. `helmfile sync` the `kind` environment: cert-manager, the evaluation CA,
   evaluation PostgreSQL and Steward.

Every coordinate comes from [`bom/bom.json`](../../../bom/bom.json), so a
passing run proves the BOM and the reference install together, not a
hand-picked set of tags.

## What it checks

1. helmfile installs the Steward and cert-manager charts at their BOM digests,
   and the Steward chart at that digest has the BOM version.
2. The rendered Steward chart uses the exact image digests from the BOM.
3. The cluster runs the Kubernetes version under test, and matches what the
   kind platform values assume: the Kubernetes API Service IP is inside
   `cluster.kubeApi.cidrs`, and the service account issuer is
   `cluster.serviceAccountTokenAudience`.
4. The running Steward, cert-manager and PostgreSQL pods use the exact image
   digests from the BOM, and the PostgreSQL pod is inside `database.cidrs`.
5. Every database migration applied.
6. cert-manager issued both Steward certificates from the evaluation CA.
7. The `AgentRuntime` CRD is established, cert-manager injected the
   evaluation CA into the validating webhook, which has `failurePolicy: Fail`,
   and the webhook denies an invalid `AgentRuntime`.
8. The API answers `401` on an admin route over TLS verified against the
   evaluation CA.

It deletes the cluster and its work directory when it finishes, pass or fail.

## Run it

Requirements: an **amd64** Docker engine, `kind`, `helm` 3.17 or later,
`helmfile`, `kubectl`, `jq`, [yq](https://github.com/mikefarah/yq) v4,
`check-jsonschema`, `openssl`, `curl` and `tar`. CI pins them in
[`scripts/ci/install-tools.sh`](../../../scripts/ci/install-tools.sh).

```sh
tests/e2e/core/run.sh                     # highest tested Kubernetes version
K8S_VERSION=1.32.11 tests/e2e/core/run.sh # a specific entry in kubernetes.tested
KEEP_CLUSTER=1 tests/e2e/core/run.sh      # keep the cluster for debugging
```

The generated inputs go to the run's work directory, not to `generated/`.
CI runs the test once per entry in `kubernetes.tested`, on GitHub-hosted
`ubuntu-latest` runners.

### Apple Silicon and other arm64 hosts

Steward images are published for linux/amd64 only
([apelogic-ai/steward#148](https://github.com/apelogic-ai/steward/issues/148)),
so kind needs amd64 nodes. On an arm64 host, kind creates arm64 nodes and the
Steward pods cannot start; the script stops early with a message. Run it on an
amd64 Linux machine or VM instead. A local kind evaluation guide is tracked in
[apelogic-ai/steward#172](https://github.com/apelogic-ai/steward/issues/172).

## Evaluation-only configuration

The kind environment sets only what the core profile needs on a throwaway
cluster. Each Steward item is ordinary chart configuration documented by
Steward; see [platform values](../../../docs/platform-values.md) for where
each one comes from.

- **PostgreSQL** runs in the cluster from the BOM image, without TLS
  (`sslmode=disable`) or persistence. This is evaluation-only; production uses
  a separately operated PostgreSQL 16.
- **Service certificates** come from cert-manager with a self-signed CA
  `Issuer`, through Steward's `tls.mode=certManager`. cert-manager's CA
  injector supplies the webhook CA bundle.
- **NetworkPolicy** stays enabled. It needs literal CIDRs: the Kubernetes API
  Service IP, and for PostgreSQL the kind pod subnet on the PostgreSQL port
  only, because the evaluation pod has no fixed address.
- **TokenReview audience** is the cluster's service account issuer. On kind
  that is `https://kubernetes.default.svc.cluster.local`, which differs from
  the chart default.
- The `AgentRuntime` CRD is installed from the chart's `crds/` directory.
- Browser login, governed execution, Mint, the web UI and the connections
  bridge stay off. If you enable browser login, `browserAuth.google.organizationId`
  must match `^org_[a-z0-9_-]{1,60}$`, which the Steward 0.3.2 chart schema
  enforces.

The assertions are ported from Steward's own
[`scripts/customer-core-install-e2e.sh`](https://github.com/apelogic-ai/steward/blob/v0.3.0/scripts/customer-core-install-e2e.sh)
at v0.3.0.
