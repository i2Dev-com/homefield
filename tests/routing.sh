#!/usr/bin/env bash
# tests/routing.sh — the automatic hosted fallback (#286): the routing
# records that mirror CI_RUNNER=local, the stop-side fallback, the
# start-side restore, and the --auto-route switch that makes plain
# stop/start do both.
#
# The route functions run against a stub gh the way tests/adopt.sh runs
# them: variables, runner lists, runs and jobs are answered from the
# environment, nothing reaches GitHub. stop/start run the real bin/homefield
# through main the way tests/start-stop.sh runs it (limactl, gh, uname,
# sw_vers stubs only). install/upgrade run the real cmd_install the way
# tests/ephemeral.sh runs it.
#
# Run:  bash tests/routing.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

BASH_BIN="$(command -v bash)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stubs="$work/stubs"
calls="$work/calls"
state="$work/state"
mkdir -p "$stubs" "$state" "$work/home/.lima/homefield"
printf '# Lima VM.\n' >"$work/home/.lima/homefield/lima.yaml"
: >"$calls"
# The stub shebangs are #!/usr/bin/env bash and a stub-only PATH cannot
# resolve that without bash on it (the same rule tests/fakes.sh's sh default
# follows), so bash — and everything the route code and the records call —
# is on the stubs' PATH from the start.
for t in awk bash cat dirname grep mktemp mkdir mv rm sleep tr; do ln -s "$(command -v "$t")" "$stubs/$t"; done

# ── the gh stub: variables, runner lists, runs, jobs, cancel/rerun ─────────
cat >"$stubs/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$CALLS"
case "$1 $2" in
  "variable get"*)
    repo=""
    all="$*"
    case "$all" in *"--repo "*) repo="${all#*--repo }" ;; esac
    repo="${repo%% *}"
    # gh's --repo takes [HOST/]OWNER/REPO; the fixture is keyed by OWNER/REPO.
    repo="${repo#github.com/}"
    if [ -n "${GH_CI_RUNNER_BY_REPO:-}" ]; then
      v="$(awk -v r="$repo" '$1 == r {print $2; exit}' "$GH_CI_RUNNER_BY_REPO" 2>/dev/null)"
      [ -n "$v" ] && { echo "$v"; exit 0; }
    fi
    if [ -n "${GH_CI_RUNNER:-}" ]; then echo "$GH_CI_RUNNER"; else echo "variable not found" >&2; exit 1; fi
    exit 0
    ;;
  "variable set"*)
    [ -z "${GH_VARSET_FAIL:-}" ] || { echo "gh: HTTP 422" >&2; exit 1; }
    exit 0
    ;;
esac
case "$*" in
  *"actions/runners?per_page="*)
    [ -z "${GH_RUNNERS_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    printf '%b' "${GH_RUNNERS-}"
    ;;
  *"actions/runs?status=queued"*)
    [ -z "${GH_RUNS_FAIL:-}" ] || { echo "gh: HTTP 500" >&2; exit 1; }
    printf '%b' "${GH_RUNS-}"
    ;;
  *"actions/runs?status=in_progress"*)
    printf '%b' "${GH_RUNS_IN_PROGRESS-}" ;;
  *"actions/runner-groups/"*"repositories"*)
    printf '%b' "${GH_GROUP_REPOS-}" ;;
  *"actions/runner-groups/"*"runners"*)
    printf '%b' "${GH_GROUP_RUNNERS-}" ;;
  *"actions/runner-groups?per_page="*)
    [ -z "${GH_GROUPS_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    printf '%b' "${GH_GROUPS-}" ;;
  *"/actions/runs/"*"/jobs"*)
    [ -z "${GH_JOBS_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    printf '%b' "${GH_JOBS-}" ;;
  "run view"*)
    [ -z "${GH_RUNVIEW_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    echo "${GH_RUN_STATUS:-completed}" ;;
  "run cancel"*)
    [ -z "${GH_CANCEL_FAIL:-}" ] || { echo "gh: HTTP 409" >&2; exit 1; } ;;
  "run rerun"*)
    [ -z "${GH_RERUN_FAIL:-}" ] || { echo "gh: HTTP 403" >&2; exit 1; } ;;
  *) echo "gh stub: unexpected: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$stubs/gh"

# ── the function harness: the real lib + cmd-route.sh, stubbed gh ──────────
HARNESS="$work/harness.sh"
cat >"$HARNESS" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
HOMEFIELD_STATE_DIR="$STATE_DIR"
INSTANCE="homefield"
. "$ROOT/bin/lib/emit.sh"
. "$ROOT/bin/lib/github.sh"
. "$ROOT/bin/lib/state.sh"
. "$ROOT/bin/cmd-route.sh"
adopt_nap() { :; }
"$@"
EOF
harness() {
  : >"$calls"
  out="$(
    env -i HOME="$work/home" PATH="$stubs" CALLS="$calls" ROOT="$ROOT" \
      STATE_DIR="$state" GH_TIMEOUT=5 ROUTE_TRIES=1 ROUTE_INTERVAL=0 \
      ${harness_env[@]+"${harness_env[@]}"} "$BASH_BIN" "$HARNESS" "$@" 2>&1 </dev/null)"
  rc=$?
}
harness_env=()
reset_records() {
  rm -f "$state/routing" "$state/autoflip"
  harness_env=()
}
# state_value <key>: the instance state file's value for the key.
state_value() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$state/homefield.state" 2>/dev/null; }

echo "the routing records"
reset_records
harness_env=(GH_CI_RUNNER=hosted)
harness cmd_route local --repo acme/api --label homefield-ci
record "route local: the repo is recorded under its label" "0/homefield-ci acme/api github.com" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"
record "...the variable was set, and nothing waits in autoflip" "yes/0" \
  "$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body local' "$calls" && echo yes || echo no)/$(wc -l <"$state/autoflip" 2>/dev/null | tr -d ' ' || echo 0)"

harness cmd_route local --repo acme/api --label other-label
record "route local on another label: the repo's line is replaced" "0/other-label acme/api github.com" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"

# A Mac may host runners for the same owner/repo on github.com and a GHES
# host: the records must not mix them (#287, Codex #295 round 2).
reset_records
printf 'homefield-ci acme/api ghes.acme.example\n' >"$state/routing"
harness cmd_route local --repo acme/api --label other-label
record "route local for a repo recorded on another host: a github.com line is added beside it" "0/homefield-ci acme/api ghes.acme.example
other-label acme/api github.com" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"
reset_records
printf 'homefield-ci acme/api ghes.acme.example\n' >"$state/routing"
printf 'homefield-ci acme/api ghes.acme.example\n' >"$state/autoflip"
harness_env=(GH_CI_RUNNER=local)
harness cmd_route hosted --repo acme/api --label homefield-ci
record "route hosted for a repo recorded on another host: the other host's lines stay" "0/homefield-ci acme/api ghes.acme.example/1" \
  "$rc/$(cat "$state/routing" 2>/dev/null)/$(wc -l <"$state/autoflip" 2>/dev/null | tr -d ' ' || echo 0)"

reset_records
printf 'label-a acme/api\n' >"$state/autoflip"
harness cmd_route local --repo acme/api --label label-b
record "a local route clears the pending restore it supersedes" "0/label-b acme/api github.com/0" \
  "$rc/$(cat "$state/routing" 2>/dev/null)/$(wc -l <"$state/autoflip" 2>/dev/null | tr -d ' ' || echo 0)"

reset_records
printf 'label-a acme/other\n' >"$state/autoflip"
harness cmd_route local --repo acme/api --label label-b
record "a local route keeps a pending restore for another repo" "0/label-a acme/other" \
  "$rc/$(cat "$state/autoflip" 2>/dev/null)"

reset_records
printf 'homefield-ci acme/api\nhomefield-ci acme/web\n' >"$state/routing"
printf 'homefield-ci acme/old\n' >"$state/autoflip"
harness_env=(GH_CI_RUNNER=local)
harness cmd_route hosted --repo acme/api --label homefield-ci
record "route hosted: the repo leaves the routing record" "0/homefield-ci acme/web" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"
record "...and it leaves autoflip too (a stop's pending restore is undone)" "0" \
  "$(grep -c acme/api "$state/autoflip" 2>/dev/null || true)"

reset_records
harness_env=(GH_CI_RUNNER=hosted)
harness cmd_route local --repo acme/api --label homefield-ci --dry-run
record "a dry run: the variable is not set and no record is written" "0/0/1" \
  "$rc/$(grep -c 'variable set' "$calls" || true)/$([ -f "$state/routing" ] && echo 0 || echo 1)"

reset_records
harness_env=(GH_VARSET_FAIL=1)
harness cmd_route local --repo acme/api --label homefield-ci
record "the variable set fails: no record, exit 1" "1/1" "$rc/$([ -f "$state/routing" ] && echo 0 || echo 1)"

echo
echo "the stop-side fallback"
# GH_RUNNERS rows: id, name, status, labels (tab-separated), as
# runners_on_github --jq prints them. my-mac-homefield is the runner being
# stopped.
runner_rows='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n'

reset_records
printf 'homefield-ci acme/api\nhomefield-ci acme/web\nother-label acme/other\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows")
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "no other runner serves the labels: every routed repo is flipped" "0/yes/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/web --body hosted' "$calls" && echo yes || echo no)"
record "...the flipped repos wait in autoflip" "homefield-ci acme/api github.com
homefield-ci acme/web github.com" \
  "$(cat "$state/autoflip" 2>/dev/null)"
record "...the routing record keeps only the label nobody serves" "other-label acme/other" \
  "$(cat "$state/routing" 2>/dev/null)"
record "...the label nobody serves (other-label) is left alone" "0" \
  "$(grep -c 'variable set CI_RUNNER --repo github.com/acme/other' "$calls" || true)"

reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows
43\tother-mac\tonline\tself-hosted,linux,arm64,homefield-ci\n")
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "another online runner serves the label: nothing is flipped" "0/yes/0" \
  "$rc/$(has "$out" 'still served by another online runner')/$(grep -c 'variable set' "$calls" || true)"

reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows
43\tother-mac\tonline\tself-hosted,linux,x64,homefield-ci\n")
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "an x64 runner sharing the label cannot take the ARM64 jobs: the flip happens" "0/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)"

reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows
43\tother-mac\toffline\tself-hosted,linux,arm64,homefield-ci\n")
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "an offline runner serving the label does not count: the flip happens" "0/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)"

reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows
43\tother-mac\tonline\tself-hosted,linux,arm64,homefield-ci\n" \
  GH_GROUPS='homefield-ci\tselected\tpublic\t7\n' GH_GROUP_RUNNERS='43\n' GH_GROUP_REPOS='acme/web\n')
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "the other runner's group does not admit the repo: the flip happens" "0/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)"

reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows
43\tother-mac\tonline\tself-hosted,linux,arm64,homefield-ci\n" \
  GH_GROUPS='Default\t\t\t1\n' GH_GROUP_RUNNERS='43\n')
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "the other runner is in the Default group: it serves every repo, nothing flips" "0/0" \
  "$rc/$(grep -c 'variable set' "$calls" || true)"

reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows
43\tother-mac\tonline\tself-hosted,linux,arm64,homefield-ci\n" GH_GROUPS_FAIL=1)
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "the group cannot be asked: fail safe, nothing flips" "0/0" \
  "$rc/$(grep -c 'variable set' "$calls" || true)"

reset_records
printf 'homefield-ci acme/api\nhomefield-ci acme/api2\n' >"$state/routing"
harness_env=(GH_RUNNERS='45\trepo-runner\tonline\tself-hosted,linux,arm64,homefield-ci\n')
harness route_stop_fallback https://github.com/acme/api repo-runner
record "a repository-scoped runner: its own repo flips, the org's others do not" "0/yes/no" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api2' "$calls" && echo yes || echo no)"
record "...the org's other repo stays routed local" "homefield-ci acme/api2" "$(grep api2 "$state/routing")"

reset_records
printf 'HomeField-CI acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,HOMEFIELD-CI\n')
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "labels match case-insensitively: the flip happens" "0/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)"

reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,HOMEFIELD-CI\n43\tother-mac\tonline\tself-hosted,linux,arm64,Homefield-CI\n' \
  GH_GROUPS='homefield-ci\tselected\tpublic\t7\n' GH_GROUP_RUNNERS='43\n' GH_GROUP_REPOS='acme/api\n')
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "the still-served check is case-insensitive too: nothing flips" "0/0" \
  "$rc/$(grep -c 'variable set' "$calls" || true)"

reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS_FAIL=1)
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "GitHub cannot be asked: nothing is flipped, exit 1" "1/yes/0" \
  "$rc/$(has "$out" 'could not read the runners from GitHub')/$(grep -c 'variable set' "$calls" || true)"

reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS='44\tsomeone-else\tonline\tself-hosted\n')
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "this runner is not in GitHub's list: nothing is flipped, exit 1" "1/yes/0" \
  "$rc/$(has "$out" 'not in GitHub')/$(grep -c 'variable set' "$calls" || true)"

reset_records
printf 'homefield-ci acme/api\nhomefield-ci beta/web\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows")
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "a record for another scope's repo: left alone, with a message" "0/yes/yes/no" \
  "$rc/$(has "$out" 'routed under a different scope than acme')/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)/$(grep -q 'variable set CI_RUNNER --repo github.com/beta/web' "$calls" && echo yes || echo no)"
record "...it stays in the routing record" "homefield-ci beta/web" "$(grep beta "$state/routing")"

reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows" GH_VARSET_FAIL=1)
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "the flip fails: exit 1, the repo stays routed local, no pending restore" "1/yes/yes/no" \
  "$rc/$(has "$out" 'could not set CI_RUNNER')/$(grep -q acme/api "$state/routing" 2>/dev/null && echo yes || echo no)/$([ -f "$state/autoflip" ] && grep -q acme/api "$state/autoflip" && echo yes || echo no)"

reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows" GH_RUNS_FAIL=1)
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "the flip lands but the stuck-run recovery fails: the repo still waits in autoflip, exit 1" "1/yes/no/no" \
  "$rc/$(grep -q acme/api "$state/autoflip" 2>/dev/null && echo yes || echo no)/$(grep -q acme/api "$state/routing" 2>/dev/null && echo yes || echo no)/$([ -f "$state/routing" ] && grep -q . "$state/routing" && echo yes || echo no)"

reset_records
harness_env=(GH_RUNNERS="$runner_rows")
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "nothing routed: a quiet exit 0 without asking GitHub" "0/yes/0" \
  "$rc/$(has "$out" 'no routed repository needed the fallback')/$(grep -c 'actions/runners' "$calls" || true)"

# A record for another host is not this stop's to flip: the stop refused
# non-github.com hosts above, and the other host's runner has a stop of its own.
reset_records
printf 'homefield-ci acme/api ghes.acme.example\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows")
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "a record for another host: not flipped, GitHub's runners not asked for it" "0/yes/0" \
  "$rc/$(has "$out" 'routed on ghes.acme.example, not github.com')/$(grep -c 'variable set' "$calls" || true)"

echo
echo "the start-side restore"
reset_records
printf 'homefield-ci acme/api\nhomefield-ci acme/web\n' >"$state/autoflip"
harness_env=(GH_CI_RUNNER=hosted GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n')
harness route_start_restore https://github.com/acme my-mac-homefield
record "every pending repo is routed back to local" "0/yes/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body local' "$calls" && echo yes || echo no)/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/web --body local' "$calls" && echo yes || echo no)"
record "...they are recorded as routed local" "homefield-ci acme/api github.com
homefield-ci acme/web github.com" \
  "$(cat "$state/routing" 2>/dev/null)"
record "...and autoflip is empty" "0" "$([ -f "$state/autoflip" ] && wc -l <"$state/autoflip" | tr -d ' ' || echo 0)"

# A pending entry for another host is not this start's to restore: the same
# owner/repo may have been flipped by that host's runner's stop, and
# restoring it here would route on the wrong server.
reset_records
printf 'homefield-ci acme/api ghes.acme.example\n' >"$state/autoflip"
harness_env=(GH_CI_RUNNER=hosted GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n')
harness route_start_restore https://github.com/acme my-mac-homefield
record "a pending entry for another host: left hosted, not restored" "0/yes/0" \
  "$rc/$(has "$out" 'flipped on ghes.acme.example, not github.com')/$(grep -c 'variable set' "$calls" || true)"
record "...and it waits for that host's start" "1" "$(wc -l <"$state/autoflip" | tr -d ' ')"

reset_records
printf 'homefield-ci acme/api\n' >"$state/autoflip"
harness_env=(GH_CI_RUNNER=hosted GH_VARSET_FAIL=1 GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n')
harness route_start_restore https://github.com/acme my-mac-homefield
record "a restore that fails: exit 1, the entry waits for the next start" "1/yes" \
  "$rc/$(grep -q acme/api "$state/autoflip" 2>/dev/null && echo yes || echo no)"

reset_records
printf 'homefield-ci acme/api\nother-label acme/web\n' >"$state/autoflip"
harness_env=(GH_CI_RUNNER=hosted GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n')
harness route_start_restore https://github.com/acme my-mac-homefield
record "a label this runner does not serve: its entry is left for the VM that serves it" "0/yes/no" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body local' "$calls" && echo yes || echo no)/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/web' "$calls" && echo yes || echo no)"
record "...it stays in autoflip" "other-label acme/web" "$(grep other-label "$state/autoflip")"

reset_records
printf 'HomeField-CI acme/api\n' >"$state/autoflip"
harness_env=(GH_CI_RUNNER=hosted GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n')
harness route_start_restore https://github.com/acme my-mac-homefield
record "the restore matches labels case-insensitively" "0/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body local' "$calls" && echo yes || echo no)"

reset_records
printf 'homefield-ci acme/api\n' >"$state/autoflip"
harness_env=(GH_CI_RUNNER=hosted GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,x64,homefield-ci\n')
harness route_start_restore https://github.com/acme my-mac-homefield
record "a runner without the canonical platform labels cannot restore: the entry waits" "0/homefield-ci acme/api" \
  "$rc/$(cat "$state/autoflip" 2>/dev/null)"

reset_records
printf 'homefield-ci beta/web\n' >"$state/autoflip"
harness_env=(GH_CI_RUNNER=hosted GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n')
harness route_start_restore https://github.com/acme my-mac-homefield
record "a pending repo in another scope: left hosted, with a message" "0/yes/0" \
  "$rc/$(has "$out" 'routed under a different scope than acme')/$(grep -c 'variable set' "$calls" || true)"
record "...it stays in autoflip" "homefield-ci beta/web" "$(cat "$state/autoflip")"

reset_records
printf 'homefield-ci acme/api\n' >"$state/autoflip"
harness_env=(GH_CI_RUNNER=hosted GH_RUNNERS='44\tsomeone-else\tonline\tself-hosted\n')
harness route_start_restore https://github.com/acme my-mac-homefield
record "this runner is not in GitHub's list: nothing restored, exit 1" "1/yes/0" \
  "$rc/$(has "$out" 'not in GitHub')/$(grep -c 'variable set' "$calls" || true)"
record "...the entry waits" "homefield-ci acme/api" "$(cat "$state/autoflip")"

reset_records
printf 'homefield-ci acme/api\n' >"$state/autoflip"
harness_env=(GH_CI_RUNNER=hosted GH_RUNNERS_FAIL=1)
harness route_start_restore https://github.com/acme my-mac-homefield
record "GitHub cannot be asked: nothing restored, exit 1" "1/yes" \
  "$rc/$(has "$out" 'could not read the runners from GitHub')"
record "...the entry waits" "homefield-ci acme/api" "$(cat "$state/autoflip")"

reset_records
harness route_start_restore https://github.com/acme my-mac-homefield
record "nothing pending: a quiet exit 0 without asking GitHub" "0/yes/0" \
  "$rc/$(has "$out" 'no repository waiting')/$(grep -c 'actions/runners' "$calls" || true)"

echo
echo "seeding the records when the fallback is switched on"
reset_records
printf 'acme/api local\nacme/web hosted\nacme/old local\n' >"$work/byrepo"
harness_env=(GH_GROUP_REPOS='acme/api\nacme/web\nacme/old\n' GH_CI_RUNNER_BY_REPO="$work/byrepo")
harness seed_routing_records https://github.com/acme my-mac-homefield homefield-ci 7
record "seeding: the group's repositories already routed local are recorded" "0/2" \
  "$rc/$(grep -c . "$state/routing" 2>/dev/null || true)"
record "...under the given label, and only the local ones" "yes/no" \
  "$(grep -q 'homefield-ci acme/api' "$state/routing" && echo yes || echo no)/$(grep -q 'acme/web' "$state/routing" && echo yes || echo no)"

reset_records
harness_env=(GH_GROUP_REPOS='' GH_CI_RUNNER_BY_REPO="$work/byrepo")
harness seed_routing_records https://github.com/acme my-mac-homefield homefield-ci 7
record "the group's repositories cannot be listed: a warning, exit 1, no records" "1/yes/1" \
  "$rc/$(has "$out" 'could not list the runner group')/$([ -f "$state/routing" ] && echo 0 || echo 1)"

reset_records
harness_env=(GH_CI_RUNNER_BY_REPO="$work/byrepo")
harness seed_routing_records https://github.com/acme/api repo-runner homefield-ci
record "a repository-scoped registration: the registration's own repo is the candidate" "0/yes" \
  "$rc/$(grep -q 'homefield-ci acme/api' "$state/routing" && echo yes || echo no)"

reset_records
printf 'acme/api local\n' >"$work/byrepo"
harness_env=(GH_GROUP_REPOS='acme/api\n' GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n' GH_CI_RUNNER_BY_REPO="$work/byrepo")
harness seed_routing_records https://github.com/acme my-mac-homefield "" 7
record "without a label, the runner's routing label is derived from GitHub's list" "0/yes" \
  "$rc/$(grep -q 'homefield-ci acme/api' "$state/routing" && echo yes || echo no)"

reset_records
harness_env=(GH_GROUP_REPOS='acme/api\n' GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64\n' GH_CI_RUNNER_BY_REPO="$work/byrepo")
harness seed_routing_records https://github.com/acme my-mac-homefield
record "a runner with no custom label: nothing routes to it, nothing to seed" "0/yes" \
  "$rc/$(has "$out" 'nothing to seed')"

reset_records
printf 'acme/api local\n' >"$work/byrepo"
harness_env=(GH_RUNNERS='45\trepo-runner\tonline\tself-hosted,linux,arm64,homefield-ci\n' GH_CI_RUNNER_BY_REPO="$work/byrepo")
harness seed_routing_records https://github.com/acme/api repo-runner
record "a repo-scoped upgrade without a label: the label is derived from GitHub's list" "0/homefield-ci acme/api github.com" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"

reset_records
printf 'label-web acme/web\n' >"$state/routing"
printf 'acme/web local\n' >"$work/byrepo"
harness_env=(GH_GROUP_REPOS='acme/web\n' GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n' GH_CI_RUNNER_BY_REPO="$work/byrepo")
harness seed_routing_records https://github.com/acme my-mac-homefield homefield-ci 7
record "an already recorded repo keeps its own label (not this runner's)" "0/label-web acme/web" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"

reset_records
printf 'acme/web local\n' >"$work/byrepo"
harness_env=(GH_GROUP_REPOS='acme/web\n' GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n43\tother-mac\tonline\tself-hosted,linux,arm64,label-web\n' \
  GH_GROUPS='homefield-ci\tselected\tpublic\t7\n' GH_GROUP_RUNNERS='43\n' GH_CI_RUNNER_BY_REPO="$work/byrepo")
harness seed_routing_records https://github.com/acme my-mac-homefield homefield-ci 7
record "another runner with a different label can serve the repo: not recorded, exit 1" "1/yes/0" \
  "$rc/$(has "$out" 'not provably the only label')/$([ -f "$state/routing" ] && wc -l < "$state/routing" | tr -d ' ' || echo 0)"

reset_records
printf 'acme/web local\n' >"$work/byrepo"
harness_env=(GH_GROUP_REPOS='acme/web\n' GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n43\tother-mac\tonline\tself-hosted,linux,arm64,homefield-ci\n' \
  GH_GROUPS='homefield-ci\tselected\tpublic\t7\n' GH_GROUP_RUNNERS='43\n' GH_CI_RUNNER_BY_REPO="$work/byrepo")
harness seed_routing_records https://github.com/acme my-mac-homefield homefield-ci 7
record "another runner with the same label: no conflict, the repo is recorded" "0/homefield-ci acme/web github.com" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"

reset_records
printf 'acme/web local\n' >"$work/byrepo"
harness_env=(GH_GROUP_REPOS='acme/web\n' GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n43\tother-mac\tonline\tself-hosted,linux,x64,label-web\n' \
  GH_CI_RUNNER_BY_REPO="$work/byrepo")
harness seed_routing_records https://github.com/acme my-mac-homefield homefield-ci 7
record "a different-label runner that cannot take the jobs is no conflict: recorded" "0/homefield-ci acme/web github.com" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"

reset_records
printf 'acme/web local\n' >"$work/byrepo"
harness_env=(GH_GROUP_REPOS='acme/web\n' GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n43\tother-mac\tonline\tself-hosted,linux,arm64,label-web\n' \
  GH_GROUPS_FAIL=1 GH_CI_RUNNER_BY_REPO="$work/byrepo")
harness seed_routing_records https://github.com/acme my-mac-homefield homefield-ci 7
record "the other runner's group cannot be asked: fail safe, not recorded" "1/0" \
  "$rc/$([ -f "$state/routing" ] && wc -l < "$state/routing" | tr -d ' ' || echo 0)"

rm -f "$stubs/gh"

echo
echo "stop and start, through the real command"
cat >"$stubs/uname" <<'EOF'
#!/bin/sh
case "$1" in
  -s) echo Darwin ;;
  -m) echo arm64 ;;
esac
EOF
cat >"$stubs/sw_vers" <<'EOF'
#!/bin/sh
echo "26.6.2"
EOF
chmod +x "$stubs/uname" "$stubs/sw_vers"

# limactl: one VM, homefield; `shell` is the guest (registered, service, job).
cat >"$stubs/limactl" <<'EOF'
#!/usr/bin/env bash
echo "limactl $*" >>"$CALLS"
case "$1" in
  --version) echo "limactl version 2.3.0" ;;
  list) [ -z "${LIMA_STATUS:-}" ] || echo "homefield ${LIMA_STATUS}" ;;
  start) [ -z "${START_FAIL:-}" ] || { echo "limactl: could not start" >&2; exit 1; } ;;
  stop) [ -z "${STOP_FAIL:-}" ] || { echo "limactl: could not stop" >&2; exit 1; } ;;
  shell)
    shift 4
    [ "$1" != sudo ] || shift
    case "$1" in
      sh)
        script="$3"
        case "$script" in
          *'test -f'*) [ "${REG:-0}" = 0 ] && echo yes || echo no ;;
          *pgrep*) [ "${JOB:-no}" = yes ] && echo yes || echo no ;;
        esac
        ;;
      python3) printf '%b' "${SETTING_OUT-}" ;;
      cat)
        case "$2" in
          */.service) [ -z "${SVC_NAME:-}" ] || printf '%s' "$SVC_NAME" ;;
          *) echo "limactl stub: unexpected cat: $*" >&2; exit 99 ;;
        esac
        ;;
      systemctl) exit "${SVC_ACTIVE:-0}" ;;
      *) echo "limactl stub: unexpected guest command: $*" >&2; exit 99 ;;
    esac
    ;;
  *) echo "limactl stub: unexpected: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$stubs/limactl"

# The gh stub again, now with the runners list the fallback reads.
cat >"$stubs/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$CALLS"
case "$*" in
  *"actions/runners?per_page="*)
    [ -z "${GH_RUNNERS_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    case "$*" in
      # the fallback/restore's label lookup (runners_on_github)
      *"map(.name)"*) printf '%b' "${GH_RUNNERS_NAMED-${GH_RUNNERS-}}" ;;
      # the online check's [id, status, busy] rows
      *) printf '%b' "${GH_RUNNERS-}" ;;
    esac ;;
  "variable get"*)
    repo=""
    all="$*"
    case "$all" in *"--repo "*) repo="${all#*--repo }" ;; esac
    repo="${repo%% *}"
    # gh's --repo takes [HOST/]OWNER/REPO; the fixture is keyed by OWNER/REPO.
    repo="${repo#github.com/}"
    if [ -n "${GH_CI_RUNNER_BY_REPO:-}" ]; then
      v="$(awk -v r="$repo" '$1 == r {print $2; exit}' "$GH_CI_RUNNER_BY_REPO" 2>/dev/null)"
      [ -n "$v" ] && { echo "$v"; exit 0; }
    fi
    if [ -n "${GH_CI_RUNNER:-}" ]; then echo "$GH_CI_RUNNER"; else echo "variable not found" >&2; exit 1; fi
    ;;
  "variable set"*) ;;
  *"actions/runner-groups/"*"repositories"*)
    printf '%b' "${GH_GROUP_REPOS-}" ;;
  *"actions/runs?status=queued"*) ;;
  *"actions/runs?status=in_progress"*) ;;
  *"/actions/runs/"*"/jobs"*) ;;
  "run view"*) echo "${GH_RUN_STATUS:-completed}" ;;
  "run cancel"*) ;;
  "run rerun"*) ;;
  *) echo "gh stub: unexpected: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$stubs/gh"

settings='my-mac-homefield\nhttps://github.com/acme\n42\n'
stop_env=(LIMA_STATUS=Running REG=0 SETTING_OUT="$settings" SVC_NAME='actions.runner.acme.test.service')

hf() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : >"$calls"
  out="$(env -i HOME="$work/home" PATH="$stubs" CALLS="$calls" \
    HOMEFIELD_STATE_DIR="$state" HOMEFIELD_GH_TIMEOUT=5 ROUTE_TRIES=1 ROUTE_INTERVAL=0 \
    ${envs[@]+"${envs[@]}"} "$BASH_BIN" "$ROOT/bin/homefield" "$@" 2>"$work/err" </dev/null)"
  rc=$?
  err="$(cat "$work/err")"
}

printf 'homefield-ci acme/api\n' >"$state/routing"
hf "${stop_env[@]}" GH_RUNNERS="$runner_rows" -- stop --route-hosted
record "stop --route-hosted: the repo is flipped, the VM stops, exit 0" "0/yes/yes/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)/$(grep -q '^limactl stop homefield' "$calls" && echo yes || echo no)/$(has "$out" 'VM homefield: Stopped')"
record "...the flipped repo waits in autoflip" "homefield-ci acme/api github.com" "$(cat "$state/autoflip" 2>/dev/null)"

hf "${stop_env[@]}" GH_RUNNERS="$runner_rows" -- stop
record "plain stop without the switch: no flip" "0/0/yes" \
  "$rc/$(grep -c 'variable set' "$calls" || true)/$(has "$out" 'VM homefield: Stopped')"

printf 'homefield-ci acme/api\n' >"$state/routing"
printf 'auto_route=1\n' >"$state/homefield.state"
hf "${stop_env[@]}" GH_RUNNERS="$runner_rows" -- stop
record "auto_route=1: plain stop runs the fallback" "0/yes/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)/$(has "$out" 'VM homefield: Stopped')"

printf 'auto_route=0\n' >"$state/homefield.state"
printf 'homefield-ci acme/api\n' >"$state/routing"
hf "${stop_env[@]}" GH_RUNNERS="$runner_rows" -- stop
record "auto_route=0: plain stop does not" "0/0" "$rc/$(grep -c 'variable set' "$calls" || true)"
rm -f "$state/homefield.state"

hf "${stop_env[@]}" JOB=yes -- stop --route-hosted
record "a live job: refused, and GitHub is not asked" "1/0/yes" \
  "$rc/$(grep -c 'actions/runners' "$calls" || true)/$(has "$err" 'a job is running on homefield')"

printf 'homefield-ci acme/api\n' >"$state/routing"
hf "${stop_env[@]}" GH_RUNNERS_FAIL=1 -- stop --route-hosted
record "GitHub cannot be asked: the stop still happens, exit 1" "1/yes/yes/yes" \
  "$rc/$(has "$err" 'could not read the runners from GitHub')/$(grep -q '^limactl stop homefield' "$calls" && echo yes || echo no)/$(has "$out" 'VM homefield: Stopped')"

printf 'homefield-ci acme/api\n' >"$state/routing"
hf "${stop_env[@]}" GH_RUNNERS="$runner_rows" STOP_FAIL=1 -- stop --route-hosted
record "limactl stop fails: exit 1, the flip already happened" "1/yes/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)/$(has "$err" 'could not stop VM homefield')"

hf "${stop_env[@]}" -- stop --bogus
record "an unknown option: refused, nothing stopped" "1/yes/0" \
  "$rc/$(has "$err" 'stop takes no options besides --instance and --route-hosted')/$(grep -c '^limactl stop' "$calls" || true)"

# start: restore from autoflip once the runner takes jobs.
named_rows='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n'
start_env=(LIMA_STATUS=Stopped REG=0 SETTING_OUT="$settings" SVC_NAME='actions.runner.acme.test.service' \
  GH_RUNNERS='42\tonline\tfalse\n' GH_RUNNERS_NAMED="$named_rows")

printf 'homefield-ci acme/api\n' >"$state/autoflip"
hf "${start_env[@]}" -- start --route-local
record "start --route-local: the pending repo is routed back, exit 0" "0/yes/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body local' "$calls" && echo yes || echo no)/$(has "$out" 'taking jobs: yes')"
record "...the entry leaves autoflip" "0" "$([ -f "$state/autoflip" ] && wc -l <"$state/autoflip" | tr -d ' ' || echo 0)"
record "...and the repo is recorded as routed local" "homefield-ci acme/api github.com" "$(cat "$state/routing" 2>/dev/null)"

printf 'homefield-ci acme/api\n' >"$state/autoflip"
hf LIMA_STATUS=Stopped REG=0 SETTING_OUT="$settings" SVC_NAME='actions.runner.acme.test.service' GH_RUNNERS='42\toffline\tfalse\n' GH_RUNNERS_NAMED="$named_rows" -- start --route-local
record "start, but not online: nothing is restored, exit 1" "1/0/yes" \
  "$rc/$(grep -c 'variable set' "$calls" || true)/$(grep -q acme/api "$state/autoflip" && echo yes || echo no)"

printf 'auto_route=1\n' >"$state/homefield.state"
printf 'homefield-ci acme/api\n' >"$state/autoflip"
hf "${start_env[@]}" -- start
record "auto_route=1: plain start restores" "0/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body local' "$calls" && echo yes || echo no)"
rm -f "$state/homefield.state"

hf "${start_env[@]}" -- start --bogus
record "an unknown start option: refused" "1/yes" \
  "$rc/$(has "$err" 'start takes no options besides --instance and --route-local')"

echo
echo "the --auto-route switch on install and upgrade"
cat >"$stubs/scutil" <<'EOF'
#!/bin/sh
echo "Test-Mac"
EOF
chmod +x "$stubs/scutil"

IHARNESS="$work/iharness.sh"
cat >"$IHARNESS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HOMEFIELD_SOURCE_ONLY=1
. "$ROOT/bin/homefield"
check_host() { :; }
verify_isolation() { :; }
ensure_vm() { :; }
enable_autostart() { :; }
cmd_preflight() { return 0; }
ensure_group() { GROUP_STATE=narrow; GROUP_ID="${STUB_GROUP_ID-7}"; }
check_name_free() { :; }
remove_taken_name() { :; }
get_token() { printf 'stub-tok-123\n'; }
run_provision() {
  local input="$1"; shift
  echo "run_provision:cmd=${PROVISION_CMD:-default}:input=${input//$'\n'/ }:env=$*" >>"$CALLS"
}
runner_setting() {
  for k in "$@"; do
    case "$k" in
      agentName) echo "test-mac-homefield" ;;
      agentId) echo "41" ;;
      gitHubUrl) echo "https://github.com/acme" ;;
    esac
  done
}
wait_online() { :; }
warm_vm() { :; }
is_job_running() { return 1; }
# 1 (the default) is a fresh install; 0 is the registered path the upgrade
# tests exercise.
is_registered() { return "${STUB_REG:-1}"; }
runner_service_state() { return 0; }
stop_runner() { echo stop_runner >>"$CALLS"; }
runner_back() { :; }
"$@"
EOF
iharness() {
  : >"$calls"
  out="$(env -i HOME="$work/home" PATH="$stubs" CALLS="$calls" ROOT="$ROOT" \
    HOMEFIELD_STATE_DIR="$state" LIMA_STATUS=Running GH_RUNNERS='41\tonline\tfalse\n' \
    ${iharness_env[@]+"${iharness_env[@]}"} "$BASH_BIN" "$IHARNESS" "$@" 2>&1 </dev/null)"
  rc=$?
}
iharness_env=()

rm -f "$state/routing"
printf 'acme/api local\nacme/web hosted\n' >"$work/byrepo-install"
iharness_env=(GH_GROUP_REPOS=$'acme/api\nacme/web\n' GH_CI_RUNNER_BY_REPO="$work/byrepo-install")
iharness cmd_install --url https://github.com/acme --org --auto-route
record "install --auto-route: the switch is saved on" "0/1" \
  "$rc/$(state_value auto_route)"
record "...and the records are seeded from the group's already-local repositories" "homefield-ci acme/api github.com" \
  "$(cat "$state/routing" 2>/dev/null)"
iharness_env=()

rm -f "$state/routing"
printf 'acme/api local\n' >"$work/byrepo-install"
iharness_env=(STUB_GROUP_ID= GH_GROUP_REPOS=$'acme/api\n' GH_CI_RUNNER_BY_REPO="$work/byrepo-install" GH_RUNNERS_NAMED='46\ttest-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n')
iharness cmd_install --url https://github.com/acme --org --auto-route
record "install --auto-route without a group id: the fallback says what is missing" "0/yes/1" \
  "$rc/$(has "$out" 'could not list the runner group')/$([ -f "$state/routing" ] && echo 0 || echo 1)"
iharness_env=()

rm -f "$state/routing"
printf 'acme/api local\n' >"$work/byrepo-install"
iharness_env=(GH_GROUP_REPOS=$'acme/api\n' GH_CI_RUNNER_BY_REPO="$work/byrepo-install" GH_RUNNERS_NAMED='46\ttest-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n')
iharness cmd_install --url https://github.com/acme/api --auto-route
record "a repository-scoped install --auto-route: the registration's repo is seeded" "0/homefield-ci acme/api github.com" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"
iharness_env=()
rm -f "$state/homefield.state"
iharness cmd_install --url https://github.com/acme --org
record "plain install: the switch is saved off" "0/0" \
  "$rc/$(state_value auto_route)"

printf 'auto_route=1\n' >"$state/homefield.state"
printf 'group_created=acme/homefield-ci/7\n' >>"$state/homefield.state"
rm -f "$state/routing"
printf 'acme/api local\n' >"$work/byrepo-up"
iharness_env=(STUB_REG=0 GH_GROUP_REPOS=$'acme/api\n' GH_CI_RUNNER_BY_REPO="$work/byrepo-up" \
  GH_RUNNERS_NAMED='46\ttest-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n')
iharness cmd_upgrade --auto-route
record "upgrade --auto-route on an existing install: the records are seeded, label derived" "0/1/homefield-ci acme/api github.com" \
  "$rc/$(grep -c . "$state/routing" 2>/dev/null || true)/$(cat "$state/routing" 2>/dev/null)"
iharness_env=(STUB_REG=0)
iharness cmd_upgrade --no-auto-route
record "upgrade --no-auto-route: the switch is saved off" "0/0" \
  "$rc/$(state_value auto_route)"
printf 'auto_route=0\n' >"$state/homefield.state"
iharness cmd_upgrade --auto-route
record "upgrade --auto-route: the switch is saved on" "0/1" \
  "$rc/$(state_value auto_route)"
iharness cmd_upgrade --bogus-flag
iharness_env=()
record "an unknown upgrade option: refused" "1/yes" "$rc/$(has "$out" 'unknown option')"

summary