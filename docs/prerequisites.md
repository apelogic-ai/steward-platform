# Prerequisites

What you need before installing the platform. This page covers requirements
that follow from combining the products. Each product's own installation guide
remains the authority for its configuration; known gaps link to the product
issue that tracks them. Read the
[known security limitations](#known-security-limitations) before you grant
administrator roles.

## Summary

| Requirement | Core | Governed |
|---|---|---|
| [amd64 nodes](#amd64-nodes) | Required | Required |
| [Kubernetes 1.32–1.34](#kubernetes-version) | 1.32–1.34 | 1.32–1.34 |
| [NetworkPolicy-enforcing CNI](#networkpolicy) | Required | Required |
| [PostgreSQL ≥ 16 (tested: 16.14, 17.11)](#postgresql) | Required | Required |
| [Google Workspace](#google-workspace) | Only for browser login (browser-admin profile) | Required |
| [GitHub.com](#githubcom) | Not needed | Required |
| [PodSecurity `privileged` namespaces](#podsecurity) | Not needed | Required |
| [Paid LLM API](#llm-api) | Not needed | Required |

The **core** profile is Steward alone (API, admission webhook and
controller), with cert-manager issuing its service certificates.
The **governed** profile adds steward-run, github-oidc-exchange, mcp-gw and
their external dependencies. The BOM implements core, task-auth and
browser-admin today. Governed is tracked in
[#3](https://github.com/apelogic-ai/steward-platform/issues/3); mcp-gw is
already pinned for it (`plannedFor`), but nothing installs it yet.

## amd64 nodes

Steward images and release tools are published for linux/amd64 only. The chart
has no scheduling values to keep its pods off other architectures, so a mixed
cluster needs its own node placement.

- Known gap: [apelogic-ai/steward#148](https://github.com/apelogic-ai/steward/issues/148).
- On Apple Silicon, local kind clusters get arm64 nodes and cannot run Steward.
  Use an amd64 Linux machine or VM. See
  [tests/e2e/core/README.md](../tests/e2e/core/README.md).

## Kubernetes version

The platform window is the set of versions the end-to-end tests run on:
**1.32 to 1.34**, for core and governed alike. Two kinds of boundary apply,
and they are not the same thing:

- **Tested boundary, 1.32 to 1.34.** CI runs the core, task-auth and
  browser-admin end-to-end tests on every version in `kubernetes.tested` in
  [bom/bom.json](../bom/bom.json): 1.32, 1.33 and 1.34, each at an exact
  patch release and kind node image. Versions above 1.34 are **untested** by
  this BOM; they are not blocked by any product chart.
- **Chart constraints.** Every product chart in the BOM declares a
  `kubeVersion` floor of 1.32 (Steward from 0.3.2, github-oidc-exchange from
  0.7.1, steward-run from 0.7.2 and mcp-gw from 0.5.0), so Helm refuses an older
  cluster
  ([apelogic-ai/steward#177](https://github.com/apelogic-ai/steward/issues/177),
  [apelogic-ai/github-oidc-exchange#73](https://github.com/apelogic-ai/github-oidc-exchange/issues/73)).
  Only the steward-run runner chart declares a ceiling: 0.7.6 accepts
  `<1.37.0-0`
  ([apelogic-ai/steward-run#62](https://github.com/apelogic-ai/steward-run/issues/62)),
  so a platform that includes the runner (governed) cannot install on 1.37 or
  later. The Steward, github-oidc-exchange and mcp-gw charts have no ceiling.
- **Why not 1.35 and 1.36 yet.** They have not been tested again since the
  fix for what failed on them was pinned. In 2026.10.0-alpha.5, on the kind
  v0.33.0 node images for 1.35.8 and 1.36.4 (kind v0.31.0, which CI uses, has
  no 1.36 image), kind's CNI evaluated NetworkPolicy after the Kubernetes
  Service address was translated to the API server endpoint, port 6443.
  github-oidc-exchange 0.7.2 allowed egress on TCP 443 only, so its Lease
  replay ledger could not reach the API server and every exchange failed with
  `ledger_unavailable`. The core and browser-admin tests passed on those
  images; task-auth did not. Any CNI that evaluates egress after that
  translation, with an API server on a port other than 443, had the same
  failure
  ([apelogic-ai/github-oidc-exchange#58](https://github.com/apelogic-ai/github-oidc-exchange/issues/58)).
  github-oidc-exchange 0.7.3 fixed it, and this BOM pins 0.7.5, whose default
  egress policy allows the API server on TCP 443 and 6443, over IPv4 and
  IPv6. Adding 1.35 (and 1.36 where kind has an image) to `kubernetes.tested`
  needs a newer kind in CI, and is tracked in
  [#34](https://github.com/apelogic-ai/steward-platform/issues/34). Until
  then, 1.35 and 1.36 are untested.

## NetworkPolicy

The product charts ship NetworkPolicies that are on by default and deny
unlisted traffic. Your CNI must enforce NetworkPolicy, and it must honour
`ipBlock` rules: peers such as the Kubernetes API, PostgreSQL and external
identity endpoints are configured as **literal CIDRs**. Namespace or pod
selectors and FQDN rules are not available for those peers.

Plan for:

- stable addresses for PostgreSQL and other peers, or a process that updates
  the CIDRs when they change;
- egress to Google's sign-in endpoints when browser login is on, which Google
  does not publish as stable ranges;
- CNI-specific handling of the Kubernetes API address (service IP or endpoint
  IP, and port);
- webhook calls from the API server. Steward uses the same Kubernetes API
  CIDRs both for its own egress to the API and for admitting the API server's
  calls to its admission webhook, so they must include the addresses that
  traffic comes from (usually the control-plane endpoints, not the Service
  IP).

In the reference install these addresses are `cluster.kubeApi` and
`database.cidrs` in the [platform values](platform-values.md).

Known gaps:
[apelogic-ai/steward#152](https://github.com/apelogic-ai/steward/issues/152),
[apelogic-ai/github-oidc-exchange#56](https://github.com/apelogic-ai/github-oidc-exchange/issues/56),
[apelogic-ai/steward-run#70](https://github.com/apelogic-ai/steward-run/issues/70).

## PostgreSQL

Steward needs a separately operated PostgreSQL database: **PostgreSQL ≥ 16;
tested: 16.14 and 17.11**. The chart does not create one.

- **Minimum, 16.** `dependencies.postgresql.minVersion` in
  [bom/bom.json](../bom/bom.json). Nothing older is tested.
- **Tested, 16.14 and 17.11.** `dependencies.postgresql.tested`, each pinned
  by image digest. CI runs the core end-to-end test on 16.14 on every tested
  Kubernetes version and on 17.11 on the highest one: every Steward database
  migration applies, and the test checks the exact server version. Managed
  database services commonly default to PostgreSQL 17, which is tested.
  Versions above 17 are untested by this BOM; no incompatibility is known.
- **Evaluation only.** The BOM's `postgresql` entry is for evaluation and
  tests: the kind reference install runs it in the cluster, without
  persistence or TLS, at the BOM default (16.14) unless
  `database.evaluationVersion` in the [platform values](platform-values.md)
  names another tested version.

See the
[Steward installation guide](https://github.com/apelogic-ai/steward/blob/v0.3.4/docs/installation/installation-guide.md)
for the required database role. That guide still lists PostgreSQL 16 without a
minimum; stating the same minimum and tested versions there is tracked in
[apelogic-ai/steward#188](https://github.com/apelogic-ai/steward/issues/188).

## Google Workspace

Browser login is Google-only today, and it is restricted to one hosted
Google Workspace domain. Browser login is optional for a core install, but
governed use needs it: users request and approve their User Envelopes through
the browser.

- Steward's `browserAuth.google.organizationId` is a Steward-chosen name, not
  a Google organization ID: `org_` followed by up to 60 lowercase letters,
  digits, `_` or `-`. The Steward 0.3.4 chart schema enforces this
  ([chart README](https://github.com/apelogic-ai/steward/blob/v0.3.4/charts/steward/README.md)).
- The OAuth client is a Google Cloud "Web application" client in the
  Workspace organization, with an Internal consent screen and the single
  redirect URI `<Steward origin>/admin/auth/callback`. Google accepts
  redirect URIs only under a public suffix, so the Steward hostname cannot be
  under `.test` or `.local` for a real sign-in. See
  [local access](browser-admin/local-access.md#the-google-oauth-client).
- The first administrator exists only after a first sign-in and a
  `bootstrap-rbac` grant ([first-admin runbook](browser-admin/first-admin.md)).
- mcp-gw's Google tool connections have their own Google Cloud requirements
  ([apelogic-ai/mcp-gw#80](https://github.com/apelogic-ai/mcp-gw/issues/80)).

## GitHub.com

Governed jobs run on GitHub Actions and authenticate with GitHub.com's Actions
OIDC tokens. GitHub Enterprise Server and GitLab are not supported. A core
install does not use GitHub.

## PodSecurity

Governed mode needs namespaces at the PodSecurity `privileged` level for the
agent runtime sandboxes and for SPIRE. Do not put privileged workloads in the
Steward control-plane namespace
([apelogic-ai/steward#150](https://github.com/apelogic-ai/steward/issues/150)
tracks an example that does). Core mode needs no privileged namespace. The governed
reference install will name the exact namespaces
([#3](https://github.com/apelogic-ai/steward-platform/issues/3)).

## LLM API

Governed mode runs coding agents that call a paid LLM provider API through the
inference proxy. You need an account and API key with that provider. Core mode
makes no LLM calls. The governed end-to-end test planned in
[#3](https://github.com/apelogic-ai/steward-platform/issues/3) will use a mock
model so that CI needs no key.

## Known security limitations

Two properties of the current products affect how far you can trust an
administrator grant and a browser session. Both apply to any install with
browser login (the browser-admin profile, and governed use). Plan for them
before you grant anyone a role.

### No revocation path without the browser

`bootstrap-rbac` only grants roles. Revoking a role needs the operator CLI
(`steward rbac revoke`), and the administrator credential that the CLI needs
cannot be obtained yet
([apelogic-ai/steward#146](https://github.com/apelogic-ai/steward/issues/146)).
Browser administration is the only other path, and it depends on Google
sign-in, the web UI and its edge all working.

- **Risk.** If the browser path is broken (sign-in fails, or the web UI or
  its edge is down), you cannot revoke a grant short of deleting and
  reinstalling Steward. Every grant is then a standing privilege.
- **Interim mitigation.**
  - Restrict who holds the administrator role to the fewest people who need
    it, and grant member roles only when a user needs one.
  - Check that you can sign in and administer in the browser before you
    rely on it to take a grant away.
  - Review the RBAC events in the audit trail regularly, so that an
    unexpected grant is noticed
    ([walkthrough, audit record](browser-admin/walkthrough.md#5-read-the-audit-record)).
- **Tracking.** [apelogic-ai/steward#146](https://github.com/apelogic-ai/steward/issues/146).
  See also [revoking](browser-admin/first-admin.md#revoking) in the
  first-admin runbook.

### Federated subject association needs a pasted session cookie

To let a Task identity act for a user, an administrator associates its
federated subject with that user's canonical ID. Steward has no page for
this and no non-browser path, so the only way is to copy the browser session
cookie into a shell and call the browser API with it
([walkthrough](browser-admin/walkthrough.md#optional-link-a-task-identity-to-the-user-manual)).
That cookie is a bearer credential: anyone who has it acts as that
administrator until the session ends. With policy v6 this is not a one-off
step. Every new caller identity needs its own association, so the cookie is
copied again each time one is enrolled.

- **Risk.** The administrator's session can leak through shell history,
  terminal scrollback, logs, screen sharing or anything else that sees the
  shell, and it can be replayed until it expires.
- **Interim mitigation.**
  - Sign in for the association only, keep the session short, and sign
    out immediately afterwards.
  - Keep the cookie out of shell history and out of any shared terminal,
    file or chat, and clear it from the shell when you are done.
  - Restrict who holds the administrator role, since each of them may need
    to do this.
  - After each association, review the subject's audit trail
    (`GET /admin/api/v1/federated-subjects/<id>/audit`) and the audit
    history for anything else done as that administrator.
- **Tracking.** A non-browser operator path
  ([apelogic-ai/steward#179](https://github.com/apelogic-ai/steward/issues/179))
  and an admin UI page for association
  ([apelogic-ai/steward#184](https://github.com/apelogic-ai/steward/issues/184)).
