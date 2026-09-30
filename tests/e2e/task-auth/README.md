# task-auth end-to-end test

[`run.sh`](run.sh) proves the [task-auth profile](../../docs/profiles/task-auth.md):
Steward, github-oidc-exchange and the steward-run GitHub Action authenticate
a Task submission with a real GitHub Actions OIDC token, through an Envoy
Gateway edge on a disposable kind cluster.

It runs only inside a GitHub-hosted job with `permissions: id-token: write`,
because the token under test is minted there. The `e2e-task-auth` job in
[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) runs it on every
Kubernetes version in `kubernetes.tested`, on pull requests, on `main` and
nightly. A pull request from a fork gets no OIDC token; the job then skips
with a notice, and the core e2e still runs.

## Phases

The steward-run action is a workflow step, so the test has phases around it:

| Step | What happens |
|---|---|
| build keyring-tool | [`scripts/ci/build-keyring-tool.sh`](../../scripts/ci/build-keyring-tool.sh), cached by commit |
| `run.sh up` | claims, policy, keyring, cluster, reference install, edge and discovery checks |
| check out the action | `apelogic-ai/steward-run` at the BOM `products.steward-run.action.commit` |
| `run.sh check-node` | the runner's Node satisfies the action's `engines.node` (Node 24 is set up by the job) |
| the action | `uses: ./.task-auth/steward-run`, `continue-on-error: true` |
| `run.sh verify` | what the action left behind, the direct chain, the negative cases |
| `run.sh down` | always: the cluster, the port-forward and the hosts entries |

## Assertions

`up`:

- the probe token's signed claims match the job context (`GITHUB_REPOSITORY_ID`,
  `GITHUB_REPOSITORY_OWNER_ID`, event, ref, actor ID, workflow ref and SHA);
- the generated v6 policy (owner and repository IDs, exact subject, event and
  ref) validates against the exchange's own schema at the BOM commit;
- `keyring-tool export-jwks` yields exactly one public ES256 signing key;
- the Gateway is `Programmed`; the Steward and exchange `HTTPRoute`s are
  `Accepted` with resolved references; the `BackendTLSPolicy` is `Accepted`;
- the exchange, Envoy Gateway, Envoy and Steward pods run their BOM digests,
  and Steward mounts the JWKS ConfigMap;
- through the edge, with TLS verified against the edge CA: Steward's
  protected-resource metadata is exactly `resource`, one authorization
  server (the issuer), `bearer_methods_supported: ["header"]` and
  `steward_task_token_contracts: ["steward-task-v2", "steward-task-v3"]`,
  cacheable for 300 seconds; the exchange's two metadata documents are
  identical and advertise the issuer, JWKS URI, exchange endpoint, the
  GitHub audience, `steward-task-v3` and policy v6; the published ES256 key
  IDs equal Steward's.

`verify`:

1. **The action.** Its outcome is `failure`; the exchange logged exactly one
   `exchange_issued` for this actor and `job_workflow_ref`; Steward has
   exactly one `federated_subjects` row, for the issuer and
   `github-actions:actor:<actor ID>`, in state `observed` with no canonical
   user, the actor's login and revision 1, and its `observed` audit entry;
   `task_submissions` is empty.
2. **Exchange.** A fresh token with the discovered audience: `200`,
   `Cache-Control: no-store`, `token_type: Bearer`, `expires_in: 120`. The
   token's claims: the issuer, `aud: ["steward-task-api"]`, the subject,
   `identity_contract: steward-task-v3`, `actor_login`, no `email`,
   `email_verified` or `groups`, a 120-second lifetime, and signed
   provenance naming this repository, event, ref, actor, and the caller and
   reusable workflow refs and SHAs.
3. **Steward.** `POST /v1/tasks` with that token: `403` with
   `{"error": "task_identity_unassociated", "issuer": <issuer>, "subject":
   "github-actions:actor:<actor ID>"}`; the observation's `last_seen_at`
   advances, its revision stays 1, and no Task exists. The same request with
   `Bearer not-a-token`, and with the raw GitHub token, is `401`.
4. **Replay.** The same GitHub assertion again: `401 invalid_token`, and one
   `exchange_replayed` audit event with reason `replay` for that assertion's
   `jti` hash.
5. **Wrong audience.** A GitHub token for another audience: `401
   invalid_token`, and one more `exchange_denied` with reason `assertion is
   invalid`.
6. **Unadmitted workflow.** The policy's subject selector is changed to
   another branch's workflow (same repository), and the exchange is rolled.
   A fresh assertion: `401 invalid_token`, and one `exchange_denied` with
   reason `identity is not authorized` for its `jti` hash.

## Why `403 task_identity_unassociated`

It is the strongest outcome a test can reach without a Steward canonical
user, and it can only follow successful authentication. In Steward 0.3.5,
`POST /v1/tasks` authenticates before it reads the request
([`submit_task`](https://github.com/apelogic-ai/steward/blob/v0.3.5/crates/steward-apiserver/src/tasks.rs#L1734-L1775),
[`resolve_task_identity`](https://github.com/apelogic-ai/steward/blob/v0.3.5/crates/steward-apiserver/src/tasks.rs#L2889-L2912)).
For a `steward-task-v3` token, the resolver
([`IdentityTaskIdentityResolver::resolve`](https://github.com/apelogic-ai/steward/blob/v0.3.5/crates/steward-apiserver/src/tasks.rs#L787-L884))
first verifies the ES256 signature against the configured JWKS, the exact
issuer, the single exact audience, the lifetime, the `jti` and the signed
provenance (`verify_identity_task_token`); only then does it record the
subject and look up its association. An unassociated subject maps to
`403 task_identity_unassociated`
([`ApiError` response](https://github.com/apelogic-ai/steward/blob/v0.3.5/crates/steward-apiserver/src/lib.rs#L2383-L2397)),
as the [task submission API](https://github.com/apelogic-ai/steward/blob/v0.3.5/docs/task-submission-api.md#production-identity-boundary)
documents. Every verification failure is `401` instead.

An associated subject is not reachable: association needs an existing
canonical user, which only a Google browser login creates, and the
browser-session admin API. With one, `task-auth-probe@1` (a versioned
Workflow reference) would next be refused in core mode with `503` "Task
submission is disabled during the staged orchestration rollout"
([`submit`](https://github.com/apelogic-ai/steward/blob/v0.3.5/crates/steward-apiserver/src/tasks.rs#L1924-L1967)).
With a `steward-task-v2` token (policy v5) an unknown canonical user is a
`401`, indistinguishable from a bad token, which is why the profile uses v6.

The steward-run action reports failures only as annotations, which a later
step cannot read, so its part is asserted from the state it leaves in the
exchange's audit log and Steward's database (read-only `SELECT`s, like the
core test's migration check).

## Run it elsewhere

`run.sh up` exits 3 without `ACTIONS_ID_TOKEN_REQUEST_URL` and
`ACTIONS_ID_TOKEN_REQUEST_TOKEN`. It also needs an amd64 Docker engine,
`sudo` (it adds `/etc/hosts` entries and lowers
`net.ipv4.ip_unprivileged_port_start` to 443 for the port-forward), and
`KEYRING_TOOL`. `KEEP_CLUSTER=1 run.sh down` keeps the cluster for
debugging.
