#!/usr/bin/env bash
# Decides, with no human in the loop, whether a GitHub user may publish a
# pod here whose name already exists on CocoaPods trunk (zorvok ADR 0010).
# The rule is CocoaPods' own: only an existing owner of the pod on trunk
# can publish its new versions. CocoaPods never has to check this across
# registries; this one has to, or anyone could claim `Alamofire` here
# before its authors do.
#
# Trunk knows a pod's owners only by the emails they registered with `pod
# trunk register`, and it lets you act as an owner by proving you control
# one of those emails. This checks the same thing, through what GitHub has
# verified about the publisher's account (identified by its numeric user
# ID), never through anything in the pull request:
#
#   1. their GitHub profile's public email is one of the pod's trunk owner
#      emails (GitHub only lets a verified address be public); or
#   2. GitHub credits their account with commits to the pod's GitHub
#      repository made with one of those emails. GitHub credits a commit
#      only to the account that has verified its email, so this works with
#      a hidden email too, and anyone else's commits made with that email
#      are credited to the owner, not to them.
#
# Owning, or controlling a file in, the repository a podspec points to is
# deliberately not accepted. GitHub doesn't say who held a username in
# the past, so after an owner renames or deletes their account, someone
# else can rename an old account and an old repository of their own into
# the freed names, and no creation date tells them apart. A file on a
# homepage isn't accepted either: its domain can lapse.
#
# A name that differs only in letter case from a trunk pod is refused. A
# name that isn't on CocoaPods trunk at all needs no evidence: its first
# publisher here owns it, as on trunk.
#
# Usage: verify-trunk-owner.sh <name> <github-user-id> <github-username>
# Exits 0 if the user may publish <name> (saying why), 1 if not (saying
# how to prove it), 2 if CocoaPods trunk couldn't be checked.
#
# Only reads, over HTTPS (no globbing, no other protocols, time and size
# capped). Test overrides: TRUNK_CDN_URL, TRUNK_API_URL, GITHUB_API_URL,
# ZORVOK_FETCH_PROTO and ZORVOK_MIN_TRUNK_PODS. GH_TOKEN, if set,
# authenticates GitHub API calls.

set -euo pipefail

NAME="${1:?usage: verify-trunk-owner.sh <name> <github-user-id> <github-username>}"
AUTHOR_ID="${2:?usage: verify-trunk-owner.sh <name> <github-user-id> <github-username>}"
LOGIN="${3:?usage: verify-trunk-owner.sh <name> <github-user-id> <github-username>}"
TRUNK_CDN_URL="${TRUNK_CDN_URL:-https://cdn.cocoapods.org}"
TRUNK_API_URL="${TRUNK_API_URL:-https://trunk.cocoapods.org/api/v1}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
FETCH_PROTO="${ZORVOK_FETCH_PROTO:-=https}"
# CocoaPods trunk lists over 100,000 pods. A list much shorter than that
# is a broken or truncated answer, and trusting it would let anyone claim
# a trunk pod's name, so it counts as trunk not being reachable.
MIN_TRUNK_PODS="${ZORVOK_MIN_TRUNK_PODS:-50000}"

# Everything below goes into URLs; refuse anything outside the expected
# characters rather than escape it.
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.+-]*$ ]] || { echo "\"$NAME\" isn't a valid pod name"; exit 1; }
[[ "$AUTHOR_ID" =~ ^[0-9]+$ ]] || { echo "\"$AUTHOR_ID\" isn't a GitHub user ID"; exit 1; }
[[ "$LOGIN" =~ ^[A-Za-z0-9-]+$ ]] || { echo "\"$LOGIN\" isn't a GitHub username"; exit 1; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

md5_hex() {
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -c1-32
  else
    md5 -q -s "$1"
  fi
}

fetch() {
  curl -fsSL --globoff --proto "$FETCH_PROTO" --proto-redir "$FETCH_PROTO" --max-time 30 --max-filesize 50000000 "$@"
}

github_api() {
  if [ -n "${GH_TOKEN:-}" ]; then
    fetch -H "Authorization: Bearer $GH_TOKEN" "$GITHUB_API_URL/$1"
  else
    fetch "$GITHUB_API_URL/$1"
  fi
}

# github_repo <url>: "owner/repo" if url points into a GitHub repository.
github_repo() {
  local u="${1%/}"
  if [[ "$u" =~ ^(https?://|git@|ssh://git@)(www\.)?github\.com[:/]+([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+) ]]; then
    printf '%s/%s' "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]%.git}"
  fi
}

unreachable() {
  echo "CocoaPods trunk couldn't be checked for $NAME"
  exit 2
}

# --- Is the name on trunk, in any letter case? ---
all_pods="$(fetch "$TRUNK_CDN_URL/all_pods.txt")" || unreachable
[ "$(grep -c . <<<"$all_pods" || true)" -ge "$MIN_TRUNK_PODS" ] || unreachable
trunk_name="$(awk -v n="$(lower "$NAME")" 'tolower($0) == n { print; exit }' <<<"$all_pods")"
if [ -z "$trunk_name" ]; then
  echo "$NAME isn't on CocoaPods trunk, so its first publisher here owns it"
  exit 0
fi
if [ "$trunk_name" != "$NAME" ]; then
  echo "$NAME differs only in letter case from $trunk_name, which is on CocoaPods trunk. Names that differ only in case can't be published here; if you own $trunk_name, publish it under that exact name."
  exit 1
fi

# --- Its owners, and the podspec trunk published most recently ---
hash="$(md5_hex "$NAME")"
index="$(fetch "$TRUNK_CDN_URL/all_pods_versions_${hash:0:1}_${hash:1:1}_${hash:2:1}.txt")" || unreachable
line="$(awk -F/ -v n="$NAME" '$1 == n' <<<"$index")"
[ -n "$line" ] || unreachable
pod_info="$(fetch "$TRUNK_API_URL/pods/$NAME")" || unreachable
cdn_versions="$(tr '/' '\n' <<<"$line" | tail -n +2)"
# The version trunk published last, by trunk's own timestamps, among those
# still on its CDN: its podspec names the pod's current repository. (A
# version sort would pick a prerelease like 2.0.0-beta.1 over 2.0.0, even
# one published years earlier from a repository the pod has since left.)
latest="$(jq -r --arg cdn "$cdn_versions" '
  ($cdn | split("\n")) as $on
  | [.versions[]? | select(.name as $n | any($on[]; . == $n))]
  | sort_by(.created_at) | last | .name // empty' <<<"$pod_info" 2>/dev/null || true)"
[ -n "$latest" ] || latest="$(sort -V <<<"$cdn_versions" | tail -n 1)"
spec="$(fetch "$TRUNK_CDN_URL/Specs/${hash:0:1}/${hash:1:1}/${hash:2:1}/$NAME/$latest/$NAME.podspec.json")" || unreachable
git_url="$(jq -r '.source.git // empty' <<<"$spec" 2>/dev/null || true)"
homepage="$(jq -r '.homepage // empty' <<<"$spec" 2>/dev/null || true)"
owner_emails="$(jq -r '.owners[]?.email // empty' <<<"$pod_info" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"

is_owner_email() {
  [ -n "$1" ] && [ -n "$owner_emails" ] && grep -qxF "$(lower "$1")" <<<"$owner_emails"
}

# --- 1. Their public email is a trunk owner's ---
user="$(github_api "user/$AUTHOR_ID" 2>/dev/null || true)"
if [ -n "$user" ] && is_owner_email "$(jq -r '.email // empty' <<<"$user")"; then
  echo "$LOGIN's public GitHub email is an owner of $NAME on CocoaPods trunk"
  exit 0
fi

# --- 2. GitHub credits them with commits made with a trunk owner's email ---
repo="$(github_repo "$git_url")"
[ -z "$repo" ] && repo="$(github_repo "$homepage")"
if [ -n "$repo" ] && repo_info="$(github_api "repos/$repo" 2>/dev/null)"; then
  # A renamed or transferred repository answers under its new name.
  full_name="$(jq -r '.full_name // empty' <<<"$repo_info")"
  [[ "$full_name" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && repo="$full_name"
  if commits="$(github_api "repos/$repo/commits?author=$LOGIN&per_page=100" 2>/dev/null)"; then
    while IFS= read -r email; do
      if is_owner_email "$email"; then
        echo "GitHub credits $LOGIN with commits to github.com/$repo made with the email of an owner of $NAME on CocoaPods trunk"
        exit 0
      fi
    done < <(jq -r --argjson id "$AUTHOR_ID" '.[]? | select(.author.id? == $id) | .commit.author.email // empty' <<<"$commits" 2>/dev/null || true)
  fi
fi

echo "$NAME already exists on CocoaPods trunk, and only its owners there can publish it here; $LOGIN couldn't be matched to one. Trunk knows its owners by the email they registered with \`pod trunk register\`. Show GitHub you have that email, in either of these ways, and run zorvok trunk push again:"
echo "  - add it to your GitHub account (Settings → Emails) and choose it as your public profile email"
if [ -n "$repo" ]; then
  echo "  - or, if you've committed to github.com/$repo with it, just add it to your GitHub account: GitHub then credits those commits to you, and it can stay private"
fi
exit 1
