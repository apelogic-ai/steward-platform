# Platform values

One file, `platform-values.yaml`, is the operator input for a platform install.
It holds the values that several charts must agree on, so each is written
once. [`scripts/generate.sh`](../scripts/generate.sh) combines it with the BOM
into per-chart values and helmfile inputs.

- Schema: [`schemas/platform-values/v1.schema.json`](../schemas/platform-values/v1.schema.json)
- Examples:
  [`environments/kind/platform-values.yaml`](../environments/kind/platform-values.yaml)
  (evaluation on kind) and
  [`environments/production/platform-values.yaml`](../environments/production/platform-values.yaml)
  (production shape)

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

The same inputs always give the same bytes. `generated/` is not committed;
regenerate it after changing the values file or the BOM.

Tools: `jq` 1.7 or later, [yq](https://github.com/mikefarah/yq) v4 and
`check-jsonschema`. CI uses the versions pinned in
[`scripts/ci/install-tools.sh`](../scripts/ci/install-tools.sh) and
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Fields

`purpose` is `evaluation` or `production`. Production forbids the evaluation
database and the evaluation CA; the schema rejects the combination.

### Implemented (core)

| Field | Sets | Notes |
|---|---|---|
| `environment` | helmfile environment and output directory | |
| `profile` | which BOM profile to install | `core` only; `governed` is refused until [#3](https://github.com/apelogic-ai/steward-platform/issues/3) |
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
| `database.secret` | Steward `secrets.database` | The evaluation database chart writes this Secret; otherwise you do. |
| `database.cidrs`, `.port` | Steward `networkPolicy.postgresCidrs`, `networkPolicy.ports.postgres` | |
| `database.tls` | Steward `databaseTls` | `verify-full` also needs the URL to carry `sslmode=verify-full&sslrootcert=/run/database-tls/ca.crt`. |
| `networkPolicy.apiserverIngressNamespaces` | Steward `networkPolicy.apiserverIngressNamespaces` | Namespaces allowed to call the Steward API. |

The generator also sets Steward's `images` from the BOM and keeps
`execution.enabled=false` and `networkPolicy.enabled=true`. Steward keys are
defined by its chart:
[values](https://github.com/apelogic-ai/steward/blob/v0.3.0/charts/steward/values.yaml),
[schema](https://github.com/apelogic-ai/steward/blob/v0.3.0/charts/steward/values.schema.json),
[chart README](https://github.com/apelogic-ai/steward/blob/v0.3.0/charts/steward/README.md).

### Reserved for governed mode

These fields are in the schema so the file keeps its shape when governed mode
arrives, and so that the values several products must share have one home.
The schema marks each with `x-reserved`. The v1 generator refuses a file that
sets any of them. Generation is tracked in
[#3](https://github.com/apelogic-ai/steward-platform/issues/3).

| Field | Must agree across |
|---|---|
| `publicEndpoints.steward` | Steward browser origin, web host and task-token resource; steward-run's Steward URL |
| `publicEndpoints.identityIssuer` | github-oidc-exchange issuer; Steward `taskIdentity.issuer`; steward-run workflow input |
| `publicEndpoints.mintIssuer` | Steward Mint; mcp-gw and the inference proxy |
| `publicEndpoints.mcpGateway` | mcp-gw; Steward MCP gateway endpoint and connections origin |
| `audiences.*` | task token, Mint token, Mint SVID and Mint control-plane audiences, between each issuer and its verifiers |
| `spiffe.trustDomain` | SPIRE, Steward Mint, github-oidc-exchange workload exchange |
| `namespaces.identityExchange`, `.mcpGateway`, `.runners`, `.litellm`, `.openshell`, `.spire`, `.runtimes` | every chart's NetworkPolicy and service URLs |
| `serviceAccounts.steward.mint`, `.identityExchange`, `.mcpGateway` | workload identities that peers trust |
| `networkPolicy.edgeNamespace`, `networkPolicy.egressCidrs.*` | Steward and peer NetworkPolicies |
| `browserAuth.google.*` | Steward browser login. The schema requires `organizationId` to start with `org_`, which the Steward chart does not check yet ([apelogic-ai/steward#137](https://github.com/apelogic-ai/steward/issues/137)). |
