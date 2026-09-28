# Pure functions that turn platform values and the BOM into chart values and
# helmfile inputs. Used by scripts/generate.sh; see that script for inputs.
#
# Every chart key set here is documented by the chart that owns it. The
# Steward keys come from its v0.3.1 chart:
# https://github.com/apelogic-ai/steward/blob/v0.3.1/charts/steward/values.yaml

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

# --- Derived settings --------------------------------------------------------

def uses_cert_manager: .tls.mode == "certManager";
def installs_cert_manager: uses_cert_manager and .tls.certManager.install;
def uses_evaluation_issuer: uses_cert_manager and .tls.certManager.issuer.source == "evaluation";
def uses_evaluation_database: .database.source == "evaluation";

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
        apiserver: {kubernetesTokenReviewAudience: $v.cluster.serviceAccountTokenAudience}
      },
      networkPolicy: {
        enabled: true,
        dnsNamespace: $v.cluster.dnsNamespace,
        kubeApiCidrs: $v.cluster.kubeApi.cidrs,
        postgresCidrs: $v.database.cidrs,
        apiserverIngressNamespaces: ($v.networkPolicy.apiserverIngressNamespaces // []),
        ports: {kubernetesApi: $v.cluster.kubeApi.port, postgres: $v.database.port}
      },
      services: {clusterDomain: $v.cluster.domain}
    };

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
      namespaces: {steward: $v.namespaces.steward, certManager: $v.namespaces.certManager},
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
          version: $bom.products.steward.chart.version
        }
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
def flux_supported: (uses_evaluation_issuer or uses_evaluation_database) | not;

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
  + (if $v | flux_supported then $v | flux_files($bom; $ca_bundle) else {} end);
