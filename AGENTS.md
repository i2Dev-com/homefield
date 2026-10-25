# AGENTS.md

Guidance for agents working in this repository. Start with `README.md` (what
this is) and `CONTRIBUTING.md` (the pre-PR checklist and conventions).

## What this repo is

Shell and Python only — no package manifest, no build, no lockfile. Three
parts:

- `bin/homefield` + `install.sh` — host-side tool (runs on the Mac, wraps
  Lima), Python helpers in `tools/` behind `adopt` and `report`.
- `vm/lima.yaml` + `vm/provision.sh` — the VM and what runs inside it.
- `routing-guard/` — the published GitHub Action (`routing_guard.py` +
  `action.yml`); consumers pin it as `i2Dev-com/homefield/routing-guard@vX.Y.Z`
  (an exact release tag) or a full commit SHA.

## Bash versions

- `bin/homefield`, `install.sh`, and everything in `tests/` run on the host —
  on a stock Mac that is **bash 3.2**: no `mapfile`, no `inherit_errexit`,
  `set -e` is off inside `$(...)` (check failures there explicitly).
- `vm/provision.sh` runs in the guest (Ubuntu, bash 5) and **must stay
  idempotent**: every run is also an upgrade.
- Run `shellcheck bin/homefield install.sh vm/provision.sh routing-guard/tests/run.sh tests/*.sh`
  (see CONTRIBUTING.md for the full pre-PR list, which also includes
  `actionlint`); CI runs the same.

## Verification

Each suite is standalone; there is no test runner.

```bash
bash routing-guard/tests/run.sh    # fixture suite: every drift case must fail
bash tests/label-rule.sh           # provision.sh and routing-guard accept the same labels
bash tests/adopt.sh                # bin/homefield adopt and tools/adopt.py, with a stub gh
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
- Changes to `bin/homefield` or `vm/provision.sh` should also be tried on a
  **throwaway VM** (`bin/homefield install --instance <name> ...`). Never
  test against a runner that serves real repositories.

## The routing expression is a versioned contract

The canonical `runs-on` expression lives in copies that must change together:
`routing-guard/routing_guard.py`, `README.md` and
`docs/adopting.md` (the runbook links to it instead of repeating it).
`vm/provision.sh` registers the runner with a label list (`RUNNER_LABELS`,
:102) that has to match the expression's `fromJSON` list; no test enforces
that pair, so change them together. `tests/label-rule.sh` keeps the label
rule in agreement — provision.sh and routing-guard must accept and reject
the same labels — run it when touching either.

- **Mandatory guards**, in every variant: the `vars.CI_RUNNER == 'local'`
  switch, a hosted fallback (`fallback` must be a bare GitHub-hosted image
  name), and fork pull requests hosted. Private repositories only is the
  runner group's job, enforced by `adopt`.
- **Options with defaults**: `events` (default `pull_request` only),
  `dependabot` (default `hosted`) and `fallback` (default `ubuntu-latest`).
  They exist on the action, on `routing_guard.py` and on `homefield adopt` and
  `tools/adopt.py` under the same names; the defaults must keep producing the
  original expression byte for byte (`routing-guard/tests/run.sh` hard-codes
  it). `pull_request_target` is never allowed in `events`.
  A new option value or a new option whose default changes the expression is
  a breaking change, as below.

- Releases are exact semver tags (`v0.1.0`, `v0.2.1`, `v0.3.0`) that are
  **never moved**. While we are in 0.x, a change that makes a previously
  passing workflow fail (new guard, new default) bumps the **minor**;
  compatible changes bump the patch. Merged changes wait on `main`, under
  *Unreleased* in `CHANGELOG.md`, until the owner cuts a release. There are
  no tag moves: a release is a new tag the owner creates, so don't ask for
  one after each merge. Say in the PR whether a change is compatible;
  `CHANGELOG.md` explains the upgrade.
- A release bumps the version in `install.sh` (`REF` default and header),
  `bin/homefield` (`update_command`), `tools/adopt.py` (`RELEASE`), the README
  and `docs/`. Before tagging, run `routing-guard/routing_guard.py` over the
  consumers' real workflows (the i2dev and snap checkouts) and expect no
  finding about unreadable syntax: the fixtures alone missed v0.2.0's false
  positives on shell scripts.
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