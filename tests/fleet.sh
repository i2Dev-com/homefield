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
runners_on_github() { printf '1\tmac-1\tonline\tself-hosted,linux,arm64,homefield-ci\n'; }
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
route_start_restore() { printf 'restore:%s:%s\n' "$1" "$2" >>"$calls"; return 0; }
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

summary
