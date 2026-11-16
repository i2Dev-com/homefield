# Security audit and invariant map

This document maps HomeField's four security invariants to the exact code that
enforces them and the suites that test them, alongside GitHub's *Security
hardening for GitHub Actions* checklist.

**Audit status:** first-party line-by-line audit (complemented by automated
regression suites and earlier AI-assisted read-only audits; see
[docs/security.md](security.md) for past bypasses and fixes). **No third-party
audit has been commissioned yet** — independent reviews are welcome via
[`SECURITY.md`](../SECURITY.md#audit-and-researcher-invitation).

## Core invariants

| # | Invariant | Enforcing code | Regression suites |
|---|---|---|---|
| 1 | Every routed job carries the reviewed expression (drift rejected) | [`routing_guard.py`](../routing-guard/routing_guard.py), [`action.yml`](../routing-guard/action.yml), [`tools/adopt.py`](../tools/adopt.py) | `routing-guard/tests/run.sh`, `tests/label-rule.sh`, `tests/adopt.sh` |
| 2 | Every job's `runs-on` is machine-readable by the scanner | [`routing_guard.py`](../routing-guard/routing_guard.py) | `routing-guard/tests/run.sh`, `tests/parser-parity.sh` |
| 3 | No host data mounts, no host credentials, verified loopback isolation | [`vm/lima.yaml`](../vm/lima.yaml), [`bin/lib/vm.sh`](../bin/lib/vm.sh), [`vm/guest/homefield-mount-count`](../vm/guest/homefield-mount-count) | `tests/loopback-probe.sh`, `tests/guest-scripts.sh`, `tests/setup.sh`, `tests/diagnose.sh` |
| 4 | Tokens never appear on a command line (`stdin` / preserved env only) | [`bin/lib/vm.sh`](../bin/lib/vm.sh), [`bin/cmd-install.sh`](../bin/cmd-install.sh), [`vm/provision.sh`](../vm/provision.sh) | `tests/provision-recovery.sh`, `tests/uninstall.sh`, `tests/reset.sh` |

### 1. Every routed job carries the reviewed expression

- **Canonical expression builders** ([`routing_guard.py:182-225`](../routing-guard/routing_guard.py#L182-L225)):
  `simple_expression` (switch + hosted fallback only, for trusted private repos)
  and `canonical_expression` (switch, allowlisted `events`, optional
  `dependabot` actor and `dependabot/` branch exclusions, fork PR exclusion,
  `fromJSON(...)` label array, hosted fallback). `guards()` asserts every
  mandatory clause is present in the generated string (`routing_guard.py:209-225`).
- **Strict allowlist and set equality** ([`routing_guard.py:544-590`](../routing-guard/routing_guard.py#L544-L590)):
  every job's `runs-on:` must match either `HOSTED` (`:79-82`) or the expected
  expression (`accepted`). Before exiting `0`, the checker enforces exact set
  equality (`expected == found` at `:583-590`) and re-asserts its own
  invariants (`:592-609`).
- **Composite action input isolation** ([`action.yml:64-85`](../routing-guard/action.yml#L64-L85)):
  action inputs flow through `env:` (`INPUT_JOBS`, `INPUT_LABEL`, etc.), never
  shell-interpolated directly into `run:`.
- **Non-bypassable guard enforcement** ([`tools/adopt.py:454-500, 574`](../tools/adopt.py#L454-L500)):
  `homefield adopt` refuses any guard step whose step, enclosing job, or
  workflow-calling job sets `continue-on-error: true` (or `if: false` at
  `:449-453, 486`).

### 2. Every job's `runs-on` is machine-readable by the line scanner

Because the guard intentionally avoids a full third-party YAML dependency, any
valid YAML syntax it cannot parse deterministically MUST fail closed:

- **Rejected YAML constructs** ([`routing_guard.py:234-268`](../routing-guard/routing_guard.py#L234-L268)):
  `PLAIN_KEY`, `UNREAD`, and `BLOCK_START` reject quoted `"runs-on"` / `"uses"`
  keys, flow mappings `{...}`, merge keys `<<`, complex `?` keys, node anchors
  `&` and tags `!`, escape-bearing quoted keys, multi-line `runs-on`, and
  spaces before `:`. Script scalars (`BLOCK_START`) are tracked by indentation
  so shell snippets inside `run: |` do not create false positives.
- **Line-by-line state machine** ([`routing_guard.py:435-508`](../routing-guard/routing_guard.py#L435-L508)):
  tracks `jobs:`, per-job keys, and per-body indentation; rejects malformed
  top-level lines, unexpected indentation shifts, or jobs on the `jobs:` line.
- **Remote reusable workflows refused** ([`routing_guard.py:515-541`](../routing-guard/routing_guard.py#L515-L541)):
  any job-level `uses:` not starting with `./` (local reusable workflow) fails
  because its `runs-on:` evaluates in the caller's context out of view.
- **Shared parser parity**: `tests/parser-parity.sh` verifies that `tools/adopt.py`
  and `routing_guard.py` classify and reject identical workflow shapes.

### 3. No host data mounts, no host credentials, and verified loopback isolation

HomeField never assumes VM configuration alone holds — it tests isolation
empirically from inside the running guest:

- **VM configuration** ([`vm/lima.yaml:23-61, 90-97`](../vm/lima.yaml#L23-L61)):
  uses `base: template:_images/ubuntu-24.04` (omitting `_default/mounts`, which
  would mount `$HOME`), sets `mounts: []`, disables `ssh.forwardAgent` and
  `ssh.loadDotSSHPubKeys`, ignores guest `portForwards` (`1..65535`), sets
  `networkOpts.hostLoopback: false`, and enables only Apple's read-only Rosetta
  translator share (`vz-rosetta on /mnt/lima-rosetta`). VM creation passes
  `--mount-none` explicitly ([`bin/lib/vm.sh:187-190`](../bin/lib/vm.sh#L187-L190)).
- **Empirical mount & home-dir check** ([`bin/lib/vm.sh:231-266`](../bin/lib/vm.sh#L231-L266)):
  `verify_isolation` runs `isolation_probe` on every install/upgrade/provision,
  executing [`vm/guest/homefield-mount-count`](../vm/guest/homefield-mount-count)
  inside the guest to count host mounts (`virtiofs`/`9p`/`sshfs`/`reverse-sshfs`,
  excluding at most one `vz-rosetta on /mnt/lima-rosetta` line) and confirming
  `/Users` is invisible (`guest_sees /Users` returns 1). Non-zero counts or
  unresponsive guests abort immediately.
- **Empirical host-loopback check** ([`bin/lib/vm.sh:445-475`](../bin/lib/vm.sh#L445-L475)):
  `verify_loopback` binds an ephemeral TCP listener on the Mac's `127.0.0.1`
  and tests connectivity from inside the guest to `host.lima.internal`. If
  reachable (`open`) while `hostLoopback: false` is configured, it fails fatally;
  if the listener dies or `nc -k` is unavailable, `LOOPBACK_STATE` records
  `not-verified` rather than falsely claiming verified closure.

### 4. Tokens never appear on a command line

- **Host-to-guest boundary** ([`bin/lib/vm.sh:203-204, 705`](../bin/lib/vm.sh#L203-L204)):
  `guest()` closes stdin (`</dev/null`), while `guest_stdin()` streams
  `RUNNER_TOKEN` / `RUNNER_REMOVE_TOKEN` over stdin from
  [`bin/cmd-install.sh:740-744`](../bin/cmd-install.sh#L740-L744) (which clears
  its shell variable right after).
- **Guest entrypoint** ([`vm/provision.sh:266-282`](../vm/provision.sh#L266-L282)):
  rejects `RUNNER_TOKEN` or `RUNNER_REMOVE_TOKEN` if present in the environment
  and reads them solely from stdin.
- **Runner CLI invocation** ([`vm/provision.sh:560-596`](../vm/provision.sh#L560-L596)):
  `runner_config` passes tokens to `./config.sh` through
  `ACTIONS_RUNNER_INPUT_TOKEN` with `sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN`
  (never `--token <value>` in process argv), then clears `RUNNER_TOKEN` and
  `RUNNER_REMOVE_TOKEN`.

## GitHub hardening checklist alignment

Mapping GitHub's [*Security hardening for GitHub Actions*](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions) guidance to HomeField:

| Hardening question | HomeField control & boundary |
|---|---|
| *Can public repositories or forks run code on the self-hosted machine?* | Private repositories only (runner group enforces `allows_public_repositories: false`; `adopt` refuses public repos). Guarded mode adds fork (`head.repo.full_name == github.repository`), `pull_request`-only, and Dependabot exclusions. |
| *Can `pull_request_target` workflows execute untrusted PR code?* | In default `guards` mode, `routing-guard` refuses `pull_request_target` in `events` ([`routing_guard.py:110-149`](../routing-guard/routing_guard.py#L110-L149)), so `canonical_expression` routes only allowlisted events and sends `pull_request_target` runs to the hosted fallback ([`:166-206`](../routing-guard/routing_guard.py#L166-L206)); `homefield adopt` also blocks guard workflows that run on `pull_request_target` instead of `pull_request` ([`tools/adopt.py:501-510`](../tools/adopt.py#L501-L510)). In `--mode simple`, the scanner does not inspect workflow `on:` triggers and deliberately lets `simple_expression` (`CI_RUNNER == 'local'` only) route every event locally — simple mode assumes a trusted private repository where every contributor may use the Mac ([`routing_guard.py:118-124, 182-187`](../routing-guard/routing_guard.py#L118-L124)). |
| *Are action versions pinned immutably?* | Release tags follow the exact-semver, never-moved release policy ([`README.md`](../README.md#versioning)), and `homefield adopt` accepts immutable 40-character commit SHA pins ([`tools/adopt.py:559-576`](../tools/adopt.py#L559-L576)). |
| *Are host credentials and files isolated from jobs?* | Isolated Lima VM (`--mount-none`, no SSH agent/keys, no loopback port forwarding), empirically probed inside the guest before registration or upgrades. |
| *What remains a deliberate caveat?* | Persistent runner across jobs on the same Mac (repos sharing one VM share disk/Docker state); guest jobs can still reach the internet and `*`-bound LAN services on the Mac's LAN IP. See [`SECURITY.md`](../SECURITY.md#known-limitations) and [`docs/runbook.md`](runbook.md#trust-boundary). |

## Reproducing the security checks locally

Run the routing-guard fixture suite, parser-parity check, and loopback/mount probe suites locally (without touching any live VM or GitHub account):

```bash
bash routing-guard/tests/run.sh
bash tests/label-rule.sh
bash tests/parser-parity.sh
bash tests/loopback-probe.sh
bash tests/guest-scripts.sh
bash tests/provision-recovery.sh
```

See [`SECURITY.md`](../SECURITY.md) for how to report a vulnerability privately.
