#!/usr/bin/env bash
# Build the input artifact for the repo-snapshot governed task (see docs/dogfooding.md).
#
# Usage: scripts/dogfood/repo-snapshot-inputs.sh <owner> <repo> <days> <max-items> <output-dir>
#
# Writes <output-dir>/inputs.json, a JSON object {"owner","repo","days","maxItems"} with
# days and maxItems as JSON numbers. The governed job downloads the artifact under in/, so
# the agent reads it as in/inputs.json.
#
# The target must be a public repository: this repository's Actions logs and artifacts are
# public. With GH_TOKEN set, the script checks that through the GitHub API; set
# SKIP_VISIBILITY_CHECK=1 to skip it for a local preview. Needs jq (and gh for the check).
set -euo pipefail

usage='usage: repo-snapshot-inputs.sh <owner> <repo> <days> <max-items> <output-dir>'
owner=${1?$usage}
repo=${2?$usage}
days=${3?$usage}
max_items=${4?$usage}
out=${5:?$usage}

fail() {
  echo "$1" >&2
  exit 1
}

# GitHub account names: alphanumerics and single inner hyphens, at most 39 characters.
[[ ${#owner} -le 39 && $owner =~ ^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]] ||
  fail "not a GitHub owner name: $owner"
[[ ${#repo} -le 100 && $repo =~ ^[A-Za-z0-9._-]+$ && $repo != . && $repo != .. ]] ||
  fail "not a GitHub repository name: $repo"
[[ $days =~ ^[1-9][0-9]?$ && $days -le 90 ]] || fail "days must be a whole number from 1 to 90: $days"
[[ $max_items =~ ^[1-9][0-9]?$ && $max_items -le 20 ]] ||
  fail "maxItems must be a whole number from 1 to 20: $max_items"

if [[ ${SKIP_VISIBILITY_CHECK:-} != 1 ]]; then
  private=$(gh api "repos/$owner/$repo" --jq .private) ||
    fail "cannot read $owner/$repo; the target must be an existing public repository"
  [[ $private == false ]] || fail "$owner/$repo is not public; the snapshot must only read public data"
fi

mkdir -p "$out"
jq -n --arg owner "$owner" --arg repo "$repo" --argjson days "$days" --argjson maxItems "$max_items" \
  '{owner: $owner, repo: $repo, days: $days, maxItems: $maxItems}' >"$out/inputs.json"
