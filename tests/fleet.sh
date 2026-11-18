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
chmod +x "$TMP/bin/limactl" "$TMP/bin/gh"

# Source bin/homefield in a subshell-safe way.
HOMEFIELD_SOURCE_ONLY=1
# shellcheck source=bin/homefield
. "$ROOT/bin/homefield"

MOCK_MODE="empty"

vm_instances() {
  case "$MOCK_MODE" in
    empty) return 0 ;;
    multi) printf '%s\n' "homefield-1" "homefield-2" ;;
    busy|single) printf '%s\n' "homefield-1" ;;
  esac
}

# shellcheck disable=SC2034
st_collect() {
  case "$MOCK_MODE:$INSTANCE" in
    multi:homefield-1)
      ST_STATUS="Running"
      ST_NAME="mac-1"
      ST_GH="online"
      ST_SVC="active"
      ST_JOB="idle"
      ;;
    multi:homefield-2)
      ST_STATUS="Running"
      ST_NAME="mac-2"
      ST_GH="offline"
      ST_SVC="inactive"
      ST_JOB="—"
      ;;
    busy:homefield-1|single:homefield-1)
      ST_STATUS="Running"
      ST_NAME="mac-1"
      ST_GH="online"
      ST_SVC="active"
      ST_JOB="running"
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
assert d["vms"][0]["instance"] == "homefield-1" and d["vms"][0]["mode"] == "persistent"
assert d["vms"][1]["instance"] == "homefield-2" and d["vms"][1]["mode"] == "ephemeral"
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

summary
