# Runbook: local self-hosted CI runner

Operating the runner: one Lima VM on a Mac, registered at an **organization**
(and limited by a runner group to the repositories allowed to use it) or at
one repository. Selected pull-request jobs run on it instead of on
GitHub-hosted runners; GitHub is still where CI is triggered, where logs live
and where checks report. Which jobs a repository routes is documented in that
repository. To add one, follow [`adopting.md`](adopting.md).

Commands below use the default VM name, `ci-runner`. If you installed with
`--instance NAME`, use that name instead (for `bin/ci-runner`, pass
`--instance NAME`). `<org>`, `<owner>` and `<repo>` are yours.

---

## How routing works

Every opted-in job uses this `runs-on`, inline:

```yaml
runs-on: ${{ vars.CI_RUNNER == 'local' && github.event_name == 'pull_request' && github.actor != 'dependabot[bot]' && !startsWith(github.head_ref, 'dependabot/') && github.event.pull_request.head.repo.full_name == github.repository && fromJSON('["self-hosted","linux","arm64","local-ci"]') || 'ubuntu-latest' }}
```

- The **repository** variable `CI_RUNNER` is the switch, so each repository
  opts in and out on its own. `local` sends pull-request jobs to the runner
  with the routing label, `local-ci` unless the runner was registered with
  another `RUNNER_LABEL`. Unset, or any other value, sends them to hosted
  `ubuntu-latest`.
- **Pushes always run hosted**, whatever `CI_RUNNER` says. Deploys wait on the
  default branch's CI, and a merge must not sit queued behind a sleeping Mac.
- **Dependabot always runs hosted.** Checked by actor and by branch name.
- **Pull requests from forks always run hosted.** Only a branch of the
  repository itself is routed, which covers private repositories that allow
  forking. It does not make a public repository safe: a fork PR runs the
  workflow files from its own merge commit, so it can rewrite `runs-on`
  altogether. See the trust boundary below.
- The [`verify-routing`](../verify-routing/action.yml) action, run in each
  repository's CI, enforces three things:
  - every copy of the expression is identical to the canonical one;
  - any `runs-on` that asks for `self-hosted` is that expression. A bare
    `self-hosted` would match this runner, because its labels are a superset;
  - the jobs that opt in are exactly the repository's `expected` list.

**Why the expression is inline and not an action.** GitHub evaluates `runs-on`
before any step runs, so no action can choose a job's runner. A separate
"choose the runner" job could pass its answer through `needs`, but that job is
itself billed a whole minute on every run, which is the cost the local runner
exists to remove. The copies are kept honest by `verify-routing` instead.

**Keep on hosted:** Docker image builds (x86-64 images, GHA build cache), and
every job holding cloud or production credentials.

## Trust boundary

| Concern | Control |
|---|---|
| Who can run code on the runner | Only repositories in the runner group. Keep them **private**, and the group at `allows_public_repositories: false`: that is the boundary, because a PR runs the workflow files from its own branch and can therefore rewrite any `runs-on`. The expression's fork guard adds defence in depth for private repositories that allow forking. |
| Unreviewed dependency code | Dependabot PRs are routed hosted (see above). |
| Host files and credentials | Lima VM with **no mounts** (`mounts: []` + `--mount-none`), no SSH-agent forwarding, and no host SSH keys. `~/.aws`, `gh` auth, `.env` files and working trees on the Mac are not reachable from the guest. |
| Guest ports on the Mac | Guest→host port forwarding is disabled, so a job's service containers never appear on the Mac's `localhost`. |
| **Mac and LAN services from the guest** | **Not isolated.** The guest reaches the Mac at `host.lima.internal` (192.168.5.2, also its gateway and DNS), which Lima maps to the Mac's loopback: every service listening on the Mac is reachable, including ones bound only to `127.0.0.1`, as is the LAN. A firewall inside the guest would not hold, since jobs are root-equivalent there. Until [#18](https://github.com/i2Dev-com/ci-runner/issues/18) is closed, keep sensitive services off the Mac that hosts the runner. |
| Production | The VM holds no cloud credentials and no AWS CLI. Deploy jobs stay hosted and get their credentials through OIDC. |
| Secrets in jobs | Jobs on the runner receive the secrets their workflow passes, on same-repo PRs. Push-only secrets never reach it, because pushes run hosted. |
| Across repositories | Every allowed repository's PR jobs share one VM, one after another. Workspaces are per repository, but anything a job leaves in the guest (Docker images, `/tmp`) is visible to the next job from another repository. Allow only repositories you would trust with each other's PR code. |
| Inside the VM | Jobs run as user `runner`, which is in the `docker` group and therefore root-equivalent **inside the guest**. The VM is the boundary, not the user. |

## Runner group

The organization's runner group is what decides which repositories can use the
runner. Set it up before registering, because an org runner without a
restricted group is usable by every repository in the organization.

Custom runner groups need the GitHub Team plan or Enterprise. On the Free plan
an organization has only the Default group, which every repository in it can
use: register there only if you would trust every repository with the others'
pull-request code, keep **Allow public repositories** off on it, and register
with `--group Default` (`RUNNER_GROUP=Default` by hand): the default group
name, `local-ci`, does not exist there and registration fails. The
alternative is a repository-scoped runner, which only that repository can use.
A personal account has no account-wide runners at all: register per
repository, one VM per repository.

*Organization settings → Actions → Runner groups → New runner group*:

- Name `local-ci`.
- Repository access: **Selected repositories**. Add only the repositories that
  have adopted the runner.
- Leave **Allow public repositories** off.

`bin/ci-runner install` passes `--group` (default `local-ci`) for an
organization URL; a repository-scoped runner has no group. Check the group
(needs the `admin:org` scope):

```bash
gh api orgs/<org>/actions/runner-groups -q '.runner_groups[] | "\(.id) \(.name) \(.visibility) public=\(.allows_public_repositories)"'
gh api orgs/<org>/actions/runner-groups/<id>/repositories -q '.repositories[].full_name'
```

## Setup (once per machine)

Requires Lima ≥ 1.1 (`brew install lima`; verified on 2.2.0). Run from a
checkout of this repository.

**The short way:** `bin/ci-runner install --url https://github.com/<org>`
(or `https://github.com/<owner>/<repo>`; options: `bin/ci-runner help`) does
every step below and enables autostart.
It fetches the registration token with `gh` when it can, and otherwise asks
you to paste one. The steps are what it does, and the way to do it by hand:

```bash
# 1. Create and start the VM (no mounts, no port forwards, Ubuntu 24.04 arm64)
limactl create --name=ci-runner --mount-none vm/lima.yaml
limactl start ci-runner

# 2. Confirm the isolation before anything runs in it: no mounts, no home dir
limactl shell ci-runner -- sh -c 'mount | grep -Ec "virtiofs|9p|sshfs|reverse-sshfs"; ls /Users 2>&1'
# expect: 0, and "No such file or directory"

# 3. Provision: packages, Docker, runner binary (checksum-verified), systemd
#    service, registration at the organization in group local-ci. The token
#    goes in on stdin, never on a command line, where any process in the guest
#    could read it; see "Registration tokens" below for where to get it.
#    RUNNER_URL is required. RUNNER_LABEL (default local-ci), RUNNER_NAME
#    (default: the guest hostname) and RUNNER_GROUP (default local-ci) are
#    optional; see the top of provision.sh.
limactl copy vm/provision.sh ci-runner:/tmp/provision.sh
printf 'RUNNER_TOKEN=%s\n' "$TOKEN" |
  limactl shell ci-runner sudo RUNNER_URL=https://github.com/<org> bash /tmp/provision.sh
unset TOKEN
```

Then, on the runners page (*Organization settings → Actions → Runners*, or
the repository's *Settings → Actions → Runners*), confirm the runner
(`lima-ci-runner`, or its `RUNNER_NAME`) is **Idle**, in the `local-ci`
group for an organization, with labels `self-hosted, Linux, ARM64, local-ci`.

Re-running `provision.sh` on a registered runner (to upgrade it) needs no
settings: the registration is kept as it is. `bin/ci-runner upgrade` does
that: it refuses while a job is running, then stops the runner so no job can
start mid-upgrade, and `provision.sh` starts it again at the end (or the
command does, if provisioning fails).

**Registration tokens.** A registration token is valid for one hour, and the
runner exchanges it for its own identity at registration. An organization
token needs an organization owner; a repository token needs the repository's
owner, or admin access to it in an organization:

- Either `gh api -X POST orgs/<org>/actions/runners/registration-token -q .token`
  (with the `admin:org` scope), or `repos/<owner>/<repo>/...` for a
  repository.
- Or the runners page → *New runner → Linux*. The page shows the token in its
  `config.sh` line; copy only the token.

**Autostart.** The VM does not restart after a reboot unless something starts
it. Run `limactl autostart enable ci-runner` (Lima 2.x; 1.x called it
`start-at-login`). Inside the VM, the runner is a systemd service and starts
with the guest.

## Adding tools

The VM starts with a small base set (see "Packages" in
[`provision.sh`](../vm/provision.sh)), which is less than `ubuntu-latest`.
Add what your jobs need without editing the script. Per-job toolchains
(`actions/setup-node`, `setup-python`, ...) need nothing here.

**Apt packages:** pass `RUNNER_EXTRA_PACKAGES` when provisioning. The list is
saved in the guest (`/etc/ci-runner/extra-packages`), so upgrade runs keep it
without passing it again, and the idle-time maintenance upgrades these
packages along with the rest. Passing it again replaces the list; passing it
empty clears it. Neither uninstalls anything.

```bash
bin/ci-runner upgrade --instance ci-runner --packages "libpq-dev shellcheck"
# by hand:
limactl copy vm/provision.sh ci-runner:/tmp/provision.sh
limactl shell ci-runner sudo RUNNER_EXTRA_PACKAGES="libpq-dev shellcheck" bash /tmp/provision.sh
```

**Anything else:** a hook, a bash script in `/etc/ci-runner/provision.d/`
ending in `.sh`. Hooks run as root, in name order, on every provisioning run,
after the packages and the `runner` user and before the runner itself is
installed or upgraded. Make them idempotent (skip if already installed). A
failing hook stops provisioning with an error before the runner is touched.
A move (`RUNNER_REREGISTER=1`) has already stopped the runner by then, and
starts it again on any failure until the old registration is removed.

The package list is saved only after apt has installed it, so a misspelt name
fails that run and leaves the saved list as it was. Packages go on one line,
separated by spaces.

```bash
limactl copy 50-awscli.sh ci-runner:/tmp/50-awscli.sh
limactl shell ci-runner sudo install -D -m 755 /tmp/50-awscli.sh /etc/ci-runner/provision.d/50-awscli.sh
limactl shell ci-runner sudo bash /tmp/provision.sh   # runs it now
```

Provision while the runner is idle, as for any upgrade (see "Maintenance").
Everything added here is available to every repository's jobs, so keep
credentials out of hooks.

## Switching (per repository)

```bash
# Back to hosted: the recovery path, and the safe default
bin/ci-runner route hosted --repo <owner>/<repo> [--repo ...]

# To the local runner
bin/ci-runner route local --repo <owner>/<repo>
```

`runs-on` is evaluated when a job is queued. **A job that is already queued for
the local runner stays queued after the switch.** `route hosted` therefore
also looks for runs with a job still queued for the routing label (`--label`,
default `local-ci`), cancels them and re-runs them, and the re-run goes to
hosted. `--dry-run` shows what it would do. It needs `gh` with write access to
the repositories, not the VM, so it works while the Mac hosting the runner is
asleep, from any machine with a checkout. By hand:

```bash
gh variable set CI_RUNNER --repo <owner>/<repo> --body hosted   # or local
gh run cancel <run-id> --repo <owner>/<repo>
gh run rerun <run-id> --repo <owner>/<repo>
```

## Failure modes

| Symptom | Cause | What happens | Recovery |
|---|---|---|---|
| PR job "Waiting for a runner to pick up this job" | VM stopped, Mac asleep or offline, runner service down | The PR's check waits in the queue, and after 24 h GitHub fails it. Merges and deploys are unaffected, because pushes run hosted. | Start the VM (`limactl start ci-runner`), or `bin/ci-runner route hosted --repo <owner>/<repo>`. |
| Waiting forever although the runner is online and idle | The repository is not in the runner group | Same as above | Add the repository to the group, or switch it to hosted |
| Waiting forever although the runner is online and idle, and the repository is in the group | The label in the expression is not one of the runner's labels. For example, a repository moved to `verify-routing@v2`, whose default label is `local-ci`, while the runner was registered with another label | Same as above | Add the label to the runner (*Settings → Actions → Runners →* the runner *→ Labels*), or pass the runner's label to `verify-routing` as `label:` and use it in the expression |
| A PR job waits while another runs | One runner runs one job at a time, across all repositories | Serialised, not failed | Accept it, or switch the less urgent repository to hosted |
| Job fails only on the local runner | Toolchain or arch gap between the VM and `ubuntu-latest` (arm64 vs x86-64) | Red check | Re-run hosted to confirm. Then add the tool ("Adding tools") or keep that job hosted |
| `No space left on device` in the VM | Docker images and old workspaces | Red check | `limactl shell ci-runner sudo /usr/local/sbin/ci-runner-cleanup` |
| Cancelled job still "in progress" for ~40 s | The runner gives the running step a grace period before killing it | Ends `cancelled`, and service containers are removed | Wait. Only investigate if it lasts minutes |

Observed in drills: an offline runner leaves the job queued, and
after switching to hosted it stays queued until it is cancelled and re-run. A
restarted VM's runner is back online within seconds. Two concurrent runs
serialise.

**Inspecting the guest.** The Lima login user is not in the `docker` group, so
use `limactl shell ci-runner sudo docker ps`. Plain `docker ps` shows
nothing, which is easy to misread as "no containers". On the Mac, `limactl`
listens only on two loopback ports for its own SSH and host agent. A job's
service ports never appear there.

## Maintenance

- **Runner updates.** The runner updates itself when GitHub releases a new
  version. `provision.sh` pins the version used for a *fresh* install. Bump
  `RUNNER_VERSION` and `RUNNER_SHA256` together (the asset `digest` from
  `gh api repos/actions/runner/releases/latest`). Re-running `provision.sh`
  after a bump stops the service, replaces the binary and starts it again.
  Stopping cancels any job in progress, so do it while the runner is idle.
- **Guest OS updates.** Automatic. Ubuntu's own `unattended-upgrades` is
  switched off, because it restarts the runner, containerd and Docker at
  06:00–07:00 whether or not a job is running, and has failed jobs that way
  ([#8](https://github.com/i2Dev-com/ci-runner/issues/8)). In its place, `ci-runner-maintenance.timer` runs daily at 07:00 guest
  time, which Lima takes from the Mac. Pick an hour when pull requests are
  rarely opened: `limactl shell ci-runner sudo systemctl edit
  ci-runner-maintenance.timer`, and add `[Timer]`, an empty `OnCalendar=`
  (timers add up otherwise) and `OnCalendar=*-*-* 03:00`. Re-provisioning
  keeps the drop-in. If a job is running it skips the day.
  Otherwise it stops the runner, runs `apt-get upgrade`, and then either
  starts the runner again or, if the update needs one
  (`/var/run/reboot-required`), reboots the guest. The runner starts on boot.
  Queued jobs wait through it, typically under a minute and longer on a
  reboot. To update now, while idle:
  `limactl shell ci-runner sudo systemctl start --no-block ci-runner-maintenance`.
  (`--no-block`, because the upgrade may restart D-Bus and drop a client
  waiting on the unit.)
  Its log: `limactl shell ci-runner sudo journalctl -u ci-runner-maintenance`.
  To check whether a reboot is pending:
  `limactl shell ci-runner ls /var/run/reboot-required`.
  To reboot by hand while idle, run `limactl shell ci-runner sudo systemctl reboot`.
  A guest reboot keeps the VM running under `vz`.
- **Cleanup.** A daily systemd timer (`ci-runner-cleanup.timer`) prunes
  stopped containers, unused networks, dangling layers and build cache older
  than 24 h. It also removes any workspace with nothing modified inside it for
  7 days. It skips the run if a job is in progress, and the prune is written to
  be safe if a job starts during it. For that reason it never removes tagged
  images. After a service image version bump, clear the old tags by hand while
  idle: `limactl shell ci-runner sudo docker image prune --all --force`.
- **Host memory.** The VM process on the Mac ("Virtual Machine Service") sits
  at roughly the configured `memory` even while idle. The guest fills spare RAM
  with page cache, and Virtualization.framework does not return pages to the
  host once the guest has used them; dropping caches in the guest does not
  lower it either. The size is therefore the idle footprint: `memory` in
  `vm/lima.yaml` is kept close to what jobs need. Restarting the VM while the
  runner is idle resets the footprint until the next jobs refill the cache. To
  resize an existing VM, while idle:
  `limactl stop ci-runner && limactl edit ci-runner --memory 8 && limactl start ci-runner`.
  Queued PR jobs wait through the restart and are then picked up.
  If `limactl stop` hangs ("did not receive an event with the `exiting`
  status"), power the guest off cleanly with
  `limactl shell ci-runner sudo systemctl poweroff`, then clear the
  leftover host agent with `limactl stop --force ci-runner`.

## Moving a registration

To move the runner to another scope (for example from one repository to the
organization), re-register it in place. Pass its current `RUNNER_NAME` and
`RUNNER_LABEL` so it keeps them and no workflow changes are needed.
`REMOVE` is a remove-token for the **current**
scope (for a repository: `gh api -X POST repos/<owner>/<repo>/actions/runners/remove-token -q .token`,
which needs repository admin). `TOKEN` is a registration token for the new
scope (see "Registration tokens").

Move it while no job is running: the script refuses otherwise, then stops the
runner before anything else.

```bash
limactl copy vm/provision.sh ci-runner:/tmp/provision.sh
printf 'RUNNER_REMOVE_TOKEN=%s\nRUNNER_TOKEN=%s\n' "$REMOVE" "$TOKEN" |
  limactl shell ci-runner sudo RUNNER_REREGISTER=1 \
    RUNNER_URL=https://github.com/<new-scope> RUNNER_NAME=<name> RUNNER_LABEL=<label> \
    bash /tmp/provision.sh
unset REMOVE TOKEN
```

If a later step fails, for example the service does not come up, re-run the
same command. A runner already registered at the new scope is not removed
again, so the stale remove token does no harm.

## Changing the label or name

`provision.sh` reads `RUNNER_NAME`, `RUNNER_LABEL` and `RUNNER_GROUP` only at
registration, and a move at the same `RUNNER_URL` is skipped, so re-running it
with new values changes nothing.

- **Label:** edit it on GitHub, no re-registration needed: *Settings →
  Actions → Runners →* the runner *→ Labels*. Add the new label, move every
  consumer's expression and `label:` to it, then remove the old one.
- **Name or group:** the group can be changed on the same page. For a new
  name, remove the runner (below, keeping the VM) and register it again with
  the new `RUNNER_NAME`.

## Removing the runner

`bin/ci-runner uninstall` deregisters the runner (fetching or asking for a
remove token), turns off autostart and deletes the VM; `--keep-vm` only
deregisters. By hand:

```bash
# Every repository that routes to it: switch to hosted first
gh variable set CI_RUNNER --repo <owner>/<repo> --body hosted
# REMOVE: org remove-token (orgs/<org>/actions/runners/remove-token, admin:org)
printf '%s\n' "$REMOVE" | limactl shell ci-runner sudo sh -c 'cd /opt/actions-runner && ./svc.sh uninstall && read -r t && ACTIONS_RUNNER_INPUT_TOKEN="$t" sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u runner ./config.sh remove'
unset REMOVE
limactl delete --force ci-runner
```

If the VM is already gone, delete the stale registration on the runners page.

## Moving to dedicated hardware

The VM definition and `provision.sh`, plus what was added under "Adding tools",
make up the machine. The additions live only in the guest
(`/etc/ci-runner/extra-packages` and `/etc/ci-runner/provision.d/`), so copy
them out first, and keep hooks somewhere versioned rather than only in the VM:

```bash
limactl shell ci-runner cat /etc/ci-runner/extra-packages   # pass as RUNNER_EXTRA_PACKAGES
limactl shell ci-runner sudo tar -C /etc/ci-runner -cf - provision.d > provision.d.tar
```

On another Mac, repeat Setup with the same `RUNNER_EXTRA_PACKAGES` and the
hooks installed before provisioning. On a Linux box, run `provision.sh`
directly on an Ubuntu 24.04 host or VM. It hardcodes the linux-arm64 tarball, so an x86-64 host needs a
different tarball and checksum, and consumers' `verify-routing` then takes
`arch: x64` along with the matching expression. Register the new runner with
the same `RUNNER_LABEL`, confirm it is online, then remove the old one.
