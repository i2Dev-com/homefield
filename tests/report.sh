#!/usr/bin/env bash
# `bin/homefield report`: classification (local, hosted, skipped, cancelled
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
   "runner_name": "lima", "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]},
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
   "runner_name": "lima", "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]},
  {"id": 17, "name": "skipme", "status": "completed", "conclusion": "skipped", "created_at": "2026-10-01T10:00:00Z",
   "started_at": null, "completed_at": null,
   "runner_name": null, "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]},
  {"id": 18, "name": "running", "status": "in_progress", "conclusion": null, "created_at": "2026-10-01T10:00:00Z",
   "started_at": "2026-10-01T10:00:05Z", "completed_at": null,
   "runner_name": "lima", "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]},
  {"id": 15, "name": "stuck", "status": "completed", "conclusion": "cancelled", "created_at": "2026-10-01T10:00:00Z",
   "started_at": null, "completed_at": null,
   "runner_name": null, "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]},
  {"id": 19, "name": "hosted-queued", "status": "queued", "conclusion": null, "created_at": "2026-10-01T10:00:00Z",
   "started_at": null, "completed_at": null,
   "runner_name": null, "labels": ["ubuntu-latest"]},
  {"id": 20, "name": "hosted-cancelled", "status": "completed", "conclusion": "cancelled", "created_at": "2026-10-01T10:00:00Z",
   "started_at": null, "completed_at": null,
   "runner_name": null, "labels": ["ubuntu-latest"]},
  {"id": 22, "name": "other-pool-queued", "status": "queued", "conclusion": null, "created_at": "2026-10-01T10:00:00Z",
   "started_at": null, "completed_at": null,
   "runner_name": null, "labels": ["self-hosted", "gpu"]},
  {"id": 24, "name": "group-only-queued", "status": "queued", "conclusion": null, "created_at": "2026-10-01T10:00:00Z",
   "started_at": null, "completed_at": null,
   "runner_name": null, "labels": []},
  {"id": 25, "name": "no-self-hosted-label", "status": "queued", "conclusion": null, "created_at": "2026-10-01T10:00:00Z",
   "started_at": null, "completed_at": null,
   "runner_name": null, "labels": ["linux", "ARM64"]},
  {"id": 23, "name": "hosted-never-ran", "status": "completed", "conclusion": "failure", "created_at": "2026-10-01T10:00:00Z",
   "started_at": null, "completed_at": null,
   "runner_name": null, "labels": ["ubuntu-latest"]}
 ]},
 {"id": 2, "path": ".github/workflows/ci.yml", "event": "pull_request", "branch": "feat/b", "jobs": [
  {"id": 21, "name": "checks", "status": "completed", "conclusion": "failure", "created_at": "2026-10-01T10:05:00Z",
   "started_at": "2026-10-01T10:11:00Z", "completed_at": "2026-10-01T10:11:50Z",
   "runner_name": "lima", "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]}
 ]},
 {"id": 3, "path": ".github/workflows/other.yml", "event": "push", "branch": "main", "jobs": [
  {"id": 31, "name": "mac", "status": "completed", "conclusion": "success", "created_at": "2026-10-02T09:00:00Z",
   "started_at": "2026-10-02T09:00:00Z", "completed_at": "2026-10-02T09:00:30Z",
   "runner_name": "GitHub Actions 7", "labels": ["macos-latest"]}
 ]}
]}
JSON

report() {
  HOMEFIELD_REPORT_FIXTURE="$work/fixture.json" python3 "$ROOT/tools/report.py" \
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
record "a hosted job still queued is pending" "0/0/1" "$(job ci.yml hosted-queued hosted jobs)/$(job ci.yml hosted-queued hosted unstarted)/$(job ci.yml hosted-queued hosted pending)"
record "a hosted job cancelled before a runner was assigned is unstarted" "0/1/0" "$(job ci.yml hosted-cancelled hosted jobs)/$(job ci.yml hosted-cancelled hosted unstarted)/$(job ci.yml hosted-cancelled hosted pending)"
record "a queued job for another self-hosted pool is not counted" "" "$(job ci.yml other-pool-queued hosted pending)"
record "a queued job with a group and no labels is not counted as hosted" "" "$(job ci.yml group-only-queued hosted pending)"
record "a queued job without the self-hosted label but not a hosted image is not counted" "" "$(job ci.yml no-self-hosted-label hosted pending)"
record "a hosted job that failed without a runner never ran: not counted" "" "$(job ci.yml hosted-never-ran hosted jobs)"
record "a skipped job is not a run" "" "$(job ci.yml deploy hosted jobs)"
record "macOS minutes carry the x10 multiplier" "10" "$(job other.yml mac hosted minutes)"
record "local total minutes (3, plus the cancelled job's 1)" "4" "$(total local minutes)"
record "PRs counted from pull_request runs only" "2" "$(total local pull_requests)"
record "local minutes per PR" "2.0" "$(total local minutes_per_pr)"
record "hosted total minutes" "13" "$(total hosted minutes)"
record "hosted minutes per PR" "6.5" "$(total hosted minutes_per_pr)"
record "local total waits use the rows' definition" "30/360/360/1" \
  "$(total local wait_p50)/$(total local wait_p95)/$(total local wait_max)/$(total local wait_over_5m)"

text="$(report)"
record "table names the repository and workflow" "yes" "$(echo "$text" | grep -q 'app .*ci.yml / checks .*local' && echo yes || echo no)"
record "table reports the cancelled-before-start and running jobs" "yes" "$(echo "$text" | grep -q '1 cancelled before starting' && echo yes || echo no)"

# Bad input fails with a message, not a traceback.
out="$(python3 "$ROOT/tools/report.py" --repo nope 2>&1)"
record "a malformed --repo is refused" "yes" "$(echo "$out" | grep -q 'must be <owner>/<repo>' && echo yes || echo no)"
out="$(python3 "$ROOT/tools/report.py" --repo a/b --since 2026-10-05 --until 2026-10-01 2>&1)"
record "since after until is refused" "yes" "$(echo "$out" | grep -q 'is after' && echo yes || echo no)"
out="$(HOMEFIELD_REPORT_FIXTURE="$work/fixture.json" python3 "$ROOT/tools/report.py" \
  --repo acme/other --since 2026-10-01 --until 2026-10-02 2>&1)"
record "a fixture without the repository is refused, not a traceback" \
  "yes" "$(echo "$out" | grep -q 'has no entry for acme/other' && echo yes || echo no)"

# Incomplete fixture input fails with a message, not a traceback (the live API
# always supplies a name and a created_at).
bad_fixture() { # <description> <json> <needle in the message>
  printf '%s' "$2" >"$work/bad.json"
  out="$(HOMEFIELD_REPORT_FIXTURE="$work/bad.json" python3 "$ROOT/tools/report.py" \
    --repo acme/app --since 2026-10-01 --until 2026-10-02 2>&1)"
  record "$1" "yes/no" \
    "$(echo "$out" | grep -q "$3" && echo yes || echo no)/$(echo "$out" | grep -q Traceback && echo yes || echo no)"
}
bad_fixture "a fixture job without a name is refused, not a traceback" \
  '{"acme/app": [{"id": 1, "jobs": [{"id": 11, "status": "completed", "conclusion": "success", "created_at": "2026-10-01T10:00:00Z", "started_at": "2026-10-01T10:00:30Z", "completed_at": "2026-10-01T10:02:10Z"}]}]}' \
  'without name'
bad_fixture "a fixture job without created_at is refused, not a traceback" \
  '{"acme/app": [{"id": 1, "jobs": [{"id": 11, "name": "checks", "status": "completed", "conclusion": "success", "started_at": "2026-10-01T10:00:30Z", "completed_at": "2026-10-01T10:02:10Z"}]}]}' \
  'without created_at'
bad_fixture "a fixture job with a null created_at is refused, not a traceback" \
  '{"acme/app": [{"id": 1, "jobs": [{"id": 11, "name": "checks", "created_at": null, "status": "completed", "conclusion": "success", "started_at": "2026-10-01T10:00:30Z", "completed_at": "2026-10-01T10:02:10Z"}]}]}' \
  'without created_at'
bad_fixture "a fixture job with a malformed started_at is refused, not a traceback" \
  '{"acme/app": [{"id": 1, "jobs": [{"id": 11, "name": "checks", "created_at": "2026-10-01T10:00:00Z", "started_at": "not-a-date", "completed_at": "2026-10-01T10:02:10Z", "status": "completed", "conclusion": "success"}]}]}' \
  'started_at that is not'
bad_fixture "a fixture job with a fractional-seconds completed_at is refused, not a traceback" \
  '{"acme/app": [{"id": 1, "jobs": [{"id": 11, "name": "checks", "created_at": "2026-10-01T10:00:00Z", "started_at": "2026-10-01T10:00:30Z", "completed_at": "2026-10-01T10:02:10.500Z", "status": "completed", "conclusion": "success"}]}]}' \
  'completed_at that is not'
bad_fixture "a fixture that is not keyed by repository is refused" \
  '[]' 'not an object keyed by repository'
bad_fixture "a fixture that is not UTF-8 text is refused, not a traceback" \
  $'\xff\xfe{}' 'not UTF-8 text'
out="$(HOMEFIELD_REPORT_FIXTURE="$work/no-such-fixture.json" python3 "$ROOT/tools/report.py" \
  --repo acme/app --since 2026-10-01 --until 2026-10-02 2>&1)"
record "a missing fixture file is refused, not a traceback" "yes/no" \
  "$(echo "$out" | grep -q 'could not read the fixture' && echo yes || echo no)/$(echo "$out" | grep -q Traceback && echo yes || echo no)"

# ── The live gh path ───────────────────────────────────────────────────────
# A gh stub on PATH answers the API the way gh --paginate prints: the post-jq
# objects, one per line, pages back to back. The runs query is answered per
# created= day, the jobs query per run, so the pagination contract (one run's
# jobs arriving as two pages) and the day-span filter are under test.
echo
echo "the live gh path"
stubs="$work/stubs"
mkdir -p "$stubs" "$work/runs" "$work/jobs"
cat >"$stubs/gh" <<'STUB'
#!/bin/sh
echo "gh $*" >>"$CALLS"
if [ -n "${GH_FAIL:-}" ]; then echo "gh: HTTP 502" >&2; exit 1; fi
case "$*" in
  *"actions/runs?per_page=100&created="*)
    day="$(printf '%s' "$*" | sed -n 's/.*created=\([0-9-]*\)T.*/\1/p')"
    # A day with no runs is an empty answer, not a failure: gh --paginate
    # exits 0 and prints nothing.
    [ -f "$RUNS/$day.txt" ] && cat "$RUNS/$day.txt"
    ;;
  *"actions/runs/"*"/jobs"*)
    id="$(printf '%s' "$*" | sed -n 's|.*/actions/runs/\([0-9]*\)/jobs.*|\1|p')"
    [ -f "$JOBS/jobs-$id.txt" ] && cat "$JOBS/jobs-$id.txt"
    ;;
esac
# A query with no answer is an empty page, never a failure: fall through to 0.
exit 0
STUB
chmod +x "$stubs/gh"
# The post-jq shapes, one object per line: RUN_FIELDS for runs, JOB_FIELDS for
# jobs. Run 1001's jobs are two pages' worth (gh --paginate prints them back
# to back); run 1002's job carries the acme-ci label for the --label case.
printf '%s\n' '{"id": 1001, "path": ".github/workflows/ci.yml", "event": "pull_request", "created_at": "2026-10-01T10:00:00Z", "branch": "feat/a"}' >"$work/runs/2026-10-01.txt"
printf '%s\n' '{"id": 1002, "path": ".github/workflows/ci.yml", "event": "pull_request", "created_at": "2026-10-02T09:00:00Z", "branch": "feat/b"}' >"$work/runs/2026-10-02.txt"
printf '%s\n%s\n' \
  '{"id": 11, "name": "checks", "status": "completed", "conclusion": "success", "created_at": "2026-10-01T10:00:00Z", "started_at": "2026-10-01T10:00:30Z", "completed_at": "2026-10-01T10:02:10Z", "runner_name": "lima", "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]}' \
  '{"id": 12, "name": "lint", "status": "completed", "conclusion": "success", "created_at": "2026-10-01T10:00:00Z", "started_at": "2026-10-01T10:00:03Z", "completed_at": "2026-10-01T10:01:04Z", "runner_name": "GitHub Actions 5", "labels": ["ubuntu-latest"]}' >"$work/jobs/jobs-1001.txt"
printf '%s\n' '{"id": 21, "name": "acme-checks", "status": "completed", "conclusion": "success", "created_at": "2026-10-02T09:00:00Z", "started_at": "2026-10-02T09:00:10Z", "completed_at": "2026-10-02T09:01:00Z", "runner_name": "lima", "labels": ["self-hosted", "linux", "arm64", "acme-ci"]}' >"$work/jobs/jobs-1002.txt"

live() {
  : >"$work/calls"
  out="$(env -i PATH="$stubs:$PATH" CALLS="$work/calls" RUNS="$work/runs" JOBS="$work/jobs" HOME="$work" \
    ${GH_FAIL:+GH_FAIL=1} HOMEFIELD_REPORT_TODAY="$REPORT_TODAY" \
    python3 "$ROOT/tools/report.py" "$@" 2>&1)"
  rc=$?
}
REPORT_TODAY=2026-10-02
live --repo acme/app --since 2026-10-01 --until 2026-10-02
record "live: two days' runs, each with its jobs, the progress line on stderr" "0/yes/yes/yes" \
  "$rc/$(echo "$out" | grep -q 'app .*ci.yml / checks .*local' && echo yes || echo no)/$(echo "$out" | grep -q 'app .*ci.yml / lint .*hosted' && echo yes || echo no)/$(echo "$out" | grep -q 'acme/app: 2 runs, fetching jobs' && echo yes || echo no)"
record "live: the created span is a single UTC day, per day of the window" "2" \
  "$(grep -c 'created=2026-10-0[12]T00:00:00Z\.\.2026-10-0[12]T23:59:59Z' "$work/calls")"
record "live: one run's jobs arrive as two pages of one call, both counted" "1/1/1" \
  "$(grep -c 'actions/runs/1001/jobs' "$work/calls")/$(echo "$out" | grep -q 'ci.yml / checks .*local' && echo 1 || echo 0)/$(echo "$out" | grep -q 'ci.yml / lint .*hosted' && echo 1 || echo 0)"
live --repo acme/app --since 2026-10-01 --until 2026-10-02 --label acme-ci
record "live: a custom --label reclassifies the job that carries it" "0/yes/no" \
  "$rc/$(echo "$out" | grep -q 'app .*ci.yml / acme-checks .*local' && echo yes || echo no)/$(echo "$out" | grep -q 'acme-checks .*hosted' && echo yes || echo no)"
live --repo acme/app --repo acme/other --since 2026-10-01 --until 2026-10-02
record "live: repeated --repo asks each repository" "2/2" \
  "$(grep -c 'repos/acme/app/actions/runs?per_page=100&created=' "$work/calls")/$(grep -c 'repos/acme/other/actions/runs?per_page=100&created=' "$work/calls")"
GH_FAIL=1 live --repo acme/app --since 2026-10-01 --until 2026-10-02
record "live: a gh failure is the one-line refusal, not a traceback" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(echo "$out" | grep -q 'gh api repos/acme/app/.* failed' && echo yes || echo no)/$(echo "$out" | grep -q Traceback && echo yes || echo no)"
# The default window: the first of the current month through today, in UTC
# (the window report.py computes). The clock is pinned with
# HOMEFIELD_REPORT_TODAY — the test never reads the host's clock — and the
# stub answers a run created on the pinned day, so the report's header names
# both ends.
today="2026-11-05"
first="2026-11-01"
printf '%s\n' "{\"id\": 1003, \"path\": \".github/workflows/ci.yml\", \"event\": \"pull_request\", \"created_at\": \"${today}T10:00:00Z\", \"branch\": \"feat/c\"}" >"$work/runs/$today.txt"
printf '%s\n' '{"id": 31, "name": "today-job", "status": "completed", "conclusion": "success", "created_at": "'"$today"'T10:00:00Z", "started_at": "'"$today"'T10:00:10Z", "completed_at": "'"$today"'T10:01:00Z", "runner_name": "lima", "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]}' >"$work/jobs/jobs-1003.txt"
REPORT_TODAY="$today"
live --repo acme/app
record "live: no --since/--until is the month to date, and it is said" "0/yes/yes" \
  "$rc/$(echo "$out" | grep -q "Jobs from $first to $today (UTC)" && echo yes || echo no)/$(echo "$out" | grep -q 'ci.yml / today-job .*local' && echo yes || echo no)"
out="$(HOMEFIELD_REPORT_TODAY=not-a-date PATH="$stubs:$PATH" RUNS="$work/runs" JOBS="$work/jobs" HOME="$work" \
  python3 "$ROOT/tools/report.py" --repo acme/app 2>&1)"; rc=$?
record "a malformed HOMEFIELD_REPORT_TODAY is refused, not a traceback" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(echo "$out" | grep -q 'not a date (YYYY-MM-DD)' && echo yes || echo no)/$(echo "$out" | grep -q Traceback && echo yes || echo no)"

summary
