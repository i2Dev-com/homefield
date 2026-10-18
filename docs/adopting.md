# Adopting the local runner in a repository

A checklist for routing a repository's pull-request CI to the local runner,
once it is installed ([README: Quick start](../README.md#quick-start)).
Steps 1–4 are edits to the repository's workflows; `homefield adopt` (step 5)
does the rest of the setup and refuses to switch the repository on until
those edits are merged.

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

## 2. Route them

Replace each chosen job's `runs-on` with the canonical expression, verbatim.
It must match the `routing-guard` version used in step 3 (`@v0.2.1` below); see
[`CHANGELOG.md`](../CHANGELOG.md) when upgrading:

```yaml
runs-on: ${{ vars.CI_RUNNER == 'local' && github.event_name == 'pull_request' && github.actor != 'dependabot[bot]' && !startsWith(github.head_ref, 'dependabot/') && github.event.pull_request.head.repo.full_name == github.repository && fromJSON('["self-hosted","linux","arm64","homefield-ci"]') || 'ubuntu-latest' }}
```

Put a comment above it that says why the job is routed and points to this
repository's docs. A reusable workflow's job counts too: the check applies to
the file the `runs-on` line is in.

## 3. Add the guard

In a job that runs on every PR, after `actions/checkout`:

```yaml
      - name: Routing guard
        uses: i2Dev-com/homefield/routing-guard@v0.2.1
        with:
          jobs: |
            ci.yml:lint
            ci.yml:test
```

`jobs` lists `workflow-file:job-id` for every job you routed in step 2.
If the runner was registered with a `RUNNER_LABEL` other than `homefield-ci`, put
that label in the expression in step 2 and pass it here as `label:`.
Routing another job later means adding it here in the same PR, which keeps it
a deliberate, reviewed change.
The step has to use `i2Dev-com/homefield/routing-guard@v0.2.1`, the release
your installed `homefield` checks with (`homefield version` shows it), or a
full commit SHA; another release, `@v0` or `@main` do not count. It must be in
a workflow that runs on `pull_request`, with no `if: false` and no
`continue-on-error: true` on the step or its job (a guard that cannot fail the
check enforces nothing); `homefield adopt` does not count anything else as a
guard. A reusable workflow works if one of the repository's `pull_request`
workflows calls it (`uses: ./.github/workflows/<file>`); a calling job with
`if: false` or `continue-on-error: true` beside one that runs does no harm, and
only callers that are all disabled make it not a guard.

### Routing options

The expression above is the default. Three options of `routing-guard` change
it; each also exists as a flag of `homefield adopt` with the same name
(`--events`, `--dependabot`, `--fallback`). Whatever you choose, the
expression in step 2 and the guard in step 3 have to agree, and `homefield
adopt` refuses a guard whose options differ from the flags you pass it.

```yaml
      - uses: i2Dev-com/homefield/routing-guard@v0.2.1
        with:
          jobs: |
            ci.yml:lint
          events: pull_request, push   # default: pull_request
          dependabot: local            # default: hosted
          fallback: ubuntu-24.04-arm   # default: ubuntu-latest
```

| Option | Default | Choices | What choosing differently costs |
|---|---|---|---|
| `events` | `pull_request` | any of `pull_request`, `push`, `workflow_dispatch`, `schedule`, separated by newlines, commas or spaces | Jobs on `push`, `workflow_dispatch` and `schedule` run on the Mac, so they wait while it sleeps (GitHub fails them after 24 hours). A deploy gated on CI can queue behind it, and the jobs fall back to hosted only when `CI_RUNNER` is switched. `pull_request_target` is refused: it runs with the repository's secrets on code from forks. So is `merge_group`: a merge group can hold a pull request from a fork, and the event has no pull request to check where it came from. |
| `dependabot` | `hosted` | `hosted`, `local` | With `local`, Dependabot's branches bring unreviewed install scripts onto a VM that is not thrown away after the job. |
| `fallback` | `ubuntu-latest` | a GitHub-hosted image name: `ubuntu-*`, `windows-*` or `macos-*` | None to the guarantee: it is the image jobs run on when `CI_RUNNER` is not `local`, such as `ubuntu-24.04-arm` for jobs that build for arm64. A self-hosted label is refused, because it would send the job to the runner whenever the switch is off. The guard checks only the prefix, so `homefield adopt` warns about a name that is not one of GitHub's standard labels: a typo would make jobs wait whenever the switch is off. |

Their order does not matter and a repeated event is ignored; the expression
always lists events as `pull_request`, `push`, `workflow_dispatch`,
`schedule`. Several events are parenthesised, and the
fork rule is written so that events without a pull request are not sent
hosted. For example, `events: push` gives:

```yaml
runs-on: ${{ vars.CI_RUNNER == 'local' && github.event_name == 'push' && github.actor != 'dependabot[bot]' && !startsWith(github.head_ref, 'dependabot/') && (github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository) && fromJSON('["self-hosted","linux","arm64","homefield-ci"]') || 'ubuntu-latest' }}
```

Unchanged in every case: the `CI_RUNNER == 'local'` switch, a hosted fallback,
and fork pull requests staying hosted. `homefield adopt --repo <owner>/<repo>
--events push` prints the expression and the guard for your choice when the
repository has no guard yet.

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

## 5. Merge, then run `homefield adopt`

Merge steps 2–4 with `CI_RUNNER` unset. Everything still runs hosted, and the
guard runs. Then, from any machine with `gh` and `python3` (not the VM):

```bash
homefield adopt --repo <owner>/<repo>
```

It does the rest of the setup, in this order, and prints one line for each
step:

1. **Repository.** Reads it with `gh`. A **public repository is refused**: the
   runner is for private repositories only (README, "Security model").
2. **Routing.** Downloads the repository's `.github/workflows` at its default
   branch and runs the same check as the guard. It is ready when a
   `routing-guard` step is there, passes, and at least one job is routed.
   The step must use `i2Dev-com/homefield/routing-guard` at the release
   `homefield` itself is (`@v0.2.1`; a full commit SHA is accepted, with a
   warning) in a workflow that runs on pull requests, because `adopt` checks
   the workflow with its own copy of the guard's rules;
   anything else, such as another repository's action, another release (update
   the pin or `homefield` so they match), a tag that is not an exact release
   (`@v1`), a branch (`@main`), a push-only workflow,
   `pull_request_target`, an `if: false` or a `continue-on-error: true`, is not a guard. A reusable workflow (`workflow_call`) counts when a workflow that
   runs on `pull_request` calls it from a job that is not `if: false` or `continue-on-error: true` (one level;
   deeper chains are not followed). Branch or path filters on the `pull_request` trigger, and
   other `if:` or `continue-on-error:` conditions on the step, its job or the calling job, are
   warnings: check that every pull request that changes `.github/workflows`
   still runs the guard. When the routing is not ready it lists what is wrong
   and prints the routing expression and the guard step to add, with
   `jobs:` taken from `--jobs "ci.yml:lint,..."` or from the jobs already
   routed, and exits 1 without switching.
3. **Cache keys.** Warns about `key:` and `restore-keys:` lines that have
   `runner.os` and no `runner.arch` ([step 4](#4-fix-cache-keys)), in the
   workflow files that contain a routed job (all of them while none is
   routed). It matches text, so check what each one is the key of.
4. **Runner group access.** For an organization's custom group (`homefield-ci` by
   default, `--group` for another), adds the repository to the group if it is
   not in it, but only when the routing is ready: group access is what lets
   the repository's jobs reach the runner, so it comes after the routing that
   keeps them to its own pull requests. When the routing is not ready it adds
   nothing, says so, and warns if the repository is already in the group.
   Adding needs the `admin:org` scope (on a terminal it offers
   `gh auth refresh -s admin:org`). Without that scope it warns, goes on, and
   leaves you to add the repository by hand (below). Skipped for the Default
   group, a personal account, a group that does not exist (the runner may be
   repository-scoped or in another group), and, with a warning, a group that
   is open to all or all private repositories, where there is nothing to add.
5. **Switch.** When the routing is ready, sets `CI_RUNNER` to `local` (the same
   as `homefield route local`). If it is already `local`, it says so.

It is safe to run again: what is done is reported, not repeated. `--dry-run`
reads everything and changes nothing, and `--no-switch` does everything but
the variable. Merge the routing first, then run it again if it stopped at
step 2.

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
2. **Find toolchain gaps by running, not by reading.** The VM has what
   [`vm/provision.sh`](../vm/provision.sh) installs, which is less than
   `ubuntu-latest`. Grepping the workflows for the commands they call misses
   things: that is how Docker Compose, which one shell test ran for real, was
   missed once, and the first local run failed on it. If a
   job fails locally but passes hosted, add what is missing through
   `RUNNER_EXTRA_PACKAGES` or a hook ("Adding tools" in
   [`runbook.md`](runbook.md)), or keep that job hosted. Only propose a
   change to the base set in `provision.sh` for something nearly every
   repository needs.

## 7. Record it

In the adopting repository, document which jobs are routed and why, how to
switch back to hosted, and link to [`runbook.md`](runbook.md). The routed
jobs themselves are already listed in the guard's `jobs`.
