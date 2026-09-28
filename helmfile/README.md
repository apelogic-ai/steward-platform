# Core reference install with helmfile

[`helmfile.yaml.gotmpl`](helmfile.yaml.gotmpl) installs the core profile from
the BOM. It has no inputs of its own: [`scripts/generate.sh`](../scripts/generate.sh)
turns one [platform values file](../docs/platform-values.md) and
[`bom/bom.json`](../bom/bom.json) into its environment values and every chart's
values. Charts from the BOM are installed by digest.

| Release | Chart | Environments |
|---|---|---|
| `cert-manager` | BOM `dependencies.cert-manager.chart`, by digest | all, unless `tls.certManager.install: false` |
| `evaluation-ca` | [`charts/evaluation-ca`](../charts/evaluation-ca): self-signed CA `Issuer` | evaluation only |
| `postgresql-evaluation` | [`charts/postgresql-evaluation`](../charts/postgresql-evaluation): the BOM PostgreSQL image, no persistence or TLS | evaluation only |
| `steward` | BOM `products.steward.chart`, by digest | all |
| `envoy-gateway` | BOM `dependencies.envoy-gateway.chart`, by digest, without its bundled CRDs. A presync hook first runs [`scripts/apply-manifests.sh`](../scripts/apply-manifests.sh): the BOM's Gateway API (standard channel) and Envoy Gateway CRD manifests, checked by digest and server-side applied against `PLATFORM_KUBE_CONTEXT` or the current context | task-auth, when `edge.install` is true |
| `edge-evaluation-ca` | [`charts/evaluation-ca`](../charts/evaluation-ca) in the Gateway namespace: the edge listener CA | task-auth evaluation only |
| `evaluation-edge` | [`charts/evaluation-edge`](../charts/evaluation-edge): evaluation `GatewayClass`, `Gateway` and the public Steward CA `ConfigMap` | task-auth evaluation only |
| `steward-edge` | [`charts/steward-edge`](../charts/steward-edge): Steward's task API `HTTPRoute` and `BackendTLSPolicy` | task-auth |
| `github-oidc-exchange` | BOM `products.github-oidc-exchange.chart`, by digest | task-auth |

The order comes from `needs`: cert-manager, then the evaluation pieces, then
Steward. For where this fits in the whole platform, see
[docs/install-order.md](../docs/install-order.md).

Tools: [helmfile](https://github.com/helmfile/helmfile) and Helm 3.17 or later,
plus the generator's `jq`, `yq` and `check-jsonschema`. CI uses the versions
pinned in [`scripts/ci/install-tools.sh`](../scripts/ci/install-tools.sh).
`helmfile sync` needs no Helm plugins; `helmfile apply` and `diff` need the
helm-diff plugin.

## Evaluate on kind

Needs an **amd64** Docker host (Steward images are linux/amd64 only), `kind` and
`kubectl`.

```sh
kind create cluster --name steward --config environments/kind/kind-config.yaml \
  --image "$(jq -r '.kubernetes.tested | last | .nodeImage' bom/bom.json)"
scripts/generate.sh environments/kind/platform-values.yaml
helmfile --file helmfile/helmfile.yaml.gotmpl --environment kind \
  --kube-context kind-steward sync
```

The kind environment's platform values assume the subnets in
[`kind-config.yaml`](../environments/kind/kind-config.yaml). The
[core end-to-end test](../tests/e2e/core/README.md) runs exactly these steps
in CI on every tested Kubernetes version, then checks the install.

Evaluation is not production: PostgreSQL loses its data when its pod is
recreated, and the CA is self-signed. Delete the cluster when done:
`kind delete cluster --name steward`.

## Production shape

Start from
[`environments/production/platform-values.yaml`](../environments/production/platform-values.yaml).
Copy the directory, set `environment` to your environment's name, replace the
values marked `REPLACE`, and add a matching entry under `environments:` in
`helmfile.yaml.gotmpl`. Production cannot use the evaluation database or CA;
the schema rejects them.

Before the first sync, in the Steward namespace:

1. PostgreSQL 16, operated separately, and the Secret named in
   `database.secret` holding the full database URL. With `database.tls.mode:
   verify-full`, the URL carries
   `sslmode=verify-full&sslrootcert=/run/database-tls/ca.crt` and the CA
   ConfigMap or Secret in `database.tls.ca` exists.
2. TLS, one of:
   - `tls.mode: certManager` (the reference choice): an `Issuer` in the Steward
     namespace or a `ClusterIssuer` that your PKI approves, named in
     `tls.certManager.issuer.ref`. Set `tls.certManager.install: false` if the
     cluster already runs cert-manager.
   - `tls.mode: customerSecret`: the two `kubernetes.io/tls` Secrets, and the
     public CA bundle file named in `tls.customerSecret.caBundleFile`.
3. NetworkPolicy CIDRs for the Kubernetes API and PostgreSQL in the platform
   values. See [prerequisites](../docs/prerequisites.md#networkpolicy).

Then:

```sh
scripts/generate.sh environments/<name>/platform-values.yaml
helmfile --file helmfile/helmfile.yaml.gotmpl --environment <name> \
  --kube-context <context> diff    # needs the helm-diff plugin
helmfile --file helmfile/helmfile.yaml.gotmpl --environment <name> \
  --kube-context <context> sync
```

Steward's own [installation guide](https://github.com/apelogic-ai/steward/blob/v0.3.1/docs/installation/installation-guide.md)
stays the authority for its prerequisites, the objects it expects, and the
checks after install.

## Upgrades and the Steward CRD

Upgrading is a BOM bump: regenerate and sync. Two things Helm does not do for
you:

- **Steward's `AgentRuntime` CRD is in the chart's `crds/` directory.** Helm
  installs it on first install and never upgrades or deletes it afterwards, so
  a sync that moves Steward to a new chart leaves the old CRD in place. Before
  upgrading, read the Steward release's upgrade notes, then apply the new
  chart's CRD yourself:

  ```sh
  helm show crds "$(jq -r '.products.steward.chart | "\(.reference)@\(.digest)"' bom/bom.json)" \
    | kubectl --context <context> apply --server-side -f -
  ```

  Steward's guide: [upgrade, rollback, backup and removal](https://github.com/apelogic-ai/steward/blob/v0.3.1/docs/installation/installation-guide.md#upgrade-rollback-backup-and-removal).
- **cert-manager's CRDs** are chart templates here (`crds.enabled: true`), so
  they upgrade with the release, and `crds.keep: true` keeps them if the
  release is deleted.
