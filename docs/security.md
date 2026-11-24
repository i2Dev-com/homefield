# The routing guard: contract and past bypasses

The routing guard (`routing-guard/routing_guard.py`, run as
[`i2Dev-com/homefield/routing-guard`](routing-guard/action.yml)) fails CI
unless every job that can reach the local runner uses the one reviewed
`runs-on` expression. Which restrictions the expression carries depends on
its shape. The **guarded** expression — the one the docs and the examples
here describe — routes a job to the self-hosted runner only when
`vars.CI_RUNNER == 'local'`, the event is a pull request, the author is not
Dependabot and the branch is not from a fork; everything else falls back to
a GitHub-hosted image. Its events and Dependabot handling are options of
the action (`events`, `dependabot`): a repository can opt a push schedule
or Dependabot in deliberately, and the guard checks the jobs against the
expression those options produce. The **simple** expression — the default
`homefield adopt --setup` writes — has only the switch and the hosted
fallback: every event routes, pushes and fork pull requests included. It is
for a private repository where being able to open a pull request already
means being trusted with the Mac (or use `--ephemeral` on throwaway VMs so
each job gets a fresh runner registration). The full procedure, including how to
write and pin the guard, is [adopting.md](adopting.md) steps 2-3.

## The contract

- **Write the `runs-on` key plainly**: `job-id:` on a line of its own,
  `runs-on: ...` on the line below. The guard reads workflow files line by
  line and fails, with the unreadable-syntax message, on spellings it cannot
  read (a quoted `"runs-on"` key, a key with a tag or an anchor, a job
  written as a `{...}` mapping, a `<<` merge key). A job that passes the
  check is a job the guard read.
- **Call local reusable workflows only** (`uses: ./.github/workflows/<file>`).
  A remote call is refused: the called file is not in this repository to
  scan, and its jobs evaluate `runs-on` in the caller's context.
- **The guard step must be able to fail**: no `continue-on-error` on the
  step, its job, or the job calling it. `homefield adopt` refuses to accept
  one.

Weaknesses are reported privately — see
[`SECURITY.md`](../SECURITY.md). The bypasses below were found during
AI-assisted read-only audits and fixed; each section says who was affected
and what consumers do. The invariant that drives the pin advice: **a
workflow that passes the current release's check ran guarded before.**
Release tags (`v*`) follow [`.github/rulesets/protect-release-tags.json`](../.github/rulesets/protect-release-tags.json)
(blocking tag deletions, updates, and non-fast-forward moves), and consumers
who want cryptographic immutability independent of upstream tag rules can pin
the action to a full 40-character commit SHA instead of a tag.

## A `runs-on` key written in other valid YAML

`"runs-on": self-hosted` (quoted), a job written as a `{...}` mapping, a
`<<` merge key, a `? runs-on` complex key, or a key split over two lines —
each has the key `runs-on`, and every release before v0.2.1 read only a
plain `runs-on:` under a plain `job-id:` line. The job was treated as having
no `runs-on`, which the guard did not check, and it reached the self-hosted
runner with none of the reviewed expression's restrictions.

- **Advisory:** [GHSA-4795-jpw2-47v2](https://github.com/i2Dev-com/homefield/security/advisories/GHSA-4795-jpw2-47v2)
- **Affected:** v0.1.0-v0.1.1. v0.2.0 contains the fix but was too strict
  and should not be pinned.
- **Fixed in:** v0.2.1 — the guard fails on workflow syntax it cannot read
  ([#71](https://github.com/i2Dev-com/homefield/issues/71),
  [#74](https://github.com/i2Dev-com/homefield/issues/74)).
- **Consumer fix:** pin `routing-guard@v0.2.1` or later. Workflows that
  start failing are rewritten in the plain form.

## `continue-on-error` on the routing-guard step

`homefield adopt` counted a routing-guard step as working when the step, its
job, or the job calling its reusable workflow had `continue-on-error: true`
(also written as `${{ true }}` or with quoted keys). Such a guard cannot
fail the check, so a later routing violation left the check green. This is a
guard-enforcement gap, not a VM escape, and needs write access to the
repository.

- **Advisory:** [GHSA-f4px-f5g2-f9px](https://github.com/i2Dev-com/homefield/security/advisories/GHSA-f4px-f5g2-f9px)
- **Affected:** v0.1.0-v0.1.1 of `homefield adopt`.
- **Fixed in:** v0.2.1
  ([#72](https://github.com/i2Dev-com/homefield/issues/72)) — a guard with
  `continue-on-error: true` is no longer accepted, and a
  `continue-on-error` expression is a warning. Update `homefield` (the
  README one-liner).
- **Consumer fix:** update `homefield`; do not set `continue-on-error` on
  the guard step or its job.

## A `runs-on` key carrying a tag or an anchor

YAML allows a mapping key to carry a tag or an anchor while staying a plain
string key. All of these spellings have the key `runs-on`:

```yaml
jobs:
  build:
    !!str runs-on: [self-hosted]
    &a runs-on: [self-hosted]
    &a "runs-on": [self-hosted]
```

The unreadable-syntax refusal since v0.2.1 (above) caught the quoted key —
but a tag or an anchor before the key is a separate spelling of the same
class, and every release before v0.5.0 matched a job's `runs-on` by line
*text*. A workflow written with a tagged or anchored key did not match, so
its job was treated as having no `runs-on`, and the workflow passed the
guard while the job ran on the self-hosted runner with none of the four
guarantees. Found by the audit, verified against v0.4.2.

- **Affected:** any workflow passing the guard at a pin of v0.4.2 or
  earlier, with one of the three spellings above and a self-hosted value.
  A workflow that passes v0.5.0's check ran guarded before.
- **Fixed in:** v0.5.0 — the checker resolves the key of every top-level
  job line the way the YAML spec does: a tag and an anchor before the key
  are stripped, and a quoted key is unquoted. A job whose `runs-on` key is
  written with a tag or an anchor now fails with the unreadable-syntax
  message, like the quoted spellings. The guard's contract stays "write
  the key plainly".
- **Consumer fix:** bump the pin: `i2Dev-com/homefield/routing-guard@v0.4.2`
  → `@v0.5.0` (or a full commit SHA). A v0.4.2 pin keeps passing the bypass
  forms, so the pin is the fix. Workflows that start failing with the
  unreadable-syntax message are rewritten by writing `runs-on:` plainly.

## A job calling a reusable workflow in another repository

```yaml
jobs:
  build:
    uses: other-owner/other-repo/.github/workflows/wf.yml@v1
```

Every release before v0.5.0 scanned only the files in *this* repository, so
the called workflow file was never read — and a job calling a reusable
workflow has no `runs-on` of its own, so it was treated as having no
`runs-on` and not checked. The called workflow's jobs evaluate their
`runs-on` in the **caller's** context: a remote workflow with
`runs-on: [self-hosted]` therefore reached the caller's self-hosted runner
with none of the reviewed expression's restrictions — the caller passed the
guard, and the routing happened in a file the guard never saw. A
step-level `uses:` (`actions/checkout@v4`) is not a call and is not
affected.

- **Affected:** any workflow passing the guard at a pin of v0.4.2 or
  earlier, with a job calling a reusable workflow in another repository
  whose jobs route to `self-hosted`. A workflow that passes v0.5.0's check
  ran guarded before.
- **Fixed in:** v0.5.0 — the guard refuses a job whose `uses:` points at a
  reusable workflow in another repository (not starting with `./`). There
  is no guarded spelling of a remote call — the called file is not in this
  repository to scan — so the failure message names the guarded spelling:
  call a **local** workflow (`./.github/workflows/<file>`), which the guard
  scans like any other file, and route its jobs there.
- **Consumer fix:** bump the pin: `i2Dev-com/homefield/routing-guard@v0.4.2`
  → `@v0.5.0` (or a full commit SHA). A v0.4.2 pin keeps passing the
  remote-call form, so the pin is the fix. Workflows that start failing
  with the refusal move the call to a local workflow file that carries the
  routing expression.

## A job written as a flow mapping or an alias

YAML lets a job's mapping be written as a flow mapping (`{...}`), and lets
another job's anchored data be reused as an alias (`*name`) — as a job
body or even as a mapping key. All of these are valid YAML that GitHub
Actions runs, and every release before v0.6.0's line scan read none of
them as a job:

```yaml
jobs:
  evil:
    {
      runs-on: self-hosted,
      steps: [{ run: echo pwned }]
    }
```

The opening `{` set the scan's body depth, so the real `runs-on:` line sat
at a depth the scan treated as data and never checked. A flow mapping
also hid a remote reusable workflow call (`{ uses: evil/repo/...@main }`),
and an alias as a job body or as a key (`*pwn`, `*k : self-hosted`) put
the anchored `runs-on: self-hosted` where the scan saw no key at all. In
every shape the job reached the self-hosted runner with none of the
reviewed expression's restrictions — the `CI_RUNNER` switch, the event
rule, the Dependabot and fork exclusions. Found by the audit, verified
against v0.5.10.

- **Advisory:** [GHSA-3qqr-mvcw-h8w2](https://github.com/i2Dev-com/homefield/security/advisories/GHSA-3qqr-mvcw-h8w2)

- **Affected:** any workflow passing the guard at a pin of v0.5.10 or
  earlier, with a job written as one of the shapes above. A workflow that
  passes v0.6.0's check ran guarded before.
- **Fixed in:** v0.6.0 — inside `jobs:` the scan refuses any line that
  opens a flow mapping or sequence, or starts an alias, an anchor or a
  tag, and refuses any job for which it read neither a job-level
  `runs-on` nor a local `uses:`: a job the check cannot vouch for is the
  shape a bypass hides in. The unreadable-syntax message says how to
  write the plain form.
- **Consumer fix:** bump the pin: `i2Dev-com/homefield/routing-guard@v0.5.10`
  → `@v0.6.0` (or a full commit SHA). A v0.5.10 pin keeps passing the
  flow-mapping and alias forms, so the pin is the fix. Workflows that
  start failing with the unreadable-syntax message are rewritten by
  writing every job as a plain block mapping with an explicit `runs-on`.

## A quoted scalar left open at the end of a line

A double- or single-quoted scalar may continue onto the following lines,
and YAML does not require the continuation to keep the block's
indentation. The scan did not track an open quote, so a continuation line
that looks like a key changed what it believed about the file's
structure, and a `runs-on` below it was never checked:

```yaml
jobs:
  build:
    name: "a
x: b"
    runs-on: self-hosted
```

A continuation line at column 0 is read as a top-level key, which ends
`jobs:` for the scan; at the job-id indent it is read as a new job id,
and a deeper line after it sets the wrong body depth. Either way the
workflow passed the guard while job `build` ran on the self-hosted runner
with none of the four guarantees. Single quotes behave the same. Found
by the audit, verified against v0.5.3.

- **Advisory:** [GHSA-mv22-x2vq-9c3w](https://github.com/i2Dev-com/homefield/security/advisories/GHSA-mv22-x2vq-9c3w)

- **Affected:** any workflow passing the guard at a pin of v0.5.10 or
  earlier, with a quoted scalar that continues onto a following line and
  a `runs-on: self-hosted` below it.
- **Fixed in:** v0.6.0 — the scan tracks an open quoted scalar and fails,
  with the unreadable-syntax message, on one left open at the end of a
  line inside `jobs:`, and (as above) on any job it read neither a
  `runs-on` nor a local `uses:` for.
- **Consumer fix:** bump the pin: `i2Dev-com/homefield/routing-guard@v0.5.10`
  → `@v0.6.0` (or a full commit SHA). Write multi-line text as a block
  scalar (`name: >-`) or on one line.

## A quoted top-level `jobs:` key hides the guard job from `adopt`

`homefield adopt` and the guard read workflow files with two different
parsers, and they disagreed on one spelling: a quoted top-level
`"jobs":` (or `'jobs':`) key. The guard recognized it; `adopt`'s
`parse_jobs()` did not, so a workflow that quoted the key and disabled
the routing-guard job at the job level (`if: false` or
`continue-on-error: true`) was read as having no jobs at all — the
job-level `if:` and `continue-on-error:` checks were skipped and `adopt`
/ `guards` reported `status = ok` while the guard was disabled on every
pull request. Found by the audit, verified against v0.5.10.

- **Advisory:** [GHSA-wwwq-2hhr-f9h4](https://github.com/i2Dev-com/homefield/security/advisories/GHSA-wwwq-2hhr-f9h4)

- **Affected:** any repository accepted by `homefield adopt` at v0.5.10
  or earlier, whose workflows quote the top-level `jobs:` key and
  disable the guard job at the job level.
- **Fixed in:** v0.6.0 — `adopt` reads a quoted `"jobs":` / `'jobs':`
  key the way the guard does, and fails closed when the guard step's job
  cannot be read inside `jobs:`, so a guard disabled at the job level
  under a quoted key is no longer accepted. (`tests/parser-parity.sh`
  pins the two parsers to the same shapes.)
- **Consumer fix:** update `homefield` (`curl -fsSL
  https://raw.githubusercontent.com/i2Dev-com/homefield/v0.6.0/install.sh |
  bash`) and re-run `homefield adopt`; write the top-level `jobs:` key
  unquoted.

## A registration or removal token enters a VM that has run jobs

This one is a `homefield` weakness, not a routing-guard bypass: the
tool's token handling relied on no job running while a token was in the
guest, and held for running jobs but not for what an earlier job left
behind. Jobs run as `runner`, which has passwordless `sudo` and is in
the `docker` group, and the VM was not reset between jobs — so a root
process an earlier job started (a container with `--restart=always`, a
systemd unit, a cron entry) could read the next registration or removal
token from the provisioning process's environment
(`/proc/<pid>/environ`) when a VM that had run jobs was registered
again (`install --replace`, a move with `RUNNER_REREGISTER=1`) or
deregistered (`uninstall`, `reset`). An organization registration token
lets its holder register a runner in that organization for up to an
hour; such a runner can join a runner group, including Default, and be
handed jobs meant for other runners whose labels it copies. Found by
the audit, verified against v0.5.3.

- **Advisory:** [GHSA-7f59-c6rm-hxp8](https://github.com/i2Dev-com/homefield/security/advisories/GHSA-7f59-c6rm-hxp8)

- **Affected:** any VM that has run jobs and was then re-registered or
  deregistered by `homefield` v0.5.10 or earlier, after a job left a
  root process behind.
- **Fixed in:** v0.6.0 — a registration or removal token never enters a
  VM that has run jobs. The state file records whether a runner has
  ever been registered on the VM, and `install` refuses a recorded VM
  even when the guest's `_work` directory is absent (the directory is
  the job's root's to delete, so the guest's answer is not the
  boundary). `uninstall` and `reset` delete the registration through
  the GitHub API from the Mac, so no removal token enters the guest at
  all; deregistration backs the registration files up first and
  restores them on any failure before the irreversible API deletion. A
  move is a fresh registration (`reset`, then `install` at the new
  scope), and an ephemeral re-register runs only on a VM just cloned
  fresh from the base.
- **Consumer fix:** update `homefield` (the one-liner above). A used VM
  is refused with the command to run instead: `bin/homefield reset
  --instance <name>`, then `bin/homefield install` — `reset` deletes
  the VM, so "reset then install" starts from a fresh one.