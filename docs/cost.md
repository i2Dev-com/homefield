# Cost math and calculator

`homefield` saves hosted CI spend when a repository's jobs run over its plan's
included monthly minutes — especially when frequent `pull_request` jobs burn
through pool minutes that would otherwise cover `10x` macOS or `2x` Windows
builds. It does not save money for a repository that stays within its included
allowance.

## GitHub-hosted runner rates and included minutes

Standard GitHub-hosted runners on private repositories bill every started job
rounded up to a whole minute (`ceil(seconds / 60)`). Usage draws down the
account's monthly included-minute pool scaled by the OS multiplier, then bills
overage per raw minute at the published rate:

| Runner | Pool multiplier | Overage rate | Cost per pool minute | Runs locally with homefield? |
|---|---|---|---|---|
| Linux 1-core slim (`ubuntu-slim`) | 1x | `$0.002` / min | `$0.0020` | Yes (`homefield-ci`) |
| Linux 2-core x64 (`ubuntu-latest`) | 1x | `$0.006` / min | `$0.0060` | Yes (`homefield-ci`) |
| Linux 2-core arm64 (`ubuntu-*-arm`) | 1x | `$0.005` / min | `$0.0050` | Yes (`homefield-ci`) |
| Windows 2-core (`windows-latest`) | 2x | `$0.010` / min | `$0.0050` | No (stays hosted) |
| macOS standard (`macos-latest`) | 10x | `$0.062` / min | `$0.0062` | No (stays hosted) |
| Self-hosted (`homefield`) | — | `$0.000` / min | — | Runs in local Lima VM |

GitHub's included monthly pool per account (private repositories):

| Plan | Included pool min / month | Equivalent Linux min | Equivalent Windows min | Equivalent macOS min |
|---|---|---|---|---|
| `free` | 2,000 | 2,000 | 1,000 | 200 |
| `pro` | 3,000 | 3,000 | 1,500 | 300 |
| `team` | 3,000 | 3,000 | 1,500 | 300 |
| `enterprise` | 50,000 | 50,000 | 25,000 | 5,000 |

Public repositories run hosted jobs free. Check
[GitHub's Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
for current rates and self-hosted runner terms (GitHub postponed its private
self-hosted platform fee indefinitely).

## Why macOS builds matter even when PR jobs run Linux

`homefield` runs a Linux arm64 VM; it cannot run `macos-*` or `windows-*` jobs.
However, all standard hosted runners on an account share **one** monthly
included-minute pool:

- Each minute of `ubuntu-latest` pull-request checks consumes `1` pool minute.
- Each minute of `macos-latest` release or main-branch builds consumes `10`
  pool minutes, and bills **`$0.062` / min** once the pool runs out.

Moving routable Linux `pull_request` jobs to `homefield` frees up pool minutes
for pushes, releases, Dependabot PRs, Windows jobs, and `10x` macOS builds.
Reclaiming `2,000` Linux PR minutes frees the full Free-tier allowance — enough
to absorb `200` raw macOS build minutes (`$12.40/mo`) before overage starts.

## Break-even formula

Let `included` be the account's monthly pool (`2,000` on Free, `3,000` on
Pro/Team). For a month's completed jobs:

```text
raw_minutes(job)    = ceil(seconds / 60)
billed_minutes      = sum(raw_minutes(job) * multiplier(OS))
gross_usd           = sum(raw_minutes(job) * rate(OS))
```

- **Break-even:** savings begin once `billed_minutes > included`. If total
  monthly billed minutes fit inside `included`, hosted cost is `$0.00` either
  way.
- **Net monthly hosted bill** (assuming uniform job arrival across the month):

```text
net_usd = gross_usd * max(0, billed_minutes - included) / billed_minutes
```

- **Monthly savings:** `net_usd(all_hosted) - net_usd(non_routable_hosted)`, in
  exchange for keeping the Mac awake with the VM's RAM reserved (5 GiB default).

## Worked example

Consider a private app repository running `150` pull requests per month plus
main-branch macOS release/verification builds:

1. **Pull-request Linux checks (routable):** `150` PRs × `3` pushes/PR × `4`
   short Linux x64 jobs (`35s`, `40s`, `50s`, `70s`). Rounded up per job:
   `1 + 1 + 1 + 2 = 5 min` per push -> `15 min/PR` -> `2,250` Linux x64
   minutes/month (`$13.50` gross, `2,250` pool minutes).
2. **macOS builds on main/release (stays hosted):** `200` raw minutes/month
   (`$12.40` gross at `$0.062/min`, `200 × 10 = 2,000` pool minutes).

Comparison:

| Metric | All hosted | With `homefield` on PRs |
|---|---|---|
| Hosted billed pool min | `4,250` | `2,000` (macOS only) |
| Gross hosted cost | `$25.90` / mo | `$12.40` / mo |
| Net bill on **Free** (`2,000` included) | **`$13.71` / mo** | **`$0.00` / mo** |
| Annual net bill (**Free**) | `$164.54` / yr | `$0.00` / yr |
| Net bill on **Pro/Team** (`3,000` included) | **`$7.62` / mo** | **`$0.00` / mo** |
| Annual net bill (**Pro/Team**) | `$91.41` / yr | `$0.00` / yr |

Even though `homefield` only offloads Linux PR jobs, freeing `2,250` Linux pool
minutes brings the `2,000`-minute macOS bill completely back inside the free tier
and saves **`$13.71/mo`** (`$164.54/yr`) on Free or **`$7.62/mo`** (`$91.41/yr`)
on Pro/Team.

## Using `tools/cost.py`

`tools/cost.py` reads your repository's recent workflow runs via `gh` (using the
same API pagination and fixture shape as `tools/report.py`), scales the window
to a 30-day month, and compares three scenarios (`all hosted`, `current`, and
`with homefield`):

```bash
# Last 30 days on the Free plan (2,000 included minutes)
python3 tools/cost.py --repo owner/repo

# Team plan across two repositories sharing one account pool
python3 tools/cost.py --repo owner/api --repo owner/app --plan team

# Explicit window (scales linearly to 30 days) and zero remaining free pool
python3 tools/cost.py --repo owner/app --since 2026-11-01 --until 2026-11-15 --included 0

# Machine-readable JSON output
python3 tools/cost.py --repo owner/app --json

# Match --dependabot local or --mode simple routing (include Dependabot / fork PRs)
python3 tools/cost.py --repo owner/app --dependabot local
python3 tools/cost.py --repo owner/app --mode simple
```

By default (`--mode guards --dependabot hosted`), hosted Dependabot
(`dependabot[bot]` or `dependabot/...` branches), fork pull requests, and
non-PR events stay in `other_hosted` so savings reflect what guarded routing
actually moves locally. Pass `--dependabot local` to include Dependabot PRs,
or `--mode simple` to project savings across all Linux events (pushes, releases,
Dependabot, and forks; macOS and Windows jobs remain hosted in every mode).

Environment overrides (primarily for tests and offline evaluation):

- `HOMEFIELD_COST_FIXTURE=<file.json>`: read `{"owner/repo": [run, ...]}`
  instead of calling `gh`.
- `HOMEFIELD_COST_TODAY=<YYYY-MM-DD>`: pin "today" for the default 30-day window.
