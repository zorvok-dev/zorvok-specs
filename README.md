# Zorvok Specs

The free, public package index for [Zorvok](https://github.com/zorvok-dev/zorvok-ios) — a CocoaPods-compatible dependency manager for iOS. This repository *is* the registry: there is no server, no database, and no hosting bill. A published package is a JSON file committed to git; the index is read by cloning this repo, fetching it over HTTPS, or (once enabled) through GitHub Pages.

If you only want to **use** packages from here, skip to [Consuming this registry](#consuming-this-registry). If you want to **publish** one, skip to [Publishing a package](#publishing-a-package).

## Why this repository exists

CocoaPods' own public registry (`cdn.cocoapods.org`) is a CDN backed by a large, continuously-updated index of `Specs/` served over HTTP. Zorvok's design goal (see [zorvok-dev/zorvok-ios](https://github.com/zorvok-dev/zorvok-ios)) is to let projects adopt an independent registry **without forking that model**: the same protocol, the same directory shape, just a different place to publish a name you control.

Running that as a live server costs money and needs operating. This repository proves it doesn't have to: CocoaPods' CDN source protocol only needs a handful of static files reachable over HTTP, and git + GitHub already provide exactly that, for free, with pull requests as the natural publish/review workflow. A second, self-hostable option that *is* a live server — for teams that want a private registry, SSO-gated access, or push-button publishing — exists separately at [zorvok-dev/zorvok-registry-ios](https://github.com/zorvok-dev/zorvok-registry-ios).

## Where this fits: Zorvok's three-tier registry model

Zorvok resolves dependencies from any CocoaPods-compatible source, with no special-casing per source. A Podfile (or `zorvok config`) can point at any combination of these, simultaneously:

| Tier | What | Who runs it | Cost |
|---|---|---|---|
| 1 | `cdn.cocoapods.org` — CocoaPods' own registry | The CocoaPods project | Free, already there |
| 2 | **This repository** — Zorvok's free public registry | The Zorvok project, as static files in git | Free (GitHub-hosted) |
| 3 | [zorvok-registry-ios](https://github.com/zorvok-dev/zorvok-registry-ios) — a self-hostable registry server | You, for a private/enterprise registry | Whatever you host it on |

This split (full rationale in [zorvok ADR 0009](https://github.com/zorvok-dev/zorvok-ios/blob/main/docs/adr/0009-three-tier-registry-model.md)) is deliberately analogous to Maven Central + a self-hosted Nexus/Artifactory: one free shared public index, plus the option to run your own for anything that shouldn't be public. From the client's point of view, all three are just a `source` URL — `zorvok install` (or plain `pod install`) doesn't know or care whether what answers at that URL is CocoaPods' CDN, this git repository, or a running Go server.

## Repository layout

```
CocoaPods-version.yml        # registry metadata: min/last supported CocoaPods version, prefix_lengths
all_pods.txt                  # one pod name per line — regenerated automatically on every merge
all_pods_versions.txt         # "<name>/<v1>/<v2>/..." per line — regenerated automatically on every merge
Specs/
  <PodName>/
    OWNERS                    # one GitHub username per line — who may publish new versions of this pod
    <version>/
      <PodName>.podspec.json  # the published podspec, as submitted, verbatim — never modified after merge
scripts/
  validate-pr.sh              # enforces immutability/structure/ownership on every publish PR
  generate-index.sh           # rebuilds all_pods.txt / all_pods_versions.txt from the Specs/ tree
.github/workflows/
  validate-pr.yml             # runs validate-pr.sh on every PR touching Specs/
  regenerate-index.yml        # runs generate-index.sh after every merge, commits the result
```

This is exactly the file shape the real CocoaPods CDN protocol expects (`prefix_lengths: []` — this registry has nowhere near `cdn.cocoapods.org`'s scale, so there is no need for the MD5-sharded directory layout the real CDN uses to keep any one directory from growing too large). It is implemented and tested against the real protocol in [`zorvok-registry-ios`'s `cdn` package](https://github.com/zorvok-dev/zorvok-registry-ios/tree/main/cdn), which serves the identical shape from a live server instead of static files — the same client code resolves either one.

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

`--native` is required to use an extra source: Zorvok's default, delegated `zorvok install` is a drop-in `pod install`, and `pod install` itself has no mechanism to resolve from a source that isn't declared in the Podfile (confirmed against real CocoaPods before this design was settled — see [ADR 0004](https://github.com/zorvok-dev/zorvok-ios/blob/main/docs/adr/0004-federation-requires-podfile-source-line.md)). `zorvok install --native` drives CocoaPods' own installer directly and can inject an extra source in memory, without ever writing to your Podfile.

> **GitHub Pages note:** this repository is laid out to be served from `https://zorvok-dev.github.io/zorvok-specs/` once GitHub Pages is enabled for it (repo Settings → Pages → Deploy from branch, `main` / `/ (root)`) — at that point the Pages URL and the `raw.githubusercontent.com` URL above are interchangeable. Until Pages is turned on, use the `raw.githubusercontent.com` URL shown above; it works today and needs no setup.

### With plain CocoaPods (`pod`)

Nothing Zorvok-specific is required — this is a standard CocoaPods CDN source. Add it to a Podfile exactly as you would any other private spec repo:

```ruby
source 'https://raw.githubusercontent.com/zorvok-dev/zorvok-specs/main/'
source 'https://cdn.cocoapods.org/'   # keep the default source for every other pod

target 'MyApp' do
  pod 'SomePodPublishedHere', '1.0.0'
end
```

```bash
pod install
```

### Browsing without installing anything

```bash
curl https://raw.githubusercontent.com/zorvok-dev/zorvok-specs/main/all_pods.txt
curl https://raw.githubusercontent.com/zorvok-dev/zorvok-specs/main/Specs/<PodName>/<version>/<PodName>.podspec.json
```

## Publishing a package

There is no server, so there is no `zorvok trunk push` against this registry yet (tracked as a follow-up in [ADR 0009](https://github.com/zorvok-dev/zorvok-ios/blob/main/docs/adr/0009-three-tier-registry-model.md)'s Consequences — `trunk push` today only publishes to a live `zorvok-registry-ios` server). Publishing here is a pull request, reviewed by the same rules a database would otherwise enforce:

1. **Produce the podspec's JSON form.** CocoaPods podspecs are Ruby; this registry stores only the evaluated, declarative JSON (never Ruby — nothing here ever gets executed), the same way `zorvok trunk push` does for a live registry:
   ```bash
   zorvok ipc spec MyPod.podspec > MyPod.podspec.json
   # or, equivalently, with plain CocoaPods:
   pod ipc spec MyPod.podspec > MyPod.podspec.json
   ```
2. **Add the file** at `Specs/<PodName>/<version>/<PodName>.podspec.json`, where `<PodName>` and `<version>` exactly match the `name`/`version` fields inside the JSON.
3. **First time publishing `<PodName>`?** Also add `Specs/<PodName>/OWNERS`, one line per GitHub username authorized to publish future versions — typically just yours. This is first-publisher-wins, the identical ownership rule `zorvok-registry-ios` enforces with a database constraint, enforced here by a PR check instead.
4. **Open a pull request.** `validate-pr.yml` runs `scripts/validate-pr.sh` and blocks the merge unless all of the following hold:
   - **Immutability** — the PR may only *add* files under `Specs/<name>/<version>/`; modifying or deleting an already-merged version's files is rejected. A published version is permanent, exactly as it is on `zorvok-registry-ios` (`ErrVersionExists`) and on `cdn.cocoapods.org` itself.
   - **Structure** — every added `*.podspec.json` must be valid JSON whose `name`/`version` fields match the path it was added at.
   - **Ownership** — if `Specs/<PodName>/OWNERS` already exists (as of the PR's base commit, not the PR's own diff), your GitHub username must already be listed in it. You cannot add yourself to `OWNERS` and publish a new version of someone else's pod in the same PR.
5. **On merge**, `regenerate-index.yml` rebuilds `all_pods.txt`/`all_pods_versions.txt` from the current `Specs/` tree and commits the result automatically — you don't update those files yourself.

`scripts/validate-pr.sh`'s logic has been exercised locally against real git repositories and real pass/fail scenarios: a valid first publish, a valid update by an existing owner, a rejected non-owner publish, a rejected ownership-hijack attempt (adding yourself to `OWNERS` in the same PR as a publish), a rejected immutability violation, a rejected name/version mismatch, and a rejected malformed-JSON podspec. The GitHub Actions YAML wiring itself (`validate-pr.yml`/`regenerate-index.yml`) has not yet been exercised against a real PR on `github.com` — if you're the first to publish here, watch the Actions run on your PR and report anything unexpected.

## Relationship to the rest of Zorvok

- [zorvok-dev/zorvok-ios](https://github.com/zorvok-dev/zorvok-ios) — the `zorvok` CLI: install/update, `trunk push`/`trunk register`/`trunk add-owner`/etc., and the full CocoaPods-compatible command set. Start there for anything about the client itself.
- [zorvok-dev/zorvok-registry-ios](https://github.com/zorvok-dev/zorvok-registry-ios) — the self-hostable registry server (Tier 3), for a private or enterprise registry with live publishing via `zorvok trunk push`, ownership management, and deprecation — everything this static repository can't do on its own.

## Scope

Zorvok and this registry are iOS-only. No Android, Maven, or Gradle functionality is in scope.

## License

MIT — see [LICENSE](LICENSE).
