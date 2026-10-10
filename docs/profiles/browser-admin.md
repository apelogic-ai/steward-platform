# browser-admin profile

The browser-admin profile gives evaluators the human side of core mode:
Steward's web UI and Google Workspace sign-in, the administrator surfaces for
Envelope templates, requests, approvals and audit, and the first-administrator
bootstrap. It is the [task-auth profile](task-auth.md) plus Steward's browser
login and web UI, from released versions only, with no governed-execution
stack: nothing runs.

| | |
|---|---|
| BOM profile | `browser-admin` in [`bom/bom.json`](../../bom/bom.json) |
| Reference install | [`environments/kind-browser-admin`](../../environments/kind-browser-admin/platform-values.yaml) through the [generator](../platform-values.md#implemented-browser-admin) and the [helmfile](../../helmfile/README.md) |
| Flux | [`examples/flux/browser-admin`](../../examples/flux/browser-admin/README.md), generated from the production shape [`environments/production-browser-admin`](../../environments/production-browser-admin/platform-values.yaml) |
| Test | [`tests/e2e/browser-admin`](../../tests/e2e/browser-admin/README.md), in CI on every tested Kubernetes version and nightly, without a real Google login |
| Evaluate it | [local access](../browser-admin/local-access.md), then the [first-admin runbook](../browser-admin/first-admin.md) and the [walkthrough](../browser-admin/walkthrough.md) |
| Tracking | [#10](https://github.com/apelogic-ai/steward-platform/issues/10) |

## What it installs

```text
browser (workstation)                       kind cluster
  https://<steward host> ──▶ 127.0.0.1:443 ─▶ Envoy Gateway (edge CA)
                                            ├─ <steward host>, Steward's own routes:
                                            │    steward-api: /.well-known/oauth-protected-resource,
                                            │      /admin/api, /admin/auth, /admin/connections/github/callback,
                                            │      /admin/operator, /app/api, /v1
                                            │      ─TLS (Steward's BackendTLSPolicy)─▶ steward-apiserver ─▶ Google (sign-in)
                                            │    steward-web: everything else ─▶ steward-web
                                            └─ identity host ─▶ github-oidc-exchange
```

- **Everything in task-auth**: Steward with cert-manager and evaluation
  PostgreSQL, task identity, github-oidc-exchange, the Gateway API CRDs,
  Envoy Gateway and the evaluation Gateway.
- **Steward's web UI** (`steward-web`, the BOM `web` image) on the same
  origin as the API: `publicEndpoints.steward` is the browser origin, the
  web host and the task-token resource.
- **Google Workspace sign-in** (`browserAuth`): the client ID, the hosted
  domain, a Steward organization ID and the client Secret by reference, with
  apiserver egress to Google on 443 through
  `networkPolicy.egressCidrs.browserAuth`.
- **steward-run's release coordinates** in `config.apiserver.stewardRunRelease`,
  which Steward requires for browser administration, projected from the BOM
  with Steward's documented mapping and checked against steward-run's signed
  release manifest.
- **A capability catalog** (`administration.capabilityCatalog`) with one
  descriptive model, so that templates can be authored.
- **The edge from Steward's own `web.httpRoute`**: the `steward-api` route
  with every public apiserver path, the `steward-web` route for the rest, and
  the `BackendTLSPolicy` that verifies the apiserver certificate. The
  platform's API-only [`charts/steward-edge`](../../charts/steward-edge) is
  not installed.

## Choices, and why

- **A superset of task-auth.** The profile builds on the task-auth edge and
  identity wiring, so the same install can show the optional last step of
  the authorization chain: an administrator associates a Task identity with a
  user ([walkthrough](../browser-admin/walkthrough.md#optional-link-a-task-identity-to-the-user-manual)).
  The cost is task-auth's operator inputs (exchange policy, keyring, JWKS).
- **Steward's routes, with the full path list from the platform.** Steward's
  chart renders the edge when the web UI is on, but does not enforce which
  paths go to the apiserver. The generator supplies every public path from
  [Steward's chart README](https://github.com/apelogic-ai/steward/blob/v0.3.15/charts/steward/README.md);
  a missing one would silently fall through to the web UI. The test proves
  each one reaches the apiserver.
- **One origin.** The browser origin, web host, route hostname and
  task-token resource are all `publicEndpoints.steward`, set once, because
  the chart requires them to agree exactly.
- **No new place for steward-run's coordinates.** The BOM already pins
  steward-run from its signed release manifest; it now also pins the
  manifest's workflow repository and commit and its `schemaVersion`, and the
  signature check proves the projection equals the manifest.
- **An unrestricted egress rule for evaluation only.** Steward's
  NetworkPolicy takes literal CIDRs and Google publishes no stable ranges for
  its sign-in endpoints; the kind values open HTTPS to `0.0.0.0/0`, and the
  schema refuses that in production.
- **A placeholder OAuth client in CI.** A real Google login needs a person, a
  browser and a Workspace account. The test proves everything up to the
  redirect to Google, with the exact parameters a real client needs.

## What it proves

1. The browser-admin install comes up from the BOM: the web UI, apiserver,
   controller, exchange and edge run their BOM digests, and the web UI is
   ready through the edge.
2. The apiserver carries the configured browser login and steward-run's
   release coordinates, which equal the signed release manifest under
   Steward's mapping; the NetworkPolicies admit the edge and open the
   browser-auth egress.
3. Steward's own routes and `BackendTLSPolicy` are accepted, with exactly the
   generated path list, and every public API path answers through the edge
   exactly as the apiserver answers directly (not as the web UI does), with
   TLS verified at both hops; web paths reach the web UI.
4. Sign-in starts correctly: `GET /admin/auth/login` redirects to
   `accounts.google.com` with the configured client ID, the redirect URI
   `<origin>/admin/auth/callback`, the hosted domain `hd`, code flow with
   PKCE, and a `Secure`, `HttpOnly` flow cookie.
5. Task discovery still works through Steward's routes.

## What it does not prove

- **A Google sign-in, a session, or any administrator action.** They need a
  real Workspace account in a browser. The [first-admin runbook](../browser-admin/first-admin.md)
  and [walkthrough](../browser-admin/walkthrough.md) cover them by hand.
- **That Google accepts the client.** The redirect parameters are checked;
  the code exchange, Google's ID token and the hosted-domain check are not.
- **The operator CLI.** Its administrator credential is not documented
  upstream ([apelogic-ai/steward#146](https://github.com/apelogic-ai/steward/issues/146)).
- **An associated Task identity.** CI cannot create a canonical user; the
  association is a manual demonstration
  ([apelogic-ai/steward#179](https://github.com/apelogic-ai/steward/issues/179)).
- **Production egress.** CI opens `0.0.0.0/0` on 443; production CIDRs for
  Google are yours to maintain.
- **Execution**, and everything task-auth does not prove.
- **A Flux install.** CI checks the [Flux output](#flux) statically against
  the helmfile; the end-to-end test installs through the helmfile.

## Known limitations

- **Google Workspace only.** Browser login is Google OIDC for one hosted
  domain; personal Google accounts are rejected. The OAuth consent screen
  must be Internal to the Workspace organization for the local flow described
  here.
- **Google egress as literal CIDRs.** Steward's NetworkPolicy has no FQDN or
  selector peers for Google, and Google publishes no stable ranges
  ([apelogic-ai/steward#152](https://github.com/apelogic-ai/steward/issues/152)).
- **amd64 only.** Steward images, and therefore the operator CLI, are
  linux/amd64 only
  ([apelogic-ai/steward#148](https://github.com/apelogic-ai/steward/issues/148)).
- **No automated identity linking.** Creating a canonical user and
  associating a Task identity need a browser session, and association means
  pasting the session cookie into a shell
  ([apelogic-ai/steward#179](https://github.com/apelogic-ai/steward/issues/179),
  [apelogic-ai/steward#184](https://github.com/apelogic-ai/steward/issues/184)).
  This is a security limitation; see
  [prerequisites](../prerequisites.md#federated-subject-association-needs-a-pasted-session-cookie).
- **No operator CLI credential yet**
  ([apelogic-ai/steward#146](https://github.com/apelogic-ai/steward/issues/146));
  administer in the browser. Without the CLI, a grant cannot be revoked if
  the browser path is broken; see
  [prerequisites](../prerequisites.md#no-revocation-path-without-the-browser).
- **One apiserver replica.** Steward 0.3.15 keeps browser sessions in the
  apiserver process; a restart signs everyone out
  ([browser session contract](https://github.com/apelogic-ai/steward/blob/v0.3.15/docs/browser-session-contract-v1.md)).
- **Google redirect URIs need a public suffix.** The committed kind hostname
  under `.test` is for CI; a real sign-in needs a hostname under a domain on
  the public suffix list ([local access](../browser-admin/local-access.md#choose-the-steward-hostname)).

## Flux

The generator writes Flux objects for browser-admin in its production shape,
as for [task-auth](task-auth.md#flux): the same releases, `dependsOn` order and
values as the helmfile, the edge CRDs as Flux `Kustomization`s, and no
evaluation piece. Steward renders its own routes, so it follows envoy-gateway
and there is no `steward-edge` release. The operator also supplies the Google
client Secret and literal browser-auth egress CIDRs. Details:
[`examples/flux/browser-admin`](../../examples/flux/browser-admin/README.md).

## Run it

The `e2e-browser-admin` job in [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)
runs [`tests/e2e/browser-admin/run.sh`](../../tests/e2e/browser-admin/README.md).
To evaluate it with a real sign-in, follow [local access](../browser-admin/local-access.md).
