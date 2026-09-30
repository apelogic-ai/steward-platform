# First administrator

How the first Steward administrator comes to exist on a browser-admin
install, and how administration continues after that. Helm creates no users,
grants, templates or Envelopes. Steward owns this procedure; this page is the
platform's order of steps, with links to Steward's contracts at v0.3.5:
[browser session contract](https://github.com/apelogic-ai/steward/blob/v0.3.5/docs/browser-session-contract-v1.md#first-local-rbac-grant),
[User Envelope and RBAC administration](https://github.com/apelogic-ai/steward/blob/v0.3.5/docs/operator-envelope-administration.md),
[post-install administration](https://github.com/apelogic-ai/steward/blob/v0.3.5/docs/installation/installation-guide.md#post-install-administration-not-helm-installation).

It assumes the install and the HTTPS path from [local access](local-access.md)
(or your own edge), and the `steward` namespace; adjust names to your
platform values.

## 1. Sign in once

Open `https://<steward host>/admin/sign-in` and sign in with a Google account
in the configured Workspace domain. Google returns to
`/admin/auth/callback`; Steward verifies the signed ID token (issuer, client
ID, nonce, verified email and the exact hosted domain) and creates your
**canonical user** on this first sign-in. An account outside the domain, or a
personal Google account, is refused.

A new user holds the ordinary user role and no member roles. There is no
first-login administrator shortcut, and Workspace membership grants no
Steward authority.

Open `https://<steward host>/settings` and copy your canonical user ID: `usr_`
followed by 32 hexadecimal characters. It is opaque; emails are never
authorization keys.

## 2. Grant the administrator role

`bootstrap-rbac` records the first grant directly in Steward's database. It
runs inside the apiserver Pod, where the database URL is already projected:

```sh
kubectl --context <context> -n steward exec deploy/steward-apiserver -- \
  /usr/local/bin/steward bootstrap-rbac \
  --user-id usr_<32 hex> \
  --grant administrator \
  --actor <your name, for the audit record>
```

All three flags are required. The grant is an append-only RBAC event with
your `--actor` as the audited operator. The same command also grants a
member role (`--grant <role>`), which the [walkthrough](walkthrough.md) uses.
Steward keeps `bootstrap-rbac` as its compatibility bootstrap; later grants
belong to the operator CLI.

A browser session keeps the roles it was created with. **Sign out and sign in
again** (or wait for the one-hour session to end); the new session carries
the administrator role, and the `/admin` pages open.

## 3. Administer in the browser

With an administrator session you can author Envelope templates, approve or
reject Envelope requests, provision Envelopes for users, and read the audit
history: continue with the [walkthrough](walkthrough.md). These pages call
`/admin/api/v1`, which accepts only an administrator browser session, with
Steward's origin, fetch-metadata and CSRF checks on every change.

## 4. The operator CLI

Steward's day-two command line is the `steward` binary in the apiserver
image: the image's entrypoint, with `rbac`, `templates` and `envelopes`
subcommands. It is a client of Steward's bearer-authenticated operator API
(`/admin/operator/v1`, routed to the apiserver by the edge) and never
connects to the database. Its configuration
([Steward's guide](https://github.com/apelogic-ai/steward/blob/v0.3.5/docs/operator-envelope-administration.md#supported-operator-cli)):

| Variable | Value |
|---|---|
| `STEWARD_OPERATOR_API_URL` | the HTTPS origin, `https://<steward host>` |
| `STEWARD_OPERATOR_TOKEN_FILE` | a file holding a short-lived administrator bearer token |
| `STEWARD_OPERATOR_CA_FILE` | optional: a private CA for the origin, for example the evaluation edge CA |

Run it with the BOM's apiserver image, pinned by digest. The image is
linux/amd64 only
([apelogic-ai/steward#148](https://github.com/apelogic-ai/steward/issues/148)).
From the kind host, through the local port-forward:

```sh
image="$(jq -r .products.steward.images.apiserver bom/bom.json)"
docker run --rm --platform linux/amd64 --network host \
  --add-host <steward host>:127.0.0.1 \
  -e STEWARD_OPERATOR_API_URL=https://<steward host> \
  -e STEWARD_OPERATOR_TOKEN_FILE=/run/steward/operator-token \
  -e STEWARD_OPERATOR_CA_FILE=/run/steward/ca.crt \
  -v "${PWD}/operator-token:/run/steward/operator-token:ro" \
  -v "${PWD}/steward-platform-edge-ca.crt:/run/steward/ca.crt:ro" \
  "${image}" rbac users list --output json
```

In the cluster, `kubectl run` with the same image and arguments works the same
way, with the token file mounted from a Secret.

**Obtaining the administrator token is not documented yet.** Steward's
operator API authenticates the bearer with Kubernetes TokenReview and
requires Steward's configured administrator group, which the chart does not
expose and which ServiceAccount tokens cannot carry; a verified Identity task
token with that group is the other accepted form. Neither is a documented
operator procedure in Steward 0.3.5
([apelogic-ai/steward#146](https://github.com/apelogic-ai/steward/issues/146)).
Until that issue lands, administer through the browser (step 3) and use
`bootstrap-rbac` for grants; this page will add the credential step when
Steward documents it. Do not work around it with a hand-made token.

## Revoking

Revocation is also an append-only event, recorded with
`steward rbac revoke admin` (or `revoke member-role`) through the operator
CLI. `bootstrap-rbac` only grants, so until the CLI has a credential
([apelogic-ai/steward#146](https://github.com/apelogic-ai/steward/issues/146))
an evaluation install is revoked by deleting it. See
[known security limitations](../prerequisites.md#no-revocation-path-without-the-browser).
