# ci-runner

Run selected pull-request jobs from GitHub Actions on a self-hosted runner in
an isolated VM on your Mac, instead of on GitHub-hosted runners. GitHub stays
where CI is triggered, where logs live and where checks report; only the
machine that executes the chosen jobs changes. If the runner is off, you flip
one repository variable and everything runs hosted again.

It has three parts:

- **An isolated runner VM** ([`vm/`](vm)): Ubuntu 24.04 arm64 in
  [Lima](https://lima-vm.io), with no access to the Mac's files, SSH keys or
  credentials. It does have network access, including to the Mac's own
  services ([Security model](#security-model)).
- **A one-command setup** ([`bin/ci-runner`](bin/ci-runner)): install,
  upgrade, status, uninstall.
- **A routing guard** ([`verify-routing`](verify-routing/action.yml)): a
  GitHub Action that fails CI unless every job that can reach the runner uses
  the one reviewed `runs-on` expression, with its safety guards, and the set of
  routed jobs is the reviewed list.

## Quick start

On an Apple Silicon Mac with Lima ≥ 1.1 (`brew install lima`), from a
checkout of this repository:

```bash
bin/ci-runner install --url https://github.com/<org>      # or https://github.com/<owner>/<repo>
bin/ci-runner status
```

This creates the VM, checks its isolation, provisions it and registers the
runner with the routing label `local-ci`. Registration needs a one-hour token:
`gh` fetches it if you are an org owner (`admin:org` scope) or a repository
admin, and otherwise you paste one from the *New runner* page. For an
organization, first create a runner group that admits only the repositories
that will use it ([runbook: Runner group](docs/runbook.md#runner-group)).

Then route jobs from a repository by following
[`docs/adopting.md`](docs/adopting.md), and switch it on:

```bash
gh variable set CI_RUNNER --repo <owner>/<repo> --body local    # hosted again: --body hosted
```

`bin/ci-runner help` lists the options (`--label`, `--packages`, `--cpus`,
...). [`docs/runbook.md`](docs/runbook.md) covers operating it.

## Requirements and limitations

- **Apple Silicon Mac, arm64 jobs.** The VM uses Apple's
  Virtualization.framework and runs arm64 Linux. Jobs that need x86-64 (amd64
  container images, prebuilt x86 binaries, x86 Docker builds) belong on hosted
  runners. Cache keys need `runner.arch` ([adopting, step 4](docs/adopting.md#4-fix-cache-keys)).
  `provision.sh` also runs on an Ubuntu arm64 host
  ([runbook](docs/runbook.md#moving-to-dedicated-hardware)).
- **Private repositories only.** A pull request runs the workflow files from
  its own branch, so anyone who can open one can change its `runs-on`. Keep
  every repository that can reach the runner private, with the runner group
  refusing public ones. See [Security model](#security-model).
- **One job at a time**, across every repository using the runner. Others
  queue. (Running several is tracked in [#14](https://github.com/i2Dev-com/ci-runner/issues/14).)
- **Only while the Mac is up.** Routed jobs wait while the Mac sleeps or the
  VM is stopped, and GitHub fails them after 24 hours. Pushes to the default
  branch always run hosted, so merging and deploying never wait on the Mac.
  To route around a sleeping runner, set `CI_RUNNER` to `hosted` and re-run
  ([runbook: Switching](docs/runbook.md#switching-per-repository)).
- **Organizations and plans.** On an organization, a custom runner group
  limits which repositories can use the runner; custom groups need the GitHub
  Team plan or Enterprise. On the Free plan there is only the Default group,
  which every repository in the organization can use, so only register there
  if you trust all of them, and pass `--group Default` (the default,
  `local-ci`, does not exist there and registration would fail). A **personal account** cannot have an
  account-wide runner: register per repository (`--url
  https://github.com/<you>/<repo>`), one VM per repository.
- **Less software than `ubuntu-latest`.** The VM starts small. Add what your
  jobs need with `--packages` or a hook
  ([runbook: Adding tools](docs/runbook.md#adding-tools)).

## Security model

The VM is the boundary. Jobs run pull-request code, so the Mac's files and
credentials are not reachable from inside: no mounts (`mounts: []` plus
`--mount-none`, and `bin/ci-runner` refuses to continue if it finds any), no
SSH-agent forwarding and no host SSH keys. Services started by a job are not
forwarded to the Mac's `localhost`. Inside the guest, jobs are
root-equivalent (the `docker` group), which is why the VM and not a user
account is the boundary.

**The network is not isolated.** Jobs can reach the internet, your LAN, and,
through `host.lima.internal`, **every service listening on the Mac, including
ones bound only to `127.0.0.1`** (local databases, development servers, local
AI or tool APIs). Until that is closed ([#18](https://github.com/i2Dev-com/ci-runner/issues/18)), don't run anything on the
Mac hosting the runner that the repositories using it shouldn't be able to
reach.

The routing expression keeps pushes, Dependabot and pull requests from forks
on hosted runners. The fork rule is defence in depth only: what keeps
strangers off the runner is that only private repositories can reach it.
Repositories that share the runner share one VM, one job after another, and
can see what earlier jobs left behind, so share it only between repositories
you would trust with each other's pull requests. Registration tokens reach
the VM on stdin, never on a command line. The full table:
[runbook: Trust boundary](docs/runbook.md#trust-boundary).

## How routing works

`runs-on` is evaluated before any step runs, so no action can choose a job's
runner, and a separate "choose the runner" job would itself be billed a full
minute on every run. So each routed job carries the routing expression
inline:

```yaml
runs-on: ${{ vars.CI_RUNNER == 'local' && github.event_name == 'pull_request' && github.actor != 'dependabot[bot]' && !startsWith(github.head_ref, 'dependabot/') && github.event.pull_request.head.repo.full_name == github.repository && fromJSON('["self-hosted","linux","arm64","local-ci"]') || 'ubuntu-latest' }}
```

It sends the job to the local runner only when the repository variable
`CI_RUNNER` is `local`, the event is a pull request, the author is not
Dependabot and the branch is not from a fork; otherwise to `ubuntu-latest`.
`verify-routing` keeps every copy identical and every guard in place:

```yaml
      - uses: i2Dev-com/ci-runner/verify-routing@v2
        with:
          expected: |
            ci.yml:lint
            ci.yml:test
```

It also fails on any other `runs-on` that could reach the runner (a bare
`self-hosted`, a label list, a runner group), because GitHub hands a job to
any runner whose labels are a superset of the request.

## Cost

GitHub-hosted runners bill every job rounded up to a whole minute (Linux
x64 $0.006/min, arm64 $0.005/min), after the plan's included minutes (2,000 a
month on Free, 3,000 on Pro and Team). Self-hosted runner usage is free. So
this pays off for repositories that exhaust their included minutes with many
short pull-request jobs, where the per-job minute floor dominates. It does not
help a repository that stays within them, and it costs the Mac's resources
while the VM runs (it holds its configured memory, 8 GiB by default).

GitHub announced a per-minute platform charge for self-hosted runners on
private repositories for March 2026, then postponed it indefinitely. Check
[GitHub's Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
for the current terms.

## Alternatives

- **[actions-runner-controller](https://github.com/actions/actions-runner-controller)**:
  ephemeral runners on Kubernetes. The right choice for a team with a
  cluster; far more to operate than one VM.
- **[Tart](https://tart.run) / [Cirrus Runners](https://cirrus-runners.app)**:
  macOS and Linux VMs on Apple Silicon, including macOS jobs, which this does
  not do.
- **[act](https://github.com/nektos/act)**: runs workflows locally without
  GitHub. Good for iterating on a workflow, but no checks on the pull request.
- **Larger or cheaper hosted runners**: no hardware to run, and nothing to
  secure.

This project's niche: an opt-in, per-repository switch with a hosted
fallback, guard rails that keep the routing reviewed, and a VM that keeps
pull-request code away from the Mac it runs on.

## Repository layout

| Path | What it is |
|---|---|
| [`bin/ci-runner`](bin/ci-runner) | Install, upgrade, inspect and remove the runner on this Mac |
| [`vm/lima.yaml`](vm/lima.yaml) | The VM: Ubuntu 24.04 arm64, no host mounts, no forwarding of guest ports to the Mac, no SSH-agent forwarding |
| [`vm/provision.sh`](vm/provision.sh) | Runs inside the VM: packages, Docker, the checksum-pinned runner, cleanup and idle-time OS update timers, registration. Settings: `RUNNER_URL`, `RUNNER_LABEL`, `RUNNER_NAME`, `RUNNER_GROUP`, `RUNNER_EXTRA_PACKAGES`; hooks in `/etc/ci-runner/provision.d/` |
| [`verify-routing/`](verify-routing/action.yml) | The routing guard action |
| [`docs/adopting.md`](docs/adopting.md) | Checklist for routing a repository's jobs to the runner |
| [`docs/runbook.md`](docs/runbook.md) | Operating it: setup, runner group, switching, failure modes, maintenance, moving, removal |

## Development

```bash
bash verify-routing/tests/run.sh   # fixture suite: every drift case must fail
bash tests/label-rule.sh           # provision.sh and verify-routing accept the same labels
bash tests/extra-packages.sh       # RUNNER_EXTRA_PACKAGES accepts package names only
bash tests/runner-url.sh           # RUNNER_URL accepts github.com orgs and repos only
shellcheck bin/ci-runner vm/provision.sh verify-routing/tests/run.sh tests/*.sh
```

## Versioning

Consumers pin `verify-routing@vN`. A compatible change moves the current
major tag. A change that makes a previously passing workflow fail, such as a
new guard in the expression, is a new major, because every consumer has to
update its inline copies at the same time; [`CHANGELOG.md`](CHANGELOG.md)
says how to upgrade. The docs on `main` can run ahead of the latest tag;
anything not yet released is listed under *Unreleased*.

While this repository is private, it has to allow access from the other
repositories in the organization for them to use the action: *Settings →
Actions → General → Access*.

## Contributing, security, license

Contributions are welcome: see [`CONTRIBUTING.md`](CONTRIBUTING.md). Report
security issues privately, as described in [`SECURITY.md`](SECURITY.md), which
also lists the known limitations. Licensed under the [MIT License](LICENSE).
