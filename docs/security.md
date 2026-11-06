# The routing guard: contract and past bypasses

The routing guard (`routing-guard/routing_guard.py`, run as
[`i2Dev-com/homefield/routing-guard`](routing-guard/action.yml)) fails CI
unless every job that can reach the local runner uses the one reviewed
`runs-on` expression. The expression carries four guarantees: jobs run on the
self-hosted runner only when `vars.CI_RUNNER == 'local'`, the event is a
pull request, Dependabot's actor and branches are excluded, fork pull
requests run hosted, and anything else falls back to a GitHub-hosted image.
The full procedure, including how to write and pin the guard, is
[adopting.md](adopting.md) steps 2-3.

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

## A `runs-on` key written in other valid YAML

`"runs-on": self-hosted` (quoted), a job written as a `{...}` mapping, a
`<<` merge key, a `? runs-on` complex key, or a key split over two lines —
each has the key `runs-on`, and every release before v0.2.1 read only a
plain `runs-on:` under a plain `job-id:` line. The job was treated as having
no `runs-on`, which the guard did not check, and it reached the self-hosted
runner with none of the four guarantees.

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
with none of the four guarantees — the caller passed the guard, and the
routing happened in a file the guard never saw. A step-level `uses:`
(`actions/checkout@v4`) is not a call and is not affected.

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