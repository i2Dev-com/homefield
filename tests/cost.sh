#!/usr/bin/env bash
# `tools/cost.py`: hosted-vs-local monthly cost projection, OS multipliers
# and rates, bucket classification, plan included minutes, 30-day window
# scaling, validation errors, and the live gh path.
#
# Run:  bash tests/cost.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat >"$work/fixture.json" <<'JSON'
{
  "acme/app": [
    {
      "id": 1,
      "path": ".github/workflows/pr.yml",
      "event": "pull_request",
      "branch": "feat/a",
      "jobs": [
        {
          "id": 11,
          "name": "local-checks",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T10:00:00Z",
          "started_at": "2026-10-01T10:00:10Z",
          "completed_at": "2026-10-01T10:01:11Z",
          "runner_name": "lima",
          "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]
        },
        {
          "id": 12,
          "name": "pr-x64",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T10:00:00Z",
          "started_at": "2026-10-01T10:00:00Z",
          "completed_at": "2026-10-01T10:00:10Z",
          "runner_name": "GitHub Actions 1",
          "labels": ["ubuntu-latest", "swarm-pool"]
        },
        {
          "id": 13,
          "name": "pr-arm64",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T10:00:00Z",
          "started_at": "2026-10-01T10:00:00Z",
          "completed_at": "2026-10-01T10:02:00Z",
          "runner_name": "GitHub Actions 2",
          "labels": ["ubuntu-24.04-arm"]
        },
        {
          "id": 14,
          "name": "pr-macos",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T10:00:00Z",
          "started_at": "2026-10-01T10:00:00Z",
          "completed_at": "2026-10-01T10:03:00Z",
          "runner_name": "GitHub Actions 3",
          "labels": ["macos-15"]
        },
        {
          "id": 15,
          "name": "pr-zero-sec",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T10:00:00Z",
          "started_at": "2026-10-01T10:00:00Z",
          "completed_at": "2026-10-01T10:00:00Z",
          "runner_name": "GitHub Actions 4",
          "labels": ["ubuntu-latest"]
        },
        {
          "id": 16,
          "name": "pr-skipped",
          "status": "completed",
          "conclusion": "skipped",
          "created_at": "2026-10-01T10:00:00Z",
          "started_at": null,
          "completed_at": null,
          "runner_name": null,
          "labels": ["ubuntu-latest"]
        },
        {
          "id": 17,
          "name": "pr-unstarted",
          "status": "completed",
          "conclusion": "cancelled",
          "created_at": "2026-10-01T10:00:00Z",
          "started_at": null,
          "completed_at": null,
          "runner_name": null,
          "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]
        },
        {
          "id": 18,
          "name": "pr-running",
          "status": "in_progress",
          "conclusion": null,
          "created_at": "2026-10-01T10:00:00Z",
          "started_at": "2026-10-01T10:00:05Z",
          "completed_at": null,
          "runner_name": "lima",
          "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]
        },
        {
          "id": 19,
          "name": "other-self-hosted",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T10:00:00Z",
          "started_at": "2026-10-01T10:00:00Z",
          "completed_at": "2026-10-01T10:05:00Z",
          "runner_name": "gpu-box",
          "labels": ["self-hosted", "gpu"]
        }
      ]
    },
    {
      "id": 2,
      "path": ".github/workflows/main.yml",
      "event": "push",
      "branch": "main",
      "jobs": [
        {
          "id": 21,
          "name": "win-build",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-02T10:00:00Z",
          "started_at": "2026-10-02T10:00:00Z",
          "completed_at": "2026-10-02T10:04:00Z",
          "runner_name": "GitHub Actions 8",
          "labels": ["windows-2025"]
        }
      ]
    }
  ],
  "acme/other": [
    {
      "id": 3,
      "path": ".github/workflows/ci.yml",
      "event": "pull_request",
      "branch": "feat/x",
      "jobs": [
        {
          "id": 31,
          "name": "pr-hosted",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T12:00:00Z",
          "started_at": "2026-10-01T12:00:00Z",
          "completed_at": "2026-10-01T12:12:30Z",
          "runner_name": "GitHub Actions 9",
          "labels": ["ubuntu-latest"]
        }
      ]
    }
  ]
}
JSON

pick() {
  python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"
}

run_fixture() {
  HOMEFIELD_COST_FIXTURE="$work/fixture.json" python3 "$ROOT/tools/cost.py" "$@"
}

echo "classification, rates, rounding and scaling"
# 10-day window -> 3.0x scale to 30 days.
# acme/app observed:
#   local       : 61s -> ceil 2m, priced at linux-x64 ($0.012, 2 billed)
#   routable    : 10s ubuntu-latest (1m, $0.006, swarm-pool must not match arm)
#                 + 120s ubuntu-24.04-arm (2m, $0.010) + 0s ubuntu-latest (0m) = 3m, $0.016
#   other_hosted: 180s macos-15 on PR (3m, 30 billed, $0.186) + 240s windows-2025 on push (4m, 8 billed, $0.040)
#                 = 7m raw, 38 billed, $0.226
json_out="$(run_fixture --repo acme/app --since 2026-10-01 --until 2026-10-10 --included 0 --json)"
rc=$?
record "fixture --json succeeds cleanly" "0" "$rc"
record "window is 10d scaled 3.0x to 30d" "10/30/3.0" \
  "$(echo "$json_out" | pick "f\"{d['window_days']}/{d['projection_days']}/{d['scale_factor']}\"")"
record "observed buckets classify local/routable/other_hosted + incomplete counts" "2/3/7/1/1/1" \
  "$(echo "$json_out" | pick "f\"{d['repos'][0]['buckets']['local']['raw_minutes']}/{d['repos'][0]['buckets']['routable']['raw_minutes']}/{d['repos'][0]['buckets']['other_hosted']['raw_minutes']}/{d['repos'][0]['pull_requests']}/{d['repos'][0]['unstarted']}/{d['repos'][0]['pending']}\"")"
record "local ignores runner arm64 label; swarm-pool does not trigger arm64" "0.01/0.02/0.23/0.02/0.01" \
  "$(echo "$json_out" | pick "f\"{d['repos'][0]['buckets']['local']['gross_usd']:.2f}/{d['repos'][0]['buckets']['routable']['gross_usd']:.2f}/{d['repos'][0]['buckets']['other_hosted']['gross_usd']:.2f}/{d['repos'][0]['by_os']['linux-x64']['gross_usd']:.2f}/{d['repos'][0]['by_os']['linux-arm64']['gross_usd']:.2f}\"")"
# Monthly scenarios (--included 0, scale 3x):
#   all_hosted    : (2+3+7)*3 = 36 raw, (6+9+114) = 129 billed, gross (0.012+0.016+0.226)*3 = 0.762 -> 0.76
#   current       : (3+7)*3 = 30 raw, 123 billed, gross 0.242*3 = 0.726 -> 0.73
#   with_homefield: 7*3 = 21 raw, 114 billed, gross 0.226*3 = 0.678 -> 0.68
#   total savings : 0.762 - 0.678 = 0.084 -> 0.08/mo, 1.01/yr
record "scaled scenarios and --included 0 overage math" "0.76/0.73/0.68/0.08/1.01" \
  "$(echo "$json_out" | pick "f\"{d['monthly_projection']['scenarios']['all_hosted']['net_usd']:.2f}/{d['monthly_projection']['scenarios']['current']['net_usd']:.2f}/{d['monthly_projection']['scenarios']['with_homefield']['net_usd']:.2f}/{d['monthly_projection']['savings']['total_monthly_usd']:.2f}/{d['monthly_projection']['savings']['total_annual_usd']:.2f}\"")"

echo
echo "worked example: Free vs Team included allowance and macOS pool sharing"
# Construct a 30-day fixture matching docs/cost.md worked example:
# 2,250 raw min linux-x64 routable PR ($13.50 gross, 2,250 billed)
# + 200 raw min macos main ($12.40 gross, 2,000 billed)
python3 - <<'PY' "$work/worked.json"
import json, sys

def span_job(jid, name, minutes, labels):
    h, m = divmod(minutes, 60)
    return {
        "id": jid,
        "name": name,
        "status": "completed",
        "conclusion": "success",
        "created_at": "2026-10-01T00:00:00Z",
        "started_at": "2026-10-01T00:00:00Z",
        "completed_at": f"2026-10-01T{h:02d}:{m:02d}:00Z",
        "runner_name": "GitHub Actions 1",
        "labels": labels,
    }

# Split 2250 minutes across 3 jobs (750m each -> 12h30m each) + 200m macOS (3h20m)
data = {
    "acme/mobile": [
        {
            "id": 10,
            "path": ".github/workflows/pr.yml",
            "event": "pull_request",
            "branch": "feat/payoff",
            "jobs": [
                span_job(1, "pr-1", 750, ["ubuntu-latest"]),
                span_job(2, "pr-2", 750, ["ubuntu-latest"]),
                span_job(3, "pr-3", 750, ["ubuntu-latest"]),
            ],
        },
        {
            "id": 20,
            "path": ".github/workflows/release.yml",
            "event": "push",
            "branch": "main",
            "jobs": [span_job(4, "ios-build", 200, ["macos-15"])],
        },
    ]
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY

worked_free="$(HOMEFIELD_COST_FIXTURE="$work/worked.json" python3 "$ROOT/tools/cost.py" --repo acme/mobile --since 2026-10-01 --until 2026-10-30 --plan free --json)"
worked_team="$(HOMEFIELD_COST_FIXTURE="$work/worked.json" python3 "$ROOT/tools/cost.py" --repo acme/mobile --since 2026-10-01 --until 2026-10-30 --plan team --json)"
record "worked example on Free (2,000 included): \$13.71/mo saved (\$164.54/yr)" "2000/13.71/0.00/13.71/164.54" \
  "$(echo "$worked_free" | pick "f\"{d['included_minutes']}/{d['monthly_projection']['scenarios']['all_hosted']['net_usd']:.2f}/{d['monthly_projection']['scenarios']['with_homefield']['net_usd']:.2f}/{d['monthly_projection']['savings']['total_monthly_usd']:.2f}/{d['monthly_projection']['savings']['total_annual_usd']:.2f}\"")"
record "worked example on Team (3,000 included): \$7.62/mo saved (\$91.41/yr)" "3000/7.62/0.00/7.62/91.41" \
  "$(echo "$worked_team" | pick "f\"{d['included_minutes']}/{d['monthly_projection']['scenarios']['all_hosted']['net_usd']:.2f}/{d['monthly_projection']['scenarios']['with_homefield']['net_usd']:.2f}/{d['monthly_projection']['savings']['total_monthly_usd']:.2f}/{d['monthly_projection']['savings']['total_annual_usd']:.2f}\"")"

worked_ent="$(HOMEFIELD_COST_FIXTURE="$work/worked.json" python3 "$ROOT/tools/cost.py" --repo acme/mobile --since 2026-10-01 --until 2026-10-30 --plan enterprise --json)"
record "under included quota (Enterprise 50,000): \$0.00 bill and \$0.00 savings" "50000/0.00/0.00" \
  "$(echo "$worked_ent" | pick "f\"{d['included_minutes']}/{d['monthly_projection']['scenarios']['all_hosted']['net_usd']:.2f}/{d['monthly_projection']['savings']['total_monthly_usd']:.2f}\"")"

echo
echo "routing guards: Dependabot and fork PR exclusions"
cat >"$work/guards.json" <<'JSON'
{
  "acme/app": [
    {
      "id": 101,
      "path": ".github/workflows/ci.yml",
      "event": "pull_request",
      "branch": "feat/same-repo",
      "actor": "alice",
      "head_repo": "acme/app",
      "jobs": [
        {
          "id": 1001,
          "name": "local-job",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T10:00:00Z",
          "started_at": "2026-10-01T10:00:00Z",
          "completed_at": "2026-10-01T10:05:00Z",
          "runner_name": "lima",
          "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]
        }
      ]
    },
    {
      "id": 102,
      "path": ".github/workflows/ci.yml",
      "event": "pull_request",
      "branch": "bump/deps",
      "actor": "dependabot[bot]",
      "head_repo": "acme/app",
      "jobs": [
        {
          "id": 1002,
          "name": "dep-actor",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T11:00:00Z",
          "started_at": "2026-10-01T11:00:00Z",
          "completed_at": "2026-10-01T12:00:00Z",
          "runner_name": "GitHub Actions 1",
          "labels": ["ubuntu-latest"]
        }
      ]
    },
    {
      "id": 103,
      "path": ".github/workflows/ci.yml",
      "event": "pull_request",
      "branch": "dependabot/npm/lodash",
      "actor": "bob",
      "head_repo": "acme/app",
      "jobs": [
        {
          "id": 1003,
          "name": "dep-branch",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T12:00:00Z",
          "started_at": "2026-10-01T12:00:00Z",
          "completed_at": "2026-10-01T12:10:00Z",
          "runner_name": "GitHub Actions 2",
          "labels": ["ubuntu-latest"]
        }
      ]
    },
    {
      "id": 104,
      "path": ".github/workflows/ci.yml",
      "event": "pull_request",
      "branch": "patch-1",
      "actor": "contributor",
      "head_repo": "stranger/app",
      "jobs": [
        {
          "id": 1004,
          "name": "fork-pr",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T13:00:00Z",
          "started_at": "2026-10-01T13:00:00Z",
          "completed_at": "2026-10-01T13:20:00Z",
          "runner_name": "GitHub Actions 3",
          "labels": ["ubuntu-latest"]
        }
      ]
    },
    {
      "id": 105,
      "path": ".github/workflows/ci.yml",
      "event": "pull_request",
      "branch": "deleted-fork",
      "actor": "contributor",
      "head_repo": null,
      "jobs": [
        {
          "id": 1005,
          "name": "null-head-repo",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T14:00:00Z",
          "started_at": "2026-10-01T14:00:00Z",
          "completed_at": "2026-10-01T14:15:00Z",
          "runner_name": "GitHub Actions 4",
          "labels": ["ubuntu-latest"]
        }
      ]
    },
    {
      "id": 106,
      "path": ".github/workflows/main.yml",
      "event": "push",
      "branch": "main",
      "actor": "alice",
      "head_repo": "acme/app",
      "jobs": [
        {
          "id": 1006,
          "name": "push-linux",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T15:00:00Z",
          "started_at": "2026-10-01T15:00:00Z",
          "completed_at": "2026-10-01T16:00:00Z",
          "runner_name": "GitHub Actions 5",
          "labels": ["ubuntu-latest"]
        },
        {
          "id": 1007,
          "name": "push-win",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T15:00:00Z",
          "started_at": "2026-10-01T15:00:00Z",
          "completed_at": "2026-10-01T15:05:00Z",
          "runner_name": "GitHub Actions 6",
          "labels": ["windows-2025"]
        }
      ]
    }
  ]
}
JSON

guards_default="$(HOMEFIELD_COST_FIXTURE="$work/guards.json" python3 "$ROOT/tools/cost.py" --repo acme/app --since 2026-10-01 --until 2026-10-30 --included 0 --json)"
record "guards mode keeps Dependabot + fork PRs + push in other_hosted (additional = \$0.00)" "5/0/170/0.00/guards/hosted" \
  "$(echo "$guards_default" | pick "f\"{d['repos'][0]['buckets']['local']['raw_minutes']}/{d['repos'][0]['buckets']['routable']['raw_minutes']}/{d['repos'][0]['buckets']['other_hosted']['raw_minutes']}/{d['monthly_projection']['savings']['additional_monthly_usd']:.2f}/{d['mode']}/{d['dependabot']}\"")"

guards_dep="$(HOMEFIELD_COST_FIXTURE="$work/guards.json" python3 "$ROOT/tools/cost.py" --repo acme/app --since 2026-10-01 --until 2026-10-30 --included 0 --dependabot local --json)"
record "--dependabot local moves Dependabot (70m) to routable, forks + push (100m) stay hosted" "70/100/0.42" \
  "$(echo "$guards_dep" | pick "f\"{d['repos'][0]['buckets']['routable']['raw_minutes']}/{d['repos'][0]['buckets']['other_hosted']['raw_minutes']}/{d['monthly_projection']['savings']['additional_monthly_usd']:.2f}\"")"

simple_mode="$(HOMEFIELD_COST_FIXTURE="$work/guards.json" python3 "$ROOT/tools/cost.py" --repo acme/app --since 2026-10-01 --until 2026-10-30 --included 0 --mode simple --json)"
record "--mode simple moves Dependabot + fork PRs + push Linux (165m) to routable; Windows stays hosted" "165/5/0.99" \
  "$(echo "$simple_mode" | pick "f\"{d['repos'][0]['buckets']['routable']['raw_minutes']}/{d['repos'][0]['buckets']['other_hosted']['raw_minutes']}/{d['monthly_projection']['savings']['additional_monthly_usd']:.2f}\"")"

echo
echo "ubuntu-slim pricing (\$0.002/min, 1x)"
cat >"$work/slim.json" <<'JSON'
{
  "acme/slim": [
    {
      "id": 301,
      "path": ".github/workflows/lint.yml",
      "event": "pull_request",
      "branch": "feat/slim",
      "actor": "alice",
      "head_repo": "acme/slim",
      "jobs": [
        {
          "id": 3001,
          "name": "slim-lint",
          "status": "completed",
          "conclusion": "success",
          "created_at": "2026-10-01T10:00:00Z",
          "started_at": "2026-10-01T10:00:00Z",
          "completed_at": "2026-10-01T11:00:00Z",
          "runner_name": "GitHub Actions 1",
          "labels": ["ubuntu-slim"]
        }
      ]
    }
  ]
}
JSON
slim_out="$(HOMEFIELD_COST_FIXTURE="$work/slim.json" python3 "$ROOT/tools/cost.py" --repo acme/slim --since 2026-10-01 --until 2026-10-30 --included 0 --json)"
record "60m ubuntu-slim PR bills \$0.12 (not \$0.36) and routes locally" "60/0/60/0.12/0.12" \
  "$(echo "$slim_out" | pick "f\"{d['repos'][0]['buckets']['routable']['raw_minutes']}/{d['repos'][0]['buckets']['other_hosted']['raw_minutes']}/{d['repos'][0]['by_os']['linux-slim']['raw_minutes']}/{d['repos'][0]['by_os']['linux-slim']['gross_usd']:.2f}/{d['monthly_projection']['savings']['additional_monthly_usd']:.2f}\"")"

echo
echo "multi-repo table and isolated python3 -I"
multi_txt="$(run_fixture --repo acme/app --repo acme/other --since 2026-10-01 --until 2026-10-10 --plan free)"
rc=$?
record "multi-repo text output includes both repos and incomplete notice" "0/yes/yes/yes/yes" \
  "$rc/$(echo "$multi_txt" | grep -q 'acme/app' && echo yes || echo no)/$(echo "$multi_txt" | grep -q 'acme/other' && echo yes || echo no)/$(echo "$multi_txt" | grep -q 'with homefield' && echo yes || echo no)/$(echo "$multi_txt" | grep -q '1 cancelled before starting, 1 queued or running now' && echo yes || echo no)"
iso_out="$(python3 -I "$ROOT/tools/cost.py" --help 2>&1)"
rc=$?
record "python3 -I tools/cost.py --help works cleanly" "0/yes" \
  "$rc/$(echo "$iso_out" | grep -q 'homefield cost' && echo yes || echo no)"

echo
echo "validation and fixture errors (no tracebacks)"
bad_cli() {
  local label="$1" expected="$2"; shift 2
  out="$(run_fixture "$@" 2>&1)"; rc=$?
  record "$label" "nonzero/yes/no" \
    "$(nonzero "$rc")/$(echo "$out" | grep -q "$expected" && echo yes || echo no)/$(echo "$out" | grep -q Traceback && echo yes || echo no)"
}
bad_cli "--since after --until" 'is after --until' --repo acme/app --since 2026-10-10 --until 2026-10-01
bad_cli "malformed --repo" 'must be <owner>/<repo>' --repo not-a-repo --since 2026-10-01 --until 2026-10-02
bad_cli "malformed --label" 'must be one label' --repo acme/app --label 'bad label' --since 2026-10-01 --until 2026-10-02
bad_cli "negative --included" 'must be non-negative' --repo acme/app --included -5 --since 2026-10-01 --until 2026-10-02
bad_cli "missing repo in fixture" 'has no entry for' --repo acme/missing --since 2026-10-01 --until 2026-10-02

printf '%s' 'not json' >"$work/bad.json"
out="$(HOMEFIELD_COST_FIXTURE="$work/bad.json" python3 "$ROOT/tools/cost.py" --repo acme/app --since 2026-10-01 --until 2026-10-02 2>&1)"; rc=$?
record "malformed JSON fixture refused without traceback" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(echo "$out" | grep -q 'not valid JSON' && echo yes || echo no)/$(echo "$out" | grep -q Traceback && echo yes || echo no)"

out="$(HOMEFIELD_COST_FIXTURE="$work/no-such.json" python3 "$ROOT/tools/cost.py" --repo acme/app --since 2026-10-01 --until 2026-10-02 2>&1)"; rc=$?
record "missing fixture file refused without traceback" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(echo "$out" | grep -q 'could not read the fixture' && echo yes || echo no)/$(echo "$out" | grep -q Traceback && echo yes || echo no)"

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
    [ -f "$RUNS/$day.txt" ] && cat "$RUNS/$day.txt"
    ;;
  *"actions/runs/"*"/jobs"*)
    id="$(printf '%s' "$*" | sed -n 's|.*/actions/runs/\([0-9]*\)/jobs.*|\1|p')"
    [ -f "$JOBS/jobs-$id.txt" ] && cat "$JOBS/jobs-$id.txt"
    ;;
esac
exit 0
STUB
chmod +x "$stubs/gh"

printf '%s\n%s\n' \
  '{"id": 2001, "path": ".github/workflows/ci.yml", "event": "pull_request", "created_at": "2026-11-30T10:00:00Z", "branch": "feat/cost", "actor": "alice", "head_repo": "acme/app"}' \
  '{"id": 2002, "path": ".github/workflows/ci.yml", "event": "pull_request", "created_at": "2026-11-30T11:00:00Z", "branch": "bump/deps", "actor": "dependabot[bot]", "head_repo": "acme/app"}' >"$work/runs/2026-11-30.txt"
printf '%s\n%s\n' \
  '{"id": 201, "name": "local-test", "status": "completed", "conclusion": "success", "created_at": "2026-11-30T10:00:00Z", "started_at": "2026-11-30T10:00:00Z", "completed_at": "2026-11-30T10:02:00Z", "runner_name": "lima", "labels": ["self-hosted", "linux", "arm64", "homefield-ci"]}' \
  '{"id": 202, "name": "hosted-lint", "status": "completed", "conclusion": "success", "created_at": "2026-11-30T10:00:00Z", "started_at": "2026-11-30T10:00:00Z", "completed_at": "2026-11-30T10:03:00Z", "runner_name": "GitHub Actions 1", "labels": ["ubuntu-latest"]}' >"$work/jobs/jobs-2001.txt"
printf '%s\n' \
  '{"id": 203, "name": "dep-hosted", "status": "completed", "conclusion": "success", "created_at": "2026-11-30T11:00:00Z", "started_at": "2026-11-30T11:00:00Z", "completed_at": "2026-11-30T11:04:00Z", "runner_name": "GitHub Actions 2", "labels": ["ubuntu-latest"]}' >"$work/jobs/jobs-2002.txt"

live() {
  : >"$work/calls"
  out="$(env -i PATH="$stubs:$PATH" CALLS="$work/calls" RUNS="$work/runs" JOBS="$work/jobs" HOME="$work" \
    ${GH_FAIL:+GH_FAIL=1} HOMEFIELD_COST_TODAY="$COST_TODAY" \
    python3 "$ROOT/tools/cost.py" "$@" 2>&1)"
  rc=$?
}

COST_TODAY=2026-11-30
live --repo acme/app --included 0 --json
record "live: default 30d window and actor/head_repo separation" "0/2/3/4/yes/30" \
  "$rc/$(echo "$out" | sed -n '/^{/,$p' | pick "f\"{d['repos'][0]['buckets']['local']['raw_minutes']}/{d['repos'][0]['buckets']['routable']['raw_minutes']}/{d['repos'][0]['buckets']['other_hosted']['raw_minutes']}\"")/$(echo "$out" | grep -q 'acme/app: 2 runs, fetching jobs' && echo yes || echo no)/$(grep -c 'actions/runs?per_page=100&created=' "$work/calls")"

live --repo acme/app
record "live: default window header shows 2026-11-01 to 2026-11-30" "0/yes/yes" \
  "$rc/$(echo "$out" | grep -q '2026-11-01 to 2026-11-30 (30d -> 30d/mo, scale 1.00x)' && echo yes || echo no)/$(echo "$out" | grep -q 'acme/app: 2 runs, fetching jobs' && echo yes || echo no)"

GH_FAIL=1 live --repo acme/app --since 2026-11-29 --until 2026-11-30
record "live: gh failure exits cleanly without traceback" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(echo "$out" | grep -q 'gh api repos/acme/app/.* failed' && echo yes || echo no)/$(echo "$out" | grep -q Traceback && echo yes || echo no)"

out="$(HOMEFIELD_COST_TODAY=bad-date PATH="$stubs:$PATH" HOME="$work" python3 "$ROOT/tools/cost.py" --repo acme/app 2>&1)"; rc=$?
record "bad HOMEFIELD_COST_TODAY is refused without traceback" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(echo "$out" | grep -q 'not a date (YYYY-MM-DD)' && echo yes || echo no)/$(echo "$out" | grep -q Traceback && echo yes || echo no)"

summary
