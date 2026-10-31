# specs

Zorvok's official public package registry — **Tier 2** of Zorvok's three-tier registry model, see
[zorvok ADR 0009](https://github.com/zorvok-dev/zorvok/blob/main/docs/adr/0009-three-tier-registry-model.md).

Unlike `zorvok-registry` (a live server, for private/enterprise use), this is just files in git, served free via GitHub Pages (or even just a plain `git clone`/`raw.githubusercontent.com`) — Zorvok's own public registry costs nothing to run.

## Format

Identical to the real CocoaPods CDN protocol, already implemented against and tested in [`zorvok-registry/cdn`](https://github.com/zorvok-dev/zorvok-registry/tree/main/cdn):

```
CocoaPods-version.yml       # min/last/prefix_lengths (prefix_lengths: [] — no sharding; this registry is nowhere near cdn.cocoapods.org's scale)
all_pods.txt                 # one pod name per line (regenerated, see below)
all_pods_versions.txt        # "<name>/<v1>/<v2>/..." per line (regenerated, see below)
Specs/
  <PodName>/
    OWNERS                    # one GitHub identity per line
    <version>/
      <PodName>.podspec.json  # the published podspec, verbatim
```

## Publishing

There's no `zorvok trunk push` wired to this repo yet (tracked as follow-up — see ADR 0009's Consequences). For now, publishing is a pull request:

1. Add `Specs/<PodName>/<version>/<PodName>.podspec.json` (the podspec's JSON form, e.g. from `pod ipc spec`).
2. If `<PodName>` is new, also add `Specs/<PodName>/OWNERS` listing your GitHub username — this establishes ownership (first publisher wins, same rule the self-hosted `zorvok-registry` enforces with a database constraint).
3. Open a PR. `.github/workflows/validate-pr.yml` checks, before merge:
   - **Immutability**: your PR may only *add* files under `Specs/<name>/<version>/`, never modify or delete one.
   - **Structure**: the podspec must be valid JSON, and its `name`/`version` fields must match the path.
   - **Ownership**: if `<PodName>` already has an `OWNERS` file, your GitHub username must already be listed in it (as it existed *before* your PR — you can't add yourself and publish in the same PR for a pod you don't already own).
4. On merge, `.github/workflows/regenerate-index.yml` rebuilds `all_pods.txt`/`all_pods_versions.txt` automatically.

The actual validation logic lives in `scripts/validate-pr.sh` and `scripts/generate-index.sh` — both tested locally against real git repos and real pass/fail scenarios (ownership hijack attempts, immutability violations, malformed podspecs) before being wired into the workflow YAML above. **The workflow YAML itself hasn't been run against real GitHub Actions yet** — verify it on the first real PR.

## Using this registry

```bash
zorvok install --native --source https://zorvok-dev.github.io/specs/
# or, once registry_url is configured, automatically (zorvok ADR 0008):
zorvok config set registry_url https://zorvok-dev.github.io/specs/ --global
zorvok install --native
```

See [zorvok-dev/zorvok](https://github.com/zorvok-dev/zorvok) for the CLI.
