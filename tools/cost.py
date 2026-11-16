#!/usr/bin/env python3
"""Project monthly GitHub-hosted CI costs and savings with homefield.

Reads workflow runs and jobs via GitHub CLI (`gh`) using the same API queries
and fixture format as `tools/report.py`, classifies completed jobs into:

  - local        jobs already routed to the homefield runner label
  - routable     hosted Linux jobs eligible for homefield under the selected
                 routing policy (`--mode` / `--dependabot`)
  - other_hosted hosted jobs that remain hosted (non-routable events or
                 guarded PRs under `--mode guards`, plus macOS / Windows jobs
                 on any event)

Durations are rounded up to a whole minute per job (`math.ceil(seconds / 60)`),
then projected linearly from the sample window to a 30-day month. Monthly plan
included minutes (2,000 Free; 3,000 Pro/Team; 50,000 Enterprise) are consumed
using GitHub's OS multipliers (1x Linux, 2x Windows, 10x macOS) under uniform
arrival across the month, and overages are billed at published standard rates.

HOMEFIELD_COST_FIXTURE=<file.json> reads {"owner/repo": [run, ...]} instead of
calling GitHub; tests/cost.sh uses it. HOMEFIELD_COST_TODAY=<YYYY-MM-DD> pins
"today" for the default 30-day window.
"""

import argparse
import datetime as dt
import importlib.util
import json
import math
import os
import re
import sys


def _load_report():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "report.py")
    spec = importlib.util.spec_from_file_location("report", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


report = _load_report()

DAYS_PER_MONTH = 30

PLANS = {
    "free": 2000,
    "pro": 3000,
    "team": 3000,
    "enterprise": 50000,
}

# Published GitHub-hosted 2-core (3/4-core for macOS) standard rates in USD
# per raw billed minute and plan minute multipliers.
RATES = {
    "linux-x64": (1, 0.006),
    "linux-arm64": (1, 0.005),
    "windows": (2, 0.010),
    "macos": (10, 0.062),
}

BUCKET_NAMES = ("local", "routable", "other_hosted")


def die(message):
    print(f"homefield cost: {message}", file=sys.stderr)
    sys.exit(1)


def os_profile(labels):
    """Return (os_key, multiplier, rate_per_min) from a job's requested labels."""
    items = [str(item).lower() for item in (labels or [])]
    if any(item == "macos" or item.startswith("macos-") for item in items):
        mult, rate = RATES["macos"]
        return "macos", mult, rate
    if any(item == "windows" or item.startswith("windows-") for item in items):
        mult, rate = RATES["windows"]
        return "windows", mult, rate
    if any(
        item in ("arm64", "arm")
        or item.startswith(("arm64-", "arm-"))
        or item.endswith(("-arm64", "-arm"))
        for item in items
    ):
        mult, rate = RATES["linux-arm64"]
        return "linux-arm64", mult, rate
    mult, rate = RATES["linux-x64"]
    return "linux-x64", mult, rate


def empty_os_map():
    return {os_key: 0 for os_key in RATES}


def empty_bucket():
    return {
        "jobs": 0,
        "raw_minutes": 0,
        "billed_minutes": 0,
        "gross_usd": 0.0,
        "by_os": empty_os_map(),
    }


def is_routable_run(run, repo, mode, dependabot):
    """True when a run's hosted Linux jobs can route to homefield under (mode, dependabot)."""
    if mode == "simple":
        return True
    if (run.get("event") or "") != "pull_request":
        return False
    if dependabot == "hosted":
        actor = (run.get("actor") or "").lower()
        branch = run.get("branch") or ""
        if actor == "dependabot[bot]" or branch.startswith("dependabot/"):
            return False
    if "head_repo" in run:
        head_repo = run["head_repo"]
        if not head_repo or head_repo.lower() != repo.lower():
            return False
    return True


def collect_repo(repo, runs, label, mode="guards", dependabot="hosted"):
    """Aggregate observed job counts, raw minutes, billed minutes, and gross
    USD per bucket (`local`, `routable`, `other_hosted`) for one repository."""
    buckets = {name: empty_bucket() for name in BUCKET_NAMES}
    by_os = {
        os_key: {"raw_minutes": 0, "billed_minutes": 0, "gross_usd": 0.0}
        for os_key in RATES
    }
    pr_branches = set()
    unstarted = 0
    pending = 0

    for run in runs:
        event = run.get("event") or ""
        if event == "pull_request" and run.get("branch"):
            pr_branches.add(run["branch"])
        run_routable = is_routable_run(run, repo, mode, dependabot)
        for job in run.get("jobs") or []:
            where = report.classify(job, label)
            if where in ("skipped", "other"):
                continue
            if job.get("status") != "completed":
                pending += 1
                continue
            started = report.parse_time(job.get("started_at"))
            completed = report.parse_time(job.get("completed_at"))
            if started is None or completed is None:
                unstarted += 1
                continue

            seconds = max(0, int((completed - started).total_seconds()))
            raw_min = math.ceil(seconds / 60)

            if where == "local":
                # Local homefield runs replace standard hosted Linux jobs
                # (ubuntu-latest / x64 default fallback).
                os_key, mult, rate = "linux-x64", *RATES["linux-x64"]
                bucket_name = "local"
            else:
                os_key, mult, rate = os_profile(job.get("labels") or [])
                if run_routable and os_key in ("linux-x64", "linux-arm64"):
                    bucket_name = "routable"
                else:
                    bucket_name = "other_hosted"

            billed_min = raw_min * mult
            gross = raw_min * rate

            bucket = buckets[bucket_name]
            bucket["jobs"] += 1
            bucket["raw_minutes"] += raw_min
            bucket["billed_minutes"] += billed_min
            bucket["gross_usd"] += gross
            bucket["by_os"][os_key] += raw_min

            os_row = by_os[os_key]
            os_row["raw_minutes"] += raw_min
            os_row["billed_minutes"] += billed_min
            os_row["gross_usd"] += gross

    return {
        "pull_requests": len(pr_branches),
        "buckets": buckets,
        "by_os": by_os,
        "unstarted": unstarted,
        "pending": pending,
    }


def bill_scenario(os_raw_minutes, scale, included_minutes):
    """Project monthly minutes and net hosted bill (after included allowance)
    under uniform arrival across OS multipliers."""
    raw = sum(os_raw_minutes.values()) * scale
    billed = sum(minutes * scale * RATES[os_key][0] for os_key, minutes in os_raw_minutes.items())
    gross = sum(minutes * scale * RATES[os_key][1] for os_key, minutes in os_raw_minutes.items())

    if billed <= 0 or billed <= included_minutes:
        overage = 0.0
        net = 0.0
    else:
        overage = billed - included_minutes
        net = gross * (overage / billed)

    return {
        "raw_minutes": raw,
        "billed_minutes": billed,
        "gross_usd": gross,
        "overage_minutes": overage,
        "net_usd": net,
    }


def combine_os_maps(*buckets):
    combined = empty_os_map()
    for bucket in buckets:
        for os_key, value in bucket["by_os"].items():
            combined[os_key] += value
    return combined


def project_costs(runs_by_repo, label, window_days, included_minutes, mode="guards", dependabot="hosted"):
    scale = DAYS_PER_MONTH / window_days
    repo_entries = []
    totals = {name: empty_bucket() for name in BUCKET_NAMES}

    for repo, runs in runs_by_repo.items():
        collected = collect_repo(repo, runs, label, mode=mode, dependabot=dependabot)
        repo_entries.append({"repo": repo, **collected})
        for name in BUCKET_NAMES:
            src = collected["buckets"][name]
            dst = totals[name]
            dst["jobs"] += src["jobs"]
            dst["raw_minutes"] += src["raw_minutes"]
            dst["billed_minutes"] += src["billed_minutes"]
            dst["gross_usd"] += src["gross_usd"]
            for os_key in RATES:
                dst["by_os"][os_key] += src["by_os"][os_key]

    scenarios_raw = {
        "all_hosted": bill_scenario(
            combine_os_maps(totals["local"], totals["routable"], totals["other_hosted"]),
            scale,
            included_minutes,
        ),
        "current": bill_scenario(
            combine_os_maps(totals["routable"], totals["other_hosted"]),
            scale,
            included_minutes,
        ),
        "with_homefield": bill_scenario(
            combine_os_maps(totals["other_hosted"]),
            scale,
            included_minutes,
        ),
    }

    all_net = scenarios_raw["all_hosted"]["net_usd"]
    cur_net = scenarios_raw["current"]["net_usd"]
    hf_net = scenarios_raw["with_homefield"]["net_usd"]

    savings = {
        "already_saved_monthly_usd": round(all_net - cur_net, 2),
        "already_saved_annual_usd": round((all_net - cur_net) * 12, 2),
        "additional_monthly_usd": round(cur_net - hf_net, 2),
        "total_monthly_usd": round(all_net - hf_net, 2),
        "total_annual_usd": round((all_net - hf_net) * 12, 2),
    }

    projected_buckets = {
        name: {
            "raw_minutes": round(totals[name]["raw_minutes"] * scale, 1),
            "billed_minutes": round(totals[name]["billed_minutes"] * scale, 1),
            "gross_usd": round(totals[name]["gross_usd"] * scale, 2),
        }
        for name in BUCKET_NAMES
    }

    scenarios = {
        name: {
            "raw_minutes": round(vals["raw_minutes"], 1),
            "billed_minutes": round(vals["billed_minutes"], 1),
            "gross_usd": round(vals["gross_usd"], 2),
            "overage_minutes": round(vals["overage_minutes"], 1),
            "net_usd": round(vals["net_usd"], 2),
        }
        for name, vals in scenarios_raw.items()
    }

    return {
        "scale": scale,
        "repos": repo_entries,
        "monthly_projection": {
            "buckets": projected_buckets,
            "scenarios": scenarios,
            "savings": savings,
        },
    }


def round_repo_entry(entry):
    return {
        "repo": entry["repo"],
        "pull_requests": entry["pull_requests"],
        "buckets": {
            name: {
                "jobs": vals["jobs"],
                "raw_minutes": vals["raw_minutes"],
                "billed_minutes": vals["billed_minutes"],
                "gross_usd": round(vals["gross_usd"], 2),
            }
            for name, vals in entry["buckets"].items()
        },
        "by_os": {
            os_key: {
                "raw_minutes": vals["raw_minutes"],
                "billed_minutes": vals["billed_minutes"],
                "gross_usd": round(vals["gross_usd"], 2),
            }
            for os_key, vals in entry["by_os"].items()
        },
        "unstarted": entry["unstarted"],
        "pending": entry["pending"],
    }


def fmt_min(value):
    rounded = round(value, 1)
    if abs(rounded - round(rounded)) < 0.05:
        return f"{round(rounded):,}"
    return f"{rounded:,.1f}"


def fmt_usd(value):
    return f"${value:,.2f}"


def render(payload):
    proj = payload["monthly_projection"]
    scenarios = proj["scenarios"]
    savings = proj["savings"]
    scale = payload["scale_factor"]

    lines = [
        (
            f"Cost projection from {payload['since']} to {payload['until']}"
            f" ({payload['window_days']}d -> {payload['projection_days']}d/mo, scale {scale:.2f}x),"
            f" plan {payload['plan']} ({payload['included_minutes']:,} included min/mo),"
            f" mode {payload['mode']}, dependabot {payload['dependabot']}, label {payload['label']}"
        ),
        "",
        "Observed window per repository (raw min and gross USD at hosted rates)",
        "",
        (
            f"{'repo':<24} {'PRs':>4} {'local min':>10} {'routable min':>12}"
            f" {'other min':>10} {'local eq':>10} {'routable':>10} {'other':>10}"
        ),
    ]

    unstarted = 0
    pending = 0
    for item in payload["repos"]:
        b = item["buckets"]
        unstarted += item["unstarted"]
        pending += item["pending"]
        lines.append(
            f"{item['repo'][:24]:<24} {item['pull_requests']:>4}"
            f" {b['local']['raw_minutes']:>10,}"
            f" {b['routable']['raw_minutes']:>12,}"
            f" {b['other_hosted']['raw_minutes']:>10,}"
            f" {fmt_usd(b['local']['gross_usd']):>10}"
            f" {fmt_usd(b['routable']['gross_usd']):>10}"
            f" {fmt_usd(b['other_hosted']['gross_usd']):>10}"
        )

    lines += [
        "",
        f"Monthly scenarios (shared {payload['included_minutes']:,} included min pool)",
        "",
    ]

    labels = [
        ("all_hosted", "all hosted"),
        ("current", "current"),
        ("with_homefield", "with homefield"),
    ]
    for key, title in labels:
        sc = scenarios[key]
        lines.append(
            f"  {title:<15}: {fmt_min(sc['raw_minutes']):>7} raw min,"
            f" {fmt_min(sc['billed_minutes']):>8} billed min"
            f" ({fmt_min(sc['overage_minutes']):>7} overage)"
            f" -> {fmt_usd(sc['net_usd']):>8}/mo"
            f"  (gross {fmt_usd(sc['gross_usd']):>8}/mo)"
        )

    lines += [
        "",
        "Projected savings vs all hosted",
        "",
        (
            f"  already saved  : {fmt_usd(savings['already_saved_monthly_usd']):>8}/mo"
            f"  ({fmt_usd(savings['already_saved_annual_usd']):>9}/yr)"
        ),
        (
            f"  additional     : {fmt_usd(savings['additional_monthly_usd']):>8}/mo"
            f"  ({fmt_usd(round(savings['additional_monthly_usd'] * 12, 2)):>9}/yr)"
        ),
        (
            f"  total potential: {fmt_usd(savings['total_monthly_usd']):>8}/mo"
            f"  ({fmt_usd(savings['total_annual_usd']):>9}/yr)"
        ),
        "",
        (
            "Rates: Linux x64 $0.006/min (1x), Linux arm64 $0.005/min (1x),"
            " Windows $0.010/min (2x), macOS $0.062/min (10x); job durations round up."
        ),
        (
            "Local jobs are priced at Linux x64 ($0.006/min); "
            + (
                "all Linux jobs treated as routable (--mode simple)."
                if payload["mode"] == "simple"
                else (
                    "fork pull_request jobs stay hosted under --mode guards;"
                    " Dependabot PRs treated as routable (--dependabot local)."
                    if payload["dependabot"] == "local"
                    else "forks and Dependabot pull_request jobs stay hosted (--mode guards --dependabot hosted)."
                )
            )
        ),
    ]
    if unstarted or pending:
        lines.append(
            f"Excluded incomplete jobs: {unstarted} cancelled before starting,"
            f" {pending} queued or running now."
        )
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="homefield cost", description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", action="append", default=[], required=True)
    parser.add_argument("--since")
    parser.add_argument("--until")
    parser.add_argument("--label", default="homefield-ci")
    parser.add_argument("--plan", choices=tuple(PLANS), default="free")
    parser.add_argument("--included", type=int, help="override monthly included minutes for the account")
    parser.add_argument("--mode", choices=("guards", "simple"), default="guards")
    parser.add_argument("--dependabot", choices=("hosted", "local"), default="hosted")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    today = dt.datetime.now(dt.timezone.utc).date()
    pinned = os.environ.get("HOMEFIELD_COST_TODAY")
    if pinned:
        today = report.parse_date(pinned, die=die)

    last = report.parse_date(args.until, die=die) if args.until else today
    first = (
        report.parse_date(args.since, die=die)
        if args.since
        else last - dt.timedelta(days=DAYS_PER_MONTH - 1)
    )
    if first > last:
        die(f"--since {first} is after --until {last}")

    label = args.label.lower()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", label):
        die("--label must be one label")
    for repo in args.repo:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            die(f"--repo must be <owner>/<repo>, got: {repo}")

    included = PLANS[args.plan] if args.included is None else args.included
    if included < 0:
        die(f"--included must be non-negative, got: {included}")

    window_days = (last - first).days + 1
    fixture = os.environ.get("HOMEFIELD_COST_FIXTURE", "")
    runs_by_repo = {
        repo: report.fetch_repo(repo, first, last, fixture=fixture, die=die)
        for repo in args.repo
    }

    projected = project_costs(
        runs_by_repo,
        label,
        window_days,
        included,
        mode=args.mode,
        dependabot=args.dependabot,
    )
    payload = {
        "since": str(first),
        "until": str(last),
        "window_days": window_days,
        "projection_days": DAYS_PER_MONTH,
        "scale_factor": round(projected["scale"], 4),
        "label": label,
        "plan": args.plan,
        "included_minutes": included,
        "mode": args.mode,
        "dependabot": args.dependabot,
        "repos": [round_repo_entry(entry) for entry in projected["repos"]],
        "monthly_projection": projected["monthly_projection"],
    }

    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        print(render(payload))


if __name__ == "__main__":
    main()
