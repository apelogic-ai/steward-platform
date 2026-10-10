# Local evaluation access

How to install the [browser-admin profile](../profiles/browser-admin.md) on
kind and reach Steward's web UI over HTTPS from a workstation, with a real
Google Workspace sign-in. The committed
[`environments/kind-browser-admin`](../../environments/kind-browser-admin/platform-values.yaml)
values are the starting point; CI installs them with a placeholder OAuth
client that never reaches Google.

Everything here is evaluation-only: a self-signed edge CA, a port-forward in
place of a load balancer, in-cluster PostgreSQL and an unrestricted
browser-auth egress rule.

## What you need

- **An amd64 Linux host for kind.** Steward images are linux/amd64 only
  ([apelogic-ai/steward#148](https://github.com/apelogic-ai/steward/issues/148)).
  On an Apple Silicon or other arm64 workstation, run kind on an amd64 Linux
  machine or VM and forward port 443 to your workstation (see
  [Reach the edge](#reach-the-edge)).
- `kind`, `kubectl`, `helm`, `helmfile`, and the generator's `jq`, `yq` and
  `check-jsonschema` ([helmfile/README.md](../../helmfile/README.md)).
- **A Google Workspace** where you can create an OAuth client in a Google
  Cloud project that belongs to the Workspace organization. Personal Google
  accounts cannot sign in: Steward requires the configured hosted domain.
- The task-auth operator inputs: an exchange policy, keyring and public JWKS
  ([task-auth profile](../profiles/task-auth.md#run-it)). Building
  `keyring-tool` needs a Rust toolchain
  ([`scripts/ci/build-keyring-tool.sh`](../../scripts/ci/build-keyring-tool.sh)).

## Choose the Steward hostname

`publicEndpoints.steward` is the one origin for the web UI, the browser APIs
and the task API, and Google's redirect URI is built from it. Google accepts
a redirect URI only if its host's top-level domain is on the public suffix
list ([Google's redirect URI rules](https://developers.google.com/identity/protocols/oauth2/web-server#uri-validation)),
so the committed `steward.platform.test` works for CI but not for a real
sign-in.

Use a name under a domain you control, for example
`steward.eval.example.com`. It needs no DNS record: your browser resolves it
through `/etc/hosts`, and Google only redirects the browser to it. The
exchange hostname (`publicEndpoints.identityIssuer`) can stay under `.test`;
browsers never visit it.

## The Google OAuth client

In the [Google Cloud console](https://console.cloud.google.com/), in a project
that belongs to your Workspace organization:

1. **Consent screen** (Google Auth Platform, "Branding" and "Audience"):
   user type **Internal**. Internal limits sign-in to your Workspace
   organization and needs no Google verification. Steward asks only for the
   `openid`, `email` and `profile` scopes.
2. **Client** (Google Auth Platform, "Clients", "Create client"): application
   type **Web application**.
3. **Authorized redirect URIs**: exactly one,

   ```text
   https://<steward host>/admin/auth/callback
   ```

   for example `https://steward.eval.example.com/admin/auth/callback`: the
   origin plus Steward's fixed callback path, with no trailing slash
   ([Steward browser session contract, v0.3.15](https://github.com/apelogic-ai/steward/blob/v0.3.15/docs/browser-session-contract-v1.md#routes)).
   Steward derives it from the origin and sends nothing else, and Google
   refuses a sign-in whose redirect URI is not listed exactly.
4. **Authorized JavaScript origins**: none. The browser never calls Google
   from JavaScript; the apiserver exchanges the code.

Keep the client ID and the client secret. The client ID is not secret; the
secret goes only into a Kubernetes Secret.

## Edit the platform values

In
[`environments/kind-browser-admin/platform-values.yaml`](../../environments/kind-browser-admin/platform-values.yaml)
replace the values marked `REPLACE`: `publicEndpoints.steward`,
`browserAuth.google.clientId` and `browserAuth.google.workspaceDomain`. Keep
the file out of commits, or copy the directory under a new name and add a
matching environment to `helmfile/helmfile.yaml.gotmpl`
([helmfile/README.md](../../helmfile/README.md#production-shape)).

`organizationId` is a name you choose and keep stable (`org_` followed by up
to 60 lowercase letters, digits, `_` or `-`), not a Google organization ID.
`networkPolicy.egressCidrs.browserAuth` is `0.0.0.0/0` for evaluation: the
apiserver calls Google over HTTPS to exchange the code and fetch its keys, and
Google publishes no stable ranges
([apelogic-ai/steward#152](https://github.com/apelogic-ai/steward/issues/152)).

## Install

```sh
kind create cluster --name steward --config environments/kind/kind-config.yaml \
  --image "$(jq -r '.kubernetes.tested | last | .nodeImage' bom/bom.json)"
scripts/generate.sh environments/kind-browser-admin/platform-values.yaml

kubectl --context kind-steward create namespace steward
kubectl --context kind-steward create namespace identity
# The task-auth inputs: the exchange policy ConfigMap and keyring Secret in
# identity, and its public JWKS ConfigMap in steward, under the names in the
# platform values. See docs/profiles/task-auth.md.

# The Google client secret: one raw value, no trailing newline.
printf '%s' '<client secret>' > client-secret
kubectl --context kind-steward -n steward create secret generic steward-google-oidc \
  --from-file=client-secret=client-secret
rm client-secret

helmfile --file helmfile/helmfile.yaml.gotmpl --environment kind-browser-admin \
  --kube-context kind-steward sync
```

The Envoy Gateway CRD hook applies to the same `--kube-context` as the
releases ([details](../../helmfile/README.md#the-crd-hook-and-the-kube-context)).
The [browser-admin end-to-end test](../../tests/e2e/browser-admin/run.sh)
creates the same inputs in its `operator-inputs` stage; read it for a working
example.

## Reach the edge

The evaluation Gateway has no load balancer. Forward local port 443 to its
Envoy Service; the port must be 443 because the browser origin has no port:

```sh
service="$(kubectl --context kind-steward -n envoy-gateway-system get service -o name \
  -l gateway.envoyproxy.io/owning-gateway-name=steward-platform-edge)"
sudo kubectl --kubeconfig "${HOME}/.kube/config" --context kind-steward \
  -n envoy-gateway-system port-forward --address 127.0.0.1 "${service}" 443:443
```

On Linux, `sudo` is needed for port 443 unless
`net.ipv4.ip_unprivileged_port_start` is 443 or lower. If kind runs on
another machine, run the port-forward there on a free port and carry it to
your workstation, for example `sudo ssh -L 443:127.0.0.1:8443 <kind host>`
after forwarding `8443:443` on that host.

Point both hostnames at the forward in `/etc/hosts` on the workstation:

```text
127.0.0.1 steward.eval.example.com identity.platform.test
```

## Trust the evaluation edge CA

The Gateway's certificate comes from a self-signed CA that cert-manager
created in the cluster. Export its public certificate:

```sh
kubectl --context kind-steward -n envoy-gateway-system get secret steward-platform-edge-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > steward-platform-edge-ca.crt
openssl x509 -in steward-platform-edge-ca.crt -noout -subject -enddate
```

Then trust it in the browser you will sign in with:

- **macOS** (Safari, Chrome):
  `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain steward-platform-edge-ca.crt`
- **Linux, Chrome and Chromium**:
  `certutil -d "sql:${HOME}/.pki/nssdb" -A -t C,, -n steward-platform-edge-ca -i steward-platform-edge-ca.crt`
- **Firefox**: Settings, Privacy & Security, Certificates, View
  Certificates, Authorities, Import; trust it to identify websites.

This CA can sign a certificate for any name, and its private key is in the
cluster. Remove the trust when you delete the cluster (Keychain Access on
macOS, `certutil -D -n steward-platform-edge-ca` on Linux, the Authorities
list in Firefox).

Check the path before opening the browser:

```sh
curl --cacert steward-platform-edge-ca.crt -o /dev/null -w '%{http_code}\n' \
  https://steward.eval.example.com/health/ready     # 204: the web UI is ready
curl --cacert steward-platform-edge-ca.crt -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://steward.eval.example.com/admin/auth/login # 303 to accounts.google.com
```

Then open `https://<steward host>/admin/sign-in` and continue with the
[first-admin runbook](first-admin.md).

## Clean up

```sh
kind delete cluster --name steward
```

Remove the `/etc/hosts` line and the CA trust, and delete the OAuth client if
you no longer need it.
