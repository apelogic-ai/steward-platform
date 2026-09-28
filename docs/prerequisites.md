# Prerequisites

What you need before installing the platform. This page covers requirements
that follow from combining the products. Each product's own installation guide
remains the authority for its configuration; known gaps link to the product
issue that tracks them.

## Summary

| Requirement | Core | Governed |
|---|---|---|
| [amd64 nodes](#amd64-nodes) | Required | Required |
| [Kubernetes 1.32–1.34](#kubernetes-version) | 1.32–1.34 | 1.32–1.34 |
| [NetworkPolicy-enforcing CNI](#networkpolicy) | Required | Required |
| [PostgreSQL 16](#postgresql) | Required | Required |
| [Google Workspace](#google-workspace) | Only for browser login | Required |
| [GitHub.com](#githubcom) | Not needed | Required |
| [PodSecurity `privileged` namespaces](#podsecurity) | Not needed | Required |
| [Paid LLM API](#llm-api) | Not needed | Required |

The **core** profile is Steward alone (API, admission webhook and
controller), with cert-manager issuing its service certificates.
The **governed** profile adds steward-run, github-oidc-exchange, mcp-gw and
their external dependencies. Only core is in the BOM today; governed is tracked
in [#3](https://github.com/apelogic-ai/steward-platform/issues/3).

## amd64 nodes

Steward images and release tools are published for linux/amd64 only. The chart
has no scheduling values to keep its pods off other architectures, so a mixed
cluster needs its own node placement.

- Known gap: [apelogic-ai/steward#148](https://github.com/apelogic-ai/steward/issues/148).
- On Apple Silicon, local kind clusters get arm64 nodes and cannot run Steward.
  Use an amd64 Linux machine or VM. See
  [tests/e2e/core/README.md](../tests/e2e/core/README.md).

## Kubernetes version

The platform window is **1.32 to 1.34**, for core and governed alike.

- **Floor, 1.32.** The platform supports and tests nothing older. Some product
  charts still declare an older `kubeVersion` floor, so Helm does not stop an
  install on an older cluster; do not rely on that. Tracked in
  [apelogic-ai/steward#177](https://github.com/apelogic-ai/steward/issues/177)
  and
  [apelogic-ai/github-oidc-exchange#73](https://github.com/apelogic-ai/github-oidc-exchange/issues/73).
- **Ceiling, 1.34.** The steward-run runner chart rejects 1.35 and later, so
  the full platform cannot install on 1.35+. Known gap:
  [apelogic-ai/steward-run#62](https://github.com/apelogic-ai/steward-run/issues/62).
- Exact tested versions are in `kubernetes.tested` in
  [bom/bom.json](../bom/bom.json). CI runs the core end-to-end test on each.

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
[apelogic-ai/github-oidc-exchange#58](https://github.com/apelogic-ai/github-oidc-exchange/issues/58),
[apelogic-ai/steward-run#70](https://github.com/apelogic-ai/steward-run/issues/70).

## PostgreSQL

Steward needs a separately operated PostgreSQL database; PostgreSQL 16 is the
tested line. The chart does not create one. The BOM's `postgresql` entry is for
evaluation and tests only: the kind reference install runs it in the cluster,
without persistence or TLS. See the
[Steward installation guide](https://github.com/apelogic-ai/steward/blob/v0.3.1/docs/installation/installation-guide.md)
for the required database role.

## Google Workspace

Browser login is Google-only today, and it is restricted to one hosted
Google Workspace domain. Browser login is optional for a core install, but
governed use needs it: users request and approve their User Envelopes through
the browser.

- Steward's `browserAuth.google.organizationId` is a Steward-chosen name, not
  a Google organization ID: `org_` followed by up to 60 lowercase letters,
  digits, `_` or `-`. The Steward 0.3.1 chart schema enforces this
  ([chart README](https://github.com/apelogic-ai/steward/blob/v0.3.1/charts/steward/README.md)).
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
