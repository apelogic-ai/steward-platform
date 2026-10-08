# Platform values

One file, `platform-values.yaml`, is the operator input for a platform install.
It holds the values that several charts must agree on, so each is written
once. [`scripts/generate.sh`](../scripts/generate.sh) combines it with the BOM
into per-chart values and helmfile inputs.

- Schema: [`schemas/platform-values/v1.schema.json`](../schemas/platform-values/v1.schema.json)
- Examples:
  [`environments/kind/platform-values.yaml`](../environments/kind/platform-values.yaml)
  (core, evaluation on kind),
  [`environments/kind-task-auth/platform-values.yaml`](../environments/kind-task-auth/platform-values.yaml)
  (task-auth, evaluation on kind),
  [`environments/kind-browser-admin/platform-values.yaml`](../environments/kind-browser-admin/platform-values.yaml)
  (browser-admin, evaluation on kind) and
  [`environments/production/platform-values.yaml`](../environments/production/platform-values.yaml),
  [`environments/production-task-auth/platform-values.yaml`](../environments/production-task-auth/platform-values.yaml)
  and
  [`environments/production-browser-admin/platform-values.yaml`](../environments/production-browser-admin/platform-values.yaml)
  (core, task-auth and browser-admin, production shape)

The generator sets only the chart keys listed below. Each product chart
remains the authority for what its keys mean; follow the links.

## Generate

```sh
scripts/generate.sh environments/kind/platform-values.yaml
```

This validates the file against the schema, refuses reserved fields, and
writes `generated/<environment>/`:

| File | Used by |
|---|---|
| `helmfile.yaml` | [`helmfile/helmfile.yaml.gotmpl`](../helmfile/helmfile.yaml.gotmpl) environment values: chart references pinned by digest, namespaces, which releases to install |
| `values/steward.yaml` | Steward chart |
| `values/cert-manager.yaml` | cert-manager chart, when `tls.certManager.install` is true |
| `values/evaluation-ca.yaml` | [`charts/evaluation-ca`](../charts/evaluation-ca), when the evaluation issuer is used |
| `values/postgresql-evaluation.yaml` | [`charts/postgresql-evaluation`](../charts/postgresql-evaluation), when the evaluation database is used |
| `values/github-oidc-exchange.yaml` | github-oidc-exchange chart (task-auth, browser-admin) |
| `values/steward-edge.yaml` | [`charts/steward-edge`](../charts/steward-edge): Steward's task API routes and BackendTLSPolicy (task-auth only; browser-admin uses Steward's own routes) |
| `values/envoy-gateway.yaml` | Envoy Gateway, without its bundled CRDs (task-auth and browser-admin, when `edge.install` is true). The helmfile applies the BOM's CRD manifests first. |
| `values/edge-evaluation-ca.yaml`, `values/evaluation-edge.yaml` | [`charts/evaluation-ca`](../charts/evaluation-ca) again, for the edge, and [`charts/evaluation-edge`](../charts/evaluation-edge): the evaluation Gateway (task-auth and browser-admin, when `edge.gateway.source` is `evaluation`) |
| `flux/` | Flux objects for the same install, when no evaluation piece is used: an `OCIRepository` pinned by digest and a `HelmRelease` per release, with the helmfile's order as `dependsOn`; for task-auth and browser-admin with `edge.install`, the Gateway API and Envoy Gateway CRDs as `Kustomization`s over their BOM `fluxSource`; for task-auth, `charts/steward-edge` from this repository at the platform version's tag. [`examples/flux/core`](../examples/flux/core/README.md), [`task-auth`](../examples/flux/task-auth/README.md) and [`browser-admin`](../examples/flux/browser-admin/README.md) are this output for the production examples, and [`mirrored`](../examples/flux/mirrored/README.md) for [`environments/production-mirrored`](../environments/production-mirrored/platform-values.yaml), task-auth from a registry mirror. |

The same inputs always give the same bytes. `generated/` is not committed;
regenerate it after changing the values file or the BOM.

With `artifacts.source: built`, the product charts and images come from a
built-artifacts lock (`artifacts.builtLock`) instead of the BOM: products you
built from source and pushed to your own registry. Everything else is
generated exactly as from the BOM alone, and each generated file gets one more
header line naming the lock. See [fork and build from source](fork-and-build.md).

Tools: `jq` 1.7 or later, [yq](https://github.com/mikefarah/yq) v4 and
`check-jsonschema`. CI uses the versions pinned in
[`scripts/ci/install-tools.sh`](../scripts/ci/install-tools.sh) and
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Fields

`purpose` is `evaluation` or `production`. Production forbids the evaluation
database, the evaluation CA and the evaluation Gateway; the schema rejects the
combination.

### Implemented (core)

| Field | Sets | Notes |
|---|---|---|
| `environment` | helmfile environment and output directory | |
| `profile` | which BOM profile to install | `core`, `task-auth` or `browser-admin`; `governed` is refused until [#3](https://github.com/apelogic-ai/steward-platform/issues/3) |
| `cluster.domain` | Steward `services.clusterDomain`; evaluation database URL | |
| `cluster.serviceAccountTokenAudience` | Steward `config.apiserver.kubernetesTokenReviewAudience` | The cluster's service account issuer. On kind it is not the chart default. |
| `cluster.dnsNamespace` | Steward `networkPolicy.dnsNamespace` | |
| `cluster.kubeApi.cidrs`, `.port` | Steward `networkPolicy.kubeApiCidrs`, `networkPolicy.ports.kubernetesApi` | Literal CIDRs only. See [NetworkPolicy](prerequisites.md#networkpolicy). |
| `namespaces.steward` | Steward release namespace | Evaluation PostgreSQL and the evaluation CA go here too. |
| `namespaces.certManager` | cert-manager release namespace | |
| `serviceAccounts.steward.apiserver`, `.controller` | Steward `serviceAccounts.<component>.annotations` | For cloud workload identity. Names are fixed by the chart. |
| `tls.mode` | Steward `tls.mode` | `certManager` or `customerSecret`. |
| `tls.certManager.install` | whether the reference install installs the BOM-pinned cert-manager | Set false if the cluster already runs it. |
| `tls.certManager.issuer` | Steward `tls.issuerRef` | `evaluation` creates a self-signed CA `Issuer` in the Steward namespace; `operator` names your `Issuer` or `ClusterIssuer`. |
| `tls.customerSecret` | Steward `tls.api.secretName`, `tls.webhook.secretName`, `tls.webhook.caBundlePem` | `caBundleFile` is read and embedded. The generator refuses a file that contains a private key. |
| `database.source` | whether the reference install runs evaluation PostgreSQL | `operator` means you create the database Secret. |
| `database.evaluationVersion` | which tested PostgreSQL image the evaluation database runs | Evaluation source only. A major version (`"17"`) or an exact one that names one entry of `dependencies.postgresql.tested` in the BOM; the default is the BOM's `version`. |
| `database.secret` | Steward `secrets.database` | The evaluation database chart writes this Secret; otherwise you do. |
| `database.cidrs`, `.port` | Steward `networkPolicy.postgresCidrs`, `networkPolicy.ports.postgres` | |
| `database.tls` | Steward `databaseTls` | `verify-full` also needs the URL to carry `sslmode=verify-full&sslrootcert=/run/database-tls/ca.crt`. |
| `networkPolicy.apiserverIngressNamespaces` | Steward `networkPolicy.apiserverIngressNamespaces` | Namespaces allowed to call the Steward API. |
| `artifacts.source`, `.builtLock` | where every product chart and image reference comes from | Optional. `bom` (the default): the BOM's upstream artifacts. `built`: the lock at `builtLock` (absolute, or relative to the values file), checked against the BOM; see [fork and build from source](fork-and-build.md). The external dependencies always come from the BOM. |

The generator also sets Steward's `images` from the BOM and keeps
`execution.enabled=false` and `networkPolicy.enabled=true`. Steward keys are
defined by its chart:
[values](https://github.com/apelogic-ai/steward/blob/v0.3.13/charts/steward/values.yaml),
[schema](https://github.com/apelogic-ai/steward/blob/v0.3.13/charts/steward/values.schema.json),
[chart README](https://github.com/apelogic-ai/steward/blob/v0.3.13/charts/steward/README.md).

### Implemented (task-auth)

The [task-auth profile](profiles/task-auth.md) uses every core field, and
these. The schema requires them for `profile: task-auth` and `profile: browser-admin`,
and forbids them for `profile: core`.

| Field | Sets | Notes |
|---|---|---|
| `publicEndpoints.steward` | Steward `taskIdentity.resource`; the hostname of the Steward task API route | An origin with no port or path. steward-run takes it as its Steward API URL and checks that the protected-resource metadata names it. |
| `publicEndpoints.identityIssuer` | github-oidc-exchange `config.issuerUrl`; Steward `taskIdentity.issuer`; the exchange route hostname | Steward matches the issuer exactly. |
| `audiences.taskApi` | github-oidc-exchange `config.outputAudience`; Steward `taskIdentity.audience` | The exchange chart fixes it to `steward-task-api`. |
| `namespaces.identityExchange` | github-oidc-exchange release namespace | The policy ConfigMap and keyring Secret live here. |
| `serviceAccounts.identityExchange` | github-oidc-exchange `serviceAccount.annotations` | |
| `networkPolicy.edgeNamespace` | added to Steward `networkPolicy.apiserverIngressNamespaces`; Envoy Gateway's namespace when `edge.install` | Steward's chart `networkPolicy.ingressNamespace` applies only with its web UI enabled, so the edge is admitted as a direct API caller. |
| `edge.install` | whether the reference install installs the BOM-pinned Gateway API CRDs and Envoy Gateway | |
| `edge.gateway` | the `parentRefs` of every route | `source: evaluation` creates an Envoy Gateway `GatewayClass` and `Gateway` with a certificate from a self-signed edge CA (evaluation only). `operator` attaches to your Gateway, which must allow routes from the Steward and exchange namespaces. |
| `edge.clientCidrs` | github-oidc-exchange `networkPolicy.ingressCidrs` | The edge data plane's source addresses. |
| `edge.stewardBackendCaConfigMap` | the Steward BackendTLSPolicy CA | The evaluation Gateway publishes it; otherwise your trust distribution must, as [Steward's chart README](https://github.com/apelogic-ai/steward/blob/v0.3.13/charts/steward/README.md) describes. |
| `identityExchange.githubAudience` | github-oidc-exchange `config.githubExchangeAudience` | Clients discover it from the issuer metadata. |
| `identityExchange.policy` | github-oidc-exchange `config.policyContract`, `config.policyConfigMapName`, `rolloutRevisions.githubPolicy`; Steward `taskIdentity.federatedSubjects.enabled` (true for v6) | The ConfigMap is yours to create; see the exchange's [integration guide](https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.5/docs/integration.md). |
| `identityExchange.keyring` | github-oidc-exchange `config.keyringSecretName`, `rolloutRevisions.githubKeyring` | The Secret is yours to create. |
| `identityExchange.publicJwksConfigMap` | Steward `taskIdentity.publicJwksConfigMap` | The exchange's public JWKS (`keyring-tool export-jwks`), in the Steward namespace. Steward does not fetch the issuer's JWKS. |

In task-auth, the Steward edge route comes from
[`charts/steward-edge`](../charts/steward-edge), not from Steward's own
`web.httpRoute`, because that interface requires Steward's browser web UI and
therefore browser login
([apelogic-ai/steward#180](https://github.com/apelogic-ai/steward/issues/180)).
browser-admin has both, so it uses Steward's routes instead.

### Implemented (browser-admin)

The [browser-admin profile](profiles/browser-admin.md) is task-auth plus
Steward's web UI and Google Workspace browser login. It uses every task-auth
field, and these. The schema requires `browserAuth` and
`networkPolicy.egressCidrs.browserAuth` for `profile: browser-admin` and
forbids them, and `administration`, for the other profiles.

| Field | Sets | Notes |
|---|---|---|
| `publicEndpoints.steward` | also Steward `browserAuth.google.origin`, `web.host` and `web.httpRoute.hostname` | One origin serves the web UI, the browser APIs and the task API. Google's redirect URI is this origin plus `/admin/auth/callback`. |
| `browserAuth.google.clientId` | Steward `browserAuth.google.clientId` | A Google Cloud "Web application" OAuth client. See [local access](browser-admin/local-access.md#the-google-oauth-client). |
| `browserAuth.google.workspaceDomain` | Steward `browserAuth.google.workspaceDomain` | The hosted domain (`hd`). The schema refuses `gmail.com` and `googlemail.com`: personal accounts have no hosted domain and Steward rejects them. |
| `browserAuth.google.organizationId` | Steward `browserAuth.google.organizationId` | A Steward-chosen, stable name, not a Google organization ID: `org_` followed by up to 60 lowercase letters, digits, `_` or `-`. |
| `browserAuth.google.clientSecret` | Steward `browserAuth.google.clientSecret` | Your Secret in the Steward namespace; its key holds only the raw client secret. |
| `networkPolicy.egressCidrs.browserAuth` | Steward `networkPolicy.browserAuthEgressCidrs` | HTTPS egress from the apiserver to Google's sign-in endpoints. Google publishes no stable ranges for them ([apelogic-ai/steward#152](https://github.com/apelogic-ai/steward/issues/152)); you maintain the list. The schema refuses `0.0.0.0/0` and `::/0` in production. |
| `administration.capabilityCatalog` | Steward `config.apiserver.capabilityCatalog` | Passed through unchanged; the Steward chart's schema validates it. Descriptive, never authority, but Steward refuses to author an Envelope template unless it lists a model. |

The generator also sets, for browser-admin:

- `config.apiserver.stewardRunRelease`, projected from the BOM's
  `products.steward-run` with the mapping in Steward's
  [compatibility contract](https://github.com/apelogic-ai/steward/blob/v0.3.13/docs/installation/governed-platform-compatibility.md):
  `signatures.releaseManifest.schemaVersion` as `manifestSchemaVersion`,
  `version`, `workflow.repository` and `workflow.commit` as
  `workflowRepository` and `workflowCommit`, `action.commit` as
  `actionCommit`, and the `runner` image without its tag as
  `governedJobContainerImage`. [`scripts/verify-signatures.sh`](../scripts/verify-signatures.sh)
  checks that this projection equals the signed release manifest, field for
  field. Steward requires it whenever browser administration is on.
- `images.web` from the BOM, and `web.enabled`.
- Steward's own edge, `web.httpRoute`, on the `edge.gateway` listener: the
  `steward-api` route with every public apiserver path from Steward's
  [chart README](https://github.com/apelogic-ai/steward/blob/v0.3.13/charts/steward/README.md)
  (the chart does not enforce the list, so the generator supplies all of it:
  `/.well-known/oauth-protected-resource` and
  `/admin/connections/github/callback` exactly, and the `/admin/api`,
  `/admin/auth`, `/admin/operator`, `/app/api` and `/v1` prefixes), the
  `steward-web` route for `/`, and the `BackendTLSPolicy` that verifies the
  apiserver certificate against `edge.stewardBackendCaConfigMap`. The helmfile
  installs Steward after Envoy Gateway, whose release applies the Gateway API
  CRDs, and does not install `charts/steward-edge`.
- `networkPolicy.ingressNamespace` set to `networkPolicy.edgeNamespace`: with
  the web UI on, the chart admits the edge to both the web UI and the
  apiserver, so the edge is not added to `apiserverIngressNamespaces`.

### Registry mirror (every profile)

Optional. Without `registry` every reference is the BOM's, unchanged. With it,
each artifact class that is set is pulled from its mirror; only the registry or
host and the leading path change, never a tag, digest or Git commit.
[Registry mirroring](registry-mirroring.md) explains the rewrite, the copy and
the check.
With `artifacts.source: built`, `registry.productImages` and
`registry.productCharts` are refused, since the lock already names where the
products are; the other classes and `registry.imagePullSecrets` apply as usual
([fork and build from source](fork-and-build.md#built-products-and-a-registry-mirror)).

| Field | Sets | Notes |
|---|---|---|
| `registry.productImages` | Steward `images.repository`; github-oidc-exchange `image.repository` | `prefix`, and `keepSourceHost` to keep the upstream registry as a path segment. Steward's chart takes one repository for all its images. |
| `registry.productCharts` | the Steward and github-oidc-exchange chart references of the helmfile and of the Flux `OCIRepository`s | `flux.secretRef`, `flux.provider` (`aws`, `azure`, `gcp`) or `flux.certSecretRef` for those `OCIRepository`s. |
| `registry.dependencyImages` | cert-manager `image.repository` and each component's; Envoy Gateway `global.images.envoyGateway.image` and `global.images.envoyProxy.image`; evaluation PostgreSQL `image.repository` | |
| `registry.dependencyCharts` | the cert-manager and Envoy Gateway chart references, including the Envoy Gateway chart the Flux CRD `Kustomization` extracts | `flux` as for product charts. |
| `registry.gitSources` | the Flux `GitRepository` URLs: the Gateway API CRDs and `charts/steward-edge` | `prefix`, or `repositories` for exact URLs; `flux.secretRef`. The BOM commit and the platform tag stay. |
| `registry.manifests` | the URLs the helmfile's CRD hook downloads (`apply-manifests.sh --url`) | Still checked against the BOM SHA-256. |
| `registry.imagePullSecrets` | Steward `imagePullSecrets`; cert-manager `global.imagePullSecrets`; github-oidc-exchange `image.pullSecrets`; Envoy Gateway `global.imagePullSecrets` | Names of Secrets you create in each chart's namespace. |

With a chart mirror, the generated helmfile inputs also carry
`registryLogins`: helmfile logs in to each chart class's registry with
`STEWARD_PLATFORM_PRODUCT_CHARTS_USERNAME` and `_PASSWORD`, or
`STEWARD_PLATFORM_DEPENDENCY_CHARTS_USERNAME` and `_PASSWORD`, when both are
set.

### Reserved for governed mode

These fields are in the schema so the file keeps its shape when governed mode
arrives, and so that the values several products must share have one home.
The schema marks each with `x-reserved`. The v1 generator refuses a file that
sets any of them. Generation is tracked in
[#3](https://github.com/apelogic-ai/steward-platform/issues/3).

| Field | Must agree across |
|---|---|
| `publicEndpoints.mintIssuer` | Steward Mint; mcp-gw and the inference proxy |
| `publicEndpoints.mcpGateway` | mcp-gw; Steward MCP gateway endpoint and connections origin |
| `audiences.mint`, `.mintSvid`, `.mintControlPlane` | Mint token, Mint SVID and Mint control-plane audiences, between each issuer and its verifiers |
| `spiffe.trustDomain` | SPIRE, Steward Mint, github-oidc-exchange workload exchange |
| `namespaces.mcpGateway`, `.runners`, `.litellm`, `.openshell`, `.spire`, `.runtimes` | every chart's NetworkPolicy and service URLs |
| `serviceAccounts.steward.mint`, `.mcpGateway` | workload identities that peers trust |
| `networkPolicy.egressCidrs.githubApi`, `.identityIssuer` | Steward and peer NetworkPolicies |
