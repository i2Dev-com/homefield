# Runbook: local self-hosted CI runner

Operating the runner: one Lima VM on a Mac, registered at an **organization**
(and limited by a runner group to the repositories allowed to use it) or at
one repository. Selected pull-request jobs run on it instead of on
GitHub-hosted runners; GitHub is still where CI is triggered, where logs live
and where checks report. Which jobs a repository routes is documented in that
repository. To add one, follow [`adopting.md`](adopting.md).

Commands below use the default VM name, `homefield`. If you installed with
`--instance NAME`, use that name instead (for `bin/homefield`, pass
`--instance NAME`). `<org>`, `<owner>` and `<repo>` are yours.

---

## How routing works

Routed jobs carry the [canonical `runs-on` expression](adopting.md#2-route-them),
and the [`routing-guard`](../routing-guard/action.yml) action, run in each
repository's CI, keeps every copy identical ([README: How routing
works](../README.md#how-routing-works)). What the expression does:

- The **repository** variable `CI_RUNNER` is the switch, so each repository
  opts in and out on its own. `local` sends the routed jobs to the runner with
  the routing label, `homefield-ci` unless the runner was registered with
  another `RUNNER_LABEL`. Unset, or any other value, sends them to the hosted
  fallback image, `ubuntu-latest` by default.
- **Pushes run hosted by default**, whatever `CI_RUNNER` says. Deploys wait on
  the default branch's CI, and a merge must not sit queued behind a sleeping
  Mac. A repository whose `events` option adds `push` (or
  `workflow_dispatch`, `schedule`) routes those jobs too: they wait for the
  Mac like pull-request jobs do, and a deploy gated on CI queues behind them
  until the repository is switched to hosted.
- **Dependabot runs hosted by default.** Checked by actor and by branch name.
  `dependabot: local` drops both checks, which puts Dependabot's unreviewed
  install scripts on a VM that is not thrown away after the job.
- **Pull requests from forks always run hosted**, whatever the options. That
  covers private repositories that allow forking. It does not make a public
  repository safe: a fork PR runs the workflow files from its own merge
  commit, so it can rewrite `runs-on` altogether (see the trust boundary).

**Keep on hosted:** Docker image builds (x86-64 images, GHA build cache), and
every job holding cloud or production credentials.

## Trust boundary

| Concern | Control |
|---|---|
| Who can run code on the runner | Only repositories in the runner group. Keep them **private**, and the group at `allows_public_repositories: false`: that is the boundary, because a PR runs the workflow files from its own branch and can therefore rewrite any `runs-on`. The expression's fork guard adds defence in depth for private repositories that allow forking. |
| Unreviewed dependency code | Dependabot PRs are routed hosted by default (see above). With `dependabot: local` their install scripts run on the VM. |
| Host files and credentials | Lima VM with **no mounts** (`mounts: []` + `--mount-none`), no SSH-agent forwarding, and no host SSH keys. `~/.aws`, `gh` auth, `.env` files and working trees on the Mac are not reachable from the guest. |
| Guest ports on the Mac | Guest→host port forwarding is disabled, so a job's service containers never appear on the Mac's `localhost`. |
| **Mac and LAN services from the guest** | **Not isolated.** The guest reaches the Mac at `host.lima.internal` (192.168.5.2, also its gateway and DNS), which Lima maps to the Mac's loopback: every service listening on the Mac is reachable, including ones bound only to `127.0.0.1`, as is the LAN. A firewall inside the guest would not hold, since jobs are root-equivalent there. Until [#18](https://github.com/i2Dev-com/homefield/issues/18) is closed, keep sensitive services off the Mac that hosts the runner. |
| Production | The VM holds no cloud credentials and no AWS CLI. Deploy jobs stay hosted and get their credentials through OIDC. |
| Secrets in jobs | Jobs on the runner receive the secrets their workflow passes, on same-repo PRs. Push-only secrets never reach it by default, because pushes run hosted; they do when `events` includes `push`, `workflow_dispatch` or `schedule`. |
| Across repositories | Every allowed repository's PR jobs share one VM, one after another. Workspaces are per repository, but anything a job leaves in the guest (Docker images, `/tmp`) is visible to the next job from another repository. Allow only repositories you would trust with each other's PR code. |
| Inside the VM | Jobs run as user `runner`, which is in the `docker` group and therefore root-equivalent **inside the guest**. The VM is the boundary, not the user. `runner` may also run one script as root through sudo, `homefield-workspace-owner` (see Maintenance); that grants nothing the `docker` group doesn't. |

**Access checklist.** Check these when something changes (a repository added,
an owner left, a Mac replaced) and now and then regardless. The first two
need an organization owner (`admin:org`):

- The runner group admits exactly the repositories that should use the
  runner, and refuses public ones (the commands are under
  [Runner group](#runner-group)).
- Every repository on that list is private.
- Each adopting repository has `CI_RUNNER` set the way you expect
  (`gh variable get CI_RUNNER --repo <owner>/<repo>`), and its
  `routing-guard` step passes on `main`.
- The VM has no mounts: `bin/homefield upgrade` and `install` check this and
  refuse to continue otherwise.
- Nothing on the Mac listens that PR code should not reach (see the
  network row above), and the Mac holds no credentials the VM could use.
- People who can edit workflow files in an adopting repository are people you
  trust with the runner: a PR runs the workflow from its own branch.

## Runner group

The organization's runner group decides which repositories can use the
runner, because an org runner without a restricted group is usable by every
repository in the organization. `bin/homefield install` looks the group up
before registering and creates it if it is missing: **selected
repositories**, **Allow public repositories** off, so that no repository can
use it until `bin/homefield adopt --repo <owner>/<repo>` adds one
([adopting, step 5](adopting.md#5-merge-then-run-homefield-adopt)). If the
group already exists and is open to all repositories (or to public ones), it
prints a warning and goes on; narrowing it is up to you.

By hand: *Organization settings → Actions → Runner groups → New runner group*,
named `homefield-ci`, repository access **Selected repositories** (add only
the repositories that have adopted the runner), **Allow public repositories**
off. To check a group:

```bash
gh api orgs/<org>/actions/runner-groups -q '.runner_groups[] | "\(.id) \(.name) \(.visibility) public=\(.allows_public_repositories)"'
gh api orgs/<org>/actions/runner-groups/<id>/repositories -q '.repositories[].full_name'
```

**Plans.** Custom runner groups need the GitHub Team plan or Enterprise. On
the Free plan an organization has only the Default group, which every
repository in it can use: register there only if you would trust every
repository with the others' pull-request code, keep **Allow public
repositories** off, and register with `--group Default` (`RUNNER_GROUP=Default`
by hand). `install` cannot create `homefield-ci` on that plan: it prints what
GitHub said and stops. The alternative is a repository-scoped runner, which
only that repository can use. A personal account has no account-wide runners
at all — that part is GitHub's: runners are scoped to a repository, an
organization or an enterprise, and a job never crosses scopes, so a runner
registered to an organization can never serve a repository in a personal
account, and every personal repository registers on its own
(`--url https://github.com/<you>/<repo>`). The one-VM-per-registration part
is ours, not GitHub's: GitHub sets no limit on registrations per machine, but
today one VM runs one runner, so each repository-scoped runner on one Mac is
its own `--instance` VM ([More runners](#more-runners)) until
[#14](https://github.com/i2Dev-com/homefield/issues/14) puts several runners
in one VM.

**The `admin:org` scope.** Looking up and creating groups needs it. If `gh`
lacks it, `install` on a terminal offers to run `gh auth refresh -h github.com
-s admin:org`. It does not offer when `GITHUB_TOKEN` or `GH_TOKEN` is set,
because `gh` uses that instead of its stored login; run
`GITHUB_TOKEN= GH_TOKEN= homefield install ...` to use the stored login, which
may have the scope. Without `gh`, `install` asks before going on with the group
unchecked, and without a terminal it stops. If you created and checked the
group by hand, pass `--group-exists` to go on without asking (registration
fails if the group is missing).

## Setup (once per machine)

Run the [README's one-liner](../README.md#quick-start), or, from a checkout,
`bin/homefield install --url https://github.com/<org>` (or
`https://github.com/<owner>/<repo>`; options: `bin/homefield help`). It needs
Lima ≥ 2.0 (verified on 2.2.0), which the one-liner installs. It does every
step below: it asks for the URL if it was not given, creates the VM and checks
its isolation, provisions it, creates the runner group, registers the runner,
waits until it is online and enables autostart.

The runner is named after the Mac and the instance (`<local hostname>-homefield`,
from `scutil --get LocalHostName`; `--name` picks another), and `install`
refuses a name that is already registered in the scope. The name shows on the
runners page and in job logs. The registration token comes from `gh` when it
can fetch one, and otherwise you paste it. `homefield version` shows the
release you have and says when a newer one exists; read `CHANGELOG.md` for
breaking changes before moving to it.

### What `install` does, by hand

From a checkout of this repository:

```bash
# 1. Create and start the VM (no mounts, no port forwards, Ubuntu 24.04 arm64)
limactl create --name=homefield --mount-none vm/lima.yaml
limactl start homefield

# 2. Confirm the isolation before anything runs in it: no mounts, no home dir
limactl shell homefield -- sh -c 'mount | grep -Ec "virtiofs|9p|sshfs|reverse-sshfs"; ls /Users 2>&1'
# expect: 0, and "No such file or directory"

# 3. Provision: packages, Docker, runner binary (checksum-verified), systemd
#    service, registration at the organization in group homefield-ci. The token
#    goes in on stdin, never on a command line, where any process in the guest
#    could read it; see "Registration tokens" below for where to get it.
#    RUNNER_URL is required. RUNNER_LABEL (default homefield-ci), RUNNER_NAME
#    and RUNNER_GROUP (default homefield-ci) are optional; see the top of
#    provision.sh. RUNNER_NAME defaults to the guest hostname, lima-homefield,
#    which is the same on every Mac: give each runner in the scope its own
#    name. A name that is already registered is refused: remove that
#    registration on the runners page first.
limactl copy vm/provision.sh homefield:/tmp/provision.sh
printf 'RUNNER_TOKEN=%s\n' "$TOKEN" |
  limactl shell homefield sudo RUNNER_URL=https://github.com/<org> \
    RUNNER_NAME="$(scutil --get LocalHostName | tr '[:upper:]' '[:lower:]')-homefield" \
    bash /tmp/provision.sh
unset TOKEN
```

Then, on the runners page (*Organization settings → Actions → Runners*, or
the repository's *Settings → Actions → Runners*), confirm the runner
(its `RUNNER_NAME`, such as `my-mac-homefield`) is **Idle**, in the `homefield-ci`
group for an organization, with labels `self-hosted, Linux, ARM64, homefield-ci`.

Re-running `provision.sh` on a registered runner upgrades it and keeps the
registration. `bin/homefield upgrade` does that: it refuses while a job is
running, stops the runner so no job can start mid-upgrade, and starts it again
at the end (or on failure).

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
it. Run `limactl autostart enable homefield` (Lima 2.x; 1.x called it
`start-at-login`). Inside the VM, the runner is a systemd service and starts
with the guest.

## Adding tools

The VM starts with a small base set (see "Packages" in
[`provision.sh`](../vm/provision.sh)), which is less than `ubuntu-latest`.
Add what your jobs need without editing the script. Per-job toolchains
(`actions/setup-node`, `setup-python`, ...) need nothing here.

**Apt packages:** pass `RUNNER_EXTRA_PACKAGES` when provisioning. The list is
saved in the guest (`/etc/homefield/extra-packages`), so upgrade runs keep it
without passing it again, and the idle-time maintenance upgrades these
packages along with the rest. Passing it again replaces the list; passing it
empty clears it. Neither uninstalls anything. The saved list holds one package
per line; a hand edit may add blank lines or several names on a line, but
anything that is not a package name stops provisioning before the runner is
touched, as it does in the variable.

```bash
bin/homefield upgrade --instance homefield --packages "libpq-dev shellcheck"
# by hand:
limactl copy vm/provision.sh homefield:/tmp/provision.sh
limactl shell homefield sudo RUNNER_EXTRA_PACKAGES="libpq-dev shellcheck" bash /tmp/provision.sh
```

**Anything else:** a hook, a bash script in `/etc/homefield/provision.d/`
ending in `.sh`. Hooks run as root, in name order, on every provisioning run,
after the packages and the `runner` user and before the runner itself is
installed or upgraded. Make them idempotent (skip if already installed). A
failing hook stops provisioning with an error before the runner is touched.
A move (`RUNNER_REREGISTER=1`) has already stopped the runner by then. If a
step fails before the old registration is removed, it reinstalls the service
if needed and starts the old runner again.

The package list is saved only after apt has installed it, so a misspelt name
fails that run and leaves the saved list as it was. Packages go on one line,
separated by spaces.

```bash
limactl copy 50-awscli.sh homefield:/tmp/50-awscli.sh
limactl shell homefield sudo install -D -m 755 /tmp/50-awscli.sh /etc/homefield/provision.d/50-awscli.sh
limactl shell homefield sudo bash /tmp/provision.sh   # runs it now
```

Provision while the runner is idle, as for any upgrade (see "Maintenance").
Everything added here is available to every repository's jobs, so keep
credentials out of hooks.

## Switching (per repository)

`bin/homefield adopt --repo <owner>/<repo>` is the first switch to local: it
also checks the repository's routing and runner group access first, and
refuses to switch until the routing is merged
([adopting, step 5](adopting.md#5-merge-then-run-homefield-adopt)). After
that, `route` flips a repository either way:

```bash
# Back to hosted: the recovery path, and the safe default
bin/homefield route hosted --repo <owner>/<repo> [--repo ...]

# To the local runner
bin/homefield route local --repo <owner>/<repo>
```

`runs-on` is evaluated when a job is queued. **A job that is already queued for
the local runner stays queued after the switch.** `route hosted` therefore
also looks for runs with a job still queued for the routing label (`--label`,
default `homefield-ci`), cancels them and re-runs them, and the re-run goes to
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
| PR job "Waiting for a runner to pick up this job" | VM stopped, Mac asleep or offline, runner service down | The PR's check waits in the queue, and after 24 h GitHub fails it. By default merges and deploys are unaffected, because pushes run hosted; with `push` (or `workflow_dispatch`, `schedule`) in `events`, those jobs wait too. | Start the VM (`limactl start homefield`), or `bin/homefield route hosted --repo <owner>/<repo>`. |
| `install` or `provision.sh` stops: "already registered" or "A runner exists with the same name" | Another runner in the scope has the name: another machine's, or this Mac's from before a VM was deleted without `uninstall` | Nothing is registered; the other runner is untouched | Another machine's: pick another name (`--name`, `RUNNER_NAME`). A stale one of this Mac's: `install --replace`, which removes it after token retrieval but before provisioning, or remove it on the runners page and run again. A provisioning failure after removal leaves the old registration gone; retry the install. Not `config.sh --replace`: it keeps the old registration's runner group ([actions/runner#4091](https://github.com/actions/runner/issues/4091)) |
| Waiting forever although the runner is online and idle | The repository is not in the runner group | Same as above | `bin/homefield adopt --repo <owner>/<repo>` adds it (or add it in the organization settings), or switch the repository to hosted |
| Waiting forever although the runner is online and idle, and the repository is in the group | The label in the expression is not one of the runner's labels. For example, an expression that uses the default label `homefield-ci` while the runner was registered with another label | Same as above | Add the label to the runner (*Settings → Actions → Runners →* the runner *→ Labels*), or pass the runner's label to `routing-guard` as `label:` and use it in the expression |
| A PR job waits while another runs | One runner runs one job at a time, across all repositories | Serialised, not failed | Accept it, switch the less urgent repository to hosted, or add a runner ([More runners](#more-runners)) |
| Job fails only on the local runner | Toolchain or arch gap between the VM and `ubuntu-latest` (arm64 vs x86-64) | Red check | Re-run hosted to confirm. Then add the tool ("Adding tools") or keep that job hosted |
| `No space left on device` in the VM | Docker images and old workspaces | Red check | `limactl shell homefield sudo /usr/local/sbin/homefield-cleanup` |
| Checkout fails with `EACCES: permission denied` deleting files in `_work` | A `container:` job ran as root and left root-owned files, and the runner predates the job-started hook that gives them back (#54) | Red check, on every later job in that repository's workspace | `bin/homefield upgrade` installs the hook, which also fixes the files left so far |
| `pnpm/action-setup` (or another JS action) fails with `Cannot find module '../lib/cli.js'` from `externals.*<version>/node*/bin/npm` | A runner self-update extracted its externals with symlinks followed ([actions/runner#2094](https://github.com/actions/runner/issues/2094), #110), leaving npm, npx and corepack as flattened regular files | With the repairing hook installed, never: the next job's hook relinks them first. On a runner without it, red check on every PR job within ~15 s | `bin/homefield upgrade` installs the repairing hook and verifies npm. Until then, by hand inside the VM, from `/opt/actions-runner`: for each `externals.*/node*/bin`, `ln -sf ../lib/node_modules/npm/bin/npm-cli.js npm`, `ln -sf ../lib/node_modules/npm/bin/npx-cli.js npx`, `ln -sf ../lib/node_modules/corepack/dist/corepack.js corepack` |
| Cancelled job still "in progress" for ~40 s | The runner gives the running step a grace period before killing it | Ends `cancelled`, and service containers are removed | Wait. Only investigate if it lasts minutes |

**Inspecting the guest.** The Lima login user is not in the `docker` group, so
use `limactl shell homefield sudo docker ps`. Plain `docker ps` shows
nothing, which is easy to misread as "no containers".

## Maintenance

- **Runner updates.** The runner updates itself when GitHub releases a new
  version. `provision.sh` pins the version used for a *fresh* install: bump
  `RUNNER_VERSION` and `RUNNER_SHA256` together (the asset `digest` from
  `gh api repos/actions/runner/releases/latest`). Re-running it after a bump
  replaces the binary, which stops the service and cancels a running job, so do
  it while the runner is idle.
  - The update itself has a defect that outlives any version
    ([actions/runner#2094](https://github.com/actions/runner/issues/2094), #110):
    the new `externals.<version>/` tree is extracted with symlinks followed, so
    npm, npx and corepack arrive as regular files and every JS action that
    shells out to npm fails. The job-started hook (below) relinks the flattened
    files before the next job runs and verifies npm works, so the runner heals
    itself. Keeping the runner updated *is* still the right move: the pinned
    version tracks what the runners self-update to, and `--disableupdate` is
    not used, because GitHub stops queueing jobs to a runner more than 30 days
    behind the latest release.
- **Guest OS updates.** Automatic. Ubuntu's own `unattended-upgrades` is
  switched off, because it restarts the runner, containerd and Docker at
  06:00–07:00 whether or not a job is running, and has failed jobs that way
  ([#8](https://github.com/i2Dev-com/homefield/issues/8)). In its place,
  `homefield-maintenance.timer` runs daily at 07:00 guest time (Lima takes the
  Mac's). If a job is running it skips the day. Otherwise it stops the runner,
  runs `apt-get upgrade`, and starts the runner again, or reboots the guest
  first if the update needs it (`/var/run/reboot-required`). Queued jobs wait
  through it, typically under a minute and longer on a reboot.
  - A different hour, when pull requests are rarely opened:
    `limactl shell homefield sudo systemctl edit homefield-maintenance.timer`,
    then add `[Timer]`, an empty `OnCalendar=` (timers add up otherwise) and
    `OnCalendar=*-*-* 03:00`. Re-provisioning keeps it.
  - To update now, while idle: `limactl shell homefield sudo systemctl start
    --no-block homefield-maintenance` (`--no-block`, because the upgrade may
    restart D-Bus and drop a client waiting on the unit).
  - Its log: `limactl shell homefield sudo journalctl -u homefield-maintenance`.
    Whether a reboot is pending: `limactl shell homefield ls
    /var/run/reboot-required`. To reboot by hand while idle: `limactl shell
    homefield sudo systemctl reboot`; the VM keeps running under `vz`.
- **Checking health after an update** (a runner bump, a guest upgrade or a
  reboot): `bin/homefield status` should show the VM running, the service
  running, the job state, and `npm: ok` — the bundled npm the JS actions use,
  which the hook repairs if a self-update flattened it (#110). It shows the
  runner version `provision.sh`
  installed, which stays put; the runner's own version, which moves when it
  updates itself, is
  `limactl shell homefield sudo -u runner /opt/actions-runner/bin/Runner.Listener --version`
  (compare with `gh api repos/actions/runner/releases/latest --jq .tag_name`).
  The runner's diagnostic logs are in `/opt/actions-runner/_diag/`
  (root-readable). Then check the next PR jobs: queued jobs should have
  started, and `bin/homefield memory --days 1` and `bin/homefield report` show
  whether anything looks off.
- **Cleanup.** A daily systemd timer (`homefield-cleanup.timer`) prunes
  stopped containers, unused networks, dangling layers and build cache older
  than 24 h. It also removes any workspace with nothing modified inside it for
  7 days. It skips the run if a job is in progress, and the prune is written to
  be safe if a job starts during it. For that reason it never removes tagged
  images. After a service image version bump, clear the old tags by hand while
  idle: `limactl shell homefield sudo docker image prune --all --force`.
- **Workspace ownership.** A `container:` job runs as root in its container,
  so whatever it writes in the workspace is owned by root, and the next job's
  checkout, as `runner`, could not delete it. Before every job, the runner's
  job-started hook (`ACTIONS_RUNNER_HOOK_JOB_STARTED` in
  `/opt/actions-runner/.env`) runs `/usr/local/sbin/homefield-workspace-owner`
  through sudo, which gives anything in `_work` not owned by `runner` back to
  it, and also repairs the runner's npm when a self-update has flattened the
  externals symlinks (#110, "Runner updates" above); sudo allows that one
  script, with no arguments, and nothing else.
  The hook's output is in the job log, under "Set up runner". A job whose npm
  the hook could not repair fails right there, with the reason, instead of
  deeper in the job.
- **Host memory.** The VM process on the Mac ("Virtual Machine Service") sits
  at roughly the configured `memory` even while idle. The guest fills spare RAM
  with page cache, and Virtualization.framework does not return pages to the
  host once the guest has used them. The size is therefore the idle footprint:
  `memory` in `vm/lima.yaml` is kept close to what jobs need. Restarting the VM
  while the runner is idle resets the footprint until the next jobs refill the
  cache. To resize an existing VM, while idle:
  `limactl stop homefield && limactl edit homefield --memory 5 && limactl start homefield`.
  Queued PR jobs wait through the restart and are then picked up.
  - If `limactl stop` hangs ("did not receive an event with the `exiting`
    status"), power the guest off with `limactl shell homefield sudo systemctl
    poweroff`, then run `limactl stop --force homefield`.
  - If the next `limactl start` hangs at "Explicitly start ssh ControlMaster",
    close the old SSH multiplexer: `ssh -S ~/.lima/homefield/ssh.sock -O exit homefield`.
  - A `limactl hostagent` whose PID is not in `~/.lima/homefield/ha.pid` is a
    leftover with no VM; end it with `kill -9`, because a normal shutdown can
    remove the live agent's files.
- **Measuring it.** Two commands answer "is the runner big enough, and is it
  paying for itself?":
  - `bin/homefield memory [--days N]` summarises the guest's memory log
    (`/var/log/homefield/memwatch-<date>.csv`, one line a minute from samples
    taken every 2 seconds, kept 90 days): per day, the average, the highest
    minute, the highest minute during a job, the lowest available memory and
    any out-of-memory kills. "Used" is total minus available memory. Read the
    peak before lowering `memory`: with no swap, a job that outgrows the VM is
    killed. A runner provisioned before the sampler existed needs
    `bin/homefield upgrade` first. Kills are counted from the kernel's
    cumulative counter, per row against the previous one, and each row also
    records when its boot began: the very first sample of a log
    counts its kills only when that boot is inside the window — kills an
    older boot left in the counter before the log began cannot be placed and
    are not counted (#91). Logs from before the boot column work as before,
    except that their first row is never counted.
  - `bin/homefield report --repo <owner>/<repo> [--repo ...] [--since DATE]`
    lists, per repository, workflow and job, how many jobs ran locally and
    on GitHub's runners, how long they queued and ran, and how many minutes
    they used (for local jobs, what they would have cost hosted). Queue wait
    is what shows whether one runner is enough. It reads the GitHub API with
    `gh`, so it needs no access to the VM. A job still queued, or cancelled
    before a runner was assigned, counts as hosted only when it asks for one of
    GitHub's standard images (`ubuntu-*`, `macos-*`, `windows-*`) without
    `self-hosted`; a larger runner or a runner group has its own name, so such
    a job is not counted until a runner takes it.

## More runners

A runner runs one job at a time. When jobs wait for each other (`bin/homefield
report` shows the queue wait), add a runner: another VM on the same Mac, or
another Mac. Each is a VM with its own registration, under the same label and
runner group as the first, and GitHub gives each queued job to whichever
runner is idle. Repositories and their routing don't change.

**On the same Mac**, a second instance:

```bash
homefield install --instance homefield-2 --url https://github.com/<org>
```

It is named `<local hostname>-homefield-2`. An instance name follows Lima's
rule (letters and digits, with a single `.`, `_` or `-` between them, at most
76 characters, not ending in `.yml` or `.yaml`), and homefield refuses any
other. `status`, `upgrade`, `memory` and
`uninstall` act on one instance (`--instance`, or `HOMEFIELD_INSTANCE`), so run
them for each; `route` and `adopt` act on repositories and cover every runner.
If the first runner was installed with a `--label`, `--group` or `--packages`
other than the defaults, pass the same ones.

If the first runner has hooks ([Adding tools](#adding-tools)), create the
second VM first and put the hooks in before `install` registers it, or the
jobs it takes in between run without them (a failing hook stops `install`
before it registers). `--cpus` and `--memory` go on `limactl create`, not on
`install`:

```bash
limactl create --name=homefield-2 --mount-none --tty=false ~/.local/share/homefield/vm/lima.yaml
limactl start --tty=false homefield-2
limactl copy 50-awscli.sh homefield-2:/tmp/50-awscli.sh
limactl shell homefield-2 sudo install -D -m 755 /tmp/50-awscli.sh /etc/homefield/provision.d/50-awscli.sh
homefield install --instance homefield-2 --url https://github.com/<org>
```

Memory is the cost: each VM holds up to its `memory` (5 GiB by default) on
the Mac even while idle ([Maintenance](#maintenance), "Host memory"), so two
take about 10 GiB. Check the first one's peak with `homefield memory` before
going lower.

**On another Mac**, install the tool there ([Setup](#setup-once-per-machine))
and run `homefield install` with the same URL, label, group and packages, and
the hooks put in first as above. The runner is named after that Mac, and a name
already in use is refused ([Failure modes](#failure-modes)). The runner group
is used as it is. Registering at an organization needs an organization owner's
`gh` login with `admin:org`, or a registration token pasted when asked.

With **v0.1.0**, the runner is named `lima-homefield` on every Mac and
registered with `config.sh --replace`, so a second Mac takes over the first's
registration and nothing reports an error. Pass a `--name` that no other
runner in the scope uses (CHANGELOG, #52).

Every runner serves every repository in the group, so the
[trust boundary](#trust-boundary)'s "Across repositories" holds on each; jobs
that run at the same time are in separate VMs. `bin/homefield route hosted
--repo <owner>/<repo>` takes a repository off all of them at once. Several
runners in one VM, to save the memory, is tracked in
[#14](https://github.com/i2Dev-com/homefield/issues/14).

### Operating several runners

Nothing in the tool shows the whole set: every command except `route` and
`adopt` acts on one VM on the Mac you run it on.

**List them.** GitHub's runner list is the one place that has every runner. It
needs an organization owner with `admin:org` (a repository admin, for a
repository's runner):

```bash
gh api --paginate "orgs/<org>/actions/runners?per_page=100" --jq '
  .runners[] | select(.labels | map(.name) | index("homefield-ci"))
  | [.name, .status, (.busy | tostring), .version, (.labels | map(.name) | join(","))] | @tsv'
```

Use your `RUNNER_LABEL` for `homefield-ci`. `offline` means the Mac is asleep
or off, or the VM or service is stopped: run `bin/homefield status` on it.
`version` is the runner's own version, which moves when it updates itself, not
the `homefield` version.

**A runner GitHub removed.** GitHub removes a runner that has not connected
for more than 14 days, so a Mac left off that long comes back unregistered:
the VM still has its registration, but the runner fails with "The runner
registration has been deleted from the server" and its service stops. A runner
missing from this list is the sign, and `bin/homefield status` says
`github: NOT listed` (and exits 1) when gh can read the list; otherwise it
says `github: not checked` and the VM's copy is all it can see. The GitHub
ask waits at most 15 s (`HOMEFIELD_GH_TIMEOUT` to change it): on a dead
network `status` says `github: not checked (timed out ...)` and still prints
everything it can answer from the VM. `upgrade`, and
`install` on that VM, refuse before anything is stopped; without gh, the
upgrade runs and fails at the end, when the service does not reach "Listening
for Jobs", and says why. Register it again (#76):

```bash
bin/homefield uninstall --instance <name> --keep-vm
bin/homefield install --instance <name> --url https://github.com/<org>
```

`uninstall` removes only the VM's copy of a registration GitHub no longer
lists (`config.sh remove --local`, no token). Without gh to tell, it asks for a
remove token and runs the full `config.sh remove`; on the registrations we have
seen, the runner (2.337.0) finds no runner on GitHub and skips that part. If it
fails instead (the runner's service is put back, still unregistered), remove
the VM's copy by hand, then run `install` as above:

```bash
limactl shell <name> sudo sh -c 'cd /opt/actions-runner && ./svc.sh uninstall && sudo -u runner ./config.sh remove --local'
```

The VM and its extra packages are kept. The label and group are not
stored in the VM, so pass `install` the same `--label`, `--group` and `--name`
as the first time if they were not the defaults.

**Upgrade them.** On each Mac: `homefield version`, the README's one-liner
again, then `homefield upgrade --instance <name>` for each VM on it.
`upgrade` refuses while a job is running and takes the runner down until it is
done, so do one runner at a time; the others keep taking jobs. Runners on
different versions work together, because each takes jobs on its own and the
routing guard lives in the repositories' workflows. But a fix to the VM only
reaches a runner when `upgrade` runs on it (the job-started hook, #54, is one),
so a failure on only some runs may be a Mac you skipped. Read the CHANGELOG's
upgrade notes first.

**Keep them alike.** Extra packages and hooks live only in each guest, so two
runners under one label can differ unnoticed, and a job passes or fails
depending on which one it lands on. Keep the hooks in a versioned directory,
install them on every VM from it, and give every Mac the same `--packages`. To
compare, `bin/homefield status` prints `extra packages:` and `limactl shell
<instance> ls /etc/homefield/provision.d` lists the hooks. `upgrade` runs the
hooks again, so a changed hook applies on the next upgrade.

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
limactl copy vm/provision.sh homefield:/tmp/provision.sh
printf 'RUNNER_REMOVE_TOKEN=%s\nRUNNER_TOKEN=%s\n' "$REMOVE" "$TOKEN" |
  limactl shell homefield sudo RUNNER_REREGISTER=1 \
    RUNNER_URL=https://github.com/<new-scope> RUNNER_NAME=<name> RUNNER_LABEL=<label> \
    bash /tmp/provision.sh
unset REMOVE TOKEN
```

If service uninstall or removal of the old registration fails, the script
restores the old service and starts it again. Fix the cause and re-run the
same command with fresh tokens. If a later step fails, for example the new
service does not come up, re-run the same command. A runner already registered
at the new scope is not removed again, so the stale remove token does no harm.

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

`bin/homefield uninstall` deregisters the runner (fetching or asking for a
remove token), turns off autostart and deletes the VM; `--keep-vm` only
deregisters. By hand:

```bash
# Every repository that routes to it: switch to hosted first
gh variable set CI_RUNNER --repo <owner>/<repo> --body hosted
# REMOVE: org remove-token (orgs/<org>/actions/runners/remove-token, admin:org)
printf '%s\n' "$REMOVE" | limactl shell homefield sudo sh -c 'cd /opt/actions-runner && ./svc.sh uninstall && read -r t && ACTIONS_RUNNER_INPUT_TOKEN="$t" sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u runner ./config.sh remove'
unset REMOVE
limactl delete --force homefield
```

`config.sh remove` refuses while the service is installed, so the service goes
first. If GitHub then refuses the removal (a rejected token, no network), or
`svc.sh uninstall` stops partway, `bin/homefield uninstall` gives the service
back and starts it, so the runner keeps taking jobs; run it again once the
cause is fixed. By hand, `provision.sh` does that and works out what the
uninstall left behind:

```bash
limactl copy vm/provision.sh homefield:/tmp/provision.sh
limactl shell homefield sudo bash /tmp/provision.sh ensure-service --start
```

If that fails too, `bin/homefield install` sets the service up again.

If the VM cannot be asked (a `limactl shell` that fails) whether the runner is
registered, whether a job is running, or whether it has a service, `uninstall`
and `upgrade` stop before anything is stopped or deleted, `--force` included,
and `install` stops too; `status` says "runner: unknown" or "job: unknown" and
exits 1. The same holds when Lima itself cannot say whether the VM exists
(`limactl list` fails): the commands stop with "could not ask Lima", and
`status` says "VM ...: unknown".
Check that the VM is running (`limactl list`) and run the command again.

If the VM is already gone, delete the stale registration on the runners page.

## Moving to dedicated hardware

The VM definition and `provision.sh`, plus what was added under "Adding tools",
make up the machine. The additions live only in the guest
(`/etc/homefield/extra-packages` and `/etc/homefield/provision.d/`), so copy
them out first, and keep hooks somewhere versioned rather than only in the VM:

```bash
limactl shell homefield cat /etc/homefield/extra-packages   # pass as RUNNER_EXTRA_PACKAGES
limactl shell homefield sudo tar -C /etc/homefield -cf - provision.d > provision.d.tar
```

On a Linux box, run `provision.sh` directly on an Ubuntu 24.04 host or VM. It
hardcodes the linux-arm64 tarball, so an x86-64 host needs a different tarball
and checksum, and consumers' `routing-guard` then takes `arch: x64` along with
the matching expression. On another Mac, repeat [Setup](#setup-once-per-machine).

The move, as a checklist:

1. Copy the extra-packages list and the hooks out of the old guest (above),
   and keep the hooks in version control.
2. Provision the new machine with the same `RUNNER_LABEL`, group, extra
   packages and hooks, and a different `RUNNER_NAME` (`bin/homefield install`
   names it after the Mac and refuses a name already in use). Two runners with
   one label share the queue, so it takes jobs once it is online.
3. Confirm it is online on the runners page.
4. Same CPU architecture: to see a job from each adopting repository pass on
   the new runner, stop the old runner's service while it is idle
   (`limactl shell homefield sudo systemctl stop "$(limactl shell homefield sudo cat /opt/actions-runner/.service)"`),
   run a PR in each repository, and check that the run's log names the new
   runner. If it fails, start the old service again.
   Different architecture: the expression's labels name the old one, so no job
   can reach the new runner yet. Once it is online, change the `routing-guard`
   `arch` and the expression's labels in each adopting repository, one PR
   each; that PR's own routed jobs run on the new runner and are the
   validation. Repositories not yet changed keep going to the old runner.
5. Retire the old runner while it is idle: `bin/homefield uninstall` on the old
   Mac (switch the repositories to hosted first if the new runner is not up).
   The memory log (`/var/log/homefield/`) stays with the old guest; copy it
   out first if you want the history.
6. Re-check "Access checklist" for the new machine, and compare `bin/homefield
   report` before and after.
