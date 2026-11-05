# Adopting the local runner in a repository

A checklist for routing a repository's pull-request CI to the local runner,
once it is installed ([README: Quick start](../README.md#quick-start)); the
closing summary of `homefield setup` points here, and lists the repositories
that can already use the runner; on a terminal it then offers to run
`homefield adopt --setup --wait` for you (see [Let adopt write steps 1 to
4](#let-adopt-write-steps-1-to-4)).
Steps 1–4 are edits to the repository's workflows; `homefield adopt` (step 5)
does the rest of the setup and refuses to switch the repository on until
those edits are merged. You can write steps 1–4 by hand, or have
[`homefield adopt --setup`](#let-adopt-write-steps-1-to-4) open a pull request
that writes them for you (with `--wait` it also carries on into step 5 once
you merge it). If you said yes to the offer at the end of `homefield setup`,
that is what ran: what was left to you was reviewing and merging the pull
request, and steps 1–5 were done for you. This page is the same path by hand,
and the reference for what each step does. For a repository without a guard
yet — a personal one being adopted for the first time — the pull request
routes with the simple expression (step 2); pass `--guards` to the command if
you want the guarded one instead.

For a repository after the first, the whole page is one command, which opens
the pull request, waits for your merge and then switches the repository on:

```bash
homefield adopt --setup --wait --repo <owner>/<repo>
```

The steps below are what it does, for when you want to write the edits yourself
or need to know why it refused.

The repository must be **private** (see the trust boundary in
[`runbook.md`](runbook.md#trust-boundary)).

## 1. Choose the jobs

Good candidates are the frequent, short, self-contained PR jobs: lint,
typecheck, unit and integration tests, and path-filter gates. The gates only
take seconds, but each one is billed a full minute.

Keep hosted:

- Docker image builds (x86-64 images, GHA build cache).
- Anything with cloud or production credentials.
- Anything that only runs on push or schedule. By default the expression
  routes pull requests only, so those would never use the runner anyway. They
  can be routed ([routing options](#routing-options)), but then they depend on
  the Mac being awake, and a deploy gated on CI can queue behind it.

The [parity table](runbook.md#what-the-vm-has-compared-with-a-hosted-runner)
in the runbook compares eight dimensions — privileges, apt packages, CLI tools,
browsers, languages, architecture, state between jobs, versions — and says what
to do for any that differ: provision it, use a setup action, or keep the job
hosted.

## 2. Route them

Replace each chosen job's `runs-on` with the routing expression, verbatim.
It must match the `routing-guard` version used in step 3 (`@v0.4.2` below); see
[`CHANGELOG.md`](../CHANGELOG.md) when upgrading. There are two shapes.

A repository whose every contributor you trust with the Mac routes with the
simple one:

```yaml
runs-on: ${{ vars.CI_RUNNER == 'local' && 'homefield-ci' || 'ubuntu-latest' }}
```

It sends the job to the local runner when the repository variable `CI_RUNNER`
is `local`, and to `ubuntu-latest` otherwise — whatever the event: pushes,
schedules, Dependabot's and forks' pull requests included. Its only guardrail
is the switch, which is also the off button (`homefield route hosted`); what
keeps strangers off the runner is everything else — the repository being
private and the runner group. `homefield adopt --setup` writes this shape for
a repository without a guard unless you pass `--guards`, and the guard in
step 3 carries `mode: simple` with it.

A repository with contributors you would not each trust with the Mac, or one
that wants to keep pushes and Dependabot hosted, routes with the guarded
expression instead:

```yaml
runs-on: ${{ vars.CI_RUNNER == 'local' && github.event_name == 'pull_request' && github.actor != 'dependabot[bot]' && !startsWith(github.head_ref, 'dependabot/') && github.event.pull_request.head.repo.full_name == github.repository && fromJSON('["self-hosted","linux","arm64","homefield-ci"]') || 'ubuntu-latest' }}
```

Put a comment above it that says why the job is routed and points to this
repository's docs. A reusable workflow's job counts too: the check applies to
the file the `runs-on` line is in. Write the job in the plain form, `job-id:`
on a line of its own with `runs-on: ...` on the line below: the guard reads
workflows line by line and fails on syntax it cannot read (a quoted
`"runs-on"` key, a `runs-on` key with a tag or anchor, a job written as a
`{...}` mapping, a `<<` merge key). A job that calls a reusable workflow in
*another* repository is refused: the called workflow's jobs evaluate
`runs-on` in this repository's context, and the called file is not here to
check. Call a local workflow (`uses: ./.github/workflows/<file>`) and route
its jobs in that file.

## 3. Add the guard

In a job that runs on every PR, after `actions/checkout`:

```yaml
      - name: Routing guard
        uses: i2Dev-com/homefield/routing-guard@v0.4.2
        with:
          jobs: |
            ci.yml:lint
            ci.yml:test
```

If the repository routes with the simple expression (step 2), the guard
carries `mode: simple` and nothing else changes:

```yaml
      - name: Routing guard
        uses: i2Dev-com/homefield/routing-guard@v0.4.2
        with:
          jobs: |
            ci.yml:lint
          mode: simple
```

`jobs` lists `workflow-file:job-id` for every job you routed in step 2.
If the runner was registered with a `RUNNER_LABEL` other than `homefield-ci`, put
that label in the expression in step 2 and pass it here as `label:`.
Routing another job later means adding it here in the same PR, which keeps it
a deliberate, reviewed change.

`homefield adopt` counts a step as the guard only if:

- it uses `i2Dev-com/homefield/routing-guard@v0.4.2`, the release your
  installed `homefield` checks with (`homefield version` shows it), or a full
  commit SHA. Another release, `@v0` or `@main` do not count;
- it is in a workflow that runs on `pull_request` (not `pull_request_target`,
  not push-only);
- neither the step nor its job has `if: false` or `continue-on-error: true`: a
  guard that cannot fail the check enforces nothing;
- its `with:` is a block (one option per line), and `label:`, if given, is not
  empty. Adopt does not read `with: {jobs: ...}` on one line, and the guard
  refuses an empty label, so adopt reports either one as a problem instead of
  guessing. Guard text that sits inside a `run: |` script is not a step.

A reusable workflow works if one of the repository's `pull_request` workflows
calls it (`uses: ./.github/workflows/<file>`, one level deep) from a job
without `if: false` or `continue-on-error: true`.

### Routing options

The guarded expression above is the shape of `guards` mode, the guard's
default. Three options of `routing-guard` change it; each also exists as a
flag of `homefield adopt` with the same name (`--events`, `--dependabot`,
`--fallback`). Whatever you choose, the
expression in step 2 and the guard in step 3 have to agree, and `homefield
adopt` refuses a guard whose options differ from the flags you pass it. Adopt
also reads the step's `arch` (below) and refuses a step whose `arch:` is not
`arm64`: it sets up the arm64 VM, and there is no flag to change that.

The shape itself is a fourth option: `mode: simple` (or `homefield adopt
--setup` without `--guards` on a repository without a guard) selects the
one-clause expression of step 2. It has no `events` or `dependabot` choice —
every event routes — so the guard refuses them there, and `homefield adopt`
refuses `--events` and `--dependabot` without `--guards`. The guard in simple
mode also accepts the guarded expression, so a repository can move between
the shapes, or mix them, without failing.

```yaml
      - uses: i2Dev-com/homefield/routing-guard@v0.4.2
        with:
          jobs: |
            ci.yml:lint
          events: pull_request, push   # default: pull_request
          dependabot: local            # default: hosted
          fallback: ubuntu-24.04-arm   # default: ubuntu-latest
```

| Option | Default | Choices | What choosing differently costs |
|---|---|---|---|
| `mode` | `guards` | `guards`, `simple` | `simple` checks the one-clause expression (step 2) and accepts the guarded one too; it has no events or Dependabot choice — every event routes — and refuses them. `guards` is the reviewed multi-clause expression this section describes. |
| `events` | `pull_request` | any of `pull_request`, `push`, `workflow_dispatch`, `schedule`, separated by newlines, commas or spaces | Jobs on `push`, `workflow_dispatch` and `schedule` run on the Mac, so they wait while it sleeps (GitHub fails them after 24 hours), and a deploy gated on CI can queue behind them until `CI_RUNNER` is switched. `pull_request_target` is refused: it runs with the repository's secrets on code from forks. So is `merge_group`: a merge group can hold a fork's pull request, and the event has no pull request to check. |
| `dependabot` | `hosted` | `hosted`, `local` | With `local`, Dependabot's branches bring unreviewed install scripts onto a VM that is not thrown away after the job. |
| `fallback` | `ubuntu-latest` | a GitHub-hosted image name: `ubuntu-*`, `windows-*` or `macos-*` | None to the guarantee: it is the image jobs run on when `CI_RUNNER` is not `local`, such as `ubuntu-24.04-arm` for jobs that build for arm64. A self-hosted label is refused, because it would send the job to the runner whenever the switch is off. The guard checks only the prefix, so `homefield adopt` warns about a name that is not one of GitHub's standard labels: a typo would make jobs wait. |

The guard also takes `arch`, the runner's architecture label (default
`arm64`, the VM's). It is not a routing choice: leave it unless the runner
is an x86-64 Linux host ([Moving to dedicated hardware](runbook.md#moving-to-dedicated-hardware)), which takes
`x64`. Any other value is refused, `ARM64` and `amd64` included. `homefield
adopt` reads it too, and refuses a guard step whose `arch:` is anything but
`arm64`, whatever its workflows say: it sets up the arm64 VM, which an `x64`
guard step routes nothing to.

The expression changes with the options, and the guard checks it. For
example, `events: push` gives:

```yaml
runs-on: ${{ vars.CI_RUNNER == 'local' && github.event_name == 'push' && github.actor != 'dependabot[bot]' && !startsWith(github.head_ref, 'dependabot/') && (github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository) && fromJSON('["self-hosted","linux","arm64","homefield-ci"]') || 'ubuntu-latest' }}
```

Unchanged in every case: the `CI_RUNNER == 'local'` switch, a hosted fallback,
and fork pull requests staying hosted. `homefield adopt --repo <owner>/<repo>
--events push` prints the expression and the guard for your choice.

## 4. Fix cache keys

`runner.os` is `Linux` on both the hosted x86-64 runners and the arm64 VM. So
any `actions/cache` key built from `runner.os` alone lets the two architectures
restore each other's build outputs, which can include native binaries. Add
`${{ runner.arch }}` to every cache key and restore-key in the routed jobs.
`actions/setup-node`'s own cache already includes the architecture.

**Clean up what outlives the job.** The VM is not thrown away between jobs,
and the next job may belong to another repository. `services:` containers are
removed by the runner, but anything a step starts itself (`docker run -d`,
`docker compose up`) is not. A leftover container keeps its name and its host
port, so the next job that needs that port fails. Remove such containers in an
`if: always()` step. If they were started in the background, wait for the
starting process to exit first.

## Let adopt write steps 1 to 4

`homefield adopt --setup --repo <owner>/<repo>` reads the same workflows a
plain adopt checks and opens a pull request against the default branch that
writes steps 2–4 for you:

- every job of a workflow that runs on `pull_request` and asks for a
  GitHub-hosted image today gets the routing expression — simple, unless
  `--guards` is given or a guard already in the repository carries another
  shape (`--guards` and an existing simple-mode guard are refused together) —
  with a comment pointing here;
- the routing guard lists exactly those jobs — its `jobs:` block is updated
  where a guard step already runs on pull requests, otherwise a new
  `.github/workflows/homefield-routing.yml` holds the checkout and the guard;
  with the simple expression it carries `mode: simple`, and without one it
  carries no `mode:` input at all;
- every `key:`/`restore-keys:` line in those files that uses `runner.os`
  without `runner.arch` gains `${{ runner.arch }}`.

A workflow whose file name holds a space or a comma is never routed — a
guard's `jobs:` list cannot hold its jobs — and the run says so; the same
limit is why `--jobs` refuses such names.

The staged files are checked with the very `routing_guard.py` the guard step
runs, so the pull request cannot open something its own guard would fail.
Jobs that already carry either shape stay as they are — an already-guarded
job is listed and not rewritten even when the run is simple-mode — whatever
`--jobs` says; `--jobs "ci.yml:lint,..."`
adds exactly that list of hosted jobs on top, and `--label`, `--events`,
`--dependabot` and `--fallback` shape the
expression and the guard as they do for a plain adopt (an existing guard must
already use them, or the run stops and says so; a guard set to `arch: x64` is
refused too, the VM being arm64). In simple mode `--events` and `--dependabot`
are refused: the one-clause expression routes every event. An edited file is
written with LF line
endings even if it had CRLF ones. It exits 1 with "nothing to
route" when no job qualifies, and with the branch's name when
`homefield/route-to-local` already exists — merge or delete that pull request
first.

That branch is the whole output: `--setup` adds nothing to the runner group
and does not set `CI_RUNNER`, so merging it changes how *future* pull requests
are routed while everything still runs hosted. Review the job list — step 1
says what to keep hosted — then merge and run step 5, or let the same command
wait for the merge:

```bash
homefield adopt --repo <owner>/<repo> --setup --wait
```

`--wait` makes the command, once it has opened the pull request, read that
pull request every 10 seconds, and carry on in the same run when it is merged
with exactly what step 5 does: it reads the repository and its workflows again
at the default branch, and runs the checks, the group access and the switch
below. The merge stays yours. Nothing is added to the runner group or switched
while it waits, and a merged pull request whose routing does not pass the
guard's checks stops the run with step 5's "not switched" message, as a plain
adopt would.

- **Timeout.** It waits 60 minutes; `--wait-timeout <minutes>` (a whole number,
  1 or more) changes that. A pull request still open then ends the run with
  exit 4 and the command to run once it is merged.
- **Closed without a merge** ends the run with exit 4: nothing was switched and
  no group access changed. The branch `homefield/route-to-local` stays, so
  delete it before running `--setup` again.
- **A read of the pull request that fails** (the network, the API) is tried
  again, not taken for a closed pull request; five failed reads in a row end
  the run with exit 4.
- **Ctrl-C or `kill`** is safe at any point of a `--setup` run, and the command
  says where things stand, then exits 130 (143 for SIGTERM):
  - *Before the pull request is opened*, nothing was switched or added to the
    runner group, and the branch the command made is taken back.
  - *While the pull request is being opened*, it may exist: the command says
    where to look and leaves the branch, since deleting it would close it. If
    there is no pull request, delete the branch (`gh api -X DELETE
    repos/<owner>/<repo>/git/refs/heads/homefield/route-to-local`) and run
    again.
  - *While waiting*, it prints the step 5 command to run by hand and leaves the
    pull request and its branch as they are.
  - *After the merge*, the group access and `CI_RUNNER` may or may not be done:
    run the step 5 command again, which is safe to repeat.
  - *During `--verify`*, the repository is already routed, only the optional
    check was cut short (a re-run may be in flight), and the commands to check by
    hand are printed.

  A plain `homefield adopt --repo <owner>/<repo>` is always the way to pick up
  from there. The command it prints keeps the `--label` and `--group` you gave
  (a plain adopt without `--group` looks at `homefield-ci`), so run it as
  printed. If `homefield setup` started the run and is ended alone (`kill
  <setup-pid>`, not its whole process group), the run stops by itself, saying
  setup ended, at its next check, within one poll interval (10 seconds by
  default); a step already in progress (the group access, the switch) finishes
  first, and the `--verify` question is not watched.
- **After the merge**, a routing check that fails, a group that cannot be
  changed or a switch that fails stops the run as a plain adopt would, with
  exit 5 (the pull request is merged by then): run `homefield adopt --repo
  <owner>/<repo>` once it is fixed.

The exit status tells a caller (`homefield setup` reads it) how far the run
got: 1 is a failure before the pull request existed (a public repository, no
write access, nothing to route, the branch already there), and it is also what
a run without `--wait` exits with for any failure; 4 is a pull request that is
open and not merged when the wait ended; 5 is a merged pull request whose
step 5 did not finish; 130 and 143 are Ctrl-C and SIGTERM. A fresh
`homefield setup` runs this very command when you say yes to its offer, and
tells these cases apart by that status.

`--wait` needs `--setup` (it follows the pull request that `--setup` opens;
for one you opened yourself, merge it and run step 5), and with `--dry-run` it
has nothing to wait for, since a dry run sends nothing.

## 5. Merge, then run `homefield adopt`

Merge steps 2–4 with `CI_RUNNER` unset. Everything still runs hosted, and the
guard runs. Then, from any machine with `gh` and `python3` (not the VM):

```bash
homefield adopt --repo <owner>/<repo>
```

(If you opened the pull request with `homefield adopt --setup --wait`, or said
yes to the offer at the end of `homefield setup`, this step already runs by
itself once you merge it; run it by hand only if that command was interrupted,
timed out or stopped. See
[Let adopt write steps 1 to 4](#let-adopt-write-steps-1-to-4).)

It does the rest of the setup, in this order, and prints one line for each
step:

1. **Repository.** Reads it with `gh`. A **public repository is refused**: the
   runner is for private repositories only (README, "Security model").
2. **Routing.** Downloads the repository's `.github/workflows` at its default
   branch and runs the same check as the guard. It is ready when a guard
   step as described in step 3 is there, passes, and at least one job is
   routed. Branch or path filters on the `pull_request` trigger, and other
   `if:` or `continue-on-error:` conditions on the step, its job or the
   calling job, are warnings: check that every pull request that changes
   `.github/workflows` still runs the guard. When the routing is not ready it
   lists what is wrong and prints the routing expression and the guard step
   to add (with `jobs:` taken from `--jobs "ci.yml:lint,..."` or from the jobs
   already routed), and exits 1 without switching.
3. **Cache keys.** Warns about `key:` and `restore-keys:` lines that have
   `runner.os` and no `runner.arch` ([step 4](#4-fix-cache-keys)), in the
   workflow files that contain a routed job (all of them while none is
   routed). It matches text, so check what each one is the key of.
4. **Fallback image.** Checks the guard step's `fallback` against GitHub's
   standard hosted labels: a typo such as `ubuntu-lates` passes the guard,
   and the jobs then wait for a runner that does not exist whenever
   `CI_RUNNER` is not `local`. A label this version does not know (a larger
   runner, an image newer than its list) only gets a warning.
5. **Runner group access.** For an organization's custom group (`homefield-ci` by
   default, `--group` for another), adds the repository to the group, but only
   when the routing is ready: group access is what lets the repository's jobs
   reach the runner, so it comes after the routing that keeps them to its own
   pull requests. When the routing is not ready it adds nothing, and warns if
   the repository is already in the group. Adding needs the `admin:org` scope
   (on a terminal it offers `gh auth refresh -s admin:org`); without it, it
   warns and you add the repository by hand (below). Skipped for the Default
   group, a personal account, a group that does not exist (the runner may be
   repository-scoped or in another group), and, with a warning, a group that
   is open to all or all private repositories, where there is nothing to add.
   A group that **allows public repositories** gets a warning too, and the
   summary line says so; adopt still adds the repository, since a public
   repository in the group is a setting for you to turn off (*Allow public
   repositories*, [Runner group](runbook.md#runner-group)). The Default group
   is not looked at (it is open to every repository in the organization), and
   neither is a group whose list could not be read. A **personal-account**
   repository always adopts on its own, with its own repository-scoped
   registration and no group step (`homefield setup`, like `install`, detects a personal
   account, or `--personal` says so, and registers one repository):
   GitHub gives a personal account no account-wide runners or groups (one VM
   per repository for now,
   [#14](https://github.com/i2Dev-com/homefield/issues/14);
   [Runner group](runbook.md#runner-group)).
6. **Switch.** When the routing is ready, sets `CI_RUNNER` to `local` (the same
   as `homefield route local`). If it is already `local`, it says so.
7. **Verify.** Offers to do [step 6](#6-run-it) for you, after the switch (or
   when `CI_RUNNER` was already `local`): it re-runs the repository's latest
   pull-request run and reports where each job landed. See
   [Let adopt check the first run](#let-adopt-check-the-first-run).

It is safe to run again: what is done is reported, not repeated. `--dry-run`
reads everything and changes nothing, and `--no-switch` does everything but
the variable (neither offers the verification, since nothing was switched).
Merge the routing first, then run it again if it stopped at step 2.

**By hand**, for a machine without `gh` access to the organization settings:
*Organization settings → Actions → Runner groups → `homefield-ci` → Repository
access*, add the repository (once the routing is merged). Until then its jobs wait for a runner that is
online but will not take them. A repository-scoped runner, or one in the
Default group, needs nothing here. Then set the variable:
`gh variable set CI_RUNNER --repo <owner>/<repo> --body local`.

## 6. Run it

1. Open or re-run a PR, and confirm that the job log's *Runner name* is the
   local runner's (`bin/homefield status` shows it). If the job waits for a
   runner instead, see "Failure modes" in [`runbook.md`](runbook.md).
   `homefield adopt` can do this for you
   ([below](#let-adopt-check-the-first-run)).
2. **Find toolchain gaps by running, not by reading.** The VM has what
   [`vm/provision.sh`](../vm/provision.sh) installs, which is less than
   `ubuntu-latest`, and grepping the workflows for the commands they call
   misses things. If a job fails locally but passes hosted, close the common
   gap with `homefield upgrade --preset hosted` (browser libraries, `gh`,
   `shellcheck`, `sqlite3`, `xvfb`, `rsync`, AWS CLI v2 and Node), add anything
   else through `RUNNER_EXTRA_PACKAGES` or a hook ("Adding tools" in
   [`runbook.md`](runbook.md)), or keep that job hosted. Only propose a change
   to the base set in `provision.sh` for something nearly every repository
   needs.

### Let adopt check the first run

After the switch, `homefield adopt` offers to re-run the repository's latest
pull-request run and to report where each job landed, which is item 1 above.
On a terminal it asks (the default is no, because the re-run uses CI minutes):

```text
Re-run the latest pull-request run of <owner>/<repo> (uses CI minutes) to confirm the local runner takes it? [y/N]
```

`--verify` does it without asking; `--no-verify` never does. Without a
terminal and without `--verify` it asks nothing, re-runs nothing, and prints
the two commands to do it by hand (`gh run list --repo <owner>/<repo> --event
pull_request --limit 1` and `gh run rerun <run-id> --repo <owner>/<repo>`).
It is not offered with `--dry-run` or `--no-switch`.

It takes the newest `pull_request` run that is not the routing guard's own
workflow (the guard's job is hosted by design, so re-running it proves
nothing; if the only `pull_request` run is the guard's, `adopt` says so and
points at opening a pull request on the repository instead), re-runs it once
it has completed, and reads the jobs of the new attempt from the API for
about three minutes, until each has a runner or has finished. While the run
is still going it keeps looking until a job that asked for the routing label
is listed, because a job behind another one (a reusable workflow called
after a job it needs) may not be listed until that one is done. A job is
local when the labels it asked for include the routing label; its line names
the runner that took it. Per job it reports:

- **ran on the local runner** `<name>`: what you wanted. A job that **failed**
  on it is reported as such, with a pointer to item 2 below.
- **ran on a GitHub-hosted runner**, with a warning: either the job stays
  hosted by design (step 1), or the routing did not take effect for it. A
  re-run uses the workflow files of the original commit, so a run from before
  the routing was merged stays hosted whatever `CI_RUNNER` says; open a new
  pull request instead.
- **still waiting for a runner** when the time is up: see "Failure modes" in
  [`runbook.md`](runbook.md). A job that needs another job also waits for it.

Nothing is reported that the jobs API did not say. If the run is not
finished when the report is made, it says so: a job that starts only after
others finish is not in the list yet, and the run's page has the rest. When there is no
pull-request run yet, or the latest one is still running (a run can only be
re-run once it has completed), it says so and re-runs nothing. A `gh` error is
reported as "could not verify". Whatever it finds, `adopt` exits 0: the
adoption itself succeeded, and the report is information. What is left by hand
is item 2 and, if you want it, step 7.

## 7. Record it

Nothing needs to be written to record which jobs are routed. The setup pull
request lists them in its body, and the routing guard's `jobs:` list in the
repository holds the same set and fails CI if it drifts from the workflows.

Add a note to the repository only for what those two do not capture: why a job
stays hosted (step 1 has the usual reasons), so the next person does not route
it by mistake. To switch the repository back to hosted, run
`homefield route hosted --repo <owner>/<repo>`
([`runbook.md`](runbook.md#switching-per-repository)).
