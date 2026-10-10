#!/usr/bin/env bash
# Publishes the chart of every product release that is not in the Helm
# repository yet. Run by .github/workflows/publish.yml; runnable by hand.
#
#   scripts/publish.sh            publish everything that is missing
#   scripts/publish.sh verify     check what the last run published
#
# For each product in products.yaml it lists the source repository's
# published releases (no drafts, no prereleases). Every tag that matches the
# product's `tags` glob, is not older than `since`, is not in `skip` and has
# no chart in index.yaml yet is published, oldest first:
#
#   1. clone the tag (depth 1), check the chart, `helm lint` it
#   2. `helm package`, `helm push` to the OCI registry
#   3. `helm repo index --merge` into the gh-pages index, commit, push
#
# The OCI push comes before the index. A run that dies between the two leaves
# the release out of index.yaml, so the next run publishes it again; the
# other order would leave an index entry with no OCI copy that no run retries.
#
# A chart version is published once. A release whose chart reuses a version
# already in the index with a different appVersion is refused: Helm caches
# charts by version, so two contents under one number make `helm upgrade`
# unpredictable. The source repository has to bump its chart version.
#
# Each product and each release runs in its own process, so one failure does
# not stop the others; the run still exits non-zero when anything failed.
#
# Environment:
#   PAGES_DIR       gh-pages worktree (default: ./pages, created if missing)
#   REPO_URL        public URL of the Helm repository (default: https://helm.brf.sh)
#   OCI_REPO        OCI registry path (default: oci://ghcr.io/brf-tech/charts)
#   DRY_RUN=1       package and index locally, push nothing
#   PUBLISHED_LIST  file that receives "name version tag new|known" per release
#   GH_TOKEN        token for the GitHub API (read access is enough)
#
# Needs: bash, git, gh, helm, yq (v4), jq, curl.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SELF="$ROOT/scripts/publish.sh"

export PAGES_DIR=${PAGES_DIR:-$ROOT/pages}
export REPO_URL=${REPO_URL:-https://helm.brf.sh}
export OCI_REPO=${OCI_REPO:-oci://ghcr.io/brf-tech/charts}
export DRY_RUN=${DRY_RUN:-}
export PUBLISHED_LIST=${PUBLISHED_LIST:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/helm-charts-published.txt}

INDEX="$PAGES_DIR/index.yaml"

log() { printf '%s\n' "$*" >&2; }
error() { printf '::error::%s\n' "$*" >&2; }
warning() { printf '::warning::%s\n' "$*" >&2; }
notice() { printf '::notice::%s\n' "$*" >&2; }

field() { jq -r --arg k "$2" '.[$k] // empty' <<<"$1"; }

strip_v() { printf '%s' "${1#v}"; }

# not_older A B: true when version A >= version B (B empty: always true).
not_older() {
  [ -z "$2" ] && return 0
  local a b
  a=$(strip_v "$1")
  b=$(strip_v "$2")
  [ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -n 1)" = "$b" ]
}

index_query() {
  [ -f "$INDEX" ] || return 0
  NAME="$1" VER="${2:-}" yq -r "$3" "$INDEX"
}

push_pages() {
  if [ -n "$DRY_RUN" ]; then
    log "dry run: gh-pages not pushed"
  else
    git -C "$PAGES_DIR" push --quiet origin HEAD:refs/heads/gh-pages
  fi
}

setup_pages() {
  if [ ! -d "$PAGES_DIR" ]; then
    if git -C "$ROOT" ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
      git -C "$ROOT" fetch --quiet --depth 1 origin +refs/heads/gh-pages:refs/remotes/origin/gh-pages
      git -C "$ROOT" worktree add --quiet -B gh-pages "$PAGES_DIR" origin/gh-pages
    else
      log "gh-pages does not exist yet: starting it"
      git -C "$ROOT" worktree add --quiet --orphan -b gh-pages "$PAGES_DIR"
    fi
  fi

  local message=""
  if [ ! -f "$INDEX" ]; then
    helm repo index "$PAGES_DIR" --url "$REPO_URL"
    message="initialize the Helm repository"
  fi
  if ! cmp -s "$ROOT/site/index.html" "$PAGES_DIR/index.html"; then
    cp "$ROOT/site/index.html" "$PAGES_DIR/index.html"
    message=${message:-update the landing page}
  fi
  if [ -n "$message" ]; then
    git -C "$PAGES_DIR" add -- index.yaml index.html
    git -C "$PAGES_DIR" commit --quiet -m "$message"
    push_pages
  fi
}

# pending PRODUCT_JSON: print the tags still to publish, oldest first.
cmd_pending() {
  local product=$1 name source pattern since tag
  name=$(field "$product" name)
  source=$(field "$product" source)
  pattern=$(field "$product" tags)
  pattern=${pattern:-v*}
  since=$(field "$product" since)
  [ -n "$name" ] && [ -n "$source" ] || { error "products.yaml: an entry has no name or source"; return 1; }

  # Command substitutions, not process substitutions: a failing gh or yq
  # must fail this step instead of reading as "no releases".
  local raw
  local -a skip known tags
  raw=$(jq -r '.skip // [] | .[]' <<<"$product")
  mapfile -t skip <<<"$raw"
  raw=$(index_query "$name" "" '(.entries[strenv(NAME)] // [])[] | .appVersion')
  mapfile -t known <<<"$raw"
  raw=$(gh api --paginate "repos/$source/releases?per_page=100" \
    --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name')
  mapfile -t tags <<<"$raw"

  local out=() s k hit
  for tag in "${tags[@]}"; do
    [ -n "$tag" ] || continue
    # shellcheck disable=SC2053
    [[ $tag == $pattern ]] || continue
    not_older "$tag" "$since" || continue
    hit=""
    for s in "${skip[@]}"; do [ "$s" = "$tag" ] && hit=1; done
    for k in "${known[@]}"; do
      { [ "$k" = "$tag" ] || [ "$k" = "$(strip_v "$tag")" ]; } && hit=1
    done
    [ -z "$hit" ] && out+=("$tag")
  done
  [ ${#out[@]} -eq 0 ] || printf '%s\n' "${out[@]}" | sort -V
}

# release PRODUCT_JSON TAG: publish one release's chart.
cmd_release() {
  local product=$1 tag=$2 name source chart
  name=$(field "$product" name)
  source=$(field "$product" source)
  chart=$(field "$product" chart)

  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  local work=$WORK

  log "== $name $tag: cloning $source"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" \
    "https://github.com/$source.git" "$work/src"
  local dir="$work/src/$chart"
  [ -f "$dir/Chart.yaml" ] || { error "$name $tag: no chart at $chart"; return 1; }

  local c_name c_ver c_app
  c_name=$(yq -r '.name' "$dir/Chart.yaml")
  c_ver=$(yq -r '.version' "$dir/Chart.yaml")
  c_app=$(yq -r '.appVersion // ""' "$dir/Chart.yaml")
  [ "$c_name" = "$name" ] || { error "$name $tag: the chart is named '$c_name', products.yaml says '$name'"; return 1; }

  local before existing
  before=$(index_query "$name" "" '(.entries[strenv(NAME)] // []) | length')
  existing=$(index_query "$name" "$c_ver" '(.entries[strenv(NAME)] // [])[] | select(.version == strenv(VER)) | .appVersion')
  if [ -n "$existing" ]; then
    if [ "$existing" = "$c_app" ]; then
      log "$name $tag: chart $c_ver is already published"
      return 0
    fi
    error "$name $tag: chart version $c_ver is already published for appVersion $existing; this release's chart says $c_app. Bump the chart version in $source, or add $tag to skip in products.yaml."
    return 1
  fi
  if [ "$c_app" != "$tag" ] && [ "$c_app" != "$(strip_v "$tag")" ]; then
    warning "$name $tag: the chart's appVersion is '$c_app', not the release tag"
  fi

  helm lint "$dir"
  mkdir -p "$work/pkg"
  helm package "$dir" --destination "$work/pkg" >/dev/null
  local file="$name-$c_ver.tgz"
  [ -f "$work/pkg/$file" ] || { error "$name $tag: helm package did not produce $file"; return 1; }

  if [ -n "$DRY_RUN" ]; then
    log "dry run: not pushing $file to $OCI_REPO"
  else
    helm push "$work/pkg/$file" "$OCI_REPO"
  fi

  if [ -f "$INDEX" ]; then
    helm repo index "$work/pkg" --url "$REPO_URL" --merge "$INDEX"
  else
    helm repo index "$work/pkg" --url "$REPO_URL"
  fi
  local url
  url=$(NAME="$name" VER="$c_ver" yq -r '.entries[strenv(NAME)][] | select(.version == strenv(VER)) | .urls[0]' "$work/pkg/index.yaml")
  [ "$url" = "$REPO_URL/$file" ] || { error "$name $tag: the index points at '$url', expected $REPO_URL/$file"; return 1; }

  cp "$work/pkg/$file" "$PAGES_DIR/$file"
  cp "$work/pkg/index.yaml" "$INDEX"
  git -C "$PAGES_DIR" add -- "$file" index.yaml
  git -C "$PAGES_DIR" commit --quiet -m "publish $name $c_ver (app $tag)"
  push_pages

  local state=known
  [ "${before:-0}" = "0" ] && state=new
  printf '%s %s %s %s\n' "$name" "$c_ver" "$tag" "$state" >> "$PUBLISHED_LIST"
  log "$name $tag: published chart $c_ver"
}

cmd_publish() {
  : > "$PUBLISHED_LIST"
  local status=0
  write_outputs() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      printf 'count=%s\n' "$(grep -c . "$PUBLISHED_LIST" || true)" >> "$GITHUB_OUTPUT"
    fi
  }
  trap write_outputs EXIT

  setup_pages

  local raw
  local -a products=()
  raw=$(yq -o=json -I=0 '.products[]' "$ROOT/products.yaml")
  [ -z "$raw" ] || mapfile -t products <<<"$raw"
  [ ${#products[@]} -gt 0 ] || { error "products.yaml lists no products"; return 1; }

  local product name tags tag
  for product in "${products[@]}"; do
    name=$(field "$product" name)
    if ! tags=$(bash "$SELF" pending "$product"); then
      error "$name: could not work out which releases to publish"
      status=1
      continue
    fi
    if [ -z "$tags" ]; then
      log "$name: nothing new"
      continue
    fi
    while IFS= read -r tag; do
      if ! bash "$SELF" release "$product" "$tag"; then
        error "$name $tag: not published"
        status=1
      fi
    done <<<"$tags"
  done
  return "$status"
}

# verify: check every release the last run published, the way a user would
# reach it - the index at the commit just pushed, the package next to it, and
# an anonymous pull from the OCI registry.
cmd_verify() {
  [ -s "$PUBLISHED_LIST" ] || { log "nothing was published"; return 0; }
  local status=0
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  local tmp=$TMP
  export HELM_REPOSITORY_CONFIG="$tmp/repositories.yaml"
  export HELM_REPOSITORY_CACHE="$tmp/cache"
  export HELM_REGISTRY_CONFIG="$tmp/registry.json"

  local sha raw
  sha=$(git -C "$PAGES_DIR" rev-parse HEAD)
  raw="https://raw.githubusercontent.com/${GITHUB_REPOSITORY:-BRF-Tech/helm-charts}/$sha"
  helm repo add verify "$raw" >/dev/null

  local live=""
  if curl -fsS --max-time 20 "$REPO_URL/index.yaml" -o "$tmp/live.yaml" 2>/dev/null; then
    live="$tmp/live.yaml"
  else
    notice "$REPO_URL/index.yaml is not reachable yet; checked the gh-pages copy only"
  fi

  local name ver tag state
  while read -r name ver tag state; do
    if helm search repo "verify/$name" --version "$ver" -o json | jq -e 'length == 1' >/dev/null; then
      log "ok   index: $name $ver ($tag)"
    else
      error "verify: the gh-pages index has no $name $ver"
      status=1
    fi
    if curl -fsSI --max-time 20 "$raw/$name-$ver.tgz" >/dev/null; then
      log "ok   package: $name-$ver.tgz on gh-pages"
    else
      error "verify: $name-$ver.tgz is not on gh-pages"
      status=1
    fi
    if helm pull "$OCI_REPO/$name" --version "$ver" --destination "$tmp/oci" >/dev/null 2>&1; then
      log "ok   oci: $OCI_REPO/$name:$ver (anonymous pull)"
    elif [ "$state" = new ]; then
      warning "verify: $OCI_REPO/$name:$ver cannot be pulled anonymously. This is the product's first chart: make the ghcr package public (README, 'Adding a product')."
    else
      error "verify: $OCI_REPO/$name:$ver cannot be pulled anonymously"
      status=1
    fi
    if [ -n "$live" ]; then
      if NAME="$name" VER="$ver" yq -e '.entries[strenv(NAME)][] | select(.version == strenv(VER))' "$live" >/dev/null 2>&1; then
        log "ok   $REPO_URL lists $name $ver"
      else
        notice "$REPO_URL does not list $name $ver yet (the site follows gh-pages on its own schedule)"
      fi
    fi
  done < "$PUBLISHED_LIST"
  return "$status"
}

case "${1:-publish}" in
  publish) cmd_publish ;;
  pending) cmd_pending "$2" ;;
  release) cmd_release "$2" "$3" ;;
  verify) cmd_verify ;;
  *) error "usage: $0 [publish|verify]"; exit 2 ;;
esac
