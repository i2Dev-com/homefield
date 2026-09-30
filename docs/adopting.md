# Adopting the local runner in a repository

A checklist for routing a repository's pull-request CI to the shared local
runner. i2dev did this first (i2Dev-com/i2dev#887). Its
`.github/workflows/ci.yml` and `ci-checks.yml` are the worked example.

The repository must be **private** (see the trust boundary in
[`runbook.md`](runbook.md)).

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
starting process to exit first. snap#886 is the example.

## 5. Allow the repository in the runner group

*Organization settings → Actions → Runner groups → `local-ci` → Repository
access* → add the repository. Until then its jobs wait for a runner that is
online but will not take them.

## 6. Run it, then switch it on

1. Merge steps 2–4 with `CI_RUNNER` unset. Everything still runs hosted, and
   the guard runs.
2. Set the repository variable:
   `GITHUB_TOKEN='' gh variable set CI_RUNNER --repo i2Dev-com/<repo> --body local`.
3. Open or re-run a PR, and confirm in the job log that the runner name is
   `i2dev-ci-lima`.
4. **Find toolchain gaps by running, not by reading.** The VM has what
   [`vm/provision.sh`](../vm/provision.sh) installs, which is less than
   `ubuntu-latest`. i2dev's grep-based inventory missed Docker Compose, which
   one shell test called for real, and the first local run failed on it. If a
   job fails locally but passes hosted, add the missing package to
   `provision.sh` in this repository and re-provision, or keep that job hosted.

## 7. Record it

In the adopting repository, document which jobs are routed and why, and link
to [`runbook.md`](runbook.md). Add a line to the table below.

| Repository | Routed jobs | Since |
|---|---|---|
| i2Dev-com/i2dev | `ci.yml:changes`, `ci-checks.yml:checks` | 2026-09-29 (i2dev#891) |
| i2Dev-com/snap | `ci.yml:ci` | 2026-09-29 (snap#886) |
