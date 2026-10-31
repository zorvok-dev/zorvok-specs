#!/usr/bin/env bash
# Validates a pull request against this repo's publishing rules
# (zorvok ADR 0009): since there's no server here, this script is what
# stands in for registry-server/packages's database constraints and
# auth checks. It is the enforcement mechanism for:
#
#   1. Immutability — a PR may only ADD files under Specs/<name>/<version>/,
#      never modify or delete one. Same rule as registry-server's
#      ErrVersionExists, enforced here by diffing git history instead of
#      a unique constraint.
#   2. Structural validation — an added podspec.json must be valid JSON
#      whose "name"/"version" fields match the path it's added at. Same
#      check as registry-server/api's validatePodspec. Never evaluated
#      as Ruby or executed (brief §9) — this script only ever reads and
#      diffs file contents.
#   3. Ownership — a Specs/<name>/OWNERS file (one identity per line)
#      must exist before a version can be added under that name. A PR
#      adding a brand-new pod must create OWNERS itself (first-publisher-
#      wins, same rule as registry-server/packages.GetOrCreate). A PR
#      adding a version to an EXISTING pod must be authored by an
#      identity already listed in OWNERS as it existed before this PR
#      (checked against $BASE_REF, not the PR's own changes, so a PR
#      can't add itself to OWNERS and publish in the same PR for a pod
#      it doesn't already own).
#
# Usage: validate-pr.sh <base-ref> <head-ref> <actor>
#   actor is the identity to check against OWNERS files — the GitHub
#   Actions workflow passes $GITHUB_ACTOR; for local testing, pass any
#   string that matches what your test OWNERS files contain.
#
# Exits non-zero (with every problem listed, not just the first) if any
# rule is violated.

set -euo pipefail

BASE_REF="${1:?usage: validate-pr.sh <base-ref> <head-ref> <actor>}"
HEAD_REF="${2:?usage: validate-pr.sh <base-ref> <head-ref> <actor>}"
ACTOR="${3:?usage: validate-pr.sh <base-ref> <head-ref> <actor>}"

errors=()

# --- 1. Immutability: no M or D under Specs/<name>/<version>/ ---
while IFS=$'\t' read -r status path; do
  [ -z "$path" ] && continue
  if [[ "$path" =~ ^Specs/[^/]+/[^/]+/.+$ ]]; then
    case "$status" in
      M|D)
        errors+=("immutability: $path was $status — a published version's files can never be changed or removed")
        ;;
    esac
  fi
done < <(git diff --name-status "$BASE_REF" "$HEAD_REF" -- Specs/)

# --- 2 & 3: for each added podspec, validate structure + ownership ---
while IFS=$'\t' read -r status path; do
  [ -z "$path" ] && continue
  [ "$status" != "A" ] && continue

  # Only care about Specs/<name>/<version>/<name>.podspec.json
  if [[ "$path" =~ ^Specs/([^/]+)/([^/]+)/([^/]+)\.podspec\.json$ ]]; then
    name="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
    filename="${BASH_REMATCH[3]}"

    if [ "$filename" != "$name" ]; then
      errors+=("structure: $path — filename must be <name>.podspec.json matching its own directory name")
      continue
    fi

    content="$(git show "$HEAD_REF:$path" 2>/dev/null || true)"
    if ! echo "$content" | jq -e . >/dev/null 2>&1; then
      errors+=("structure: $path is not valid JSON")
      continue
    fi

    spec_name="$(echo "$content" | jq -r '.name // empty')"
    spec_version="$(echo "$content" | jq -r '.version // empty')"
    if [ "$spec_name" != "$name" ]; then
      errors+=("structure: $path — podspec \"name\" ($spec_name) does not match its path ($name)")
    fi
    if [ "$spec_version" != "$version" ]; then
      errors+=("structure: $path — podspec \"version\" ($spec_version) does not match its path ($version)")
    fi

    # Ownership: does OWNERS already exist in the BASE ref (pre-PR)?
    owners_path="Specs/$name/OWNERS"
    if git show "$BASE_REF:$owners_path" >/dev/null 2>&1; then
      base_owners="$(git show "$BASE_REF:$owners_path")"
      if ! grep -qxF "$ACTOR" <<<"$base_owners"; then
        errors+=("ownership: $path — $ACTOR is not listed in $owners_path (as it existed before this PR); an existing pod's versions can only be published by its listed owners")
      fi
    else
      # Brand-new pod: this PR must itself add OWNERS for it.
      head_status="$(git diff --name-status "$BASE_REF" "$HEAD_REF" -- "$owners_path" | cut -f1)"
      if [ "$head_status" != "A" ]; then
        errors+=("ownership: $path — new pod \"$name\" has no $owners_path; this PR must add one, listing $ACTOR, to establish ownership")
      else
        head_owners="$(git show "$HEAD_REF:$owners_path")"
        if ! grep -qxF "$ACTOR" <<<"$head_owners"; then
          errors+=("ownership: $owners_path does not list $ACTOR — the PR author must be listed as an owner of a pod they're newly publishing")
        fi
      fi
    fi
  fi
done < <(git diff --name-status "$BASE_REF" "$HEAD_REF" -- Specs/)

if [ "${#errors[@]}" -gt 0 ]; then
  echo "This PR violates the specs repo's publishing rules:" >&2
  for e in "${errors[@]}"; do
    echo "  - $e" >&2
  done
  exit 1
fi

echo "OK: no violations found"
