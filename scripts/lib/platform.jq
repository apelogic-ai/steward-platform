# Pure functions that turn platform values and the BOM into chart values and
# helmfile inputs. Used by scripts/generate.sh; see that script for inputs.
#
# Every chart key set here is documented by the chart that owns it. The
# Steward keys come from its v0.3.1 chart:
# https://github.com/apelogic-ai/steward/blob/v0.3.1/charts/steward/values.yaml
# and the github-oidc-exchange keys from its v0.7.1 chart:
# https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.2/charts/github-oidc-exchange/values.yaml

# --- Reserved fields ---------------------------------------------------------

# Follow a local "$ref" in the schema.
def deref($schema):
  if type == "object" and has("$ref") then
    (.["$ref"] | ltrimstr("#/") | split("/")) as $path
    | $schema | getpath($path) | deref($schema)
  else . end;

# A property is reserved when it, or any schema it references, says so.
def is_reserved($schema):
  has("x-reserved")
  or (has("$ref") and ((.["$ref"] | ltrimstr("#/") | split("/")) as $path
      | $schema | getpath($path) | is_reserved($schema)));

# Paths (arrays of keys) of every property the schema marks x-reserved.
def reserved_paths($schema; $prefix):
  (.properties // {}) | to_entries[] | .key as $key | .value
  | if is_reserved($schema) then $prefix + [$key]
    else deref($schema) | reserved_paths($schema; $prefix + [$key]) end;

# Reserved paths that are set in the values, as dotted strings.
def reserved_in_use($schema):
  . as $values
  | [$schema | reserved_paths($schema; []) | select(. as $p | $values | getpath($p) != null) | join(".")];

# --- BOM helpers ------------------------------------------------------------

# registry/repository:tag@sha256:digest -> {repository, tag, digest}
def image_parts:
  capture("^(?<repository>[^@]+):(?<tag>[^:@/]+)@(?<digest>sha256:[a-f0-9]{64})$")
  // error("not a tag@digest image reference: \(.)");

# OCI chart reference pinned by digest, as helm and helmfile accept it.
def chart_ref: "\(.reference)@\(.digest)";

# --- Names the reference install owns ----------------------------------------

def evaluation_issuer_name: "steward-platform-evaluation-ca";
def evaluation_postgres_name: "postgresql-evaluation";
def evaluation_edge_issuer_name: "steward-platform-edge-ca";
def evaluation_gateway_class_name: "steward-platform-evaluation";

# github-oidc-exchange: the chart's fixed ServiceAccount name.
def identity_service_account_name: "github-oidc-exchange";

# --- Derived settings --------------------------------------------------------

def uses_cert_manager: .tls.mode == "certManager";
def installs_cert_manager: uses_cert_manager and .tls.certManager.install;
def uses_evaluation_issuer: uses_cert_manager and .tls.certManager.issuer.source == "evaluation";
def uses_evaluation_database: .database.source == "evaluation";
# browser-admin is task-auth plus Steward's browser web UI and login.
def task_auth: .profile == "task-auth" or .profile == "browser-admin";
def browser_admin: .profile == "browser-admin";
def installs_edge: task_auth and .edge.install;
def uses_evaluation_gateway: task_auth and .edge.gateway.source == "evaluation";

# https://host -> host
def origin_host: ltrimstr("https://");

# Steward's API Service DNS identity, which its certificate carries and the
# edge verifies.
def steward_api_hostname: "steward-apiserver.\(.namespaces.steward).svc.\(.cluster.domain)";

# Steward's browser login callback: the configured origin plus this exact
# path (Steward's browser session contract v1).
# https://github.com/apelogic-ai/steward/blob/v0.3.1/docs/browser-session-contract-v1.md
def browser_callback_path: "/admin/auth/callback";

# Every public apiserver path, for Steward's own web.httpRoute. The chart does
# not enforce the list, so the platform supplies all of it: the task API and its
# protected-resource metadata, the browser APIs and login, the GitHub
# connection callback, the operator API and the application API. Everything
# else is the web UI. From Steward's chart README and platform preflight:
# https://github.com/apelogic-ai/steward/blob/v0.3.1/charts/steward/README.md
# https://github.com/apelogic-ai/steward/blob/v0.3.1/scripts/steward-platform-preflight.py
def steward_api_paths:
  [
    {type: "Exact", value: "/.well-known/oauth-protected-resource"},
    {type: "PathPrefix", value: "/admin/api"},
    {type: "PathPrefix", value: "/admin/auth"},
    {type: "Exact", value: "/admin/connections/github/callback"},
    {type: "PathPrefix", value: "/admin/operator"},
    {type: "PathPrefix", value: "/app/api"},
    {type: "PathPrefix", value: "/v1"}
  ];
def steward_web_paths: [{type: "PathPrefix", value: "/"}];

# The Gateway listener both public hostnames attach to.
def edge_parent_refs:
  [{name: .edge.gateway.name, namespace: .edge.gateway.namespace, sectionName: .edge.gateway.listener}];

# Steward's config.apiserver.stewardRunRelease, projected from the BOM's
# steward-run entry with Steward's documented mapping (schemaVersion ->
# manifestSchemaVersion, image -> governedJobContainerImage). Every field comes
# from the signed release manifest (scripts/verify-signatures.sh); the image
# is the runner image without its tag, as the manifest names it.
# https://github.com/apelogic-ai/steward/blob/v0.3.1/docs/installation/governed-platform-compatibility.md
def steward_run_release($bom):
  $bom.products["steward-run"] as $run
  | ($run.images.runner | image_parts) as $image
  | {
      manifestSchemaVersion: $run.signatures.releaseManifest.schemaVersion,
      version: $run.version,
      workflowRepository: $run.workflow.repository,
      workflowCommit: $run.workflow.commit,
      actionCommit: $run.action.commit,
      governedJobContainerImage: "\($image.repository)@\($image.digest)"
    }
  | if any(.[]; . == null) then error("BOM: steward-run lacks a stewardRunRelease coordinate: \(.)") else . end;

# --- Chart values ------------------------------------------------------------

def steward_values($bom; $ca_bundle):
  . as $v
  | ($bom.products.steward.images.apiserver | image_parts) as $apiserver
  | ($bom.products.steward.images.controller | image_parts) as $controller
  | if $apiserver.repository != $controller.repository then
      error("BOM: Steward apiserver and controller images must share one repository")
    else . end
  | {
      images: {
        repository: $apiserver.repository,
        apiserver: {tag: $apiserver.tag, digest: $apiserver.digest},
        controller: {tag: $controller.tag, digest: $controller.digest}
      },
      execution: {enabled: false},
      serviceAccounts: {
        apiserver: {annotations: ($v.serviceAccounts.steward.apiserver.annotations // {})},
        controller: {annotations: ($v.serviceAccounts.steward.controller.annotations // {})}
      },
      secrets: {database: $v.database.secret},
      databaseTls: (
        if ($v.database.tls.mode // "disabled") == "verify-full"
        then {mode: "verify-full", ca: $v.database.tls.ca}
        else {mode: "disabled"} end
      ),
      tls: (
        if $v | uses_cert_manager then
          {
            mode: "certManager",
            issuerRef: (
              if $v | uses_evaluation_issuer
              then {name: evaluation_issuer_name, kind: "Issuer"}
              else $v.tls.certManager.issuer.ref end
            )
          }
        else
          {
            mode: "customerSecret",
            api: {secretName: ($v.tls.customerSecret.apiSecretName // "steward-apiserver-tls")},
            webhook: {
              secretName: ($v.tls.customerSecret.webhookSecretName // "steward-webhook-tls"),
              caBundlePem: $ca_bundle
            }
          }
        end
      ),
      config: {
        apiserver: (
          {kubernetesTokenReviewAudience: $v.cluster.serviceAccountTokenAudience}
          + (if $v | browser_admin then
              {stewardRunRelease: steward_run_release($bom)}
              + (if $v.administration.capabilityCatalog then
                  {capabilityCatalog: $v.administration.capabilityCatalog}
                else {} end)
            else {} end)
        )
      },
      networkPolicy: {
        enabled: true,
        dnsNamespace: $v.cluster.dnsNamespace,
        kubeApiCidrs: $v.cluster.kubeApi.cidrs,
        postgresCidrs: $v.database.cidrs,
        # Without the web UI the edge reaches the API as a direct caller: the
        # chart's ingressNamespace only applies with its web UI enabled.
        apiserverIngressNamespaces: (
          ($v.networkPolicy.apiserverIngressNamespaces // [])
          + (if ($v | task_auth) and ($v | browser_admin | not) then [$v.networkPolicy.edgeNamespace] else [] end)
          | reduce .[] as $n ([]; if index([$n]) then . else . + [$n] end)
        ),
        ports: {kubernetesApi: $v.cluster.kubeApi.port, postgres: $v.database.port}
      },
      services: {clusterDomain: $v.cluster.domain}
    }
  + (if $v | task_auth then
      {
        # Task tokens from github-oidc-exchange, verified against its public
        # JWKS. Policy v6 issues steward-task-v3, which needs federated
        # subjects; the resource enables the protected-resource metadata.
        taskIdentity: {
          enabled: true,
          issuer: $v.publicEndpoints.identityIssuer,
          audience: $v.audiences.taskApi,
          resource: $v.publicEndpoints.steward,
          federatedSubjects: {
            enabled: ($v.identityExchange.policy.contract == "github-oidc-exchange.apelogic.io/v6")
          },
          publicJwksConfigMap: $v.identityExchange.publicJwksConfigMap
        }
      }
    else {} end)
  # Deep merge: the web image and NetworkPolicy keys join the ones above.
  | . * (if $v | browser_admin then
      ($bom.products.steward.images.web | image_parts) as $web
      | if $web.repository != ($bom.products.steward.images.apiserver | image_parts).repository then
          error("BOM: Steward web and apiserver images must share one repository")
        else . end
      | {
          images: {web: {tag: $web.tag, digest: $web.digest}},
          # Google Workspace login. The origin is the public Steward origin;
          # the client secret stays in the operator's Secret.
          browserAuth: {
            enabled: true,
            google: {
              clientId: $v.browserAuth.google.clientId,
              origin: $v.publicEndpoints.steward,
              workspaceDomain: $v.browserAuth.google.workspaceDomain,
              organizationId: $v.browserAuth.google.organizationId,
              clientSecret: $v.browserAuth.google.clientSecret
            }
          },
          # The web UI, on the same origin as the API, and Steward's own
          # routes: the API paths to the apiserver through a BackendTLSPolicy
          # that verifies its certificate, everything else to the web UI.
          web: {
            enabled: true,
            host: ($v.publicEndpoints.steward | origin_host),
            httpRoute: {
              enabled: true,
              parentRefs: ($v | edge_parent_refs),
              hostname: ($v.publicEndpoints.steward | origin_host),
              apiPaths: steward_api_paths,
              webPaths: steward_web_paths,
              backendTls: {
                hostname: ($v | steward_api_hostname),
                caConfigMap: {name: $v.edge.stewardBackendCaConfigMap, key: "ca.crt"}
              }
            }
          },
          networkPolicy: {
            browserAuthEgressCidrs: $v.networkPolicy.egressCidrs.browserAuth,
            # The edge data plane reaches the web UI and, as the chart's edge
            # namespace, the apiserver.
            ingressNamespace: $v.networkPolicy.edgeNamespace
          }
        }
    else {} end);

# cert-manager chart values: CRDs as templates (so upgrades update them) and
# every image pinned to its BOM digest.
# https://github.com/cert-manager/cert-manager/blob/v1.21.2/deploy/charts/cert-manager/values.yaml
def cert_manager_values($bom):
  ($bom.dependencies["cert-manager"].images) as $images
  | def pinned($component): $images[$component] | image_parts | {repository, tag, digest};
  {
    crds: {enabled: true, keep: true},
    image: pinned("controller"),
    webhook: {image: pinned("webhook")},
    cainjector: {image: pinned("cainjector")},
    startupapicheck: {image: pinned("startupapicheck")},
    acmesolver: {image: pinned("acmesolver")}
  };

# Values for charts/evaluation-ca in this repository.
def evaluation_ca_values:
  {name: evaluation_issuer_name};

# github-oidc-exchange chart values. The policy ConfigMap and keyring Secret
# are referenced, never created. Workload exchange and browser HOP-1 stay off.
def identity_values($bom):
  . as $v
  | ($bom.products["github-oidc-exchange"].images.exchange | image_parts) as $image
  | {
      image: {repository: $image.repository, tag: $image.tag, digest: $image.digest},
      serviceAccount: {
        create: true,
        name: identity_service_account_name,
        annotations: ($v.serviceAccounts.identityExchange.annotations // {})
      },
      config: {
        issuerUrl: $v.publicEndpoints.identityIssuer,
        githubExchangeAudience: $v.identityExchange.githubAudience,
        outputAudience: $v.audiences.taskApi,
        policyContract: $v.identityExchange.policy.contract,
        policyConfigMapName: $v.identityExchange.policy.configMapName,
        keyringSecretName: $v.identityExchange.keyring.secretName
      },
      rolloutRevisions: {
        githubPolicy: $v.identityExchange.policy.revision,
        githubKeyring: $v.identityExchange.keyring.revision
      },
      httpRoute: {
        enabled: true,
        parentRefs: ($v | edge_parent_refs),
        hostnames: [$v.publicEndpoints.identityIssuer | origin_host]
      },
      networkPolicy: {
        enabled: true,
        ingressCidrs: $v.edge.clientCidrs,
        dnsNamespaceSelector: {"kubernetes.io/metadata.name": $v.cluster.dnsNamespace}
      }
    };

# Envoy Gateway, without its bundled CRDs, with the controller and proxy
# images pinned to their BOM digests. The Gateway API CRDs (standard channel)
# and Envoy Gateway's own CRDs are the BOM manifests, which the helmfile
# server-side applies first (scripts/apply-manifests.sh).
# https://github.com/envoyproxy/gateway/blob/v1.9.1/charts/gateway-helm/values.yaml
def envoy_gateway_values($bom):
  ($bom.dependencies["envoy-gateway"].images) as $images
  | {
      crds: {enabled: false},
      global: {
        images: {
          envoyGateway: {image: $images.controller},
          envoyProxy: {image: $images.proxy}
        }
      }
    };

# Values for charts/steward-edge in this repository: Steward's task API routes.
def steward_edge_values:
  . as $v
  | {
      hostname: ($v.publicEndpoints.steward | origin_host),
      parentRefs: ($v | edge_parent_refs),
      backendTls: {
        hostname: ($v | steward_api_hostname),
        caConfigMapName: $v.edge.stewardBackendCaConfigMap
      }
    };

# Values for the evaluation edge CA: charts/evaluation-ca again, in the
# Gateway namespace.
def edge_evaluation_ca_values:
  {name: evaluation_edge_issuer_name};

# Values for charts/evaluation-edge in this repository.
def evaluation_edge_values:
  . as $v
  | {
      gatewayClassName: evaluation_gateway_class_name,
      gateway: {name: $v.edge.gateway.name, listener: $v.edge.gateway.listener},
      hostnames: [$v.publicEndpoints.steward, $v.publicEndpoints.identityIssuer | origin_host],
      routeNamespaces: [$v.namespaces.steward, $v.namespaces.identityExchange],
      issuerName: evaluation_edge_issuer_name,
      stewardCa: {
        namespace: $v.namespaces.steward,
        secretName: evaluation_issuer_name,
        configMapName: $v.edge.stewardBackendCaConfigMap
      }
    };

# Values for charts/postgresql-evaluation in this repository.
def postgresql_evaluation_values($bom):
  . as $v
  | {
      name: evaluation_postgres_name,
      image: ($bom.dependencies.postgresql.images.postgres | image_parts | {repository, tag, digest}),
      port: $v.database.port,
      clusterDomain: $v.cluster.domain,
      stewardDatabaseSecret: $v.database.secret
    };

# --- helmfile inputs ---------------------------------------------------------

def helmfile_environment($bom):
  . as $v
  | {
      platformVersion: $bom.platformVersion,
      environment: $v.environment,
      purpose: $v.purpose,
      profile: $v.profile,
      namespaces: (
        {steward: $v.namespaces.steward, certManager: $v.namespaces.certManager}
        + (if $v | task_auth then
            {
              identityExchange: $v.namespaces.identityExchange,
              edge: $v.networkPolicy.edgeNamespace,
              gateway: $v.edge.gateway.namespace
            }
          else {} end)
      ),
      releases: {
        certManager: {
          enabled: ($v | installs_cert_manager),
          chart: ($bom.dependencies["cert-manager"].chart | chart_ref),
          version: $bom.dependencies["cert-manager"].chart.version
        },
        evaluationCa: {enabled: ($v | uses_evaluation_issuer)},
        postgresqlEvaluation: {enabled: ($v | uses_evaluation_database)},
        steward: {
          chart: ($bom.products.steward.chart | chart_ref),
          version: $bom.products.steward.chart.version,
          # Steward renders Gateway API objects itself, so it needs their CRDs.
          routes: ($v | browser_admin)
        },
        envoyGateway: (
          {enabled: ($v | installs_edge)}
          + (if $v | installs_edge then
              {chart: ($bom.dependencies["envoy-gateway"].chart | chart_ref),
               version: $bom.dependencies["envoy-gateway"].chart.version}
            else {} end)
        ),
        edgeEvaluationCa: {enabled: ($v | uses_evaluation_gateway)},
        evaluationEdge: {enabled: ($v | uses_evaluation_gateway)},
        # browser-admin routes through Steward's own web.httpRoute instead.
        stewardEdge: {enabled: (($v | task_auth) and ($v | browser_admin | not))},
        identityExchange: (
          {enabled: ($v | task_auth)}
          + (if $v | task_auth then
              {chart: ($bom.products["github-oidc-exchange"].chart | chart_ref),
               version: $bom.products["github-oidc-exchange"].chart.version}
            else {} end)
        )
      }
    };

# --- Flux ---------------------------------------------------------------------

# Flux objects live here; each HelmRelease installs into its own namespace.
def flux_namespace: "flux-system";

# OCIRepository for a BOM chart, pinned by digest. The layer selector picks the
# chart archive (cert-manager also publishes a provenance layer).
# https://fluxcd.io/flux/components/source/ocirepositories/
def flux_oci_repository($name; $chart):
  {
    apiVersion: "source.toolkit.fluxcd.io/v1",
    kind: "OCIRepository",
    metadata: {name: $name, namespace: flux_namespace},
    spec: {
      interval: "1h",
      url: $chart.reference,
      ref: {digest: $chart.digest},
      layerSelector: {
        mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip",
        operation: "copy"
      }
    }
  };

# https://fluxcd.io/flux/components/helm/helmreleases/
def flux_helm_release($name; $namespace; $depends_on; $crds_on_upgrade; $values):
  {
    apiVersion: "helm.toolkit.fluxcd.io/v2",
    kind: "HelmRelease",
    metadata: {name: $name, namespace: flux_namespace},
    spec: (
      {
        interval: "1h",
        releaseName: $name,
        targetNamespace: $namespace,
        storageNamespace: $namespace,
        chartRef: {kind: "OCIRepository", name: $name}
      }
      + (if ($depends_on | length) > 0 then {dependsOn: [$depends_on[] | {name: .}]} else {} end)
      + {
        install: {createNamespace: true, crds: "Create", remediation: {retries: 3}},
        upgrade: {crds: $crds_on_upgrade, remediation: {retries: 3}},
        values: $values
      }
    )
  };

# The Flux example covers the BOM charts only. Evaluation pieces are in-repo
# charts that the helmfile installs; an environment that uses them gets no
# Flux output.
# The Flux output covers the core profile only for now.
def flux_supported: .profile == "core" and ((uses_evaluation_issuer or uses_evaluation_database) | not);

def flux_files($bom; $ca_bundle):
  . as $v
  | (if $v | installs_cert_manager then
      {"flux/cert-manager.yaml": [
        flux_oci_repository("cert-manager"; $bom.dependencies["cert-manager"].chart),
        flux_helm_release("cert-manager"; $v.namespaces.certManager; []; "Create"; cert_manager_values($bom))
      ]}
    else {} end)
  + {"flux/steward.yaml": [
      flux_oci_repository("steward"; $bom.products.steward.chart),
      # Steward's CRD is in the chart's crds/ directory. Skip keeps Helm's
      # behaviour: the CRD is upgraded deliberately, after reading the release
      # notes (see helmfile/README.md).
      flux_helm_release("steward"; $v.namespaces.steward;
        (if $v | installs_cert_manager then ["cert-manager"] else [] end); "Skip";
        ($v | steward_values($bom; $ca_bundle)))
    ]}
  | . + {"flux/kustomization.yaml": {
      apiVersion: "kustomize.config.k8s.io/v1beta1",
      kind: "Kustomization",
      resources: [keys[] | select(. != "flux/kustomization.yaml") | ltrimstr("flux/")]
    }};

# --- Everything, keyed by output path ----------------------------------------

def generate($bom; $ca_bundle):
  . as $v
  | {"helmfile.yaml": ($v | helmfile_environment($bom)),
     "values/steward.yaml": ($v | steward_values($bom; $ca_bundle))}
  + (if $v | installs_cert_manager then {"values/cert-manager.yaml": cert_manager_values($bom)} else {} end)
  + (if $v | uses_evaluation_issuer then {"values/evaluation-ca.yaml": evaluation_ca_values} else {} end)
  + (if $v | uses_evaluation_database then {"values/postgresql-evaluation.yaml": ($v | postgresql_evaluation_values($bom))} else {} end)
  + (if $v | task_auth then
      {"values/github-oidc-exchange.yaml": ($v | identity_values($bom))}
    else {} end)
  + (if ($v | task_auth) and ($v | browser_admin | not) then
      {"values/steward-edge.yaml": ($v | steward_edge_values)}
    else {} end)
  + (if $v | installs_edge then
      {"values/envoy-gateway.yaml": envoy_gateway_values($bom)}
    else {} end)
  + (if $v | uses_evaluation_gateway then
      {"values/edge-evaluation-ca.yaml": edge_evaluation_ca_values,
       "values/evaluation-edge.yaml": ($v | evaluation_edge_values)}
    else {} end)
  + (if $v | flux_supported then $v | flux_files($bom; $ca_bundle) else {} end);
