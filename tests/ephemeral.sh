#!/usr/bin/env bash
# tests/ephemeral.sh — --ephemeral install, re-register, --watch loop, and
# failure visibility.
#
# Run:  bash tests/ephemeral.sh
# Exit: 0 when every case passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/homefield-ephemeral-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

STUBS="$TMP/stubs"
mkdir -p "$STUBS"
for t in awk bash cat cut dirname git grep head mktemp mv rm mkdir sed sh sleep tr wc; do
  ln -s "$(command -v "$t")" "$STUBS/$t"
done

cat >"$STUBS/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -s) echo Darwin ;;
  -m) echo arm64 ;;
esac
EOF
cat >"$STUBS/limactl" <<'EOF'
#!/bin/sh
case "${1:-}" in
  --version) echo "limactl version 2.3.0" ;;
  list) echo "homefield Running" ;;
esac
EOF
cat >"$STUBS/gh" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$STUBS/scutil" <<'EOF'
#!/bin/sh
echo "Test-Mac"
EOF
chmod +x "$STUBS/uname" "$STUBS/limactl" "$STUBS/gh" "$STUBS/scutil"

WORK="$TMP/work"
mkdir -p "$WORK/home/.lima/homefield" "$WORK/state"
printf '# Lima VM for the local GitHub Actions runner.\n' >"$WORK/home/.lima/homefield/lima.yaml"

CALLS="$WORK/calls.log"
HARNESS="$WORK/harness.sh"
cat >"$HARNESS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HOMEFIELD_SOURCE_ONLY=1
. "$REPO_ROOT/bin/homefield"
check_host() { :; }
verify_isolation() { :; }
ensure_vm() { :; }
enable_autostart() { :; }
cmd_preflight() { return 0; }
ensure_group() { GROUP_STATE=narrow; GROUP_ID=7; }
check_name_free() { :; }
remove_taken_name() { :; }
get_token() {
  echo "get_token:$*" >>"$CALLS"
  [ "${STUB_TOKEN_FAIL:-0}" = "0" ] || return 1
  printf 'stub-tok-123\n'
}
run_provision() {
  local input="$1"; shift
  echo "run_provision:cmd=${PROVISION_CMD:-default}:input=${input//$'\n'/ }:env=$*" >>"$CALLS"
  [ "${STUB_PROV_FAIL:-0}" = "0" ] || return 1
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
wait_online() { echo "wait_online:$*" >>"$CALLS"; }
warm_vm() { WARM_STATE="warm"; WARM_DETAIL=""; }
is_job_running() { return "${STUB_JOB_RC:-1}"; }
is_registered() { return 1; }
runner_service_state() { return "${STUB_SVC_RC:-0}"; }
"$@"
EOF

hrun() {
  : >"$CALLS"
  out="$(env -i \
    HOME="$WORK/home" \
    PATH="$STUBS" \
    REPO_ROOT="$REPO_ROOT" \
    CALLS="$CALLS" \
    HOMEFIELD_STATE_DIR="$WORK/state" \
    STUB_TOKEN_FAIL="${STUB_TOKEN_FAIL:-0}" \
    STUB_PROV_FAIL="${STUB_PROV_FAIL:-0}" \
    STUB_JOB_RC="${STUB_JOB_RC:-1}" \
    STUB_SVC_RC="${STUB_SVC_RC:-0}" \
    bash "$HARNESS" "$@" 2>&1 </dev/null)"
  rc=$?
}

# 1. re-register refuses non-ephemeral instance
rm -rf "$WORK/state"/*
hrun cmd_re_register
record "non-ephemeral: re-register refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" "not configured in ephemeral mode")"

# 2. install --ephemeral passes RUNNER_EPHEMERAL=1 and persists state
hrun cmd_install --url https://github.com/acme --org --ephemeral
calls="$(cat "$CALLS")"
st_body="$(cat "$WORK/state/homefield.state")"
record "install --ephemeral: passes RUNNER_EPHEMERAL=1 and sets state" "0/yes/yes/yes" "$rc/$(has "$calls" "RUNNER_EPHEMERAL=1")/$(has "$st_body" "ephemeral=1")/$(has "$st_body" "ephemeral_url=https://github.com/acme")"

# 3. re-register refuses when job is running
STUB_JOB_RC=0 hrun cmd_re_register
record "busy VM: re-register refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" "a job is running")"

# 4. re-register happy path: pipes token on stdin, runs PROVISION_CMD=re-register, waits online
STUB_JOB_RC=1 hrun cmd_re_register
calls="$(cat "$CALLS")"
record "re-register happy path: stdin token + PROVISION_CMD=re-register + wait_online" "0/yes/yes/yes" "$rc/$(has "$calls" "cmd=re-register")/$(has "$calls" "input=RUNNER_TOKEN=stub-tok-123")/$(has "$calls" "wait_online:https://github.com/acme")"

# 5. re-register failure path: sets ephemeral_error and exits nonzero
STUB_PROV_FAIL=1 STUB_JOB_RC=1 hrun cmd_re_register
st_body="$(cat "$WORK/state/homefield.state")"
record "re-register failure: exits nonzero and records ephemeral_error" "nonzero/yes" "$(nonzero "$rc")/$(has "$st_body" "ephemeral_error=re-registration failed")"

# 6. re-register --watch skips while service is running, re-registers when stopped
STUB_SVC_RC=0 STUB_JOB_RC=1 hrun cmd_re_register --watch --interval 0 --max-cycles 2
calls="$(cat "$CALLS")"
record "--watch while service running: does not re-register" "0/no" "$rc/$(has "$calls" "cmd=re-register")"

STUB_SVC_RC=1 STUB_JOB_RC=1 hrun cmd_re_register --watch --interval 0 --max-cycles 1
calls="$(cat "$CALLS")"
record "--watch when service stopped (job finished): re-registers" "0/yes/yes" "$rc/$(has "$out" "finished a job; re-registering")/$(has "$calls" "cmd=re-register")"

summary
