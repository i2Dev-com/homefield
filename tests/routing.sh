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
# is on the stubs' PATH from the start. python3 is the route watcher's
# power-event helper (its --auto-route check refuses without it).
for t in awk bash cat dirname grep mktemp mkdir mv rm sed sleep tr python3; do ln -s "$(command -v "$t")" "$stubs/$t"; done

# CLOCK_EPOCH: the suite's clock. The scaler and the route watcher read the
# time through `date`, and so do the fixtures that must be fresh or overdue
# relative to it — a suspended or delayed test process would otherwise turn
# a fresh fixture into an overdue one (tests never observe ambient host
# time). Every date call in the code under test reads CLOCK_EPOCH, and the
# fixtures below are written relative to the same constant.
CLOCK_EPOCH=1700000000
cat >"$stubs/date" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "+%s") printf '%s\n' "${CLOCK_EPOCH:?CLOCK_EPOCH not set}" ;;
  "+%Y-%m-%d %H:%M:%S") printf '2023-11-14 22:13:20\n' ;;
  *) echo "date stub: unsupported format: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$stubs/date"

# launchctl: the route watcher agent's load and unload, recorded.
cat >"$stubs/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "launchctl $*" >>"$CALLS"
exit 0
EOF
chmod +x "$stubs/launchctl"

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
    # The interrupted-flip probe (#290's review): when set, record whether the
    # repo's autoflip entry is on disk at the moment the stuck-run recovery's
    # wait loop starts — the kill-during-recovery case must find it there.
    if [ -n "${GH_RUNVIEW_PROBE_REPO:-}" ]; then
      if grep -q "$GH_RUNVIEW_PROBE_REPO" "$STATE_DIR/autoflip" 2>/dev/null; then
        echo present >>"$PROBE_FILE"
      else
        echo absent >>"$PROBE_FILE"
      fi
    fi
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
record "route local: the repo is recorded under its label" "0/homefield-ci acme/api github.com pull_request hosted guards" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"
record "...the variable was set, and nothing waits in autoflip" "yes/0" \
  "$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body local' "$calls" && echo yes || echo no)/$(wc -l <"$state/autoflip" 2>/dev/null | tr -d ' ' || echo 0)"

harness cmd_route local --repo acme/api --label other-label
record "route local on another label: the repo's line is replaced" "0/other-label acme/api github.com pull_request hosted guards" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"

# The option fields (#315): the flags write the consumer's guard options
# into the record, and the values are the guard's own — the demand side
# reads them as the expression's exclusions.
reset_records
harness_env=(GH_CI_RUNNER=hosted)
harness cmd_route local --repo acme/api --label homefield-ci --events push,pull_request --dependabot local
record "route local: the flags land in the record" "0/homefield-ci acme/api github.com push,pull_request local guards" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"
harness cmd_route local --repo acme/api --label homefield-ci --events 'push schedule'
record "route local: a space-separated list canonicalizes to one comma field" \
  "0/homefield-ci acme/api github.com push,schedule hosted guards" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"
harness cmd_route local --repo acme/api --label homefield-ci --mode simple
record "route local: --mode simple records the mode" "0/homefield-ci acme/api github.com pull_request hosted simple" \
  "$rc/$(cat "$state/routing" 2>/dev/null)"

# --profile unknown records the legacy three-field shape: the profile is
# not known, and the demand side stays permissive until it is recorded.
# It refuses to carry options — an unknown profile with a guessed events
# list would be neither unknown nor precise.
reset_records
harness_env=(GH_CI_RUNNER=hosted)
harness cmd_route local --repo acme/api --label homefield-ci --profile unknown
record "route local: --profile unknown records the legacy three-field shape" \
  "0/homefield-ci acme/api github.com" "$rc/$(cat "$state/routing" 2>/dev/null)"
harness cmd_route local --repo acme/api --label homefield-ci --profile unknown --events push
record "route local: --profile unknown refuses to carry options" "1" "$rc"
harness cmd_route local --repo acme/api --label homefield-ci --profile wrong
record "route local: a profile outside the two is refused" "1" "$rc"

reset_records
harness cmd_route local --repo acme/api --events pull_request_target
record "route local: pull_request_target is refused" "1/yes" \
  "$rc/$(has "$out" 'never routable')"
harness cmd_route local --repo acme/api --events merge_group
record "route local: an event the guard cannot route is refused" "1" "$rc"
harness cmd_route local --repo acme/api --dependabot sometimes
record "route local: a dependabot value outside the guard's is refused" "1" "$rc"
harness cmd_route local --repo acme/api --mode full
record "route local: a mode outside the guard's is refused" "1" "$rc"
harness cmd_route local --repo acme/api --mode simple --events push
record "route local: --events has no effect in simple mode and is refused" "1" "$rc"
record "...and a refusal records nothing" "0" \
  "$(wc -l <"$state/routing" 2>/dev/null | tr -d ' ' || echo 0)"

# The route command's option values are the routing-guard's own: the lists
# must not drift (the same pin tests/label-rule.sh applies to the labels).
guard_list() {
  sed -n "s/^$1 = (\(.*\))\$/\1/p" "$ROOT/routing-guard/routing_guard.py" | tr -d '" ' | tr ',' ' '
}
route_list() {
  sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$ROOT/bin/cmd-route.sh"
}
record "the route command's events are the guard's" \
  "$(guard_list EVENTS | tr ' ' '\n' | sort | tr '\n' ' ')" \
  "$(route_list ROUTE_EVENTS | tr ' ' '\n' | sort | tr '\n' ' ')"
record "the route command's dependabot values are the guard's" \
  "$(guard_list DEPENDABOT | tr ' ' '\n' | sort | tr '\n' ' ')" \
  "$(route_list ROUTE_DEPENDABOT | tr ' ' '\n' | sort | tr '\n' ' ')"
record "the route command's modes are the guard's" \
  "$(guard_list MODES | tr ' ' '\n' | sort | tr '\n' ' ')" \
  "$(route_list ROUTE_MODE | tr ' ' '\n' | sort | tr '\n' ' ')"

# A Mac may host runners for the same owner/repo on github.com and a GHES
# host: the records must not mix them (#287, Codex #295 round 2).
reset_records
printf 'homefield-ci acme/api ghes.acme.example\n' >"$state/routing"
harness cmd_route local --repo acme/api --label other-label
record "route local for a repo recorded on another host: a github.com line is added beside it" "0/homefield-ci acme/api ghes.acme.example
other-label acme/api github.com pull_request hosted guards" \
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
record "a local route clears the pending restore it supersedes" "0/label-b acme/api github.com pull_request hosted guards/0" \
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

# Hosted runners exist on github.com and the *.ghe.com data-residency
# subdomains (Linux and Windows; macOS is the only kind missing there), not on
# a GitHub Enterprise Server (#287, Codex #295 round 3).
reset_records
harness_env=(GH_CI_RUNNER=local HOMEFIELD_GITHUB_HOST=ghes.acme.example)
harness cmd_route hosted --repo acme/api --label homefield-ci
record "route hosted on a GHES host: refused, nothing set" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" "hosted runners do not exist on ghes.acme.example")/$(grep -c 'variable set' "$calls" || true)"
reset_records
harness_env=(GH_CI_RUNNER=local HOMEFIELD_GITHUB_HOST=acme.ghe.com)
harness cmd_route hosted --repo acme/api --label homefield-ci
record "route hosted on a GHE.com host: allowed, the variable is set" "0/1/no" \
  "$rc/$(grep -c 'variable set CI_RUNNER --repo acme.ghe.com/acme/api --body hosted' "$calls" || true)/$(grep -q acme/api "$state/autoflip" 2>/dev/null && echo yes || echo no)"

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

# A six-field routing record's option fields ride into the autoflip entry,
# so the wake side's demand filter reads the consumer's guard options (#315).
reset_records
printf 'homefield-ci acme/api github.com push local guards\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows")
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "a six-field record: the flip carries the options into autoflip" "0/yes/homefield-ci acme/api github.com push local guards" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)/$(cat "$state/autoflip" 2>/dev/null)"

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

# A flip killed during the stuck-run recovery — the watcher's sleep budget
# killing an overrunning flip — must leave the restore intent on disk: the
# variable has landed, so a repo in neither record could never be brought
# back by a start or a wake. The entry is persisted before the recovery, so
# the probe (the recovery's first wait-loop step) must find it there.
reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
probe="$work/probe"
: >"$probe"
harness_env=(GH_RUNNERS="$runner_rows" GH_RUNS='123\n' GH_JOBS='5\n' \
  GH_RUNVIEW_PROBE_REPO=acme/api PROBE_FILE="$probe")
harness route_stop_fallback https://github.com/acme my-mac-homefield
record "a flip killed mid-recovery would find the entry on disk already: it is persisted before the recovery" "present/yes/no/1" \
  "$(cat "$probe" 2>/dev/null)/$(grep -q acme/api "$state/autoflip" 2>/dev/null && echo yes || echo no)/$(grep -q acme/api "$state/routing" 2>/dev/null && echo yes || echo no)/$(grep -c 'variable set' "$calls" || true)"
rm -f "$probe"

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

# Hosted runners exist on a GHE.com host (Linux and Windows), so the
# stop-side fallback runs there as on github.com; a GitHub Enterprise Server
# has none, so it skips (the stop itself still happens).
reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows")
harness route_stop_fallback https://ghes.acme.example/acme my-mac-homefield
record "the stop-side fallback on a GHES host: skipped, nothing flipped" "0/yes/0" \
  "$rc/$(has "$out" 'which ghes.acme.example does not have')/$(grep -c 'variable set' "$calls" || true)"

reset_records
printf 'homefield-ci acme/api\n' >"$state/routing"
harness_env=(GH_RUNNERS="$runner_rows")
harness route_stop_fallback https://acme.ghe.com/acme my-mac-homefield
record "the stop-side fallback on a GHE.com host: the flip runs and waits in autoflip" "0/1/homefield-ci acme/api acme.ghe.com" \
  "$rc/$(grep -c 'variable set CI_RUNNER --repo acme.ghe.com/acme/api --body hosted' "$calls" || true)/$(cat "$state/autoflip" 2>/dev/null)"

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

# A six-field autoflip entry reads the same: the host is still the third
# field, and the option fields ride along untyped (#315).
reset_records
printf 'homefield-ci acme/api github.com push local guards\n' >"$state/autoflip"
harness_env=(GH_CI_RUNNER=hosted GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n')
harness route_start_restore https://github.com/acme my-mac-homefield
record "a six-field entry: the restore lands and the entry leaves autoflip" "0/yes/0" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body local' "$calls" && echo yes || echo no)/$([ -f "$state/autoflip" ] && wc -l <"$state/autoflip" | tr -d ' ' || echo 0)"
record "...and the options survive the restore into the routing record" \
  "homefield-ci acme/api github.com push local guards" "$(cat "$state/routing" 2>/dev/null)"

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

# The gid comes from the group_created record when the caller does not know
# it: org/group/id/host since the host support, org/group/id before it.
reset_records
printf 'group_created=acme/homefield-ci/7/github.com\n' >"$state/homefield.state"
printf 'acme/api local\n' >"$work/byrepo"
harness_env=(GH_RUNNERS="$runner_rows" GH_CI_RUNNER_BY_REPO="$work/byrepo" GH_GROUP_REPOS='acme/api\n')
harness seed_routing_records https://github.com/acme my-mac-homefield
record "the gid read from a host-carrying group_created record: the group's repositories are enumerated" "0/yes/homefield-ci acme/api github.com" \
  "$rc/$(grep -q 'actions/runner-groups/7/repositories' "$calls" && echo yes || echo no)/$(cat "$state/routing" 2>/dev/null)"
reset_records
printf 'group_created=acme/homefield-ci/7\n' >"$state/homefield.state"
harness_env=(GH_RUNNERS="$runner_rows" GH_CI_RUNNER_BY_REPO="$work/byrepo" GH_GROUP_REPOS='acme/api\n')
harness seed_routing_records https://github.com/acme my-mac-homefield
record "...and from a legacy three-field record" "0/yes/homefield-ci acme/api github.com" \
  "$rc/$(grep -q 'actions/runner-groups/7/repositories' "$calls" && echo yes || echo no)/$(cat "$state/routing" 2>/dev/null)"

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
  list)
    # LIMA_ROWS: a multi-VM Mac (the watcher's fleet tests); otherwise one VM.
    if [ -n "${LIMA_ROWS:-}" ]; then printf '%b' "$LIMA_ROWS"
    else [ -z "${LIMA_STATUS:-}" ] || echo "homefield ${LIMA_STATUS}"
    fi ;;
  start) [ -z "${START_FAIL:-}" ] || { echo "limactl: could not start" >&2; exit 1; } ;;
  stop) [ -z "${STOP_FAIL:-}" ] || { echo "limactl: could not stop" >&2; exit 1; } ;;
  shell)
    # guest() calls: limactl shell --workdir / <vm> [--] <through> <cmd> ...
    vm="$4"
    shift 4
    [ "$1" != sudo ] || shift
    case "$1" in
      sh)
        script="$3"
        case "$script" in
          *'test -f'*) [ "${REG:-0}" = 0 ] && echo yes || echo no ;;
          *pgrep*)
            [ -z "${PGREP_FAIL:-}" ] || exit 2
            if [ -n "${JOBS_DIR:-}" ]; then [ -f "$JOBS_DIR/$vm" ] && echo yes || echo no
            else [ "${JOB:-no}" = yes ] && echo yes || echo no
            fi ;;
          # the demand scaler's reads of the primary's guest (#291): the
          # saved extra packages, and the provisioning hooks it carries
          # (per-VM: one VM carries hooks, another does not)
          *extra-packages*) [ -n "${EXTRA_PKGS:-}" ] && printf '%s\n' "$EXTRA_PKGS" || : ;;
          *provision.d*)
            case "$vm" in
              second) printf '%b' "${HOOKS_LIST_SECOND-}" ;;
              *) printf '%b' "${HOOKS_LIST-}" ;;
            esac ;;
        esac
        ;;
      python3)
        # SETTINGS_DIR: per-VM settings for a multi-VM Mac; otherwise the one
        # SETTING_OUT every VM answers with.
        if [ -n "${SETTINGS_DIR:-}" ] && [ -f "$SETTINGS_DIR/$vm" ]; then cat "$SETTINGS_DIR/$vm"
        else printf '%b' "${SETTING_OUT-}"
        fi ;;
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
  # the demand scaler's group-admission check (#299): a per-group override,
  # so a fixture can put runner 42 in a group that excludes the queued repo
  # and runner 43 in one that admits it
  *"runner-groups/7/runners"*) printf '%b' "${GH_GROUP_RUNNERS_7:-${GH_GROUP_RUNNERS-}}" ;;
  *"runner-groups/8/runners"*) printf '%b' "${GH_GROUP_RUNNERS_8:-${GH_GROUP_RUNNERS-}}" ;;
  *"runner-groups/7/repositories"*) printf '%b' "${GH_GROUP_REPOS_7:-${GH_GROUP_REPOS-}}" ;;
  *"runner-groups/8/repositories"*) printf '%b' "${GH_GROUP_REPOS_8:-${GH_GROUP_REPOS-}}" ;;
  *"actions/runner-groups/"*"repositories"*)
    printf '%b' "${GH_GROUP_REPOS-}" ;;
  *"actions/runner-groups/"*"runners"*)
    printf '%b' "${GH_GROUP_RUNNERS-}" ;;
  *"actions/runner-groups?per_page="*)
    # orgs/<repo>/... is not a valid endpoint: a repository-scoped
    # registration's owner is "owner/repo", and only the scaler's group
    # check could reach it (route's checks are scope-aware). Fail the way
    # GitHub does so a fixture cannot hide that mistake.
    case "$*" in
      *"orgs/"*"/"*/"actions/runner-groups"*) echo "gh: HTTP 404" >&2; exit 1 ;;
    esac
    [ -z "${GH_GROUPS_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    printf '%b' "${GH_GROUPS-}" ;;
  *"actions/runs?status=queued"*)
    # [id, created_at] rows: the demand scaler's wait lookup (#291); the
    # stuck-run lookup reads .workflow_runs[].id from the same fixture shape.
    [ -z "${GH_RUNS_FAIL:-}" ] || { echo "gh: HTTP 500" >&2; exit 1; }
    printf '%b' "${GH_RUNS-}" ;;
  *"actions/runs?status=in_progress"*)
    [ -z "${GH_RUNS_FAIL:-}" ] || { echo "gh: HTTP 500" >&2; exit 1; }
    printf '%b' "${GH_RUNS_IN_PROGRESS-}" ;;
  *"/actions/runs/"*"/jobs"*)
    [ -z "${GH_JOBS_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    printf '%b' "${GH_JOBS-}" ;;
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
    HOMEFIELD_STATE_DIR="$state" HOMEFIELD_GH_TIMEOUT=5 ROUTE_TRIES=1 ROUTE_INTERVAL=0 CLOCK_EPOCH="$CLOCK_EPOCH" \
    ${envs[@]+"${envs[@]}"} "$BASH_BIN" "$ROOT/bin/homefield" "$@" 2>"$work/err" </dev/null)"
  rc=$?
  err="$(cat "$work/err")"
}

# sysctl: the host's cores and memory, for the scaler's headroom budget —
# driven from the test the same way every outside effect is.
cat >"$stubs/sysctl" <<'EOF'
#!/usr/bin/env bash
# A 16-core, 32 GiB Mac by default: room for the tests' 6 vCPU / 5 GiB primary
# plus one more of the same, with the runbook's 2 cores and 8 GiB to spare.
case "$2" in
  hw.ncpu) echo "${SYSCTL_CPUS:-16}" ;;
  hw.memsize) echo "${SYSCTL_MEM:-34359738368}" ;;
  *) echo "sysctl stub: unexpected: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$stubs/sysctl"

# ── the scaler's tick harness: the real modules, scale_exec recorded ────────
# The tick runs the real bin/homefield's functions, but not its subprocesses:
# scale_exec (the scaler's only way to create, start or stop a VM) is replaced
# by a recorder, so a test can assert the exact command the scaler would run
# without building a VM. The integration test below runs the real one.
THARNESS="$work/tharness.sh"
cat >"$THARNESS" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
HOMEFIELD_SOURCE_ONLY=1
HOMEFIELD_STATE_DIR="$STATE_DIR"
INSTANCE="homefield"
. "$ROOT/bin/homefield"
adopt_nap() { :; }
scale_exec() {
  echo "scale_exec $*" >>"$CALLS"
  [ -z "${SCALE_RC:-}" ] || return "$SCALE_RC"
  return 0
}
"$@"
EOF
tharness() {
  : >"$calls"
  out="$(env -i HOME="$work/home" PATH="$stubs" CALLS="$calls" ROOT="$ROOT" STATE_DIR="$state" \
    HOMEFIELD_STATE_DIR="$state" HOMEFIELD_GH_TIMEOUT=5 CLOCK_EPOCH="$CLOCK_EPOCH" \
    ${tharness_env[@]+"${tharness_env[@]}"} "$BASH_BIN" "$THARNESS" "$@" 2>"$work/err" </dev/null)"
  rc=$?
  err="$(cat "$work/err")"
}
tharness_env=()
# lima_for <name> <status>: a VM Lima lists and a stored config for: the
# marker line first (vm_instances' HomeField check), then the size the
# scaler's budget and secondary installs read.
# lima_for <name> [cpus] [memory]: a VM Lima lists and a stored config for:
# the marker line first (vm_instances' HomeField check), then the size the
# scaler's budget and secondary installs read.
lima_for() {
  mkdir -p "$work/home/.lima/$1"
  printf '# Lima VM for the local GitHub Actions runner.\ncpus: %s\nmemory: %s\n' \
    "${2:-6}" "${3:-5GiB}" >"$work/home/.lima/$1/lima.yaml"
}
# tick_env: the common fixture set: one Running VM whose runner serves
# homefield-ci on github.com, one queued run that has waited long enough (a
# created_at of 2020 is older than any threshold the tests set).
tick_env() {
  lima_for homefield 6 5GiB
  mkdir -p "$work/settings"
  printf 'my-mac-homefield\nhttps://github.com/acme\n42\n' >"$work/settings/homefield"
  printf 'homefield-ci acme/api github.com\n' >"$state/routing"
  printf 'auto_route=1\n' >"$state/homefield.state"
  tharness_env=(
    LIMA_ROWS='homefield Running\n'
    LIMA_HOME="$work/home/.lima"
    SETTINGS_DIR="$work/settings"
    JOBS_DIR="$work/jobs"
    GH_RUNNERS=$'42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n'
    GH_GROUPS=$'Default\tselected\tfalse\t1\n'
    GH_GROUP_RUNNERS='42\n'
    GH_GROUP_REPOS='acme/api\n'
    GH_RUNS='9001\t2020-01-01T00:00:00Z\n'
    GH_JOBS='5\n'
    HOMEFIELD_SCALE_WAIT=10 HOMEFIELD_SCALE_IDLE=100
  )
}
# th_state <key>: the tick record's value for the key.
th_state() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$state/route-watcher/scale-state" 2>/dev/null; }

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
echo "the sleep/wake watcher"

# watcher_state_value <key>: the per-Mac run record's value (the watcher's
# own state file, in its subdirectory of the state directory).
watcher_state_value() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$state/route-watcher/state" 2>/dev/null; }

# sleep: one Running VM, idle, the automatic fallback on, one repo routed
# local under the runner's label. Jobs are queued (JOB=no), GitHub lists the
# runner online (the still-served check must skip it by name).
sleep_env=(LIMA_STATUS=Running REG=0 SETTING_OUT="$settings" SVC_NAME='actions.runner.acme.test.service' JOB=no)

printf 'auto_route=1\n' >"$state/homefield.state"
printf 'homefield-ci acme/api\n' >"$state/routing"
rm -f "$state/autoflip"
hf "${sleep_env[@]}" GH_RUNNERS="$runner_rows" -- route-watch sleep
record "route-watch sleep, jobs queued: the repo is flipped to hosted, the VM is not stopped, exit 0" "0/yes/no/no" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)/$(grep -q '^limactl stop' "$calls" && echo yes || echo no)/$(has "$out" 'VM homefield: Stopped')"
record "...the flipped repo waits in autoflip" "homefield-ci acme/api github.com" "$(cat "$state/autoflip" 2>/dev/null)"
record "...the run is recorded" "sleep/ok" "$(watcher_state_value last_mode)/$(watcher_state_value last_result)"

printf 'homefield-ci acme/api\n' >"$state/routing"
rm -f "$state/autoflip"
hf "${sleep_env[@]}" JOB=yes -- route-watch sleep
record "route-watch sleep, a job running: skipped, the records are untouched, exit 0" "0/0/yes" \
  "$rc/$(grep -c 'variable set' "$calls" || true)/$(has "$out" 'a job is running')"
record "...nothing waits in autoflip" "0" "$([ -f "$state/autoflip" ] && wc -l <"$state/autoflip" | tr -d ' ' || echo 0)"

printf 'homefield-ci acme/api\n' >"$state/routing"
rm -f "$state/autoflip"
hf "${sleep_env[@]}" PGREP_FAIL=1 -- route-watch sleep
record "route-watch sleep, the VM cannot be asked: fail safe, nothing flips, exit 1" "1/0/yes" \
  "$rc/$(grep -c 'variable set' "$calls" || true)/$(has "$err" 'could not ask whether a job is running')"
record "...the routing record is untouched" "homefield-ci acme/api" "$(cat "$state/routing")"
record "...the failed run is recorded" "sleep/failed" "$(watcher_state_value last_mode)/$(watcher_state_value last_result)"

printf 'auto_route=0\n' >"$state/homefield.state"
printf 'homefield-ci acme/api\n' >"$state/routing"
hf "${sleep_env[@]}" GH_RUNNERS="$runner_rows" -- route-watch sleep
record "route-watch sleep, auto_route=0: the VM's routing is left alone" "0/0" \
  "$rc/$(grep -c 'variable set' "$calls" || true)"
printf 'auto_route=1\n' >"$state/homefield.state"

# wake: the VM is down (it does not survive sleep cleanly), one repo waits in
# autoflip, GitHub lists the runner online once it is up.
printf 'homefield-ci acme/api\n' >"$state/autoflip"
hf LIMA_STATUS=Stopped REG=0 SETTING_OUT="$settings" SVC_NAME='actions.runner.acme.test.service' \
  GH_RUNNERS='42\tonline\tfalse\n' GH_RUNNERS_NAMED="$runner_rows" HOMEFIELD_WATCH_WAKE_WAIT=1 -- route-watch wake
record "route-watch wake: the VM is started and the pending repo restored, exit 0" "0/yes/yes/0" \
  "$rc/$(grep -q '^limactl start --tty=false homefield' "$calls" && echo yes || echo no)/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body local' "$calls" && echo yes || echo no)/$([ -f "$state/autoflip" ] && wc -l <"$state/autoflip" | tr -d ' ' || echo 0)"
record "...the repo is recorded as routed local" "homefield-ci acme/api github.com" "$(cat "$state/routing" 2>/dev/null)"
record "...the run is recorded" "wake/ok" "$(watcher_state_value last_mode)/$(watcher_state_value last_result)"

printf 'homefield-ci acme/api\n' >"$state/autoflip"
hf LIMA_STATUS=Running REG=0 SETTING_OUT="$settings" GH_RUNNERS_FAIL=1 HOMEFIELD_WATCH_WAKE_WAIT=1 -- route-watch wake
record "route-watch wake, GitHub cannot be asked: the entries are kept, exit 1" "1/yes/yes" \
  "$rc/$(grep -q acme/api "$state/autoflip" && echo yes || echo no)/$(has "$err" 'not online after')"
record "...the failed run is recorded" "wake/failed" "$(watcher_state_value last_mode)/$(watcher_state_value last_result)"

printf 'auto_route=0\n' >"$state/homefield.state"
printf 'homefield-ci acme/api\n' >"$state/autoflip"
hf LIMA_STATUS=Stopped REG=0 SETTING_OUT="$settings" -- route-watch wake
record "route-watch wake, auto_route=0: nothing is started or restored" "0/0/0/yes" \
  "$rc/$(grep -c '^limactl start' "$calls" || true)/$(grep -c 'variable set' "$calls" || true)/$(grep -q acme/api "$state/autoflip" && echo yes || echo no)"
printf 'auto_route=1\n' >"$state/homefield.state"

# A two-VM Mac whose runners share a label: at sleep both runners go away
# together, so neither may keep the other's repositories served — the flip's
# still-served check must exclude every runner on this Mac.
lima="$work/lima"
mkdir -p "$lima/second" "$work/settings" "$work/jobs"
printf '%s\n' '# Lima VM for the local GitHub Actions runner.' >"$lima/second/lima.yaml"
printf 'my-mac-homefield\nhttps://github.com/acme\n42\n' >"$work/settings/homefield"
printf 'second-mac\nhttps://github.com/acme\n43\n' >"$work/settings/second"
printf 'auto_route=1\n' >"$state/second.state"
printf 'homefield-ci acme/api\nhomefield-ci acme/web\n' >"$state/routing"
rm -f "$state/autoflip"
hf LIMA_ROWS='homefield Running\nsecond Running\n' LIMA_HOME="$lima" SETTINGS_DIR="$work/settings" \
  JOBS_DIR="$work/jobs" REG=0 \
  GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n43\tsecond-mac\tonline\tself-hosted,linux,arm64,homefield-ci\n' \
  -- route-watch sleep
record "sleep on a two-VM Mac sharing a label: both repos flip (each runner would keep the other's served)" "0/yes/yes" \
  "$rc/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/api --body hosted' "$calls" && echo yes || echo no)/$(grep -q 'variable set CI_RUNNER --repo github.com/acme/web --body hosted' "$calls" && echo yes || echo no)"

# A runner name is only excluded within its own registration scope: a Mac
# with runners for two organizations must not let one org's local runner name
# exclude a same-named remote runner of the other org, which still serves its
# repositories.
printf 'other-mac\nhttps://github.com/beta\n43\n' >"$work/settings/second"
printf 'homefield-ci acme/api\n' >"$state/routing"
rm -f "$state/autoflip"
hf LIMA_ROWS='homefield Running\nsecond Running\n' LIMA_HOME="$lima" SETTINGS_DIR="$work/settings" \
  JOBS_DIR="$work/jobs" REG=0 \
  GH_RUNNERS='42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n43\tother-mac\tonline\tself-hosted,linux,arm64,homefield-ci\n' \
  -- route-watch sleep
record "sleep does not exclude another scope's runner: the remote namesake keeps the repos served" "0/0/0" \
  "$rc/$(grep -c 'variable set' "$calls" || true)/$([ -f "$state/autoflip" ] && wc -l <"$state/autoflip" | tr -d ' ' || echo 0)"

# A stopped VM is not asked and not flipped: its runner is not taking jobs.
printf 'homefield-ci acme/api\n' >"$state/routing"
rm -f "$state/autoflip" "$state/second.state"
hf LIMA_ROWS='homefield Running\nsecond Stopped\n' LIMA_HOME="$lima" SETTINGS_DIR="$work/settings" \
  JOBS_DIR="$work/jobs" REG=0 SETTING_OUT="$settings" GH_RUNNERS="$runner_rows" -- route-watch sleep
record "sleep skips a Stopped VM: it is not asked and its records stay" "0/no" \
  "$rc/$(grep -q 'second-mac' "$calls" && echo yes || echo no)"
record "...the Running VM still flips" "homefield-ci acme/api github.com" "$(cat "$state/autoflip" 2>/dev/null)"

# A VM literally named route-watcher: its own state file (route-watcher.state)
# must survive a watcher run, because the watcher's records live in their own
# subdirectory — the run summary would otherwise overwrite the VM's
# auto_route and silently disable its automatic fallback.
mkdir -p "$lima/route-watcher"
printf '%s\n' '# Lima VM for the local GitHub Actions runner.' >"$lima/route-watcher/lima.yaml"
printf 'rw-mac\nhttps://github.com/acme\n44\n' >"$work/settings/route-watcher"
printf 'auto_route=1\n' >"$state/route-watcher.state"
printf 'homefield-ci acme/api\n' >"$state/routing"
rm -f "$state/autoflip"
hf LIMA_ROWS='route-watcher Running\n' LIMA_HOME="$lima" SETTINGS_DIR="$work/settings" \
  JOBS_DIR="$work/jobs" REG=0 GH_RUNNERS='44\trw-mac\tonline\tself-hosted,linux,arm64,homefield-ci\n' -- route-watch sleep
record "a VM named route-watcher: its state file survives the watcher run" "0/yes/yes" \
  "$rc/$(grep -qx 'auto_route=1' "$state/route-watcher.state" && echo yes || echo no)/$(grep -q '^last_mode=sleep$' "$state/route-watcher/state" 2>/dev/null && echo yes || echo no)"
record "...the run record carries the run, not the VM's state" "sleep/ok" \
  "$(watcher_state_value last_mode)/$(watcher_state_value last_result)"
rm -rf "$lima" "$work/settings" "$work/jobs"
rm -f "$state/second.state" "$state/homefield.state" "$state/routing" "$state/autoflip" "$state/route-watcher.state"
rm -rf "$state/route-watcher"

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
# ran_jobs: 1 (the default) is a fresh VM, 0 one that has run jobs, 2 a guest
# that cannot be asked. A token only goes into a fresh VM (the install
# registration check).
ran_jobs() { return "${STUB_RAN_JOBS:-1}"; }
runner_service_state() { return 0; }
stop_runner() { echo stop_runner >>"$CALLS"; }
runner_back() { :; }
"$@"
EOF
iharness() {
  : >"$calls"
  # A clean state file per install: a registration records ever_registered
  # (the host-side token guard), and the next install on the same VM is
  # refused by design. Cases that pre-set state before a call do it for
  # upgrades, which keep the file.
  if [ "$1" = cmd_install ]; then
    rm -f "$state/homefield.state"
  fi
  out="$(env -i HOME="$work/home" PATH="$stubs" CALLS="$calls" ROOT="$ROOT" \
    HOMEFIELD_STATE_DIR="$state" LIMA_STATUS=Running CLOCK_EPOCH="$CLOCK_EPOCH" GH_RUNNERS='41\tonline\tfalse\n' \
    STUB_RAN_JOBS="${STUB_RAN_JOBS:-1}" \
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
record "...the route watcher LaunchAgent is installed and loaded" "yes/yes" \
  "$([ -f "$work/home/Library/LaunchAgents/com.homefield.route-watcher.plist" ] && echo yes || echo no)/$(grep -q 'launchctl load -w' "$calls" && echo yes || echo no)"
record "...the agent logs to the state directory" "yes" \
  "$(grep -q 'route-watcher/log' "$work/home/Library/LaunchAgents/com.homefield.route-watcher.plist" && echo yes || echo no)"
# The operator's tuning at install time reaches the agent: launchd does not
# inherit a shell's environment, so every HOMEFIELD_WATCH_* the docs document
# must be baked into the plist's own environment block.
iharness_env=(HOMEFIELD_WATCH_SLEEP_BUDGET=7 HOMEFIELD_WATCH_WAKE_WAIT=9 HOMEFIELD_WATCH_WAKE_BUDGET=300)
iharness cmd_install --url https://github.com/acme --org --auto-route
plist_env="$work/home/Library/LaunchAgents/com.homefield.route-watcher.plist"
record "...the watcher budgets the operator set at install time reach the agent" "yes/yes/yes" \
  "$(grep -q '<key>HOMEFIELD_WATCH_SLEEP_BUDGET</key>' "$plist_env" && grep -A1 '<key>HOMEFIELD_WATCH_SLEEP_BUDGET</key>' "$plist_env" | grep -q '<string>7</string>' && echo yes || echo no)/$(grep -A1 '<key>HOMEFIELD_WATCH_WAKE_WAIT</key>' "$plist_env" | grep -q '<string>9</string>' && echo yes || echo no)/$(grep -A1 '<key>HOMEFIELD_WATCH_WAKE_BUDGET</key>' "$plist_env" | grep -q '<string>300</string>' && echo yes || echo no)"
iharness_env=(HOMEFIELD_SCALE_INTERVAL=90 HOMEFIELD_SCALE_WAIT=600 HOMEFIELD_SCALE_IDLE=1800 HOMEFIELD_SCALE_MAX=6 HOMEFIELD_SCALE_TICK_BUDGET=3600)
iharness cmd_install --url https://github.com/acme --org --auto-route
record "...the scaler's tuning reaches the agent the same way" "yes/yes/yes/yes/yes" \
  "$(grep -A1 '<key>HOMEFIELD_SCALE_INTERVAL</key>' "$plist_env" | grep -q '<string>90</string>' && echo yes || echo no)/$(grep -A1 '<key>HOMEFIELD_SCALE_WAIT</key>' "$plist_env" | grep -q '<string>600</string>' && echo yes || echo no)/$(grep -A1 '<key>HOMEFIELD_SCALE_IDLE</key>' "$plist_env" | grep -q '<string>1800</string>' && echo yes || echo no)/$(grep -A1 '<key>HOMEFIELD_SCALE_MAX</key>' "$plist_env" | grep -q '<string>6</string>' && echo yes || echo no)/$(grep -A1 '<key>HOMEFIELD_SCALE_TICK_BUDGET</key>' "$plist_env" | grep -q '<string>3600</string>' && echo yes || echo no)"
iharness_env=()

# The scaler's own subprocess installs a spare with --auto-route: the agent
# supervising the tick is already installed, and reloading it would stop the
# helper mid-install (launchctl unload stops the job). It is left as it is.
plist_env="$work/home/Library/LaunchAgents/com.homefield.route-watcher.plist"
cp "$plist_env" "$work/plist-before"
iharness_env=(HOMEFIELD_SCALE_INSTALL=1)
iharness cmd_install --url https://github.com/acme --org --auto-route
record "the scaler's spare install leaves the running agent as it is" \
  "0/0/yes" \
  "$(grep -c '^launchctl unload' "$calls" || true)/$(grep -c '^launchctl load' "$calls" || true)/$(cmp -s "$plist_env" "$work/plist-before" && echo yes || echo no)"
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
rm -f "$state/homefield.state" "$work/home/Library/LaunchAgents/com.homefield.route-watcher.plist"
iharness cmd_install --url https://github.com/acme --org
record "plain install: the switch is saved off, the watcher stays out" "0/0/no" \
  "$rc/$(state_value auto_route)/$([ -f "$work/home/Library/LaunchAgents/com.homefield.route-watcher.plist" ] && echo yes || echo no)"

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
record "...the route watcher agent is removed with it (no other VM wants it)" "no" \
  "$([ -f "$work/home/Library/LaunchAgents/com.homefield.route-watcher.plist" ] && echo yes || echo no)"

# Another VM on the Mac still wanting the watcher keeps the agent in place:
# the agent is per-Mac, the switch is per-VM.
printf 'auto_route=1\n' >"$state/other.state"
iharness cmd_upgrade --auto-route
record "upgrade --auto-route: the agent is back" "yes" \
  "$([ -f "$work/home/Library/LaunchAgents/com.homefield.route-watcher.plist" ] && echo yes || echo no)"
iharness cmd_upgrade --no-auto-route
record "upgrade --no-auto-route, another VM still wants the watcher: the agent stays" "0/0/yes" \
  "$rc/$(state_value auto_route)/$([ -f "$work/home/Library/LaunchAgents/com.homefield.route-watcher.plist" ] && echo yes || echo no)"
rm -f "$state/other.state"
printf 'auto_route=0\n' >"$state/homefield.state"
iharness cmd_upgrade --auto-route
record "upgrade --auto-route: the switch is saved on" "0/1" \
  "$rc/$(state_value auto_route)"
iharness cmd_upgrade --bogus-flag
iharness_env=()
record "an unknown upgrade option: refused" "1/yes" "$rc/$(has "$out" 'unknown option')"

echo
echo "the demand scaler (#291)"
# The tick runs the real modules through THARNESS, with scale_exec replaced
# by a recorder: the tests below assert the exact command the scaler would
# run (create, start, stop) without building a VM. The last two tests run the
# real command, subprocess seam included.

tharness_env=()
tharness iso_to_epoch 2026-11-20T10:00:00Z
record "iso_to_epoch: a UTC timestamp is seconds since the epoch" \
  "0/$(python3 -c 'import calendar; print(calendar.timegm((2026,11,20,10,0,0,0,0,0)))')" "$rc/$out"
tharness iso_to_epoch 2020-02-29T12:34:56Z
record "iso_to_epoch: a leap day" \
  "0/$(python3 -c 'import calendar; print(calendar.timegm((2020,2,29,12,34,56,0,0,0)))')" "$rc/$out"
tharness iso_to_epoch 1970-01-01T00:00:00Z
record "iso_to_epoch: the epoch itself" "0/0" "$rc/$out"
tharness iso_to_epoch 2026-11-21T08:09:00Z
record "iso_to_epoch: zero-padded components are base 10, not octal" \
  "0/$(python3 -c 'import calendar; print(calendar.timegm((2026,11,21,8,9,0,0,0,0)))')" "$rc/$out"
tharness iso_to_epoch not-a-date
record "iso_to_epoch: garbage is refused" "1/" "$rc/$out"

tharness mem_to_bytes 5GiB
record "mem_to_bytes: Lima's template unit" "0/5368709120" "$rc/$out"
tharness mem_to_bytes 512MiB
record "mem_to_bytes: MiB" "0/536870912" "$rc/$out"
tharness mem_to_bytes 4G
record "mem_to_bytes: a bare G reads as its binary cousin" "0/4294967296" "$rc/$out"
tharness mem_to_bytes 100
record "mem_to_bytes: plain bytes" "0/100" "$rc/$out"
tharness mem_to_bytes 5TiB
record "mem_to_bytes: an unknown unit is refused" "1/" "$rc/$out"

tharness mem_to_gib 5GiB
record "mem_to_gib: the template's unit is numeric GiB for limactl create" "0/5" "$rc/$out"
tharness mem_to_gib 512MiB
record "mem_to_gib: a half-GiB VM reads 0.5" "0/0.5" "$rc/$out"
tharness mem_to_gib 1536MiB
record "mem_to_gib: one and a half" "0/1.5" "$rc/$out"
tharness mem_to_gib 100
record "mem_to_gib: plain bytes are a fraction of a GiB" "0/9.31323e-08" "$rc/$out"

reset_scale() {
  rm -f "$state/route-watcher/scale" "$state/route-watcher/scale-state" "$state/route-watcher/running"
}

# The common fixtures: one busy primary (a queued run behind it), one queued
# run that has waited since 2020, the group and runner rows the secondary's
# registration is copied from.
tick_env() {
  lima_for homefield 6 5GiB
  mkdir -p "$work/settings" "$work/jobs"
  printf 'my-mac-homefield\nhttps://github.com/acme\n42\n' >"$work/settings/homefield"
  : >"$work/jobs/homefield"
  printf 'homefield-ci acme/api github.com\n' >"$state/routing"
  printf 'auto_route=1\n' >"$state/homefield.state"
  tharness_env=(
    LIMA_ROWS='homefield Running\n'
    LIMA_HOME="$work/home/.lima"
    SETTINGS_DIR="$work/settings"
    JOBS_DIR="$work/jobs"
    GH_RUNNERS=$'42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n'
    GH_GROUPS=$'Default\tselected\tfalse\t1\n'
    GH_GROUP_RUNNERS=$'42\n43\n'
    GH_GROUP_REPOS=$'acme/api\nacme/web\n'
    GH_RUNS='9001\t2020-01-01T00:00:00Z\n'
    GH_JOBS='5\n'
    HOMEFIELD_SCALE_WAIT=10 HOMEFIELD_SCALE_IDLE=100
  )
}
# th_state <key>: the tick record's value for the key.
th_state() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$state/route-watcher/scale-state" 2>/dev/null; }

tick_env
reset_scale
tharness fleet_watch_tick
record "a queued run older than the threshold: a secondary is created like the primary" \
  "0/scale_exec install --instance homefield-scale --url https://github.com/acme --label homefield-ci --group Default --auto-route --cpus 6 --memory 5" \
  "$rc/$(grep '^scale_exec install ' "$calls")"
record "...the secondary is recorded as the spare" "homefield-scale homefield-ci github.com https://github.com/acme Default epoch" \
  "$(awk -F'|' '{print $1, $2, $3, $4, $5, ($6 ~ /^[0-9]+$/ ? "epoch" : "bad")}' "$state/route-watcher/scale" 2>/dev/null)"
record "...the tick record says what it did" "ok/created homefield-scale" \
  "$(th_state last_result)/$(th_state last_action)"

tick_env
reset_scale
tharness_env+=(GH_RUNS='' GH_RUNS_IN_PROGRESS='9002\t2020-01-01T00:00:00Z\n')
tharness fleet_watch_tick
record "a matrix run in progress with jobs still queued counts as demand" \
  "0/scale_exec install --instance homefield-scale --url https://github.com/acme --label homefield-ci --group Default --auto-route --cpus 6 --memory 5" \
  "$rc/$(grep '^scale_exec install ' "$calls")"

tick_env
reset_scale
tharness_env+=(HOOKS_LIST=$'50-buildx-rosetta.sh\n')
tharness fleet_watch_tick
record "a primary with provisioning hooks: no create, the runbook's manual path is named" \
  "0/0/yes" "$rc/$(grep -c '^scale_exec install ' "$calls" || true)/$(has "$out" 'cannot copy')"

tick_env
reset_scale
lima_for homefield 6 1536MiB
tharness fleet_watch_tick
record "a MiB-sized primary: the spare's --memory is numeric GiB (limactl refuses 5GiB)" \
  "0/scale_exec install --instance homefield-scale --url https://github.com/acme --label homefield-ci --group Default --auto-route --cpus 6 --memory 1.5" \
  "$rc/$(grep '^scale_exec install ' "$calls")"

tick_env
reset_scale
tharness_env+=(EXTRA_PKGS='docker-buildx ghcli')
tharness fleet_watch_tick
record "the primary's saved extra packages go on the spare's install" \
  "0/scale_exec install --instance homefield-scale --url https://github.com/acme --label homefield-ci --group Default --auto-route --packages docker-buildx ghcli --cpus 6 --memory 5" \
  "$rc/$(grep '^scale_exec install ' "$calls")"

tick_env
reset_scale
# Two runners share the label in different selected-repository groups: the
# first VM's group excludes the queued repository, so the primary is the one
# whose group admits it — a spare in the excluding group could not take the
# queued jobs (route's own permission check, runner_serves_repo).
printf 'second-mac\nhttps://github.com/acme\n43\n' >"$work/settings/second"
lima_for second 6 5GiB
: >"$work/jobs/second"
printf 'auto_route=1\n' >"$state/second.state"
tharness_env+=(
  LIMA_ROWS=$'homefield Running\nsecond Running\n'
  GH_RUNNERS=$'42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n43\tsecond-mac\tonline\tself-hosted,linux,arm64,homefield-ci\n'
  GH_GROUPS=$'Excludes\tselected\tfalse\t7\nAdmits\tselected\tfalse\t8\n'
  GH_GROUP_RUNNERS_7=$'42\n' GH_GROUP_RUNNERS_8=$'43\n'
  GH_GROUP_REPOS_7=$'acme/other\n' GH_GROUP_REPOS_8=$'acme/api\n'
  SYSCTL_CPUS=24 SYSCTL_MEM=68719476736
)
tharness fleet_watch_tick
record "a primary whose group excludes the queued repo is skipped for one that admits it" \
  "0/scale_exec install --instance homefield-scale --url https://github.com/acme --label homefield-ci --group Admits --auto-route --cpus 6 --memory 5" \
  "$rc/$(grep '^scale_exec install ' "$calls")"

tick_env
reset_scale
# Two overdue demands in one tick: the first cannot be answered (the only
# runner serving its label carries hooks the scaler cannot copy), and the
# tick must go on to the second instead of letting the first starve it.
printf 'second-mac\nhttps://github.com/acme\n43\n' >"$work/settings/second"
lima_for second 6 5GiB
: >"$work/jobs/second"
printf 'auto_route=1\n' >"$state/second.state"
printf 'homefield-ci acme/api github.com\nbeta-ci acme/web github.com\n' >"$state/routing"
tharness_env+=(
  LIMA_ROWS=$'homefield Running\nsecond Running\n'
  GH_RUNNERS=$'42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n43\tsecond-mac\tonline\tself-hosted,linux,arm64,beta-ci\n'
  HOOKS_LIST=$'50-buildx-rosetta.sh\n'
  SYSCTL_CPUS=24 SYSCTL_MEM=68719476736
)
tharness fleet_watch_tick
record "an unserviceable demand does not starve the next one in the same tick" \
  "0/scale_exec install --instance homefield-scale --url https://github.com/acme --label beta-ci --group Default --auto-route --cpus 6 --memory 5" \
  "$rc/$(grep '^scale_exec install ' "$calls")"
rm -f "$work/jobs/second" "$work/settings/second" "$state/second.state"

tick_env
reset_scale
# Two routed repositories share the label and host while their eligible
# runners differ: remote's runner is elsewhere (its group excludes the
# repo), local's is this VM. The demand entries stay separate — merging
# them into the oldest run's repository would let remote starve local.
printf 'homefield-ci acme/remote github.com\nhomefield-ci acme/api github.com\n' >"$state/routing"
tharness fleet_watch_tick
record "a demand this Mac cannot serve does not swallow the next one with the same label" \
  "0/scale_exec install --instance homefield-scale --url https://github.com/acme --label homefield-ci --group Default --auto-route --cpus 6 --memory 5" \
  "$rc/$(grep '^scale_exec install ' "$calls")"

tick_env
reset_scale
tharness_env+=(HOMEFIELD_SCALE_MAX=1)
tharness fleet_watch_tick
record "the fleet is at its cap: no create, the tick still passes" "0/0/yes" \
  "$rc/$(grep -c '^scale_exec install ' "$calls" || true)/$(has "$out" 'at its cap')"

tick_env
reset_scale
printf 'second|homefield-ci|github.com|https://github.com/acme|Default|%s\n' "$(( CLOCK_EPOCH - 1000 ))" >"$state/route-watcher/scale"
lima_for second 6 5GiB
rm -f "$work/jobs/homefield"
tharness_env+=(LIMA_ROWS=$'homefield Running\nsecond Running\n')
tharness fleet_watch_tick
record "a secondary idle past the cooldown: the real stop runs on it, and it stays recorded" \
  "0/scale_exec stop --instance second/second homefield-ci github.com https://github.com/acme Default epoch" \
  "$rc/$(grep '^scale_exec stop ' "$calls")/$(awk -F'|' '{print $1, $2, $3, $4, $5, ($6 ~ /^[0-9]+$/ ? "epoch" : "bad")}' "$state/route-watcher/scale" 2>/dev/null)"
record "...the primary is never a stop candidate" "0" "$(grep -c '^scale_exec stop --instance homefield$' "$calls" || true)"
record "...the tick record says what it did" "ok/stopped second" "$(th_state last_result)/$(th_state last_action)"

tick_env
reset_scale
printf 'second|homefield-ci|github.com|https://github.com/acme|Default|%s\n' "$(( CLOCK_EPOCH - 1000 ))" >"$state/route-watcher/scale"
lima_for second 6 5GiB
: >"$work/jobs/second"
rm -f "$work/jobs/homefield"
tharness_env+=(LIMA_ROWS=$'homefield Running\nsecond Running\n')
tharness fleet_watch_tick
record "a secondary with a live job: not stopped, its busy time is fresh" "0/0" \
  "$rc/$(grep -c '^scale_exec stop ' "$calls" || true)"
record "...and the queue behind a partly busy fleet is not scaled" "0" \
  "$(grep -c '^scale_exec install ' "$calls" || true)"

tick_env
reset_scale
rm -f "$work/jobs/homefield"
tharness_env+=(PGREP_FAIL=1)
tharness fleet_watch_tick
record "a VM that cannot be asked about jobs: fail safe, nothing scales" "1/0/failed" \
  "$rc/$(grep -c '^scale_exec ' "$calls" || true)/$(th_state last_result)"

tick_env
reset_scale
printf 'pid=%s\nstarted=%s\n' "$$" "$CLOCK_EPOCH" >"$state/route-watcher/running"
tharness fleet_watch_tick
record "the sleep/wake watcher is running: the tick stands down" "0/0/yielded to the watcher" \
  "$rc/$(grep -c '^scale_exec ' "$calls" || true)/$(th_state last_action)"
printf 'pid=99999999\nstarted=%s\n' "$CLOCK_EPOCH" >"$state/route-watcher/running"
tharness fleet_watch_tick
record "...a dead marker pid does not stop the scaler" "0/1" \
  "$rc/$(grep -c '^scale_exec ' "$calls" || true)"

tick_env
reset_scale
printf 'second|homefield-ci|github.com|https://github.com/acme|Default|%s\n' "$CLOCK_EPOCH" >"$state/route-watcher/scale"
lima_for second 6 5GiB
tharness_env+=(LIMA_ROWS=$'homefield Running\nsecond Stopped\n')
tharness fleet_watch_tick
record "a recorded spare that matches the demand is booted, not re-created" \
  "0/scale_exec start --instance second/0" \
  "$rc/$(grep '^scale_exec start ' "$calls")/$(grep -c '^scale_exec install ' "$calls" || true)"
record "...the boot refreshes its busy time" "second homefield-ci github.com https://github.com/acme Default epoch" \
  "$(awk -F'|' '{print $1, $2, $3, $4, $5, ($6 ~ /^[0-9]+$/ ? "epoch" : "bad")}' "$state/route-watcher/scale" 2>/dev/null)"

tick_env
reset_scale
printf 'second|homefield-ci|github.com|https://github.com/other|Default|%s\n' "$CLOCK_EPOCH" >"$state/route-watcher/scale"
lima_for second 6 5GiB
tharness_env+=(LIMA_ROWS=$'homefield Running\nsecond Stopped\n')
# A bigger host: homefield plus a new 6 vCPU / 5 GiB spare fit, so the create
# that replaces the unreachable boot is what the tick is measured on.
tharness_env+=(SYSCTL_CPUS=24 SYSCTL_MEM=68719476736)
tharness fleet_watch_tick
record "a stopped spare from another registration is not booted for this demand" \
  "0/scale_exec install --instance homefield-scale --url https://github.com/acme --label homefield-ci --group Default --auto-route --cpus 6 --memory 5/0" \
  "$rc/$(grep '^scale_exec install ' "$calls")/$(grep -c '^scale_exec start ' "$calls" || true)"

tick_env
reset_scale
tharness_env+=(SYSCTL_CPUS=8 SYSCTL_MEM=17179869184)
tharness fleet_watch_tick
record "a create that would oversubscribe the Mac's CPU or RAM: refused, the tick passes" \
  "0/0/yes" "$rc/$(grep -c '^scale_exec install ' "$calls" || true)/$(has "$out" 'oversubscribe')"

tick_env
reset_scale
# A repository-scoped registration has no runner group: the record's group
# field is empty, and the tab-separated record must keep it (a space-separated
# record would shift the busy time into the group field and drop the line).
printf 'my-mac-homefield\nhttps://github.com/acme/api\n42\n' >"$work/settings/homefield"
printf 'second|homefield-ci|github.com|https://github.com/acme/api||%s\n' "$CLOCK_EPOCH" >"$state/route-watcher/scale"
lima_for second 6 5GiB
tharness_env+=(LIMA_ROWS=$'homefield Running\nsecond Stopped\n')
# A bigger host: the boot is what is measured, not a headroom refusal.
tharness_env+=(SYSCTL_CPUS=24 SYSCTL_MEM=68719476736)
tharness fleet_watch_tick
record "a record with an empty group (a repo-scoped registration) round-trips and boots" \
  "0/scale_exec start --instance second/0" \
  "$rc/$(grep '^scale_exec start ' "$calls")/$(grep -c '^scale_exec install ' "$calls" || true)"

tick_env
reset_scale
# A group name with spaces survives the record: written by one tick, read by
# the next, and still matching the demand's primary on the boot path.
tharness_env+=(GH_GROUPS=$'CI Runners\tselected\tfalse\t7\n')
tharness fleet_watch_tick
record "a group with spaces is recorded whole" \
  "homefield-scale homefield-ci github.com https://github.com/acme CI Runners epoch" \
  "$(awk -F'|' '{print $1, $2, $3, $4, $5, ($6 ~ /^[0-9]+$/ ? "epoch" : "bad")}' "$state/route-watcher/scale" 2>/dev/null)"
printf 'second|homefield-ci|github.com|https://github.com/acme|CI Runners|%s\n' "$CLOCK_EPOCH" >"$state/route-watcher/scale"
lima_for second 6 5GiB
tharness_env+=(LIMA_ROWS=$'homefield Running\nsecond Stopped\n')
tharness fleet_watch_tick
record "...and a stopped spare of that group is still booted for the demand" \
  "0/scale_exec start --instance second" "$rc/$(grep '^scale_exec start ' "$calls")"

tick_env
reset_scale
tharness_env+=(GH_RUNNERS=$'42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,other-label\n')
tharness fleet_watch_tick
record "no running runner serves the queued label: not this Mac's to scale" "0/0" \
  "$rc/$(grep -c '^scale_exec ' "$calls" || true)"

tick_env
reset_scale
printf 'my-mac-homefield\nhttps://ghes.acme.example/acme\n42\n' >"$work/settings/homefield"
printf 'homefield-ci acme/api ghes.acme.example\n' >"$state/routing"
tharness fleet_watch_tick
record "a GHES record is scaled like a github.com one, on its own host" \
  "0/scale_exec install --instance homefield-scale --url https://ghes.acme.example/acme --label homefield-ci --group Default --auto-route --cpus 6 --memory 5" \
  "$rc/$(grep '^scale_exec install ' "$calls")"

tick_env
reset_scale
printf 'ghost|homefield-ci|github.com|https://github.com/acme|Default|123\nhomefield-scale|homefield-ci|github.com|https://github.com/acme|Default|%s\n' "$CLOCK_EPOCH" >"$state/route-watcher/scale"
lima_for homefield-scale 6 5GiB
tharness_env+=(LIMA_ROWS=$'homefield Running\nhomefield-scale Running\n')
tharness fleet_watch_tick
record "a secondary deleted by hand leaves the scale record at the next tick" \
  "homefield-scale homefield-ci github.com https://github.com/acme Default" "$(awk -F'|' '{print $1, $2, $3, $4, $5}' "$state/route-watcher/scale" 2>/dev/null)"

tick_env
reset_scale
tharness_env+=(GH_RUNS_FAIL=1)
tharness fleet_watch_tick
record "GitHub cannot be asked about queued runs: fail safe, nothing scales" "1/0/failed" \
  "$rc/$(grep -c '^scale_exec ' "$calls" || true)/$(th_state last_result)"

tick_env
reset_scale
# created_at is CLOCK_EPOCH - 5: younger than HOMEFIELD_SCALE_WAIT=10, so
# the run is queued but has not waited long enough.
tharness_env+=(GH_RUNS='9001\t2023-11-14T22:13:15Z\n')
tharness fleet_watch_tick
record "a queued run younger than the threshold: no action yet" "0/0/none" \
  "$rc/$(grep -c '^scale_exec ' "$calls" || true)/$(th_state last_action)"

# The real command, subprocess seam included: the tick's stop of the idle
# secondary goes through the real stop, and `fleet status` prints the
# scaler's last tick.
reset_scale
tick_env
rm -f "$work/jobs/homefield"
printf 'second|homefield-ci|github.com|https://github.com/acme|Default|%s\n' "$(( CLOCK_EPOCH - 1000 ))" >"$state/route-watcher/scale"
lima_for second 6 5GiB
tharness_env+=(LIMA_ROWS=$'homefield Running\nsecond Running\n')
tharness fleet_watch_tick
hf -- fleet
record "fleet status prints the scaler's last tick" "yes/yes" \
  "$(has "$out" 'No HomeField VMs found on this Mac.')/$(has "$out" 'scaler: last tick at ')"

# Two overlapping fleet watch runs serialize on the per-Mac lock: a
# contender stands down instead of interleaving its read-modify-write of
# the scale record (a slower tick could otherwise erase the other's newly
# created spare from the bookkeeping, and both could provision the same
# spare name).
tick_env
reset_scale
printf 'second|homefield-ci|github.com|https://github.com/acme|Default|%s\n' "$(( CLOCK_EPOCH - 1000 ))" >"$state/route-watcher/scale"
lima_for second 6 5GiB
mkdir -p "$state/route-watcher/scale.lock"
printf '%s\n' "$$" >"$state/route-watcher/scale.lock/pid"
hf LIMA_ROWS=$'homefield Running\nsecond Running\n' LIMA_HOME="$work/home/.lima" \
  SETTINGS_DIR="$work/settings" JOBS_DIR="$work/jobs" \
  -- fleet watch --max-ticks 1
record "a live scaler lock: the contender stands down, the record untouched" \
  "0/yes/no/$(( CLOCK_EPOCH - 1000 ))" \
  "$rc/$(has "$out" 'standing down')/$(grep -qE '^limactl (list|stop|start)' "$calls" && echo yes || echo no)/$(awk -F'|' '$1 == "second" {print $6}' "$state/route-watcher/scale" 2>/dev/null)"
printf '%s\n' 99999999 >"$state/route-watcher/scale.lock/pid"
rm -f "$work/jobs/homefield" "$work/jobs/second"
hf LIMA_ROWS=$'homefield Running\nsecond Running\n' LIMA_HOME="$work/home/.lima" \
  SETTINGS_DIR="$work/settings" JOBS_DIR="$work/jobs" \
  -- fleet watch --max-ticks 1
record "...a dead lock owner is reclaimed, and the tick releases the lock" \
  "0/yes/no" \
  "$rc/$(grep -q '^limactl stop second' "$calls" && echo yes || echo no)/$([ -d "$state/route-watcher/scale.lock" ] && echo yes || echo no)"

reset_scale
tick_env
printf 'second|homefield-ci|github.com|https://github.com/acme|Default|%s\n' "$(( CLOCK_EPOCH - 1000 ))" >"$state/route-watcher/scale"
lima_for second 6 5GiB
rm -f "$work/jobs/homefield" "$work/jobs/second"
hf LIMA_ROWS=$'homefield Running\nsecond Running\n' LIMA_HOME="$work/home/.lima" \
  SETTINGS_DIR="$work/settings" JOBS_DIR="$work/jobs" REG=0 \
  SETTING_OUT='second-mac\nhttps://github.com/acme\n43\n' SVC_NAME='actions.runner.acme.second.service' \
  GH_RUNNERS=$'42\tmy-mac-homefield\tonline\tself-hosted,linux,arm64,homefield-ci\n43\tsecond-mac\tonline\tself-hosted,linux,arm64,homefield-ci\n' \
  -- fleet watch --max-ticks 1
record "fleet watch through the real command: the idle secondary is stopped" "0/yes" \
  "$rc/$(grep -q '^limactl stop second' "$calls" && echo yes || echo no)"

hf -- fleet watch --instance homefield
record "fleet watch refuses --instance: the scaler covers every VM" "1/yes" \
  "$rc/$(has "$err" 'does not apply')"
hf -- fleet stop --interval 5
record "fleet stop refuses the scaler's options" "1/yes" \
  "$rc/$(has "$err" "only supported with 'fleet watch'")"

# The watcher's tick launcher declares its globals: before scale_generation
# was declared, every agent-driven tick died on UnboundLocalError before
# fleet watch ran, and the loop repeated the failure every interval. The
# IOKit import confines this to macOS; the Linux suite job has no IOKit.
if [ "$(uname -s)" = Darwin ]; then
  tick_marker="$work/scale-tick-marker"
  tick_stub="$work/tick-stub.sh"
  cat >"$tick_stub" <<EOF
#!/usr/bin/env bash
: >"$tick_marker"
EOF
  chmod +x "$tick_stub"
  wl_out="$(MARKER="$tick_marker" python3 - "$ROOT/bin/route-watcher.py" "$tick_stub" <<'PYEOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("rw", sys.argv[1])
rw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rw)
rw.HOMEFIELD = sys.argv[2]
rw.SCALE_TICK_BUDGET = 10
rw.run_scale_tick()
print("tick-ok" if os.path.exists(os.environ["MARKER"]) else "tick-no-marker")
PYEOF
)"
  record "the watcher's tick launcher declares its globals and runs the tick" \
    "tick-ok" "$wl_out"
fi

summary