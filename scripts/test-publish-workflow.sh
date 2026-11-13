#!/usr/bin/env bash
# End-to-end test of .github/workflows/publish.yml: runs the workflow's own
# "judge" script, as written in the YAML, on simulated pull requests. A
# bare git repository plays this registry on GitHub (so the fast-forward
# publish is real), and a stand-in `gh` records the verdict comments and
# closes. The ownership checks run against LIVE CocoaPods trunk and GitHub
# data (Kingfisher is owned on trunk by onevcat, GitHub user 1019875), so
# this needs network access and about 10 of GitHub's 60 unauthenticated API
# calls an hour.
#
# Covers, in order, on one registry:
#   1. a new pod (not on trunk) is published
#   2. an owner removes a co-owner
#   3. the removed co-owner publishes from a branch made before the
#      removal, which must be rejected (judged on the current tip, not
#      the pull request's base)
#   4. someone who isn't Kingfisher's trunk owner claims it: rejected
#   5. Kingfisher's trunk owner claims it: published
#   6. the removed co-owner re-adds themselves to OWNERS: rejected
#
# Usage: scripts/test-publish-workflow.sh   (needs git, jq, curl, ruby)
set -uo pipefail

SPECS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT

ruby -ryaml -e '
  step = YAML.load_file(ARGV[0])["jobs"]["publish"]["steps"].find { |s| s["id"] == "judge" }
  abort "no step with id: judge in publish.yml" unless step
  puts step["run"]
' "$SPECS/.github/workflows/publish.yml" > "$W/judge.sh" || exit 1

git init -q --bare -b main "$W/origin.git"
git clone -q "$W/origin.git" "$W/seed" 2>/dev/null
cd "$W/seed" || exit 1
git config user.email seed@example.com
git config user.name Seed
cp -R "$SPECS/scripts" .
cp "$SPECS"/{all_pods.txt,all_pods_versions.txt,CocoaPods-version.yml} .
mkdir -p Specs/ExistingPod/1.0.0
echo '{"name":"ExistingPod","version":"1.0.0"}' > Specs/ExistingPod/1.0.0/ExistingPod.podspec.json
printf '1001 alice\n9001 mallory\n' > Specs/ExistingPod/OWNERS
git add -A
git commit -q -m seed
git push -q origin main

mkdir -p "$W/bin" "$W/comments"
cat > "$W/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr comment") cp "\${@: -1}" "$W/comments/pr-\$3.md" ;;
  "pr close") echo "\$3" >> "$W/closed" ;;
  "workflow run") echo "\$*" >> "$W/workflow-runs" ;;
  *) echo "stand-in gh: unexpected \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$W/bin/gh"

# open_pr <number> <base commit, or "" for the current main> <setup
# commands>: commits setup's changes on top of base as the pull request's
# head, and prints its SHA.
open_pr() {
  cd "$W/seed" || exit 1
  git fetch -q origin main
  git checkout -q -f -B "pr$1" "${2:-origin/main}"
  eval "$3"
  git add -A
  git commit -q -m "pr $1"
  git push -q -f origin "HEAD:refs/pull/$1/head"
  git rev-parse HEAD
}

spec() {
  mkdir -p "Specs/$1/$2"
  echo "{\"name\":\"$1\",\"version\":\"$2\"}" > "Specs/$1/$2/$1.podspec.json"
}

pass=0
fail=0
# judge <number> <author login> <author id> <head SHA> <expected verdict>
# <description> [text the comment must contain]: runs the workflow's
# script in a fresh checkout, the way the runner would, and checks its
# verdict, its reason, and whether the head landed on main.
judge() {
  local rc got landed want_landed=no
  cd "$W" || exit 1 # out of the previous run's checkout before deleting it
  rm -rf "${W:?}/ws"
  git clone -q "$W/origin.git" "$W/ws" 2>/dev/null
  cd "$W/ws" || exit 1
  mkdir -p "$W/tmp$1"
  : > "$W/out$1"
  PATH="$W/bin:$PATH" GH_TOKEN="" PR="$1" AUTHOR="$2" AUTHOR_ID="$3" BASE=main HEAD_SHA="$4" \
    GITHUB_REPOSITORY=zorvok-dev/zorvok-specs GITHUB_WORKSPACE="$W/ws" RUNNER_TEMP="$W/tmp$1" \
    GITHUB_OUTPUT="$W/out$1" bash -e "$W/judge.sh" >/dev/null 2>"$W/err$1"
  rc=$?
  got="$(sed -n 's/^verdict=//p' "$W/out$1")"
  landed=no
  git --git-dir="$W/origin.git" merge-base --is-ancestor "$4" main 2>/dev/null && landed=yes
  [ "$5" = published ] && want_landed=yes
  if [ "$rc" -eq 0 ] && [ "$got" = "$5" ] && [ "$landed" = "$want_landed" ] &&
     head -1 "$W/comments/pr-$1.md" 2>/dev/null | grep -qF "sha=$4 verdict=$5" &&
     grep -qF -- "${7:-}" "$W/comments/pr-$1.md"; then
    echo "PASS ($5) - $6"
    pass=$((pass + 1))
  else
    echo "FAIL (expected $5${7:+, saying \"$7\"}; got ${got:-nothing}, exit $rc, landed on main: $landed) - $6"
    sed 's/^/  /' "$W/comments/pr-$1.md" "$W/err$1" 2>/dev/null | tail -12
    fail=$((fail + 1))
  fi
}

s=$(open_pr 1 "" 'spec ZorvokTestFreshPod 1.0.0; echo "1002 bob" > Specs/ZorvokTestFreshPod/OWNERS')
judge 1 bob 1002 "$s" published "a new pod that isn't on trunk"
before_removal="$(git --git-dir="$W/origin.git" rev-parse main)"
s=$(open_pr 2 "" 'printf "1001 alice\n" > Specs/ExistingPod/OWNERS')
judge 2 alice 1001 "$s" published "an owner removes a co-owner"
s=$(open_pr 3 "$before_removal" 'spec ExistingPod 2.0.0')
judge 3 mallory 9001 "$s" rejected "the removed co-owner publishes from a branch made before the removal" \
  "GitHub user 9001 is not listed in Specs/ExistingPod/OWNERS"
s=$(open_pr 4 "" 'spec Kingfisher 99.0.0; echo "583231 octocat" > Specs/Kingfisher/OWNERS')
judge 4 octocat 583231 "$s" rejected "someone who isn't Kingfisher's trunk owner claims it" \
  "only its owners there can publish it here"
s=$(open_pr 5 "" 'spec Kingfisher 99.0.0; echo "1019875 onevcat" > Specs/Kingfisher/OWNERS')
judge 5 onevcat 1019875 "$s" published "Kingfisher's trunk owner claims it"
s=$(open_pr 6 "" 'printf "1001 alice\n9001 mallory\n" > Specs/ExistingPod/OWNERS')
judge 6 mallory 9001 "$s" rejected "the removed co-owner re-adds themselves to OWNERS" \
  "only a current owner of ExistingPod can change Specs/ExistingPod/OWNERS"

if [ "$(git --git-dir="$W/origin.git" show main:all_pods_versions.txt)" != "$(printf 'ExistingPod/1.0.0\nKingfisher/99.0.0\nZorvokTestFreshPod/1.0.0')" ]; then
  echo "FAIL - the index on main isn't the three published pods:"
  git --git-dir="$W/origin.git" show main:all_pods_versions.txt | sed 's/^/  /'
  fail=$((fail + 1))
fi
if [ "$(tr '\n' ' ' < "$W/closed" 2>/dev/null)" != "3 4 6 " ]; then
  echo "FAIL - closed pull requests: $(tr '\n' ' ' < "$W/closed" 2>/dev/null), want 3 4 6"
  fail=$((fail + 1))
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
