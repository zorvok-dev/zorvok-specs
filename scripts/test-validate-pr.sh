#!/usr/bin/env bash
# Exercises validate-pr.sh against a disposable local git repository,
# covering every scenario the README's "Publishing a package" section
# claims is enforced. The README said this had "been exercised locally
# against real git repositories and real pass/fail scenarios" but no
# repeatable script backed that claim — this is that script, so the
# claim can be checked by anyone, any time, not just taken on faith.
#
# Usage: scripts/test-validate-pr.sh
# Exits non-zero if any scenario's actual result doesn't match its
# expected one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate-pr.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"
git init -q -b main
git config user.email "test@example.com"
git config user.name "Test Harness"

mkdir -p Specs
echo "placeholder" > Specs/.gitkeep
git add Specs/.gitkeep
git commit -q -m "initial"

# --- base state: ExistingPod 1.0.0, owned by alice ---
mkdir -p Specs/ExistingPod/1.0.0
cat > Specs/ExistingPod/1.0.0/ExistingPod.podspec.json <<'EOF'
{"name": "ExistingPod", "version": "1.0.0"}
EOF
printf '1001 alice\n' > Specs/ExistingPod/OWNERS
git add Specs/ExistingPod
git commit -q -m "seed: ExistingPod 1.0.0 owned by alice"
BASE="$(git rev-parse HEAD)"

pass=0
fail=0

# run_case <description> <actor> <expect: pass|fail> <setup-function>
run_case() {
  local desc="$1" actor="$2" expect="$3" setup_fn="$4"

  git checkout -q -b "case-$RANDOM" "$BASE"
  "$setup_fn"
  git add -A
  git commit -q -m "$desc"
  HEAD="$(git rev-parse HEAD)"

  local got="pass"
  if ! "$VALIDATE" "$BASE" "$HEAD" "$actor" >/tmp/validate-pr-out.$$ 2>&1; then
    got="fail"
  fi

  if [ "$got" = "$expect" ]; then
    echo "PASS (as expected: $expect) - $desc"
    pass=$((pass + 1))
  else
    echo "FAIL (expected $expect, got $got) - $desc"
    echo "  --- validate-pr.sh output ---"
    sed 's/^/  /' /tmp/validate-pr-out.$$
    fail=$((fail + 1))
  fi
  rm -f /tmp/validate-pr-out.$$

  git checkout -q main
  git branch -q -D "$(git branch --list 'case-*' | tail -1 | tr -d ' *')" 2>/dev/null || true
}

# 1. Existing owner publishes a new version — should pass.
setup_valid_update() {
  mkdir -p Specs/ExistingPod/2.0.0
  cat > Specs/ExistingPod/2.0.0/ExistingPod.podspec.json <<'EOF'
{"name": "ExistingPod", "version": "2.0.0"}
EOF
}
run_case "alice publishes ExistingPod 2.0.0 (existing owner)" "1001" "pass" setup_valid_update

# 2. Non-owner tries to publish a version of someone else's pod — should fail.
setup_non_owner_publish() {
  mkdir -p Specs/ExistingPod/2.0.0
  cat > Specs/ExistingPod/2.0.0/ExistingPod.podspec.json <<'EOF'
{"name": "ExistingPod", "version": "2.0.0"}
EOF
}
run_case "bob publishes ExistingPod 2.0.0 (not an owner)" "1002" "fail" setup_non_owner_publish

# 3. Ownership hijack: add yourself to OWNERS and publish in the same PR — should fail.
setup_hijack() {
  mkdir -p Specs/ExistingPod/2.0.0
  cat > Specs/ExistingPod/2.0.0/ExistingPod.podspec.json <<'EOF'
{"name": "ExistingPod", "version": "2.0.0"}
EOF
  printf '1001 alice\n1002 bob\n' > Specs/ExistingPod/OWNERS
}
run_case "bob adds himself to OWNERS and publishes in the same PR" "1002" "fail" setup_hijack

# 4. Immutability: modify an already-published version's file — should fail.
setup_immutability_violation() {
  cat > Specs/ExistingPod/1.0.0/ExistingPod.podspec.json <<'EOF'
{"name": "ExistingPod", "version": "1.0.0", "summary": "tampered"}
EOF
}
run_case "alice modifies an already-published ExistingPod 1.0.0" "1001" "fail" setup_immutability_violation

# 5. Name/version mismatch between podspec content and its path — should fail.
setup_name_mismatch() {
  mkdir -p Specs/ExistingPod/2.0.0
  cat > Specs/ExistingPod/2.0.0/ExistingPod.podspec.json <<'EOF'
{"name": "SomeOtherName", "version": "2.0.0"}
EOF
}
run_case "podspec name field doesn't match its own path" "1001" "fail" setup_name_mismatch

# 6. Malformed JSON — should fail.
setup_malformed_json() {
  mkdir -p Specs/ExistingPod/2.0.0
  echo '{not valid json' > Specs/ExistingPod/2.0.0/ExistingPod.podspec.json
}
run_case "malformed JSON podspec" "1001" "fail" setup_malformed_json

# 6b. A second JSON document after a valid one — should fail.
setup_two_documents() {
  mkdir -p Specs/ExistingPod/2.0.0
  printf '{"name": "ExistingPod", "version": "2.0.0"}\n{"name": "Other"}\n' > Specs/ExistingPod/2.0.0/ExistingPod.podspec.json
}
run_case "a podspec file holding two JSON documents" "1001" "fail" setup_two_documents

# 7. Brand-new pod, first publish, with its own OWNERS — should pass.
setup_new_pod() {
  mkdir -p Specs/BrandNewPod/1.0.0
  cat > Specs/BrandNewPod/1.0.0/BrandNewPod.podspec.json <<'EOF'
{"name": "BrandNewPod", "version": "1.0.0"}
EOF
  printf '1003 carol\n' > Specs/BrandNewPod/OWNERS
}
run_case "carol publishes BrandNewPod 1.0.0 (brand new, adds own OWNERS)" "1003" "pass" setup_new_pod

# 8. Brand-new pod, first publish, but forgets to add OWNERS — should fail.
setup_new_pod_no_owners() {
  mkdir -p Specs/AnotherNewPod/1.0.0
  cat > Specs/AnotherNewPod/1.0.0/AnotherNewPod.podspec.json <<'EOF'
{"name": "AnotherNewPod", "version": "1.0.0"}
EOF
}
run_case "dave publishes a new pod but forgets to add OWNERS" "1004" "fail" setup_new_pod_no_owners

# 9. A rename of a published version (git would report R100) — should fail.
setup_rename() {
  mkdir -p Specs/ExistingPod/2.0.0
  git mv Specs/ExistingPod/1.0.0/ExistingPod.podspec.json Specs/ExistingPod/2.0.0/ExistingPod.podspec.json
  echo '{"name": "ExistingPod", "version": "2.0.0"}' > Specs/ExistingPod/2.0.0/ExistingPod.podspec.json
}
run_case "bob renames ExistingPod 1.0.0 to 2.0.0" "1002" "fail" setup_rename

# 10. A new pod whose OWNERS lists a bare username (the old format) — should fail.
setup_username_owners() {
  mkdir -p Specs/UsernamePod/1.0.0
  echo '{"name": "UsernamePod", "version": "1.0.0"}' > Specs/UsernamePod/1.0.0/UsernamePod.podspec.json
  printf 'carol\n' > Specs/UsernamePod/OWNERS
}
run_case "carol publishes a new pod with a username-only OWNERS" "1003" "fail" setup_username_owners

# 11. A pod name outside CocoaPods' characters ("-n" would vanish from the index) — should fail.
setup_bad_name() {
  mkdir -p -- "Specs/-n/1.0.0"
  echo '{"name": "-n", "version": "1.0.0"}' > "Specs/-n/1.0.0/-n.podspec.json"
  printf '1003 carol\n' > "Specs/-n/OWNERS"
}
run_case "carol publishes a pod named -n" "1003" "fail" setup_bad_name

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
