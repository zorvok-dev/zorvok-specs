#!/usr/bin/env bash
# Decides, with no human in the loop, whether a pull request that already
# passed validate-pr.sh is published (merged) or rejected (zorvok ADR
# 0010). validate-pr.sh answers "does this break the registry's rules?";
# this covers the rest of what trunk.cocoapods.org decides. A pull request
# is published only if every change in it is one of:
#
#   - a new version: Specs/<name>/<version>/<name>.podspec.json added;
#   - a new pod's owners: Specs/<name>/OWNERS added alongside a version of
#     that pod (validate-pr.sh checks it lists the author);
#   - an owners change: an existing pod's OWNERS edited by one of its
#     current owners, leaving at least one (`pod trunk add-owner` /
#     `remove-owner`, as a pull request);
#
# and, on top of that:
#
#   - no podspec uses `prepare_command`, which runs shell commands on every
#     machine that installs the pod (CocoaPods trunk has rejected new
#     podspecs that use it since May 2025); and
#   - a pod that's new here but already on CocoaPods trunk is claimed by
#     someone verify-trunk-owner.sh shows controls its repository or site.
#
# validate-pr.sh's immutability rule covers version directories but not
# OWNERS, so the OWNERS rules above are what keep a pull request from
# taking over someone else's pod.
#
# Usage: publish-policy.sh <base-ref> <head-ref> <author>
#   Judges the pull request's own changes (base..head) as <author>'s.
#   verify-trunk-owner.sh's test overrides apply.
#
# Exits 0 to publish, or 1 with every reason it can't be, one per line,
# written for the publisher.

set -euo pipefail

BASE_REF="${1:?usage: publish-policy.sh <base-ref> <head-ref> <author>}"
HEAD_REF="${2:?usage: publish-policy.sh <base-ref> <head-ref> <author>}"
AUTHOR="${3:?usage: publish-policy.sh <base-ref> <head-ref> <author>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

reasons=()
versions=()    # "<name>/<version>" for each added podspec
new_owners=()  # pods whose OWNERS this pull request adds
owner_edits=() # pods whose existing OWNERS it edits

while IFS=$'\t' read -r status path; do
  [ -z "$path" ] && continue
  if [ "$status" = "A" ] && [[ "$path" =~ ^Specs/([^/]+)/([^/]+)/([^/]+)\.podspec\.json$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[3]}" ]; then
    versions+=("${BASH_REMATCH[1]}/${BASH_REMATCH[2]}")
  elif [ "$status" = "A" ] && [[ "$path" =~ ^Specs/([^/]+)/OWNERS$ ]]; then
    new_owners+=("${BASH_REMATCH[1]}")
  elif [ "$status" = "M" ] && [[ "$path" =~ ^Specs/([^/]+)/OWNERS$ ]]; then
    owner_edits+=("${BASH_REMATCH[1]}")
  else
    reasons+=("$path: a publish can only add podspecs or change a pod's OWNERS")
  fi
done < <(git diff --no-renames --name-status "$BASE_REF" "$HEAD_REF")

if [ "${#versions[@]}" -eq 0 ] && [ "${#owner_edits[@]}" -eq 0 ]; then
  reasons+=("it doesn't add a version or change a pod's owners")
fi

adds_version_of() {
  local v
  for v in ${versions[@]+"${versions[@]}"}; do
    [ "${v%%/*}" = "$1" ] && return 0
  done
  return 1
}
for name in ${new_owners[@]+"${new_owners[@]}"}; do
  adds_version_of "$name" || reasons+=("Specs/$name/OWNERS is added without a version of $name; a name is claimed by publishing its first version")
done

# --- Owners changes: by a current owner, leaving at least one ---
for name in ${owner_edits[@]+"${owner_edits[@]}"}; do
  if ! git show "$BASE_REF:Specs/$name/OWNERS" | grep -xF "$AUTHOR" >/dev/null; then
    reasons+=("only a current owner of $name can change Specs/$name/OWNERS, and $AUTHOR isn't listed in it")
  fi
  if ! git show "$HEAD_REF:Specs/$name/OWNERS" | grep '[^[:space:]]' >/dev/null; then
    reasons+=("Specs/$name/OWNERS would be left with no owners")
  fi
done

# --- No prepare_command ---
for v in ${versions[@]+"${versions[@]}"}; do
  name="${v%%/*}"
  version="${v#*/}"
  if git show "$HEAD_REF:Specs/$name/$version/$name.podspec.json" | jq -e 'has("prepare_command")' >/dev/null 2>&1; then
    reasons+=("$name $version uses prepare_command, which runs shell commands on every machine that installs it; CocoaPods trunk doesn't accept it either")
  fi
done

# --- A name that's new here but already on CocoaPods trunk ---
checked=" "
for v in ${versions[@]+"${versions[@]}"}; do
  name="${v%%/*}"
  case "$checked" in *" $name "*) continue ;; esac
  checked="$checked$name "
  # An existing pod's versions are already limited to its owners by
  # validate-pr.sh; only a first publish here needs this.
  git show "$BASE_REF:Specs/$name/OWNERS" >/dev/null 2>&1 && continue

  rc=0
  out="$("$SCRIPT_DIR/verify-trunk-owner.sh" "$name" "$AUTHOR")" || rc=$?
  case "$rc" in
    0) ;;
    2) reasons+=("CocoaPods trunk couldn't be reached to check whether $name is already taken there; run zorvok trunk push again in a few minutes") ;;
    *) reasons+=("$out") ;;
  esac
done

if [ "${#reasons[@]}" -gt 0 ]; then
  for r in "${reasons[@]}"; do
    echo "- $r"
  done
  exit 1
fi

echo "OK: publishes automatically"
