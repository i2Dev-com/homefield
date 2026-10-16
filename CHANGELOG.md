# Changelog

Releases are exact semver tags, such as `v0.1.0`, and a tag is never moved.
Consumers pin an exact tag (`routing-guard@v0.1.0`) or a full commit SHA; see
[Versioning](README.md#versioning).

While the version is 0.x, a change that makes a previously passing workflow
fail, such as a new guard in the routing expression, bumps the minor version
(0.1 to 0.2). Compatible changes bump the patch. Merged changes wait on
`main`, under *Unreleased*, until a release is cut.

## Unreleased

### Changed

- The README installs with `curl` now that the repository is public, and
  `homefield version` prints the same `curl` one-liner when an update is
  available, in place of the `gh api` one.

## v0.1.0 (2026-10-16)

First public release.

- **An isolated runner VM.** Ubuntu 24.04 arm64 in [Lima](https://lima-vm.io)
  with no host mounts, no SSH-agent forwarding and no forwarding of guest
  ports to the Mac. Setup verifies the isolation before it continues. The
  runner is checksum-pinned, with timers for workspace cleanup and idle-time
  OS updates, extra apt packages (`--packages`) and hooks in
  `/etc/homefield/provision.d/`.
- **One-command setup.** `install.sh` installs the tool and Lima, then
  `homefield install`, `upgrade`, `status` and `uninstall` manage the VM and
  the runner registration.
- **Runner group.** For an organization, `homefield install` creates the
  `homefield-ci` runner group (selected repositories only, no public ones),
  or uses an existing one with `--group-exists` when `gh` cannot list groups.
- **Adopting repositories.** `homefield adopt --repo <owner>/<repo>` checks a
  repository's routing and guard, and only then adds it to the runner group
  and switches it to the local runner. It refuses a public repository.
  `homefield route hosted|local` switches repositories back and forth, and
  re-runs runs that were stuck waiting for the local runner.
- **Routing options.** `--events`, `--dependabot` and `--fallback` on
  `homefield adopt`, with the same names on `routing-guard`: which events are
  routed (default `pull_request`), whether Dependabot is routed (default
  `hosted`) and the hosted image jobs fall back to (default `ubuntu-latest`).
  `--label` sets the routing label (default `homefield-ci`).
- **`routing-guard` action.** Fails CI unless every job that can reach the
  runner uses the one reviewed `runs-on` expression, with its guards, and the
  set of routed jobs is the reviewed list. `homefield adopt` counts a guard
  pinned to its own release or a full commit SHA, since it checks the
  workflow with its own copy of the guard's rules.
- **`homefield version`.** Shows the installed ref and commit, and checks
  through `gh` whether the ref has moved or a later release exists.
- **`homefield memory` and `homefield report`.** Per-day memory use and
  out-of-memory kills from the guest's per-minute log, and queue wait,
  duration and minutes of local against hosted jobs from the GitHub API.
