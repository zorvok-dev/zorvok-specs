#!/usr/bin/env bash
# Decides whether a publish pull request that already passed
# validate-pr.sh can be merged with no human in the loop (zorvok ADR
# 0010). validate-pr.sh answers "does this break the registry's rules?";
# this answers "is it a change a machine should merge on its own?" The
# publish workflow merges only when both say yes, and leaves the pull
# request for a maintainer otherwise. It merges automatically only when
# the pull request:
#
#   1. only ADDS files, each one either
#      Specs/<name>/<version>/<name>.podspec.json or, alongside a version
#      of a pod that's new here, Specs/<name>/OWNERS. So it can never
#      edit an existing pod's OWNERS (validate-pr.sh's immutability rule
#      covers version directories, not OWNERS), the registry's scripts or
#      workflows, or anything else;
#   2. adds at least one version;
#   3. doesn't use `prepare_command`, which runs shell commands on every
#      machine that installs the pod (CocoaPods trunk stopped accepting
#      new podspecs that use it in May 2025); and
#   4. for a pod that's NEW here, uses a name that isn't already on
#      CocoaPods trunk. The first Zorvok publish of an existing trunk
#      pod's name waits for a one-time maintainer review, so nobody can
#      claim someone else's pod. Its later versions publish
#      automatically, since validate-pr.sh then holds them to its OWNERS.
#
# Usage: publish-policy.sh <base-ref> <head-ref>
#   Judges the pull request's own changes (base..head). TRUNK_CDN_URL
#   overrides https://cdn.cocoapods.org for tests (a file:// URL works).
#
# Exits 0 to merge automatically, or 1 with every reason a maintainer
# needs to look, one per line.

set -euo pipefail

BASE_REF="${1:?usage: publish-policy.sh <base-ref> <head-ref>}"
HEAD_REF="${2:?usage: publish-policy.sh <base-ref> <head-ref>}"
TRUNK_CDN_URL="${TRUNK_CDN_URL:-https://cdn.cocoapods.org}"

reasons=()
versions=()   # "<name>/<version>" for each added podspec
new_owners=() # pods whose OWNERS this pull request adds

# --- 1. Only additions of podspecs (and a new pod's OWNERS) ---
while IFS=$'\t' read -r status path; do
  [ -z "$path" ] && continue
  if [ "$status" != "A" ]; then
    reasons+=("$path is changed ($status); only additions publish automatically")
    continue
  fi
  if [[ "$path" =~ ^Specs/([^/]+)/([^/]+)/([^/]+)\.podspec\.json$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[3]}" ]; then
    versions+=("${BASH_REMATCH[1]}/${BASH_REMATCH[2]}")
  elif [[ "$path" =~ ^Specs/([^/]+)/OWNERS$ ]]; then
    new_owners+=("${BASH_REMATCH[1]}")
  else
    reasons+=("$path isn't a podspec or a new pod's OWNERS file")
  fi
done < <(git diff --no-renames --name-status "$BASE_REF" "$HEAD_REF")

# --- 2. At least one version, and no OWNERS without one ---
[ "${#versions[@]}" -eq 0 ] && reasons+=("it doesn't add a version of any pod")

adds_version_of() {
  local v
  for v in ${versions[@]+"${versions[@]}"}; do
    [ "${v%%/*}" = "$1" ] && return 0
  done
  return 1
}
for name in ${new_owners[@]+"${new_owners[@]}"}; do
  adds_version_of "$name" || reasons+=("Specs/$name/OWNERS is added without a version of $name")
done

# --- 3. No prepare_command ---
for v in ${versions[@]+"${versions[@]}"}; do
  name="${v%%/*}"
  version="${v#*/}"
  if git show "$HEAD_REF:Specs/$name/$version/$name.podspec.json" | jq -e 'has("prepare_command")' >/dev/null 2>&1; then
    reasons+=("$name $version uses prepare_command, which runs shell commands on every machine that installs it")
  fi
done

# --- 4. A new pod's name isn't already on CocoaPods trunk ---
md5_hex() {
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -c1-32
  else
    md5 -q -s "$1"
  fi
}

# on_trunk <name>: 0 if CocoaPods trunk has a pod with exactly this name,
# 1 if not, 2 if trunk couldn't be checked. Uses the same sharded index
# files CocoaPods' own CDN source reads (all_pods_versions_X_Y_Z.txt,
# keyed by the name's MD5).
on_trunk() {
  local hash index
  hash="$(md5_hex "$1")"
  if ! index="$(curl -fsSL --max-time 20 "$TRUNK_CDN_URL/all_pods_versions_${hash:0:1}_${hash:1:1}_${hash:2:1}.txt")"; then
    return 2
  fi
  if awk -F/ -v n="$1" '$1 == n { found = 1 } END { exit !found }' <<<"$index"; then
    return 0
  fi
  return 1
}

checked=" "
for v in ${versions[@]+"${versions[@]}"}; do
  name="${v%%/*}"
  case "$checked" in *" $name "*) continue ;; esac
  checked="$checked$name "
  # Only a pod that's new here: an existing one's versions are already
  # limited to its owners by validate-pr.sh.
  git show "$BASE_REF:Specs/$name/OWNERS" >/dev/null 2>&1 && continue

  rc=0
  on_trunk "$name" || rc=$?
  case "$rc" in
    0) reasons+=("$name already exists on CocoaPods trunk. Its first version here needs a one-time maintainer review, so nobody can claim someone else's pod; its later versions publish automatically.") ;;
    2) reasons+=("CocoaPods trunk couldn't be checked for $name, so a maintainer needs to review it") ;;
  esac
done

if [ "${#reasons[@]}" -gt 0 ]; then
  for r in "${reasons[@]}"; do
    echo "- $r"
  done
  exit 1
fi

echo "OK: publishes automatically"
