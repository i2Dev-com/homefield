# ci-runner

Shared tooling for running i2Dev-com's pull-request CI on a local self-hosted
GitHub Actions runner, to cut billed Actions minutes. GitHub stays the source
of triggers, logs and checks; only the machine that executes selected jobs
changes. Background: i2Dev-com/i2dev#879.

| Path | What it is |
|---|---|
| [`vm/lima.yaml`](vm/lima.yaml) | The Lima VM that isolates the runner: Ubuntu 24.04 arm64, no host mounts, no port forwarding, no SSH-agent forwarding |
| [`vm/provision.sh`](vm/provision.sh) | Installs the toolchain, Docker, the checksum-pinned runner, a cleanup timer and an idle-time OS update timer. Registers the runner at `RUNNER_URL` (an organization, in runner group `local-ci`, or one repository) with routing label `RUNNER_LABEL` (default `local-ci`). Idempotent, and handles upgrades and moves |
| [`verify-routing/`](verify-routing/action.yml) | Composite action that fails a repository's CI unless every `runs-on` is either a GitHub-hosted image or the canonical routing expression, and the set of routed jobs matches its reviewed list |
| [`docs/runbook.md`](docs/runbook.md) | Setup, runner group, switching, failure modes, maintenance, removal |
| [`docs/adopting.md`](docs/adopting.md) | Checklist for routing another repository's jobs to the runner |

## The one thing that cannot be shared

`runs-on` is evaluated before any step runs, so no action can choose a job's
runner. A separate "choose the runner" job could hand its answer over through
`needs`, but it is billed a full minute on every run, which is the cost this
exists to remove. So each routed job carries the routing expression inline, and
`verify-routing` keeps every copy identical and every guard in place:

- a hosted fallback;
- pull requests only;
- Dependabot excluded;
- pull requests from forks excluded.

## Usage

```yaml
      - uses: i2Dev-com/ci-runner/verify-routing@v2
        with:
          expected: |
            ci.yml:lint
            ci.yml:test
```

For consumers, this repository must stay accessible to other repositories in
the organization: *Settings → Actions → General → Access*.

## Development

```bash
bash verify-routing/tests/run.sh   # fixture suite: every drift case must fail
bash tests/label-rule.sh           # provision.sh and verify-routing accept the same labels
shellcheck vm/provision.sh verify-routing/tests/run.sh tests/label-rule.sh
```

Releases: move the current major tag for compatible changes. A change that
makes a previously passing workflow fail, such as a new required guard in the
expression, is a new major, because every consumer has to update its inline
copies at the same time. Changes are recorded in [`CHANGELOG.md`](CHANGELOG.md).
The docs on `main` can run ahead of the latest tag; anything not yet released
is listed under *Unreleased* in the changelog.
