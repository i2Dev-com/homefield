# Try HomeField in 5 minutes: one-PR demo workflow

Before modifying existing CI workflows, you can prove the runner and routing
guard end-to-end in a single pull request. This walkthrough adds a standalone
demo workflow to your repository so you can verify both behaviors:

1. While `CI_RUNNER` is unset, jobs fall back to GitHub-hosted `ubuntu-latest`
   and the routing guard passes.
2. Once adopted (`CI_RUNNER=local`), the demo job runs on your Mac VM and
   prints its `aarch64` Linux kernel and Docker version.

## The demo workflow

Create `.github/workflows/homefield-demo.yml`:

```yaml
name: HomeField demo

on: pull_request

permissions:
  contents: read

jobs:
  routing-guard:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: i2Dev-com/homefield/routing-guard@v0.5.6
        with:
          jobs: |
            homefield-demo.yml:demo

  demo:
    runs-on: ${{ vars.CI_RUNNER == 'local' && github.event_name == 'pull_request' && github.actor != 'dependabot[bot]' && !startsWith(github.head_ref, 'dependabot/') && github.event.pull_request.head.repo.full_name == github.repository && fromJSON('["self-hosted","linux","arm64","homefield-ci"]') || 'ubuntu-latest' }}
    steps:
      - name: Runner info
        run: |
          uname -a
          docker --version
```

The `runs-on` expression in `demo` is the exact canonical guarded expression
that `homefield adopt --setup --guards` writes — not a separate contract. It
routes only non-fork, non-Dependabot pull requests from this repository when
`CI_RUNNER` is `local`, and falls back to `ubuntu-latest` otherwise. (For a
custom label, pass `--label` to `homefield adopt` and match that label in
`fromJSON(...)` and the guard's `label:` input; see
[adopting.md](adopting.md#2-route-them).)

## 1. Open a pull request

Open a pull request adding `.github/workflows/homefield-demo.yml` to a
**private** repository.

With `CI_RUNNER` unset:

- `demo` evaluates the fallback and runs on GitHub-hosted `ubuntu-latest`.
- `routing-guard` checks `.github/workflows` and confirms that
  `homefield-demo.yml:demo` carries the canonical guarded expression.

Both checks pass on the pull request without queueing for your Mac.

## 2. Merge and run `homefield adopt`

Merge the pull request to your default branch, then run:

```bash
homefield adopt --repo <owner>/<repo>
```

`homefield adopt` verifies the workflow's routing guard, adds the repository to
the `homefield-ci` runner group (for an organization), sets `CI_RUNNER=local`,
and offers to re-run the pull-request run to verify where it lands.

Accept the verify prompt (or open another pull request):

- Check the `Runner info` step in the job log: it runs on your local runner,
  printing an `aarch64` Linux kernel and `docker --version`.
- If the job stays queued, check `homefield status` on the Mac
  ([runbook: Failure modes](runbook.md#failure-modes)).

## 3. Route real workflows and remove the demo

Once the demo passes on your Mac, replace it with routing for your real CI
workflows without dropping your routing guard (`homefield adopt --setup` reads
`.github/workflows` on GitHub's **default branch** — never unmerged local
edits — and reuses an existing usable guard step instead of creating a new
guard workflow):

1. Either delete `.github/workflows/homefield-demo.yml` on your **default
   branch** first (commit, push, and merge that deletion), then run:

   ```bash
   homefield adopt --setup --wait --repo <owner>/<repo>
   ```

   Because no guard workflow remains on the default branch, `--setup` creates
   a dedicated `.github/workflows/homefield-routing.yml` alongside the routed
   jobs, opens a pull request, waits for you to merge it, and verifies the
   jobs on the local runner.

2. Or run `homefield adopt --setup --wait --repo <owner>/<repo>` while
   `homefield-demo.yml` is still on the default branch, and in the pull
   request `--setup` opens, move the `routing-guard` job into a permanent
   workflow (such as `.github/workflows/homefield-routing.yml`), remove
   `homefield-demo.yml:demo` from its `jobs:` list, and delete
   `.github/workflows/homefield-demo.yml` before merging so your routed
   workflows keep their routing check.

For routing options, simple vs. guarded mode, and operating the runner, see:

- [adopting.md](adopting.md) — full adoption guide, simple mode, and cache keys.
- [runbook.md](runbook.md) — trust boundaries, hosted parity, and operations.
- [getting-started.md](getting-started.md) — first-time install and `setup`.
