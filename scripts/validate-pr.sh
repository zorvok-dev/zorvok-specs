#!/usr/bin/env bash
# Validates a pull request against this repo's publishing rules
# (zorvok ADR 0009): since there's no server here, this script is what
# stands in for registry-server/packages's database constraints and
# auth checks. It is the enforcement mechanism for:
#
#   1. Immutability — a PR may only ADD files under Specs/<name>/<version>/,
#      never modify, delete or rename one. Same rule as registry-server's
#      ErrVersionExists, enforced here by diffing git history instead of
#      a unique constraint.
#   2. Structural validation — an added podspec.json must be valid JSON
#      whose "name"/"version" fields match the path it's added at, and
#      whose name and version use CocoaPods' characters. Same check as
#      registry-server/api's validatePodspec. Never evaluated as Ruby or
#      executed (brief §9) — this script only ever reads and diffs file
#      contents.
#   3. Ownership — a Specs/<name>/OWNERS file must exist before a version
#      can be added under that name. A PR adding a brand-new pod must
#      create OWNERS itself (first-publisher-wins, same rule as
#      registry-server/packages.GetOrCreate). A PR adding a version to an
#      EXISTING pod must be authored by an owner listed in OWNERS as it
#      exists in <base-ref> (not the PR's own changes, so a PR can't add
#      itself to OWNERS and publish in the same PR for a pod it doesn't
#      already own). The publish workflow passes the registry's CURRENT
#      tip as <base-ref>, never a commit the PR author chose.
#
# OWNERS lists one owner per line as "<GitHub user ID> <username>", for
# example "1019875 onevcat"; "#" starts a comment. Owners are matched by
# the numeric ID, which never changes hands, rather than by username,
# which can be renamed or freed and re-registered by someone else.
#
# Usage: validate-pr.sh <base-ref> <head-ref> <actor-user-id>
#   actor-user-id is the PR author's numeric GitHub user ID — the
#   workflow passes github.event.pull_request.user.id; for local testing,
#   pass whatever ID your test OWNERS files contain.
#
# Exits non-zero (with every problem listed, not just the first) if any
# rule is violated.

set -euo pipefail

BASE_REF="${1:?usage: validate-pr.sh <base-ref> <head-ref> <actor-user-id>}"
HEAD_REF="${2:?usage: validate-pr.sh <base-ref> <head-ref> <actor-user-id>}"
ACTOR_ID="${3:?usage: validate-pr.sh <base-ref> <head-ref> <actor-user-id>}"

NAME_RE='^[A-Za-z0-9][A-Za-z0-9_.+-]*$'
VERSION_RE='^[0-9A-Za-z][0-9A-Za-z.+-]*$'
OWNER_LINE_RE='^[0-9]+([[:space:]]+[A-Za-z0-9-]+)?[[:space:]]*$'

errors=()

# owner_ids <ref> <path>: the user IDs an OWNERS file lists, one per line.
owner_ids() {
  git show "$1:$2" | sed 's/#.*//' | awk 'NF { print $1 }'
}

# --- 1. Immutability: no M, D, R or T under Specs/<name>/<version>/ ---
while IFS=$'\t' read -r status path; do
  [ -z "$path" ] && continue
  if [[ "$path" =~ ^Specs/[^/]+/[^/]+/.+$ ]]; then
    case "$status" in
      A) ;;
      *) errors+=("immutability: $path was $status — a published version's files can never be changed or removed") ;;
    esac
  fi
done < <(git diff --no-renames --name-status "$BASE_REF" "$HEAD_REF" -- Specs/)

# --- OWNERS files this PR adds or edits must be well-formed ---
while IFS=$'\t' read -r status path; do
  [ -z "$path" ] && continue
  [[ "$path" =~ ^Specs/[^/]+/OWNERS$ ]] || continue
  [ "$status" = "D" ] && continue
  while IFS= read -r line; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if ! [[ "$line" =~ $OWNER_LINE_RE ]]; then
      errors+=("structure: $path has \"$line\"; each owner must be \"<GitHub user ID> <username>\". If you published with zorvok, update it (brew upgrade zorvok) and run zorvok trunk push again")
    fi
  done < <(git show "$HEAD_REF:$path")
done < <(git diff --no-renames --name-status "$BASE_REF" "$HEAD_REF" -- Specs/)

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
    if ! [[ "$name" =~ $NAME_RE ]]; then
      errors+=("structure: $path — a pod name may only use letters, digits and _ . + - and must start with a letter or digit")
      continue
    fi
    if ! [[ "$version" =~ $VERSION_RE ]]; then
      errors+=("structure: $path — a version may only use letters, digits and . + - and must start with a letter or digit")
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
      if ! grep -qxF "$ACTOR_ID" <<<"$(owner_ids "$BASE_REF" "$owners_path")"; then
        errors+=("ownership: $path — GitHub user $ACTOR_ID is not listed in $owners_path; an existing pod's versions can only be published by its listed owners")
      fi
    else
      # Brand-new pod: this PR must itself add OWNERS for it.
      head_status="$(git diff --no-renames --name-status "$BASE_REF" "$HEAD_REF" -- "$owners_path" | cut -f1)"
      if [ "$head_status" != "A" ]; then
        errors+=("ownership: $path — new pod \"$name\" has no $owners_path; this PR must add one, listing the publisher, to establish ownership")
      elif ! grep -qxF "$ACTOR_ID" <<<"$(owner_ids "$HEAD_REF" "$owners_path")"; then
        errors+=("ownership: $owners_path does not list GitHub user $ACTOR_ID — the PR author must be listed as an owner of a pod they're newly publishing")
      fi
    fi
  fi
done < <(git diff --no-renames --name-status "$BASE_REF" "$HEAD_REF" -- Specs/)

if [ "${#errors[@]}" -gt 0 ]; then
  echo "This PR violates the specs repo's publishing rules:" >&2
  for e in "${errors[@]}"; do
    echo "  - $e" >&2
  done
  exit 1
fi

echo "OK: no violations found"
