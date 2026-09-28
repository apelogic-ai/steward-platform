# browser-admin end-to-end test

[`run.sh`](run.sh) installs the [browser-admin profile](../../../docs/profiles/browser-admin.md)
on a disposable kind cluster through the [reference install](../../../helmfile/README.md),
then checks it **without a real Google login**: the OAuth client is a
placeholder, and nothing in the test contacts Google.

The `e2e-browser-admin` job in [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml)
runs it on every Kubernetes version in `kubernetes.tested`, on pull requests
(including forks: it needs no OIDC token), on `main` and nightly.

## Steps

1. Prepare the operator-owned inputs: a placeholder github-oidc-exchange v6
   policy that admits a repository that does not exist, validated against
   the exchange's own schema at the BOM commit; a fresh ES256 keyring and its
   public JWKS from `keyring-tool` (built by
   [`scripts/ci/build-keyring-tool.sh`](../../../scripts/ci/build-keyring-tool.sh),
   cached with the task-auth job); a random placeholder Google client secret.
2. Create a kind cluster from
   [`environments/kind/kind-config.yaml`](../../../environments/kind/kind-config.yaml)
   and the BOM node image.
3. Run [`scripts/generate.sh`](../../../scripts/generate.sh) on
   [`environments/kind-browser-admin/platform-values.yaml`](../../../environments/kind-browser-admin/platform-values.yaml),
   create the inputs in the cluster, and `helmfile sync`.

## What it checks

1. **What runs.** The Steward apiserver, controller and web UI,
   github-oidc-exchange, Envoy Gateway and Envoy run their BOM image digests,
   and every Deployment rolls out.
2. **Configuration.** The apiserver's `STEWARD_RUN_RELEASE_JSON` is exactly
   the steward-run release projected from the BOM (the projection that
   `scripts/verify-signatures.sh` proves equal to the signed release
   manifest); its browser origin, client ID, Workspace domain and
   organization ID are the configured ones, and the client secret is read
   from the configured Secret and key. The NetworkPolicies admit the edge
   namespace to the web UI and the apiserver, and open the browser-auth
   egress CIDRs on port 443.
3. **Edge objects.** The Gateway is `Programmed`; Steward's own `steward-api`
   and `steward-web` HTTPRoutes and the exchange's route are `Accepted` with
   resolved references; Steward's `BackendTLSPolicy` is `Accepted`; the
   `steward-api` route matches exactly the generated public API path list;
   the platform's API-only `steward-task-api` route is absent.
4. **The web UI is ready**: `GET /health/ready` answers `204` through the
   edge, with TLS verified against the edge CA.
5. **Every public API path reaches the apiserver.** For each path in the
   route (each `Exact` path, each `PathPrefix` both bare and with a subpath
   no product serves, and four apiserver routes: `/admin/api/v1/session`,
   `/admin/operator/v1/users`, `/app/api/v1/envelope-templates` and `/v1/tasks`),
   the response through the edge (status,
   content type, `Location` and body digest) equals the apiserver's own
   response to the same request, sent directly to its Service over TLS
   verified against the Steward CA; the web UI's direct response differs, so
   each probe tells the two backends apart. `GET /admin/api/v1/session`
   without a session is `401`.
6. **Web paths reach the web UI**: `/`, `/admin/sign-in`, `/admin/approvals`,
   `/health/ready` and an unknown `/admin/...` path answer through the edge
   as the web UI answers directly (status, content type, `Location`), and
   not as the apiserver does.
7. **Google login starts.** `GET /admin/auth/login` answers `303` with a
   `Location` on `https://accounts.google.com/` whose query carries exactly
   the configured `client_id`, the redirect URI `<origin>/admin/auth/callback`,
   the configured hosted domain `hd`, `response_type=code`, `scope=openid
   email profile`, PKCE `S256` with a 43-character challenge, and a `state`
   and `nonce`; a second login gets a different `state`. It sets a
   `__Secure-steward-oidc-flow` cookie with `Path=/admin/auth; HttpOnly;
   SameSite=Lax` and `Secure`. The redirect is not followed.
8. **Task discovery still works** through Steward's routes: the
   protected-resource metadata names the origin and the exchange issuer, and
   the exchange's metadata is served through the same edge.

It deletes the cluster and its work directory when it finishes, pass or fail.

## What it does not check

A Google login, a session, the first administrator or any administrator
action: those need a real Google Workspace account in a browser. The
[first-admin runbook](../../../docs/browser-admin/first-admin.md) and the
[walkthrough](../../../docs/browser-admin/walkthrough.md) cover them by hand.

## Run it

Requirements: an **amd64** Docker engine, `kind`, `helm`, `helmfile`,
`kubectl`, `jq`, [yq](https://github.com/mikefarah/yq) v4,
`check-jsonschema`, `openssl`, `curl`, `sha256sum`, and `KEYRING_TOOL`
pointing at a `keyring-tool` built by
[`scripts/ci/build-keyring-tool.sh`](../../../scripts/ci/build-keyring-tool.sh).
No `sudo`: the edge is reached through a port-forward on a free local port.

```sh
KEYRING_TOOL=... tests/e2e/browser-admin/run.sh
KEYRING_TOOL=... K8S_VERSION=1.32.11 tests/e2e/browser-admin/run.sh
KEYRING_TOOL=... KEEP_CLUSTER=1 tests/e2e/browser-admin/run.sh
```
