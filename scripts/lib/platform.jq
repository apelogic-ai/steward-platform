# Pure functions that turn platform values and the BOM into chart values and
# helmfile inputs. Used by scripts/generate.sh; see that script for inputs.
#
# Every chart key set here is documented by the chart that owns it. The
# Steward keys come from its v0.3.8 chart:
# https://github.com/apelogic-ai/steward/blob/v0.3.8/charts/steward/values.yaml
# and the github-oidc-exchange keys from its v0.7.5 chart:
# https://github.com/apelogic-ai/github-oidc-exchange/blob/v0.7.5/charts/github-oidc-exchange/values.yaml

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

# --- Registry mirror ---------------------------------------------------------
#
# The platform values' registry block names a mirror per artifact class. A
# rewrite changes only the registry or host and the leading path of a
# reference; the tag and the digest stay the BOM's. Every function below takes
# the platform values as input. See docs/registry-mirroring.md.

# The mirror of one artifact class, or null when it comes from upstream.
def mirror_of($class): (.registry // {})[$class];

# The BOM class of a product or dependency artifact.
def image_class($kind): if $kind == "products" then "productImages" else "dependencyImages" end;
def chart_class($kind): if $kind == "products" then "productCharts" else "dependencyCharts" end;

# host/path (an OCI repository) or scheme://host/path (a URL), rewritten for
# the mirror $m: the prefix replaces the host, or with keepSourceHost precedes
# it. Unchanged when $m is null.
def mirror_location($m):
  if $m == null then .
  else
    (capture("^(?<scheme>[a-z]+://)?(?<host>[^/]+)/(?<path>.+)$")
      // error("cannot mirror \(.): not a host/path reference"))
    | "\($m.prefix)/\(if $m.keepSourceHost then "\(.host)/" else "" end)\(.path)"
  end;

# A BOM image reference, registry/repository:tag@digest, from its class's
# mirror.
def mirror_image($class; $ref):
  mirror_of($class) as $m
  | ($ref | image_parts) as $p
  | "\($p.repository | mirror_location($m)):\($p.tag)@\($p.digest)";

# A BOM chart ({reference, version, digest}) from its class's mirror.
def mirror_chart($class; $chart):
  mirror_of($class) as $m
  | $chart + {reference: ("oci://" + ($chart.reference | ltrimstr("oci://") | mirror_location($m)))};

# A Git repository URL from the gitSources mirror: its exact entry in
# repositories, else by prefix.
def mirror_git($url):
  mirror_of("gitSources") as $m
  | if $m == null then $url
    elif ($m.repositories // {})[$url] then $m.repositories[$url]
    elif $m.prefix then $url | mirror_location($m)
    else $url end;

# A manifest download URL from the manifests mirror.
def mirror_manifest_url($url): mirror_of("manifests") as $m | $url | mirror_location($m);

# Image pull secrets, as the charts take them: [{name: ...}].
def image_pull_secrets: [(.registry.imagePullSecrets // [])[] | {name: .}];

# The Flux access settings (secretRef, provider, certSecretRef) of a class, as
# source spec fields.
def mirror_flux_access($class):
  (mirror_of($class).flux // {}) | with_entries(select(.value != null));

# This repository, for its in-repo steward-edge chart.
def platform_repository: "https://github.com/apelogic-ai/steward-platform";

# Every artifact in the BOM, or in one BOM profile, with where it comes from
# and where the platform values mirror it to. Consumed by scripts/mirror-list.sh
# and scripts/verify-digests.sh --mirror. Kubernetes node images (kind, for
# tests) are not install artifacts and are left out.
#
# Entries of type "oci" (charts and images) carry source and target as
# repository:tag and sourceRef and targetRef as repository@digest; copying
# sourceRef to target keeps the digest. "git" entries carry the repository and
# its ref; "http" entries the URL and its SHA-256.
def mirror_list($bom; $profile):
  . as $v
  | (if $profile == null then null
     else $bom.profiles[$profile] // error("the BOM has no \($profile) profile") end) as $p
  | def included($kind; $name): $p == null or any($p[$kind][]; . == $name);
    def oci($class; $id; $artifact; $repository; $tag; $digest):
      ($repository | mirror_location($v | mirror_of($class))) as $target
      | {id: $id, class: $class, type: "oci", artifact: $artifact,
         source: "\($repository):\($tag)", digest: $digest, sourceRef: "\($repository)@\($digest)",
         target: "\($target):\($tag)", targetRef: "\($target)@\($digest)",
         mirrored: (($v | mirror_of($class)) != null)};
    def git($id; $repository; $ref):
      ($v | mirror_git($repository)) as $target
      | {id: $id, class: "gitSources", type: "git", artifact: "git", source: $repository, ref: $ref,
         target: $target, mirrored: ($target != $repository)};
    def http($id; $url; $digest):
      {id: $id, class: "manifests", type: "http", artifact: "manifest", source: $url, digest: $digest,
       target: ($v | mirror_manifest_url($url)), mirrored: (($v | mirror_of("manifests")) != null)};
    [ ("products", "dependencies") as $kind
      | $bom[$kind] | to_entries[] | select(included($kind; .key)) | .key as $name | .value
      | (.chart // empty
          | oci(chart_class($kind); "\($kind).\($name).chart"; "chart";
              (.reference | ltrimstr("oci://")); .version; .digest)),
        ((.images // {}) | to_entries[]
          | (.value | image_parts) as $image
          | oci(image_class($kind); "\($kind).\($name).images.\(.key)"; "image";
              $image.repository; $image.tag; $image.digest)),
        # The images of every other tested version (the default's are above).
        (.images as $default | (.tested // [])[] | .version as $version
          | (.images // {}) | to_entries[] | select(.value != $default[.key])
          | (.value | image_parts) as $image
          | oci(image_class($kind); "\($kind).\($name).tested.\($version).images.\(.key)"; "image";
              $image.repository; $image.tag; $image.digest)),
        ((.manifests // []) | to_entries[] | .key as $i | .value
          | http("\($kind).\($name).manifests.\($i)"; .url; .digest),
            (.fluxSource.git // empty
              | git("\($kind).\($name).manifests.\($i).fluxSource.git"; .repository; {tag, commit})))
    ]
    # charts/steward-edge, which the task-auth Flux output builds from this
    # repository at the platform tag.
    + (if $profile == null or $profile == "task-auth" then
        [git("platform.charts.steward-edge"; platform_repository; {tag: $bom.platformVersion})]
      else [] end);

# Refuse a mirror that maps two different upstream artifacts onto one target,
# for example two registries' same path with keepSourceHost false.
def mirror_collisions($bom):
  [mirror_list($bom; null)[]
    | if .type == "oci" then {target: (.targetRef | sub("@.*$"; "")), source: (.sourceRef | sub("@.*$"; ""))}
      else {target, source} end]
  | group_by(.target)
  | map(select((map(.source) | unique | length) > 1)
      | "\(map(.source) | unique | join(" and ")) both map to \(.[0].target)")
  | if length > 0 then error("registry: \(join("; ")); set keepSourceHost true or use distinct prefixes") else . end;

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
# https://github.com/apelogic-ai/steward/blob/v0.3.8/docs/browser-session-contract-v1.md
def browser_callback_path: "/admin/auth/callback";

# Every public apiserver path, for Steward's own web.httpRoute: the task API and
# its protected-resource metadata, the browser APIs and login, the GitHub
# connection callback, the operator API and the application API. Everything
# else is the web UI. From 0.3.2 the chart's values schema requires exactly
# these seven entries in this order (the chart README's order), and exactly
# [PathPrefix /] as webPaths; helm lint and helm template in
# tests/generate/run.sh apply that schema.
# https://github.com/apelogic-ai/steward/blob/v0.3.8/charts/steward/README.md
# https://github.com/apelogic-ai/steward/blob/v0.3.8/charts/steward/values.schema.json
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
# https://github.com/apelogic-ai/steward/blob/v0.3.8/docs/installation/governed-platform-compatibility.md
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
  | ($v | mirror_image("productImages"; $bom.products.steward.images.apiserver) | image_parts) as $apiserver
  | ($v | mirror_image("productImages"; $bom.products.steward.images.controller) | image_parts) as $controller
  | if $apiserver.repository != $controller.repository then
      error("BOM: Steward apiserver and controller images must share one repository")
    else . end
  | {
      images: {
        repository: $apiserver.repository,
        apiserver: {tag: $apiserver.tag, digest: $apiserver.digest},
        controller: {tag: $controller.tag, digest: $controller.digest}
      }
    }
  + (if ($v | image_pull_secrets | length) > 0 then {imagePullSecrets: ($v | image_pull_secrets)} else {} end)
  + {
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
      ($v | mirror_image("productImages"; $bom.products.steward.images.web) | image_parts) as $web
      | if $web.repository != .images.repository then
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
  . as $v
  | ($bom.dependencies["cert-manager"].images) as $images
  | def pinned($component): $v | mirror_image("dependencyImages"; $images[$component]) | image_parts | {repository, tag, digest};
  (if ($v | image_pull_secrets | length) > 0 then {global: {imagePullSecrets: ($v | image_pull_secrets)}} else {} end)
  + {
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
  | ($v | mirror_image("productImages"; $bom.products["github-oidc-exchange"].images.exchange) | image_parts) as $image
  | {
      image: (
        {repository: $image.repository, tag: $image.tag, digest: $image.digest}
        + (if ($v | image_pull_secrets | length) > 0 then {pullSecrets: ($v | image_pull_secrets)} else {} end)
      ),
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
  . as $v
  | ($bom.dependencies["envoy-gateway"].images) as $images
  | {
      crds: {enabled: false},
      global: (
        # global.imagePullSecrets also reaches the Envoy proxies the controller
        # creates.
        (if ($v | image_pull_secrets | length) > 0 then {imagePullSecrets: ($v | image_pull_secrets)} else {} end)
        + {
          images: {
            envoyGateway: {image: ($v | mirror_image("dependencyImages"; $images.controller))},
            envoyProxy: {image: ($v | mirror_image("dependencyImages"; $images.proxy))}
          }
        }
      )
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

# The BOM's tested PostgreSQL entries that database.evaluationVersion names: a
# major version ("17") or an exact one. scripts/generate.sh requires exactly
# one.
def evaluation_postgres_matches($bom):
  .database.evaluationVersion as $wanted
  | [($bom.dependencies.postgresql.tested // [])[]
      | select(.version == $wanted or (.version | startswith($wanted + ".")))];

# The evaluation PostgreSQL image: that tested entry's, or the BOM default.
def evaluation_postgres_image($bom):
  if .database.evaluationVersion == null then $bom.dependencies.postgresql.images.postgres
  else evaluation_postgres_matches($bom)
    | if length == 1 then .[0].images.postgres
      else error("database.evaluationVersion does not name exactly one tested PostgreSQL version") end
  end;

# Values for charts/postgresql-evaluation in this repository.
def postgresql_evaluation_values($bom):
  . as $v
  | {
      name: evaluation_postgres_name,
      image: ($v | mirror_image("dependencyImages"; $v | evaluation_postgres_image($bom)) | image_parts | {repository, tag, digest}),
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
          chart: ($v | mirror_chart("dependencyCharts"; $bom.dependencies["cert-manager"].chart) | chart_ref),
          version: $bom.dependencies["cert-manager"].chart.version
        },
        evaluationCa: {enabled: ($v | uses_evaluation_issuer)},
        postgresqlEvaluation: {enabled: ($v | uses_evaluation_database)},
        steward: {
          chart: ($v | mirror_chart("productCharts"; $bom.products.steward.chart) | chart_ref),
          version: $bom.products.steward.chart.version,
          # Steward renders Gateway API objects itself, so it needs their CRDs.
          routes: ($v | browser_admin)
        },
        envoyGateway: (
          {enabled: ($v | installs_edge)}
          + (if $v | installs_edge then
              {chart: ($v | mirror_chart("dependencyCharts"; $bom.dependencies["envoy-gateway"].chart) | chart_ref),
               version: $bom.dependencies["envoy-gateway"].chart.version}
              # The CRD manifests the presync hook applies, from the manifests
              # mirror; the hook still checks each against its BOM SHA-256.
              + (if $v | mirror_of("manifests") then
                  {manifestUrls: (["gateway-api-crds", "envoy-gateway"]
                    | map(. as $d | {($d): ($v | mirror_manifest_url($bom.dependencies[$d].manifests[0].url))}) | add)}
                else {} end)
            else {} end)
        ),
        edgeEvaluationCa: {enabled: ($v | uses_evaluation_gateway)},
        evaluationEdge: {enabled: ($v | uses_evaluation_gateway)},
        # browser-admin routes through Steward's own web.httpRoute instead.
        stewardEdge: {enabled: (($v | task_auth) and ($v | browser_admin | not))},
        identityExchange: (
          {enabled: ($v | task_auth)}
          + (if $v | task_auth then
              {chart: ($v | mirror_chart("productCharts"; $bom.products["github-oidc-exchange"].chart) | chart_ref),
               version: $bom.products["github-oidc-exchange"].chart.version}
            else {} end)
        )
      }
    }
  # With a chart mirror, one helmfile OCI repository per chart class, so that
  # helmfile logs in to its registry with <NAME>_USERNAME and <NAME>_PASSWORD
  # from the environment when both are set (otherwise Helm's own registry
  # credentials apply). docs/registry-mirroring.md
  + ([["productCharts", "steward-platform-product-charts"], ["dependencyCharts", "steward-platform-dependency-charts"]]
      | map(.[0] as $class | .[1] as $name | ($v | mirror_of($class)) as $m
          | select($m != null) | {name: $name, host: ($m.prefix | split("/")[0])})
      | if length > 0 then {registryLogins: .} else {} end);

# --- Flux ---------------------------------------------------------------------

# Flux objects live here; each HelmRelease installs into its own namespace.
def flux_namespace: "flux-system";

# The Helm chart layer of an OCI chart artifact.
def helm_chart_media_type: "application/vnd.cncf.helm.chart.content.v1.tar+gzip";

# OCIRepository for a BOM chart, pinned by digest. The layer selector picks the
# chart archive (cert-manager also publishes a provenance layer): "copy" keeps
# it as a chart for a HelmRelease, "extract" unpacks it for a Kustomization.
# https://fluxcd.io/flux/components/source/ocirepositories/
def flux_oci_repository($name; $chart; $operation):
  {
    apiVersion: "source.toolkit.fluxcd.io/v1",
    kind: "OCIRepository",
    metadata: {name: $name, namespace: flux_namespace},
    spec: {
      interval: "1h",
      url: $chart.reference,
      ref: {digest: $chart.digest},
      layerSelector: {mediaType: helm_chart_media_type, operation: $operation}
    }
  };

# The OCIRepository of a BOM chart of $class, from that class's mirror with
# its Flux access settings (secretRef, provider, certSecretRef) when the
# platform values set one. Takes the platform values.
def flux_chart_source($name; $class; $chart; $operation):
  . as $v
  | flux_oci_repository($name; $v | mirror_chart($class; $chart); $operation)
  | .spec += ($v | mirror_flux_access($class));
def flux_chart_source($name; $class; $chart): flux_chart_source($name; $class; $chart; "copy");

# GitRepository at a pinned commit or tag, keeping only one directory in the
# artifact.
# https://fluxcd.io/flux/components/source/gitrepositories/
def flux_git_repository($name; $url; $ref; $path):
  {
    apiVersion: "source.toolkit.fluxcd.io/v1",
    kind: "GitRepository",
    metadata: {name: $name, namespace: flux_namespace},
    spec: {
      interval: "1h",
      url: $url,
      ref: $ref,
      ignore: "/*\n!/\($path)/\n"
    }
  };

# The same, from the gitSources mirror with its secretRef when the platform
# values set one. Takes the platform values.
def flux_git_source($name; $url; $ref; $path):
  . as $v
  | flux_git_repository($name; $v | mirror_git($url); $ref; $path)
  | .spec += ($v | mirror_flux_access("gitSources"));

# Kustomization that server-side applies a directory of plain manifests, as
# scripts/apply-manifests.sh does for the helmfile. prune: false never deletes
# CRDs (and with them every object of their kinds), also when the
# Kustomization itself is removed; wait: true is ready once they are
# established.
# https://fluxcd.io/flux/components/kustomize/kustomizations/
def flux_manifests_kustomization($name; $source_kind; $path; $depends_on):
  {
    apiVersion: "kustomize.toolkit.fluxcd.io/v1",
    kind: "Kustomization",
    metadata: {name: $name, namespace: flux_namespace},
    spec: (
      {
        interval: "1h",
        sourceRef: {kind: $source_kind, name: $name},
        path: "./\($path)",
        prune: false,
        wait: true,
        timeout: "5m"
      }
      + (if ($depends_on | length) > 0 then {dependsOn: [$depends_on[] | {name: .}]} else {} end)
    )
  };

# https://fluxcd.io/flux/components/helm/helmreleases/
#
# $options:
#   chart         {chartRef: ...} or {chart: ...}; default: the OCIRepository
#                 of the same name
#   crdsOnUpgrade Create or Skip (default Skip, which is Helm's behaviour);
#   crds          both install and upgrade, overriding the two defaults
#   retry         retry a failed install or upgrade every minute, without
#                 remediation, instead of three remediated attempts
def flux_helm_release($name; $namespace; $depends_on; $options; $values):
  ($options.crds // "Create") as $install_crds
  | ($options.crds // $options.crdsOnUpgrade // "Skip") as $upgrade_crds
  | (if $options.retry then {strategy: {name: "RetryOnFailure", retryInterval: "1m"}}
     else {remediation: {retries: 3}} end) as $on_failure
  | {
      apiVersion: "helm.toolkit.fluxcd.io/v2",
      kind: "HelmRelease",
      metadata: {name: $name, namespace: flux_namespace},
      spec: (
        {
          interval: "1h",
          releaseName: $name,
          targetNamespace: $namespace,
          storageNamespace: $namespace
        }
        + ($options.chart // {chartRef: {kind: "OCIRepository", name: $name}})
        + (if ($depends_on | length) > 0 then {dependsOn: [$depends_on[] | {name: .}]} else {} end)
        + {
          install: ({createNamespace: true, crds: $install_crds} + $on_failure),
          upgrade: ({crds: $upgrade_crds} + $on_failure),
          values: $values
        }
      )
    };

# The Flux output covers the production shape: the BOM charts, and
# charts/steward-edge from this repository. The evaluation pieces (CA,
# PostgreSQL, Gateway) are in-repo charts that only the helmfile installs; an
# environment that uses any of them gets no Flux output.
def flux_supported:
  (uses_evaluation_issuer or uses_evaluation_database or uses_evaluation_gateway) | not;

# The BOM manifests the helmfile server-side applies before envoy-gateway
# (its presync hook), in that order, each with the Flux source of the same
# objects.
def flux_edge_manifests($bom):
  ["gateway-api-crds", "envoy-gateway"]
  | map(. as $dependency | $bom.dependencies[$dependency] as $d
      | ($d.manifests // error("BOM: \($dependency) pins no manifests"))
      | if length != 1 then error("BOM: the Flux output takes one manifest per dependency; \($dependency) pins \(length)") else .[0] end
      | (.fluxSource // error("BOM: \($dependency) manifest \(.url) has no fluxSource"))
      | {dependency: $dependency, name: "\($dependency | rtrimstr("-crds"))-crds", source: ., chart: $d.chart});

def flux_manifest_objects($manifest; $depends_on):
  if $manifest.source.git then
    $manifest.source.git as $git
    | [flux_git_source($manifest.name; $git.repository; {commit: $git.commit}; $git.path),
       flux_manifests_kustomization($manifest.name; "GitRepository"; $git.path; $depends_on)]
  else
    [flux_chart_source($manifest.name; "dependencyCharts"; $manifest.chart; "extract"),
     flux_manifests_kustomization($manifest.name; "OCIRepository"; $manifest.source.chart.path; $depends_on)]
  end;

def flux_files($bom; $ca_bundle):
  . as $v
  | ($v | installs_cert_manager) as $cert_manager
  | ($v | installs_edge) as $edge
  | ($v | task_auth and (browser_admin | not)) as $steward_edge
  # Flux cannot order a HelmRelease after a Kustomization. With the edge
  # installed here, the releases that need the Gateway API or Envoy Gateway
  # CRDs retry until the CRD Kustomizations have applied them.
  | {retry: $edge} as $needs_crds
  | (if $cert_manager then
      {"flux/cert-manager.yaml": [
        flux_chart_source("cert-manager"; "dependencyCharts"; $bom.dependencies["cert-manager"].chart),
        flux_helm_release("cert-manager"; $v.namespaces.certManager; []; {crdsOnUpgrade: "Create"}; cert_manager_values($bom))
      ]}
    else {} end)
  + {"flux/steward.yaml": [
      flux_chart_source("steward"; "productCharts"; $bom.products.steward.chart),
      # Steward's CRD is in the chart's crds/ directory. Skip keeps Helm's
      # behaviour: the CRD is upgraded deliberately, after reading the release
      # notes (see helmfile/README.md). In browser-admin Steward renders its
      # own routes, so it follows envoy-gateway as in the helmfile.
      flux_helm_release("steward"; $v.namespaces.steward;
        (if $cert_manager then ["cert-manager"] else [] end)
          + (if ($v | browser_admin) and $edge then ["envoy-gateway"] else [] end);
        (if $v | browser_admin then $needs_crds else {} end);
        ($v | steward_values($bom; $ca_bundle)))
    ]}
  + (if $edge then
      # The helmfile's presync hook, as Kustomizations: the Gateway API CRDs,
      # then Envoy Gateway's, server-side applied.
      (flux_edge_manifests($bom)) as $manifests
      | reduce range(0; $manifests | length) as $i ({};
          . + {"flux/\($manifests[$i].name).yaml":
                ($v | flux_manifest_objects($manifests[$i];
                  (if $i > 0 then [$manifests[$i - 1].name] else [] end)))})
      + {"flux/envoy-gateway.yaml": [
          flux_chart_source("envoy-gateway"; "dependencyCharts"; $bom.dependencies["envoy-gateway"].chart),
          # The CRDs belong to the Kustomizations above, never to Helm.
          flux_helm_release("envoy-gateway"; $v.networkPolicy.edgeNamespace; [];
            $needs_crds + {crds: "Skip"}; envoy_gateway_values($bom))
        ]}
    else {} end)
  + (if $steward_edge then
      # charts/steward-edge is not published as an artifact: Flux builds it
      # from this repository at the tag of this platform version.
      {"flux/steward-edge.yaml": [
        flux_git_source("steward-platform"; platform_repository;
          {tag: $bom.platformVersion}; "charts/steward-edge"),
        flux_helm_release("steward-edge"; $v.namespaces.steward;
          ["steward"] + (if $edge then ["envoy-gateway"] else [] end);
          $needs_crds + {chart: {chart: {spec: {
            chart: "./charts/steward-edge",
            sourceRef: {kind: "GitRepository", name: "steward-platform"},
            reconcileStrategy: "Revision"
          }}}};
          ($v | steward_edge_values))
      ]}
    else {} end)
  + (if $v | task_auth then
      {"flux/github-oidc-exchange.yaml": [
        flux_chart_source("github-oidc-exchange"; "productCharts"; $bom.products["github-oidc-exchange"].chart),
        flux_helm_release("github-oidc-exchange"; $v.namespaces.identityExchange;
          (if $edge then ["envoy-gateway"] else [] end); $needs_crds;
          ($v | identity_values($bom)))
      ]}
    else {} end)
  | . + {"flux/kustomization.yaml": {
      apiVersion: "kustomize.config.k8s.io/v1beta1",
      kind: "Kustomization",
      resources: [keys[] | select(. != "flux/kustomization.yaml") | ltrimstr("flux/")]
    }};

# --- Everything, keyed by output path ----------------------------------------

def generate($bom; $ca_bundle):
  . as $v
  | mirror_collisions($bom) as $_
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

# The mirror list entries that the install generated from these platform values
# pulls: the charts and images whose digest the generated values, helmfile
# inputs or Flux objects name, the Git sources the Flux objects read, and the
# CRD manifests when the helmfile applies them. Used by scripts/mirror-list.sh
# --installed.
def installed_artifacts($bom):
  generate($bom; "") as $files
  | ([$files | .. | strings | scan("sha256:[a-f0-9]{64}")] | unique) as $digests
  | ([$files | .. | strings] | unique) as $strings
  | ($files["helmfile.yaml"].releases.envoyGateway.enabled) as $manifests
  | [mirror_list($bom; null)[]
      | select(
          if .type == "oci" then .digest as $d | any($digests[]; . == $d)
          elif .type == "git" then .target as $t | any($strings[]; . == $t)
          else $manifests end)];
