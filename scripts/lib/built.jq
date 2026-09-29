# Functions for the built-artifacts lock (schemas/built-lock/v1.schema.json):
# products an operator built from source and pushed to their own registry.
# Used by scripts/generate.sh (platform values artifacts.source built),
# scripts/verify-built-lock.sh and scripts/built-lock-from-digests.sh. See
# docs/fork-and-build.md.

# Products whose artifacts the platform never deploys: it projects their
# signed release coordinates into another product's configuration instead
# (steward-run into Steward's config.apiserver.stewardRunRelease, which
# Steward's contract requires to equal the signed BOM coordinates). A lock
# must not list them; they stay the BOM's, and scripts/verify-signatures.sh
# keeps verifying them.
def projected_products: ["steward-run"];

# The products a BOM profile deploys, whose artifacts a lock must cover.
def deployed_products($bom; $profile):
  ($bom.profiles[$profile].products // error("the BOM has no \($profile) profile"))
  - projected_products;

# The artifacts a BOM product pins, as lock paths relative to the product:
# "chart" and "images.<component>".
def pinned_artifacts:
  (if .chart != null then ["chart"] else [] end)
  + [(.images // {}) | keys[] | "images.\(.)"];

# registry/repository[:tag]@sha256:digest -> {repository, tag (or null), digest}
def lock_image_parts:
  capture("^(?<repository>[^@]+?)(:(?<tag>[^:@/]+))?@(?<digest>sha256:[a-f0-9]{64})$")
  // error("not a digest-pinned image reference: \(.)");

# Everything wrong with a lock (the input) against the BOM, as messages: for
# each product it lists, the version, the commit (unless allowSourceDrift),
# the chart version and every chart and image the BOM pins; and, when
# $profile is not null, every product that profile deploys. An empty list
# means the lock covers the install.
def built_lock_problems($bom; $profile):
  . as $lock
  | (if $profile == null then [] else deployed_products($bom; $profile) end) as $required
  | [
      # Products the profile deploys that the lock does not list: every
      # artifact of each is missing.
      ($required[] as $name | select($lock.products[$name] == null)
        | $bom.products[$name] | pinned_artifacts[]
        | "products.\($name).\(.) is missing (the \($profile) profile deploys \($name))"),
      ($lock.products | to_entries[] | .key as $name | .value as $built | $bom.products[$name] as $pinned
        | if $pinned == null then
            "products.\($name) is not a product of the BOM"
          elif (projected_products | index($name)) then
            "products.\($name): the platform does not deploy \($name)'s artifacts; it projects its signed release coordinates from the BOM, so a lock must not list it"
          else
            (select($built.version != $pinned.version)
              | "products.\($name).version is \($built.version); the BOM pins \($pinned.version)"),
            (select($built.commit != $pinned.commit and ($built.allowSourceDrift // false | not))
              | "products.\($name).commit is \($built.commit), not the BOM commit \($pinned.commit) of \($pinned.source) (\($pinned.release // "its release")); build from that commit, or set allowSourceDrift"),
            ($pinned | pinned_artifacts[] as $artifact
              | select(($built | getpath($artifact | split("."))) == null)
              | "products.\($name).\($artifact) is missing"),
            (($built.images // {}) | keys[] | select(($pinned.images // {})[.] == null)
              | "products.\($name).images.\(.) is not an image the BOM pins for \($name)"),
            (select($built.chart != null and $pinned.chart == null)
              | "products.\($name).chart: the BOM pins no chart for \($name)"),
            (select($built.chart != null and $pinned.chart != null and $built.chart.version != $pinned.chart.version)
              | "products.\($name).chart.version is \($built.chart.version); the BOM pins \($pinned.chart.version) (the chart version, not the application version)")
          end),
      # Steward's chart takes one images.repository for all its images.
      ($lock.products.steward // empty | .images // {}
        | [.apiserver, .controller, .web | select(. != null) | lock_image_parts.repository] | unique
        | select(length > 1)
        | "products.steward.images: apiserver, controller and web must share one repository (Steward's chart takes one images.repository); the lock names \(join(", "))")
    ];

# Products the lock builds from a commit other than the BOM's
# (allowSourceDrift), as warnings.
def built_lock_drift($bom):
  [.products | to_entries[] | .key as $name | .value as $built | $bom.products[$name] as $pinned
    | select($pinned != null and $built.commit != $pinned.commit)
    | "products.\($name) is built from \($built.source) at \($built.commit), not the BOM's \($pinned.source) at \($pinned.commit) (allowSourceDrift): it is not the tested release"];

# The BOM (the input) with each product the lock lists taking the lock's chart
# and images. An image without a tag keeps the BOM's tag; the digest is the
# lock's. Everything else, including versions, commits, signatures, the
# projected products and the dependencies, stays the BOM's, so the generator
# renders the same install from the operator's artifacts.
def apply_built_lock($lock):
  reduce ($lock.products | to_entries[]) as $entry (.;
    if .products[$entry.key] == null or (projected_products | index($entry.key)) then .
    else
      .products[$entry.key] |= (
        (if $entry.value.chart != null then .chart = $entry.value.chart else . end)
        | .images as $pinned
        | .images = (($pinned // {}) + (($entry.value.images // {}) | with_entries(
            (.value | lock_image_parts) as $built
            | .value = "\($built.repository):\($built.tag // ($pinned[.key] | capture(":(?<tag>[^:@/]+)@").tag))@\($built.digest)")))
      )
    end);

# Every artifact of the lock (the input), one per line for the shell:
# kind <TAB> label <TAB> repository <TAB> tag (or "-") <TAB> digest.
def built_lock_artifacts:
  .products | to_entries[] | .key as $name | .value
  | (.chart // empty
      | ["chart", "products.\($name).chart", (.reference | ltrimstr("oci://")), .version, .digest]),
    ((.images // {}) | to_entries[] | .key as $component | .value | lock_image_parts
      | ["image", "products.\($name).images.\($component)", .repository, (.tag // "-"), .digest])
  | @tsv;
