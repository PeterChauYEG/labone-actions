#!/usr/bin/env bash
# Installs (or reads a cached bundle of) node_modules for the "Read bundle
# (cache hit) or install" step in action.yml - see that file's top-level
# `description` for the full content-addressed-bundle design.
#
# Extracted out of action.yml's inline `run:` block so it can be unit
# tested (see install.test.sh) and so `set -o pipefail` failures aren't
# silently absorbed by GitHub Actions' YAML multi-line string handling.
#
# Expects these env vars (set by action.yml):
#   BUNDLE       - absolute path to this lockfile hash's bundle directory
#   REL_PATHS    - newline-separated paths (relative to cwd) to symlink
#                  from the bundle, e.g. "node_modules\n.next/cache"
#   CACHE_WRITE  - 'true' or 'false' (string)
set -euo pipefail

# Symlinks each top-level entry of a bundle's node_modules into this job's
# own node_modules - cheap (one symlink per top-level package/scope) rather
# than walking the whole tree.
#
# For scoped packages (@scope/pkg), this means node_modules/@scope ends up
# as a SINGLE symlink pointing at the bundle's node_modules/@scope - not a
# real local directory. Anything that later writes underneath that path
# (e.g. relink_workspaces) will transparently write straight into the
# shared, supposedly-immutable bundle unless it detaches that symlink into
# a real directory first - see detach_shared_dir_if_symlink below.
link_node_modules_shallow() {
  local bundle_nm="$1"
  mkdir -p node_modules
  shopt -s dotglob nullglob
  local entry
  for entry in "$bundle_nm"/*; do
    ln -sfn "$entry" "node_modules/$(basename "$entry")"
  done
  shopt -u dotglob nullglob
}

# If $path is a symlink (e.g. node_modules/@scope, shallow-linked straight
# into the shared bundle), replace it with a real local directory
# containing symlinks to the same entries, so that a caller can safely
# rm -rf/create paths *underneath* it without mutating the bundle itself.
# No-op if $path is already a real directory or doesn't exist.
detach_shared_dir_if_symlink() {
  local path="$1"
  [[ -L "$path" ]] || return 0

  local target
  target="$(readlink -f "$path")"
  rm -f "$path"
  mkdir -p "$path"
  if [[ -d "$target" ]]; then
    shopt -s dotglob nullglob
    local entry
    for entry in "$target"/*; do
      ln -sfn "$entry" "$path/$(basename "$entry")"
    done
    shopt -u dotglob nullglob
  fi
}

# Emits "<name>\t<location>" for every workspace package, by reading the
# root package.json's `workspaces` glob array directly and matching it
# against each candidate directory's own package.json `name` field.
#
# Deliberately does NOT shell out to `yarn workspaces list --json`: yarn
# itself is being asked to resolve this from a node_modules tree that may
# still contain dangling/bundle-relative symlinks at this point in
# link_bundle (relink_workspaces runs precisely because node_modules is in
# that partially-valid state) - this sidesteps that chicken/egg entirely by
# only ever touching package.json files.
discover_workspaces() {
  jq -e '.workspaces' package.json >/dev/null 2>&1 || return 0

  local patterns
  patterns="$(jq -r '
    (if (.workspaces | type) == "array" then .workspaces
     else (.workspaces.packages // []) end)[]
  ' package.json)"
  [[ -z "$patterns" ]] && return 0

  local -a include=() exclude=()
  local pat
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    if [[ "$pat" == '!'* ]]; then
      exclude+=("${pat#!}")
    else
      include+=("$pat")
    fi
  done <<< "$patterns"

  shopt -s nullglob
  local dir ex skip name
  for pat in "${include[@]}"; do
    for dir in $pat; do
      [[ -f "$dir/package.json" ]] || continue

      skip=false
      for ex in "${exclude[@]:-}"; do
        [[ -z "$ex" ]] && continue
        [[ "$dir" == $ex ]] && { skip=true; break; }
      done
      [[ "$skip" == true ]] && continue

      name="$(jq -r '.name // empty' "$dir/package.json")"
      [[ -z "$name" ]] && continue
      printf '%s\t%s\n' "$name" "$dir"
    done
  done
  shopt -u nullglob
}

# Re-points each workspace package's node_modules entry at THIS job's own
# checkout, since the bundle's copy of that symlink (written by whichever
# job originally built the bundle) is only ever valid in that job's own
# now-deleted ephemeral checkout.
#
# Root cause confirmed by repro (see install.test.sh): link_node_modules_shallow
# symlinks node_modules/@scope straight into the bundle (a single symlink,
# not a real directory - scoped packages live inside it). Before this fix,
# this function's rm -rf/ln -sfn calls on "node_modules/@scope/pkg" walked
# straight through that symlink and mutated the files *inside the shared
# bundle itself* - so the "last job to run relink_workspaces" would
# overwrite the bundle's workspace symlinks with ITS OWN ephemeral
# checkout's path, which every other job then inherited as a dangling
# symlink once that checkout was deleted. That's the actual TS2307 flake
# mechanism - not a yarn-workspaces-list resolution failure.
relink_workspaces() {
  jq -e '.workspaces' package.json >/dev/null 2>&1 || return 0

  local abs_wd
  abs_wd="$(pwd)"

  local entries
  entries="$(discover_workspaces)"
  [[ -z "$entries" ]] && return 0

  local name loc scope
  while IFS=$'\t' read -r name loc; do
    [[ -z "$name" ]] && continue

    scope="node_modules/${name%%/*}"
    if [[ "$scope" != "node_modules/$name" ]]; then
      detach_shared_dir_if_symlink "$scope"
    fi

    rm -rf "node_modules/$name"
    mkdir -p "$(dirname "node_modules/$name")"
    ln -sfn "$abs_wd/$loc" "node_modules/$name"
  done <<< "$entries"
}

link_bundle() {
  local bundle="$1"
  touch "$bundle/.last-used"
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if [[ "$rel" == "node_modules" ]]; then
      link_node_modules_shallow "$bundle/node_modules"
      continue
    fi
    mkdir -p "$(dirname "$rel")" "$bundle/$rel"
    ln -sfn "$bundle/$rel" "$rel"
  done <<< "$REL_PATHS"
  relink_workspaces
}

install_with_retry() {
  local attempt=1 max_attempts=3
  while true; do
    if yarn install --frozen-lockfile; then
      return 0
    fi
    if (( attempt >= max_attempts )); then
      echo "[setup-node-yarn] yarn install failed after ${max_attempts} attempts - not retrying further" >&2
      return 1
    fi
    echo "[setup-node-yarn] yarn install failed (attempt ${attempt}/${max_attempts}) - wiping node_modules and retrying"
    rm -rf node_modules
    attempt=$(( attempt + 1 ))
  done
}

main() {
  mkdir -p "$(dirname "$YARN_CACHE_FOLDER")" "$YARN_CACHE_FOLDER"

  if [[ -f "$BUNDLE/.complete" ]]; then
    echo "[setup-node-yarn] bundle hit: $BUNDLE - symlinking, no install"
    link_bundle "$BUNDLE"
    return 0
  fi

  if [[ "$CACHE_WRITE" == "true" ]]; then
    echo "[setup-node-yarn] cache-write run, bundle miss: $BUNDLE - installing into shared cache"
    local scratch
    scratch="${BUNDLE}.tmp-${RANDOM}-$$"
    mkdir -p "$scratch"
    while IFS= read -r rel; do
      [[ -z "$rel" || "$rel" == "node_modules" ]] && continue
      mkdir -p "$(dirname "$rel")" "$scratch/$rel"
      ln -sfn "$scratch/$rel" "$rel"
    done <<< "$REL_PATHS"
    install_with_retry
    mkdir -p "$(dirname "$scratch/node_modules")"
    rm -rf "$scratch/node_modules"
    mv node_modules "$scratch/node_modules"
    if [[ ! -d "$BUNDLE" ]]; then
      mv "$scratch" "$BUNDLE"
      touch "$BUNDLE/.complete"
    else
      rm -rf "$scratch"
    fi
    link_bundle "$BUNDLE"
    return 0
  fi

  echo "[setup-node-yarn] bundle miss on a non-cache-write run: $BUNDLE - installing locally, not shared"
  install_with_retry
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
