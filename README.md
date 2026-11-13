# Zorvok Specs: the free public pod registry for Zorvok

The public pod registry for [Zorvok](https://github.com/zorvok-dev/zorvok-ios), the CocoaPods-compatible dependency manager for iOS. Publish new pods here with one command, including new versions of pods that are already on CocoaPods trunk, which stops accepting new versions on December 2, 2026.

This repository *is* the registry: no server, no database, no hosting bill. A published pod is its podspec, as JSON, committed to git and served in CocoaPods' own CDN format, so plain `pod install` can read it too.

**Publish a pod** (details in [Publishing a package](#publishing-a-package)):

```bash
gh auth login        # once
zorvok trunk push    # in your pod's folder
```

**Install one** (details in [Consuming this registry](#consuming-this-registry)):

```ruby
pod 'MyPod', :source => 'https://raw.githubusercontent.com/zorvok-dev/zorvok-specs/main/'
```

Publishing is fully automatic, like trunk.cocoapods.org: a GitHub Actions check accepts or rejects every publish in about a minute, and nobody reviews anything by hand. Names that already exist on CocoaPods trunk stay with their trunk owners.

## Why this repository exists

CocoaPods' own public registry (`cdn.cocoapods.org`) is a CDN backed by a large, continuously-updated index of `Specs/` served over HTTP. Zorvok's design goal (see [zorvok-dev/zorvok-ios](https://github.com/zorvok-dev/zorvok-ios)) is to let projects adopt an independent registry **without forking that model**: the same protocol, the same directory shape, just a different place to publish a name you control.

Running that as a live server costs money and needs operating. This repository proves it doesn't have to: CocoaPods' CDN source protocol only needs a handful of static files reachable over HTTP, and git + GitHub already provide exactly that, for free, with pull requests as the natural publish/review workflow. A second, self-hostable option that *is* a live server — for teams that want a private registry or SSO-gated access — exists separately at `zorvok-registry-ios`.

## Where this fits: Zorvok's three-tier registry model

Zorvok resolves dependencies from any CocoaPods-compatible source, with no special-casing per source. A Podfile (or `zorvok config`) can point at any combination of these, simultaneously:

| Tier | What | Who runs it | Cost |
|---|---|---|---|
| 1 | `cdn.cocoapods.org` — CocoaPods' own registry | The CocoaPods project | Free, already there |
| 2 | **This repository** — Zorvok's free public registry | The Zorvok project, as static files in git | Free (GitHub-hosted) |
| 3 | `zorvok-registry-ios` — a self-hostable registry server | You, for a private/enterprise registry | Whatever you host it on |

This split is deliberately analogous to Maven Central + a self-hosted Nexus/Artifactory: one free shared public index, plus the option to run your own for anything that shouldn't be public. From the client's point of view, all three are just a `source` URL — `zorvok install` (or plain `pod install`) doesn't know or care whether what answers at that URL is CocoaPods' CDN, this git repository, or a running Go server.

## Repository layout

```
CocoaPods-version.yml        # registry metadata: min/last supported CocoaPods version, prefix_lengths
all_pods.txt                  # one pod name per line — regenerated automatically on every merge
all_pods_versions.txt         # "<name>/<v1>/<v2>/..." per line — regenerated automatically on every merge
Specs/
  <PodName>/
    OWNERS                    # "<GitHub user ID> <username>" per line — who may publish new versions of this pod
    <version>/
      <PodName>.podspec.json  # the published podspec, as submitted, verbatim — never modified after merge
scripts/
  validate-pr.sh              # enforces immutability/structure/ownership on every publish PR
  publish-policy.sh           # the rest of what trunk checks: publish or reject, no human in the loop
  verify-trunk-owner.sh       # only a pod's CocoaPods trunk owners may publish it here
  generate-index.sh           # rebuilds all_pods.txt / all_pods_versions.txt from the Specs/ tree
  push-index.sh               # regenerates the index on the latest main and pushes it, retrying on races
  test-validate-pr.sh         # repeatable local test harness for validate-pr.sh (run it: no setup needed)
  test-publish-policy.sh      # repeatable local test harness for publish-policy.sh (same)
  test-publish-workflow.sh    # runs publish.yml's own script on simulated pull requests, against live trunk data
.github/workflows/
  publish.yml                 # judges every publish PR: publishes or closes it, comments a verdict
  regenerate-index.yml        # regenerates the index after anything else lands on main
```

This is exactly the file shape the real CocoaPods CDN protocol expects (`prefix_lengths: []` — this registry has nowhere near `cdn.cocoapods.org`'s scale, so there is no need for the MD5-sharded directory layout the real CDN uses to keep any one directory from growing too large). It is implemented and tested against the real protocol in `zorvok-registry-ios`'s `cdn` package, which serves the identical shape from a live server instead of static files — the same client code resolves either one.

## Consuming this registry

### With Zorvok

```bash
# One-off, for a single run:
zorvok install --native --source https://raw.githubusercontent.com/zorvok-dev/zorvok-specs/main/

# Or configure it once and let Zorvok federate it automatically from
# then on (zorvok ADR 0008) — no --source flag needed on future installs:
zorvok config set registry_url https://raw.githubusercontent.com/zorvok-dev/zorvok-specs/main/ --global
zorvok install --native

# Opt out of automatic federation for a single run, once configured:
zorvok install --native --no-registry
```

`--native` is required — plain `pod install` can't resolve a source that isn't declared in the Podfile (see [docs/adr/0004](https://github.com/zorvok-dev/zorvok-ios/blob/main/docs/adr/0004-federation-requires-podfile-source-line.md)). `zorvok install --native` drives CocoaPods' own installer directly and can inject an extra source in memory, without ever writing to your Podfile.

> **GitHub Pages note:** this repository is laid out to be served from `https://zorvok-dev.github.io/zorvok-specs/` once GitHub Pages is enabled for it (repo Settings → Pages → Deploy from branch, `main` / `/ (root)`); the Pages URL and the `raw.githubusercontent.com` URL above are then interchangeable. Until then, use the `raw.githubusercontent.com` URL.
>
> **Known issue:** while the registry has no pods yet, raw.githubusercontent.com occasionally answers an install's first request for `all_pods_versions.txt` with HTTP 501. Running the install again works.

### With plain CocoaPods (`pod`)

Nothing Zorvok-specific is required: this is a standard CocoaPods CDN source. Point each pod you take from it at it with `:source =>`, and leave every other pod on CocoaPods' default source:

```ruby
target 'MyApp' do
  pod 'SomePodPublishedHere', '1.0.0', :source => 'https://raw.githubusercontent.com/zorvok-dev/zorvok-specs/main/'
end
```

```bash
pod install
```

> **Pin, don't add a global `source` line.** With several `source` lines, CocoaPods merges every source's versions of a pod and picks the highest. Anyone can publish a pod name here that isn't on CocoaPods trunk, so if your company's private spec repo has a pod that isn't on trunk either, someone could publish a higher version of the same name here, and a Podfile that lists both sources as `source` lines would install theirs (a "dependency confusion" attack). A `:source =>` pin takes that pod from exactly one source.

### Browsing without installing anything

```bash
curl https://raw.githubusercontent.com/zorvok-dev/zorvok-specs/main/all_pods.txt
curl https://raw.githubusercontent.com/zorvok-dev/zorvok-specs/main/Specs/<PodName>/<version>/<PodName>.podspec.json
```

## Publishing a package

Publishing is one command, like `pod trunk push`, and it's fully automatic: no maintainer reviews anything. Only the podspec goes into this registry; your pod's code, frameworks and xcframeworks stay wherever its `source` points.

```bash
gh auth login        # once: publishing uses your GitHub account (or set GITHUB_TOKEN)
cd /path/to/your/pod
zorvok trunk push    # or: zorvok trunk push MyPod.podspec
```

`zorvok trunk push` lints the podspec and converts it to JSON with `pod ipc spec`; this registry stores only that evaluated JSON, never Ruby, so nothing here is ever executed. It opens a pull request from your fork that adds `Specs/<PodName>/<version>/<PodName>.podspec.json`, plus `Specs/<PodName>/OWNERS` listing your GitHub user ID and username on a pod's first publish. Then it waits, usually about a minute, for [the publish workflow](.github/workflows/publish.yml) to decide:

- **Published.** It passed every rule below, so the workflow added its files to `main` and regenerated the index. It's installable within 5 minutes (GitHub caches these files that long).
- **Rejected.** `zorvok trunk push` prints exactly why. Fix it and run `zorvok trunk push` again.

Either way the workflow then closes the pull request. It publishes the checked files as its own commit, never the pull request's commits, so a published pull request shows as closed, not merged; its verdict comment says which it was.

The rules are the ones trunk.cocoapods.org enforces:

- **Immutability** — a pull request may only *add* files under `Specs/<name>/<version>/`; modifying or deleting an already-published version's files is rejected. A published version is permanent, exactly as it is on `zorvok-registry-ios` (`ErrVersionExists`) and on `cdn.cocoapods.org` itself.
- **Structure** — every added `*.podspec.json` must be valid JSON whose `name`/`version` fields match the path it was added at.
- **Ownership** — if `Specs/<PodName>/OWNERS` already exists, the pull request's author must already be listed in it. That's judged against the registry as it is when the workflow runs, never against the commit the pull request happens to be based on (which its author chooses), so an owner who has been removed can't publish from an old branch. You can't add yourself to `OWNERS` and publish a new version of someone else's pod in the same pull request. A new pod's first publisher becomes its owner: first publisher wins, the same rule `zorvok-registry-ios` enforces with a database constraint.
- **Owners are GitHub user IDs.** Each `OWNERS` line is `<GitHub user ID> <username>`, and only the ID counts. A GitHub username can be renamed and then registered by someone else; the numeric ID never changes and is never reused. `zorvok trunk push` writes the line for you.
- **Pods that exist on CocoaPods trunk stay with their owners.** If the name is already on CocoaPods trunk, only one of its owners there can publish it here. Trunk knows its owners by the email they registered with `pod trunk register`, so, as on trunk, you prove you're one by controlling that email. It's checked against trunk's own records and what GitHub has verified about your account, never against anything in the pull request, and either of these counts:
  - that email is the public email on your GitHub profile (GitHub only lets a verified address be public);
  - GitHub credits your account with commits to the pod's repository made with that email. GitHub credits a commit only to the account that has verified its email, so this works with a private email too, and it's already true for most pod authors.

  Owning the pod's repository doesn't count on its own. GitHub doesn't record who held a username before, so after an owner renames or deletes their account, someone else can rename an old account and repository of theirs into the freed names, and nothing tells the two apart. A name that differs from a trunk pod's only in case, like `alamofire`, is refused outright. If neither proof matches, `zorvok trunk push` says how to add the email to your GitHub account. Once a pod's first version is published here, its later versions follow the Ownership rule above.
- **No `prepare_command`**, which runs shell commands on every machine that installs the pod. CocoaPods trunk stopped accepting it in May 2025.
- **One pod per pull request, podspecs and owners only.** A publish may add one pod's podspecs and change its `OWNERS`, and nothing else in this repository. Every file must be a plain file (no symlinks, submodules or executables), and every podspec exactly one JSON object.
- **Only the author updates a pull request.** If anyone else pushes to it, it's rejected, since everything in it is judged as its author's.
- **No look-alike names.** A new pod's name can't differ from a pod already here only in case.

`scripts/validate-pr.sh` enforces the first four; `scripts/publish-policy.sh` and `scripts/verify-trunk-owner.sh` enforce the rest. `scripts/test-validate-pr.sh` and `scripts/test-publish-policy.sh` exercise them against real git repositories and local stand-ins for CocoaPods trunk and GitHub; run them any time, with no setup. `scripts/test-publish-workflow.sh` runs the workflow's own script end to end on simulated pull requests, including an attack by a removed owner, against live CocoaPods trunk and GitHub data. The workflow YAML itself hasn't run on GitHub Actions yet, so if you're among the first to publish, watch the Actions run on your pull request and report anything unexpected.

### Adding a co-owner

Open a pull request that adds a line for them to `Specs/<PodName>/OWNERS`: their GitHub user ID, a space, and their username. Look up the ID with `gh api users/<username> --jq .id`, or at `https://api.github.com/users/<username>`. Lines starting with `#` are comments.

```
# Specs/MyPod/OWNERS
1019875 onevcat
583231 octocat
```

If you're already listed, it's published automatically, like `pod trunk add-owner`. Removing someone works the same way, as long as at least one owner remains.

### Publishing by hand

A pull request you open yourself goes through exactly the same workflow:

1. Convert the podspec: `zorvok ipc spec MyPod.podspec > MyPod.podspec.json` (or `pod ipc spec`).
2. Add it at `Specs/<PodName>/<version>/<PodName>.podspec.json`, where `<PodName>` and `<version>` exactly match the JSON's `name` and `version`.
3. First time publishing `<PodName>`? Also add `Specs/<PodName>/OWNERS` with a `<GitHub user ID> <username>` line for yourself (see above).
4. Open the pull request. The workflow comments its verdict on it, then publishes it or closes it.

## Relationship to the rest of Zorvok

- [zorvok-dev/zorvok-ios](https://github.com/zorvok-dev/zorvok-ios) — the `zorvok` CLI: install/update, `trunk push`/`trunk register`/`trunk add-owner`/etc., and the full CocoaPods-compatible command set. Start there for anything about the client itself.
- `zorvok-registry-ios` — the self-hostable registry server (Tier 3), for a private or enterprise registry, with ownership management and deprecation through the `zorvok trunk` commands.

## Scope

Zorvok and this registry are iOS-only. No Android, Maven, or Gradle functionality is in scope.

## License

MIT — see [LICENSE](LICENSE).
