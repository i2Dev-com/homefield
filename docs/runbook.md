# Runbook: local self-hosted CI runner

Operating the runner: one Lima VM on a Mac, registered at an **organization**
(and limited by a runner group to the repositories allowed to use it) or at
one repository. Selected pull-request jobs run on it instead of on
GitHub-hosted runners; GitHub is still where CI is triggered, where logs live
and where checks report. Which jobs a repository routes is documented in that
repository. To add one, follow [`adopting.md`](adopting.md).

Commands below act on every HomeField VM on the Mac by default, or on one when
you pass `--instance NAME` (or set `HOMEFIELD_INSTANCE`) — for a first install,
that is also how you pick its instance name (`homefield` unless given).
`<org>`, `<owner>` and `<repo>` are yours.

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
| Host files and credentials | Lima VM with **no host data mounts** (`mounts: []` + `--mount-none`), no SSH-agent forwarding, and no host SSH keys. `~/.aws`, `gh` auth, `.env` files and working trees on the Mac are not reachable from the guest. The one expected mount is Apple's read-only Rosetta share (`vz-rosetta on /mnt/lima-rosetta`, [#21](https://github.com/i2Dev-com/homefield/issues/21)): Apple's translator, nothing of the Mac's, writes refused. |
| Guest ports on the Mac | Guest→host port forwarding is disabled, so a job's service containers never appear on the Mac's `localhost`. |
| **Mac and LAN services from the guest** | **Partly isolated.** The guest reaches the Mac at `host.lima.internal` (192.168.5.2, also its gateway and DNS). On VMs created on Lima ≥ 2.3.0 (the minimum), `networkOpts.hostLoopback: false` makes that gateway answer for itself, so **nothing** bound to the Mac's loopback is reachable through it — services bound only to `127.0.0.1` and `*`-bound ones alike; `*`-bound services and the wider LAN stay reachable through the Mac's LAN address. `install` and `upgrade` prove the state from inside the guest ([Host loopback exposure](#host-loopback-exposure)). A firewall inside the guest would not hold, since jobs are root-equivalent there. Keep anything the runner's repositories should not reach off the Mac that hosts them ([#18](https://github.com/i2Dev-com/homefield/issues/18)). |
| Production | The VM holds no cloud credentials. Deploy jobs stay hosted and get their credentials through OIDC. |
| Secrets in jobs | Jobs on the runner receive the secrets their workflow passes, on same-repo PRs. Push-only secrets never reach it by default, because pushes run hosted; they do when `events` includes `push`, `workflow_dispatch` or `schedule`. |
| Across repositories | Every allowed repository's PR jobs share one VM, one after another. Workspaces are per repository, but anything a job leaves in the guest (Docker images, `/tmp`, and through `sudo` the packages it installs and the services it enables) is visible to the next job from another repository. Allow only repositories you would trust with each other's PR code. |
| Inside the VM | Jobs run as user `runner`, which is in the `docker` group and therefore root-equivalent **inside the guest**, and has passwordless `sudo` as a hosted Linux runner does. The VM is the boundary, not the user: neither adds reach the other did not give. |
| Provisioning tokens | A registration or removal token reaches the guest only on stdin, and only into a VM that has **never run a job**: jobs are root-equivalent, so a root process a job left behind could read the token from the provisioning process's environment. What counts as "never ran a job" is decided on the **Mac, not in the guest**: the state file records whether a runner has ever been registered on this VM, and a VM that has been registered is refused outright — a job's leftover root process could delete the `_work` marker the guest probe checks, so the guest's own answer is not the boundary. `install` refuses a registered VM even when `_work` is absent, and a
  `reset` that keeps the VM (`--keep-vm`, or a delete that failed) keeps
  the record, so a retained VM cannot be re-registered into; `re-register`
  re-registers only a VM it has just cloned fresh from the base (with the
  reset on — a skipped reset leaves the old VM and is refused too). The `_work` probe stays as the second line on never-registered VMs and on the fresh clone. Deregistration (`uninstall`, `reset`) removes the registration through the GitHub API from the Mac, so no removal token enters the guest at all. |

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
- The VM has no host data mounts: `bin/homefield upgrade` and `install` check
  this and refuse to continue otherwise. Apple's read-only Rosetta share is
  expected and does not count against it.
- Nothing on the Mac listens that PR code should not reach (see the
  network row above), and the Mac holds no credentials the VM could use.
- People who can edit workflow files in an adopting repository are people you
  trust with the runner: a PR runs the workflow from its own branch.

## Host loopback exposure

`vm/lima.yaml` asks Lima to stop mapping `host.lima.internal` onto the Mac's
loopback (`networkOpts.hostLoopback: false`, lima-vm/lima#5581, honoured
since Lima 2.3.0 — the version the tool requires, released 2026-11-06).
Nothing bound to the Mac's loopback is then reachable through that
address — `127.0.0.1`-only services and `*`-bound ones alike; `*`-bound
services stay reachable through the Mac's LAN address, because the line
closes the loopback, not the network. The
block is applied when the VM starts, so after `brew upgrade lima` it takes
effect only once the VM has been stopped and started again. This is issue
[#18](https://github.com/i2Dev-com/homefield/issues/18).

`install` and `upgrade` do not take the config's word for it. They stand a
throwaway listener on the Mac's `127.0.0.1` and connect to it from inside the
guest (`nc` on the Mac does this; without it the probe reports itself
skipped). The listener answers with a token the probe's own first connect
must read back, so what answers is provably the probe's listener and not
some service that already held the port; and inside the guest only a refused
connect counts as closed — a name that does not resolve, a silent timeout
and anything else that is not "Connection refused" are treated as unproven,
never as isolation:

| Probe says | Meaning | What to do |
|---|---|---|
| `loopback probe: closed` | The guest cannot reach the Mac's loopback | Nothing. |
| `#18: jobs in VM ... can reach the Mac's loopback` | A VM whose stored config does not show the block (absent, or unreadable) | Recreate the VM, or stop it and add the setting with `limactl edit`, then start it (below). |
| `... although its config sets networkOpts.hostLoopback: false` | The block was asked for and the installed Lima honours asks, yet the guest gets through. Most likely the VM has been running since before the Lima upgrade and still has the old gateway. Nothing was stopped or registered. | Stop the VM, start it, and run this again. If it still gets through, check `limactl --version` and `~/.lima/<name>/lima.yaml`; if both are right, the boundary is broken — report it (SECURITY.md). A fresh install leaves the VM (and possibly the runner group) behind. |
| `#18 probe skipped (...)` or `no clear answer ...` | Nothing proved (no `nc` on the Mac, port in use, an `nc` without `-k`, guest unreachable, or an answer that is neither open nor closed) | The run goes on; treat the exposure as present until a probe answers. |

To close an existing VM after upgrading Lima: if it was created from this
repository's `vm/lima.yaml`, its stored config already asks for the block
and a restart is enough (`limactl stop <name> && limactl start <name>`);
otherwise add the lines below first. No rebuild either way — the extra
packages and hooks stay:

```bash
limactl stop <name>
EDITOR=vi limactl edit <name>     # add these two lines at the top level:
                                  #   networkOpts:
                                  #     hostLoopback: false
limactl start <name>
bin/homefield upgrade             # probes before anything is stopped; it should say "loopback probe: closed"
```

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
(`--url https://github.com/<you>/<repo>`). `install` finds out which kind of
account owns the URL before it asks for anything else and, for a personal
one, skips the group step, prints both limits and ends with advice saying
the runner serves only that repository; an owner URL alone gets a prompt for
the repository on a terminal, and an error naming
`--url https://github.com/<you>/<repo>` without one. `--personal` and `--org`
force the answer and skip the lookup (for an unreachable API, or a token that
cannot see the account); a repository URL whose owner cannot be looked up goes
on with a note, an owner URL stops and names these two flags. `--group` is ignored on a personal account, as it
already is for any repository URL. The one-VM-per-registration part
is ours, not GitHub's: GitHub sets no limit on registrations per machine, but
today one VM runs one runner, so each repository-scoped runner on one Mac is
its own `--instance` VM ([More runners](#more-runners)) until
[#14](https://github.com/i2Dev-com/homefield/issues/14) puts several runners
in one VM.

### The `admin:org` scope

Looking up and creating groups needs it. If `gh`
lacks it, `install` on a terminal offers to run `gh auth refresh -h <host>
-s admin:org`, where <host> is the registration's GitHub host (`--url`'s, or
`HOMEFIELD_GITHUB_HOST`; github.com by default). It does not offer when
`GITHUB_TOKEN` or `GH_TOKEN` is set, because `gh` uses that instead of its
stored login; run `GITHUB_TOKEN= GH_TOKEN= homefield install ...` to use the
stored login, which may have the scope. Without `gh`, `install` asks before
going on with the group unchecked, and without a terminal it stops. If you
created and checked the group by hand, pass `--group-exists` to go on without
asking (registration fails if the group is missing).

### The `workflow` scope

Writing `.github/workflows/` through the Contents
API needs it — a classic PAT's `workflow` scope — and GitHub answers a bare
404 without it, though the same token writes everywhere else in the
repository. `homefield adopt --setup` checks the scope of gh's active login
first and stops before anything is created when it is missing; a token whose
scopes GitHub does not report (a fine-grained or App token) or an env-var
token cannot be checked, and the write's own 404 says the likely cause. To
add the scope to gh's stored login: `gh auth refresh -h <host> -s
workflow`, with <host> the host adopt works on (`HOMEFIELD_GITHUB_HOST`;
github.com by default). `GITHUB_TOKEN`/`GH_TOKEN` must carry the scope
themselves; gh's `auth refresh` cannot add it to them.

## Setup (once per machine)

`homefield setup` is the whole first-time setup in one command: it runs the
prerequisite check below and stops when any check fails, then does what
`install` does (the steps below) and ends with a summary and the next steps.
Run `homefield preflight` on its own to verify the prerequisites (macOS,
Apple Silicon, Lima ≥ 2.3, gh, a python3 that actually runs, Homebrew) are in
place. It exits 0 when all pass, 1 otherwise, with messages pointing to the
exact fix command (`brew install lima`, `gh auth login`, and so on; a missing
Homebrew points at <https://brew.sh>). For gh it reads the active
account from `gh auth status --json hosts`, so an App-installed token (which
reports no scopes) is accepted; a token without `admin:org` only warns, because
an organization URL needs that scope while a repository URL does not. The
`setup` command prints it first and stops on any failed check, before creating
or touching anything (a warning does not stop it). On a terminal, when gh is
installed, has no active login and no other check fails, `setup` first offers
`gh auth login -h <host>` (gh asks its own questions) and runs the check
after it. When `--url` is an organization's owner URL (looked up, or `--org`),
the login is `gh auth login -h <host> -s admin:org`, so the scope the
runner group needs comes with the one browser authorization instead of a second
one at the group step; a repository URL, a personal account, `--personal`, no
`--url` yet or an owner that cannot be looked up keep gh's default login, and
the scope is offered later, as above; declining, end of input, a login that does not finish, or no terminal
leaves the check to fail as above. <host> is the registration's GitHub host
(`--url`'s, or `HOMEFIELD_GITHUB_HOST`; github.com by default). It does not offer when another check fails
too (a browser login would only be followed by the stop), when `gh` cannot
answer the login question at all (a login would not fix that), or when
`GITHUB_TOKEN` or `GH_TOKEN` is set, since `gh` uses that instead of its stored
login. `preflight` and `diagnose` only report. `install` does not offer the
login; it prints the preflight report and then
gates on its own subset — macOS, Apple Silicon, Lima — before creating
anything:

```bash
homefield preflight
```

Run the [README's one-liner](../README.md#quick-start), or, from a checkout,
`bin/homefield setup --url https://github.com/<org>` (or
`https://github.com/<owner>/<repo>`, which is what a personal account needs;
on a GitHub Enterprise Server or GHE.com host, the URL carries that host
instead, and commands without a `--url` take it from `HOMEFIELD_GITHUB_HOST`;
options: `bin/homefield help`). It needs
Lima ≥ 2.3 (verified on 2.3.0), which the one-liner installs, with gh, in one
Homebrew question (`HOMEFIELD_YES=1` answers it; Lima is required, so declining
it, or no terminal without `HOMEFIELD_YES=1`, stops the one-liner with the brew
command to run, while a missing gh never does and is left to `setup`'s
preflight). `setup` runs
`install`, which does every step below (the one-liner hands over to `setup`, or
to `install` when the release it installed has no `setup`): it asks for the URL if it was not given, creates the VM and checks
its isolation, provisions it, creates the runner group, registers the runner,
waits until it is online and enables autostart. Right after the URL it says
whether the owner is an organization or a personal account (see *Plans* under
[Runner group](#runner-group)).

`setup` ends with a summary instead of `install`'s short advice: one line each
for the VM (created or already there), the isolation check, the runner group
(created, found, or what is wrong with it), the registered runner (name and id)
and whether it is online with its labels. A line starts with a check mark when
the step is done and was seen to be true, and with `!` when it needs attention:
a runner group wider than recommended, a group that could not be checked, a
runner that was not online within the wait or whose group could not be
confirmed. A `!` line does not change the exit status, which stays 0 once the
runner is registered. The next steps follow: route a repository with
`homefield adopt --repo <owner>/<repo>`, the guide
([`docs/adopting.md`](adopting.md)), advice for the group's state, and the
repositories that can use the runner now. That list is group access, not
whether a repository's `CI_RUNNER` is `local`: for an organization it is the
repositories the selected group admits (read from GitHub; a list that could not
be read is said so), for a repository or personal registration the one
repository, and for the Default group, a group wider than recommended or one
that was not checked, no list.

After the summary, on a terminal, a fresh `setup` offers to open the routing
pull request and carry on once you merge it, so the next commands do not have
to be typed. A repository-scoped registration (a personal account, or a
repository URL) knows the repository and asks `Open the routing pull request
for <owner>/<repo> now, and carry on once you merge it? [Y/n]`; Enter or `y`
runs `homefield adopt --repo <owner>/<repo> --setup --wait` (on a GitHub host
other than github.com, in that host's environment, so the offer works on the
host the runner was registered at; the commands printed for later carry
`HOMEFIELD_GITHUB_HOST=<host>` for the same reason). An organization asks
`Repository to route first (name or owner/repo; Enter to skip)`: a bare name
means `<org>/<name>`, and text that is not a repository name is refused without
running anything. `n`, Enter at the organization question and end of input
(Ctrl-D) skip it, with a line naming the command for later. Nothing is created
on GitHub without the answer, and `adopt` keeps its own checks (it refuses a
public repository and needs write access). `setup` then waits in that run, as
[`adopt --setup --wait`](adopting.md#let-adopt-write-steps-1-to-4) does, for up
to 60 minutes: when you merge the pull request it adds the repository to the
runner group and switches it on, and `setup` ends. If `adopt` fails, its message
is already above and the setup stays a success (exit 0), and `setup` says what
is left, by the status `adopt` exited with (`4` and `5` are new for `--wait`;
`adopt` exits 1 as ever for anything before the pull request exists):

| `adopt` ended | `setup` prints |
| --- | --- |
| Before a pull request existed (exit 1: a public repository, no write access, no workflow to route, the branch already there) | `The routing pull request was not opened`, and `To try again: homefield adopt ...` with the same arguments |
| With the pull request open and not merged (exit 4: the 60 minutes ran out, it was closed without a merge, or five reads in a row failed) | `The routing pull request is open; adopt stopped waiting for it`, and no `--setup` retry, as the branch exists: `adopt` printed what to run next (`homefield adopt --repo <owner>/<repo>` once it is merged) |
| After the merge (exit 5: the routing check, group access or the switch failed) | `The routing pull request was merged but adopt did not finish switching the repository`, and `homefield adopt --repo <owner>/<repo>` with the `--label` and `--group` the runner was registered with, if any (without `--group` it would look at `homefield-ci`, not the group the runner joined) |
| Ctrl-C or SIGTERM (exit 130 or 143), in any phase: before the pull request existed, while it was being opened, waiting for the merge, after the merge, or during `--verify` | `The runner is set up. adopt was interrupted`, and `setup` itself ends with 130 or 143 because you cancelled. What `adopt` printed says where things stand and what to run next (it takes back a branch that has no pull request, and leaves one whose pull request may exist). A SIGTERM sent to `setup` alone ends it at once, with 143, and its `adopt` stops by itself, saying setup ended, at its next check, within 10 seconds (one poll interval; a step already in progress finishes first) |

Without a terminal there is no question, and an instance that is already
registered (the upgrade) is not offered it.

On an instance that is already registered,
`setup` upgrades it like `install` and ends with a shorter summary that does not
look at the runner group again.

The wait polls for the runner to show online on GitHub, up to about 90 seconds (18 tries at 5 seconds each). It reports progress every 15 seconds — `waiting for <name> (up to 90 s, waited 15 s)` — and says nothing when the runner appears online before the first report. Those three settings are read from the environment where `install` runs: `ONLINE_WAIT_TRIES` (default 18), `ONLINE_WAIT_INTERVAL` (default 5) and `ONLINE_PROGRESS_CYCLES` (default 3, the polls per progress line; a value below 1 falls back to 3).

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

# 2. Confirm the isolation before anything runs in it: no host data mounts
#    (the read-only vz-rosetta share is expected), no home dir
limactl shell homefield -- sh -c 'mount | grep -E "virtiofs|9p|sshfs|reverse-sshfs" | grep -vc "^vz-rosetta on /mnt/lima-rosetta type virtiofs (ro,"; ls /Users 2>&1'
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
limactl copy -r vm/guest homefield:/tmp/guest   # the helpers provision.sh installs
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

- Either `gh api -X POST orgs/<org>/actions/runners/registration-token --jq .token`
  (with the `admin:org` scope), or `repos/<owner>/<repo>/...` for a
  repository.
- Or the runners page → *New runner → Linux*. The page shows the token in its
  `config.sh` line; copy only the token.

**Autostart.** The VM does not restart after a reboot unless something starts
it. Run `limactl autostart enable homefield` (Lima 2.x; 1.x called it
`start-at-login`). Inside the VM, the runner is a systemd service and starts
with the guest.

**Warm-up check.** Both `vm/provision.sh` and `homefield setup` / `install`
run a bounded warm-up check before the first routed job: Docker daemon
responsiveness (`docker info`), runner service health (`actions.runner.*.service`),
and armed maintenance timers (`homefield-cleanup.timer` and
`homefield-maintenance.timer`). `setup` reports this in its summary (`✓ VM warm
(docker, runner, timers)` or `! Warm-up incomplete (...)`). To re-check a
running VM later, run `homefield status` or `homefield diagnose`.

**Ephemeral mode (`--ephemeral`).** By default, the runner is persistent across
jobs. Pass `--ephemeral` to `homefield install` / `setup` (recommended on
throwaway VMs) to register with `config.sh --ephemeral` (one job per
registration). After a job finishes, `homefield re-register` (or `homefield
re-register --watch`) fetches a fresh one-hour token on the host via `gh`, pipes
it on stdin to `provision.sh re-register`, and restarts the service. Trade-off:
each job incurs a few seconds of cold registration instead of reusing a
persistent registration. If re-registration fails, the runner is left visibly
offline (`homefield status` reports the error).

**VM reset (`--reset-vm`).** `homefield install --ephemeral --reset-vm` adds a
clean root disk to every job: the install provisions the VM unregistered
(a prepare-only provision run), clones it while stopped to a base VM named
`<instance>-base` (an instant APFS copy-on-write `limactl clone`), and only then
registers the working VM, so the base stays behind as the stopped, unregistered
source every later reset clones from. Each `re-register` with the reset on —
one-shot or `--watch` after every job — stops the VM, deletes it, clones a fresh
one from the base and registers that instead, so each job starts from a clean
root disk. What survives the reset is what the base's disk image carries (apt
packages, hooks, sudoers, timers, the runner binary); what does not is what the
job created (Docker images, caches, anything outside the base). The trade-off
against plain `--ephemeral`: a reset pays one clone (seconds) and a full boot
plus registration per job, and a Docker cache has to rebuild from zero, so
image-heavy jobs should prefer `--job-cleanup` (keeps tagged images warm) or
plain ephemeral mode.

The switch is saved in the instance state, and `homefield status` shows it
(`vm reset: on (each re-register clones a fresh VM from <instance>-base)`).
`upgrade --reset-vm` turns it on for an installed VM (the base must already
exist — only install creates it), `--no-reset-vm` turns it off, and
`re-register --reset-vm` / `--no-reset-vm` override it for one invocation.
Failure policy: a reset that cannot run (the base is missing, or the stop or
delete failed) is skipped — the old VM is re-registered as it is and `status`
reports the `reset_error`, retried on the next cycle; a clone that fails after
the delete leaves the VM gone with `ephemeral_error` recorded, a one-shot
`re-register` exits nonzero, and the `--watch` loop stays alive — its next
cycle (or a manual `re-register`) clones the VM back from the base; recovery
is exactly what the base is for. Only a base that install marked as a reset
base is ever replaced: an ordinary runner named `<instance>-base` is refused,
never deleted. `start`/`stop`/`status`/`fleet` and
the watch loop never touch the base VM (`vm_instances` skips it; use
`--instance <name>-base` to act on it directly).

`uninstall` and `reset` delete a marked base with the VM, so removing a
`--reset-vm` runner leaves nothing behind; a base that cannot be deleted is
reported with the hand command (`limactl delete -f <instance>-base`). When the
runner VM is already gone — a base a previous reset could not delete, or one a
failed re-register clone left behind — `reset` removes the orphaned base on
its own, so a retry cleans it up. The base
is never upgraded, by decision ([#297]): clones get OS updates through the
in-guest maintenance, but a change to the VM's own settings (CPU, memory, disk)
or a provisioning change needs the base rebuilt, which means uninstall and
install again with `--reset-vm` — one command each way, since the uninstall
takes the base with it.

## What the VM has, compared with a hosted runner

The bar for switching a job is that it runs the same on the VM as on a hosted
runner. The VM is Ubuntu 24.04, which `ubuntu-24.04` selects on GitHub; that
image is the stable baseline below. `ubuntu-latest` is moving to Ubuntu 26.04
by 2026-11-19, with a different preinstalled set, so point `fallback` at
`ubuntu-24.04` where a job depends on its exact packages and recheck this table
after the migration. Most gaps close by provisioning; the right column says
what to do. Check this before choosing jobs
([adopting, step 1](adopting.md#1-choose-the-jobs)), and again when a job
passes hosted but fails locally.

| What | On the hosted Ubuntu 24.04 image | In the VM | What to do |
|---|---|---|---|
| Privileges | passwordless `sudo` | passwordless `sudo`, as a hosted Linux runner has; `runner` is already root-equivalent through the `docker` group ([Trust boundary](#trust-boundary)) | Nothing to do on a current VM: a job's `sudo apt-get install`, `sudo systemctl` and `playwright install --with-deps` work. A VM provisioned before #176 upgrades first (update the tool, then `bin/homefield upgrade`, [Failure modes](#failure-modes)). Pre-provisioning still makes a large set faster and saves network ([Adding tools](#adding-tools)) |
| Apt packages | dozens, including `shellcheck`, `sqlite3`, `xvfb`, `rsync` | a small base set ([Packages](../vm/provision.sh)) | Add to `RUNNER_EXTRA_PACKAGES`, or a hook for what apt cannot supply; `--preset hosted` adds the common ones at once ([Adding tools](#adding-tools)) |
| CLI tools | AWS CLI, Azure CLI, Google Cloud CLI, SAM CLI, GitHub CLI | none installed | Hook or apt (`gh` is in noble, older than the image's). `awscli` has no noble candidate, so the AWS CLI v2 bundle comes in by hook; `--preset hosted` installs both. Azure, gcloud and SAM are usually easier through their own actions |
| Browsers | Chrome, Chromium, Firefox and Edge, with drivers and OS libraries | no browser binary; OS libraries at job time through `--with-deps`, or pre-provisioned | Playwright and Puppeteer download their own browser, and `--with-deps` installs the OS libraries now that `runner` has sudo ([Browsers](#browsers)). Pre-provisioning them saves time and network only for a tool that then installs without `--with-deps`. Jobs that drive Chrome, Firefox or Edge directly stay hosted |
| Languages | Node, Python, Java, Ruby, PHP, Rust and more, each pinned by the image | `python3` 3.12 (same as Ubuntu 24.04); no Node, Java, Ruby, PHP or Rust | Setup actions (`actions/setup-node`, `setup-*`) work here and give the job its version. A job that assumes a bare `node`, `npm` or `java` needs it provisioned (noble's `nodejs` is 18.19, against the image's Node 22; `--preset hosted` installs that major), or stays hosted |
| Architecture | x86-64 by default; `ubuntu-24.04-arm` is a hosted image too | arm64, with x86-64 binaries and `linux/amd64` containers translated by Apple's Rosetta ([#21](https://github.com/i2Dev-com/homefield/issues/21)) | `docker run --platform linux/amd64` and x86-64 ELF files work as they are. `docker buildx build --platform linux/amd64` needs the `buildx-rosetta` preset first ([Building amd64 images](#building-amd64-images)); without it, BuildKit's bundled QEMU segfaults Node-heavy steps. Arm jobs can point `fallback` at `ubuntu-24.04-arm` ([routing options](adopting.md#routing-options)) |
| State between jobs | a fresh VM for every job | one VM, used in turn by every allowed repository ([Trust boundary](#trust-boundary)) | Cleanup and workspace ownership keep it usable, not clean. Anything a job leaves is visible to the next, including what it does through `sudo`: a package it apt-installs stays, and the daily maintenance upgrades it with the rest, and a service it enables starts on every boot. The VM drifts from `RUNNER_EXTRA_PACKAGES` that way ([Maintenance](#maintenance)) |
| Versions | the image is rebuilt weekly | apt packages upgrade in the daily maintenance, and the runner self-updates ([Maintenance](#maintenance)) | Anything whose version matters: pin it with a setup action or an explicit install, on both sides |

## Adding tools

The VM starts with a small base set (see "Packages" in
[`provision.sh`](../vm/provision.sh)), which is less than `ubuntu-latest`;
"what the VM has" above maps the difference. Add what your jobs need without
editing the script. Per-job toolchains (`actions/setup-node`,
`setup-python`, ...) need nothing here.

**Presets: the common gaps in one command.** These are shipped with the tool
(`vm/presets/`) and add, never replace:

```bash
bin/homefield upgrade --instance homefield --preset browsers   # the twelve Chromium OS libraries below
bin/homefield upgrade --instance homefield --preset hosted     # browsers + CLI tools + Node, all of it
bin/homefield upgrade --instance homefield --preset buildx-rosetta  # amd64 image builds under Rosetta, below
```

`hosted` is `browsers`, then noble's `gh`, `shellcheck`, `sqlite3`, `xvfb` and
`rsync`, plus two hooks from the same set: AWS CLI v2 (official bundle; noble
has no `awscli`) and Node at the major `ubuntu-24.04` carries (`setup-node`
still wins for a job that installs its own). Its packages join what is saved
in `/etc/homefield/extra-packages`, and any `--packages` on the same command;
only plain `--packages` replaces the list, and it warns when that drops names
a preset installed; the preset's hooks stay, a hook the preset no longer
ships is removed at the next copy (a manifest at
`/etc/homefield/preset-hooks` names what the VM got), and a hook you added by
hand is never touched (`rm /etc/homefield/provision.d/<file>`, as for any
hook). The hooks run on
every provisioning run, so what they installed survives later upgrades. They
install whatever upstream serves at provision time (the hosted image rebuilds
weekly), so anything version-critical still pins itself with a setup action or
an explicit install.

**Building amd64 images.** Rosetta translates x86-64 binaries in the VM, so
`docker run --platform linux/amd64` works as the VM ships. A buildx
docker-container builder does not reach Rosetta: buildkitd validates each
platform by running a tiny test binary through its own bundled
`buildkit-qemu-x86_64`, that dies under the Lima Rosetta mount, and BuildKit
then wraps every amd64 `RUN` in QEMU — Node-heavy steps segfault
([moby/buildkit#7052](https://github.com/moby/buildkit/issues/7052),
[moby/buildkit#7110](https://github.com/moby/buildkit/issues/7110), both open;
the preset is retired when they close). The `buildx-rosetta` preset provisions
a BuildKit image with that emulator removed, pinned by digest and rebuilt
only when the base image moves, so the steps exec directly and the kernel's
Rosetta handler takes them:

```bash
bin/homefield upgrade --instance homefield --preset buildx-rosetta
```

and the job creates the builder itself — `docker/setup-buildx-action` cannot
do this part, because with `driver-opts: image=` it always runs `docker pull`
first and fails on a local image with `pull access denied`:

```yaml
- name: Create the Rosetta-aware builder
  run: |
    printf '[worker.oci]\nplatforms = ["linux/arm64", "linux/amd64"]\n' > bk.toml
    docker buildx create --name hf --driver docker-container \
      --driver-opt image=buildkit-rosetta --buildkitd-config bk.toml --use
    docker buildx inspect --bootstrap
```

A cold amd64 build of a Next.js production image took 48s this way, against
a median 95s per build step on hosted `ubuntu-latest` with a warm cache
(#241). `docker buildx rm hf` at the end of the job removes the builder.

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
limactl copy -r vm/guest homefield:/tmp/guest   # the helpers provision.sh installs
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

`awscli` is the case that needs a hook: noble has no `awscli` apt package (it
was removed from the archive in February 2024), so `RUNNER_EXTRA_PACKAGES`
cannot supply it and provisioning stops in apt with no candidate. The hook
installs the official AWS CLI v2 bundle instead; `--preset hosted` copies that
same hook, arch-aware and idempotent. The hook pins a version and the zip's
SHA256 (as `provision.sh` pins the runner), so a provision installs exactly
that version; bump the version and both digests together. `gh`, `shellcheck`
and `sqlite3` are apt packages, so they need no hook.

Provision while the runner is idle, as for any upgrade (see "Maintenance").
Everything added here is available to every repository's jobs, so keep
credentials out of hooks.

### Browsers

`playwright install --with-deps chromium` works on the VM as on a hosted
runner, because `runner` has passwordless `sudo`
([Trust boundary](#trust-boundary)). It runs `apt-get update` and an apt
install in every job, which costs network and time. Where either matters,
pre-provision the libraries in `RUNNER_EXTRA_PACKAGES` and install the browser
alone; that helps only a workflow that then leaves out `--with-deps`.

The shipped `browsers` preset adds exactly this set:
`bin/homefield upgrade --instance homefield --preset browsers`. By hand, these
names go in `RUNNER_EXTRA_PACKAGES`, and the hook and by-hand recipes below stay
the reference. Five of the twelve are `t64`-suffixed on 24.04, and the plain
names have no candidate:

`libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libatspi2.0-0t64 libasound2t64 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2`

`libnss3`, `libnspr4`, `libdrm2` and `libxkbcommon0` already arrive with the
Lima Ubuntu image (a base-only VM has them), so they need no entry; a trimmed
or different image would. Passing plain `--packages` *replaces* the saved list,
so include anything already there — `bin/homefield status` prints
`extra packages:`. A preset never replaces it:

```bash
bin/homefield upgrade --instance homefield --packages "libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libatspi2.0-0t64 libasound2t64 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2"
```

With those installed, `npx playwright install --only-shell chromium` (no
`--with-deps`) succeeds as `runner`, and is faster. An action that keeps
`--with-deps` where passwordless sudo exists and falls back to this sudo-less
install where it does not works on both ([ranacseruet/snapdrift#229](https://github.com/ranacseruet/snapdrift/pull/229)).
Since #176 such an action finds sudo and always takes `--with-deps`, as on a
hosted runner, so pre-provisioned libraries no longer save it the apt step;
the fallback runs only on a VM not yet upgraded.
Chrome, Firefox and Edge themselves are not in the VM: a job that drives one
of those directly stays hosted, or installs it with a hook.

## Switching (per repository)

`bin/homefield adopt --repo <owner>/<repo>` is the first switch to local: it
also checks the repository's routing and runner group access first, and
refuses to switch until the routing is merged
([adopting, step 5](adopting.md#5-merge-then-run-homefield-adopt)); `adopt
--setup --wait` runs it for you once the pull request it opens is merged. It
afterwards offers to re-run the latest pull-request run and report where its
jobs ran ([adopting](adopting.md#let-adopt-check-the-first-run)). After that,
`route` flips a repository either way:

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

## The automatic hosted fallback (stop/start)

A stopped VM leaves every routed job queued until it starts again. `stop
--route-hosted` hands those jobs to GitHub's runners before the VM stops: each
repository routed to this runner goes hosted, but only when no other online
runner in the scope serves the routing label, so a one-runner Mac falls back
and a fleet keeps routing locally while one VM stops. A repository whose
routing label another online runner still serves stays local and says so.
`start --route-local` puts the flipped repositories back once the runner is
taking jobs again (the runner being online is checked first; a start that
fails to restore keeps the pending entries and exits 1). A manual `route
local` for a flipped repository clears its pending restore — the operator's
routing label wins over the stop's, and the next start will not overwrite
it.

`install --auto-route` (or `upgrade --auto-route`; `--no-auto-route` turns it
off) makes plain `stop` and plain `start` run the fallback every time. `fleet
start`/`fleet stop` accept the same flags for every VM. Switching it on seeds
the routing records from the registration's own repositories (the runner
group's list, or the repository itself for a repository-scoped runner): every
one already routed local is recorded, so an install that adopted before the
fallback existed is covered from the first stop. A repository that is already
recorded keeps its record (runners in one group can use different routing
labels, and the record says which label routes the repository), and one that
is not is recorded under this runner's label only when no other runner in the
scope with a different label can also take its jobs — otherwise it is left
unrecorded with the `route local --repo` command to record it by hand, like
every other seeding failure.

The fallback is fail-safe: when GitHub cannot be asked, this runner is not in
GitHub's runner list, or a flip fails, nothing is flipped, the stop (or start)
still happens, and the command exits 1 — jobs keep routing to the local
runner, which is the state a human can see and fix with `route`. Queued jobs
that the flip catches are cancelled and re-run, the same as `route hosted`
does by hand. On a GitHub Enterprise Server host the stop-side fallback
skips with a warning, and `route hosted` refuses: a GHES host has no hosted
runners, so there is nothing to fall back to there. A GHE.com
data-residency host has hosted Linux and Windows runners (macOS is the only
kind GitHub does not serve there), and the fallback's labels are Linux ones,
so the fallback and `route hosted` work on it as on github.com
([#287](https://github.com/i2Dev-com/homefield/issues/287) added the host
support). The records carry the host they were written for (a line
without one, from before the host support, reads as github.com): a Mac with
runners for the same owner/repo on github.com and a GHES host keeps the two
hosts' records apart, so one host's start does not consume the other's
pending restore.

## The sleep/wake watcher (sleep and login)

Stop and start need someone to run them. Two moments have no such caller:
the Mac sleeping (the Lima VMs do not survive sleep cleanly, so the runners
go offline with the Mac and queued jobs wait behind them) and a reboot or
login (autostart boots the VMs, but nothing restores the repositories a
stop flipped). `install --auto-route` and `upgrade --auto-route` therefore
also install a LaunchAgent, `com.homefield.route-watcher`, whose helper
(part of the installed tool, a small Python program that receives macOS's
power events) runs `homefield route-watch sleep` when the Mac is about to
sleep and `homefield route-watch wake` when it wakes up or logs in. The same
agent also drives the demand scaler of the next section: a second loop runs
one `homefield fleet watch` tick per interval, and a tick stands down while
a sleep/wake run is in progress. A sleep notification kills a running tick
the same way it kills a wake recovery — including one that has just been
launched, which is cancelled before it can run anything — and parks the
loop until the wake, so no fresh tick spawns in the middle of the
sleep-side flip. The spare's
install never reloads the agent: an unload would stop the very helper
supervising the tick mid-install, so a spare's `--auto-route` leaves the
installed agent as it is (a hand-run `upgrade --auto-route` is what
refreshes it).

The sleep side runs the stop-side flip of the section above, without
stopping the VMs: every Running VM whose own `auto_route` is on has its
routed repositories flipped to hosted, so jobs queued while the Mac is away
run on GitHub's runners, and the flipped repositories wait in `autoflip` for
the wake side (or the next `start`) to bring them back. A VM with a job
running is skipped — the same rule `stop` applies — and so is a VM that
cannot be asked whether one is: neither is flipped and neither's records
are touched. Because every runner on the Mac goes away together at sleep,
the flip's still-served check treats all of them as gone: two VMs sharing a
label do not leave each other's repositories served. The exclusion follows
each runner's registration scope (the url it registered under), so a Mac
with runners for two organizations does not let one org's local runner name
exclude a same-named remote runner of the other org — that remote runner is
still there and still serves its repositories.

The wake side starts every VM the sleep side recorded as running — the
ones whose own `auto_route` was on and that were Running when the Mac slept,
whether their flip landed or was skipped for a job — if it is not running,
waits for each runner to be listed online (up to
`HOMEFIELD_WATCH_WAKE_WAIT` seconds per VM, default 120), and runs the
start-side restore. A VM that was not running at sleep — stopped by hand, or
scaled dark by the demand scaler — is not started: the Mac's wake is not
demand, and booting such a VM would burn a full idle cooldown with no work
for it. A stop's own paths bring a VM back — the operator's `start`, or the
tick's wake on demand for a dark line (the scale-to-zero section below) —
and a stopped VM's pending entries keep waiting for that start. A VM that
does not come back, and a GitHub that cannot be asked, keep their pending
entries for the next `start` or the next wake
and the run says so. A VM with `auto_route` off is never touched by the
watcher on either side: its routing stays exactly where the operator left
it, and its pending entries keep waiting for the explicit `start
--route-local`.

A stop cancels a VM's wake eligibility: every stop path — a plain `stop`,
`--route-hosted`, `fleet stop`, and the demand scaler's scale-to-zero —
removes the VM's line from the sleep record, so the Mac's next wake does
not start a VM someone explicitly put down. A stop of an already-stopped
VM does the same: a wake start that failed leaves the VM Stopped with its
line still in the record, and the operator's stop is what says it stays
down. (The scaler's zero-stop writes
the dark line that arms the demand wake, the same stop.) The record is
rewritten whole by every sleep run, with the previous record's
still-pending lines carried over: a VM still Stopped with a valid line is
a recovery that has not finished — a wake whose start failed, or one the
Mac slept again before it reached — and only a VM gone from Lima's list,
or an explicit stop, removes its line; the next wake retries the start.
Otherwise a line goes when its VM is up again, so a wake that runs without
an intervening sleep — a LaunchAgent restart — does not start a VM that
has since been stopped by hand. The
record's writers hold a lock while they rewrite it: two overlapping
writers (a stop racing a wake's line-drop, or two stops) would otherwise
read the same record before either replaces it, and the last rename
would resurrect the line the other removed. A lock left behind by a
killed writer is stolen once its owner is gone — including one whose
writer died before it could write its owner, stolen once it has stayed
undescribed through the wait — and a live owner is never stolen,
however long it holds the lock. The reclamation is fenced: it only
removes a lock whose owner is still the dead pid the writer saw, and it
removes the directory by a rename only one contender can win, so two
reclaimers cannot take each other's replacement lock; a transaction
whose lock was taken over mid-flight gives up and retries rather than
writing under another writer's lock. Instead a writer waits a live
holder out — half a minute by default, which covers a sleep-side store,
since the sleep budget kills a sleep run before it could hold the lock
longer — and a writer that still cannot get the lock leaves the record
as it is, loudly on the stop side: the stop says the wake eligibility is
uncertain and to run it again. The store re-proves each recorded VM
under the lock, so a stop that completed between the pre-pass's status
read and the store is not undone by the stale snapshot; a Lima that
cannot be asked at the re-prove keeps the line, the phase-1 proof
standing. A sleep run whose pre-pass cannot read a Running VM's runner
identity
still writes the record: the flip fails safe (nothing is flipped), but
the VMs' Running statuses were proven, and the wake side must not lose
them. The record is stored after the statuses and before any guest
identity read, so a guest that hangs in its read — the sleep budget
killing the whole run — cannot erase it either. Only a pre-pass that
cannot even prove the statuses — the VM list, or Lima not answering
about a VM — leaves the previous record.

The watcher is fail-safe in the same direction as the rest of the fallback:
when a flip cannot be proven, a VM cannot be asked, or a restore cannot
run, the records stay as they are and the run is reported as failed. Each
run is recorded in the watcher's own state file, in a `route-watcher`
subdirectory of the state directory (the directory the routing records live
in — a subdirectory, so a VM named `route-watcher` cannot share its state
file with the watcher's record), `status` shows the last run for every VM
with the fallback on, and `diagnose` turns a missing agent into a problem
with the fixing command, and a failed last run into a hint naming the log.
The log, the `log` file in the same subdirectory, carries every flip, skip
and failure in full. macOS grants about 30 seconds before it forces a sleep,
so the sleep side is bounded by `HOMEFIELD_WATCH_SLEEP_BUDGET` (default
20 s): a flip that does not finish in time is killed and logged loudly. A
kill cannot lose the restore intent: the pending `autoflip` entry is written
before the flip's slowest part (the stuck-job recovery, which can wait a
minute), so a flip killed there leaves the repository waiting for the next
wake or start instead of hosted with no way back; the repositories the flip
did not reach keep their routing until then. The wake side runs in a thread
of its own, because it can wait
minutes per VM: if the Mac goes back to sleep while a wake recovery is
still running, the sleep notification kills the recovery and runs the
sleep-side flip, so the repositories are never left routed to a runner that
is about to disappear with the Mac. Unloading the agent (or the Mac shutting
down) is a SIGTERM, and the wake recovery and the scaler tick run detached
in sessions of their own — the agent's death does not reach them — so the
helper handles SIGTERM by killing both before it exits: without that, an
unloaded agent would leave a wake recovery or a tick flipping repositories
for its whole budget (minutes to half an hour) with no agent behind it.

`--no-auto-route`, `uninstall` and `reset` remove the agent when no
remaining VM on this Mac has the fallback on; while any VM wants it, the
agent stays, because it is per-Mac and the switch is per-VM. A Mac where
some VM has the fallback off still gets the agent — it covers every VM that
has it on.

## The demand scaler (queued jobs behind a busy fleet)

The fallback's first two parts move work *off* the fleet when a VM stops or
the Mac sleeps. Neither scales capacity *up*: a fleet of one busy VM queues
every other routed job behind it even though the Mac has headroom for
another VM. Part three is the demand scaler: when queued jobs have waited
longer than a threshold while every Running VM on the Mac is busy, it boots
— or creates — one spare VM registered like the runner that serves the
queued label. The label is the load balancer: the spare joins the same
runner group with the same label, so GitHub hands it the queued jobs with no
routing change at all. After an idle cooldown with no job it is stopped
again — never deleted — and the next demand spike boots it in seconds.

The scaler is a tick, `homefield fleet watch`: it can be run by hand, but it
is meant to be driven by the route-watcher LaunchAgent of the section above,
whose helper runs one tick every `HOMEFIELD_SCALE_INTERVAL` seconds (default
60) in a thread of its own. Ticks serialize on a per-Mac lock: a second
`fleet watch` run — a hand-run one against the agent's loop, or two
hand-runs — stands down while another tick holds it, so two ticks cannot
interleave their read-modify-write of the scale record or provision the
same spare name (a lock left behind by a killed tick is reclaimed from its
dead pid). A tick:

1. stands down while a sleep/wake run is in progress — one owner per VM at
   a time, the same rule the wake recovery's kill-on-sleep follows;
2. asks every VM whether a job is running (a VM that cannot be asked is
   fail-safe: nothing scales, and the tick says so);
3. stops each secondary it created that has had no job for
   `HOMEFIELD_SCALE_IDLE` seconds (default 900) — through the real `stop`,
   which refuses under a live job the same way `fleet stop` does, so the
   cooldown is proven idle, not assumed; a VM with the automatic fallback on
   has its still-served repositories flipped to hosted first, exactly as a
   hand-run `stop` would;
4. and, only when at least one VM is running and every one of them is busy,
   asks GitHub for queued and in-progress runs whose jobs still wait for a
   routing label (a matrix or parallel run goes in_progress as soon as one
   of its jobs starts, while the rest of its jobs are still queued) — the
   same lookup the stuck-run recovery uses, and host-agnostic since #287,
   so a GHES registration is scaled like a github.com one. When the oldest
   wait is past `HOMEFIELD_SCALE_WAIT` seconds (default 300), one spare is
   booted or created per tick.

Creating a spare passes the guards the situation demands: the fleet-size cap
(`HOMEFIELD_SCALE_MAX` VMs, default 4), and the headroom budget of
"Scaling on one Mac" — the sizes of every VM on the Mac, stopped ones
included, plus the new one, must leave 2 host cores and 8 GiB unallocated,
or the create is refused. The spare is named after the fleet's first VM
(`<instance>-scale`, `-scale2`, …), is persistent rather than `--ephemeral`
(it is started and stopped on demand, so its registration has to survive a
stop), and is installed like the runner that serves the queued label: same
url, label and group, same CPU and RAM as the primary, the primary's saved
extra apt packages (`--packages`), and `--auto-route` when the primary has
the fallback on. A primary that carries provisioning hooks
(`/etc/homefield/provision.d`, user hooks and preset hooks alike) is not
auto-created at all — install has no flag that stages another VM's hooks,
and a spare without them would take jobs whose tools it does not have — so
the tick names the runbook's manual path ("More runners") instead. The
spare's record matches on url and group too, so a stopped spare from
another registration on the same host is not booted for this demand.
Everything it did is recorded in the route-watcher subdirectory of the
state directory (`scale` holds one line per secondary, `scale-state` the
last tick's summary), and `fleet status` prints the last tick's result.

The scaler is fail-safe in the same direction as the rest of the fallback:
a queued-run lookup that cannot be asked reads as "nothing is proven", not
as "nothing waits", and a tick that runs past `HOMEFIELD_SCALE_TICK_BUDGET`
(default 30 minutes — creating a VM takes minutes, and a hung tick must not
stop the ones after it) is killed and logged loudly; a secondary it was
half-creating stays behind for the next tick to reconcile, or for
`bin/homefield reset --instance <name>` to remove by hand.

### Scale to zero, and wake on demand (#305)

The scaler above only ever adds capacity while a VM is running: a fleet
that is entirely stopped scales nothing, because a stopped VM cannot be
asked for its runner identity and the tick refuses to guess. #305
completes the column with two sides, one of them opt-in.

**Scale to zero** — off until `HOMEFIELD_SCALE_ZERO=1` is baked into the
agent's plist (set it when you run `install`/`upgrade --auto-route`, the
way the other `HOMEFIELD_SCALE_*` reach the agent) — lets the tick stop
the fleet's own VMs (the ones it did not create) after the same idle
cooldown the secondaries use, through the real `stop`: the automatic
fallback flips the VM's routed repositories to hosted first, so the dark
Mac's jobs still run. A VM without the automatic fallback stops too —
its queued jobs wait for the label, and the wake side below is what
answers them. Every VM the tick's stops put down — the primary, a
secondary that idled out on the same or a later tick — gets a line in
the `scale-dark` record, provided the tick could capture the identity
the wake side matches against (the registration url, the routing
label, the runner id) while the VM still runs: the identity is read
through the guest, and a stopped guest cannot be asked, so a stop the
tick cannot pair with a usable identity is deferred to a later tick —
a dark line that cannot be matched would leave the VM down with its
demand unanswered. The line is also written before the stop: the
record is the only proof the VM is dark by the scaler's hand, and a
write that failed after the stop would leave it down with no wake
eligibility — the next tick would read the stale file and treat the VM
as hand-stopped — so a failed write defers the stop the same way. With
its line durably recorded, the VM is dark by the scaler's hand and the
wake side may bring it back on demand. The record
keeps the route-watcher agent installed (its ticks are what can wake
the fleet), and a line is dropped the moment its VM is seen Running
again — by the wake, the user, or anything else. A VM the user stopped
by hand never gets a line and never wakes: a line is written only when
the tick's own stop put the VM down, so a fleet that was already dark
when the tick started writes nothing.

**Wake on demand** — only a VM with a dark line wakes. The tick reads
the same demand the up-scale side does (queued jobs waiting for a
routing label: the stop's flip did not land, or a workflow that never
went through the `CI_RUNNER` switch) plus one more source: the runs an
automatic flip moved to hosted, which are demand burning hosted minutes
and wake at once. The queued source waits out `HOMEFIELD_SCALE_WAIT`
like the up-scale side; the hosted source does not. One VM per tick,
the scaler's rule: a dark VM whose recorded label, host and
registration scope match the demand starts first (the primaries record,
`scale-primaries`, is maintained while the VMs run precisely because a
stopped one cannot be asked — the scope match matters, since two
repository-scoped VMs can share the default label, and an organization
runner's group must admit the repository too, the same check the
up-scale side makes). A demand no dark line serves is left alone and
logged — starting an unrelated VM would drop its dark line and strand
the jobs anyway — and the started VM's flipped repositories come back
the watcher's wake way — a bounded online wait, then the restore. A
start that lands but does not prove out — the bounded wait expires, or
the restore fails — still ends the pass: the VM is up and eligible all
the same, and a second start could not serve the next demand any
better than the runner that is already online, so the pass ends with
the failure surfaced rather than reaching for another dark VM. A
queued demand that an idle running runner on this Mac already serves
wakes nothing either: the run is waiting on workflow dependencies no
runner can help, or on a runner the idle cooldown is about to retire,
and a dark VM started for the same scope would idle out behind the
same wait — demands for other scopes still wake, and the hosted
source always wakes, since its runs are on hosted now and the restore
that brings the routing back rides on a start. A woken secondary also
gets a fresh idle clock, the same reset the
up-scale side's secondary start does: its stamp already exceeded the
cooldown when it was stopped, and without the reset the next tick
would stop it again before it can pick up a job. (A woken primary's
clock heals itself: its line's up flag is cleared while the VM is
down, and the next refresh starts a fresh cooldown from it.) A VM
whose status could not be read keeps the scaler from starting
anything, whether the fleet is fully dark or partly running, because
one may already be running and serving the demand.

**What counts as demand** (#315) — the hosted source counts a run only
when the consumer's own routing expression would have sent it to the
local runner had `CI_RUNNER` been local. A run the expression keeps
hosted — a scheduled workflow when the guard's `events` is the default
`pull_request`, a Dependabot PR while `dependabot` is the default
`hosted`, a fork pull request in `guards` mode — can never take the
runner, and reading it as demand would wake a dark VM on a schedule
instead of on work: each wake costs the full idle cooldown, and
consecutive schedules buy consecutive cooldowns. The consumer's
options therefore ride in the records: the `routing` and `autoflip`
lines carry the guard's `events`, `dependabot` and `mode` after the
host (`route local --events push,schedule --dependabot local --mode
simple` writes them; the defaults are the guard's defaults). A
`simple`-mode record counts every active run, because the simple
expression routes every event. A line without the option fields — one
written before #315, or `route local --profile unknown` — carries no
profile: it is not read as the guard's defaults (that would silence a
simple-mode repository's push and schedule demand for good), it keeps
the permissive demand model the scaler had before #315, counting
every active run, until `route local` or `adopt` records the profile.
The queued source needs none of this: a job queued for the routing
label is by construction a job the expression routed to the runner.

Because the dark record is per VM, one scope's wake does not strand
another's: with two repository-scoped VMs dark, waking the first leaves
the second's line — and its demand — answerable on a later tick, even
while the first stays up. A fleet-wide flag could not do that; that is
why the record is a record and not a flag.

### The webhook receiver, opt-in (#309)

The tick is the only decision point, and its interval bounds how long a
dark VM's wake waits. The opt-in webhook receiver closes that gap the way
a cloud autoscaler does: GitHub delivers `workflow_job` webhooks to the
Mac, and each verified delivery rings the scaler at once — one
`fleet watch --max-ticks 1` tick — instead of waiting up to
`HOMEFIELD_SCALE_INTERVAL` for the route watcher's next tick.

The Mac sits behind NAT, so deliveries arrive through a cloudflared named
tunnel: `homefield webhook setup --hostname <fqdn>` creates the tunnel,
routes the DNS name, writes the webhook secret (0600) and installs the
`com.homefield.webhook` LaunchAgent — the one-time `cloudflared tunnel
login` is a browser flow the tool cannot do for you, and the hostname
needs a domain on the Cloudflare account. Use a **first-level** subdomain
of that domain (`webhook.example.com`, not
`webhook.ci.example.com`): the zone's free Universal SSL certificate
covers only the apex and `*.<domain>`, so a deeper name gets a TLS
alert 40 at the edge and no delivery ever reaches the tunnel (found live
setting this one up). A hostname that already has a
DNS record is refused unless `--overwrite-dns`: the route error says
nothing about the existing record's target, and a record pointing at
another tunnel or service would silently swallow every delivery —
`remove --purge` leaves the record behind, so a re-setup after it needs
the flag too. `homefield webhook connect
<owner/repo>` subscribes a repository to `workflow_job` (repo admin,
through gh; safe to re-run). The receiver authenticates every delivery
with GitHub's `X-Hub-Signature-256` HMAC over the raw body against the
secret, listens on 127.0.0.1 only (the tunnel is the only path in), caps
the body it will read, and rings on `queued` and `completed` jobs by
default (`HOMEFIELD_WEBHOOK_ACTIONS` changes the set). It is a doorbell,
not a brain: the payload decides nothing, and a delivery for a job the
routing would never send here costs one harmless evaluation — the tick
answers "nothing waits" for it. The tick lock serializes a webhook tick
with the route watcher's own, so the two agents cannot interleave — and
the route watcher's sleep side kills a running webhook tick before the
sleep-side routing flip, the same way it kills its own: a tick that
survived the sleep notification could route repositories back to the
now-sleeping runner after the flip. The endpoint is also bounded against
peers that never speak: a connection that stops reading mid-request is
closed at the read deadline (`HOMEFIELD_WEBHOOK_READ_TIMEOUT`, default
10 s), and only so many connections are served at once
(`HOMEFIELD_WEBHOOK_MAX_CONNECTIONS`, default 32) — a peer that only
opens connections is refused before a thread is spent on it, and GitHub
retries a refused delivery.

The trade is inbound configuration and attack surface the tick-only
design does not have: one more always-on agent, and a public URL that
accepts GitHub's deliveries — authenticated, and anything else gets a
generic 403 before the body is parsed. `webhook status` reports the
pieces (agent, tunnel, secret, receiver port, public URL); `webhook
remove [--purge]` takes them down (connected repositories keep their
webhook until you delete it, and GitHub disables a hook whose endpoint
stops answering). Without the setup, nothing changes: the tick design is
the whole feature.

## Failure modes

Not sure which row applies? `bin/homefield diagnose` checks the VM, the runner
(including whether GitHub lists it, online or offline, busy or idle), the
runner group and the prerequisites in one read-only pass, and ends with
"Summary:": either healthy, or each problem with the command that fixes it. It
never starts the VM or changes anything, and it skips the checks inside a
stopped VM (saying so). It exits 0 when healthy and 1 on any problem;
`bin/homefield diagnose --json` prints only JSON on stdout, with a `healthy`
boolean and a `problems` array, for scripts; with several VMs it wraps them as
`instances`, `healthy`, `prerequisites` (once) and `vms`. Add `--instance <name>`
for one VM.

| Symptom | Cause | What happens | Recovery |
|---|---|---|---|
| PR job "Waiting for a runner to pick up this job" | VM stopped, Mac asleep or offline, runner service down | The PR's check waits in the queue, and after 24 h GitHub fails it. By default merges and deploys are unaffected, because pushes run hosted; with `push` (or `workflow_dispatch`, `schedule`) in `events`, those jobs wait too. | Start the VM (`bin/homefield start --instance homefield`), or `bin/homefield route hosted --repo <owner>/<repo>`. |
| `install` or `provision.sh` stops: "already registered" or "A runner exists with the same name" | Another runner in the scope has the name: another machine's, or this Mac's from before a VM was deleted without `uninstall` | Nothing is registered; the other runner is untouched | Another machine's: pick another name (`--name`, `RUNNER_NAME`). A stale one of this Mac's: `install --replace`, which removes it after token retrieval but before provisioning, or remove it on the runners page and run again. A provisioning failure after removal leaves the old registration gone; retry the install. Not `config.sh --replace`: it keeps the old registration's runner group ([actions/runner#4091](https://github.com/actions/runner/issues/4091)) |
| `install` stopped partway: a VM that never registered, or a runner group left behind | Provisioning, registration or the network failed after the VM or the group was created | Whatever was created stays | `bin/homefield reset` ([Rolling back a failed install](#rolling-back-a-failed-install)), then install again |
| Waiting forever although the runner is online and idle | The repository is not in the runner group | Same as above | `bin/homefield adopt --repo <owner>/<repo>` adds it (or add it in the organization settings), or switch the repository to hosted |
| Waiting forever although the runner is online and idle, and the repository is in the group | The label in the expression is not one of the runner's labels. For example, an expression that uses the default label `homefield-ci` while the runner was registered with another label | Same as above | Add the label to the runner (*Settings → Actions → Runners →* the runner *→ Labels*), or pass the runner's label to `routing-guard` as `label:` and use it in the expression |
| A PR job waits while another runs | One runner runs one job at a time, across all repositories | Serialised, not failed | Accept it, switch the less urgent repository to hosted, or add a runner ([More runners](#more-runners)) |
| Job fails only on the local runner | Toolchain or arch gap between the VM and `ubuntu-latest` (arm64 vs x86-64) | Red check | Re-run hosted to confirm. Then add the tool ("Adding tools") or keep that job hosted |
| A job installing a browser or an OS package fails: `sudo: a terminal is required to read the password` or `sudo: a password is required`, then e.g. `Failed to install browsers` | The VM was provisioned before #176 gave `runner` general passwordless sudo, so its sudoers allow only the `homefield-workspace-owner` helper, and nothing a job runs | Red check in one job that would pass hosted | Update the tool (the README's one-liner again), then `bin/homefield upgrade --instance <name>` (run it while idle): `upgrade` re-runs the provision.sh in the installed tool, which grants the rule. Until then pre-provision the package ([Adding tools](#adding-tools)) or the browser libraries ([Browsers](#browsers)) and install the browser alone, or keep that job hosted |
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
  first if the update needs it (`/var/run/reboot-required`, which
  `update-notifier-common` writes; a minimal image without that package never
  writes it, so the upgrade then finishes without a reboot). A runner that
  was already stopped when maintenance ran stays stopped: maintenance
  restarts only a runner it stopped itself, and leaves a needed reboot to
  whatever stopped it (#323). Queued jobs wait
  through it, typically under a minute and longer on a reboot.
  - A job's own `sudo apt-get` (#176) never restarts a service. Ubuntu's
    needrestart would restart everything using an upgraded library, the
    runner included, and kill the job; a drop-in,
    `/etc/needrestart/conf.d/50-homefield.conf`, makes it only list them, and
    never restart the runner. Maintenance still restarts the others, because
    it runs with `NEEDRESTART_MODE=a`. A job that asks for
    `sudo NEEDRESTART_MODE=a apt-get ...` gets that, except for the runner.
  - `apt-daily.timer` and `apt-daily-upgrade.timer` are off, as on a hosted
    runner. They refreshed the package lists at random times, holding apt's
    lock, and a job's `sudo apt-get update` fails at once on a held lock
    (`Could not get lock /var/lib/apt/lists/lock`). Maintenance's own
    `apt-get update` refreshes the lists daily instead.
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
  - **Per-job cleanup (opt-in).** `bin/homefield install --job-cleanup` (or
    `upgrade --job-cleanup` on an existing VM) adds the runner's
    job-completed hook (`ACTIONS_RUNNER_HOOK_JOB_COMPLETED` in
    `/opt/actions-runner/.env`): after every job,
    `/usr/local/sbin/homefield-job-cleanup` removes stopped containers and
    unused custom Docker networks, the job's build state under `_work`
    (anything not starting with `_`), and everything in `/tmp` except the
    guest's own state there (the `systemd-private-*` dirs of PrivateTmp
    services and a provision run's `homefield-stage-*` staging directory),
    while tagged
    images, BuildKit layers and apt/preset packages stay warm. `--no-job-cleanup`
    takes it back out; the switch is saved in the guest, so later runs and
    re-registers keep it. The hook runs before the job's result is finalized,
    so it is written to warn and move on rather than fail: a cleanup hiccup
    never turns a finished job red — its warnings are in the job log under
    "Complete runner". Containers still running when the hook fires are left
    for the daily timer (killing containers blindly is worse than leaving one
    for an hour).
- **Workspace ownership.** A `container:` job runs as root in its container,
  so whatever it writes in the workspace is owned by root, and the next job's
  checkout, as `runner`, could not delete it. Before every job, the runner's
  job-started hook (`ACTIONS_RUNNER_HOOK_JOB_STARTED` in
  `/opt/actions-runner/.env`) runs `/usr/local/sbin/homefield-workspace-owner`
  through sudo, which gives anything in `_work` not owned by `runner` back to
  it, and also repairs the runner's npm when a self-update has flattened the
  externals symlinks (#110, "Runner updates" above). The script has its own
  narrow sudoers rule, so the hook does not depend on `runner`'s general
  passwordless sudo (#176). While that general rule is in place it covers the
  script too, so the narrow rule restricts nothing.
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
    records when its boot began. The whole counter counts — at a boot
    change between rows, or at the very first sample of a log — only when
    that boot is known and began inside the window, which is measured in
    the VM's own days, the same ones that select the rows. Kills under an
    older boot cannot be placed and are not counted, and an unreadable boot
    reads as unknown (#91); same boot, the difference decides. Logs from
    before the boot column work as before, except that their first row is
    never counted.
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
runner is idle. Repositories and their routing don't change. On one Mac this
can also be automatic: the demand scaler ([The demand
scaler](#the-demand-scaler-queued-jobs-behind-a-busy-fleet)) boots a spare VM
when queued jobs wait behind a busy fleet and stops it again after an idle
cooldown — the rest of this section is the manual equivalent.

**On the same Mac**, a second instance:

```bash
homefield setup --instance homefield-2 --url https://github.com/<org>
```

Run on a terminal, a new registration ends with the offer to open a routing
pull request (the one a first setup makes). A second runner needs none, since
repositories and their routing are already done: answer `n`, or press Enter at
an organization's "Repository to route first" question. Answering yes runs
`adopt` as usual: for a repository with nothing left to route it refuses
("nothing to route"), and the runner is set up either way.

It is named `<local hostname>-homefield-2`. An instance name follows Lima's
rule (letters and digits, with a single `.`, `_` or `-` between them, at most
76 characters, not ending in `.yml` or `.yaml`), and homefield refuses any
other. `status`, `upgrade`, `start`, `stop`, `diagnose` and `memory` cover every
HomeField VM on the Mac by default — one block per instance, each run as its own
process, exiting nonzero if any failed; add `--instance <name>` (or set
`HOMEFIELD_INSTANCE`) to narrow them to one. `uninstall` and `reset` never guess:
with more than one VM they refuse until `--instance` names the one to remove.
`route` and `adopt` act on repositories and cover every runner.
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
homefield setup --instance homefield-2 --url https://github.com/<org>
```

Memory is the cost: each VM holds up to its `memory` (5 GiB by default) on
the Mac even while idle ([Maintenance](#maintenance), "Host memory"), so two
take about 10 GiB. Check the first one's peak with `homefield memory` before
going lower.

**On another Mac**, install the tool there ([Setup](#setup-once-per-machine))
and run `homefield setup` with the same URL, label, group and packages, and
the hooks put in first as above. Answer `n` to the routing-pull-request offer
at the end, as for a second instance. The runner is named after that Mac, and a name
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
again, then `homefield upgrade` — it covers every VM there in turn (pass
`--instance <name>` for just one). It takes a runner down until that VM is done,
so a VM with a job running is refused and skipped; the others keep taking jobs.
Runners on
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

## Scaling on one Mac

You can run multiple HomeField VMs on a single Mac (`homefield setup --instance <name> ...`) and manage them together with `homefield fleet`:

- `homefield fleet` (or `homefield fleet status`) prints a compact table of every HomeField VM on the Mac (`INSTANCE`, `VM`, `RUNNER`, `GITHUB`, `SERVICE`, `JOB`, `MODE`) plus totals (`total`, `online`, `idle`, `busy`, `offline`). Pass `--json` for machine-readable output.
- `homefield fleet start` boots every HomeField VM and prints the fleet status summary.
- `homefield fleet stop` stops every HomeField VM (refusing any VM currently running a job).

When creating an additional VM on a Mac that already has one or more HomeField VMs, `install`/`setup` logs a non-blocking warning so you size CPU and RAM intentionally:

- Leave at least **2 host cores** and **8 GiB RAM** unallocated for macOS, Lima/VZ overhead, and Spotlight/WindowServer.
- Never oversubscribe total vCPUs or RAM across concurrent VMs (for example, on a 10-core / 24 GiB Mac, two 4-vCPU / 8 GiB VMs fit comfortably; three would contend for CPU and swap).
- Use `homefield memory` to verify each VM's peak RSS before adding another runner.

The demand scaler (the section above, [The demand
scaler](#the-demand-scaler-queued-jobs-behind-a-busy-fleet)) applies the
same budget on its own creates: the sizes of every VM on the Mac, stopped
ones included, plus the new one must keep the 2 cores and 8 GiB free, or the
create is refused and the tick says so.

Scale-to-zero ([#305](https://github.com/i2Dev-com/homefield/issues/305),
the section above) trades hosted minutes for an idle Mac: with
`HOMEFIELD_SCALE_ZERO=1` the tick stops the fleet's own idle VMs after the
cooldown and wakes them on demand. It starts existing VMs — no new
allocation — so the budget here is about how many VMs you create, not how
many the scaler wakes.

## Moving a registration

To move the runner to another scope (for example from one repository to the
organization), register it fresh: a token must not go into a VM that has run
jobs (see the [trust boundary](#trust-boundary)), and a VM that has served
jobs has. `bin/homefield reset --instance <name>` deregisters the runner
(through the GitHub API, from the Mac) and deletes the VM; then install at
the new scope:

```bash
bin/homefield reset --instance <name>
bin/homefield install --instance <name> --url https://github.com/<new-scope> \
  --name <name> --label <label>
```

Pass the current `RUNNER_NAME` and `RUNNER_LABEL` so workflows need no
changes. The only in-place move left is a VM that has never run a job (a
fresh registration that has not served one yet): `provision.sh` with
`RUNNER_REREGISTER=1`, `RUNNER_REMOVE_TOKEN` for the **current** scope (for
a repository: `gh api -X POST repos/<owner>/<repo>/actions/runners/remove-token --jq .token`,
which needs repository admin) and `RUNNER_TOKEN` for the new scope (see
"Registration tokens"). This is the operator asserting the VM has never run
a job: the script's `_work` check is a safety net, not a boundary — a VM
that has run jobs can delete that directory, and the host-side state that
guards `install` is not consulted here — so be sure before using it. The
script refuses both tokens in a VM that has run jobs, and refuses the move
while a job is running, then stops the runner before anything else.

```bash
limactl copy vm/provision.sh homefield:/tmp/provision.sh
limactl copy -r vm/guest homefield:/tmp/guest   # the helpers provision.sh installs
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

`bin/homefield uninstall` deregisters the runner (removing the registration
through the GitHub API from the Mac, so no removal token enters the guest),
turns off autostart and deletes the VM; `--keep-vm` only
deregisters. When the deleted VM was the last one on this Mac with the
automatic fallback on, `uninstall` also removes the sleep/wake agent
([The sleep/wake watcher](#the-sleep-wake-watcher-sleep-and-login)); a
`reset` does the same once its state file is gone. By hand — only on a VM
that has never run a job; on one that has, remove the runner on GitHub's
runners page instead and delete the VM, so no removal token enters a guest a
job's leftover root process could read:

```bash
# Every repository that routes to it: switch to hosted first
gh variable set CI_RUNNER --repo <owner>/<repo> --body hosted
# REMOVE: org remove-token (orgs/<org>/actions/runners/remove-token, admin:org)
printf '%s\n' "$REMOVE" | limactl shell homefield sudo sh -c 'cd /opt/actions-runner && ./svc.sh uninstall && read -r t && ACTIONS_RUNNER_INPUT_TOKEN="$t" sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u runner ./config.sh remove'
unset REMOVE
limactl delete --force homefield
```

`config.sh remove` refuses while the service is installed, so the service
goes first, and the registration files are copied to a backup in the
guest before anything is removed. The VM's local cleanup runs while the
registration still exists on GitHub: if anything there fails (the service
uninstall stops partway, or the local removal fails), `bin/homefield
uninstall` restores the files and gives the service back, so a runner
GitHub still knows keeps taking jobs; run it again once the cause is
fixed. If the GitHub API deletion itself fails after the local cleanup
(a network problem, or `gh` not authorized), the same backup puts the
registration back and the service starts again: the runner is still
registered and takes jobs, and the command says so — fix the cause and
run it again. By hand, `provision.sh` does the restore and works out what
the uninstall left behind (this one needs only the script, not the
`vm/guest/` helpers):

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
(`limactl list` fails): the commands fall back to reporting just `homefield`
and say it cannot ask Lima, as `status` does with "VM homefield: unknown".
Check that the VM is running (`limactl list`) and run the command again.

If the VM is already gone, delete the stale registration on the runners page.

## Rolling back a failed install

`install` can stop partway: the VM exists but provisioning failed, the runner
never registered, or the runner group was created and nothing after it
worked. `uninstall` needs a VM that exists, and never touches the runner
group. `bin/homefield reset` rolls back whatever there is, complete or half
finished; with more than one HomeField VM on the Mac it refuses until
`--instance <name>` names the target (as does `uninstall`):

```bash
bin/homefield reset                  # asks first, after listing what it will do
HOMEFIELD_YES=1 bin/homefield reset  # no terminal (a script, CI): answers yes
bin/homefield reset --keep-vm        # only deregister the runner
bin/homefield reset --keep-group     # leave the runner group alone
bin/homefield reset --remove-tool    # also remove the command and the tool's files
```

It prints a plan and asks `y/N` before changing anything; without a terminal
and without `HOMEFIELD_YES=1` (exactly `1`) it stops and changes nothing. When
there is nothing to undo (no VM, no runner group recorded as created by
install) it says so, exits 0 and asks nothing. A job running on the runner
makes it stop first, as `uninstall` does, before anything is asked or changed;
it asks again after you confirm, because the runner stays online while you
read the plan, and stops (nothing changed) if a job started in the meantime.
A VM Lima cannot describe, or a guest that cannot be asked whether the runner
is registered, stops it too (nothing changed); for a VM that will not start,
the message names `limactl delete --force <name>`, after removing its runner
on the runners page if it registered. It ends with a report, one line per
thing: kept, removed, or failed. It exits 1 when a step failed.

In this order, what it **removes**:

1. **The runner's registration**, if the VM has one: deregistered on GitHub
   with a remove token (`gh`, or pasted), or, when GitHub no longer lists the
   runner (#76), only the VM's copy of the registration (`config.sh remove
   --local`). A VM that never registered has nothing to deregister. A stopped
   VM is started for this, after the answer. If deregistering fails, the
   runner's service is given back, the VM and everything after are kept, and
   `reset` fails; run it again once the cause is fixed.
2. **The VM** (autostart off, stop, delete), with everything in it: extra
   packages, hooks, Docker images. Not with `--keep-vm`. If the delete fails,
   the report names `limactl delete --force <name>`; the steps that do not
   depend on it still run.
3. **The runner group, only if this install created it.** Deleting a group
   moves its runners to Default, so every one of these must hold, and a group
   that cannot be checked is kept, with the page to delete it by hand: the
   state file (below) says `install` created it; it is not the Default group;
   GitHub still lists a group with the recorded id and name; no runner other
   than this instance's own is in it; no `--keep-group`. Needs the same
   `admin:org` scope as creating it. Failing to list or delete it fails
   `reset`, but never stops the VM from being deleted.
4. **The state file**, unless a group it records still exists (kept for
   `--keep-group`, another runner in it, or a failed check or delete), so that
   a later `reset` can still clean it up.
5. **With `--remove-tool` only**, as the very last step and only if everything
   above worked: the `homefield` command, if it is a regular file (not a
   link) whose last line runs `<install dir>/bin/homefield`, in
   `$HOMEFIELD_BIN_DIR` or, when that is unset, in Homebrew's bin or
   `~/.local/bin`; and the install dir (`$HOMEFIELD_HOME`, default
   `~/.local/share/homefield`) if `install.sh` put it there (it has a
   `.homefield-ref`; a git checkout does not). Give `reset` the same
   `HOMEFIELD_HOME` and `HOMEFIELD_BIN_DIR` that `install.sh` had. The command
   and the install dir are shared by every instance on this Mac, which is why
   this is opt-in; after it, `homefield` is gone until the one-liner is run
   again.

What it **does not** remove: a runner group that was already there (including
Default), or one that `install` created but now holds other runners; the
repositories' access to a group; `CI_RUNNER` variables and the routing in the
workflows (switch repositories to hosted first, `route hosted`; `reset`
reminds you when it deregisters); a runner registered on GitHub whose VM is
gone (remove it on the runners page, `reset` cannot reach it without the VM);
other instances; Lima, `gh`, Homebrew and your shell's `PATH`.

**The state file.** `${HOMEFIELD_STATE_DIR:-~/.local/state/homefield}/<instance>.state`
holds `key=value` lines. `group_created=<org>/<group name>/<group id>` is
written by `install` the moment it creates the runner group, before the VM
exists, so a failed install still has it (the id is empty if it could not be
read from GitHub's answer, and `reset` then finds the group by name). A group
that already existed is never recorded. `ever_registered=1` is written by
`install`, `upgrade` and `re-register` before a registration token enters the
VM: it is the [trust boundary](#trust-boundary)'s host-side record, and
`install` refuses a VM it marks, even one whose `_work` is gone. A `reset`
that keeps the VM keeps the line (a `reset` that deletes the VM removes the
file with it). It lives outside the
tool's install directory because `install.sh` replaces that directory on every
update, and it is per instance. There are no secrets in it. Delete the
`group_created` line, or
the file, to make `reset` leave the group alone; without it (a Mac that
installed before this file existed) delete the group by hand in the
organization's *Settings → Actions → Runner groups*.

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
