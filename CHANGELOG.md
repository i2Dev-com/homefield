# Changelog

Versions are the tags consumers pin, `verify-routing@vN`. A compatible change
moves the current major tag; a change that makes a previously passing workflow
fail is a new major (see [README](README.md#development)).

## Unreleased

### Changed

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

### Added

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
