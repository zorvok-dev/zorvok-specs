#!/usr/bin/env bash
# Decides, with no human in the loop, whether a pull request that already
# passed validate-pr.sh is published (merged) or rejected (zorvok ADR
# 0010). validate-pr.sh answers "does this break the registry's rules?";
# this covers the rest of what trunk.cocoapods.org decides. A pull request
# is published only if it concerns ONE pod and every change in it is one
# of:
#
#   - a new version: Specs/<name>/<version>/<name>.podspec.json added;
#   - a new pod's owners: Specs/<name>/OWNERS added alongside a version of
#     that pod (validate-pr.sh checks it lists the author);
#   - an owners change: an existing pod's OWNERS edited by one of its
#     current owners, leaving at least one (`pod trunk add-owner` /
#     `remove-owner`, as a pull request);
#
# each a plain file (no symlinks or executables), and on top of that:
#
#   - no podspec uses `prepare_command`, which runs shell commands on every
#     machine that installs the pod (CocoaPods trunk has rejected new
#     podspecs that use it since May 2025);
#   - a new pod's name doesn't differ only in letter case from a pod
#     already here; and
#   - a pod that's new here but already on CocoaPods trunk is published
#     by one of its trunk owners, as verify-trunk-owner.sh decides.
#
# validate-pr.sh's immutability rule covers version directories but not
# OWNERS, so the OWNERS rules above are what keep a pull request from
# taking over someone else's pod. Owners are matched by numeric GitHub
# user ID (see validate-pr.sh).
#
# Usage: publish-policy.sh <base-ref> <head-ref> <author-user-id> <author-username>
#   Judges the change from base to head as the author's. The publish
#   workflow passes the registry's current tip as <base-ref>.
#   verify-trunk-owner.sh's test overrides apply.
#
# Exits 0 to publish, or 1 with every reason it can't be, one per line,
# written for the publisher.

set -euo pipefail

USAGE="usage: publish-policy.sh <base-ref> <head-ref> <author-user-id> <author-username>"
BASE_REF="${1:?$USAGE}"
HEAD_REF="${2:?$USAGE}"
AUTHOR_ID="${3:?$USAGE}"
AUTHOR_LOGIN="${4:?$USAGE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

reasons=()
versions=()    # "<name>/<version>" for each added podspec
new_owners=()  # pods whose OWNERS this pull request adds
owner_edits=() # pods whose existing OWNERS it edits
pods=" "       # every pod this pull request touches

owner_ids() {
  git show "$1:$2" | sed 's/#.*//' | awk 'NF { print $1 }'
}

while IFS=$'\t' read -r status path; do
  [ -z "$path" ] && continue
  if [[ "$path" =~ ^Specs/([^/]+)/ ]]; then
    case "$pods" in *" ${BASH_REMATCH[1]} "*) ;; *) pods="$pods${BASH_REMATCH[1]} " ;; esac
  fi
  if [ "$status" != "D" ] && [ "$(git ls-tree "$HEAD_REF" -- "$path" | awk '{ print $1 }')" != "100644" ]; then
    reasons+=("$path isn't a plain file (symlinks and executables aren't allowed)")
    continue
  fi
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

# --- One pod per pull request ---
pod_count="$(wc -w <<<"$pods" | tr -d ' ')"
if [ "$pod_count" -gt 1 ]; then
  reasons+=("it changes $pod_count pods (${pods# }); a publish can change only one pod at a time")
fi

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
  if ! grep -qxF "$AUTHOR_ID" <<<"$(owner_ids "$BASE_REF" "Specs/$name/OWNERS")"; then
    reasons+=("only a current owner of $name can change Specs/$name/OWNERS, and $AUTHOR_LOGIN (GitHub user $AUTHOR_ID) isn't listed in it")
  fi
  if [ -z "$(owner_ids "$HEAD_REF" "Specs/$name/OWNERS")" ]; then
    reasons+=("Specs/$name/OWNERS would be left with no owners")
  fi
done

# --- No prepare_command ---
for v in ${versions[@]+"${versions[@]}"}; do
  name="${v%%/*}"
  version="${v#*/}"
  spec="$(git show "$HEAD_REF:Specs/$name/$version/$name.podspec.json" 2>/dev/null || true)"
  if ! jq -se 'length == 1 and (.[0] | type) == "object"' >/dev/null 2>&1 <<<"$spec"; then
    reasons+=("$name $version's podspec must be a single JSON object")
  elif jq -e 'has("prepare_command")' >/dev/null 2>&1 <<<"$spec"; then
    reasons+=("$name $version uses prepare_command, which runs shell commands on every machine that installs it; CocoaPods trunk doesn't accept it either")
  fi
done

# --- A name that's new here: no case-only clash, and trunk owners only ---
existing_lc="$(git ls-tree --name-only "$BASE_REF" Specs/ 2>/dev/null | sed 's|^Specs/||' | tr '[:upper:]' '[:lower:]')"
checked=" "
for v in ${versions[@]+"${versions[@]}"}; do
  name="${v%%/*}"
  case "$checked" in *" $name "*) continue ;; esac
  checked="$checked$name "
  # An existing pod's versions are already limited to its owners by
  # validate-pr.sh; only a first publish here needs this.
  git show "$BASE_REF:Specs/$name/OWNERS" >/dev/null 2>&1 && continue

  if grep -qxF "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" <<<"$existing_lc"; then
    reasons+=("a pod whose name differs from $name only in letter case is already published here")
    continue
  fi

  rc=0
  out="$("$SCRIPT_DIR/verify-trunk-owner.sh" "$name" "$AUTHOR_ID" "$AUTHOR_LOGIN")" || rc=$?
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
