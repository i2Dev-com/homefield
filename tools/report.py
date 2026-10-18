#!/usr/bin/env python3
"""Queue wait, duration and minutes of the jobs in some repositories, local
runner against GitHub-hosted. Run it through `bin/homefield report`.

Everything comes from the GitHub API (via `gh`), one day of runs at a time:
the runs endpoint returns at most 1,000 results for a filtered query, which a
busy repository can pass in a month. Jobs are fetched with filter=all, so a
re-run's earlier attempts count too.

A job is *local* if the routing label is among the labels it asked for, and
*hosted* if a GitHub-hosted runner picked it up. Skipped jobs are not counted.
Jobs that finished without starting (cancelled while queued) and jobs queued
or running at the time of the report are reported separately, not as runs:
the first are what a stopped VM leaves behind. Matrix jobs keep their full
names, so each combination is its own row.

Minutes are each job's duration rounded up to a whole minute, times GitHub's
multiplier for the OS (Linux 1, Windows 2, macOS 10). For hosted jobs that is
the billed figure (a rough one: larger runners have their own rates). For
local jobs it is what they would have cost.

HOMEFIELD_REPORT_FIXTURE=<file.json> reads {"owner/repo": [run, ...]} instead
of calling GitHub; tests/report.sh uses it.
"""

import argparse
import datetime as dt
import json
import math
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
SLOW_QUEUE_SECONDS = 5 * 60

RUN_FIELDS = (
    "{id, path, event, created_at, branch: .head_branch}"
)
JOB_FIELDS = (
    "{id, name, status, conclusion, created_at, started_at, completed_at,"
    " runner_name, labels}"
)


def die(message):
    print(f"homefield report: {message}", file=sys.stderr)
    sys.exit(1)


def gh_lines(path, jq):
    """JSON objects, one per line of `gh api --paginate PATH --jq JQ`."""
    result = subprocess.run(
        ["gh", "api", "--paginate", path, "--jq", jq],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        # A failed lookup must not read as "no jobs".
        die(f"gh api {path} failed: {result.stderr.strip()}")
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]


def days(first, last):
    day = first
    while day <= last:
        yield day
        day += dt.timedelta(days=1)


def fetch_repo(repo, first, last):
    """Runs of the repository created from `first` to `last` (dates,
    inclusive), each with its jobs under "jobs"."""
    fixture = os.environ.get("HOMEFIELD_REPORT_FIXTURE")
    if fixture:
        with open(fixture, encoding="utf-8") as handle:
            data = json.load(handle)
        if repo not in data:
            die(f"the fixture {fixture} has no entry for {repo}")
        return data[repo]

    def runs_of(day):
        span = f"{day}T00:00:00Z..{day}T23:59:59Z"
        return gh_lines(
            f"repos/{repo}/actions/runs?per_page=100&created={span}",
            f".workflow_runs[] | {RUN_FIELDS}",
        )

    def with_jobs(run):
        run["jobs"] = gh_lines(
            f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100&filter=all",
            f".jobs[] | {JOB_FIELDS}",
        )
        return run

    with ThreadPoolExecutor(max_workers=8) as pool:
        runs = [run for batch in pool.map(runs_of, list(days(first, last))) for run in batch]
        print(f"{repo}: {len(runs)} runs, fetching jobs...", file=sys.stderr)
        return list(pool.map(with_jobs, runs))


def parse_time(value):
    return dt.datetime.strptime(value, TIME_FORMAT) if value else None


def percentile(sorted_values, fraction):
    """Nearest-rank percentile of an ascending list."""
    if not sorted_values:
        return None
    rank = max(1, math.ceil(fraction * len(sorted_values)))
    return sorted_values[rank - 1]


def multiplier(labels):
    joined = " ".join(labels)
    if "macos" in joined:
        return 10
    if "windows" in joined:
        return 2
    return 1


def classify(job, label):
    """"local", "hosted", "skipped" (not counted) or "other"."""
    labels = [item.lower() for item in job.get("labels") or []]
    runner = job.get("runner_name") or ""
    # A skipped job keeps the labels it asked for, so this comes first.
    if job.get("conclusion") == "skipped":
        return "skipped"
    if label in labels:
        return "local"
    if not runner:
        # Not skipped, yet no runner: queued now, or cancelled before one was
        # assigned. Hosted unless it asked for a self-hosted runner that is not
        # ours. Any other conclusion without a runner never ran: not counted.
        if job.get("status") == "completed" and job.get("conclusion") != "cancelled":
            return "skipped"
        return "other" if "self-hosted" in labels else "hosted"
    if runner.startswith(("GitHub Actions", "GitHub-hosted", "Hosted Compute Agent")):
        return "hosted"
    return "other"


def aggregate(runs_by_repo, label):
    """Rows keyed by (repo, workflow, job, where), and per-repo PR counts."""
    rows = {}
    prs = {}
    for repo, runs in runs_by_repo.items():
        seen = set()
        for run in runs:
            # The runs API leaves pull_requests empty for most runs, so a PR is
            # counted as a head branch that had a pull_request run.
            if run.get("event") == "pull_request" and run.get("branch"):
                seen.add(run["branch"])
            workflow = os.path.basename(run.get("path") or "") or "?"
            for job in run.get("jobs") or []:
                where = classify(job, label)
                if where in ("skipped", "other"):
                    continue
                key = (repo, workflow, job["name"], where)
                row = rows.setdefault(
                    key,
                    {"jobs": 0, "unstarted": 0, "pending": 0, "waits": [], "seconds": 0,
                     "minutes": 0, "failed": 0, "cancelled": 0},
                )
                if job.get("status") != "completed":
                    # Queued or running now: not a result yet.
                    row["pending"] += 1
                    continue
                started = parse_time(job.get("started_at"))
                completed = parse_time(job.get("completed_at"))
                if started is None or completed is None:
                    # Finished without ever starting: cancelled while queued.
                    row["unstarted"] += 1
                    continue
                queued = parse_time(job["created_at"])
                seconds = max(0, int((completed - started).total_seconds()))
                row["jobs"] += 1
                row["waits"].append(max(0, int((started - queued).total_seconds())))
                row["seconds"] += seconds
                row["minutes"] += math.ceil(seconds / 60) * multiplier(job.get("labels") or [])
                if job.get("conclusion") == "cancelled":
                    row["cancelled"] += 1
                elif job.get("conclusion") not in ("success", "neutral"):
                    row["failed"] += 1
        prs[repo] = len(seen)
    for row in rows.values():
        row["waits"].sort()
    return rows, prs


def duration(seconds):
    if seconds is None:
        return "-"
    minutes, rest = divmod(int(seconds), 60)
    return f"{minutes}m{rest:02d}s" if minutes else f"{rest}s"


def summarise(row):
    waits = row["waits"]
    return {
        "jobs": row["jobs"],
        "unstarted": row["unstarted"],
        "pending": row["pending"],
        "wait_p50": percentile(waits, 0.5),
        "wait_p95": percentile(waits, 0.95),
        "wait_max": waits[-1] if waits else None,
        "wait_over_5m": sum(1 for wait in waits if wait > SLOW_QUEUE_SECONDS),
        "avg_seconds": row["seconds"] / row["jobs"] if row["jobs"] else None,
        "minutes": row["minutes"],
        "failed": row["failed"],
        "cancelled": row["cancelled"],
    }


def as_data(rows, prs):
    """Rows plus a per-repo, per-where total, as plain data."""
    out = {"jobs": [], "totals": []}
    totals = {}
    for (repo, workflow, job, where), row in sorted(rows.items()):
        out["jobs"].append({"repo": repo, "workflow": workflow, "job": job,
                            "where": where, **summarise(row)})
        total = totals.setdefault((repo, where), {"jobs": 0, "minutes": 0, "waits": [],
                                                  "unstarted": 0, "pending": 0, "failed": 0, "cancelled": 0})
        total["jobs"] += row["jobs"]
        total["minutes"] += row["minutes"]
        total["waits"].extend(row["waits"])
        total["unstarted"] += row["unstarted"]
        total["pending"] += row["pending"]
        total["failed"] += row["failed"]
        total["cancelled"] += row["cancelled"]
    for (repo, where), total in sorted(totals.items()):
        waits = sorted(total["waits"])
        count = prs.get(repo, 0)
        out["totals"].append({
            "repo": repo, "where": where, "jobs": total["jobs"],
            "minutes": total["minutes"], "unstarted": total["unstarted"],
            "pending": total["pending"],
            "failed": total["failed"], "cancelled": total["cancelled"],
            "pull_requests": count,
            "minutes_per_pr": round(total["minutes"] / count, 1) if count else None,
            "wait_p50": percentile(waits, 0.5), "wait_p95": percentile(waits, 0.95),
            "wait_max": waits[-1] if waits else None,
            "wait_over_5m": sum(1 for wait in waits if wait > SLOW_QUEUE_SECONDS),
        })
    return out


def render(data, first, last, label):
    lines = [
        f"Jobs from {first} to {last} (UTC), label {label}",
        "",
        f"{'repo':<8} {'workflow / job':<50} {'where':<6} {'jobs':>5} {'wait p50':>9} "
        f"{'p95':>8} {'max':>8} {'>5m':>4} {'avg run':>8} {'minutes':>8} {'failed':>6} {'cancel':>6}",
    ]
    for item in data["jobs"]:
        name = f"{item['workflow']} / {item['job']}"
        lines.append(
            f"{item['repo'].split('/')[-1]:<8} {name[:50]:<50} {item['where']:<6} "
            f"{item['jobs']:>5} {duration(item['wait_p50']):>9} "
            f"{duration(item['wait_p95']):>8} {duration(item['wait_max']):>8} "
            f"{item['wait_over_5m']:>4} {duration(item['avg_seconds']):>8} "
            f"{item['minutes']:>8} {item['failed']:>6} {item['cancelled']:>6}"
        )
    lines += ["", "Totals", ""]
    for item in data["totals"]:
        per_pr = "" if item["minutes_per_pr"] is None else f", {item['minutes_per_pr']} min per PR"
        never = f", {item['unstarted']} cancelled before starting" if item["unstarted"] else ""
        never += f", {item['pending']} queued or running now" if item["pending"] else ""
        lines.append(
            f"  {item['repo']} {item['where']}: {item['jobs']} jobs, {item['minutes']} min"
            f"{per_pr}, queue p50 {duration(item['wait_p50'])} / p95 {duration(item['wait_p95'])}"
            f" / max {duration(item['wait_max'])}, {item['wait_over_5m']} over 5 min,"
            f" {item['failed']} failed, {item['cancelled']} cancelled{never}"
        )
    prs = {(item["repo"], item["pull_requests"]) for item in data["totals"]}
    lines += [
        "",
        "PRs per repository: "
        + ", ".join(f"{repo} {count}" for repo, count in sorted(prs))
        + " (distinct head branches with a pull_request run in the window).",
        "Minutes are job durations rounded up per job; for local jobs, what they would have billed.",
    ]
    return "\n".join(lines)


def parse_date(value):
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        die(f"not a date (YYYY-MM-DD): {value}")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="homefield report", description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", action="append", default=[], required=True)
    parser.add_argument("--since")
    parser.add_argument("--until")
    parser.add_argument("--label", default="homefield-ci")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    today = dt.datetime.now(dt.timezone.utc).date()
    first = parse_date(args.since) if args.since else today.replace(day=1)
    last = parse_date(args.until) if args.until else today
    if first > last:
        die(f"--since {first} is after --until {last}")
    label = args.label.lower()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", label):
        die("--label must be one label")
    for repo in args.repo:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            die(f"--repo must be <owner>/<repo>, got: {repo}")

    runs_by_repo = {repo: fetch_repo(repo, first, last) for repo in args.repo}
    rows, prs = aggregate(runs_by_repo, label)
    data = as_data(rows, prs)
    if args.json:
        print(json.dumps({"since": str(first), "until": str(last), "label": label, **data}, indent=2))
    else:
        print(render(data, first, last, label))


if __name__ == "__main__":
    main()
