# task-auth profile

The task-auth profile proves that the current Steward, github-oidc-exchange
and steward-run releases authenticate a Task submission together, with a real
GitHub Actions OIDC token and no stored secrets. It adds no agent execution:
nothing runs in a sandbox, and Steward stays in its core mode.

| | |
|---|---|
| BOM profile | `task-auth` in [`bom/bom.json`](../../bom/bom.json) |
| Reference install | [`environments/kind-task-auth`](../../environments/kind-task-auth/platform-values.yaml) through the [generator](../platform-values.md) and the [helmfile](../../helmfile/README.md) |
| Test | [`tests/e2e/task-auth`](../../tests/e2e/task-auth/README.md), in CI on every tested Kubernetes version and nightly |
| Tracking | [#7](https://github.com/apelogic-ai/steward-platform/issues/7) |

## What it installs

```text
GitHub-hosted job (runner)                  kind cluster
  steward-run action ──HTTPS──▶ 127.0.0.1:443 ─▶ Envoy Gateway (edge CA)
  curl                                          ├─ steward.platform.test
                                                │    /.well-known/oauth-protected-resource, /v1
                                                │    ─TLS (BackendTLSPolicy, Steward CA)─▶ steward-apiserver
                                                └─ identity.platform.test
                                                     discovery, /jwks.json, /v1/exchange
                                                     ─▶ github-oidc-exchange ─▶ GitHub JWKS (internet)
```

- **Core**: Steward with cert-manager and evaluation PostgreSQL, as in the
  [core profile](../install-order.md), plus Steward `taskIdentity`: the
  exchange's issuer, the `steward-task-api` audience, the public Steward
  origin as the protected resource, the exchange's public JWKS in a
  ConfigMap, and federated subjects (policy v6).
- **github-oidc-exchange** 0.7.2, policy v6, from its chart by digest. Its
  policy ConfigMap and keyring Secret are operator inputs; the test creates
  them.
- **Edge**: the Gateway API 1.6.1 CRDs (standard channel) and Envoy
  Gateway 1.9.1 from the BOM (the CRDs as digest-pinned manifests,
  server-side applied, because Envoy Gateway's CRD chart is too large for a
  Helm release); an
  evaluation `GatewayClass` and `Gateway` whose HTTPS listener certificate
  comes from a second self-signed CA; the Steward task API `HTTPRoute` and a
  `BackendTLSPolicy` that verifies the Steward API certificate against the
  public Steward CA ([`charts/steward-edge`](../../charts/steward-edge),
  [`charts/evaluation-edge`](../../charts/evaluation-edge)); the exchange's
  own `HTTPRoute` from its chart.
- **steward-run**: only the GitHub Action, at the `actionCommit` of the
  signed release manifest. The ARC chart and runner image are pinned in the
  BOM but not installed.

GitHub never reaches the cluster. The runner reaches the edge through a
port-forward, the public hostnames resolve to it through `/etc/hosts`, and
the exchange fetches GitHub's public JWKS over the internet.

## Choices, and why

- **Policy v6 and `steward-task-v3`.** Steward 0.3.1's release handoff names
  v5 as its identity-policy contract, and v5 is the exchange's default. But a
  v5 policy must map the actor to a Steward canonical user, and Steward
  answers a v2 token for an unknown canonical user with a plain `401`, which
  a test cannot tell apart from a bad token. Canonical users are created only
  by a Google browser login. With v6, Steward verifies the token first and
  then gives a specific, documented answer for an authenticated subject that
  is not yet associated with a user: `403 task_identity_unassociated`
  ([Steward task submission API, v0.3.1](https://github.com/apelogic-ai/steward/blob/v0.3.1/docs/task-submission-api.md#production-identity-boundary);
  [exchange consumer contracts, v0.7.2](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/consumer-contract-v1.md)).
- **The policy admits only this repository's workflow, as far as v6 can
  express it**: the numeric owner and repository IDs, and the exact subject,
  event and ref observed from the job's own signed token. v6 has no selector
  for the workflow file (`job_workflow_ref`); the workflow ref and SHA travel
  in the token's signed source provenance, which the test checks. The policy
  is generated in the job and never committed.
- **keyring-tool is built from source.** The exchange image does not ship it
  ([apelogic-ai/github-oidc-exchange#55](https://github.com/apelogic-ai/github-oidc-exchange/issues/55)),
  and its guides run it with `cargo run --locked`.
  [`scripts/ci/build-keyring-tool.sh`](../../scripts/ci/build-keyring-tool.sh)
  builds it from the BOM commit (checked against the release tag) with the
  product's pinned `rust-toolchain.toml` and `Cargo.lock`; CI caches the
  binary by commit.
- **Steward's edge route comes from this repository.** Steward's own
  `web.httpRoute` requires its browser web UI, which requires Google browser
  login. `charts/steward-edge` routes only the task API paths from
  [Steward's chart README](https://github.com/apelogic-ai/steward/blob/v0.3.1/charts/steward/README.md),
  and the edge namespace is admitted through `apiserverIngressNamespaces`.
- **The action runs by path.** GitHub cannot take a `uses:` reference from an
  expression, so the job checks out `apelogic-ai/steward-run` at the BOM
  `action.commit` and runs `uses: ./.task-auth/steward-run`. The code that
  runs is the released action at that commit, and a steward-run bump is a BOM
  edit.
- **Node 24 is set up explicitly.** The composite action runs `node` from
  `PATH` and declares `engines.node: ">=24 <25"`
  ([apelogic-ai/steward-run#69](https://github.com/apelogic-ai/steward-run/issues/69)).
  The job reports the runner's default Node, installs a pinned Node 24, and
  checks it against the action's `engines`.
- **Trust uses the action's documented mechanism**, `NODE_EXTRA_CA_CERTS`
  ([steward-run installation, v0.7.2](https://github.com/apelogic-ai/steward-run/blob/v0.7.2/docs/installation.md)),
  not the deprecated `steward-ca-certificate-file` input.

## What it proves

1. **Discovery through the edge.** Steward's protected-resource metadata
   names the public Steward origin, the exchange as its only authorization
   server, and `steward-task-v2` and `steward-task-v3`; the exchange's RFC
   8414 and OpenID metadata agree and advertise its exchange endpoint, its
   GitHub audience, `steward-task-v3` and policy v6; the exchange's published
   ES256 keys are the ones Steward holds. TLS is verified end to end: the
   edge certificate against the edge CA, and the Steward API certificate
   against the Steward CA through the `BackendTLSPolicy`.
2. **The released action works against it.** The steward-run action
   discovers, exchanges a fresh GitHub token and submits; the exchange logs
   one issued token for this actor and workflow; Steward records the subject
   `github-actions:actor:<id>` as an unassociated observation and creates no
   Task.
3. **Each response of the chain**, driven directly: the exchange returns a
   120-second `steward-task-v3` Bearer token (`Cache-Control: no-store`) for
   the job's actor, with the workflow ref and SHA in its signed provenance;
   Steward answers it `403 task_identity_unassociated` naming the exact
   issuer and subject, and refreshes the observation; the same route answers
   `401` to an invalid token and to the raw GitHub token.
4. **Negative cases** at the exchange, each `401 invalid_token` and each
   matched to its audit event: a replayed assertion (`exchange_replayed`, by
   the assertion's `jti` hash), a GitHub token for the wrong audience
   (`exchange_denied`, rejected at verification), and a workflow the policy
   does not admit (`exchange_denied`, "identity is not authorized", after the
   policy's subject selector is changed to another branch's workflow).

## What it does not prove

- **No Task is admitted.** A Steward canonical user exists only after a
  Google browser login, and an administrator must associate the federated
  subject with it through the browser admin API. There is no supported
  non-browser path, so the test stops at `task_identity_unassociated`. It
  does not reach User Envelope lookup or the core-mode refusal
  (`503`, "Task submission is disabled during the staged orchestration
  rollout") that an associated subject would get. The governed profile needs
  the same capability ([#3](https://github.com/apelogic-ai/steward-platform/issues/3)).
  The [browser-admin profile](browser-admin.md) adds the browser login, and
  its walkthrough shows the association
  [by hand](../browser-admin/walkthrough.md#optional-link-a-task-identity-to-the-user-manual).
- **Policy v5 and `steward-task-v2`** are not exercised: they need that
  canonical user too.
- **No execution**, no runner scale set, no Mint, SPIRE, sandbox or
  inference; that is the governed profile.
- **The workflow file is not an exchange selector.** Any workflow in this
  repository on the same event and ref would be admitted by the generated
  policy; Steward's source binding is where the workflow is authorized.
- **Evaluation-only pieces**: the self-signed CAs, the evaluation Gateway,
  the Steward CA `ConfigMap` copied at install time (production publishes it
  with its trust distribution, for example trust-manager), a port-forward in
  place of a load balancer, and in-cluster PostgreSQL.
- **Key rotation**, and Steward reloading a changed JWKS.
- **Flux**: the generator writes Flux output for the core profile only.

## Run it

Only a GitHub-hosted job with `permissions: id-token: write` can mint the
token; see the `e2e-task-auth` job in
[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) and
[`tests/e2e/task-auth/README.md`](../../tests/e2e/task-auth/README.md).
Pull requests from forks get no token: the job skips with a notice and the
core e2e still runs.

To install the same environment on your own kind cluster without the test,
create the three operator inputs first (the exchange policy ConfigMap and
keyring Secret in `identity`, and Steward's JWKS ConfigMap in `steward`; the
names are in the platform values), then:

```sh
scripts/generate.sh environments/kind-task-auth/platform-values.yaml
helmfile --file helmfile/helmfile.yaml.gotmpl --environment kind-task-auth sync
```
