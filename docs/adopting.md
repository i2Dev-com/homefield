# Adopting the local runner in a repository

A checklist for routing a repository's pull-request CI to the local runner,
once it is installed ([README: Quick start](../README.md#quick-start)).
Steps 1–4 are edits to the repository's workflows; `ci-runner adopt` (step 5)
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
- Anything that only runs on push or schedule. The expression routes pull
  requests only, so those would never use the runner anyway.

## 2. Route them

Replace each chosen job's `runs-on` with the canonical expression, verbatim.
It must match the `verify-routing` version used in step 3 (`@v2` below); see
[`CHANGELOG.md`](../CHANGELOG.md) when upgrading:

```yaml
runs-on: ${{ vars.CI_RUNNER == 'local' && github.event_name == 'pull_request' && github.actor != 'dependabot[bot]' && !startsWith(github.head_ref, 'dependabot/') && github.event.pull_request.head.repo.full_name == github.repository && fromJSON('["self-hosted","linux","arm64","local-ci"]') || 'ubuntu-latest' }}
```

Put a comment above it that says why the job is routed and points to this
repository's docs. A reusable workflow's job counts too: the check applies to
the file the `runs-on` line is in.

## 3. Add the guard

In a job that runs on every PR, after `actions/checkout`:

```yaml
      - name: Verify local-runner routing
        uses: i2Dev-com/ci-runner/verify-routing@v2
        with:
          expected: |
            ci.yml:lint
            ci.yml:test
```

`expected` lists `workflow-file:job-id` for every job you routed in step 2.
If the runner was registered with a `RUNNER_LABEL` other than `local-ci`, put
that label in the expression in step 2 and pass it here as `label:`.
Routing another job later means adding it here in the same PR, which keeps it
a deliberate, reviewed change.
The step has to use exactly `i2Dev-com/ci-runner/verify-routing@v2` and be in
a workflow that runs on `pull_request`, with no `if: false` on the step or its
job; `ci-runner adopt` does not count anything else as a guard. A reusable
workflow works if one of the repository's `pull_request` workflows calls it
(`uses: ./.github/workflows/<file>`).

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

## 5. Merge, then run `ci-runner adopt`

Merge steps 2–4 with `CI_RUNNER` unset. Everything still runs hosted, and the
guard runs. Then, from any machine with `gh` and `python3` (not the VM):

```bash
ci-runner adopt --repo <owner>/<repo>
```

It does the rest of the setup, in this order, and prints one line for each
step:

1. **Repository.** Reads it with `gh`. A **public repository is refused**: the
   runner is for private repositories only (README, "Security model").
2. **Routing.** Downloads the repository's `.github/workflows` at its default
   branch and runs the same check as the guard. It is ready when a
   `verify-routing` step is there, passes, and at least one job is routed.
   The step must use `i2Dev-com/ci-runner/verify-routing@v2` (a full commit
   SHA is accepted, with a warning) in a workflow that runs on pull requests;
   anything else, such as another repository's action, `@v1`, `@main`, a
   push-only workflow, `pull_request_target` or an `if: false`, is not a
   guard. A reusable workflow (`workflow_call`) counts when a workflow that
   runs on `pull_request` calls it from a job (one level; deeper chains are
   not followed). Branch or path filters on the `pull_request` trigger, and
   other `if:` conditions on the step, its job or the calling job, are
   warnings: check that every pull request that changes `.github/workflows`
   still runs the guard. When the routing is not ready it lists what is wrong
   and prints the routing expression and the guard step to add, with
   `expected:` taken from `--jobs "ci.yml:lint,..."` or from the jobs already
   routed, and exits 1 without switching.
3. **Cache keys.** Warns about `key:` and `restore-keys:` lines that have
   `runner.os` and no `runner.arch` ([step 4](#4-fix-cache-keys)), in the
   workflow files that contain a routed job (all of them while none is
   routed). It matches text, so check what each one is the key of.
4. **Runner group access.** For an organization's custom group (`local-ci` by
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
   as `ci-runner route local`). If it is already `local`, it says so.

It is safe to run again: what is done is reported, not repeated. `--dry-run`
reads everything and changes nothing, and `--no-switch` does everything but
the variable. Merge the routing first, then run it again if it stopped at
step 2.

**By hand**, for a machine without `gh` access to the organization settings:
*Organization settings → Actions → Runner groups → `local-ci` → Repository
access*, add the repository (once the routing is merged). Until then its jobs wait for a runner that is
online but will not take them. A repository-scoped runner, or one in the
Default group, needs nothing here. Then set the variable:
`gh variable set CI_RUNNER --repo <owner>/<repo> --body local`.

## 6. Run it

1. Open or re-run a PR, and confirm that the job log's *Runner name* is the
   local runner's (`bin/ci-runner status` shows it). If the job waits for a
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
jobs themselves are already listed in the guard's `expected`.
