# Changelog

Releases are exact semver tags, such as `v0.1.0`, and a tag is never moved.
Consumers pin an exact tag (`routing-guard@v0.3.0`) or a full commit SHA; see
[Versioning](README.md#versioning).

While the version is 0.x, a change that makes a previously passing workflow
fail, such as a new guard in the routing expression, bumps the minor version
(0.1 to 0.2). Compatible changes bump the patch. Merged changes wait on
`main`, under *Unreleased*, until a release is cut.

## Unreleased

### Added

- The job-started hook also repairs the runner's own npm (#110). A runner
  self-update extracts its new `externals.<version>/` tree with symlinks
  followed (upstream actions/runner#2094, open since 2022): npm, npx and
  corepack arrive as regular files — copies of what the link should point at —
  and every JS action that shells out to npm, such as `pnpm/action-setup`,
  dies with `Cannot find module '../lib/cli.js'`. Before every job, the hook
  relinks a file that is byte for byte the flattened artifact back into the
  link, so a job never sees the flatten; anything else is left alone. It then
  runs `npm --version` under both bundled nodes: if npm is broken in some
  other way the job fails at *Set up runner* with that message instead of a
  cryptic error in its first step. `homefield status` reports an `npm:` line.

### Fixed

- `homefield adopt` reads the routing-guard step's `arch` and refuses one
  whose `arch:` is anything but `arm64`, the VM it sets up. Before, it checked
  every workflow against `arm64` whatever the step said: an `x64` guard step
  with matching `x64` expressions was reported as failing with nothing routed
  although CI passed, and an `amd64` one as ready although the guard refuses
  that value in CI. The guard check now runs with the step's own `arch`, so
  what adopt reports is what CI runs (#105).
- `homefield report` refuses incomplete fixture input with a message instead
  of a traceback: a fixture file that is missing, not JSON, or not keyed by
  repository, and jobs without a name or a created_at — fields the live API
  always supplies. Rows and totals share one queue-wait computation, so a
  total can no longer disagree with the sum of its rows. `tools/adopt.py`
  names a missing workflow directory the same way (#90).

### Changed

- The pinned runner version is 2.338.0 (from 2.337.0), the version the
  runners self-updated to on 2026-10-23. Re-provisioning no longer replaces
  the live 2.338.0 tree with 2.337.0 and waits for the runner to self-update
  again.

## v0.3.0 (2026-10-21)

Not a drop-in for v0.2.1, by the rule above: the routing guard now refuses an
`arch` other than `arm64` or `x64` (below). A workflow that leaves `arch` out,
or passes `arm64` or `x64`, is unaffected, and the expression and its
guarantees are unchanged. To upgrade, run the README's one-liner again, then
`homefield upgrade` on each runner while it is idle, which brings in the
provisioning fixes below. Bump `routing-guard@v0.2.1` pins to `@v0.3.0`:
`homefield adopt` counts only its own release.

### Changed

- **The routing guard refuses an `arch` other than `arm64` or `x64`**, as
  `--print-expression`, `--list` and a check, the way it already refuses a bad
  `label` or `fallback`. A typo such as `amd64` used to become the expression
  the guard enforced, so every job carrying it passed and then waited for a
  runner with that label, and a value with a quote in it added labels of its
  own. A workflow that passed `arch: ARM64` or any other value now fails,
  which is why this release is a minor one. `--list` and `--print-expression`
  now print a refused option on stderr, so their stdout holds only the jobs or
  the expression (#87).
- Restoring the runner's service has one implementation,
  `provision.sh ensure-service [--start]`, used after registration on every
  provisioning run, when a move is rolled back, and by `homefield uninstall`
  when deregistering fails. `uninstall` now copies `provision.sh` into the VM
  before it stops anything, so a VM provisioned by an older release gets the
  same restore. A provisioning run now also enables a runner service a cut-off
  uninstall left disabled (#99).
- The runbook's *More runners* section has an *Operating several runners*
  subsection: listing every runner through GitHub's API (online, busy, runner
  version), upgrading Mac by Mac, keeping extra packages and hooks alike on
  every VM, and that GitHub removes a runner offline for more than 14 days
  (the recovery is under Fixed, #76).
- The docs are shorter. The runbook's Setup leads with the one-liner and keeps
  the manual steps under *What `install` does, by hand*; the guard rules, the
  runner-group commands and the test list each live in one place and the other
  documents link to them. The routing expression is a full copy in README and
  in the adopting guide — consumers read each standalone — and
  `tests/adopt.sh` keeps the two copies equal. Nothing about
  behaviour changed.

### Fixed

- `provision.sh` has one EXIT trap. It removes the run's temp files (the
  runner tarball, the sudoers draft and the `.env` copies) on every exit, which
  used to stay in `/tmp` after a failed download, `visudo` check or service
  start. When a run that replaced the runner binary fails after changing
  `.env`, the previous `.env` is now put back with the runner's restart, as the
  comment promised; it used to be deleted. The saved package list
  (`/etc/homefield/extra-packages`) is checked like `RUNNER_EXTRA_PACKAGES`
  before it reaches apt-get. Reading the runner's name and URL for the last
  line no longer fails a run that has finished provisioning (#89).
- `homefield` and `install.sh` refuse an instance name (`--instance` or
  `HOMEFIELD_INSTANCE`) that Lima would not accept: letters and digits with a
  single `.`, `_` or `-` between them, at most 76 characters, not ending in
  `.yml` or `.yaml`. `HOMEFIELD_INSTANCE=--help` used to reach `limactl list`
  as an option, and install.sh read its output as "the VM exists".
  `install.sh` also refuses a download whose `bin/homefield` is not
  executable, which used to install and then fail with "Permission denied"
  (#86).
- A runner GitHub removed after 14 days offline is no longer reported as
  registered. `homefield status` checks GitHub's runner list by the runner's
  id when gh can read it, prints `github: listed`, `github: NOT listed` with
  the way to register it again, or `github: not checked`, and exits 1 when it
  is not listed. `upgrade` (and `install` on that VM) refuse before anything
  is stopped instead of failing at the end; `uninstall` removes only the VM's
  copy of the registration (`config.sh remove --local`, no token), so
  `uninstall --keep-vm` then `install --url ...` registers the VM again.
  Without gh, a provisioning run that fails because of it says so. Recovery
  is in docs/runbook.md, "Operating several runners" (#76).
- `homefield upgrade` and `uninstall` no longer stop with "Unit ... not
  loaded" when `.service` names a unit whose file is gone (an uninstall cut
  off partway): there is nothing to stop, so they go on, and `upgrade`
  repairs the service. Found on a throwaway VM; before this, the repair that
  #83 describes for this state never ran (#99).
- A first registration or a move no longer leaves the runner registered with
  no service when the workspace hook's setup fails: that setup now runs before
  registration (in a move, before the old registration is removed, so the old
  runner is started again), and the service is installed straight after it.
  `homefield uninstall` now also gives the service back (unit, `.service` and
  enabled at boot) when `svc.sh uninstall` fails partway, not only when GitHub
  refuses the removal. Running `homefield install` again now repairs a service
  left half done (a unit file with no `.service`, or the reverse) instead of
  failing the same way each time (#83).
- Moving a runner now reinstalls and starts its old service if service
  uninstall or registration removal fails, while the old registration still
  exists. `install --replace` documentation now states that it removes the
  old registration before provisioning, so a
  failure in between leaves that name unregistered (#81).
- `homefield adopt` no longer reads routing-guard text inside a `run:` script
  as a guard step, which could report "routing: ready" and switch a repository
  on with no guard. A step with `label:` set to nothing (which the guard
  refuses) or its `with:` on one line (which adopt does not read) is now
  reported as a problem instead of being read as the default label or as no
  options. When listing the routed jobs fails because `routing_guard.py` does
  not run, adopt stops with that instead of reporting an empty list (#79).
- `homefield uninstall`, `install` and `upgrade` no longer read a failed
  `limactl shell` as "the runner is not registered". `uninstall` used to
  delete the VM and leave the registration on GitHub; `install` with
  `--replace` could remove this VM's own registration. They now stop with
  "could not ask VM ..." and change nothing, and `status` prints
  "runner: unknown" and exits 1 (#80).
- `homefield upgrade` and `uninstall` no longer read a failed `limactl shell`
  as "no job is running" or "the runner has no service", which let them stop
  the runner under a live job (and, with `upgrade`, run provisioning, which can
  restart Docker). They stop with "could not ask VM ..." before anything is
  stopped, `--force` included: it overrides a job that is running, not a VM
  that cannot be reached. `status` prints "job: unknown" instead of "job:
  idle", after the rest of its report, and exits 1 (#82).
- The isolation check and the VM lookup no longer read a failed call as a safe
  answer. A `mount` that fails in the VM was counted as "no host mounts"; a
  failed `/Users` check was read as "cannot see it", and a failed `limactl
  list` as "no VM", so `install` could create a runner group and then fail to
  create a VM that exists. They stop with "could not run ..." or "could not
  ask Lima ...", and `status` prints "VM ...: unknown" and exits 1 (#85).
- `homefield adopt` warns when the runner group allows public repositories, as
  `install` already does, and says so in its summary line ("runner group added,
  but the group allows public repositories"). It read that setting and never
  used it, so a group wider than the docs describe passed silently (#84).

## v0.2.1 (2026-10-18)

Replaces v0.2.0, which is too strict and should not be pinned: its routing
guard failed compliant workflows because of their scripts (below). Nothing in
v0.2.0 is unsafe. Everything else in v0.2.0 is unchanged, so its upgrade notes
apply: run the README's one-liner again, then `homefield upgrade` on each
runner, and bump `routing-guard@v0.1.1` pins to `@v0.2.1`; `homefield adopt`
counts only its own release.

### Fixed

- The routing guard no longer fails a compliant workflow because of a script.
  v0.2.0 matched its unreadable-syntax checks on every line under `jobs:`, so a
  `run: |` script with a line starting with `?`, a bracket or an open quote
  (a multi-line quoted string, a here-document line) failed the guard; real
  workflows hit this in a dozen places. Lines under a block scalar (`|` or `>`)
  are text and are skipped, including one with an anchor or tag
  (`run: &script |`). A key written after the script is still checked.

## v0.2.0 (2026-10-18)

Not a drop-in for v0.1.x, by the rule above: the routing guard now fails on
workflow syntax it cannot read, and `homefield adopt` stops accepting a guard
with `continue-on-error: true`. A workflow written in the plain style (a
`job-id:` line, then `runs-on: ...` on a line of its own) is unaffected; the
expression and its guarantees are unchanged. To upgrade, run the README's
one-liner again, then `homefield upgrade` on each runner. Bump
`routing-guard@v0.1.1` pins to `@v0.2.0`: `homefield adopt` counts only its own
release. Two fixes below close ways to get a job onto the runner past the
guard; both affected v0.1.0 and v0.1.1.

### Fixed

- `homefield adopt` no longer accepts a routing guard that cannot fail the
  check. A guard step, or its job, with `continue-on-error: true` (or
  `${{ true }}`) passed adoption and then stayed green on a routing violation.
  It is now not a guard, as with `if: false`, and so is a reusable workflow
  whose callers all have it; a `continue-on-error` expression is a warning.
  Quoted keys (`"continue-on-error": true`) count the same.
  This affected v0.1.0 and v0.1.1.
- The routing guard fails on workflow syntax it cannot read, instead of passing
  it. It scans workflow files line by line, so a job whose `runs-on` was
  written another way (a quoted `"runs-on"` key, a job as a `{...}` mapping, a
  `<<` merge key, `? runs-on`, or a `jobs :` key with a space) was not seen,
  and an unguarded self-hosted job could sit beside two compliant ones with the
  guard green. It now fails and says to write the job plainly. This affected
  v0.1.0 and v0.1.1. `homefield adopt` shows the same reason.
- `homefield report` now counts a GitHub-hosted job that never got a runner
  (#64). A hosted job still queued, or cancelled before a runner was assigned,
  has no runner name and was dropped as if it had been skipped, so it never
  reached the "queued or running now" and "cancelled before starting" counts.
  It now does, when it asks for one of GitHub's standard images
  (`ubuntu-*`, `macos-*`, `windows-*`). A job that was actually skipped, that
  failed without a runner, or that targets a runner group or custom labels
  is still not counted.
- `homefield adopt` no longer rejects a guard in a reusable workflow because
  one of its callers is disabled (#62). A caller with `if: false` beside one
  that runs made adopt report that the guard never runs. It now blocks only
  when every caller is disabled.
- `homefield status` no longer stops after the VM line when the runner's
  settings can't be read (#63). Reading the name and URL from the runner's
  config failed on missing lines, and that ended the command before the
  "registered, but its details could not be read" line it is meant to print
  and before the service, job and version lines, which is when they are most
  useful.
- `homefield uninstall` no longer leaves a registered runner with no service
  when GitHub refuses the removal (#60). It uninstalls the service before it
  removes the registration, because `config.sh remove` refuses while the
  service exists; if the removal then failed, the runner was still registered
  but the unit it tried to start was gone. It now installs the service again
  and starts it, so the runner keeps taking jobs and `uninstall` can be run
  again.
- `provision.sh`, run by hand on a runner that is running, no longer leaves
  it stopped when it fails (#61). It stops the service to replace the runner
  binary, and only the replacement itself was covered: a failure after that,
  in the workspace hook, the sudo rule or `.env`, exited with the runner down
  and no job able to start. It now starts the service again on any failure
  until it starts it for good at the end. `bin/homefield upgrade` already did
  this from the Mac and is unchanged.

## v0.1.1 (2026-10-18)

Compatible with v0.1.0: the routing expression and `routing-guard`'s rules
are unchanged. To upgrade, run the README's one-liner again, then
`homefield upgrade` on each runner, which installs the workspace fix (#54).
Bump `routing-guard@v0.1.0` pins to `@v0.1.1`: `homefield adopt` counts only
its own release.

### Fixed

- A `container:` job no longer breaks the next job's checkout (#54). The job
  container runs as root, so it left root-owned files in the workspace, and
  the next job, as `runner`, failed to delete them with `EACCES`. Before every
  job, a job-started hook now gives `_work` back to `runner`, through a sudo
  rule for that one script. `bin/homefield upgrade` installs it and fixes
  the files left so far. Running `provision.sh` by hand on a running runner
  restarts it once, to load the hook, which cancels a job in progress.

- Installing on a second Mac with default settings no longer takes over the
  first Mac's runner (#52). Every Mac's default runner name was the guest
  hostname, `lima-homefield`, and registration replaced any runner of that
  name, so the first runner silently stopped working. `homefield install` now
  names the runner after the Mac and the instance (`<local
  hostname>-<instance>`), and before creating anything it refuses a name
  already registered in the scope: `--name` picks another, and the new
  `--replace` removes a stale registration right before registering.
  `provision.sh` no longer registers with `config.sh --replace`, so
  registration itself refuses a taken name when the runners list can't be
  read. `config.sh --replace` also kept the old registration's runner group
  and ignored the one asked for
  ([actions/runner#4091](https://github.com/actions/runner/issues/4091)),
  which could leave a runner in `Default`. Registered runners keep their
  names; nothing to do on upgrade.

### Changed

- The runbook has a *More runners* section: for more than one job at a time,
  add a runner as another VM on the same Mac (`--instance`) or on another
  Mac, with the same label and group. It covers the memory each VM holds,
  putting hooks in before the new runner registers, passing `--name` on
  another Mac with v0.1.0, and what changes once there are several.
- The README installs with `curl` now that the repository is public, and
  `homefield version` prints the same `curl` one-liner when an update is
  available, in place of the `gh api` one.
- `homefield version` checks for updates without `gh` too: it reads the
  public GitHub API with `curl`. `gh`, when installed, is still used first,
  since it can read a private fork.

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
