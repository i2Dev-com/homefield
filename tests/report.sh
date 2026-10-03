#!/usr/bin/env bash
# `bin/ci-runner report`: classification (local, hosted, skipped, cancelled
# before starting, running now), queue-wait percentiles, minutes with the OS
# multiplier, matrix jobs kept as separate rows, and PR counts, all from a
# fixture instead of the GitHub API.
#
# Run:  bash tests/report.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat >"$work/fixture.json" <<'JSON'
{"acme/app": [
 {"id": 1, "path": ".github/workflows/ci.yml", "event": "pull_request", "branch": "feat/a", "jobs": [
  {"id": 11, "name": "checks", "status": "completed", "conclusion": "success", "created_at": "2026-10-01T10:00:00Z",
   "started_at": "2026-10-01T10:00:30Z", "completed_at": "2026-10-01T10:02:10Z",
   "runner_name": "lima", "labels": ["self-hosted", "linux", "arm64", "local-ci"]},
  {"id": 12, "name": "lint (node 22)", "status": "completed", "conclusion": "success", "created_at": "2026-10-01T10:00:00Z",
   "started_at": "2026-10-01T10:00:03Z", "completed_at": "2026-10-01T10:01:04Z",
   "runner_name": "GitHub Actions 5", "labels": ["ubuntu-latest"]},
  {"id": 13, "name": "lint (node 24)", "status": "completed", "conclusion": "success", "created_at": "2026-10-01T10:00:00Z",
   "started_at": "2026-10-01T10:00:03Z", "completed_at": "2026-10-01T10:00:59Z",
   "runner_name": "GitHub Actions 6", "labels": ["ubuntu-latest"]},
  {"id": 14, "name": "deploy", "status": "completed", "conclusion": "skipped", "created_at": "2026-10-01T10:00:00Z",
   "started_at": "2026-10-01T10:02:10Z", "completed_at": "2026-10-01T10:02:10Z",
   "runner_name": null, "labels": ["ubuntu-latest"]},
  {"id": 16, "name": "cancelme", "status": "completed", "conclusion": "cancelled", "created_at": "2026-10-01T10:00:00Z",
   "started_at": "2026-10-01T10:00:10Z", "completed_at": "2026-10-01T10:00:40Z",
   "runner_name": "lima", "labels": ["self-hosted", "linux", "arm64", "local-ci"]},
  {"id": 17, "name": "skipme", "status": "completed", "conclusion": "skipped", "created_at": "2026-10-01T10:00:00Z",
   "started_at": null, "completed_at": null,
   "runner_name": null, "labels": ["self-hosted", "linux", "arm64", "local-ci"]},
  {"id": 18, "name": "running", "status": "in_progress", "conclusion": null, "created_at": "2026-10-01T10:00:00Z",
   "started_at": "2026-10-01T10:00:05Z", "completed_at": null,
   "runner_name": "lima", "labels": ["self-hosted", "linux", "arm64", "local-ci"]},
  {"id": 15, "name": "stuck", "status": "completed", "conclusion": "cancelled", "created_at": "2026-10-01T10:00:00Z",
   "started_at": null, "completed_at": null,
   "runner_name": null, "labels": ["self-hosted", "linux", "arm64", "local-ci"]}
 ]},
 {"id": 2, "path": ".github/workflows/ci.yml", "event": "pull_request", "branch": "feat/b", "jobs": [
  {"id": 21, "name": "checks", "status": "completed", "conclusion": "failure", "created_at": "2026-10-01T10:05:00Z",
   "started_at": "2026-10-01T10:11:00Z", "completed_at": "2026-10-01T10:11:50Z",
   "runner_name": "lima", "labels": ["self-hosted", "linux", "arm64", "local-ci"]}
 ]},
 {"id": 3, "path": ".github/workflows/other.yml", "event": "push", "branch": "main", "jobs": [
  {"id": 31, "name": "mac", "status": "completed", "conclusion": "success", "created_at": "2026-10-02T09:00:00Z",
   "started_at": "2026-10-02T09:00:00Z", "completed_at": "2026-10-02T09:00:30Z",
   "runner_name": "GitHub Actions 7", "labels": ["macos-latest"]}
 ]}
]}
JSON

report() {
  CI_RUNNER_REPORT_FIXTURE="$work/fixture.json" python3 "$ROOT/tools/report.py" \
    --repo acme/app --since 2026-10-01 --until 2026-10-02 "$@"
}
# field <jobs|totals> <repo-workflow-job or repo-where> <key>
json="$(report --json)"
pick() {
  python3 -c '
import json, sys
data = json.load(sys.stdin)
section, match, key = sys.argv[1:4]
for item in data[section]:
    ident = "/".join(str(item.get(k)) for k in sys.argv[4:])
    if ident == match:
        print(item[key]); break
' "$@" <<<"$json"
}
job() { pick jobs "$1/$2/$3" "$4" workflow job where; }
total() { pick totals "$1" "$2" where; }

record "local checks: jobs" "2" "$(job ci.yml checks local jobs)"
record "local checks: p50 wait (nearest rank)" "30" "$(job ci.yml checks local wait_p50)"
record "local checks: p95 and max wait" "360/360" "$(job ci.yml checks local wait_p95)/$(job ci.yml checks local wait_max)"
record "local checks: waits over 5 min" "1" "$(job ci.yml checks local wait_over_5m)"
record "local checks: average run seconds" "75.0" "$(job ci.yml checks local avg_seconds)"
record "local checks: minutes (100 s -> 2, 50 s -> 1)" "3" "$(job ci.yml checks local minutes)"
record "local checks: a failure is counted as failed" "1" "$(job ci.yml checks local failed)"
record "a cancelled job is not a failure" "1/0" "$(job ci.yml cancelme local cancelled)/$(job ci.yml cancelme local failed)"
record "a never-started local job is counted apart" "0/1" "$(job ci.yml stuck local jobs)/$(job ci.yml stuck local unstarted)"
record "matrix jobs keep their own rows" "1/1" "$(job ci.yml 'lint (node 22)' hosted jobs)/$(job ci.yml 'lint (node 24)' hosted jobs)"
record "hosted lint minutes (61 s -> 2, 56 s -> 1)" "2/1" "$(job ci.yml 'lint (node 22)' hosted minutes)/$(job ci.yml 'lint (node 24)' hosted minutes)"
record "a skipped job that asked for the local label is not counted" "" "$(job ci.yml skipme local jobs)"
record "a running job is pending, not a run or an unstarted job" "0/0/1" "$(job ci.yml running local jobs)/$(job ci.yml running local unstarted)/$(job ci.yml running local pending)"
record "a skipped job is not a run" "" "$(job ci.yml deploy hosted jobs)"
record "macOS minutes carry the x10 multiplier" "10" "$(job other.yml mac hosted minutes)"
record "local total minutes (3, plus the cancelled job's 1)" "4" "$(total local minutes)"
record "PRs counted from pull_request runs only" "2" "$(total local pull_requests)"
record "local minutes per PR" "2.0" "$(total local minutes_per_pr)"
record "hosted total minutes" "13" "$(total hosted minutes)"
record "hosted minutes per PR" "6.5" "$(total hosted minutes_per_pr)"

text="$(report)"
record "table names the repository and workflow" "yes" "$(echo "$text" | grep -q 'app .*ci.yml / checks .*local' && echo yes || echo no)"
record "table reports the cancelled-before-start and running jobs" "yes" "$(echo "$text" | grep -q '1 cancelled before starting' && echo yes || echo no)"

# Bad input fails with a message, not a traceback.
out="$(python3 "$ROOT/tools/report.py" --repo nope 2>&1)"
record "a malformed --repo is refused" "yes" "$(echo "$out" | grep -q 'must be <owner>/<repo>' && echo yes || echo no)"
out="$(python3 "$ROOT/tools/report.py" --repo a/b --since 2026-10-05 --until 2026-10-01 2>&1)"
record "since after until is refused" "yes" "$(echo "$out" | grep -q 'is after' && echo yes || echo no)"

summary
