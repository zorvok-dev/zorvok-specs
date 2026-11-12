#!/usr/bin/env bash
# Decides, with no human in the loop, whether a GitHub user may publish a
# pod here whose name already exists on CocoaPods trunk (zorvok ADR 0010).
# The rule is CocoaPods' own: only an existing owner of the pod on trunk
# can publish its new versions. CocoaPods never has to check this across
# registries; this one has to, or anyone could claim `Alamofire` here
# before its authors do.
#
# All the evidence comes from CocoaPods trunk and GitHub, never from the
# pull request: trunk's API lists the pod's owners (by email), and the
# latest podspec published there names the pod's repository and homepage.
# <login> may publish the pod if any one of these holds:
#
#   1. <login>'s GitHub profile shows, as its public email, one of the
#      pod's trunk owners' emails (GitHub only lets a verified address be
#      public);
#   2. GitHub credits <login> with commits in the pod's repository made
#      with one of those emails (it only credits an account with commits
#      whose email belongs to that account, so this works with a hidden
#      email too);
#   3. that repository is owned by <login>'s GitHub account;
#   4. it's owned by a GitHub organization <login> is a public member of;
#   5. the repository's default branch has a `.zorvok-owners` file listing
#      <login> (one GitHub username per line); or
#   6. the homepage's site serves /.well-known/zorvok-owners listing <login>.
#
# 1 and 2 prove <login> is a trunk owner; 3 to 6 prove they control what
# the trunk owners published, for owners whose trunk email isn't linked to
# their GitHub account. A name that isn't on CocoaPods trunk needs no
# evidence: its first publisher here owns it, as on trunk.
#
# Usage: verify-trunk-owner.sh <name> <github-login>
# Exits 0 if <login> may publish <name> (saying why), 1 if not (saying how
# to prove it), 2 if CocoaPods trunk couldn't be checked.
#
# Only reads: fetches over HTTPS and makes a shallow, blob-less clone,
# never running anything from it. Test overrides: TRUNK_CDN_URL,
# TRUNK_API_URL, GITHUB_API_URL, GITHUB_SERVER_URL (GitHub Actions sets the
# last two to the real services; the defaults below match) and
# GIT_ALLOW_PROTOCOL. GH_TOKEN, if set, authenticates GitHub API calls.

set -euo pipefail

NAME="${1:?usage: verify-trunk-owner.sh <name> <github-login>}"
LOGIN="${2:?usage: verify-trunk-owner.sh <name> <github-login>}"
TRUNK_CDN_URL="${TRUNK_CDN_URL:-https://cdn.cocoapods.org}"
TRUNK_API_URL="${TRUNK_API_URL:-https://trunk.cocoapods.org/api/v1}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
export GIT_ALLOW_PROTOCOL="${GIT_ALLOW_PROTOCOL:-https}"
export GIT_TERMINAL_PROMPT=0

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
  curl -fsSL --max-time 20 "$@"
}

github_api() {
  if [ -n "${GH_TOKEN:-}" ]; then
    fetch -H "Authorization: Bearer $GH_TOKEN" "$GITHUB_API_URL/$1"
  else
    fetch "$GITHUB_API_URL/$1"
  fi
}

# lists_login: does stdin list LOGIN? One GitHub username per line,
# compared case-insensitively (GitHub usernames are), ignoring blanks,
# whitespace and # comments.
lists_login() {
  tr '[:upper:]' '[:lower:]' | sed -e 's/#.*//' -e 's/[[:space:]]//g' | grep -xF "$LOGIN_LC" >/dev/null
}

# github_repo <url>: "owner/repo" if url points into a GitHub repository.
github_repo() {
  local u="${1%/}"
  if [[ "$u" =~ ^(https?://|git@|ssh://git@)(www\.)?github\.com[:/]+([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+) ]]; then
    printf '%s/%s' "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]%.git}"
  fi
}

with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    "$@"
  fi
}

# --- Is the name on trunk, and what's its latest podspec there? ---
hash="$(md5_hex "$NAME")"
if ! index="$(fetch "$TRUNK_CDN_URL/all_pods_versions_${hash:0:1}_${hash:1:1}_${hash:2:1}.txt")"; then
  echo "CocoaPods trunk couldn't be checked for $NAME"
  exit 2
fi
line="$(awk -F/ -v n="$NAME" '$1 == n' <<<"$index")"
if [ -z "$line" ]; then
  echo "$NAME isn't on CocoaPods trunk, so its first publisher here owns it"
  exit 0
fi
latest="$(tr '/' '\n' <<<"$line" | tail -n +2 | sort -V | tail -n 1)"
if ! spec="$(fetch "$TRUNK_CDN_URL/Specs/${hash:0:1}/${hash:1:1}/${hash:2:1}/$NAME/$latest/$NAME.podspec.json")"; then
  echo "CocoaPods trunk couldn't be checked for $NAME"
  exit 2
fi
git_url="$(jq -r '.source.git // empty' <<<"$spec" 2>/dev/null || true)"
homepage="$(jq -r '.homepage // empty' <<<"$spec" 2>/dev/null || true)"

repo="$(github_repo "$git_url")"
[ -z "$repo" ] && repo="$(github_repo "$homepage")"
repo_info=""
if [ -n "$repo" ] && repo_info="$(github_api "repos/$repo" 2>/dev/null)"; then
  # A renamed or transferred repository answers under its new name.
  full_name="$(jq -r '.full_name // empty' <<<"$repo_info")"
  [ -n "$full_name" ] && repo="$full_name"
fi

# --- 1 & 2: <login> is one of the pod's owners on CocoaPods trunk ---
owner_emails=""
if pod_info="$(fetch "$TRUNK_API_URL/pods/$NAME" 2>/dev/null)"; then
  owner_emails="$(jq -r '.owners[]?.email // empty' <<<"$pod_info" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
fi
is_owner_email() {
  [ -n "$1" ] && [ -n "$owner_emails" ] && grep -xF "$(lower "$1")" <<<"$owner_emails" >/dev/null
}
if [ -n "$owner_emails" ]; then
  if user="$(github_api "users/$LOGIN" 2>/dev/null)" && is_owner_email "$(jq -r '.email // empty' <<<"$user")"; then
    echo "$LOGIN's public GitHub email is an owner of $NAME on CocoaPods trunk"
    exit 0
  fi
  if [ -n "$repo" ] && commits="$(github_api "repos/$repo/commits?author=$LOGIN&per_page=100" 2>/dev/null)"; then
    while IFS= read -r email; do
      if is_owner_email "$email"; then
        echo "GitHub credits $LOGIN with commits to github.com/$repo made with the email of an owner of $NAME on CocoaPods trunk"
        exit 0
      fi
    done < <(jq -r --arg login "$LOGIN_LC" '.[]? | select(((.author.login // "") | ascii_downcase) == $login) | .commit.author.email // empty' <<<"$commits" 2>/dev/null || true)
  fi
fi

# --- 3 & 4: the GitHub repository's owner ---
clone_url="$git_url"
if [ -n "$repo" ]; then
  if [ -n "$repo_info" ]; then
    owner="$(jq -r '.owner.login // empty' <<<"$repo_info")"
    owner_type="$(jq -r '.owner.type // empty' <<<"$repo_info")"
    if [ "$owner_type" = "User" ] && [ "$(lower "$owner")" = "$LOGIN_LC" ]; then
      echo "$LOGIN owns github.com/$repo, the repository CocoaPods trunk's $NAME $latest points to"
      exit 0
    fi
    if [ "$owner_type" = "Organization" ] && github_api "orgs/$owner/public_members/$LOGIN" >/dev/null 2>&1; then
      echo "$LOGIN is a public member of $owner, which owns github.com/$repo, the repository CocoaPods trunk's $NAME $latest points to"
      exit 0
    fi
  fi
  clone_url="$GITHUB_SERVER_URL/$repo.git"
fi

# --- 5: a .zorvok-owners file in the repository ---
if [ -n "$clone_url" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  if with_timeout git clone -q --depth 1 --filter=blob:none --no-checkout "$clone_url" "$tmp/repo" >/dev/null 2>&1 &&
    git -C "$tmp/repo" show HEAD:.zorvok-owners 2>/dev/null | lists_login; then
    echo "$clone_url lists $LOGIN in .zorvok-owners"
    exit 0
  fi
fi

# --- 6: /.well-known/zorvok-owners on the homepage's site ---
site=""
if [[ "$homepage" =~ ^(https?://[^/?#]+) ]]; then
  site="${BASH_REMATCH[1]}"
  case "$(lower "$site")" in
    # GitHub's own sites never serve it; the repository checks above cover them.
    *://github.com | *://www.github.com | *.githubusercontent.com) site="" ;;
  esac
fi
if [ -n "$site" ] && fetch "$site/.well-known/zorvok-owners" 2>/dev/null | lists_login; then
  echo "$site/.well-known/zorvok-owners lists $LOGIN"
  exit 0
fi

echo "$NAME already exists on CocoaPods trunk, and only its owners there can publish it here; $LOGIN couldn't be matched to one. Any one of these proves it, checked automatically the next time you run zorvok trunk push:"
echo "  - make the email you registered with \`pod trunk register\` the public email on your GitHub profile"
[ -n "$repo" ] && echo "  - publish from the GitHub account that owns github.com/$repo, or make your membership of the organization that owns it public"
[ -n "$clone_url" ] && echo "  - add a file named .zorvok-owners listing $LOGIN to the default branch of $clone_url"
[ -n "$site" ] && echo "  - serve $site/.well-known/zorvok-owners listing $LOGIN"
exit 1
