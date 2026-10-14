# Contributing

Thanks for helping. Issues and pull requests are welcome; for anything larger
than a fix, open an issue first so we can agree on the approach.

## Before you open a pull request

```bash
bash verify-routing/tests/run.sh   # routing guard fixtures
bash tests/label-rule.sh           # label rule, provision.sh and verify-routing agree
bash tests/extra-packages.sh       # RUNNER_EXTRA_PACKAGES validation
bash tests/runner-url.sh           # RUNNER_URL validation
bash tests/memwatch.sh             # memory sampler (needs bash >= 4.2 to run)
bash tests/memory-summary.sh       # `bin/ci-runner memory` summary
bash tests/report.sh               # `bin/ci-runner report`
bash tests/install-sh.sh           # install.sh
bash tests/runner-group.sh         # runner group, wait for online, `version`
shellcheck bin/ci-runner install.sh vm/provision.sh verify-routing/tests/run.sh tests/*.sh
actionlint
```

CI runs the same. Changes to `bin/ci-runner` or `vm/provision.sh` should also be
tried on a throwaway VM (`bin/ci-runner install --instance <name> ...`), and
the pull request should say what was run and what happened. Never test against
a runner that serves real repositories.

## Conventions

- **`bin/ci-runner` and `install.sh` run on the host**, which on a stock Mac is bash 3.2: no
  `mapfile`, no `inherit_errexit`, and `set -e` is off inside `$(...)`, so
  check failures there explicitly. **`vm/provision.sh` runs in the guest**
  (Ubuntu, bash 5) and must stay idempotent: every run is also an upgrade.
- **Tokens never go on a command line**, only on stdin.
- **Anything that stops the runner restores it on failure.**
- **Isolation claims are tested from inside the guest**, not inferred from
  configuration.
- **Documentation follows changes:** a new setting, flag or behaviour
  updates the README or runbook, and `CHANGELOG.md` under *Unreleased*, in
  the same pull request.

## Versioning

Consumers pin `verify-routing@vN`. A change that makes a previously passing
workflow fail (a new guard in the routing expression, a new default) is a new
major version; see the README. Say so in the pull request if yours is one.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
