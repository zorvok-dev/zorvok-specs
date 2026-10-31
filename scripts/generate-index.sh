#!/usr/bin/env bash
# Regenerates all_pods.txt and all_pods_versions.txt from the Specs/
# tree — the static equivalent of zorvok-registry/cdn computing the
# same files from the live store on every request (zorvok ADR 0006/0009).
# Run after every merge to main so the index files never drift from the
# actual podspec files on disk.
#
# Usage: generate-index.sh [repo-root]  (defaults to the script's own
# repo root, two levels up from scripts/)

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SPECS_DIR="$ROOT/Specs"

> "$ROOT/all_pods.txt"
> "$ROOT/all_pods_versions.txt"

[ -d "$SPECS_DIR" ] || exit 0

for pod_dir in "$SPECS_DIR"/*/; do
  [ -d "$pod_dir" ] || continue
  name="$(basename "$pod_dir")"

  versions=()
  for version_dir in "$pod_dir"*/; do
    [ -d "$version_dir" ] || continue
    version="$(basename "$version_dir")"
    # Skip anything that isn't an actual published version directory
    # (e.g. a stray non-version subdirectory) — a real version has its
    # own podspec file.
    [ -f "${version_dir}${name}.podspec.json" ] || continue
    versions+=("$version")
  done

  [ "${#versions[@]}" -eq 0 ] && continue

  echo "$name" >> "$ROOT/all_pods.txt"

  line="$name"
  for v in "${versions[@]}"; do
    line="$line/$v"
  done
  echo "$line" >> "$ROOT/all_pods_versions.txt"
done

sort -o "$ROOT/all_pods.txt" "$ROOT/all_pods.txt"
sort -o "$ROOT/all_pods_versions.txt" "$ROOT/all_pods_versions.txt"
