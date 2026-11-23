#!/usr/bin/env bash
# tests/fleet.sh — fleet status/start/stop, --json output, and multi-VM install guard.
#
# Run:  bash tests/fleet.sh
# Exit: 0 when every case passes, 1 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/.config/homefield" "$TMP/bin"
export PATH="$TMP/bin:$PATH"

calls="$TMP/calls"
: > "$calls"

# Stub limactl and gh so nothing touches the real machine or GitHub.
cat > "$TMP/bin/limactl" <<'EOF'
#!/usr/bin/env bash
case "${1-}" in
  --version) echo "limactl version 2.3.0" ;;
esac
exit 0
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# The hosted-activity test drives the demand filter's real jq: the canned
# pages are JSON (GH_RUNS_QUEUED_JSON, GH_RUNS_PROGRESS_JSON, one jobs file
# per run id under GH_JOBS_DIR), and this stub applies the call's --jq to
# them with the system jq, the way gh does. Everything else succeeds
# silently, the way the function level stubs above assume.
case "${GH_MODE:-}" in
  hosted-activity)
    expr="" prev=""
    for a in "$@"; do
      [ "$prev" = "--jq" ] && expr="$a"
      prev="$a"
    done
    case "$*" in
      *"actions/runs?"*)
        if [ "${GH_RUNS_FAIL:-}" = 1 ]; then echo "gh: HTTP 500" >&2; exit 1; fi
        case "$*" in
          *status=queued*) jq -r "${expr:-.}" "$GH_RUNS_QUEUED_JSON" 2>/dev/null ;;
          *status=in_progress*) jq -r "${expr:-.}" "$GH_RUNS_PROGRESS_JSON" 2>/dev/null ;;
        esac
        exit 0 ;;
      *"actions/runs/"*"/jobs"*)
        if [ "${GH_JOBS_FAIL:-}" = 1 ]; then echo "gh: HTTP 502" >&2; exit 1; fi
        run="$(printf '%s' "$*" | sed -n 's|.*/actions/runs/\([0-9]*\)/jobs.*|\1|p')"
        jq -r "${expr:-.}" "$GH_JOBS_DIR/$run.json" 2>/dev/null
        exit 0 ;;
    esac
    ;;
esac
exit 0
EOF
cat > "$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "${1-}" in
  -s) echo "Darwin" ;;
  -m) echo "arm64" ;;
  *) /usr/bin/uname "$@" ;;
esac
EOF
chmod +x "$TMP/bin/limactl" "$TMP/bin/gh" "$TMP/bin/uname"

# Source bin/homefield in a subshell-safe way.
# shellcheck disable=SC2034
HOMEFIELD_SOURCE_ONLY=1
# shellcheck source=bin/homefield
. "$ROOT/bin/homefield"

MOCK_MODE="empty"

vm_instances() {
  case "$MOCK_MODE" in
    empty) return 0 ;;
    multi) printf '%s\n' "homefield-1" "homefield-2" ;;
    busy|single|unknown_job) printf '%s\n' "homefield-1" ;;
  esac
}

# shellcheck disable=SC2034
st_collect() {
  ST_GH_STATUS=""
  case "$MOCK_MODE:$INSTANCE" in
    multi:homefield-1)
      ST_STATUS="Running"
      ST_NAME="mac-1"
      ST_GH="listed"
      ST_GH_STATUS="online"
      ST_SVC="running"
      ST_JOB="idle"
      ;;
    multi:homefield-2)
      # Simulate a stopped VM where real st_collect returns without resetting ST_NAME.
      ST_STATUS="Stopped"
      ST_GH="not_checked"
      ST_SVC="unknown"
      ST_JOB="unknown"
      ;;
    busy:homefield-1|single:homefield-1)
      ST_STATUS="Running"
      ST_NAME="mac-1"
      ST_GH="listed"
      ST_GH_STATUS="online"
      ST_SVC="running"
      ST_JOB="running"
      ;;
    unknown_job:homefield-1)
      ST_STATUS="Running"
      ST_NAME="mac-1"
      ST_GH="listed"
      ST_GH_STATUS="online"
      ST_SVC="running"
      ST_JOB="unknown"
      ;;
  esac
}

state_get() {
  if [ "$1" = "ephemeral" ] && [ "$INSTANCE" = "homefield-2" ]; then
    echo "1"
  fi
}

# 1. Empty fleet (human + JSON)
MOCK_MODE="empty"
out="$(cmd_fleet 2>&1)"; rc=$?
record "fleet empty: exits 0 and prints message" "0/yes" "$rc/$(has "$out" 'No HomeField VMs found')"

out="$(cmd_fleet --json 2>&1)"; rc=$?
record "fleet empty --json: exits 0 and empty array" "0/yes" \
  "$rc/$(has "$out" '{"total":0,"online":0,"idle":0,"busy":0,"offline":0,"vms":[]}')"

# 2. Multi-VM fleet status (human + JSON)
MOCK_MODE="multi"
out="$(cmd_fleet status 2>&1)"; rc=$?
record "fleet status: exits 0" "0" "$rc"
record "fleet status: prints header and both VMs" "yes/yes/yes" \
  "$(has "$out" 'INSTANCE')/$(has "$out" 'homefield-1')/$(has "$out" 'homefield-2')"
record "fleet status: shows persistent and ephemeral modes" "yes/yes" \
  "$(has "$out" 'persistent')/$(has "$out" 'ephemeral')"
record "fleet status: prints fleet totals" "yes" \
  "$(has "$out" 'Fleet: 2 total, 1 online (1 idle, 0 busy), 1 offline')"

out="$(cmd_fleet status --json 2>&1)"; rc=$?
record "fleet status --json: exits 0" "0" "$rc"
json_ok="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["total"] == 2 and d["online"] == 1 and d["idle"] == 1 and d["busy"] == 0 and d["offline"] == 1
assert len(d["vms"]) == 2
assert d["vms"][0]["instance"] == "homefield-1" and d["vms"][0]["github"] == "online" and d["vms"][0]["mode"] == "persistent"
assert d["vms"][1]["instance"] == "homefield-2" and d["vms"][1]["runner"] == "—" and d["vms"][1]["github"] == "not_checked" and d["vms"][1]["mode"] == "ephemeral"
print("ok")
' "$out" 2>/dev/null || echo bad)"
record "fleet status --json: valid schema and counts" "ok" "$json_ok"

# 3. Busy runner counted under online + busy
MOCK_MODE="busy"
out="$(cmd_fleet --json 2>&1)"
json_busy="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["total"] == 1 and d["online"] == 1 and d["idle"] == 0 and d["busy"] == 1 and d["offline"] == 0
print("ok")
' "$out" 2>/dev/null || echo bad)"
record "fleet --json: counts busy runner under online+busy" "ok" "$json_busy"

# 3b. Unknown job state counted under online, not idle or busy
MOCK_MODE="unknown_job"
out="$(cmd_fleet --json 2>&1)"
json_unk="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["total"] == 1 and d["online"] == 1 and d["idle"] == 0 and d["busy"] == 0 and d["offline"] == 0
print("ok")
' "$out" 2>/dev/null || echo bad)"
record "fleet --json: keeps unknown job out of idle and busy" "ok" "$json_unk"

# 4. fleet start and fleet stop dispatch
vm_dispatch() {
  echo "$1:$2" >> "$calls"
}
out="$(cmd_fleet start 2>&1)"; rc=$?
record "fleet start: dispatches start_single and prints summary" "0/1/yes" \
  "$rc/$(called '^start:start_single$')/$(has "$out" 'Fleet: 1 total')"

out="$(cmd_fleet stop 2>&1)"; rc=$?
record "fleet stop: dispatches stop_single" "0/1" \
  "$rc/$(called '^stop:stop_single$')"

# 5. Argument validation
rc=0
out="$(cmd_fleet bogus 2>&1)" || rc=$?
record "fleet bogus: fails" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'unknown fleet subcommand')"

rc=0
out="$(cmd_fleet start --json 2>&1)" || rc=$?
record "fleet start --json: fails" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'only supported with')"

# 6. Multi-VM registration warning in cmd_install
# Stub everything after the warning so cmd_install stops right at prepare_registration.
MOCK_MODE="single"
INSTANCE="homefield-2"
# shellcheck disable=SC2034
vm_lookup() { VM_STATUS=""; }
cmd_preflight() { return 0; }
prepare_registration() { return 99; }
rc=0
out="$(cmd_install --url https://github.com/org/repo 2>&1)" || rc=$?
record "cmd_install with existing VM: logs CPU/RAM budget warning" "yes/yes" \
  "$(has "$out" '1 other HomeField VM(s) already exist')/$(has "$out" 'Scaling on one Mac')"

# ── The demand scaler's tick: scale-to-zero and wake-from-zero (#291, #305) ──
# The tick is driven through fleet_watch_tick with every boundary stubbed —
# Lima (vm_instances, vm_status_of, job_running), GitHub (the demand
# lookups, the runner list, the runner's online status), the scaler
# subprocess (scale_exec) and the watcher's wake helpers — while the
# records are real files under a temp HOMEFIELD_STATE_DIR, so the wake
# flag and the primaries record are asserted as files. The tick is the
# only entry point: cmd_fleet watch's loop wrapper is argument handling.

export HOMEFIELD_STATE_DIR="$TMP/state"
mkdir -p "$HOMEFIELD_STATE_DIR/route-watcher"

scale_exec() {
  printf '%s\n' "scale:$*" >>"$calls"
  case "$1 $2" in
    "stop --instance")
      ZERO_STOPPED="$ZERO_STOPPED ${3:-}"
      return "${SCALE_STOP_RC:-0}"
      ;;
  esac
  return 0
}
route_watcher_is_running() { return 1; }
adopt_nap() { return 0; }
job_running() {
  case "$INSTANCE" in
    homefield-2) return "${JOB2_RC:-1}" ;;
  esac
  return "$JOB_RC"
}
# shellcheck disable=SC2034  # read by the scaler through load_runner_settings
load_runner_settings() {
  RS_NAME="mac-1"
  # A real read goes through the guest's .runner: a VM that is neither
  # Running nor just started by this tick has nothing to read, so the
  # read returns nothing — the spare pass must read the identity before
  # it stops the VM, and the wake reads it only after its start.
  if [ -n "${RS_READ_FAIL:-}" ]; then
    RS_NAME=""
    RS_URL=""
    RS_ID=""
    return 0
  fi
  local st
  st="$(vm_status_of "${INSTANCE:-}")" || st=""
  if [ "$st" != "Running" ] &&
    ! grep -q "^scale:start --instance ${INSTANCE:-}\$" "$calls" 2>/dev/null; then
    RS_NAME=""
    RS_URL=""
    RS_ID=""
    return 0
  fi
  case "$INSTANCE" in
    homefield-2)
      RS_ID="2"
      RS_URL="${RS_URL_2:-https://github.com/org/repo}"
      ;;
    *)
      RS_ID="1"
      RS_URL="${RS_URL_1:-https://github.com/org/repo}"
      ;;
  esac
}
runners_on_github() {
  if [ -n "${GH_ROWS_FAIL:-}" ]; then return 1; fi
  printf '1\tmac-1\tonline\tself-hosted,linux,arm64,homefield-ci\n';
}
# runner_serves_repo stub: SERVES_RC answers for every runner; SERVES_ID
# narrows the answer to that runner id (SERVES_RC_OTHER for the rest).
runner_serves_repo() {
  if [ -n "${SERVES_ID:-}" ] && [ "$2" != "$SERVES_ID" ]; then
    return "${SERVES_RC_OTHER:-0}"
  fi
  return "${SERVES_RC:-0}"
}
# shellcheck disable=SC2034  # read by the scaler through runner_on_github
runner_on_github() { RUNNER_GH_STATUS="online"; return 0; }
route_start_restore() { printf 'restore:%s:%s\n' "$1" "$2" >>"$calls"; return "${RESTORE_RC:-0}"; }
queued_wait_since() { [ -n "$QUEUED_SINCE" ] && printf '%s\n' "$QUEUED_SINCE"; return 0; }
hosted_activity_since() { [ -n "$HOSTED_SINCE" ] && printf '%s\n' "$HOSTED_SINCE"; return 0; }
vm_instances() {
  # FLEET_LIST is space-separated: one line per VM, the way Lima lists.
  local n
  for n in $FLEET_LIST; do
    printf '%s\n' "$n"
  done
}
vm_status_of() {
  # A VM the tick started earlier in this test reads Running, the way
  # Lima answers after a start: the wake's partial-failure path asks
  # Lima whether the start landed. ($calls is per test, so a start from
  # an earlier test does not leak into this one.)
  if grep -q "^scale:start --instance $1\$" "$calls" 2>/dev/null; then
    echo "Running"
    return 0
  fi
  # ZERO_STOPPED is a space-separated set: a VM the scaler stopped this or
  # an earlier tick reads Stopped, the way Lima would answer.
  case " $ZERO_STOPPED " in
    *" $1 "*)
      echo "Stopped"
      return 0
      ;;
  esac
  case "$1" in
    homefield-1) echo "${VM1_STATUS-Running}" ;;
    homefield-2) echo "${VM2_STATUS-Running}" ;;
    homefield-3) echo "${VM3_STATUS-Stopped}" ;;
    *) echo "Stopped" ;;
  esac
}
state_get() {
  if [ "$1" = "ephemeral" ] && [ "$INSTANCE" = "homefield-2" ]; then
    echo "1"
  elif [ "$1" = "auto_route" ] && [ "${AUTO_ROUTE:-}" = "1" ]; then
    echo "1"
  fi
}

RECORDS="$HOMEFIELD_STATE_DIR/route-watcher"
VM1_STATUS="Running"
VM2_STATUS="Running"
JOB_RC=1
JOB2_RC=1
QUEUED_SINCE=""
HOSTED_SINCE=""
AUTO_ROUTE=""
ZERO_STOPPED=""
SCALE_STOP_RC=0
FLEET_LIST="homefield-1"
# shellcheck disable=SC2034  # read by the stubs above
HOMEFIELD_SCALE_ZERO=""

# 7. Scale-to-zero: the opt-in stops the fleet's own idle VM and writes its
# dark line
# shellcheck disable=SC2034  # read by the tick
HOMEFIELD_SCALE_ZERO=1
printf '%s|https://github.com/org/repo|homefield-ci||%s|1\n' \
  "homefield-1" "$(( $(date +%s) - 1000 ))" >"$RECORDS/scale-primaries"
rm -f "$RECORDS/scale-dark" "$RECORDS/scale" "$HOMEFIELD_STATE_DIR/routing" \
  "$HOMEFIELD_STATE_DIR/autoflip"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
record "scale-to-zero: stops the idle own VM through the real stop" "1/yes" \
  "$(called '^scale:stop --instance homefield-1$')/$(has "$out" 'scaled to zero')"
record "scale-to-zero: the stopped VM's dark line is written" "yes" \
  "$(grep -q '^homefield-1|https://github.com/org/repo|homefield-ci|1$' "$RECORDS/scale-dark" && echo yes || echo no)"

# 8. Scale-to-zero is opt-in: off by default the idle VM stays up
# shellcheck disable=SC2034  # read by the tick
HOMEFIELD_SCALE_ZERO=""
printf '%s|https://github.com/org/repo|homefield-ci||%s|1\n' \
  "homefield-1" "$(( $(date +%s) - 1000 ))" >"$RECORDS/scale-primaries"
rm -f "$RECORDS/scale-dark"
: >"$calls"
rc=0; fleet_watch_tick >/dev/null 2>&1 || rc=$?
record "scale-to-zero: off by default, the idle VM stays up" "0/0/0" \
  "$rc/$(called '^scale:stop')/$(called 'scaled to zero')"

# 9. Scale-to-zero needs the idle clock to prove the cooldown: a VM seen
# Running again starts a fresh stamp, so a fresh line means no stop
# shellcheck disable=SC2034  # read by the tick
HOMEFIELD_SCALE_ZERO=1
printf '%s|https://github.com/org/repo|homefield-ci||%s|1\n' \
  "homefield-1" "$(date +%s)" >"$RECORDS/scale-primaries"
rm -f "$RECORDS/scale-dark"
: >"$calls"
rc=0; fleet_watch_tick >/dev/null 2>&1 || rc=$?
record "scale-to-zero: a fresh idle clock, the cooldown is not proven" "0/0/0" \
  "$rc/$(called '^scale:stop')/$(called 'scaled to zero')"

# 10. Wake-from-zero: queued demand starts the dark VM
# shellcheck disable=SC2034  # read by the tick
HOMEFIELD_SCALE_ZERO=""
VM1_STATUS="Stopped"
QUEUED_SINCE="$(( $(date +%s) - 1000 ))"
printf 'homefield-ci org/repo github.com\n' >"$HOMEFIELD_STATE_DIR/routing"
printf 'homefield-1|https://github.com/org/repo|homefield-ci|1\n' >"$RECORDS/scale-dark"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
record "wake-from-zero: queued demand starts the dark VM" "1/yes" \
  "$(called '^scale:start --instance homefield-1$')/$(has "$out" 'from zero')"
record "wake-from-zero: the runner comes online before the restore is asked" "1" \
  "$(called '^restore:https://github.com/org/repo:mac-1$')"
record "wake-from-zero: the dark line is dropped once the VM is up" "no" \
  "$(grep -q '^homefield-1|' "$RECORDS/scale-dark" 2>/dev/null && echo yes || echo no)"

# 11. Wake-from-zero: hosted activity on a flipped repo wakes at once
rm -f "$HOMEFIELD_STATE_DIR/routing"
printf 'homefield-ci org/repo github.com\n' >"$HOMEFIELD_STATE_DIR/autoflip"
HOSTED_SINCE="$(( $(date +%s) - 5 ))"
QUEUED_SINCE=""
printf 'homefield-1|https://github.com/org/repo|homefield-ci|1\n' >"$RECORDS/scale-dark"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
record "wake-from-zero: hosted activity wakes at once, no wait" "1/yes" \
  "$(called '^scale:start --instance homefield-1$')/$(has "$out" 'hosted runners')"

# 11b. The wake passes the autoflip entry's option fields to the demand
# lookup (#315): a six-field entry carries the consumer's guard options, a
# legacy three-field entry reads as the guard's defaults. The function
# stub records its arguments for the assertion.
hosted_activity_since() {
  printf 'hosted-activity:%s\n' "$*" >>"$calls"
  [ -n "${HOSTED_SINCE:-}" ] && printf '%s\n' "$HOSTED_SINCE"
  return 0
}
printf 'homefield-ci org/repo github.com push local simple\n' >"$HOMEFIELD_STATE_DIR/autoflip"
HOSTED_SINCE="$(( $(date +%s) - 5 ))"
QUEUED_SINCE=""
printf 'homefield-1|https://github.com/org/repo|homefield-ci|1\n' >"$RECORDS/scale-dark"
: >"$calls"
fleet_watch_tick >/dev/null 2>&1 || true
record "wake-from-zero: the entry's option fields reach the demand lookup" "1" \
  "$(called '^hosted-activity:org/repo github.com push local simple$')"
printf 'homefield-ci org/repo github.com\n' >"$HOMEFIELD_STATE_DIR/autoflip"
printf 'homefield-1|https://github.com/org/repo|homefield-ci|1\n' >"$RECORDS/scale-dark"
: >"$calls"
fleet_watch_tick >/dev/null 2>&1 || true
record "wake-from-zero: a legacy three-field entry reads as the defaults" "1" \
  "$(called '^hosted-activity:org/repo github.com pull_request hosted guards$')"
# Restore the suite's function-level stub for the sections below.
hosted_activity_since() { [ -n "${HOSTED_SINCE:-}" ] && printf '%s\n' "$HOSTED_SINCE"; return 0; }

# 12. A hand-stopped VM stays down: no dark line, no wake
rm -f "$RECORDS/scale-dark" "$HOMEFIELD_STATE_DIR/autoflip"
printf 'homefield-ci org/repo github.com\n' >"$HOMEFIELD_STATE_DIR/routing"
QUEUED_SINCE="$(( $(date +%s) - 1000 ))"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
record "wake-from-zero: a hand-stopped VM stays down (no dark line)" "0/0/yes" \
  "$rc/$(called '^scale:start')/$(has "$out" 'no VM the scaler stopped is dark')"

# 13. A dark line is dropped the moment its VM is seen Running
VM1_STATUS="Running"
QUEUED_SINCE=""
printf 'homefield-1|https://github.com/org/repo|homefield-ci|1\n' >"$RECORDS/scale-dark"
fleet_watch_tick >/dev/null 2>&1 || true
record "the dark line drops the moment its VM is Running" "no" \
  "$(grep -q '^homefield-1|' "$RECORDS/scale-dark" 2>/dev/null && echo yes || echo no)"

# 14. An unreadable VM status blocks the wake (fail safe)
VM1_STATUS=""
QUEUED_SINCE="$(( $(date +%s) - 1000 ))"
printf 'homefield-1|https://github.com/org/repo|homefield-ci|1\n' >"$RECORDS/scale-dark"
printf '%s|https://github.com/org/repo|homefield-ci|1|%s|0\n' \
  "homefield-1" "$(( $(date +%s) - 10 ))" >"$RECORDS/scale-primaries"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
record "wake-from-zero: an unreadable status blocks the wake (fail safe)" "0/nonzero/yes" \
  "$(called '^scale:start')/$(nonzero "$rc")/$(has "$out" 'not waking a dark fleet')"

# 15. The restore retry: a Running online auto_route VM restores flipped repos
VM1_STATUS="Running"
QUEUED_SINCE=""
AUTO_ROUTE=1
rm -f "$RECORDS/scale-dark" "$HOMEFIELD_STATE_DIR/routing"
printf 'homefield-ci org/repo github.com\n' >"$HOMEFIELD_STATE_DIR/autoflip"
: >"$calls"
rc=0; fleet_watch_tick >/dev/null 2>&1 || rc=$?
record "the restore retry: a Running online auto_route VM restores flipped repos" "1/0" \
  "$(called '^restore:https://github.com/org/repo:mac-1$')/$(nonzero "$rc")"

# 16. A stop that exits nonzero but stopped the VM anyway (the fallback's
# flip could not be proven) still counts as dark: the dark line is written
HOMEFIELD_SCALE_ZERO=1
SCALE_STOP_RC=1
VM1_STATUS="Running"
printf '%s|https://github.com/org/repo|homefield-ci||%s|1\n' \
  "homefield-1" "$(( $(date +%s) - 1000 ))" >"$RECORDS/scale-primaries"
rm -f "$RECORDS/scale-dark" "$RECORDS/scale" "$HOMEFIELD_STATE_DIR/routing" \
  "$HOMEFIELD_STATE_DIR/autoflip"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
dark_landed="no"; grep -q '^homefield-1|' "$RECORDS/scale-dark" && dark_landed="yes"
record "scale-to-zero: a stop that landed despite its fallback failing is dark" "yes/no/yes" \
  "$(has "$out" 'scaled to zero')/$(has "$out" 'it stays up')/$dark_landed"
SCALE_STOP_RC=0

# 17. The dark record survives a cross-tick dark: the primary goes first,
# the secondary idles out on a later tick, and both stay wake-eligible
HOMEFIELD_SCALE_ZERO=1
FLEET_LIST="homefield-1 homefield-2"
VM1_STATUS="Running"
VM2_STATUS="Running"
ZERO_STOPPED=""
printf '%s|https://github.com/org/repo|homefield-ci||%s|1\n' \
  "homefield-1" "$(( $(date +%s) - 1000 ))" >"$RECORDS/scale-primaries"
printf 'homefield-2|homefield-ci|github.com|https://github.com/org/repo||%s\n' \
  "$(date +%s)" >"$RECORDS/scale"
rm -f "$RECORDS/scale-dark" "$HOMEFIELD_STATE_DIR/routing" "$HOMEFIELD_STATE_DIR/autoflip"
: >"$calls"
fleet_watch_tick >/dev/null 2>&1 || true
record "scale-to-zero: the primary stops while a secondary runs, its dark line lands" "yes/no" \
  "$(grep -q '^homefield-1|' "$RECORDS/scale-dark" && echo yes || echo no)/$(grep -q '^homefield-2|' "$RECORDS/scale-dark" && echo yes || echo no)"
printf 'homefield-2|homefield-ci|github.com|https://github.com/org/repo||%s\n' \
  "$(( $(date +%s) - 1000 ))" >"$RECORDS/scale"
: >"$calls"
fleet_watch_tick >/dev/null 2>&1 || true
record "scale-to-zero: the secondary's later stop lands its dark line too" "yes/yes" \
  "$(grep -q '^homefield-1|' "$RECORDS/scale-dark" && echo yes || echo no)/$(grep -q '^homefield-2|' "$RECORDS/scale-dark" && echo yes || echo no)"

# 18. The wake matches the demand's registration scope, not just the label:
# two repo-scoped VMs share the default label, and only the one whose scope
# covers the repository may start
# shellcheck disable=SC2034  # read by the tick
HOMEFIELD_SCALE_ZERO=""
FLEET_LIST="homefield-1 homefield-2"
VM1_STATUS="Stopped"
VM2_STATUS="Stopped"
QUEUED_SINCE="$(( $(date +%s) - 1000 ))"
printf 'homefield-ci org/repo github.com\n' >"$HOMEFIELD_STATE_DIR/routing"
printf 'homefield-1|https://github.com/org/other|homefield-ci|1\n' >"$RECORDS/scale-dark"
printf 'homefield-2|https://github.com/org/repo|homefield-ci|2\n' >>"$RECORDS/scale-dark"
: >"$calls"
fleet_watch_tick >/dev/null 2>&1 || true
record "wake-from-zero: the scope-matching VM starts, the same-label other does not" "0/1" \
  "$(called '^scale:start --instance homefield-1$')/$(called '^scale:start --instance homefield-2$')"

# 19. No dark VM serves the demand: the fleet stays dark and says so,
# instead of starting an unrelated VM and dropping its dark line
rm -f "$RECORDS/scale-dark"
printf 'homefield-1|https://github.com/org/other|homefield-ci|1\n' >"$RECORDS/scale-dark"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
record "wake-from-zero: no VM serves the demand, the fleet stays dark (fail safe)" "0/0/yes" \
  "$rc/$(called '^scale:start')/$(has "$out" 'no dark VM here serves')"

# 20. A dark VM wakes while another scope's VM runs (#305's own repro):
# homefield-1 (org/other) runs busy, homefield-2 (org/repo) is dark; the
# queued demand for org/repo wakes homefield-2 — the grow side cannot
# serve it (no running VM covers the repo) and must not strand it
FLEET_LIST="homefield-1 homefield-2"
VM1_STATUS="Running"
VM2_STATUS="Stopped"
JOB_RC=0
ZERO_STOPPED=""
RS_URL_1="https://github.com/org/other"
printf 'homefield-2|https://github.com/org/repo|homefield-ci|2\n' >"$RECORDS/scale-dark"
printf '%s|https://github.com/org/other|homefield-ci||%s|1\n' \
  "homefield-1" "$(date +%s)" >"$RECORDS/scale-primaries"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
record "wake-from-zero: a dark VM wakes while another scope's VM runs" "1/yes" \
  "$(called '^scale:start --instance homefield-2$')/$(has "$out" 'from zero')"
record "wake-from-zero: the running other-scope VM is left alone" "0" \
  "$(called '^scale:start --instance homefield-1$')"

# 21. An organization runner's group must admit the demand's repository:
# two org-scoped dark VMs share the label, and only the one whose group
# covers the repo may start
RS_URL_1="https://github.com/org"
VM1_STATUS="Stopped"
JOB_RC=1
printf 'homefield-1|https://github.com/org|homefield-ci|1\n' >"$RECORDS/scale-dark"
printf 'homefield-2|https://github.com/org|homefield-ci|2\n' >>"$RECORDS/scale-dark"
SERVES_ID=1
SERVES_RC=1
SERVES_RC_OTHER=0
: >"$calls"
fleet_watch_tick >/dev/null 2>&1 || true
record "wake-from-zero: the group-matching VM starts, the excluded one does not" "0/1" \
  "$(called '^scale:start --instance homefield-1$')/$(called '^scale:start --instance homefield-2$')"

# 22. A group that cannot be asked blocks the wake (fail safe): neither
# org-scoped VM may start on an unanswerable group lookup
SERVES_RC=2
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
record "wake-from-zero: an unanswerable group lookup blocks the wake" "0/0/yes" \
  "$rc/$(called '^scale:start')/$(has "$out" 'no dark VM here serves')"
SERVES_ID=""
SERVES_RC=""
SERVES_RC_OTHER=""

# 23. A secondary the scaler stopped (the spare pass) is dark by its hand
# and wakes on its demand, the same as a primary
# shellcheck disable=SC2034  # read by the tick
HOMEFIELD_SCALE_ZERO=1
FLEET_LIST="homefield-2"
VM2_STATUS="Running"
JOB2_RC=1
ZERO_STOPPED=""
printf 'homefield-2|homefield-ci|github.com|https://github.com/org/repo||%s\n' \
  "$(( $(date +%s) - 1000 ))" >"$RECORDS/scale"
rm -f "$RECORDS/scale-dark" "$RECORDS/scale-primaries" "$HOMEFIELD_STATE_DIR/routing" \
  "$HOMEFIELD_STATE_DIR/autoflip"
: >"$calls"
fleet_watch_tick >/dev/null 2>&1 || true
record "scale-to-zero: a stopped secondary lands its dark line" "yes" \
  "$(grep -q '^homefield-2|https://github.com/org/repo|homefield-ci|2$' "$RECORDS/scale-dark" && echo yes || echo no)"
QUEUED_SINCE="$(( $(date +%s) - 1000 ))"
printf 'homefield-ci org/repo github.com\n' >"$HOMEFIELD_STATE_DIR/routing"
: >"$calls"
rc=0; fleet_watch_tick >/dev/null 2>&1 || rc=$?
record "wake-from-zero: the dark secondary wakes on its demand" "1/0" \
  "$(called '^scale:start --instance homefield-2$')/$(nonzero "$rc")"

# 24. A secondary the user stopped by hand has no dark line and stays down
VM2_STATUS="Stopped"
rm -f "$RECORDS/scale-dark"
: >"$calls"
rc=0; fleet_watch_tick >/dev/null 2>&1 || rc=$?
record "wake-from-zero: a hand-stopped secondary stays down" "0/0" \
  "$rc/$(called '^scale:start')"

# 25. A stop needs a usable wake identity in the record: the identity
# cannot be read through a stopped guest, so a VM stopped without one
# could never match demand again — and GitHub's listing failing at
# refresh time is exactly when the record goes without it. The tick
# defers the stop to a tick whose refresh captured the identity.
HOMEFIELD_SCALE_ZERO=1
FLEET_LIST="homefield-1"
VM1_STATUS="Running"
JOB_RC=1
ZERO_STOPPED=""
GH_ROWS_FAIL=1
printf '%s|https://github.com/org/repo|||%s|1|\n' \
  "homefield-1" "$(( $(date +%s) - 1000 ))" >"$RECORDS/scale-primaries"
rm -f "$RECORDS/scale-dark" "$RECORDS/scale" "$HOMEFIELD_STATE_DIR/routing" \
  "$HOMEFIELD_STATE_DIR/autoflip"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
dark_landed="no"; grep -q '^homefield-1|' "$RECORDS/scale-dark" 2>/dev/null && dark_landed="yes"
record "scale-to-zero: a stop without a recorded wake identity is deferred" \
  "0/yes/no/nonzero" \
  "$(called '^scale:stop')/$(has "$out" 'no wake identity recorded')/$dark_landed/$(nonzero "$rc")"
GH_ROWS_FAIL=""

# 26. The spare pass reads the secondary's identity before it stops it, so
# a read that fails while the VM runs defers the stop — the VM keeps
# running until its identity can be read, instead of going down
# unmatched
# shellcheck disable=SC2034  # read by the tick
HOMEFIELD_SCALE_ZERO=1
FLEET_LIST="homefield-2"
VM2_STATUS="Running"
ZERO_STOPPED=""
RS_READ_FAIL=1
printf 'homefield-2|homefield-ci|github.com|https://github.com/org/repo||%s\n' \
  "$(( $(date +%s) - 1000 ))" >"$RECORDS/scale"
rm -f "$RECORDS/scale-dark" "$RECORDS/scale-primaries" \
  "$HOMEFIELD_STATE_DIR/routing" "$HOMEFIELD_STATE_DIR/autoflip"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
dark_landed="no"; grep -q '^homefield-2|' "$RECORDS/scale-dark" 2>/dev/null && dark_landed="yes"
record "scale-to-zero: a secondary whose identity read fails keeps running" \
  "0/yes/no/nonzero" \
  "$(called '^scale:stop')/$(has "$out" 'wake identity')/$dark_landed/$(nonzero "$rc")"
RS_READ_FAIL=""

# 27. A dark record the tick cannot write must not become a stop: the
# record is the only proof the VM is dark by the scaler's hand, and a
# write that failed after the stop would leave the VM down with no wake
# eligibility — the next tick reads the stale file and treats the VM as
# hand-stopped. The write happens before the stop, and a failed write
# defers it. (The read-only state dir makes the real write fail.)
# shellcheck disable=SC2034  # read by the tick
HOMEFIELD_SCALE_ZERO=1
FLEET_LIST="homefield-1"
VM1_STATUS="Running"
JOB_RC=1
ZERO_STOPPED=""
printf '%s|https://github.com/org/repo|homefield-ci||%s|1|101\n' \
  "homefield-1" "$(( $(date +%s) - 1000 ))" >"$RECORDS/scale-primaries"
rm -f "$RECORDS/scale-dark" "$RECORDS/scale" "$HOMEFIELD_STATE_DIR/routing" \
  "$HOMEFIELD_STATE_DIR/autoflip"
chmod 555 "$RECORDS"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
chmod 755 "$RECORDS"
dark_landed="no"; grep -q '^homefield-1|' "$RECORDS/scale-dark" 2>/dev/null && dark_landed="yes"
record "scale-to-zero: a dark record the tick cannot write stops nothing" \
  "0/yes/no/nonzero" \
  "$(called '^scale:stop')/$(has "$out" 'could not write')/$dark_landed/$(nonzero "$rc")"

# 28. The same for the spare pass: a secondary whose dark line cannot be
# persisted keeps running until the write lands
FLEET_LIST="homefield-2"
VM2_STATUS="Running"
ZERO_STOPPED=""
printf 'homefield-2|homefield-ci|github.com|https://github.com/org/repo||%s\n' \
  "$(( $(date +%s) - 1000 ))" >"$RECORDS/scale"
rm -f "$RECORDS/scale-dark" "$RECORDS/scale-primaries"
chmod 555 "$RECORDS"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
chmod 755 "$RECORDS"
dark_landed="no"; grep -q '^homefield-2|' "$RECORDS/scale-dark" 2>/dev/null && dark_landed="yes"
record "scale-to-zero: a secondary whose dark record cannot be written keeps running" \
  "0/yes/no/nonzero" \
  "$(called '^scale:stop')/$(has "$out" 'could not write')/$dark_landed/$(nonzero "$rc")"

# 29. A woken secondary gets a fresh idle clock: its stamp already
# exceeded the cooldown when it was stopped, and without the reset the
# next tick would stop it again before it can pick up a job — the same
# reset the grow side's secondary start does
# shellcheck disable=SC2034  # read by the tick
HOMEFIELD_SCALE_ZERO=""
FLEET_LIST="homefield-2"
VM2_STATUS="Stopped"
QUEUED_SINCE="$(( $(date +%s) - 1000 ))"
printf 'homefield-2|homefield-ci|github.com|https://github.com/org/repo||%s\n' \
  "$(( $(date +%s) - 1000 ))" >"$RECORDS/scale"
printf 'homefield-2|https://github.com/org/repo|homefield-ci|2\n' >"$RECORDS/scale-dark"
printf 'homefield-ci org/repo github.com\n' >"$HOMEFIELD_STATE_DIR/routing"
: >"$calls"
rc=0; fleet_watch_tick >/dev/null 2>&1 || rc=$?
busy_now="$(cut -d'|' -f6 "$RECORDS/scale" 2>/dev/null || printf '0')"
record "wake-from-zero: the woken secondary's idle clock resets" "1/yes" \
  "$(called '^scale:start --instance homefield-2$')/$( [ "${busy_now:-0}" -ge "$(( $(date +%s) - 60 ))" ] && echo yes || echo no)"

# 30. A start that landed but did not prove out (the restore failed)
# still ends the wake pass: the VM is up and eligible, one VM per tick,
# and a second start could not serve the next demand any better than
# the runner that is already online — while the nonzero return keeps
# the restore failure visible
FLEET_LIST="homefield-1 homefield-2"
VM1_STATUS="Stopped"
VM2_STATUS="Stopped"
ZERO_STOPPED=""
QUEUED_SINCE="$(( $(date +%s) - 1000 ))"
printf 'homefield-ci org/repo github.com\nhomefield-ci org/other github.com\n' \
  >"$HOMEFIELD_STATE_DIR/routing"
printf 'homefield-1|https://github.com/org/repo|homefield-ci|1\n' >"$RECORDS/scale-dark"
printf 'homefield-2|https://github.com/org/other|homefield-ci|2\n' >>"$RECORDS/scale-dark"
RESTORE_RC=1
: >"$calls"
rc=0; fleet_watch_tick >/dev/null 2>&1 || rc=$?
RESTORE_RC=""
line1_gone="yes"; grep -q '^homefield-1|' "$RECORDS/scale-dark" 2>/dev/null && line1_gone="no"
line2_kept="no"; grep -q '^homefield-2|' "$RECORDS/scale-dark" 2>/dev/null && line2_kept="yes"
started2="$(called '^scale:start --instance homefield-2$')"
record "wake-from-zero: a start that landed but did not prove out ends the pass" \
  "1/0/nonzero/yes/yes" \
  "$(called '^scale:start --instance homefield-1$')/$started2/$(nonzero "$rc")/$line1_gone/$line2_kept"

# 31. A queued demand an idle running runner already serves wakes no dark
# VM for the same scope: the run is waiting on workflow dependencies no
# runner can help, or on a runner the idle cooldown is about to retire,
# and a dark VM started for it would idle out behind the same wait. An
# unrelated scope's dark VM still wakes, and the idle runner itself is
# left alone
# shellcheck disable=SC2034  # read by the tick
HOMEFIELD_SCALE_ZERO=""
FLEET_LIST="homefield-1 homefield-2 homefield-3"
VM1_STATUS="Running"
VM2_STATUS="Stopped"
VM3_STATUS="Stopped"
ZERO_STOPPED=""
QUEUED_SINCE="$(( $(date +%s) - 1000 ))"
printf 'homefield-ci org/repo github.com\nhomefield-ci2 org/other github.com\n' \
  >"$HOMEFIELD_STATE_DIR/routing"
printf 'homefield-1|https://github.com/org/repo|homefield-ci||%s|1|1\n' \
  "$(date +%s)" >"$RECORDS/scale-primaries"
printf 'homefield-2|https://github.com/org/repo|homefield-ci|2\n' >"$RECORDS/scale-dark"
printf 'homefield-3|https://github.com/org/other|homefield-ci2|3\n' >>"$RECORDS/scale-dark"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
line2_kept="no"; grep -q '^homefield-2|' "$RECORDS/scale-dark" 2>/dev/null && line2_kept="yes"
line3_gone="yes"; grep -q '^homefield-3|' "$RECORDS/scale-dark" 2>/dev/null && line3_gone="no"
started3="$(called '^scale:start --instance homefield-3$')"
record "wake-from-zero: an idle running runner already serving the demand wakes no dark VM for it" \
  "0/1/yes/yes/yes/0" \
  "$(called '^scale:start --instance homefield-2$')/$started3/$line2_kept/$line3_gone/$(has "$out" 'already serves')/$(nonzero "$rc")"

# 32. A partly-running fleet whose third VM's status could not be read
# wakes nothing: that VM may already be running and serving the demand —
# the same guard the fully-dark fleet applies, which the partly-running
# call used to bypass
FLEET_LIST="homefield-1 homefield-2 homefield-3"
VM1_STATUS="Running"
VM2_STATUS="Stopped"
VM3_STATUS=""
ZERO_STOPPED=""
rm -f "$RECORDS/scale-primaries"
printf 'homefield-ci org/repo github.com\n' >"$HOMEFIELD_STATE_DIR/routing"
printf 'homefield-2|https://github.com/org/repo|homefield-ci|2\n' >"$RECORDS/scale-dark"
: >"$calls"
rc=0; out="$(fleet_watch_tick 2>&1)" || rc=$?
line2_kept="no"; grep -q '^homefield-2|' "$RECORDS/scale-dark" 2>/dev/null && line2_kept="yes"
record "wake-from-zero: an unreadable status blocks the partly-running wake too" \
  "0/yes/yes/nonzero" \
  "$(called '^scale:start')/$line2_kept/$(has "$out" 'could not ask Lima')/$(nonzero "$rc")"

# 33. hosted_activity_since counts a run only when the consumer's routing
# expression would have sent it to the local runner (#315): the record's
# option fields (events, dependabot, mode) filter the run's own metadata —
# event, actor, head branch, head repository. A scheduled workflow, a
# Dependabot PR or a fork PR can never take the runner, and reading one as
# demand would wake a dark VM on a schedule instead of on work; a run
# listed queued forever with no jobs behind it is not demand either.
# The suite stubbed the function above; re-source the real one. The gh
# stub applies the call's --jq to the canned JSON with the system jq, so
# the filter itself is what is under test.
# shellcheck source=bin/cmd-fleet.sh
. "$ROOT/bin/cmd-fleet.sh"
GH_MODE="hosted-activity"
JOBS="$TMP/gh-jobs"
mkdir -p "$JOBS"
# The queued page: every kind of run the filter must tell apart. 1001 is a
# Dependabot PR (actor and branch), 1002 a scheduled workflow, 1003 a fork
# PR, 1004 the only run the defaults count, 1005 a same-repo PR with no
# active jobs behind it (the zombie shape #312 fixed), 1006 a push.
cat > "$TMP/gh-runs-queued.json" <<'EOF'
{"total_count":6,"workflow_runs":[
  {"id":1001,"created_at":"2026-11-11T19:30:00Z","event":"pull_request","actor":{"login":"dependabot[bot]"},"head_branch":"dependabot/npm_and_yarn/jest-dom","head_repository":{"full_name":"org/repo"},"repository":{"full_name":"org/repo"}},
  {"id":1002,"created_at":"2026-11-11T21:00:00Z","event":"schedule","actor":{"login":"tom-bot-for-rana[bot]"},"head_branch":"main","head_repository":{"full_name":"org/repo"},"repository":{"full_name":"org/repo"}},
  {"id":1003,"created_at":"2026-11-11T19:00:00Z","event":"pull_request","actor":{"login":"bob"},"head_branch":"patch","head_repository":{"full_name":"fork/other"},"repository":{"full_name":"org/repo"}},
  {"id":1004,"created_at":"2026-11-11T20:30:50Z","event":"pull_request","actor":{"login":"alice"},"head_branch":"feature/x","head_repository":{"full_name":"org/repo"},"repository":{"full_name":"org/repo"}},
  {"id":1005,"created_at":"2026-11-10T10:00:00Z","event":"pull_request","actor":{"login":"alice"},"head_branch":"feature/zombie","head_repository":{"full_name":"org/repo"},"repository":{"full_name":"org/repo"}},
  {"id":1006,"created_at":"2026-11-11T18:00:00Z","event":"push","actor":{"login":"alice"},"head_branch":"main","head_repository":{"full_name":"org/repo"},"repository":{"full_name":"org/repo"}}
]}
EOF
cat > "$TMP/gh-runs-progress.json" <<'EOF'
{"total_count":0,"workflow_runs":[]}
EOF
for n in 1001 1002 1003 1004 1006; do
  printf '{"total_count":1,"jobs":[{"id":5%03d,"status":"queued"}]}\n' "$n" >"$JOBS/$n.json"
done
printf '{"total_count":1,"jobs":[{"id":505,"status":"completed"}]}\n' >"$JOBS/1005.json"
export GH_MODE
export GH_RUNS_QUEUED_JSON="$TMP/gh-runs-queued.json"
export GH_RUNS_PROGRESS_JSON="$TMP/gh-runs-progress.json"
export GH_JOBS_DIR="$JOBS"
export GH_RUNS_FAIL GH_JOBS_FAIL

# The defaults — the guard's defaults, which is also what a legacy
# three-field record reads as — count only the same-repo, non-Dependabot
# pull_request run with active jobs: the Dependabot PR (1001), the
# schedule (1002), the fork PR (1003), the jobless zombie (1005) and the
# push (1006) all stay out, and any one of them counting would show up as
# an earlier timestamp than 1004's.
since="$(hosted_activity_since org/repo github.com)"
record "hosted-activity: the defaults count only the routable run" \
  "$(iso_to_epoch '2026-11-11T20:30:50Z')" "$since"

since="$(hosted_activity_since org/repo github.com push,pull_request)"
record "hosted-activity: a record naming push counts the push run too" \
  "$(iso_to_epoch '2026-11-11T18:00:00Z')" "$since"

since="$(hosted_activity_since org/repo github.com pull_request local)"
record "hosted-activity: a dependabot=local record counts the Dependabot run" \
  "$(iso_to_epoch '2026-11-11T19:30:00Z')" "$since"

since="$(hosted_activity_since org/repo github.com pull_request hosted simple)"
record "hosted-activity: a simple-mode record counts every active run" \
  "$(iso_to_epoch '2026-11-11T18:00:00Z')" "$since"

record "hosted-activity: an event nothing runs is no demand" "0" \
  "$(hosted_activity_since org/repo github.com workflow_dispatch | wc -l | tr -d ' ')"

GH_RUNS_FAIL=1
record "hosted-activity: an unreadable runs list fails safe" "1" \
  "$(hosted_activity_since org/repo github.com >/dev/null 2>&1; echo $?)"
GH_RUNS_FAIL=""
GH_JOBS_FAIL=1
record "hosted-activity: an unreadable jobs list fails safe" "1" \
  "$(hosted_activity_since org/repo github.com >/dev/null 2>&1; echo $?)"
unset GH_MODE GH_RUNS_QUEUED_JSON GH_RUNS_PROGRESS_JSON GH_JOBS_DIR GH_RUNS_FAIL GH_JOBS_FAIL

summary
