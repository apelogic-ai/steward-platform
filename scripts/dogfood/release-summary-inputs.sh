#!/usr/bin/env bash
# Collect the input artifact for the release-summary dogfood task (see docs/dogfooding.md).
#
# Usage: scripts/dogfood/release-summary-inputs.sh <platform-release-tag> <output-dir>
#
# Writes, under <output-dir>:
#   request.json                the tag, the previous release tag and the changed products
#   bom.json                    bom/bom.json at the tag
#   bom-previous.json           bom/bom.json at the previous release (absent for the first release)
#   platform-release-notes.md   docs/releases/<tag>.md at the tag (absent if the tag has none)
#   products/<name>.json        GitHub release metadata and notes of each product whose pin changed
#
# Needs git (with tags fetched), gh (GH_TOKEN) and jq. Reads public release data only.
set -euo pipefail

tag=${1:?usage: release-summary-inputs.sh <tag> <output-dir>}
out=${2:?usage: release-summary-inputs.sh <tag> <output-dir>}
repo=${GITHUB_REPOSITORY:-apelogic-ai/steward-platform}
max_notes_chars=20000

if [[ ! $tag =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$ ]]; then
  echo "not a platform release tag: $tag" >&2
  exit 1
fi
git rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null || {
  echo "tag not found locally (fetch tags first): $tag" >&2
  exit 1
}

created=$(gh release view "$tag" -R "$repo" --json createdAt --jq .createdAt)
previous=$(gh release list -R "$repo" -L 100 --exclude-drafts --json tagName,createdAt |
  jq -r --arg c "$created" '[.[] | select(.createdAt < $c)] | sort_by(.createdAt) | last | .tagName // empty')

mkdir -p "$out/products"
git show "$tag:bom/bom.json" >"$out/bom.json"
if [[ -n $previous ]]; then
  git show "$previous:bom/bom.json" >"$out/bom-previous.json"
fi
if git cat-file -e "$tag:docs/releases/$tag.md" 2>/dev/null; then
  git show "$tag:docs/releases/$tag.md" >"$out/platform-release-notes.md"
fi

# Products whose pinned version differs from the previous release (all products for the first release).
if [[ -f $out/bom-previous.json ]]; then
  changed=$(jq -r --slurpfile prev "$out/bom-previous.json" '
    .products | to_entries[]
    | select(.value.version != ($prev[0].products[.key].version // null)) | .key' "$out/bom.json")
else
  changed=$(jq -r '.products | keys[]' "$out/bom.json")
fi

for name in $changed; do
  url=$(jq -r --arg n "$name" '.products[$n].release' "$out/bom.json")
  if [[ ! $url =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/releases/tag/([A-Za-z0-9_.+-]+)$ ]]; then
    echo "unexpected release URL for $name: $url" >&2
    exit 1
  fi
  gh release view "${BASH_REMATCH[2]}" -R "${BASH_REMATCH[1]}" --json tagName,name,url,publishedAt,body |
    jq --argjson max "$max_notes_chars" '
      .truncated = ((.body | length) > $max) | .body = .body[0:$max]' >"$out/products/$name.json"
done

jq -n --arg tag "$tag" --arg previous "$previous" --arg repo "$repo" --arg changed "$changed" '{
  repository: $repo,
  tag: $tag,
  previousTag: (if $previous == "" then null else $previous end),
  changedProducts: ($changed | split("\n") | map(select(. != "")))
}' >"$out/request.json"
