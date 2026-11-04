# Homefield UX: Colors, Honest Verify, Simple Runs-On

## Problem Statement

How might we make homefield's terminal output and generated workflows as easy to trust at a glance as they are correct under the hood — so a first-time adopter reads green/yellow/red instead of parsing prose, never gets a false-alarm warning from the verify step, and can wire a repo to their runner with one simple `runs-on` line like GitHub's own docs suggest?

## Recommended Direction

Three independent, phased changes (user chose **phased** delivery):

### Phase 1 — Color-coded output (patch)

Color the three surfaces users scan, not every line:

| Level | Color | Symbol | Example |
|---|---|---|---|
| Success/OK | green | ✓ | preflight checks, "routing: ready", "npm: ok" |
| Warning | yellow | ⚠ | `adopt_warn`, preflight WARN, verify hosted-by-design |
| Error/Fatal | red | ✗ | `die`, preflight FAIL, diagnose problems |

- Add a tiny `color` helper at the top of `bin/homefield`: honors `--color=auto|always|never` (auto = default), `NO_COLOR` env, and tty detection; **auto-off when output is piped** so `record`/`has`/`wc -l` test assertions never see ANSI.
- Symbols only in auto/force mode; plain `OK/WARN/FAIL` text prefixes preserved when `--color=never` (backward compatible for log scrapers).
- Surfaces: `preflight`, `diagnose`, `adopt`/`verify`, `setup` summary. Not: routine `log` info lines (keep plain).

### Phase 2 — Honest verify (patch)

The verify step's false alarm: it re-runs the newest `pull_request` run **of any workflow**, which in the user's case was `homefield-routing.yml` — a workflow that is hosted **by design**, so the warning printed was guaranteed noise.

Fix in `adopt_verify()` (`bin/homefield:3799-3865`):
1. Pick the newest `pull_request` run **of a routed workflow** (one whose `runs-on` the guard says routes), not "any workflow".
2. Never re-run the guard workflow itself — exclude it explicitly.
3. If the chosen run's jobs are all in a workflow that stays hosted by design, say that plainly instead of warning ("this workflow's jobs are hosted by design; nothing to verify here").
4. Keep the existing 180s poll + label check; the warning text only fires when a genuinely routable job landed on hosted.

### Phase 3 — Simple `runs-on` mode (**minor** bump, 0.x)

User chose **simple default for fresh installs** + **guard covers it** for safety.

- New installs (and `adopt --setup`) generate a **one-clause expression** — GitHub-docs simple, CI_RUNNER as the only guardrail:

  ```yaml
  runs-on: ${{ vars.CI_RUNNER == 'local' && 'homefield-ci' || 'ubuntu-latest' }}
  ```

  (user refined 2026-11-04: keep the CI_RUNNER switch so `homefield route hosted` remains an instant rollback; drop the pull_request-only, Dependabot, and fork conditions.)

- `adopt --guards` opts into the canonical multi-clause expression for users who want dependabot-hosted / fork-hosted / events filtering.
- The routing guard workflow accepts both shapes: it validates that the `runs-on` resolves to the runner label on PRs (guard "covers it" — user's explicit choice), so a simple-mode repo that accidentally loses routing still fails the guard, not the CI.
- Document in README/adopting.md: simple mode routes **every** event (push, schedule, Dependabot PRs, fork PRs) to the Mac whenever `CI_RUNNER=local`. That is the point — the owner's own code on their own machine — but it assumes everyone who can open a PR is trusted. For org-owned repos or repos with outside collaborators, homefield prints a one-line warning at adopt time and points at `--guards` (public repos are already refused outright). Also document: scheduled/push jobs queued while the Mac sleeps fail after GitHub's 24-hour window; secrets-bearing jobs (deploys) run on the Mac.
- Old repos already on the full expression keep working unchanged (guard grandfathering).

**This is a minor bump** per CONTRIBUTING.md policy — previously-passing workflow shape changes for new installs.

## Key Assumptions to Validate

- [ ] ANSI colors disabled when stdout is not a tty keeps every existing test green (validate: run full suite before/after Phase 1)
- [ ] Guard workflow can distinguish "simple" (one-clause) vs "guards" (canonical) runs-on shapes without a new repo-level flag (validate: extend `routing_guard.py` fixture suite first)
- [ ] Simple-mode deploy job (secrets-bearing) behaves identically on the Mac as on hosted for a personal repo (validate: throwaway-VM run on the codesamplez repo)
- [ ] Verify-step fix works when a repo has zero routed PR runs yet (validate: dry-run on codesamplez before the PR-#309-style merge)

## MVP Scope

- Phase 1: `color` helper + green/yellow/red on preflight, diagnose, adopt/verify/setup summary lines only.
- Phase 2: verify picks a routed workflow's run, never the guard workflow; hosted-by-design message instead of warning.
- Phase 3: `runs-on: homefield-ci` default on fresh installs; `--guards` opt-in; guard accepts both; docs updated.

## Not Doing (and Why)

- **Coloring every `log` line** — noise; the value is scannability of status changes, not decoration.
- **Changing `pull_request` event defaults or Dependabot/fork rules** — those guard against real cost/secrets risks; opt-in via `--events`/`--dependabot` flags already exists, and the user's "extra conditionals in docs" ask is satisfied by keeping them as flags, not defaults.
- **Removing the guard workflow in simple mode** — user explicitly chose guard-covers-it; the guard is the only automated check that simple mode didn't silently lose routing.
- **Retroactively rewriting old repos' workflows** — grandfathering keeps existing adopters stable; they can re-run `adopt --setup` if they want simple mode.
- **Progress spinners/structured `--json` everywhere** — scope creep; `diagnose --json` already exists for machine reads.

## Open Questions

- Should `--simple` be a flag or a `homefield.conf` setting? (Flag is simpler; config only if users ask.)
- Should adopt refuse simple mode (not just warn) for org-owned repos with forking enabled, or is the warning + `--guards` pointer enough?