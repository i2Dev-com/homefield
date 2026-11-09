# Changelog

Releases are exact semver tags, such as `v0.1.0`, and a tag is never moved.
Consumers pin an exact tag (`routing-guard@v0.3.0`) or a full commit SHA; see
[Versioning](README.md#versioning).

While the version is 0.x, a change that makes a previously passing workflow
fail, such as a new guard in the routing expression, bumps the minor version
(0.1 to 0.2). Compatible changes bump the patch. Merged changes wait on
`main`, under *Unreleased*, until a release is cut.

## Unreleased

Enables Rosetta in the VM ([#21](https://github.com/i2Dev-com/homefield/issues/21)):
x86-64 Linux binaries and `linux/amd64` container images run in the arm64
guest, translated by Apple's Rosetta. Compatible for consumers: the routing
expression, the guard and every default are unchanged, and jobs keep routing
with `arch: arm64`. Applies to VMs created after this change — an existing VM
keeps its stored config, so recreate it to get Rosetta
(`bin/homefield uninstall --instance <name>`, then `install` again). The
installer's download is curl-first: the public repository needs no `gh`, so
the tarball comes from GitHub's public codeload endpoint and `gh api` is only
the fallback, which keeps a private `HOMEFIELD_REPO` fork installable.

### Added

- Rosetta in the VM: `vm/lima.yaml` sets `vmOpts.vz.rosetta` (enabled +
  binfmt, the current form — the top-level `rosetta:` key is deprecated since
  Lima 2.0). A job that needs an amd64 binary or image now works:
  `docker run --platform linux/amd64 ...` and x86-64 ELF files run as they
  are. Measured (2026-11-09): translated process spawns are ~9x native, so
  this is for the occasional amd64 job, not the default route. Requires
  macOS ≥ 13; Lima installs the Rosetta runtime itself when missing.
- The isolation probe knows the one expected host mount this adds: Apple's
  read-only Rosetta share (`vz-rosetta on /mnt/lima-rosetta type virtiofs`,
  Apple's two runtime files, writes refused). It excludes that exact line,
  once — a rosetta line at another path, a second one, and every other
  virtiofs/9p/sshfs/reverse-sshfs mount still refuse. The "no host mounts"
  claims in README, runbook and SECURITY.md now say "no host data mounts"
  with the share named.

### Changed

- `install.sh` downloads the tarball with `curl` first, from GitHub's public
  codeload endpoint — the default repository is public, so no `gh` and no
  login are involved on a public install. `gh api` moves to the fallback, so
  a private `HOMEFIELD_REPO` fork stays installable when `gh` is logged in
  with access to it. The success lines are unchanged
  (`downloaded ... with gh` names the fallback path).

## v0.5.2 (2026-11-07)

Bumps the patch from v0.5.1, and it is compatible for consumers: a workflow
that passes v0.5.1's check passes this one, and no guard, default or option
changed. The tool gains `status --json`, per-command help with an
agent-oriented CLI reference (`docs/cli.md`), the README/docs refocus, and an
update check that no longer depends on a working `gh` login; it now requires
Lima 2.3.0 — hosts on 2.0–2.2 must `brew upgrade lima` before installing or
upgrading (see below). To upgrade, run the README's one-liner again (it
replaces the installed copy, `bin/lib/` and the per-command files included),
then `homefield upgrade --instance <name>` while idle on each VM. Consumers of
the routing guard can bump `routing-guard@v0.5.1` pins to `@v0.5.2` at their
leisure — a v0.5.1 pin passes the same workflows.

### Added

- `status --json`: the status report as one machine-readable object per VM
  (instance, healthy, the VM's status, the runner and its registration, the
  GitHub listing, the service, the job, npm, the extra packages), wrapped as
  `instances`/`healthy`/`vms` for every VM on this Mac, matching the shape
  `diagnose --json` wraps its reports in. The human form is unchanged, and
  `healthy`/the exit status carry the same facts.

### Changed

- The minimum Lima is 2.3.0, from 2.0. 2.3.0 (released 2026-11-06) is the
  first stable release honouring `networkOpts.hostLoopback: false`
  (lima-vm/lima#5581), the loopback boundary `install` and `upgrade` prove
  from inside the guest; 2.0–2.2 ignored the ask and left even
  `127.0.0.1`-only services reachable. A host below 2.3.0 is refused, with
  `brew install lima` / `brew upgrade lima` as the fix, and the probe's
  "Lima below 2.3 ignores the setting" warning is gone with those versions —
  on 2.3.0 an open probe means the VM's config (recreate it, or `limactl
  edit`). This closes
  [#18](https://github.com/i2Dev-com/homefield/issues/18). A
  host-requirement bump: hosts on 2.0–2.2 need `brew upgrade lima` before
  installing or upgrading.
- The help is reorganized: `homefield --help` is now a concise overview (one
  line per command, pointers to the rest), `homefield help <command>` and
  `<command> --help` print one command's options (`install --help` is no
  longer "unknown option"), and `homefield help` remains the full reference,
  unchanged. New `tests/help.sh` pins every surface.
- `homefield version`'s update check reads GitHub's public API through curl
  alone, never `gh`: a stale or unusable `gh` login no longer turns it into
  "could not check for updates" on this public repository
  ([#216](https://github.com/i2Dev-com/homefield/issues/216)). A private fork
  set with `HOMEFIELD_REPO` cannot be read that way, and now says so instead.

### Documentation

- The README is refocused on the goal, the problems it solves and the quick
  start (292 lines, from 483); its setup detail moved to a new
  `docs/getting-started.md`, and the routing expression — the versioned
  contract — stays in the README.
- `docs/cli.md` is new: every command, option, exit code, environment
  variable and `--json` shape, organized for scripts and AI agents; the
  README links it from a new "For AI agents" section. `docs/README.md` is a
  new index of the guides.
- `docs/security.md` is new: the routing guard's contract (write the
  `runs-on` key plainly, call local reusable workflows only, keep the guard
  step able to fail) and the bypasses found so far, each with its advisory
  link, the affected versions, the release that fixed it and the pin bump
  consumers make (#201, #202). Linked from the README's Security model,
  `docs/adopting.md` step 2 and `SECURITY.md`.
- The README is trimmed to ~250 lines: the "Repository layout" section is
  gone (the intro names the three parts, and the Documentation table maps
  `docs/`), "Development" merged into "Contributing, security, license", and
  the Quick start, routing, requirements, security, cost and alternatives
  prose tightened. No facts, links, anchors or code snippets changed; the
  canonical expression and the pinned routing-guard snippet are byte for byte
  what they were, as `tests/adopt.sh` pins.

## v0.5.1 (2026-11-06)

Bumps the patch from v0.5.0, and it is compatible: a workflow that passes
v0.5.0's check passes this one, and no guard, default or option changed.
The routing checker gained `--list-unroutable` and posts `::error`
annotations in CI; the homefield tool's preset hooks are no longer
add-only (#188) — a hook a preset stops shipping is removed from the VMs
on the next provision run. To upgrade, run the README's one-liner again
(it replaces the installed copy, `bin/lib/` and the per-command files
included), then `homefield upgrade --instance <name>` while idle on each
VM. Consumers of the routing guard can bump `routing-guard@v0.5.0` pins
to `@v0.5.1` at their leisure — a v0.5.0 pin passes the same workflows.

### Changed

- `bin/homefield` is split into `bin/lib/` (presentation, state, the VM,
  GitHub) and one `bin/cmd-*.sh` per command (#194). The move is mechanical
  and byte-preserving; behavior, options and output are unchanged. The
  download carries the whole tree, so installs and updates work as before.

- The routing checker's list modes gained `--list-unroutable` (#193): the
  jobs that carry no `runs-on` at all — GitHub runs them on its
  `ubuntu-latest` default, so they stay hosted silently — one `file:job` per
  line, reusable-workflow calls excluded (their routing is the callee's).
  `homefield adopt`'s ready report prints the line ("these jobs have no
  runs-on and stay hosted on GitHub's default") from the same scan, closing
  the routing-completeness gap that only `--verify` surfaced after the
  switch.

- In GitHub Actions, the routing checker's failures are `::error` annotations
  on the workflow file and line as well as output lines (#193), so a drift
  surfaces on the pull request's diff, not only in the job log.

- The checker's simple-mode refusal for a `runs-on` that is neither
  GitHub-hosted nor accepted names both accepted expressions now (#193):
  simple mode also passes a job carrying the guarded expression, and the
  message used to show only the simple one.

- `tests/parser-parity.sh` is a new suite pinning the agreement between the
  two line-by-line workflow readers — `routing_guard.py` and `tools/adopt.py`
  (duplicated by design, `python3 -I` keeps them from sharing a module) — on
  workflows shaped to mislead a naive scan (#193): a `runs-on` line inside a
  block scalar, one in a comment, a quoted `"runs-on"` key. It records that
  adopt reads the quoted key and rewrites the job to a plain `runs-on:`, so
  the plan's output is a file the checker reads.

### Fixed

- The 2026-11 audit's hygiene sweep (#193): the checker reads workflow files
  as utf-8 with replacement, as `adopt.py` does, so a non-UTF-8 workflow
  scans the same under every locale; `report.py`'s multiplier matches
  `macOS-15` (it lowercased in `classify` but not here, so the label billed
  1× instead of 10×); `bin/homefield` reads `.homefield-ref` with the
  final-line-without-newline idiom, asks `gh api --paginate` to close its
  stdin, saves and restores the caller's globbing in `merge_packages`, hands
  `state_get`'s key to awk as data instead of into a sed program, and the
  loopback probe kills its listener on INT/TERM; provision.sh disables
  apt-daily's timers before its first apt run (a fresh VM raced it for the
  lists lock), drops the dead `sed '/^$/d'`, retries the runner tarball
  download, prints a hand-off when the post-update restart fails, wants
  Docker for the cleanup unit, gates the `chown -R` of the runner home on a
  run that replaced the binary, validates `RUNNER_NAME`/`RUNNER_GROUP`
  locally (a group name keeps its spaces), and reads a missing runner
  setting as empty instead of a traceback; `install.sh` says what to do when
  the wrapper write fails (the new copy is in place, the old one gone) and
  probes for the `setup` command with `homefield setup --exists`, falling
  back to the help text for a release that has setup but predates the
  probe.

### Changed

- The five guest helpers provision.sh used to carry as heredocs are
  `vm/guest/` files now (#189): homefield-workspace-owner, the job-started
  hook, homefield-cleanup, homefield-maintenance and homefield-memwatch are
  individually reviewable, diffable and shellcheckable, and CI lints them.
  `bin/homefield` stages the directory beside provision.sh; the uninstall
  path still stages provision.sh alone, so `ensure-service` stays
  self-contained. The two helpers the suites extracted from the heredocs are
  read as files now, and the two most subtle ones — the cleanup's
  workspace-age rule and the maintenance stop/trap/reboot dance — have a
  suite of their own, `tests/guest-scripts.sh`.

### Fixed

- The tools refuse malformed input with a message, not a traceback (#190):
  a report fixture job whose `started_at`, `completed_at` or `created_at`
  does not parse as `%Y-%m-%dT%H:%M:%SZ` (a fractional-seconds timestamp
  included) is named in a one-line refusal, like the missing fields; an
  `adopt.py guards`/`setup` directory containing a directory named like a
  workflow skips it instead of dying on the open; and
  `HOMEFIELD_MODE_RELEASE=abc` is refused as not a vX.Y.Z release where
  it was an int() traceback mid-setup.

- Preset hooks are no longer add-only (#188): `copy_preset_hooks` writes a
  manifest (`/etc/homefield/preset-hooks`, one name per line) of the hooks it
  installed, and the next copy removes the ones the current preset set no
  longer ships — a hook retired upstream had kept running as root on every
  provision run of every VM that ever got it. A hand-added hook is never
  touched (the manifest names only preset hooks), and a tampered manifest
  line is skipped, not turned into a root `rm` path.

- `route` no longer abandons the repositories after the one that failed
  (#186): a failed `CI_RUNNER` switch, a failed stuck-runs listing, a failed
  cancel, status read or re-run warns naming the repository, the state and
  the manual step, and goes on to the next repository — like every other
  multi-target command. The command's exit status is the aggregate, and a
  partial `route hosted` (some repositories switched, some not) is visible
  per repository instead of silent.

## v0.5.0 (2026-11-05)

Bumps the minor from v0.4.2, and it is breaking for consumers of the routing
guard: two workflows that passed v0.4.2's check fail from this release on —
one with a `runs-on` key carrying a tag or an anchor, one calling a reusable
workflow in another repository. Both were bypasses: a workflow written that
way reached the runner with none of the guards. Found by this repository's
code audit, verified against v0.4.2, and fixed in the checker. A workflow that
starts failing with "a tagged or anchored runs-on key" is rewritten by writing
the key plainly; one failing with "a job calling a reusable workflow in
another repository" has no guarded spelling — call a local workflow
(`./.github/workflows/<file>`) and route its jobs there. A workflow that
passes v0.5.0's check ran guarded before. Bump `routing-guard@v0.4.2` pins to
`@v0.5.0`: a v0.4.2 pin keeps passing the two bypass forms, so the pin is the
fix. The check also stops failing a matrix dimension named `runs-on` and a
`jobs:` line with a value anchor.

On a Mac with more than one HomeField VM, the commands that act on a VM now
cover every one by default (below), and `uninstall`/`reset` refuse to guess.
To upgrade, run the README's one-liner again (it replaces the installed copy),
then `homefield upgrade --instance <name>` while idle on each VM: it re-runs
the *installed* tool's `provision.sh`, so the tool has to come first for a VM
to get the staged provisioning files and the pinned AWS CLI.

### Security

- `routing-guard` fails a `runs-on` key that carries a tag or an anchor —
  `!!str runs-on: self-hosted`, `&a runs-on: self-hosted`, `&a "runs-on":
  self-hosted` are valid YAML whose key is `runs-on`, and a workflow written
  that way passed every earlier release with an unguarded job. They now fail
  with the unreadable-syntax message, like the quoted-key spellings
  (GHSA-4795-jpw2-47v2) already do.
- `routing-guard` refuses a job that calls a reusable workflow in another
  repository (`uses: owner/repo/.github/workflows/wf.yml@v1`): the called
  file is not in this repository to scan, and its jobs evaluate `runs-on` in
  the caller's context, so a remote workflow with `runs-on: [self-hosted]`
  reached the runner with none of the guards. A local call
  (`./.github/workflows/<file>`) keeps passing — the called file is scanned
  like any other. A step-level `uses:` (`actions/checkout@v4`) is not a call
  and is not affected.

### Changed

- The guard no longer fails a workflow whose `strategy.matrix` has a
  dimension named `runs-on`: the dimension is data, and the job's own
  `runs-on` line — the only line that routes — is checked as before. A
  `jobs:` line carrying a value anchor (`jobs: &jobs`) is accepted, where it
  was misread as inline jobs.
- The hosted preset's AWS CLI hook pins the version and the zip's SHA256 for
  each architecture (#187), as `provision.sh` pins the runner: the one
  root-executed download in the provisioning layer that had neither. A
  provision now installs exactly 2.39.4 from the versioned URL, skips when
  that version is already installed, and refuses a download whose digest does
  not match — the unversioned "latest" URL made every provision install
  whatever AWS had published that day. Bumping means the version and both
  digests together, documented in the hook.

### Fixed

- Three failure paths in `bin/homefield` ended the command with no message
  (#184): `adopt --setup` died silently when the downloaded workflows could
  not be read (the `${mode:-simple}` fallback on the next line was never
  reached), and the workflow-name quoting in `adopt` and `adopt --setup`, and
  the memory-log read in `memory`, ended the run with a bare `exit 1` past
  `die`. Each now prints the tool, the state and the fix, like every
  neighboring failure.

### Changed

- CI lints the Python tools (#191): `ruff check` (pinned 0.17.3, the wheel's
  sha256 verified before it is installed, as actionlint and shellcheck are)
  plus `python3 -m py_compile` over `tools/` and `routing-guard/` — the ~2,000
  lines of Python the repo's CI never linted. `ruff.toml` pins target-version
  py39 (the tools run on the host's `python3`, which macOS ships as 3.9) and
  turns TRY004 off (the ValueError sites are input validation the callers
  catch as ValueError). Two files that carried shebangs without the executable
  bit are now `+x`. And shellcheck is pinned (0.11.0, asset digest verified)
  where it floated with the runner image — the drift actionlint's pin already
  prevented for it.

- Commands that act on a VM no longer report only the `homefield` instance when
  this Mac runs several (#182): `status`, `upgrade`, `start`, `stop`,
  `diagnose` and `memory` cover every HomeField VM, in Lima's order with one
  block per instance separated by a blank line, each run as its own process so
  one failure never skips or changes the next. The exit status is nonzero when
  any of them failed; the single-VM output stays byte for byte what it was.
  `--instance NAME` (or `HOMEFIELD_INSTANCE`) narrows a command to that VM, as
  before; `install` and `setup` still create/register exactly one. A Mac whose
  only VM is under another name now reports that one instead of "VM homefield:
  not created". Instances are found by the marker line every HomeField VM's
  stored `~/.lima/<name>/lima.yaml` starts with (copied from `vm/lima.yaml`
  since v0.1.0), so other Lima VMs on a dev Mac stay out; a config edited to
  lose that header is only seen when named, and the default instance counts even
  without it because `install` creates it under that name.
- `uninstall` and `reset` never guess which VM was meant (#182): with more than
  one HomeField VM on this Mac — or its only one under a non-default name —
  they list what is there and stop until `--instance NAME` names the target,
  instead of deleting `homefield`. Nothing to undo, or exactly the default
  instance, behaves as before.
- `diagnose --json` with several VMs wraps the per-VM reports:
  `{"instances": [...], "healthy": bool, "prerequisites": [...], "vms":
  [<single-VM report>, ...]}`, each entry exactly what one VM's report holds
  minus its own prerequisites. The human form prints the prerequisites once,
  before the VM blocks. A failed prerequisite fails every run and says so.
- Options are validated once, before any VM is asked: `memory --days`,
  `upgrade`'s options and its presets fail without a per-instance repeat.

## v0.4.2 (2026-11-05)

Bumps the patch from v0.4.1: both entries are compatible. The presets are
opt-in (`--preset`), and the passwordless `sudo` adds a capability a hosted
runner already has, so no workflow that passes v0.4.1's guard fails now; one
that probes `sudo -n true` takes its hosted branch instead of a fallback and
still passes. To upgrade, run the README's one-liner again (it replaces the
installed copy), then `homefield upgrade --instance <name>` while idle on each
VM: it re-runs the *installed* tool's `provision.sh`, so the tool has to come
first for a VM to get the new sudoers rule, the needrestart drop-in and the
disabled apt-daily timers. Bump `routing-guard@v0.4.1` pins to `@v0.4.2`
before running `homefield adopt` (it counts only its own release); the checker
itself is unchanged, so a v0.4.1 pin keeps passing.


### Added

- Shipped presets close the hosted-parity gaps that adopting used to copy by
  hand (#175): `homefield upgrade --preset browsers` adds the twelve Chromium
  OS libraries on Ubuntu 24.04, and `--preset hosted` adds those plus noble's
  `gh`, `shellcheck`, `sqlite3`, `xvfb` and `rsync`, a hook installing AWS CLI
  v2 (noble has no `awscli`) and one installing Node at the major
  `ubuntu-24.04` carries. The flag also works on `install`/`setup`, is
  repeatable, and **adds** to `/etc/homefield/extra-packages` instead of
  replacing it, so a repository's earlier extras survive. Only plain
  `--packages` still replaces the list; it now warns when that drops names a
  preset installed (its hooks stay in place until removed by hand). The sets
  live in `vm/presets/`, with preset hook files copied into
  `/etc/homefield/provision.d/` and re-run on every provisioning run. Versions
  track upstream at provision time, as the hosted image rebuilds weekly; a job
  whose version matters still pins it. An unknown or malformed preset stops
  before anything is stopped or created. Compatible: opt-in only.

### Changed

- The VM's `runner` user now has general passwordless `sudo`, as a
  GitHub-hosted Linux runner does (#176): a job that installs OS packages or
  starts a service at job time (`playwright install --with-deps`, `sudo
  apt-get install ...`, `sudo systemctl ...`) no longer fails for a password.
  `provision.sh` installs a second sudoers drop-in beside the
  workspace-owner's narrow rule, validates it with `visudo -cqf` and proves it
  as `runner`, so a bad rule fails provisioning rather than a job's first
  step. It adds no reach: `runner` is already root-equivalent inside the
  guest through the `docker` group, so the VM remains the boundary. A VM
  provisioned before this gets it after updating the tool (the README's
  one-liner again) and running `homefield upgrade` while idle: `upgrade`
  re-runs the `provision.sh` in the installed tool, so the tool comes first.
  Two guards come with it, because jobs now run apt themselves. A
  needrestart drop-in (`/etc/needrestart/conf.d/50-homefield.conf`) makes a
  job's apt list the services that use an upgraded library instead of
  restarting them, and never restart the runner, whose restart killed the job
  (the #8 failure); `homefield-maintenance` still restarts the others. And
  `apt-daily.timer` and `apt-daily-upgrade.timer` are disabled, as on a hosted
  image: they held apt's lists lock at random times, and a job's `sudo apt-get
  update` fails at once on it. Maintenance refreshes the lists daily instead.
  A job that failed now passes, so this is compatible (patch). A workflow
  that probes `sudo -n true` (snapdrift's browser actions) now takes its
  `--with-deps` branch, the hosted one, instead of the pre-provisioned
  fallback: it passes, and runs `apt-get update` and an apt install in every
  job, so pre-provisioned browser libraries no longer save it that step. The
  runbook's trust, parity, browsers, failure and maintenance rows, and the
  adopting notes, follow.

## v0.4.1 (2026-11-04)

Bumps the patch from v0.4.0: the routing expression and the provisioner are
unchanged, and every change either adds a command or clarifies existing
output, so no workflow that passes v0.4.0's guard fails now. To upgrade, run
the README's one-liner again, which replaces the installed copy; the VM is
untouched, so no `homefield upgrade` is needed. Bump `routing-guard@v0.4.0`
pins to `@v0.4.1` before running `homefield adopt` (it counts only its own
release); the checker itself is unchanged, so a v0.4.0 pin keeps passing.

### Changed

- Docs only: the runbook now compares what the VM has with a hosted runner
  before "Adding tools" — privileges, apt packages, CLI tools, browsers,
  languages, architecture, state between jobs, versions — pinned to
  `ubuntu-24.04`, the release the VM runs, because `ubuntu-latest` is moving
  to 26.04. A new failure-modes row resolves a job that fails on a job-time
  `sudo` install (`playwright install --with-deps`) to the new "Browsers"
  recipe. That recipe gives the noble `t64` library names, the fact that
  `libnss3`, `libnspr4`, `libdrm2` and `libxkbcommon0` come with the Lima
  image, and the sudo-less install that a job can use once they are there.
  "Adding tools" also says noble has no `awscli` apt candidate, so the AWS CLI
  v2 bundle comes in by hook (#169), and `docs/adopting.md` step 1 points at
  the table. No routing or behaviour change (#170).
- `adopt --setup` no longer dies with a bare `gh: Not Found (HTTP 404)` when
  gh's active login cannot write `.github/workflows/`: the `workflow` scope of
  a classic PAT is checked before the branch is created and a missing one
  stops the run with `gh auth refresh -h github.com -s workflow` (#165). A
  token whose scopes GitHub does not report (fine-grained, App, an env-var
  `GITHUB_TOKEN`/`GH_TOKEN`) cannot be checked, and the write's own 404 then
  names the likely cause. `gh auth status` scopes are read with the spaces
  GitHub reports them with stripped, so the `admin:org` preflight matches
  whichever order they come back in.

### Added

- `homefield start`: boots a stopped VM, then reports whether its runner is
  taking jobs — registered, its service running and GitHub listing it online.
  Booted and online are separate facts: it exits 0 only when GitHub lists the
  runner `online`, names the fix for each state that keeps it from serving
  jobs otherwise, and never reads a VM, guest or GitHub answer it could not
  get as healthy.
- `homefield stop`: stops the VM, so its runner takes no jobs until it starts
  again. It refuses while a job is running (stopping would cancel it) and
  when the VM cannot be asked whether one is; stopping an already-stopped VM
  is not an error.
- `diagnose` names `bin/homefield start` as the fix for a stopped VM, where
  it named `limactl start` before.

## v0.4.0 (2026-11-04)

Bumps the minor from v0.3.2: `homefield adopt --setup` now routes a
repository without a guard with the simple expression unless `--guards` is
given (a default change, though no workflow that passes v0.3.2's guard fails
now — the simple-mode check accepts both shapes). Output colors are off when
it matters — piped or captured — so nothing reading homefield's output
changes. To upgrade, run the README's one-liner again, then `homefield
upgrade` on each runner. Bump `routing-guard@v0.3.2` pins to `@v0.4.0`:
`homefield adopt` counts only its own release.

### Added

- Severity colors: `OK`/`WARN`/`FAIL` markers and summaries (preflight,
  diagnose), the summary lines (adopt), warnings and errors print green,
  yellow and red when the output goes to a terminal. Piped output stays
  plain byte-for-byte, so scripts, `grep` and the test suites see exactly
  the old text; `HOMEFIELD_COLOR=always` colors a pipe anyway, `NO_COLOR`
  turns color off everywhere, and `--color=never` (a global option, accepted
  before or after the command) beats the variable. A colored marker still
  carries its plain word, so `--color=never` output is identical to
  v0.3.2's.
- Simple `runs-on` mode: the one-clause expression
  `${{ vars.CI_RUNNER == 'local' && 'homefield-ci' || 'ubuntu-latest' }}`
  whose only guardrail is the `CI_RUNNER` switch (which stays the rollback,
  `homefield route hosted`). It routes every event, so it is for a private
  repository whose every contributor may use the Mac. `homefield adopt
  --setup` writes it for a repository without a guard; `--guards` opts into
  the guarded multi-clause expression, and a guard already in the repository
  keeps its own shape either way. The guard learns `--mode`/`mode: simple`
  (its default `guards` keeps every existing step byte for byte); in simple
  mode it also accepts the guarded expression, so a repository can move
  between the shapes or mix them, and it refuses `events`/`dependabot`
  (there), which would have no effect — every event routes. Until the
  release carrying simple mode is cut, `adopt --setup` and `guard-snippet`
  refuse it: the guard step they write pins this copy's release, whose
  checker has no `--mode` and would fail the workflows on their first pull
  request; `--guards` is the way until then.

### Fixed

- The files `bin/homefield` stages into the guest for the guest to run as
  root — `provision.sh` (provisioning, and the restore `uninstall`/`reset`
  fall back on) and the preset hooks — are staged through a per-run private
  directory (#185): `mktemp -d`, 0700, owned by the login user, with a name
  no live job can guess, instead of fixed `/tmp/provision.sh` and
  `/tmp/homefield-preset-<name>` paths. The guest's `runner` user cannot read
  what is staged, and the copy and the run no longer depend on how Lima's
  agent treats a pre-planted path. `HOMEFIELD_STAGE_DIR` pins the directory
  for the suites. A directory left behind by a killed run is harmless.

- `adopt`'s verify step no longer re-runs the routing guard's own run: after
  `adopt --setup` the newest `pull_request` run is often the guard
  workflow's, which is hosted by design, so the check always ended in the
  hosted warning whatever the routing does (seen adopting a personal
  repository). It now re-runs the newest `pull_request` run of any other
  workflow; if the only `pull_request` run is the guard's, it says so and
  points at opening a pull request on the repository instead.

## v0.3.2 (2026-11-03)

Compatible with v0.3.1 (workflows unchanged). To upgrade, run the README's
one-liner again, then `homefield upgrade` on each runner: re-provisioning
brings an existing runner the loopback probe's verdicts (which only prove
closed on Lima ≥ 2.3.0, not a stable release yet) and the memory sampler's
boot column. Bump `routing-guard@v0.3.1` pins to `@v0.3.2`: `homefield adopt`
counts only its own release.

### Added

- `homefield setup` now carries on after the routing pull request is merged:
  the offer at the end of a fresh setup runs `homefield adopt --repo
  <owner>/<repo> --setup --wait`, so after the pull request is opened it waits
  for your merge and then adds the repository to the runner group and switches
  it on, in the same run (Ctrl-C is safe). The question reads `Open the routing
  pull request for <owner>/<repo> now, and carry on once you merge it? [Y/n]`,
  and the command printed for a declined offer carries `--wait`. `adopt --wait`
  has two new exit statuses so that `setup` can tell the cases apart: 4 when
  the pull request is open and not merged (the wait timed out, it was closed
  without a merge, or five reads in a row failed) and 5 when it was merged but
  the routing check, the group access or the switch then failed. Anything
  before the pull request exists still exits 1, as does every run without
  `--wait`; Ctrl-C and SIGTERM stay 130 and 143. `setup` still exits 0 when
  `adopt` fails (the runner is set up) but now says which case it was: no
  `--setup` retry line once the pull request exists, as its branch would make
  `--setup` refuse, and for a merged one the plain `homefield adopt --repo
  <owner>/<repo>`, with the `--label` and `--group` the runner was registered
  with (adopt's own "run this after the merge" lines and the routing pull
  request's body keep the ones you passed too). After Ctrl-C `setup` says `adopt` was
  interrupted (what it printed says how far it got) and exits 130, as you
  cancelled. A compatible change.
  [#156](https://github.com/i2Dev-com/homefield/issues/156)
- `homefield adopt --verify | --no-verify` — `docs/adopting.md` step 6 (open
  a run, read the *Runner name*) done by `adopt` itself. After a switch that
  happened, or a `CI_RUNNER` that was already `local`, it offers to re-run the
  repository's latest pull-request run and reports, one line per job, where
  each landed: on the local runner (with its name), on a GitHub-hosted runner
  (a warning: the job stays hosted by design, or the routing did not take
  effect for it), or still waiting for a runner when the time (about three
  minutes) runs out, with a pointer to the runbook's failure modes. A job that
  failed on the local runner points at the toolchain-gap advice. A job counts
  as local by the labels it asked for, read from the jobs API, so it works from
  any machine, and only jobs of the new attempt count. While the run is going
  it keeps looking until a job with the routing label is listed (a job in a
  reusable workflow that needs another job may not be listed until that one is
  done), and it says when the run is still unfinished, so the list may not be
  complete. On a terminal it asks
  first (`[y/N]`, the default is no, since the re-run uses CI minutes);
  `--verify` skips the question, `--no-verify` never asks or touches a run,
  and giving both is an error. Without a terminal and without `--verify` it
  asks nothing and prints the two `gh` commands to do it by hand. It is not
  offered with `--dry-run` or `--no-switch`. A repository with no pull-request
  run yet, or whose latest run is still running, is told so and nothing is
  re-run; a `gh` error is reported as "could not verify". `adopt` exits 0
  whatever it finds. The closing "still by hand" line names only what remains
  (tools the jobs lack, recording the setup) when the check ran.
  [#149](https://github.com/i2Dev-com/homefield/issues/149)
- `homefield setup` offers to open the routing pull request at the end of a
  fresh setup, on a terminal, so the next command is not left to be typed. A
  repository-scoped registration (a personal account, or a repository URL)
  asks `Open the routing pull request for <owner>/<repo> now? [Y/n]`; an
  organization asks which repository to route first (a name, meaning
  `<org>/<name>`, or `owner/repo`; Enter skips, and text that is not a
  repository name runs nothing). Yes runs `homefield adopt --repo <owner>/<repo>
  --setup`; `n`, Enter at the organization question and end of input skip it
  with a line naming the command for later. Nothing is created on GitHub
  without the answer, and `adopt` keeps refusing public repositories and
  needing write access. If `adopt` fails, its message is shown, `setup` still
  exits 0 (the runner is set up) and prints the command to run again. Without a
  terminal, on an upgrade of a registered instance, and for `install`, nothing
  changes. A `--label` or `--group` given to `setup` goes along to `adopt`
  (and into the printed commands), so the pull request routes on the label the
  runner carries.
  [#148](https://github.com/i2Dev-com/homefield/issues/148)
- `homefield setup [install options]` — the first-time setup in one command.
  It runs `preflight` first and, if any check fails (a warning does not count),
  exits 1 saying so before creating or touching anything: no VM, no runner
  group, no registration, no state file, and no GitHub write. Then it runs
  `install`'s steps and ends with a summary instead of `install`'s advice: a
  check mark line each for the VM (created, or already there), the isolation
  check, the runner group, the registered runner (name and id) and the runner
  online with its labels, and a `!` line for what needs attention (a group wider
  than recommended or not checked, a runner not online within the wait or whose
  group could not be confirmed); a `!` does not change the exit status, which
  stays 0 once the runner is registered. The next steps follow: route a
  repository with `homefield adopt --repo <owner>/<repo>`, the guide
  (`docs/adopting.md`), the advice for the group's state, and the repositories
  that can use the runner now (group access, not `CI_RUNNER`: an organization's
  selected group is listed, or said to be empty or not listable; a repository or
  personal registration names its repository; Default, wide and unchecked groups
  say why there is no list). On an instance that is already registered it
  upgrades it, like `install`, and prints a shorter summary. `install` is
  unchanged (its output is byte for byte what it was) and stays the lower-level
  command and the upgrade path. `install.sh`'s closing hint, and its advice for
  an unfinished setup, name `homefield setup` when the release it installed has
  that command, and `homefield install` for an older one (the default is a
  pinned tag). The one-liner hands over to `homefield setup` the same way, so
  its preflight is strict: a missing gh, python3 or Homebrew stops it before the
  VM is created.
  [#129](https://github.com/i2Dev-com/homefield/issues/129)
- `homefield reset [--keep-vm] [--keep-group] [--remove-tool]` rolls back a
  complete or half-finished install of one instance (a failed `install`, an
  `uninstall` that stopped partway, a VM deleted by hand), and is a no-op that
  exits 0 when there is nothing to undo. It lists what it will do and asks
  `y/N` (`HOMEFIELD_YES=1` answers yes; without a terminal and without it, it
  stops and changes nothing), refuses while a job is running (checked again
after the confirmation, as the runner stays online meanwhile), deregisters the
  runner (only the VM's copy of the registration when GitHub no longer lists
  it), deletes the VM, and deletes the runner group when this install created
  it, ending with a report of what was removed, kept or failed. The group is
  deleted only if it is not Default, GitHub still lists it with the recorded id
  and name, no runner other than this one is in it (deleting a group moves its
  runners to Default) and `--keep-group` was not given. To know the group is
  its own, `install` now records a created group in a per-instance state file,
  `~/.local/state/homefield/<instance>.state` (`HOMEFIELD_STATE_DIR`), before it
  creates the VM; a group that already existed is never recorded or deleted.
  Unlike the issue's step 4, the wrapper script and install directory are
  shared by every instance, so removing them is opt-in with `--remove-tool`,
  and then happens last, only when every other step worked.
  `uninstall` is unchanged. See `docs/runbook.md`, "Rolling back a failed
  install".
  [#127](https://github.com/i2Dev-com/homefield/issues/127)
- `homefield diagnose [--json]` — one read-only report for "why is my CI not
  running": the VM (created, Lima status, isolation), the runner (registered
  name and id, whether GitHub lists it online or offline and busy or idle,
  service, runner version, extra packages, npm state), the runner group
  (exists, selected or all repositories, public repositories allowed, which
  repositories; "n/a" for a repository-scoped registration) and the
  prerequisites `preflight` checks, ending in a "Summary:" of healthy or each
  problem with its fix command (see `docs/runbook.md`, "Failure modes"). Exits
  0 when healthy and 1 on any problem. `--json` prints only JSON on stdout
  (`healthy` and a `problems` array), built without jq or python3. It never
  starts or stops the VM, registers or changes the runner, or writes to
  GitHub; the checks inside a stopped VM are skipped and said to be.
  `preflight` and `status` output is unchanged.
  [#126](https://github.com/i2Dev-com/homefield/issues/126)
- `homefield install` finds out whether the URL's owner is a personal account
  or an organization before the token, group and name steps, for an owner URL
  and now also a repository URL (with `gh`, else the public API), and says
  which it found. A personal account skips the runner group entirely
  (`GROUP_STATE=personal`), prints GitHub's limit (no account-wide runners, so
  each repository registers on its own) and HomeField's (one VM per
  registration until
  [#14](https://github.com/i2Dev-com/homefield/issues/14), so each repository
  needs its own `--instance`), and ends with advice that the runner serves
  only that repository. Given only a personal account's owner URL, it asks
  for the repository on a terminal, and without one stops naming
  `--url https://github.com/<you>/<repo>`. `--personal` and `--org` force the
  mode and skip the lookup (the API unreachable, or a token that cannot see the
  account); both together is an error. A repository URL whose owner cannot be
  looked up still works, with a note; an owner URL that cannot is still
  refused, now naming the two flags. `--group` on a personal account is
  ignored with a message, as it already was for a repository URL. A
  compatible change.
  [#125](https://github.com/i2Dev-com/homefield/issues/125)
- `homefield adopt --setup --repo <owner>/<repo>` opens a pull request that
  writes steps 1–4 of `docs/adopting.md` instead of waiting for them: every
  job of a workflow that runs on `pull_request` and asks for a GitHub-hosted
  image gets the canonical `runs-on` expression (with a comment pointing at
  the guide), the routing guard lists exactly those jobs — its `jobs:` block
  where a guard already runs on pull requests, otherwise a new
  `.github/workflows/homefield-routing.yml` — and every cache key built from
  `runner.os` without `runner.arch` in those files gains
  `${{ runner.arch }}`. `--jobs` routes only the listed jobs; a workflow
  whose file name holds a space or a comma is never routed (a guard's
  `jobs:` list cannot hold it). Jobs already carrying the expression stay in
  the guard's list whatever `--jobs` says; a guard this copy does not
  recognize, or one set to `arch: x64`, is refused before anything is staged.
  The staged files are checked with
  `routing_guard.py` before anything is sent, the run
  exits 1 with "nothing to route" when no job qualifies, a guard set to
  `arch: x64` is refused (the VM is arm64), and neither the
  runner group nor `CI_RUNNER` is touched: after merging, plain
  `homefield adopt` (step 5) switches the repository on. Needs `gh`,
  `python3` and write access to the repository; needs no VM.
  [#124](https://github.com/i2Dev-com/homefield/issues/124)
- `homefield adopt --repo <owner>/<repo> --setup --wait` waits for the pull
  request `--setup` opens to be merged and then carries on in the same run
  with what a plain `homefield adopt` does (it reads the repository and its
  workflows again, runs the checks, adds the repository to the runner group and
  sets `CI_RUNNER=local`), instead of leaving you to come back and run it. The
  merge stays yours: nothing is added to the group or switched while it waits,
  and a merged pull request whose routing does not pass stops the run with the
  usual "not switched". It reads the pull request every 10 seconds and says
  once a minute that it is still waiting. A pull request closed without a
  merge, or still open after `--wait-timeout <minutes>` (a whole number, default
  60), ends the run with exit 4 and the command to run after the merge; a
  failed read is tried again, five in a row end the run. Ctrl-C or SIGTERM
  prints that command, exits 130 or 143 and leaves the pull request and its
  branch alone. `--wait` without `--setup` and `--wait-timeout` without
  `--wait` are errors, and with `--dry-run` `--wait` has nothing to wait for.
  Plain `homefield adopt` stays the way to pick up by hand. A compatible
  change. [#147](https://github.com/i2Dev-com/homefield/issues/147)
- The VM now asks Lima to stop mapping the Mac's loopback into the guest
  (`networkOpts.hostLoopback: false` in `vm/lima.yaml`, from
  [lima-vm/lima#5581](https://github.com/lima-vm/lima/pull/5581)). Only
  Lima ≥ 2.3.0 honours it — not a stable release yet; Lima 2.0–2.2 warn
  "unknown field" and ignore the line — so `install` and `upgrade` prove the
  state from inside the guest instead of trusting the config: a throwaway
  listener on the Mac's `127.0.0.1` serving a token its own connect must
  read back (so what answers is provably the probe's listener), a connect
  from the guest, and only bash's own "Connection refused" counted as
  closed (an unresolved name shares the exit status and is treated as
  unproven). Closed is
  logged, open warns with the way to close it (and stops the run only when
  the VM's own config asked for the block and the Lima is new enough to
  honour it), and an unprovable probe never reads as closed. Existing VMs
  keep the documented exposure until 2.3.0 is stable and their config is
  updated (`docs/runbook.md`, "Host loopback exposure").
  [#18](https://github.com/i2Dev-com/homefield/issues/18) stays open until a
  stable Lima closes it for everyone.
- `homefield preflight` — a pre-install readiness check. Verifies macOS,
  Apple Silicon, Lima ≥ 2.0, gh (the active account, by login and scope; an App
  token reports no scope, which is fine), python3 and Homebrew; exits 0 when all
  pass, 1 otherwise (with exact fix commands). `install` prints it first and
  gates on its own subset — macOS, Apple Silicon, Lima. See `homefield help` and
  [`docs/runbook.md`](docs/runbook.md).

### Fixed

- `homefield adopt --setup` (and so `--setup --wait`, and the offer at the end of
  `homefield setup`) now says where things stand on Ctrl-C or SIGTERM in every
  phase, not only while it waits for the merge, and exits 130 or 143 each
  time. Before the pull request was opened it takes back the branch it made and
  says nothing was switched; while the pull request is being opened it says the
  pull request may exist and leaves the branch (deleting it would close that
  pull request), saying how to delete it if there is none; after the merge it says the group access and `CI_RUNNER` may
  or may not be done and to run `homefield adopt --repo <owner>/<repo>` again
  (safe to repeat); during `--verify` it says the repository is routed, only
  the optional check was cut short, and prints the commands to check by hand.
  Before, a signal outside the wait ended `adopt` with no word and, before the
  pull request existed, left the branch behind, and under `homefield setup`
  could end setup without its note. A second signal while it reports no longer
  prints the note twice and ends the run at once, with the first signal's
  status (so a hung cleanup call can be aborted), the call that creates the
  branch is covered by the cleanup too, and `--verify` stops between reads at
  once instead of after the pause. `kill` sent to `homefield setup` alone no longer leaves the
  `adopt` it was running waiting for the merge for up to an hour: that `adopt`
  stops, saying setup ended, at its next check, within one poll interval (10
  seconds by default; a step already in progress finishes first).
  [#158](https://github.com/i2Dev-com/homefield/issues/158)
- A first run no longer dead-ends on `gh`. `install.sh` now asks one question
  for everything Homebrew has to install, naming the commands it will run:
  Lima (missing, or older than 2.0) and gh (missing), and `HOMEFIELD_YES=1`
  installs both. Lima stays required, with the same failures as before; gh
  never fails the installer: declining, no terminal without `HOMEFIELD_YES=1`,
  no Homebrew or a failed `brew install gh` just goes on, and `homefield setup`'s preflight reports it with its
  fix command. A Mac with no Homebrew and no Lima is now told so before
  anything is downloaded or written. On a terminal, `homefield setup` offers
  `gh auth login -h github.com` when gh is installed but not logged in and no
  other check fails, before its preflight report, then runs the preflight;
  declining, end of input, a login that does not finish, or no terminal leaves
  the same failed check as before. It is not offered when another check fails
  too, when gh cannot answer the login question, or when `GITHUB_TOKEN` or
  `GH_TOKEN` is set (gh uses it instead of the stored login). `preflight`, `diagnose` and `install` do not offer the login,
  and what preflight prints is unchanged. A compatible change.
  [#146](https://github.com/i2Dev-com/homefield/issues/146)
- `homefield install` now confirms the runner group an organization's runner
  landed in. After the runner shows online it asked GitHub's runner list for
  `runner_group_id`, a field that list never returns, so the check silently
  fell back to the plain `is online: labels ...` line. It now asks each runner
  group which runners it holds and matches the runner's id, printing
  `group <name>`, or `group <name> (expected <group>)` when it landed
  elsewhere; when the groups cannot be listed, or the runner is in none, it says
  that instead of assuming the expected group. A repository's runner has no
  group and is unchanged. `diagnose` shares the lookup. The tests no longer
  fake a `runner_group_id`, and apply the code's real `--jq` filters to
  API-shaped JSON (#141).

### Changed

- Docs only: the README's Quick start now opens with what you need (an Apple
  Silicon Mac that stays awake, the VM's memory, disk and CPU, private
  repositories, org-owner rights, and `--group Default` on the Free plan) and
  ends with "Later": another repository (`homefield adopt --setup --wait`),
  another runner or Mac (answer `n` to the routing-pull-request offer), and
  leaving. `docs/adopting.md` leads with the one-command path, and the runbook's
  "More runners" says what to answer to the offer.
- The last lines `homefield adopt` prints no longer say to "record the setup in
  the repository" by hand: `docs/adopting.md` step 7 now says the setup pull
  request and the guard's `jobs:` list are that record, and a note is only for
  why a job stays hosted.
- `homefield setup --url https://github.com/<org>` asks for the `admin:org`
  scope in the `gh auth login` it offers (`gh auth login -h github.com -s
  admin:org`), so a first-time organization user authorizes in the browser
  once, not again at the runner-group step. The owner is looked up first (the
  public API works before gh is logged in); `--org` and `--personal` decide it
  without the lookup. A repository URL, a personal account and a run with no
  `--url` yet keep gh's default login, and the scope is offered later as
  before. A compatible change.
- When the directory the `homefield` command goes into is not on the PATH,
  `install.sh` now leads with the `export PATH=...` line to copy-paste into
  the current terminal ("add it now"), and only then the same line for
  `~/.zshrc` ("to make it permanent"). The old hint only described the
  `~/.zshrc` edit, which does nothing until a new terminal opens
  (#128). A bin dir already on the PATH still gets no hint.
- `homefield install` reports progress while waiting for the runner to show
  online on GitHub: a line every 15 seconds (`waiting for <name> (up to 90 s,
  waited 15 s)`), so the ~90 second poll is never silent. No line is emitted when the
  runner appears online before the first report (#130). The wait and its
  progress lines are configurable through `ONLINE_WAIT_TRIES` (default 18),
  `ONLINE_WAIT_INTERVAL` (default 5) and `ONLINE_PROGRESS_CYCLES` (default 3)
  in the environment.

## v0.3.1 (2026-10-29)

Compatible with v0.3.0 (workflows unchanged; a host on Lima 1.x first needs
`brew upgrade lima` — the minimum is now 2.0, below). To upgrade, run the
README's one-liner again, then `homefield upgrade` on each runner. Bump
`routing-guard@v0.3.0` pins to `@v0.3.1`: `homefield adopt` counts only its
own release.

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

- `homefield memory` counts the out-of-memory kills a young VM's first log
  row already holds, which it silently reported as zero (#91). The sampler
  writes a ninth CSV column, the epoch of the current boot (`btime`; `0`
  means unknown). The whole counter counts — first retained row, or a boot
  that changed between rows even when its value did not fall — only when
  that boot is known and began inside the window; the window's epoch is
  derived from the rows' own timestamps (the VM's timezone), not the host's;
  kills under a boot that predates the window span its start and stay
  uncounted rather than guessed; same boot, the difference as before. Old
  8-column logs keep the counter rule, first row uncounted; a mid-upgrade
  day mixes both widths safely.
- `homefield status` no longer stalls on a dead network while asking GitHub
  whether it still lists the runner (#103). `gh` has no timeout flag and a
  black-holed connect can take ~75 s on macOS, and `status` is what the
  runbook says to run when a runner looks offline. The ask now runs in the
  background and is killed after 15 s (`HOMEFIELD_GH_TIMEOUT`), reported as
  `github: not checked (timed out ...)`; the service, job and version lines
  still come from the VM. `upgrade` and `uninstall` bound the same ask.
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

- **The minimum Lima is 2.0 (from 1.1)**, and `vm/lima.yaml` now uses the
  `template:` locator (`base: template:_images/ubuntu-24.04`) instead of the
  `template://` form Lima 2.0 deprecated (its warning fired on every VM
  creation). The new form is documented for 2.0 and later, so the
  requirement was raised instead of version-gated; a 1.x host is refused by
  `install`/`check_host` with a `brew upgrade lima` nudge (#100).
- The personal-account limits in the docs are split into what GitHub enforces
  and what this project does (#117). README, runbook *Runner group* and
  adopting step 5 now say plainly that GitHub scopes runners to a repository,
  organization or enterprise and jobs never cross scopes — so an
  organization-registered runner can never serve a personal-account
  repository, and each such repository registers on its own — while
  one-VM-per-registration is ours, until #14 puts several runners in one VM.
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
