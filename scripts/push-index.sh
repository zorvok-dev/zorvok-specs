#!/usr/bin/env bash
# Regenerates all_pods.txt / all_pods_versions.txt on the latest <branch>
# and pushes them, retrying from a fresh fetch when another merge lands
# first. Both workflows that merge into this registry use it —
# publish.yml (for the pull requests it merges itself) and
# regenerate-index.yml (for ones a maintainer merges) — and they can run
# at the same time.
#
# Usage: push-index.sh <branch> [repo-root]  (repo-root defaults to this
# script's own repo, one level up from scripts/)

set -euo pipefail

BRANCH="${1:?usage: push-index.sh <branch> [repo-root]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${2:-$(cd "$SCRIPT_DIR/.." && pwd)}"

cd "$ROOT"
for attempt in 1 2 3 4 5; do
  git fetch -q --no-tags origin "$BRANCH"
  git checkout -q -B "$BRANCH" "origin/$BRANCH"
  "$SCRIPT_DIR/generate-index.sh" "$ROOT"

  if git diff --quiet -- all_pods.txt all_pods_versions.txt; then
    echo "Index files are up to date"
    exit 0
  fi
  git add all_pods.txt all_pods_versions.txt
  git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -q -m "Regenerate index files"
  if git push -q origin "$BRANCH"; then
    echo "Regenerated and pushed the index files"
    exit 0
  fi
  sleep $((attempt * 3))
done

echo "Couldn't push the regenerated index files after 5 attempts" >&2
exit 1
