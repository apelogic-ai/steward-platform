# Install order

The order in which to install the platform, and why. This page covers only
what no single product owns: the sequence across products and the values that
join them. Each product's installation guide stays the authority for its own
steps; where this page and a product guide disagree about that product's
procedure, the product guide wins.

The **core** sequence is implemented by the reference installs
([helmfile](../helmfile/README.md), [Flux](../examples/flux/core/README.md);
Flux for [task-auth](../examples/flux/task-auth/README.md) and
[browser-admin](../examples/flux/browser-admin/README.md) too)
and proven by the [core end-to-end test](../tests/e2e/core/README.md). The
**governed** sequence is an outline until the governed reference install lands
([#3](https://github.com/apelogic-ai/steward-platform/issues/3)).

Upgrading an existing pre-platform install instead? Use the
[migration runbook](upgrades/from-pre-platform.md).

## 1. Choose the profile and check prerequisites

| Profile | Installs | Needs |
|---|---|---|
| core | Steward API, admission webhook and controller; cert-manager for service TLS | PostgreSQL ≥ 16 (tested: 16.14, 17.11) |
| task-auth | core plus github-oidc-exchange behind an Envoy Gateway edge | a GitHub Actions job that can reach the edge |
| browser-admin | task-auth plus Steward's web UI and Google sign-in | a Google Workspace OAuth client |
| governed | core plus steward-run, github-oidc-exchange, mcp-gw and the execution dependencies | everything in [prerequisites](prerequisites.md), including browser login |

Core is the starting point even when governed execution is the goal: every
governed step below assumes a working core install. Check
[prerequisites](prerequisites.md) first, in particular amd64 nodes,
Kubernetes 1.32 to 1.34, and a CNI that enforces NetworkPolicy with literal
CIDRs.

## 2. Take the version set from the BOM

[`bom/bom.json`](../bom/bom.json) is the exact set of product releases and
dependency versions tested together, pinned by digest. Install from it rather
than assembling versions from product repositories, and check it the way CI
does ([verification](verification.md)). The Kubernetes version must satisfy
every installed chart at once; the BOM's `kubernetes` range is that
intersection.

To install from a private registry mirror, copy the BOM's artifacts into it
first, digests intact, and check the copy
([registry mirroring](registry-mirroring.md)). The `registry` block of the
platform values (step 3) then points every chart, image and CRD source at the
mirror, and the order below is unchanged.

## 3. Write the platform values and generate

Describe the environment once in a [platform values](platform-values.md)
file: namespaces, the cluster's API address and token audience, TLS mode, and
the database. Then generate every chart's values from it and the BOM:

```sh
scripts/generate.sh environments/<name>/platform-values.yaml
```

Values that several charts must agree on (issuer URLs, audiences, namespaces,
trust domain, workload identities) have one home in that file, so they cannot
disagree between charts.

## 4. Provide what the operator owns

Production installs never use the evaluation pieces. Before installing, in
the Steward namespace:

- **PostgreSQL 16 or later** ([tested versions](prerequisites.md#postgresql))
  and the Secret holding its URL, plus its CA for `verify-full`. Steward's
  [installation guide](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/installation-guide.md)
  lists the required database role.
- **A certificate issuer** that your PKI approves (cert-manager mode), or the
  two TLS Secrets and the public CA bundle (customer-Secret mode).
- **NetworkPolicy addresses** for the Kubernetes API and PostgreSQL, in the
  platform values.

The kind evaluation environment replaces the first two with in-cluster
PostgreSQL and a self-signed CA; see [helmfile/README.md](../helmfile/README.md).

## 5. Install core

In this order; the helmfile's `needs` and the Flux `dependsOn` enforce it.

1. **cert-manager**, from the BOM. Skip it if the cluster already runs
   cert-manager. It must be ready before anything creates `Certificate` or
   `Issuer` objects.
2. **Evaluation pieces**, evaluation only: the self-signed CA issuer and
   in-cluster PostgreSQL.
3. **Steward**, from the BOM. The chart creates its two service certificates
   through cert-manager, and cert-manager injects the CA into Steward's
   admission webhook. Helm installs the `AgentRuntime` CRD from the chart's
   `crds/` directory on first install only; later CRD changes are applied by
   hand ([how](../helmfile/README.md#upgrades-and-the-steward-crd)).

Then check the install the way the end-to-end test does: pods run the BOM
digests, migrations applied, both certificates ready, the webhook denies an
invalid `AgentRuntime`, and the API answers over verified TLS. Steward's
[post-install checks](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/installation-guide.md#post-install-and-delivery-tests)
cover the rest.

Helm creates no Steward users, grants, templates or Envelopes. Administration
after install is Steward's:
[post-install administration](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/installation-guide.md#post-install-administration-not-helm-installation).

## 6. Task authentication (task-auth profile)

The [task-auth profile](profiles/task-auth.md) adds, after core: the Gateway
API CRDs and Envoy Gateway (unless the cluster already runs a Gateway API
implementation with BackendTLSPolicy support), the operator inputs of
github-oidc-exchange (its policy ConfigMap and keyring Secret, and Steward's
copy of its public JWKS), Steward's task identity settings, the edge routes,
and github-oidc-exchange itself. The
[helmfile](../helmfile/README.md) orders them with `needs`, the
[Flux output](../examples/flux/task-auth/README.md) with the same `dependsOn`
(its CRDs through `Kustomization`s), and the
[task-auth end-to-end test](../tests/e2e/task-auth/README.md) proves them
with the steward-run action. It stops before Envelope admission: that needs
a Steward canonical user, which only a browser login creates (step 5 of the
governed sequence below).

The helmfile applies the Gateway API and Envoy Gateway CRDs from a hook, to
the kube context of its releases: run it with `--kube-context <context>`. The
hook refuses to run without one rather than use the current kubeconfig
context ([troubleshooting](../helmfile/README.md#the-crd-hook-and-the-kube-context)).

## 7. Browser administration (browser-admin profile)

The [browser-admin profile](profiles/browser-admin.md) is step 6 plus
Steward's web UI and Google Workspace sign-in. Before installing, add to the
task-auth inputs:

- a Google Cloud **Web application** OAuth client in your Workspace
  organization, consent screen **Internal**, with the single redirect URI
  `<publicEndpoints.steward>/admin/auth/callback`
  ([local access](browser-admin/local-access.md#the-google-oauth-client));
- the Secret holding its client secret, in the Steward namespace;
- literal CIDRs for Steward's egress to Google on 443
  (`networkPolicy.egressCidrs.browserAuth`).

The generator then turns on Steward's `browserAuth`, web UI and its own
`web.httpRoute` edge, with the full public API path list, and projects
steward-run's release coordinates from the BOM. The helmfile installs Steward
after Envoy Gateway, whose release applies the Gateway API CRDs Steward's
routes need, and skips the API-only `steward-edge`. The
[browser-admin end-to-end test](../tests/e2e/browser-admin/README.md) proves
the install up to the redirect to Google.

After install, the first administrator signs in once, is granted the role
with `bootstrap-rbac`, and administers in the browser
([first-admin runbook](browser-admin/first-admin.md),
[walkthrough](browser-admin/walkthrough.md)).

## 8. Governed mode (outline)

Not yet a reference install; tracked in
[#3](https://github.com/apelogic-ai/steward-platform/issues/3), which adds
the governed BOM profile, generation for the reserved platform values, and a
governed end-to-end test. Exact versions will come from the governed BOM
profile; until then, follow each product's guide at its current release.

### What sets the order

A governed Task is admitted only against the submitting user's active User
Envelope in Steward. That user's canonical ID is created at their first
browser login to Steward, and github-oidc-exchange must put that same ID into
the task token. So the exchange's policy cannot be final until Steward is
running and the user has signed in, and steward-run cannot authenticate until
that policy is final. The order resolves this by installing the exchange early
and enrolling it late.

### Sequence

1. **Core Steward**, with browser login and its HTTPS edge (steps 1 to 7
   above).
2. **github-oidc-exchange, not yet enrolled.** Install it so that its issuer
   URL and public JWKS exist; later steps need both. Its
   [installation guide](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/installation.md)
   and [consumer contract](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/consumer-contract-v1.md)
   own the details.
3. **steward-run**: runner controller, runner scale set and the pinned
   reusable workflow
   ([installation](https://github.com/apelogic-ai/steward-run/blob/v0.7.2/docs/installation.md)).
   Governed jobs fail authentication until step 6; one such run shows the real
   GitHub claims that step 6 enrolls.
4. **Wire Steward to the exchange**: Steward's task identity settings take the
   exchange's issuer, audience and public JWKS
   ([Steward installation guide](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/installation-guide.md)).
5. **Provision authority in Steward**: the user signs in once, an
   administrator grants roles, authors Envelope templates and approves the
   user's Envelope. Record the user's canonical ID.
6. **Enroll the exchange policy** with the observed claims and that canonical
   ID
   ([integration](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/integration.md)).
7. **Accept in core mode**: one submission is authenticated and admitted
   against the Envelope without running anything; wrong audience, issuer,
   repository, ref or actor each fail closed.
8. **Execution dependencies**: SPIRE, agent-sandbox, OpenShell, the
   inference proxy and optionally mcp-gw
   ([quickstart](https://github.com/apelogic-ai/mcp-gw/blob/v0.4.11/docs/quickstart.md)),
   then enable Steward's governed execution.
9. **Accept end to end**: a governed Task runs, its output matches, the audit
   record holds the Envelope evidence, and the runtime is cleaned up.

The seams between products (token formats, audiences, trust domain, network
paths) get one page each in #3, linking the product-owned contracts.

## Where this came from

This page supersedes Steward's
[platform deployment order](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/platform-deployment-order.md)
for the cross-product sequence. Steward will link here
([apelogic-ai/steward#140](https://github.com/apelogic-ai/steward/issues/140)).
