# Changelog

Versions are the tags consumers pin, `routing-guard@vN`. A compatible change
moves the current major tag; a change that makes a previously passing workflow
fail is a new major (see [README](README.md#development)).

## Unreleased

This is v3, a new major: the project is renamed from ci-runner to HomeField.
Nothing about how routing works changes, but every name below does, so an
existing install is replaced, not upgraded in place. See "Migrating from
ci-runner (v2)" in [`docs/runbook.md`](docs/runbook.md#migrating-from-ci-runner-v2).

### Breaking

- The command is `homefield` (was `ci-runner`), and the script is
  `bin/homefield`. The installer writes a `homefield` wrapper and installs the
  tool in `~/.local/share/homefield` (was `~/.local/share/ci-runner`); the
  install marker is `.homefield-ref` (was `.ci-runner-ref`). The installer
  fetches `v3` by default.
- The environment variables are `HOMEFIELD_*` (was `CI_RUNNER_*`):
  `HOMEFIELD_HOME`, `HOMEFIELD_REPO`, `HOMEFIELD_REF`, `HOMEFIELD_BIN_DIR`,
  `HOMEFIELD_YES`, `HOMEFIELD_TTY`, `HOMEFIELD_INSTANCE`, plus the test hooks
  `HOMEFIELD_SOURCE_ONLY` and `HOMEFIELD_REPORT_FIXTURE`. The repository
  variable `CI_RUNNER` is unchanged: it is part of the routing expression, so
  consuming repositories keep their `runs-on` switch as it is.
- The default Lima instance is `homefield` (was `ci-runner`), so the default
  runner name is `lima-homefield` (was `lima-ci-runner`).
- The default routing label and org runner group are `homefield-ci` (was
  `local-ci`), in `homefield`, `provision.sh` (`RUNNER_LABEL`,
  `RUNNER_GROUP`), `adopt`, `report` and the `verify-routing` action's `label`
  input. A consumer whose workflows use `local-ci` either passes
  `label: local-ci` or switches to `homefield-ci` in the same change as the
  action.
- Inside the VM: `/etc/homefield` (was `/etc/ci-runner`),
  `/var/log/homefield` (was `/var/log/ci-runner`), the `homefield-cleanup`,
  `homefield-maintenance` and `homefield-memwatch` scripts and systemd units
  (were `ci-runner-*`) and `/etc/apt/apt.conf.d/52homefield-no-unattended-upgrade`.
  `provision.sh` does not migrate the old paths: the migration below
  replaces the VM.
- The repository is `i2Dev-com/homefield` (was `i2Dev-com/ci-runner`), and the
  action is `i2Dev-com/homefield/verify-routing@v3`. GitHub redirects the old
  repository's web and API URLs, but not a workflow's `uses:`: once the
  repository is renamed, a step on `i2Dev-com/ci-runner/verify-routing` (any
  ref) fails with "Repository not found", so switch each consumer as soon as
  the rename happens. `adopt` does not accept the old path, and says what
  migrating means when it finds it.

### Migrating from ci-runner (v2)

Route the repositories to hosted with the old tool, uninstall the old runner,
install v3, switch each consuming repository to the new label and action, then
adopt it again. The steps, in order, are in
[`docs/runbook.md`](docs/runbook.md#migrating-from-ci-runner-v2).

A v2 install is detected and left alone, so v3 never creates a second VM and
runner next to it:

- `install.sh` installs the tool but does not hand over to `homefield install`
  when a Lima instance `ci-runner` exists and the target instance does not; it
  prints the pointer to the migration and exits non-zero.
- `homefield install` refuses in the same case. Passing `--instance` or setting
  `HOMEFIELD_INSTANCE` is taken as deliberate and skips the check. `status`,
  `upgrade`, `uninstall` and `memory` add the same pointer when they find no
  `homefield` VM but a `ci-runner` one.
- `provision.sh` exits before changing anything on a guest that has
  `/etc/ci-runner` or `ci-runner-*` systemd units, instead of provisioning
  next to them.
- `adopt` says the `i2Dev-com/ci-runner/verify-routing@v2` step is the v2
  guard, and that migrating switches the action to
  `i2Dev-com/homefield/verify-routing@v3` and the label from `local-ci` to
  `homefield-ci` together.

### Fixed

- `install`'s online check reported the group the runner was *expected* to
  join as if it were the one GitHub listed: the runners list carries only the
  group's id (no name), so the name was always read as empty and the message
  fell back to the expected group. The group is now resolved against the
  runner-groups list and reported as observed; a different group is shown
  with the expected one, and an unreadable list shows the group's id.
- The `verify-routing` check attributed runs-on lines to jobs by a fixed
  two-space indent and matched a `runs-on:` key anywhere in the file. A
  workflow indented by four spaces was reported as `file:None`, and a
  workflow_dispatch input named `runs-on:` failed as a multi-line runs-on.
  Job ids are now the keys directly under `jobs:` at whatever indent the
  file's first such key uses, and only runs-on lines inside `jobs:` count.
  Both cases failed safe before; both now pass when the routing is right.
- `adopt` computed the routed-jobs list with only the first verify-routing
  step's label, so with steps carrying different labels, jobs routed under
  the others were missed and adopt wrongly reported "no job uses the routing
  expression". Jobs routed under any step count now — under the steps carrying
  the requested label, when `--label` is given — and when no `--label` was
  given, the label of a passing step is the one advised in the snippet and
  messages.
- The `verify-routing` check now recognizes a top-level `jobs:` key spelled
  with quotes (`"jobs":`), which YAML allows. Before, the runs-on lines under
  one were attributed to no job and (in the unreleased draft) went unchecked;
  a workflow with a quoted `jobs:` key and routing in place now passes, and a
  bare `runs-on: self-hosted` under one still fails.
- The isolation check read a failed guest command (a VM that is not running,
  say) as an empty mount list and misreported it as "the VM has host
  mounts". It now distinguishes a check that could not run from a mount
  count, and refuses to continue either way.
- `status` printed an empty `runner: , registered at ` line when the
  registration's details could not be read; it now says so.
- A runner group name with a space reached `config.sh --runnergroup` as two
  words (provision.sh). GitHub allows spaces in group names.
- `report` with a fixture that has no entry for the repository raised a
  KeyError traceback instead of a message.

### Changed

- The VM's default memory is 5 GiB instead of 8, the same as GitHub's
  `ubuntu-slim` runner, which lowers the VM's idle footprint on the Mac. The
  highest minute measured on a live runner over two weeks used 4.4 GiB. An
  existing VM keeps its size until resized (runbook, "Host memory").
- The base package set includes `docker-buildx`: Ubuntu's `docker.io` has no
  buildx, so `docker buildx build` (and `docker build --secret`) failed in
  jobs, as it did for one repository's browser test. Existing runners get it
  from `bin/ci-runner upgrade`, which is a no-op if it was already passed as
  an extra package.
- Runbook: an access checklist, a health check after updates, a step list for
  moving to dedicated hardware, and the Lima loopback opt-out's status in the
  trust-boundary table.
- Docs are written for any organization or account, not one deployment: a
  README with a quick start, requirements and limitations (Apple Silicon,
  private repositories only, one job at a time, offline behaviour, plans and
  personal accounts), the security model, cost and alternatives; the runbook
  and adoption guide use placeholders and the default VM name, and no longer
  link to private issues. The adopters table is gone: each adopting
  repository documents its own routing.
- The guest OS maintenance hour (07:00) is documented as adjustable with a
  systemd drop-in.
- The security model now states that the VM's network is not isolated: jobs
  can reach the Mac's services through `host.lima.internal`, including
  loopback-only ones, and the LAN (#18). The earlier docs said the VM had no
  access to the Mac's ports.
- Free-plan organizations are told to register with `--group Default`.
- `tests/memwatch.sh` skips the run (not fails) when GNU `timeout` is
  missing, as it already did for bash < 4.2; macOS ships neither.

### Added

- `bin/ci-runner adopt --repo <owner>/<repo>`: does the part of
  `docs/adopting.md` that is not a workflow edit. It refuses a public
  repository, downloads the repository's workflows and runs the
  `verify-routing` check on them, warns about cache keys with `runner.os` and
  no `runner.arch` in files with routed jobs, and only when the routing is
  ready adds the repository to the organization's runner group (needs
  `admin:org`; without it, it warns and goes on) and sets `CI_RUNNER` to
  `local`. The routing is ready when a guard is present, passes and at least
  one job is routed. A guard is a step that uses
  `i2Dev-com/ci-runner/verify-routing@v2` (a full commit SHA is accepted with
  a warning) in a workflow that runs on `pull_request`, or in a reusable
  workflow that one of those calls, and that is not switched off by
  `if: false`; another repository's action, another ref, a push-only or
  `pull_request_target` workflow does not count. Branch and path filters on
  the trigger and other `if:` conditions are warnings. When the routing is not
  ready, the group is only read (it warns if the repository is already in it)
  and nothing is added; it prints the routing expression and the guard step to
  add, and exits 1. `--jobs`, `--label`, `--group`, `--no-switch`;
  `--dry-run` changes nothing. Needs `gh` and `python3`, not the VM. `install`'s closing message
  points to it.
- `verify_routing.py --list` (the jobs that carry the canonical expression)
  and `--print-expression`, which `adopt` uses. Existing invocations and
  their output are unchanged, so the action stays `@v2`.
- `install.sh`, a one-line installer: `gh api
  'repos/i2Dev-com/ci-runner/contents/install.sh?ref=v2' -H 'Accept:
  application/vnd.github.raw' | bash` (or `curl -fsSL
  https://raw.githubusercontent.com/i2Dev-com/ci-runner/v2/install.sh | bash`
  once the repository is public). It downloads the tool for a ref
  (`CI_RUNNER_REPO`, `CI_RUNNER_REF`; `gh` for a private repository, `curl`
  otherwise) into `~/.local/share/ci-runner`, puts a `ci-runner` command on
  the PATH, installs or upgrades Lima (1.1 or later) with Homebrew if you agree, and runs
  `ci-runner install`; arguments after `bash -s --` go to it. Run it again to
  upgrade the tool; with no arguments, an existing VM is left alone.
- `bin/ci-runner version`: the installed ref and commit, or the checkout's.
- `bin/ci-runner install` asks for the URL on a terminal when `--url` is
  missing, instead of failing, and checks it before creating anything.
- `bin/ci-runner install` creates the organization's runner group when it is
  missing (selected repositories, public repositories off) and warns when an
  existing one is open to all or to public repositories. On the Free plan,
  where custom groups cannot be created, it says so and points to
  `--group Default`. `--group Default` skips the step.
- `bin/ci-runner install` and `uninstall` offer `gh auth refresh -s admin:org`
  when gh lacks the scope (unless `GITHUB_TOKEN` or `GH_TOKEN` overrides gh's
  login), before falling back to a pasted token.
- `bin/ci-runner install` waits up to 90 seconds for the runner to show online
  and prints its labels and group, or the runners page to check by hand.
- `bin/ci-runner route <hosted|local> --repo <owner>/<repo>`: switches
  repositories' pull-request jobs (the `CI_RUNNER` variable), and on a switch
  to hosted cancels and re-runs runs that are stuck waiting for the local
  runner. `--dry-run` previews it. It works without the VM, for a Mac that is
  asleep.
- MIT `LICENSE`, `SECURITY.md` (private reporting, scope, known
  limitations), `CONTRIBUTING.md`, issue forms and a pull request template.
- `bin/ci-runner`: `install`, `upgrade`, `status` and `uninstall` the runner
  on a Mac in one command each. It checks prerequisites, creates the VM,
  verifies its isolation before running anything in it, fetches tokens with
  `gh` or prompts for them (never on a command line), refuses to upgrade or
  remove while a job is running and takes the runner offline for the
  duration (starting it again if the command fails), and refuses a personal
  account's URL, which cannot have account-wide runners (checked with `gh`,
  or `curl` without it). Runs on macOS's stock bash 3.2.
- `provision.sh` rejects a `RUNNER_URL` that is not a github.com organization
  or repository.

- `provision.sh`: `RUNNER_EXTRA_PACKAGES` installs extra apt packages on top
  of the base set. The list is saved in the guest and kept by later runs.
  Hooks in `/etc/ci-runner/provision.d/*.sh` install anything apt does not
  have. See "Adding tools" in [`docs/runbook.md`](docs/runbook.md). Nothing
  changes for existing runners: the base set is the same.
- `bin/ci-runner memory`: per-day average and peak memory of the VM, the peak
  during jobs and out-of-memory kills, from a new guest sampler
  (`ci-runner-memwatch.service`) that logs the per-minute peak of 2-second
  samples to `/var/log/ci-runner/`. Existing runners get it with
  `bin/ci-runner upgrade`.
- `bin/ci-runner report`: queue wait, duration and minutes per repository,
  workflow and job, local against hosted, from the GitHub API, for measuring
  whether the runner saves money and keeps up.
- The `routing-guard` action (`i2Dev-com/homefield/routing-guard@v3`): the
  routing check under its new name, with the input `jobs:` in place of
  `expected:` (same meaning, same format). `label:`, `arch:` and
  `workflows-dir:` are unchanged. `homefield adopt` recognizes it, reads
  `jobs:` from it, and prints it in the guard step it suggests.

### Deprecated

- `i2Dev-com/homefield/verify-routing@v3` and its `expected:` input. It stays
  as an alias of `routing-guard` (same checks, same inputs as before) so that
  consumers pinned to `@v3` keep working unchanged, and is removed in v4.
  `homefield adopt` still accepts it as a guard, with a warning. To switch,
  change two lines in the guard step:

  ```diff
  -        uses: i2Dev-com/homefield/verify-routing@v3
  +        uses: i2Dev-com/homefield/routing-guard@v3
           with:
  -          expected: |
  +          jobs: |
  ```

## v2 (2026-09-30)

### Upgrading from v1

In one pull request per consuming repository:

1. Make sure the runner has the label your expression will use: `local-ci`
   by default (add it on the runners page if it was registered with another
   label), or keep your label and pass it as `label:` below.
2. Replace every routed job's `runs-on` with the v2 expression from
   [`docs/adopting.md`](docs/adopting.md), using that label.
3. Change `verify-routing@v1` to `verify-routing@v2`.

### Breaking

- The canonical routing expression gains a fourth guard,
  `github.event.pull_request.head.repo.full_name == github.repository`, so pull
  requests from forks always run hosted. Every routed job's inline `runs-on`
  must be updated to the new expression in the same change that moves to `@v2`
  ([`docs/adopting.md`](docs/adopting.md) has the expression verbatim). Mixing
  them fails: `@v1` rejects the new expression and `@v2` rejects the old one.
  This is defence in depth for private repositories that allow forking; it
  does not make the runner safe for public repositories (see the trust
  boundary in [`docs/runbook.md`](docs/runbook.md)).
- The default routing label is `local-ci` instead of `i2dev-ci`, in
  `verify-routing` (`label` input) and in `provision.sh` (new `RUNNER_LABEL`
  setting). Both reject anything but one custom label, including GitHub's
  default labels and hosted image names such as `ubuntu-latest`, which would
  make the runner take plain hosted jobs. A runner registered with `i2dev-ci` keeps working in either of two
  ways: pass `label: i2dev-ci` to `verify-routing@v2` and keep that label in
  the expression, or add `local-ci` to the runner's labels (*Settings →
  Actions → Runners →* the runner *→ Labels*) and use the default.
- `provision.sh` no longer defaults `RUNNER_URL` to an organization: it is
  required to register or move, and not needed to re-run on a registered
  runner. `RUNNER_NAME` defaults to the guest's hostname instead of
  `i2dev-ci-lima`. Existing registrations are unaffected: both are only read
  at registration.

## v1

- Initial release: `verify-routing` action, Lima VM definition and
  `provision.sh`.
