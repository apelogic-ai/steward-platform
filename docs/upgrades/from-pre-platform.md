# Migrate a pre-platform install to the current BOM

This runbook is for operators who installed the products before this
repository existed. It covers the move from the 0.2.6-era set to the release
set of platform BOM `2026.10.0-alpha.6` (the same product releases as
`2026.10.0-alpha.5`). The current BOM, `2026.10.0-alpha.12`, pins newer
releases of every product (Steward 0.3.13, github-oidc-exchange 0.7.5,
steward-run 0.8.1, mcp-gw 0.5.7): finish this runbook first, then apply
[upgrading from 2026.10.0-alpha.6](../releases/2026.10.0-alpha.7.md#upgrading-from-2026100-alpha6)
in the alpha.7 release notes,
[upgrading from 2026.10.0-alpha.7](../releases/2026.10.0-alpha.8.md#upgrading-from-2026100-alpha7)
in the alpha.8 release notes,
[upgrading from 2026.10.0-alpha.8](../releases/2026.10.0-alpha.9.md#upgrading-from-2026100-alpha8)
in the alpha.9 release notes,
[upgrading from 2026.10.0-alpha.9](../releases/2026.10.0-alpha.10.md#upgrading-from-2026100-alpha9)
in the alpha.10 release notes,
[upgrading from 2026.10.0-alpha.10](../releases/2026.10.0-alpha.11.md#upgrading-from-2026100-alpha10)
in the alpha.11 release notes and
[upgrading from 2026.10.0-alpha.11](../releases/2026.10.0-alpha.12.md#upgrading-from-2026100-alpha11)
in the alpha.12 release notes, in that order.

| Product | From (0.2.6-era) | To |
|---|---|---|
| Steward | 0.2.6 | **0.3.2** |
| github-oidc-exchange | 0.5.x (Steward 0.2.6 pinned 0.5.1) | **0.7.2** |
| steward-run | 0.5.x (Steward 0.2.6 pinned 0.5.0) | **0.7.2** |
| mcp-gw | 0.4.x (Steward 0.2.6 accepted 0.4.9 to 0.4.11) | **0.5.0** |
| Governed dependencies (SPIRE, OpenShell, agent-sandbox, LiteLLM) | as pinned by Steward 0.2.6 | no change in this runbook; see [Governed dependencies](#governed-dependencies) |

[`bom/bom.json`](../../bom/bom.json) is authoritative. Take exact versions,
commits and digests from it, never from this page. If the BOM in your checkout
names different product versions from the table above, the BOM wins and this
page may be out of date.

This page covers only the order across products and the inputs that change.
Each product's upgrade guide, linked at its pinned tag, stays the authority for
that product's procedure. Where this page and a product guide disagree about
that product, the product guide wins. Statements marked **(inferred)** are
derived from the products' declared contracts; no product states them
directly, and this repository does not test the migration.

## Contents

1. [Before you start](#before-you-start)
2. [Order of operations](#order-of-operations)
3. [Mixed-version states](#mixed-version-states)
4. [Stage 0: prepare and move Kubernetes to 1.32](#stage-0-prepare-and-move-kubernetes-to-132)
5. [Stage 1: github-oidc-exchange 0.5.x to 0.7.2, policy v5 unchanged](#stage-1-github-oidc-exchange-05x-to-072-policy-v5-unchanged)
6. [Stage 2: Steward 0.2.6 to 0.3.2, v2 identity only](#stage-2-steward-026-to-032-v2-identity-only)
7. [Stage 3: steward-run 0.5.x to 0.7.2, explicit inputs kept](#stage-3-steward-run-05x-to-072-explicit-inputs-kept)
8. [Stage 4: turn on discovery](#stage-4-turn-on-discovery)
9. [Stage 5 (optional): policy v6 and `steward-task-v3`](#stage-5-optional-policy-v6-and-steward-task-v3)
10. [Stage 6: mcp-gw 0.4.x to 0.5.0](#stage-6-mcp-gw-04x-to-050)
11. [Governed dependencies](#governed-dependencies)
12. [Final acceptance](#final-acceptance)
13. [Known gaps](#known-gaps)

## Before you start

- **Read each product guide first.** This page names what changes; the
  guides give the commands:
  - Steward: [upgrade to v0.3.0](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/upgrade-v0.3.0.md)
    (its step 9 covers 0.3.2),
    [federated Task identity upgrade](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/federated-task-identity-upgrade.md),
    [chart README](https://github.com/apelogic-ai/steward/blob/v0.3.2/charts/steward/README.md),
    [CHANGELOG](https://github.com/apelogic-ai/steward/blob/v0.3.2/CHANGELOG.md).
    `upgrade-v0.2.0.md` in the same directory covers 0.1.23 to 0.2.6 and does
    not apply here.
  - github-oidc-exchange: the per-version guides
    [v0.6.0](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/upgrade-v0.6.0.md),
    [v0.7.0](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/upgrade-v0.7.0.md),
    [v0.7.1](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/upgrade-v0.7.1.md),
    [v0.7.2](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/upgrade-v0.7.2.md),
    and the [installation guide](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/installation.md).
  - steward-run: [installation](https://github.com/apelogic-ai/steward-run/blob/v0.7.2/docs/installation.md)
    (its upgrade and rollback sections), release notes
    [v0.6.0](https://github.com/apelogic-ai/steward-run/blob/v0.7.2/docs/release-notes-v0.6.0.md),
    [v0.7.0](https://github.com/apelogic-ai/steward-run/blob/v0.7.2/docs/release-notes-v0.7.0.md),
    [v0.7.1](https://github.com/apelogic-ai/steward-run/blob/v0.7.2/docs/release-notes-v0.7.1.md),
    [v0.7.2](https://github.com/apelogic-ai/steward-run/blob/v0.7.2/docs/release-notes-v0.7.2.md).
  - mcp-gw: [CHANGELOG](https://github.com/apelogic-ai/mcp-gw/blob/v0.5.0/CHANGELOG.md)
    (upgrade notes for 0.4.10, 0.4.11 and 0.5.0),
    [external platform issuer](https://github.com/apelogic-ai/mcp-gw/blob/v0.5.0/docs/external-platform-issuer.md),
    [chart README](https://github.com/apelogic-ai/mcp-gw/blob/v0.5.0/deploy/k8s/chart/README.md).
- **Verify every artifact before installing it**, the way this repository's
  CI does ([verification](../verification.md)): digests, GitHub artifact
  attestations for Steward and mcp-gw, and the cosign-signed release
  manifests for github-oidc-exchange and steward-run.
- **Optionally adopt the platform tooling.** For the core, task-auth and
  browser-admin shapes, the [generator](../platform-values.md) writes Steward's
  and the exchange's values from one platform values file and the BOM,
  including the exact Steward route lists and the steward-run release
  projection that this migration needs. It does not generate governed mode
  yet ([#3](https://github.com/apelogic-ai/steward-platform/issues/3)). If you
  keep your own values files, apply the changes below to them by hand.

## Order of operations

```text
Stage 0  prepare; Kubernetes to 1.32-1.34              rollback: nothing changed yet
Stage 1  github-oidc-exchange -> 0.7.2 (policy v5)     rollback: helm rollback
Stage 2  Steward -> 0.3.2 (v2 only, discovery off)     rollback: bounded, see Stage 2
Stage 3  steward-run -> 0.7.2 (explicit inputs kept)   rollback: previous release as one unit
Stage 4  discovery on; drop steward-run explicit inputs rollback: restore the inputs
Stage 5  optional: policy v6 / steward-task-v3         rollback: exchange to v5 first, then Steward
Stage 6  mcp-gw -> 0.5.0                               rollback: helm rollback
         (optional) Kubernetes to 1.35 or 1.36
```

Why this order:

- **Kubernetes first.** Every target chart requires Kubernetes 1.32 or newer,
  and every old chart accepts 1.32 to 1.34 (steward-run 0.5.0 caps at
  `<1.35`). Moving the cluster to 1.32, 1.33 or 1.34 first keeps both the old
  and the new set within their declared ranges.
- **The exchange before Steward.** github-oidc-exchange does not call or
  depend on Steward. On policy v5, 0.7.2 issues the same `steward-task-v2`
  token as 0.5.1, which Steward 0.2.6 already accepts, and it adds the RFC
  8414 discovery document that steward-run's discovery needs later.
- **Steward before steward-run.** Steward 0.3.x with browser administration
  refuses to start without a steward-run 0.7.0 or later release projection,
  and steward-run's discovery needs Steward 0.3.x's protected-resource
  metadata. Steward 0.3.2 still accepts submissions from 0.5.x callers (see
  [Mixed-version states](#mixed-version-states)), so steward-run can follow
  in the same maintenance window.
- **Discovery, then v6, each as its own change.** Each product guide keeps
  the binary upgrade separate from activating a new identity contract.
- **mcp-gw after Steward.** Steward 0.3.2 declares its connection authority
  compatible with mcp-gw 0.4.9 through 0.5.0; Steward 0.2.6 declared only
  0.4.9 to 0.4.11.

Do each stage in a staging environment first, then in production, and run the
stage's checks before starting the next one.

## Mixed-version states

A state not in this table is not declared valid by any product.

| State | Valid? | Basis |
|---|---|---|
| Kubernetes 1.32 to 1.34 with the whole 0.2.6-era set | Yes, by declared chart ranges **(inferred)** | Chart `kubeVersion`: Steward 0.2.6 and exchange 0.5.1 `>=1.30`; steward-run 0.5.0 `>=1.30 <1.35`; mcp-gw 0.4.x declares none. |
| Exchange 0.7.2 on policy v5 with Steward 0.2.6 and steward-run 0.5.x | Yes **(inferred)** | The exchange guides state v5 output is unchanged (`steward-task-v2`). Outside Steward 0.2.6's exact pin of exchange 0.5.1. |
| Exchange 0.5.1 with a v6 policy | **No** | [Exchange v0.6.0 guide](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/upgrade-v0.6.0.md): 0.5.1 cannot read v6. |
| Steward 0.2.6 and 0.3.2 pods side by side, during the rolling upgrade | Only with v2 identity, no template authoring and federated subjects off | [Steward upgrade to v0.3.0](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/upgrade-v0.3.0.md), [federated identity upgrade](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/federated-task-identity-upgrade.md). |
| Steward 0.3.2 with steward-run 0.5.x callers | Yes, while each submitting user has exactly one active Envelope | The Task API stays `steward.task/v2`; callers without `envelopeDigest` get `409` once a user has several active Envelopes (Steward 0.3.0 CHANGELOG). With browser administration on, Steward's configured steward-run projection must still name 0.7.0 or later. |
| steward-run 0.7.2 with Steward 0.2.6 | Only with the deprecated explicit exchange inputs and no `envelope-digest` **(inferred)** | Steward 0.2.6 serves no `/.well-known/oauth-protected-resource`; `envelope-digest` needs Steward 0.3.0 or later. Not a recommended stop. |
| steward-run 0.7.2 discovery | Needs Steward 0.3.x with `taskIdentity.resource` set, and exchange 0.7.0 or later | Steward serves its metadata only when `resource` is set; exchange 0.7.0 added RFC 8414 metadata. |
| Policy v6 / `steward-task-v3` | Needs exchange 0.6.0 or later and every Steward apiserver on 0.3.x with `taskIdentity.federatedSubjects.enabled: true` | Federated identity upgrade guide. |
| mcp-gw 0.4.9 to 0.5.0 with Steward 0.3.2 | Yes | Steward 0.3.2 [chart README](https://github.com/apelogic-ai/steward/blob/v0.3.2/charts/steward/README.md), "Governed provider connections": authority `steward.connections.github/v2` is used by mcp-gw 0.4.9 through 0.5.0. |
| mcp-gw 0.5.0 with Steward 0.2.6 | Not declared; avoid | Steward 0.2.6's manifest listed mcp-gw 0.4.9, 0.4.10 and 0.4.11 only. |

## Stage 0: prepare and move Kubernetes to 1.32

1. **Record the current state** of every product: Helm release names and
   revisions, chart and image digests, complete values files, the exchange
   policy ConfigMap and keyring Secret `resourceVersion`s, the JWKS key IDs,
   Steward's migration head (0039 on 0.2.6), and the steward-run workflow and
   action commits your callers use. Every rollback below needs these.
2. **Back up Steward's PostgreSQL** with an encrypted backup and prove that
   it restores. Steward's migrations are forward-only; a Helm rollback does
   not reverse them.
3. **Take an inventory of the governed dependencies** you run (SPIRE,
   OpenShell, agent-sandbox, LiteLLM) with their digests. Steward 0.3.0
   removed the manifest that pinned them; see
   [Governed dependencies](#governed-dependencies).
4. **Check the exchange signing keys.** github-oidc-exchange 0.7.1 and later
   report not ready when the current key has seven days or less left. Rotate
   now if it does (see [Stage 1](#stage-1-github-oidc-exchange-05x-to-072-policy-v5-unchanged)).
5. **Upgrade Kubernetes to 1.32, 1.33 or 1.34.** The target set supports 1.32
   to 1.36 (the BOM `kubernetes` range, tested in CI on each version), but the
   old steward-run chart declares `<1.35`. Move beyond 1.34 only after Stage 3.

**Check:** every product still works as before on the new Kubernetes
version: a steward-run job exchanges a token and Steward admits or refuses it
as it did before the cluster upgrade.

## Stage 1: github-oidc-exchange 0.5.x to 0.7.2, policy v5 unchanged

Upgrade the binary and chart only. Keep the v5 policy ConfigMap, the keyring
Secret, the issuer, the inbound audience and the replay Leases unchanged.

The exchange publishes one guide per minor step and states that older
installations follow their version-specific guides; it does not say whether
0.5.1 to 0.7.2 can be a single Helm upgrade. Run the preflight of every guide
from v0.6.0 to v0.7.2. If you want the documented path exactly, upgrade
through 0.6.0, 0.7.0 and 0.7.1 in turn; the BOM pins only 0.7.2.

### Exchange: breaking inputs

| Input | 0.5.1 | 0.7.2 | Since |
|---|---|---|---|
| Chart `kubeVersion` | `>=1.30.0-0` | `>=1.32.0-0` | 0.7.1 |
| `config.policyContract` | absent | required. For this stage set `github-oidc-exchange.apelogic.io/v5` explicitly; the process refuses to start if the ConfigMap's version differs. | 0.6.0 |
| `config.policyConfigMapName` | optional | set it explicitly to your existing v5 ConfigMap | 0.6.0 guide |
| `config.issuerUrl` | HTTPS URL, path allowed | HTTPS origin only: no path, query, fragment or userinfo. A path is a separate trust migration to do before this upgrade. The chart tolerates one trailing `/` and strips it; downstream values (Steward `taskIdentity.issuer`) must use the form without it. | 0.7.0 |
| `config.githubExchangeAudience` | at least 1 character | 1 to 255 printable ASCII characters, no spaces | 0.7.0 |
| `config.keyExpiryReadinessThresholdSeconds` | absent | required, default `604800` (seven days), range 120 to 31536000. `/readyz` returns `503` inside the window, so `helm upgrade --wait` times out on a nearly expired key. | 0.7.1 |
| `networkPolicy.metricsNamespaceSelector`, `networkPolicy.metricsPodSelector` | optional `{}`; empty maps admitted every Pod to port 8080, which is also the exchange port | both must be non-empty when `serviceMonitor.enabled: true` | 0.7.1 |
| Public routes | three paths | adds `Exact /.well-known/oauth-authorization-server`. If your edge does not use the chart's Ingress or HTTPRoute, add it there. | 0.7.0 |

Detail: [v0.7.0 guide](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/upgrade-v0.7.0.md)
and [v0.7.1 guide](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/upgrade-v0.7.1.md).
The v0.7.2 guide's example uses the release name `github-oidc-exchange`,
where the other guides use `identity`; use your release's actual name.

### Keys and Steward's static JWKS

0.7.1 adds key lifetime enforcement: signing stops at a key's `not_after`,
startup fails if the current key is already outside its window, and the
gauges `github_oidc_exchange_signing_key_seconds_until_expiry` (and
`github_oidc_exchange_workload_signing_key_seconds_until_expiry` when the
workload exchange is on) report the time left. Alert on them.

Steward does not fetch the issuer's JWKS; it reads a copy from the ConfigMap
named by `taskIdentity.publicJwksConfigMap`. When you rotate, follow the
exchange's [rotation runbook](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/installation.md#6-rotation-recovery-uninstall)
and at its static-verifier steps:

1. After adding the next key and before activating it, replace `jwks.json`
   in Steward's ConfigMap with the output of `keyring-tool export-jwks`
   (both key IDs).
2. **Restart `steward-apiserver`.** Steward 0.3.2 reads the file only at
   startup, and its chart has no checksum annotation for this ConfigMap.
   Steward accepts at most 16 ES256 signing keys with unique key IDs.
3. Activate the new key only when every apiserver replica holds both key IDs.
4. After retiring the old key, publish and restart again.

The same applies to any other static verifier of the exchange's tokens.

### Exchange: rollback

`helm rollback` to the recorded revision, with the v5 ConfigMap untouched.
Rolling back from 0.7.x to 0.6.0 removes the RFC 8414 document; rolling back
to 0.7.0 removes expiry enforcement and the gauges but does not undo a key
rotation or a JWKS publication done separately. Never roll back only the
image.

### Check after Stage 1

- [ ] Exchange Pods run the BOM image digest; `/healthz` and `/readyz` return
      `200`.
- [ ] `/.well-known/oauth-authorization-server` and
      `/.well-known/openid-configuration` return identical documents naming
      the issuer, `jwks_uri`, `github_oidc_exchange_endpoint` and
      `github_oidc_audience`, with both policy versions and both identity
      contracts listed. Discovery lists both whatever policy is active, so it
      does not prove which one is.
- [ ] `/jwks.json` publishes the same ES256 key IDs as Steward's JWKS
      ConfigMap.
- [ ] The expiry gauges are present.
- [ ] An existing steward-run job exchanges a token, the exchange logs
      `exchange_issued` with `identity_contract=steward-task-v2`, and Steward
      0.2.6 accepts the token as before. A wrong audience and a replayed
      assertion are refused.

## Stage 2: Steward 0.2.6 to 0.3.2, v2 identity only

Install the 0.3.2 chart and images as one set from the BOM. Keep Task
orchestration staged and `taskIdentity.federatedSubjects.enabled: false` for
this rollout. Follow Steward's
[upgrade to v0.3.0](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/upgrade-v0.3.0.md)
end to end; its "Before rollout" list is the preflight. Stop Envelope template
authoring until every apiserver and controller runs 0.3.2: there is no
dual-write between the two versions.

### Steward: breaking inputs

| Input | 0.2.6 | 0.3.2 |
|---|---|---|
| Chart `kubeVersion` | `>=1.30.0-0` | `>=1.32.0-0` |
| `config.apiserver.capabilityCatalog` | `schemaVersion: steward.capability-catalog/v1` | `steward.capability-catalog/v2`: every `tools[]` entry needs `accessClass` (`read`, `write` or `destructive`), and a `catalogs` array is required. v1 is rejected by the schema, the runtime and preflight. Convert before the rollout. |
| `config.apiserver.stewardRunRelease` | absent | Required when `browserAuth.enabled: true`; the apiserver refuses to start on a missing, malformed, mutable or pre-0.7.0 value. Project it from steward-run 0.7.2's signed `oss-release-manifest.json` (schema 3), which the BOM pins: `schemaVersion` as `manifestSchemaVersion` (the number `3`), `version`, `workflowRepository`, `workflowCommit`, `actionCommit`, and `image` as `governedJobContainerImage`. Mapping: [product compatibility and installation BOM](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/governed-platform-compatibility.md); this repository's generator does it for browser-admin ([platform values](../platform-values.md)). |
| `web.httpRoute.apiPaths` (when `web.httpRoute.enabled`) | any non-empty list | exactly these seven entries, in this order: `Exact /.well-known/oauth-protected-resource`, `PathPrefix /admin/api`, `PathPrefix /admin/auth`, `Exact /admin/connections/github/callback`, `PathPrefix /admin/operator`, `PathPrefix /app/api`, `PathPrefix /v1`. The 0.2.6 example lacked `/.well-known/oauth-protected-resource` and `/admin/operator`. |
| `web.httpRoute.webPaths` (when `web.httpRoute.enabled`) | any non-empty list | exactly `[{type: PathPrefix, value: /}]` |
| `browserAuth.google.organizationId` | Helm accepted any non-blank string; the runtime already required the `org_` form | `^org_[a-z0-9_-]{1,60}$`, 5 to 64 characters, in the schema, the runtime and preflight. Only a bare `org_` is newly rejected. **Do not change the value**: it is part of every canonical user's identity key. |
| `taskIdentity.resource`, `taskIdentity.federatedSubjects.enabled` | absent | New required keys. Leave `resource: ""` and `federatedSubjects.enabled: false` in this stage; Stage 4 and Stage 5 set them. With `taskIdentity.enabled: false` they must stay at those values. |
| `config.apiserver.customEnvelopeSafetyCeiling` | absent | Optional, default `null`, which rejects template-free custom Envelope requests. Set the complete ceiling only if you want them. |
| `config.apiserver.defaultLlmTemplate` | absent | Present in the chart defaults with `enabled: false`. If you enable it, set every value explicitly. |
| `connectionsBridge.mcpGatewayAuthorityContract` | optional | Unchanged key; set `steward.connections.github/v2` in place of the deprecated `mcpGatewayVersion` (never both). See [Stage 6](#stage-6-mcp-gw-04x-to-050). |
| `networkPolicy.identityExchangeNamespace` | default `identity-exchange` | Unchanged. It must be the namespace github-oidc-exchange runs in (for example `identity`); Steward's controller egress to the workload exchange uses it when execution is on. The exchange's workload pairing guide omits it ([github-oidc-exchange#88](https://github.com/apelogic-ai/github-oidc-exchange/issues/88)). |

Also changed: the operator CLI talks to the API with
`STEWARD_OPERATOR_API_URL` and `STEWARD_OPERATOR_TOKEN_FILE` instead of
database credentials, but its administrator credential is not documented yet
([apelogic-ai/steward#146](https://github.com/apelogic-ai/steward/issues/146));
administer in the browser. Migrations 0040 to 0051 apply on upgrade and are
additive.

### Rollback boundary

A Helm rollback does not reverse migrations. Returning to 0.2.6 is supported
only if all of these hold: v3 identity was never enabled (or is disabled
first), no template-free request exists, every user has at most one active
Envelope, no template revision was authored after the upgrade, and all
migrations and history stay in place. Otherwise roll forward. The exact
conditions are in the guide's "Rollback boundary" section. This is the last
point where the whole migration can be undone cheaply; decide here.

### Check after Stage 2

- [ ] Every Steward Pod runs the BOM digests; the migration head is 0051.
- [ ] Both service certificates are ready, the admission webhook denies an
      invalid `AgentRuntime`, and the API answers over verified TLS (the checks
      of the [core end-to-end test](../../tests/e2e/core/README.md)).
- [ ] With the web UI on: every one of the seven API paths reaches the
      apiserver through your edge, not the web UI, and `/admin/auth/login`
      redirects to Google with your client ID, the redirect URI
      `<origin>/admin/auth/callback` and your hosted domain (the checks of the
      [browser-admin end-to-end test](../../tests/e2e/browser-admin/README.md)).
      An administrator signs in and sees the request queue and catalog.
- [ ] The apiserver started with the configured `stewardRunRelease`.
- [ ] An existing steward-run 0.5.x caller still submits with its explicit
      exchange inputs, and Steward authenticates the v2 token and admits it
      against the user's single active Envelope.
- [ ] `/.well-known/oauth-protected-resource` answers `503` (discovery is not
      configured yet).
- [ ] The threshold behaviour in the guide's "Migration and activation"
      section holds before you re-enable template authoring.

## Stage 3: steward-run 0.5.x to 0.7.2, explicit inputs kept

Upgrade the runner scale set chart and move callers to the new reusable
workflow, as one release: chart, image, workflow commit and action commit all
from the 0.7.2 signed manifest. Keep the deprecated explicit exchange inputs
for now; the v0.6.0 release notes order is "publish Steward and Identity
metadata first, upgrade one coherent steward-run release, verify the explicit
path, then remove the compatibility inputs".

### steward-run: breaking and changed inputs

| Item | 0.5.x | 0.7.2 |
|---|---|---|
| Chart `kubeVersion` (`steward-run-arc`) | `>=1.30.0-0 <1.35.0-0` | `>=1.32.0-0 <1.37.0-0` (1.32 to 1.36). If you carried a fork of the chart only to lift the old ceiling, drop it. |
| Runner Pod security context | loosely validated | The values schema now requires: pod `runAsNonRoot: true` and an integer `runAsUser` of at least 1; runner container `name`, `image`, `imagePullPolicy`, `command: ["/home/runner/run.sh"]`, `securityContext` with `allowPrivilegeEscalation: false`, `privileged: false`, `capabilities.drop: ["ALL"]` and no `add`, a boolean `readOnlyRootFilesystem`, and `cpu` and `memory` in both `resources.requests` and `resources.limits`. The complete values file from the 0.5.0 guide already complies; overlays that dropped fields fail. |
| Private CA for Steward and the exchange | volume `steward-run-ca` at `/etc/steward-run`, input `steward-ca-certificate-file: /etc/steward-run/ca.crt` | ConfigMap volume `steward-run-trust-bundle` mounted read-only at `/etc/steward-run/trust`, and `NODE_EXTRA_CA_CERTS=/etc/steward-run/trust/ca.crt`. `steward-ca-certificate-file` is deprecated. |
| Caller workflow | a fork's `steward-task.yml`, pinned to a fork commit | `uses: apelogic-ai/steward-run/.github/workflows/steward-task-customer.yml@<workflowCommit>`, a literal 40-hex commit from the signed manifest (GitHub does not accept an expression in `uses:`). The caller job needs `permissions: {contents: read, id-token: write}`. Cross-repository use of another private fork is unsupported. |
| `identity-exchange-url`, `identity-exchange-audience` | required workflow inputs | optional and deprecated. A non-empty URL bypasses discovery; the audience is valid only with the URL. Keep both in this stage. |
| Job timeout | fixed 15 minutes | `job-timeout-minutes` (reusable workflows only), default `15`, range 1 to 360 |
| Runtime binding timeout | fixed attempt cap | `runtime-binding-timeout-minutes` (workflows and action), default `10`, range 1 to 360 |
| `envelope-digest` | absent | optional selector `steward:sha256:<64 hex>`; needs Steward 0.3.0 or later. Required once a user has several active Envelopes. |

Detail: [installation](https://github.com/apelogic-ai/steward-run/blob/v0.7.2/docs/installation.md)
and the [customer workflow](https://github.com/apelogic-ai/steward-run/blob/v0.7.2/.github/workflows/steward-task-customer.yml).
Running the action directly (not through the reusable workflow) needs Node 24
on `PATH` ([apelogic-ai/steward-run#69](https://github.com/apelogic-ai/steward-run/issues/69)).

**The exchange policy needs no change for the workflow switch.** steward-run's
guide asks you to update the "Identity allowlist" for the exact
`job_workflow_ref`, but exchange policies v5 and v6 have no workflow selector:
it was removed in exchange 0.5.0. The policy selects the caller repository,
subject, event and ref; the workflow ref and SHA travel in the token's signed
provenance, and Steward's source binding is where the workflow is authorized.
The exchange's
[integration guide](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/integration.md)
still shows the legacy `steward-task.yml`; the correct workflow is
`steward-task-customer.yml` as above
([github-oidc-exchange#88](https://github.com/apelogic-ai/github-oidc-exchange/issues/88)).

### steward-run: rollback

Restore the previous release as one unit: chart, image digest, reusable
workflow commit and caller configuration together (`helm rollback` for the
chart). Rolling back to 0.5.x means callers drop `job-timeout-minutes`,
`runtime-binding-timeout-minutes` and `envelope-digest` and keep the explicit
inputs, and the cluster must be below 1.35 for the 0.5.0 chart. There is no
data migration.

### Check after Stage 3

- [ ] Runner Pods run the BOM `runner` image digest; the steward-run
      controller preflight reports runner linkage verified.
- [ ] A caller on `steward-task-customer.yml@<workflowCommit>` with the
      explicit inputs completes a Task (or reaches the answer your Envelope
      setup expects).
- [ ] The workflow and action commits your callers use equal the BOM's
      `products.steward-run.workflow.commit` and `action.commit`, and equal
      Steward's `stewardRunRelease`.

After this stage every chart accepts Kubernetes 1.35 and 1.36; the cluster
can move within the BOM's tested window.

## Stage 4: turn on discovery

1. **Steward**: set `taskIdentity.resource` to the public Steward origin
   (`https://steward.example.com`: HTTPS, no path, no trailing slash) and
   `taskIdentity.issuer` to the exchange issuer exactly as the exchange
   publishes it. Keep `federatedSubjects.enabled: false`.
2. Check `GET <origin>/.well-known/oauth-protected-resource`: `resource` is
   the origin, `authorization_servers` is exactly `[<issuer>]`,
   `steward_task_token_contracts` is `["steward-task-v2"]`, with
   `Cache-Control: public, max-age=300`.
3. **steward-run callers**: remove `identity-exchange-url`,
   `identity-exchange-audience` and `steward-ca-certificate-file`, and set
   `steward-api-url` to exactly the value of `taskIdentity.resource`.
   Discovery compares raw strings; a trailing slash is a different string.

Rollback: put the explicit inputs back on the callers; optionally clear
`taskIdentity.resource`.

### Check after Stage 4

- [ ] A caller with only `steward-api-url` discovers the exchange, exchanges a
      token and submits; the job log shows no deprecation warnings.
- [ ] With the task-auth shape, the discovery assertions of the
      [task-auth end-to-end test](../../tests/e2e/task-auth/README.md#assertions)
      hold against your install (except that Steward lists only
      `steward-task-v2` until Stage 5).

## Stage 5 (optional): policy v6 and `steward-task-v3`

Policy v6 lets the exchange authenticate only the signed numeric repository,
without mapping each GitHub actor to an email address in the exchange policy.
The token becomes `steward-task-v3` with subject
`github-actions:actor:<numeric id>`, and Steward owns the binding of that
subject to a user. Steward 0.3.2's compatibility contract still names v5 and
`steward-task-v2` as its default; v6 is opt-in on both sides. This
repository's task-auth and browser-admin profiles use v6
([why](../profiles/task-auth.md#choices-and-why)).

Order, Steward first:

1. **Steward**: with every apiserver on 0.3.2, set
   `taskIdentity.federatedSubjects.enabled: true` (it requires `resource`).
   Discovery now lists `steward-task-v2` and `steward-task-v3`.
   Detail: [federated Task identity upgrade](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/federated-task-identity-upgrade.md).
2. **Exchange**: create a **new** ConfigMap for the v6 policy (never rewrite
   the v5 one), validate it, then change these three values in one Helm
   revision: `config.policyContract: github-oidc-exchange.apelogic.io/v6`,
   `config.policyConfigMapName: <the v6 ConfigMap>`, and a new
   `rolloutRevisions.githubPolicy`. v6 requires `version`, `service_group`
   and `repositories` (each with positive numeric `owner_id` and
   `repository_id`); `subjects`, `events` and `refs` are optional exact
   selectors; `actors`, `allowed_email_domains` and `acting_group_prefix`
   are all-or-none. Detail: [v0.6.0 guide](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/upgrade-v0.6.0.md)
   and the [consumer contract](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/docs/consumer-contract-v1.md).
   Several exchange docs point to the v0.7.2 guide for this sequence; the
   v0.7.2 guide does not contain it, and the v0.6.0 guide does.
3. **Associate each caller identity.** The first v3 submission from each
   GitHub actor is recorded as an observed subject and refused with
   `403 task_identity_unassociated`. A browser administrator associates the
   subject with the user's canonical ID
   ([Steward Task submission API](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/task-submission-api.md);
   [by hand](../browser-admin/walkthrough.md#optional-link-a-task-identity-to-the-user-manual)).
   Association grants no authority by itself; the source binding and an
   active User Envelope still decide. With v6 this is an enrollment step for
   every new caller, and its only path today uses a pasted browser session
   ([#18](https://github.com/apelogic-ai/steward-platform/issues/18),
   [apelogic-ai/steward#179](https://github.com/apelogic-ai/steward/issues/179)).
   A v2 token for an already resolved user can seed its association while
   federated subjects are on, so running v5 with federated subjects on for a
   while before switching the exchange to v6 reduces manual associations.

Rollback, in reverse: switch the exchange back to its v5 revision first
(`helm rollback`; keep the v6 ConfigMap), then set
`federatedSubjects.enabled: false` in Steward and check that discovery lists
v2 only. Never reverse migration 0040 or delete subjects.

### Check after Stage 5

- [ ] Discovery: Steward lists `steward-task-v2` and `steward-task-v3`; the
      exchange lists policy v6.
- [ ] A fresh exchange returns a 120-second `steward-task-v3` Bearer token
      with `Cache-Control: no-store`, `aud: ["steward-task-api"]`,
      `sub: github-actions:actor:<id>` and signed source provenance.
- [ ] An unassociated actor gets `403 task_identity_unassociated` naming the
      issuer and subject; after association, the same caller is admitted
      against its Envelope.
- [ ] An invalid token and a raw GitHub token get `401`; a replayed
      assertion, a wrong audience and an unadmitted repository or ref get
      `401 invalid_token` with the matching audit event.

These are the `verify` assertions of the
[task-auth end-to-end test](../../tests/e2e/task-auth/README.md#assertions),
which runs them on a disposable cluster; run them by hand against your
install.

## Stage 6: mcp-gw 0.4.x to 0.5.0

If you run mcp-gw below 0.4.9, first reach 0.4.9 with its forward-only
database migrations 005 to 007 (see its CHANGELOG), while Steward 0.2.6's
declared range still holds. mcp-gw 0.5.0 has no database migration, Secret
change or provider reauthorization, and its runtime code is the same as
0.4.11; the changes are in the chart.

### mcp-gw: breaking inputs

| Input | 0.4.x | 0.5.0 |
|---|---|---|
| Chart `kubeVersion` | none | `>=1.32.0-0` |
| `agentgateway.enabled: true` | accepted without a resource or backend | also requires a non-empty `agentgateway.mcpAuthentication.resourceMetadata.resource` and at least one `agentgateway.backends[]` entry with `enabled: true`. Helm replaces lists, so mark every backend in your list. |
| GitHub upstream URL | default `githubWrapper.env.GITHUB_MCP_UPSTREAM_URL: http://mcp-gateway-github-mcp:8082/mcp` | default derived from the release name, `http://<fullname>-github-mcp:<githubMcp.port>/mcp`. An explicit `githubWrapper.env` value still wins. |
| OPA policy URL | `googleWorkspace.env.OPA_POLICY_URL` and `githubWrapper.env.OPA_POLICY_URL`, set separately | `policy.opaUrl`, one HTTP(S) URL without credentials or fragment, injected into both wrappers. The old form is accepted only while `policy.opaUrl` is empty; move both wrappers together. |
| GitHub OAuth redirect origins | `githubWrapper.env.GITHUB_OAUTH_REDIRECT_AFTER_ALLOWED_ORIGINS`, a comma-separated string | `githubWrapper.oauth.redirectAfterAllowedOrigins`, a list of exact HTTPS origins (loopback HTTP allowed), at most 32. The old form is accepted only while the list is empty. |
| Private CA | none | `trustBundle`: `enabled`, `mountPath` and exactly one of `configMapKeyRef` or `secretKeyRef`. It must hold every public and private root AgentGateway needs, not only the private one. |
| Callers of the connection lifecycle routes | the wrappers' NetworkPolicies admitted only AgentGateway | `connectionLifecycle.enabled` and `allowedCallers`, Kubernetes label selectors only (see below) |

Also from 0.4.10 and 0.4.11, if you come from 0.4.9: set
`secretRef.envKeys` on each wrapper when one Secret also holds the signing
JWKS, and review Google `match.scope` allow rules, which no longer admit a
broader grant for a narrower rule.

**Admit Steward's apiserver.** Steward 0.3.2's apiserver reads connection
status from the GitHub wrapper directly (its egress NetworkPolicy opens the
mcp-gw namespace when `connectionsBridge.enabled`). Add it as a caller:

```yaml
connectionLifecycle:
  enabled: true
  allowedCallers:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: steward   # Steward's namespace
      podSelector:
        matchLabels:
          app.kubernetes.io/name: steward
          app.kubernetes.io/component: apiserver
```

Keep `podSelector`: an entry without it admits every Pod in the namespace.
Steward's `networkPolicy.mcpGatewayNamespace` (default `mcp-gw`) must name
mcp-gw's namespace.

**Route aliases.** mcp-gw keeps the authenticated `/oauth/{provider}/*`
routes as aliases of `/connections/{provider}/*` through the whole 0.6.x
line; the earliest removal is 0.7.0. Steward's authority
`steward.connections.github/v1` uses the legacy `/oauth/github/status`;
`steward.connections.github/v2` uses `/connections/github/status`. Set
`connectionsBridge.mcpGatewayAuthorityContract: steward.connections.github/v2`
now so that the alias removal does not affect you.

Detail: [external platform issuer](https://github.com/apelogic-ai/mcp-gw/blob/v0.5.0/docs/external-platform-issuer.md),
[chart README](https://github.com/apelogic-ai/mcp-gw/blob/v0.5.0/deploy/k8s/chart/README.md),
[example values](https://github.com/apelogic-ai/mcp-gw/blob/v0.5.0/deploy/k8s/examples/values-external-platform-issuer.example.yaml).

### mcp-gw: rollback

mcp-gw documents no rollback. `helm rollback` restores the previous
revision's stored values **(inferred)**. A values file that uses any 0.5.0-only
key fails a 0.4.x chart's schema, so strip those keys before installing an
older chart from a file.

### Check after Stage 6

- [ ] mcp-gw Pods run the BOM digests; the chart renders with your values
      (`helm template` with the pinned chart).
- [ ] In the browser, Steward's connections page shows the GitHub connection
      status; connect and disconnect work.
- [ ] A Pod outside `allowedCallers` cannot reach the wrappers' port.

This repository pins mcp-gw 0.5.0 but installs and tests it in no profile yet
([#3](https://github.com/apelogic-ai/steward-platform/issues/3)).

## Governed dependencies

Steward 0.2.6 shipped a governed-platform compatibility manifest
(`config/governed-platform/v1/compatibility.json`, also a release asset) that
pinned, by digest, the governed dependencies it was tested with: SPIRE
(charts and images, with an upgrade order of `spire-crds`, then `spire`, then
workload API checks, then Steward Mint), OpenShell, agent-sandbox, LiteLLM,
the Gateway API minimum, and the accepted mcp-gw releases
([at v0.2.6](https://github.com/apelogic-ai/steward/blob/v0.2.6/config/governed-platform/v1/compatibility.json)).

Steward 0.3.0 removed it. Its replacement,
[`config/product-compatibility/v1/compatibility.json`](https://github.com/apelogic-ai/steward/blob/v0.3.2/config/product-compatibility/v1/compatibility.json),
declares contracts only (Task API `steward.task/v2`, identity policy v5,
`steward-task-v2`, connection authority v2, the steward-run 0.7.0 minimum for
`envelopeDigest`) and no dependency versions or digests. Steward now expects
a separately signed installation BOM to carry them. This repository's BOM
does not pin the governed dependencies yet, so **no authoritative pinned set
exists today** for the profile that executes agents.

What to do in this migration:

- **Keep the governed dependencies you run.** Do not upgrade them as part of
  this migration. Keep the inventory and digests you recorded in Stage 0.
- **Interim pins** are tracked in
  [#13](https://github.com/apelogic-ai/steward-platform/issues/13) (pin them in
  the BOM as not yet exercised), and the governed profile and its end-to-end
  test in [#3](https://github.com/apelogic-ai/steward-platform/issues/3).
- **OpenShell** has an open blocker:
  [apelogic-ai/steward#147](https://github.com/apelogic-ai/steward/issues/147).
  In the OpenShell release Steward 0.2.6 pinned (0.0.98), the supervisor never
  prepares the identity mount namespace, so a sandbox using a SPIFFE token
  grant fails; Steward's tested path used a locally patched supervisor that is
  not published. A newer stock OpenShell release (the v0.1.x line) is under
  evaluation there. This runbook recommends no OpenShell version; follow that
  issue and #13.
- Steward 0.3.2 keeps only the SPIRE identity contract: the trust domain is
  immutable, Mint's ID is `spiffe://<trust-domain>/steward/mint`, and changing
  the trust domain is an identity migration
  ([product compatibility](https://github.com/apelogic-ai/steward/blob/v0.3.2/docs/installation/governed-platform-compatibility.md)).

## Final acceptance

After the last stage, check the install as a whole:

- [ ] Every product Pod runs the digests in [`bom/bom.json`](../../bom/bom.json)
      (compare `imageID` of each container with the BOM).
- [ ] The artifacts you installed pass the BOM checks in
      [verification](../verification.md): `scripts/verify-digests.sh`,
      `scripts/verify-attestations.sh` and `scripts/verify-signatures.sh`.
      If you mirror images, also check your mirror with
      `scripts/verify-digests.sh --mirror`
      ([registry mirroring](../registry-mirroring.md)).
- [ ] The task-auth chain holds end to end: discovery, exchange, Steward's
      answer and the negative cases, as in the
      [task-auth assertions](../../tests/e2e/task-auth/README.md#assertions),
      and an associated caller is admitted against its Envelope.
- [ ] Browser administration works: sign-in, the request queue, template
      authoring, approval and audit
      ([walkthrough](../browser-admin/walkthrough.md)).
- [ ] Monitoring alerts on the exchange's key expiry gauges.
- [ ] Your rotation procedure includes publishing the JWKS to Steward and
      restarting the apiserver.

## Known gaps

This repository:

- [#3](https://github.com/apelogic-ai/steward-platform/issues/3): no governed
  profile, generator output or end-to-end test; mcp-gw and the governed
  dependencies are not exercised here.
- [#13](https://github.com/apelogic-ai/steward-platform/issues/13): no pinned
  governed dependency inventory since Steward 0.3.0.
- [#16](https://github.com/apelogic-ai/steward-platform/issues/16):
  NetworkPolicy peers in the platform values are literal CIDRs only.
- [#18](https://github.com/apelogic-ai/steward-platform/issues/18): no grant
  revocation without the browser, and subject association uses a pasted
  browser session.
- The migration itself is not tested by this repository; the end-to-end tests
  install fresh.

Products:

- Steward: [#147](https://github.com/apelogic-ai/steward/issues/147) OpenShell
  supervisor and SPIFFE grant;
  [#179](https://github.com/apelogic-ai/steward/issues/179) no non-browser
  subject association;
  [#146](https://github.com/apelogic-ai/steward/issues/146) no documented
  operator CLI credential;
  [#152](https://github.com/apelogic-ai/steward/issues/152) NetworkPolicy
  takes literal CIDRs only;
  [#148](https://github.com/apelogic-ai/steward/issues/148) amd64-only images.
- github-oidc-exchange:
  [#88](https://github.com/apelogic-ai/github-oidc-exchange/issues/88) the
  integration guide names the legacy workflow (use
  `steward-task-customer.yml`) and the workload pairing guide omits Steward's
  `networkPolicy.identityExchangeNamespace` (set it to the exchange's
  namespace);
  [#55](https://github.com/apelogic-ai/github-oidc-exchange/issues/55)
  `keyring-tool` is not shipped as a release binary.
- steward-run: [#69](https://github.com/apelogic-ai/steward-run/issues/69) the
  action needs Node 24 on `PATH`.
