# Runbook: Local Self-Hosted CI Runner

Run selected pull-request CI jobs on a local runner instead of GitHub-hosted,
to cut billed Actions minutes (i2Dev-com/i2dev#879). GitHub is still where CI
is triggered, where logs live and where checks report. Only the machine that
executes the job changes.

One runner, `i2dev-ci-lima`, in a Lima VM on the founder's Mac, registered at
the **organization** and limited by a runner group to the repositories allowed
to use it. Which jobs each repository routes is documented in that repository
(for i2dev: `docs/runbooks/self-hosted-ci-runner.md`). To add a repository,
follow [`adopting.md`](adopting.md).

---

## How routing works

Every opted-in job uses this `runs-on`, inline:

```yaml
runs-on: ${{ vars.CI_RUNNER == 'local' && github.event_name == 'pull_request' && github.actor != 'dependabot[bot]' && !startsWith(github.head_ref, 'dependabot/') && fromJSON('["self-hosted","linux","arm64","i2dev-ci"]') || 'ubuntu-latest' }}
```

- The **repository** variable `CI_RUNNER` is the switch, so each repository
  opts in and out on its own. `local` sends pull-request jobs to the runner
  with label `i2dev-ci`. Unset, or any other value, sends them to hosted
  `ubuntu-latest`.
- **Pushes always run hosted**, whatever `CI_RUNNER` says. Deploys wait on the
  default branch's CI, and a merge must not sit queued behind a sleeping laptop.
- **Dependabot always runs hosted.** Checked by actor and by branch name.
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
| Who can run code on the runner | Only repositories in the runner group. Keep them **private**: then only collaborators can open PRs, so there are no fork PRs. The group must have `allows_public_repositories: false`. |
| Unreviewed dependency code | Dependabot PRs are routed hosted (see above). |
| Host files and credentials | Lima VM with **no mounts** (`mounts: []` + `--mount-none`), no SSH-agent forwarding, and no host SSH keys. `~/.aws`, `gh` auth, `.env` files and working trees on the Mac are not reachable from the guest. |
| Host ports | Guest→host port forwarding is disabled, so a job's service containers never appear on the Mac's `localhost`. |
| Production | The VM holds no cloud credentials and no AWS CLI. Deploy jobs stay hosted and get their credentials through OIDC. |
| Secrets in jobs | Jobs on the runner receive the secrets their workflow passes, on same-repo PRs. Push-only secrets never reach it, because pushes run hosted. |
| Across repositories | Every allowed repository's PR jobs share one VM, one after another. Workspaces are per repository, but anything a job leaves in the guest (Docker images, `/tmp`) is visible to the next job from another repository. Allow only repositories you would trust with each other's PR code. |
| Inside the VM | Jobs run as user `runner`, which is in the `docker` group and therefore root-equivalent **inside the guest**. The VM is the boundary, not the user. |

## Runner group

The organization's runner group is what decides which repositories can use the
runner. Set it up before registering, because an org runner without a
restricted group is usable by every repository in the organization.

*Organization settings → Actions → Runner groups → New runner group*:

- Name `local-ci`.
- Repository access: **Selected repositories**. Add only the repositories that
  have adopted the runner.
- Leave **Allow public repositories** off.

Check it (needs the `admin:org` scope):

```bash
gh api orgs/i2Dev-com/actions/runner-groups -q '.runner_groups[] | "\(.id) \(.name) \(.visibility) public=\(.allows_public_repositories)"'
gh api orgs/i2Dev-com/actions/runner-groups/<id>/repositories -q '.repositories[].full_name'
```

## Setup (once per machine)

Requires Lima ≥ 1.1 (`brew install lima`; verified on 2.2.0). Run from a
checkout of this repository.

```bash
# 1. Create and start the VM (no mounts, no port forwards, Ubuntu 24.04 arm64)
limactl create --name=i2dev-ci-runner --mount-none vm/lima.yaml
limactl start i2dev-ci-runner

# 2. Confirm the isolation before anything runs in it: no mounts, no home dir
limactl shell i2dev-ci-runner -- sh -c 'mount | grep -Ec "virtiofs|9p|sshfs|reverse-sshfs"; ls /Users 2>&1'
# expect: 0, and "No such file or directory"

# 3. Provision: packages, Docker, runner binary (checksum-verified), systemd
#    service, registration at the organization in group local-ci. The token
#    goes in on stdin, never on a command line, where any process in the guest
#    could read it; see "Registration tokens" below for where to get it.
limactl copy vm/provision.sh i2dev-ci-runner:/tmp/provision.sh
printf 'RUNNER_TOKEN=%s\n' "$TOKEN" | limactl shell i2dev-ci-runner sudo bash /tmp/provision.sh
unset TOKEN
```

Then, in *Organization settings → Actions → Runners*, confirm `i2dev-ci-lima`
is **Idle** in the `local-ci` group, with labels
`self-hosted, Linux, ARM64, i2dev-ci`.

**Registration tokens.** A registration token is valid for one hour, and the
runner exchanges it for its own identity at registration. An org token needs
an organization owner:

- Either `gh api -X POST orgs/i2Dev-com/actions/runners/registration-token -q .token`
  with a token that has the `admin:org` scope. The bot App cannot do it.
- Or *Organization settings → Actions → Runners → New runner → Linux*. The page
  shows the token in its `config.sh` line; copy only the token.

**Autostart.** The VM does not restart after a reboot unless something starts
it. Run `limactl autostart enable i2dev-ci-runner` (Lima 2.x; 1.x called it
`start-at-login`). Inside the VM, the runner is a systemd service and starts
with the guest.

## Switching (per repository)

```bash
# To the local runner
GITHUB_TOKEN='' gh variable set CI_RUNNER --repo i2Dev-com/<repo> --body local

# Back to hosted: the recovery path, and the safe default
GITHUB_TOKEN='' gh variable set CI_RUNNER --repo i2Dev-com/<repo> --body hosted
```

`runs-on` is evaluated when a job is queued. **A job that is already queued for
`i2dev-ci` stays queued after the switch.** Cancel the run and re-run it:

```bash
GITHUB_TOKEN='' gh run cancel <run-id> --repo i2Dev-com/<repo>
GITHUB_TOKEN='' gh run rerun <run-id> --repo i2Dev-com/<repo>
```

## Failure modes

| Symptom | Cause | What happens | Recovery |
|---|---|---|---|
| PR job "Waiting for a runner to pick up this job" | VM stopped, Mac asleep or offline, runner service down | The PR's check waits in the queue, and after 24 h GitHub fails it. Merges and deploys are unaffected, because pushes run hosted. | Start the VM (`limactl start i2dev-ci-runner`), or switch to hosted and re-run. |
| Waiting forever although the runner is online and idle | The repository is not in the runner group | Same as above | Add the repository to the group, or switch it to hosted |
| A PR job waits while another runs | One runner runs one job at a time, across all repositories | Serialised, not failed | Accept it, or switch the less urgent repository to hosted |
| Job fails only on the local runner | Toolchain or arch gap between the VM and `ubuntu-latest` (arm64 vs x86-64) | Red check | Re-run hosted to confirm. Then fix `provision.sh` or keep that job hosted |
| `No space left on device` in the VM | Docker images and old workspaces | Red check | `limactl shell i2dev-ci-runner sudo /usr/local/sbin/ci-runner-cleanup` |
| Cancelled job still "in progress" for ~40 s | The runner gives the running step a grace period before killing it | Ends `cancelled`, and service containers are removed | Wait. Only investigate if it lasts minutes |

Observed in the i2dev#889 drills: an offline runner leaves the job queued, and
after switching to hosted it stays queued until it is cancelled and re-run. A
restarted VM's runner is back online within seconds. Two concurrent runs
serialise.

**Inspecting the guest.** The Lima login user is not in the `docker` group, so
use `limactl shell i2dev-ci-runner sudo docker ps`. Plain `docker ps` shows
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
- **Guest OS updates.** Re-run `provision.sh`. It is idempotent and skips
  registration when the runner already exists. Or run `sudo apt-get upgrade`
  in the guest.
- **Cleanup.** A daily systemd timer (`ci-runner-cleanup.timer`) prunes
  stopped containers, unused networks, dangling layers and build cache older
  than 24 h. It also removes any workspace with nothing modified inside it for
  7 days. It skips the run if a job is in progress, and the prune is written to
  be safe if a job starts during it. For that reason it never removes tagged
  images. After a service image version bump, clear the old tags by hand while
  idle: `limactl shell i2dev-ci-runner sudo docker image prune --all --force`.
- **Host memory.** The VM process on the Mac ("Virtual Machine Service") sits
  at roughly the configured `memory` even while idle. The guest fills spare RAM
  with page cache, and Virtualization.framework does not return pages to the
  host once the guest has used them; dropping caches in the guest does not
  lower it either. The size is therefore the idle footprint: `memory` in
  `vm/lima.yaml` is kept close to what jobs need. Restarting the VM while the
  runner is idle resets the footprint until the next jobs refill the cache. To
  resize an existing VM, while idle:
  `limactl stop i2dev-ci-runner && limactl edit i2dev-ci-runner --memory 8 && limactl start i2dev-ci-runner`.
  Queued PR jobs wait through the restart and are then picked up.
  If `limactl stop` hangs ("did not receive an event with the `exiting`
  status"), power the guest off cleanly with
  `limactl shell i2dev-ci-runner sudo systemctl poweroff`, then clear the
  leftover host agent with `limactl stop --force i2dev-ci-runner`.

## Moving a registration

To move the runner to another scope (for example from one repository to the
organization), re-register it in place. It keeps its name and labels, so no
workflow changes are needed. `REMOVE` is a remove-token for the **current**
scope (for a repository: `gh api -X POST repos/i2Dev-com/<repo>/actions/runners/remove-token -q .token`,
which needs repository admin). `TOKEN` is a registration token for the new
scope (see "Registration tokens").

Move it while no job is running: the script refuses otherwise, then stops the
runner before anything else.

```bash
limactl copy vm/provision.sh i2dev-ci-runner:/tmp/provision.sh
printf 'RUNNER_REMOVE_TOKEN=%s\nRUNNER_TOKEN=%s\n' "$REMOVE" "$TOKEN" |
  limactl shell i2dev-ci-runner sudo RUNNER_REREGISTER=1 bash /tmp/provision.sh
unset REMOVE TOKEN
```

If a later step fails, for example the service does not come up, re-run the
same command. A runner already registered at the new scope is not removed
again, so the stale remove token does no harm.

## Removing the runner

```bash
# Every repository that routes to it: switch to hosted first
GITHUB_TOKEN='' gh variable set CI_RUNNER --repo i2Dev-com/<repo> --body hosted
# REMOVE: org remove-token (orgs/i2Dev-com/actions/runners/remove-token, admin:org)
printf '%s\n' "$REMOVE" | limactl shell i2dev-ci-runner sudo sh -c 'cd /opt/actions-runner && ./svc.sh uninstall && read -r t && ACTIONS_RUNNER_INPUT_TOKEN="$t" sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u runner ./config.sh remove'
unset REMOVE
limactl delete --force i2dev-ci-runner
```

If the VM is already gone, delete the stale registration in
*Organization settings → Actions → Runners*.

## Moving to dedicated hardware

The VM definition and `provision.sh` are the whole machine. On another Mac,
repeat Setup. On a Linux box, run `provision.sh` directly on an Ubuntu 24.04
host or VM. It hardcodes the linux-arm64 tarball, so an x86-64 host needs a
different tarball and checksum, and consumers' `verify-routing` then takes
`arch: x64` along with the matching expression. Register the new runner with
the same `i2dev-ci` label, confirm it is online, then remove the old one. The
decision to buy hardware waits on i2dev#890's measurement.
