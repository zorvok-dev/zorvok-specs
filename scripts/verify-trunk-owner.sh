#!/usr/bin/env bash
# Decides, with no human in the loop, whether a GitHub user may publish a
# pod here whose name already exists on CocoaPods trunk (zorvok ADR 0010).
# The rule is CocoaPods' own: only an existing owner of the pod on trunk
# can publish its new versions. CocoaPods never has to check this across
# registries; this one has to, or anyone could claim `Alamofire` here
# before its authors do.
#
# All the evidence comes from CocoaPods trunk and GitHub, never from the
# pull request: trunk's API lists the pod's owners (by email) and when
# each version was published, and the latest podspec published there
# names the pod's repository. The publisher, identified by their numeric
# GitHub user ID, may publish the pod if any one of these holds:
#
#   1. their GitHub profile's public email is one of the pod's trunk owner
#      emails (GitHub only lets a verified address be public);
#   2. GitHub credits their account with commits to the pod's GitHub
#      repository made with one of those emails (it only credits an
#      account with commits whose email belongs to it, so this works with
#      a hidden email too);
#   3. that repository is owned by their account, and both the account
#      and the repository already existed when trunk published the
#      version that points to them;
#   4. that repository's default branch has a `.zorvok-owners` file
#      listing their GitHub user ID (or username), and the repository and
#      its owner already existed when trunk published that version.
#
# 1 and 2 prove the publisher is a trunk owner. 3 and 4 prove they
# control what the trunk owners published. The age checks are what stop
# a namespace takeover: someone who registers a deleted account's freed
# username, or recreates a renamed repository, gets a newer creation date
# than the trunk release and doesn't pass. Proofs that can't be protected
# that way (membership of a large organization, a file on a homepage
# whose domain can lapse) are deliberately not accepted.
#
# A name that differs only in letter case from a trunk pod is refused. A
# name that isn't on CocoaPods trunk at all needs no evidence: its first
# publisher here owns it, as on trunk.
#
# Usage: verify-trunk-owner.sh <name> <github-user-id> <github-username>
# Exits 0 if the user may publish <name> (saying why), 1 if not (saying
# how to prove it), 2 if CocoaPods trunk couldn't be checked.
#
# Only reads: fetches over HTTPS (no globbing, no other protocols, size
# capped) and makes a shallow, blob-less clone of a github.com repository,
# never running anything from it. Test overrides: TRUNK_CDN_URL,
# TRUNK_API_URL, GITHUB_API_URL, GITHUB_SERVER_URL (GitHub Actions sets
# the last two to the real services; the defaults below match),
# GIT_ALLOW_PROTOCOL and ZORVOK_FETCH_PROTO. GH_TOKEN, if set,
# authenticates GitHub API calls.

set -euo pipefail

NAME="${1:?usage: verify-trunk-owner.sh <name> <github-user-id> <github-username>}"
AUTHOR_ID="${2:?usage: verify-trunk-owner.sh <name> <github-user-id> <github-username>}"
LOGIN="${3:?usage: verify-trunk-owner.sh <name> <github-user-id> <github-username>}"
TRUNK_CDN_URL="${TRUNK_CDN_URL:-https://cdn.cocoapods.org}"
TRUNK_API_URL="${TRUNK_API_URL:-https://trunk.cocoapods.org/api/v1}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
FETCH_PROTO="${ZORVOK_FETCH_PROTO:-=https}"
export GIT_ALLOW_PROTOCOL="${GIT_ALLOW_PROTOCOL:-https}"
export GIT_TERMINAL_PROMPT=0

# Everything below goes into URLs; refuse anything outside the expected
# characters rather than escape it.
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.+-]*$ ]] || { echo "\"$NAME\" isn't a valid pod name"; exit 1; }
[[ "$AUTHOR_ID" =~ ^[0-9]+$ ]] || { echo "\"$AUTHOR_ID\" isn't a GitHub user ID"; exit 1; }
[[ "$LOGIN" =~ ^[A-Za-z0-9-]+$ ]] || { echo "\"$LOGIN\" isn't a GitHub username"; exit 1; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
LOGIN_LC="$(lower "$LOGIN")"

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

# epoch <ISO-8601 timestamp>: seconds since 1970, or nothing.
epoch() {
  [ -n "$1" ] && jq -rn --arg t "$1" '$t | fromdateiso8601' 2>/dev/null || true
}

with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    "$@"
  fi
}

# --- Is the name on trunk, in any letter case? ---
if ! all_pods="$(fetch "$TRUNK_CDN_URL/all_pods.txt")"; then
  echo "CocoaPods trunk couldn't be checked for $NAME"
  exit 2
fi
trunk_name="$(awk -v n="$(lower "$NAME")" 'tolower($0) == n { print; exit }' <<<"$all_pods")"
if [ -z "$trunk_name" ]; then
  echo "$NAME isn't on CocoaPods trunk, so its first publisher here owns it"
  exit 0
fi
if [ "$trunk_name" != "$NAME" ]; then
  echo "$NAME differs only in letter case from $trunk_name, which is on CocoaPods trunk. Names that differ only in case can't be published here; if you own $trunk_name, publish it under that exact name."
  exit 1
fi

# --- Its latest podspec, and when trunk published that version ---
hash="$(md5_hex "$NAME")"
if ! index="$(fetch "$TRUNK_CDN_URL/all_pods_versions_${hash:0:1}_${hash:1:1}_${hash:2:1}.txt")" ||
  ! line="$(awk -F/ -v n="$NAME" '$1 == n' <<<"$index")" || [ -z "$line" ]; then
  echo "CocoaPods trunk couldn't be checked for $NAME"
  exit 2
fi
latest="$(tr '/' '\n' <<<"$line" | tail -n +2 | sort -V | tail -n 1)"
if ! spec="$(fetch "$TRUNK_CDN_URL/Specs/${hash:0:1}/${hash:1:1}/${hash:2:1}/$NAME/$latest/$NAME.podspec.json")" ||
  ! pod_info="$(fetch "$TRUNK_API_URL/pods/$NAME")"; then
  echo "CocoaPods trunk couldn't be checked for $NAME"
  exit 2
fi
git_url="$(jq -r '.source.git // empty' <<<"$spec" 2>/dev/null || true)"
homepage="$(jq -r '.homepage // empty' <<<"$spec" 2>/dev/null || true)"
owner_emails="$(jq -r '.owners[]?.email // empty' <<<"$pod_info" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
released="$(jq -r --arg v "$latest" '[.versions[]? | select(.name == $v) | .created_at][0] // empty | sub(" UTC$"; "Z") | sub(" "; "T")' <<<"$pod_info" 2>/dev/null || true)"
released_at="$(epoch "$released")"

is_owner_email() {
  [ -n "$1" ] && [ -n "$owner_emails" ] && grep -qxF "$(lower "$1")" <<<"$owner_emails"
}
# predates_release <ISO-8601 timestamp>: was it created before trunk published $latest?
predates_release() {
  local t
  t="$(epoch "$1")"
  [ -n "$t" ] && [ -n "$released_at" ] && [ "$t" -lt "$released_at" ]
}

user="$(github_api "user/$AUTHOR_ID" 2>/dev/null || true)"

# --- 1. Their public email is a trunk owner's ---
if [ -n "$user" ] && is_owner_email "$(jq -r '.email // empty' <<<"$user")"; then
  echo "$LOGIN's public GitHub email is an owner of $NAME on CocoaPods trunk"
  exit 0
fi

repo="$(github_repo "$git_url")"
[ -z "$repo" ] && repo="$(github_repo "$homepage")"
repo_info=""
if [ -n "$repo" ] && repo_info="$(github_api "repos/$repo" 2>/dev/null)"; then
  # A renamed or transferred repository answers under its new name.
  full_name="$(jq -r '.full_name // empty' <<<"$repo_info")"
  [[ "$full_name" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && repo="$full_name"
fi

# --- 2. GitHub credits them with commits made with a trunk owner's email ---
if [ -n "$repo_info" ] && commits="$(github_api "repos/$repo/commits?author=$LOGIN&per_page=100" 2>/dev/null)"; then
  while IFS= read -r email; do
    if is_owner_email "$email"; then
      echo "GitHub credits $LOGIN with commits to github.com/$repo made with the email of an owner of $NAME on CocoaPods trunk"
      exit 0
    fi
  done < <(jq -r --argjson id "$AUTHOR_ID" '.[]? | select(.author.id? == $id) | .commit.author.email // empty' <<<"$commits" 2>/dev/null || true)
fi

# --- 3 & 4 need a repository that predates the trunk release ---
genuine=false
if [ -n "$repo_info" ]; then
  owner_id="$(jq -r '.owner.id // empty' <<<"$repo_info")"
  owner_login="$(jq -r '.owner.login // empty' <<<"$repo_info")"
  if [ "$owner_id" = "$AUTHOR_ID" ]; then
    owner_created="$(jq -r '.created_at // empty' <<<"$user")"
  elif [[ "$owner_login" =~ ^[A-Za-z0-9-]+$ ]]; then
    owner_created="$(github_api "users/$owner_login" 2>/dev/null | jq -r '.created_at // empty' 2>/dev/null || true)"
  else
    owner_created=""
  fi
  if predates_release "$(jq -r '.created_at // empty' <<<"$repo_info")" && predates_release "$owner_created"; then
    genuine=true
  fi

  # --- 3. They own the repository ---
  if [ "$genuine" = true ] && [ "$owner_id" = "$AUTHOR_ID" ]; then
    echo "$LOGIN owns github.com/$repo, the repository CocoaPods trunk's $NAME $latest points to, and both predate that release"
    exit 0
  fi

  # --- 4. The repository lists them in .zorvok-owners ---
  if [ "$genuine" = true ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    if with_timeout git clone -q --depth 1 --filter=blob:none --no-checkout -- "$GITHUB_SERVER_URL/$repo.git" "$tmp/repo" >/dev/null 2>&1 &&
      git -C "$tmp/repo" show HEAD:.zorvok-owners 2>/dev/null |
      sed 's/#.*//' | awk 'NF { print tolower($1) }' | grep -xF -e "$AUTHOR_ID" -e "$LOGIN_LC" >/dev/null; then
      echo "github.com/$repo lists $LOGIN in .zorvok-owners"
      exit 0
    fi
  fi
fi

echo "$NAME already exists on CocoaPods trunk, and only its owners there can publish it here; $LOGIN couldn't be matched to one. Any one of these proves it, checked automatically the next time you run zorvok trunk push:"
echo "  - make the email you registered with \`pod trunk register\` the public email on your GitHub profile"
if [ -n "$repo_info" ]; then
  if [ "$genuine" = true ]; then
    echo "  - publish from the GitHub account that owns github.com/$repo"
    echo "  - add a file named .zorvok-owners containing your GitHub user ID ($AUTHOR_ID) to the default branch of github.com/$repo"
  else
    echo "  - (github.com/$repo, or the account that owns it, was created after CocoaPods trunk published $NAME $latest, so it can't vouch for the pod)"
  fi
fi
exit 1
