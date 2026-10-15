# AGENTS.md

Guidance for agents working in this repository. Start with `README.md` (what
this is) and `CONTRIBUTING.md` (the pre-PR checklist and conventions).

## What this repo is

Shell and Python only — no package manifest, no build, no lockfile. Three
parts:

- `bin/ci-runner` + `install.sh` — host-side tool (runs on the Mac, wraps
  Lima), Python helpers in `tools/` behind `adopt` and `report`.
- `vm/lima.yaml` + `vm/provision.sh` — the VM and what runs inside it.
- `verify-routing/` — the published GitHub Action (`verify_routing.py` +
  `action.yml`); consumers pin it as `i2Dev-com/ci-runner/verify-routing@vN`.

## Bash versions

- `bin/ci-runner`, `install.sh`, and everything in `tests/` run on the host —
  on a stock Mac that is **bash 3.2**: no `mapfile`, no `inherit_errexit`,
  `set -e` is off inside `$(...)` (check failures there explicitly).
- `vm/provision.sh` runs in the guest (Ubuntu, bash 5) and **must stay
  idempotent**: every run is also an upgrade.
- Run `shellcheck bin/ci-runner install.sh vm/provision.sh verify-routing/tests/run.sh tests/*.sh`
  (see CONTRIBUTING.md for the full pre-PR list, which also includes
  `actionlint`); CI runs the same.

## Verification

Each suite is standalone; there is no test runner.

```bash
bash verify-routing/tests/run.sh   # fixture suite: every drift case must fail
bash tests/label-rule.sh           # provision.sh and verify-routing accept the same labels
bash tests/adopt.sh                # bin/ci-runner adopt and tools/adopt.py, with a stub gh
# ... plus the other tests/*.sh suites; see CONTRIBUTING.md
```

- `tests/memwatch.sh` needs **bash ≥ 4.2** and GNU **`timeout`** to run the
  sampler; it skips the run without either (macOS ships neither — a newer
  bash is auto-detected at `/opt/homebrew/bin/bash` etc., but `timeout` only
  comes from coreutils' `gnubin`, since brew links only `gtimeout`). The
  lint part always runs. CI (Linux) runs everything.
- Suites stub every outside effect (`gh`, `curl`, `brew`, `limactl`, temp
  `HOME`); nothing reaches GitHub, a VM, or the real machine.
  `tests/lib.sh` refuses to run as root.
- Tests never observe ambient host state (processes, files, time): give the
  code an override and drive it from the test. This Mac is itself a runner
  host.
- Changes to `bin/ci-runner` or `vm/provision.sh` should also be tried on a
  **throwaway VM** (`bin/ci-runner install --instance <name> ...`). Never
  test against a runner that serves real repositories.

## The routing expression is a versioned contract

The canonical `runs-on` expression (guarded: hosted fallback, PR-only,
no Dependabot, no forks) lives in copies that must change together:
`verify-routing/verify_routing.py`, `vm/provision.sh`, `README.md`,
`docs/adopting.md`, `docs/runbook.md`, `.github/workflows/ci.yml`.
`tests/label-rule.sh` exists to keep provision.sh and verify-routing in
agreement — run it when touching either.

- A change that makes a previously passing workflow fail (new guard, new
  default) is a **new major** `verify-routing@vN`; compatible changes move the
  current tag. Say so in the PR; `CHANGELOG.md` explains the upgrade.
- This repo's own CI checks its workflow against the **published `@v2`
  action**, not the local checkout — a breaking change lands only when the
  tag moves.
- The checker rejects multi-line `runs-on`; write expressions on one line.

## Safety and workflow conventions

- **Tokens never go on a command line** — stdin only (a token on `cmdline` is
  readable by every user in the guest; jobs run PR code).
- **Isolation claims are tested empirically from inside the guest**, never
  inferred from configuration.
- Anything that stops the runner must restore it on every failure path;
  before adding a step to a stateful script, enumerate the states it can be
  reached in.
- `limactl shell` swallows typed stdin — pass `</dev/null` unless feeding a
  token deliberately.
- Docs follow changes in the same PR: new setting/flag/behaviour updates
  README or runbook plus `CHANGELOG.md` under *Unreleased* (PR template has
  checkboxes).
- Start work on a branch (`git switch -c ...`) before any edit.