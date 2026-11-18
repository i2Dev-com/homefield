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
for t in awk bash cat chmod cp cut date dirname git grep head mktemp mv rm mkdir sed sh sleep tr wc; do
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

# 8. Real run_provision propagates guest_stdin failure inside cmd_re_register
REAL_PROV_HARNESS="$WORK/real_prov_harness.sh"
cat >"$REAL_PROV_HARNESS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HOMEFIELD_SOURCE_ONLY=1
. "$REPO_ROOT/bin/homefield"
check_host() { :; }
verify_isolation() { :; }
ensure_vm() { :; }
is_job_running() { return 1; }
get_token() { printf 'stub-tok-123\n'; }
guest_stage_dir() { echo "/tmp/stage-1"; }
guest_unstage() { :; }
guest_stdin() { return 42; }
runner_setting() { echo "test-mac-homefield"; }
wait_online() { :; }
cmd_re_register
EOF
state_set_err_out="$(env -i \
  HOME="$WORK/home" \
  PATH="$STUBS" \
  REPO_ROOT="$REPO_ROOT" \
  HOMEFIELD_STATE_DIR="$WORK/state" \
  bash "$REAL_PROV_HARNESS" 2>&1 </dev/null)"
real_prov_rc=$?
st_body="$(cat "$WORK/state/homefield.state")"
record "real run_provision: guest_stdin failure propagates and sets ephemeral_error" "nonzero/yes/yes" "$(nonzero "$real_prov_rc")/$(has "$state_set_err_out" "re-register: failed on homefield")/$(has "$st_body" "ephemeral_error=re-registration failed")"

# 9. provision.sh re_register restores previous registration on config.sh failure
REREG_WORK="$TMP/rereg"
mkdir -p "$REREG_WORK/runner"
printf '{"agentName":"old-runner"}\n' >"$REREG_WORK/runner/.runner"
printf '{"scheme":"OAuth"}\n' >"$REREG_WORK/runner/.credentials"
printf 'actions.runner.test.service\n' >"$REREG_WORK/runner/.service"
REREG_FN="$WORK/rereg_fn.sh"
sed -n '/^REREG_BACKUP_DIR=/,/^if /p' "$REPO_ROOT/vm/provision.sh" | sed '$d' >"$REREG_FN"
rereg_calls="$REREG_WORK/calls.log"
: >"$rereg_calls"
# shellcheck disable=SC2016  # inner bash -c expands its own vars
rereg_out="$(env -i \
  PATH="$STUBS" \
  RUNNER_HOME="$REREG_WORK/runner" \
  RUNNER_URL="https://github.com/acme" \
  RUNNER_TOKEN="tok-new" \
  RUNNER_NAME="test-runner" \
  RUNNER_LABELS="self-hosted,linux,arm64,homefield-ci" \
  RUNNER_GROUP="" \
  RUNNER_USER="runner" \
  REREG_CALLS="$rereg_calls" \
  bash -c '
    set -euo pipefail
    pgrep() { return 1; }
    systemctl() {
      case "${1:-}" in
        is-active) return 0 ;;
        *) echo "systemctl:$*" >>"$REREG_CALLS"; return 0 ;;
      esac
    }
    runner_config() { echo "runner_config" >>"$REREG_CALLS"; return 1; }
    ensure_service() { echo "ensure_service:$*" >>"$REREG_CALLS"; return 0; }
    . "$1"
    re_register
  ' _ "$REREG_FN" 2>&1)"
rereg_rc=$?
restored_runner="$(cat "$REREG_WORK/runner/.runner" 2>/dev/null || true)"
rereg_log="$(cat "$rereg_calls")"
record "provision.sh re_register failure: restores .runner and calls ensure_service --start" "nonzero/yes/yes/yes" "$(nonzero "$rereg_rc")/$(has "$rereg_out" "restored previous state")/$(has "$restored_runner" "old-runner")/$(has "$rereg_log" "ensure_service:--start")"

# 10. Persistent install clears previous ephemeral metadata
hrun cmd_install --url https://github.com/other-org --org
st_body="$(cat "$WORK/state/homefield.state")"
record "persistent install after ephemeral: clears ephemeral=1 and ephemeral_url" "0/yes/no" "$rc/$(has "$st_body" "ephemeral=0")/$(has "$st_body" "https://github.com/acme")"

# 11. Ephemeral install without --group/--label overwrites prior custom values
hrun cmd_install --url https://github.com/acme --org --ephemeral --group old-grp --label old-lbl
hrun cmd_install --url https://github.com/acme --org --ephemeral
st_body="$(cat "$WORK/state/homefield.state")"
record "ephemeral install with defaults: overwrites prior custom group and label" "0/no/no" "$rc/$(has "$st_body" "old-grp")/$(has "$st_body" "old-lbl")"

# 12. st_render_human surfaces ephemeral error even when ST_REG=no
hrun state_set ephemeral_error "re-registration failed"
# shellcheck disable=SC2016  # inner bash -c expands $REPO_ROOT
st_out="$(env -i HOME="$WORK/home" PATH="$STUBS" REPO_ROOT="$REPO_ROOT" HOMEFIELD_STATE_DIR="$WORK/state" /bin/bash -c '
  HOMEFIELD_SOURCE_ONLY=1
  . "$REPO_ROOT/bin/homefield"
  ST_CREATED=yes ST_STATUS=Running ST_LB_STATE=verified ST_ASKFAIL=0 ST_REG=no ST_SVC=stopped
  st_render_human
' 2>&1)"
record "status render with ST_REG=no and ephemeral_error: shows mode and ERROR" "yes/yes" "$(has "$st_out" "mode: ephemeral")/$(has "$st_out" "ephemeral: ERROR (re-registration failed)")"

# 13. provision.sh re_register restores via EXIT trap even if rm fails under set -e
: >"$rereg_calls"
# shellcheck disable=SC2016  # inner bash -c expands its own vars
rm_fail_rc=0
env -i \
  PATH="$STUBS" \
  RUNNER_HOME="$REREG_WORK/runner" \
  RUNNER_URL="https://github.com/acme" \
  RUNNER_TOKEN="tok-new" \
  RUNNER_NAME="test-runner" \
  RUNNER_LABELS="self-hosted,linux,arm64,homefield-ci" \
  RUNNER_GROUP="" \
  RUNNER_USER="runner" \
  REREG_CALLS="$rereg_calls" \
  /bin/bash -c '
    set -euo pipefail
    pgrep() { return 1; }
    systemctl() {
      case "${1:-}" in
        is-active) return 0 ;;
        *) return 0 ;;
      esac
    }
    rm() {
      case "$*" in
        *".runner"*) return 42 ;;
        *) command rm "$@" ;;
      esac
    }
    ensure_service() { echo "ensure_service:$*" >>"$REREG_CALLS"; return 0; }
    . "$1"
    re_register
  ' _ "$REREG_FN" >/dev/null 2>&1 || rm_fail_rc=$?
rereg_log="$(cat "$rereg_calls")"
record "provision.sh re_register rm failure: EXIT trap restores and calls ensure_service --start" "42/yes" "$rm_fail_rc/$(has "$rereg_log" "ensure_service:--start")"

# 14. provision.sh re_register reuses completed registration when ensure_service fails and is retried
RETRY_WORK="$TMP/rereg-retry"
mkdir -p "$RETRY_WORK/runner"
retry_calls="$RETRY_WORK/calls.log"
: >"$retry_calls"
# shellcheck disable=SC2016  # inner bash -c expands its own vars
env -i \
  PATH="$STUBS" \
  RUNNER_HOME="$RETRY_WORK/runner" \
  RUNNER_URL="https://github.com/acme" \
  RUNNER_TOKEN="tok-1" \
  RUNNER_NAME="test-runner" \
  RUNNER_LABELS="self-hosted,linux,arm64,homefield-ci" \
  RUNNER_GROUP="" \
  RUNNER_USER="runner" \
  RETRY_CALLS="$retry_calls" \
  /bin/bash -c '
    set -euo pipefail
    pgrep() { return 1; }
    systemctl() { return 0; }
    runner_config() { echo "runner_config" >>"$RETRY_CALLS"; : >"$RUNNER_HOME/.runner"; return 0; }
    ensure_service() { echo "ensure_service:fail" >>"$RETRY_CALLS"; return 1; }
    . "$1"
    re_register
  ' _ "$REREG_FN" >/dev/null 2>&1 || true
: >"$retry_calls"
# shellcheck disable=SC2016  # inner bash -c expands its own vars
retry_rc=0
env -i \
  PATH="$STUBS" \
  RUNNER_HOME="$RETRY_WORK/runner" \
  RUNNER_URL="https://github.com/acme" \
  RUNNER_TOKEN="tok-2" \
  RUNNER_NAME="test-runner" \
  RUNNER_LABELS="self-hosted,linux,arm64,homefield-ci" \
  RUNNER_GROUP="" \
  RUNNER_USER="runner" \
  RETRY_CALLS="$retry_calls" \
  /bin/bash -c '
    set -euo pipefail
    pgrep() { return 1; }
    systemctl() { return 0; }
    journalctl() { echo "Listening for Jobs"; }
    install() { :; }
    runner_config() { echo "runner_config" >>"$RETRY_CALLS"; return 1; }
    ensure_service() { echo "ensure_service:ok" >>"$RETRY_CALLS"; printf "actions.runner.test.service\n" >"$RUNNER_HOME/.service"; return 0; }
    . "$1"
    re_register
  ' _ "$REREG_FN" >/dev/null 2>&1 || retry_rc=$?
retry_log="$(cat "$retry_calls")"
record "provision.sh re_register retry after ensure_service failure: reuses registration without re-running config" "0/no/yes/no" "$retry_rc/$(has "$retry_log" "runner_config")/$(has "$retry_log" "ensure_service:ok")/$([ -f "$RETRY_WORK/runner/.re-register-pending" ] && echo yes || echo no)"

# 15. Retrying install --ephemeral on already-registered VM reconciles ephemeral state (and refuses persistent)
rm -rf "$WORK/state"/*
# shellcheck disable=SC2016  # inner bash -c expands $REPO_ROOT
env -i HOME="$WORK/home" PATH="$STUBS" REPO_ROOT="$REPO_ROOT" CALLS="$CALLS" HOMEFIELD_STATE_DIR="$WORK/state" /bin/bash -c '
  HOMEFIELD_SOURCE_ONLY=1
  . "$REPO_ROOT/bin/homefield"
  check_host() { :; }
  verify_isolation() { :; }
  ensure_vm() { :; }
  cmd_preflight() { return 0; }
  is_registered() { return 0; }
  guest_has_file() { return 0; }
  upgrade_registered() { :; }
  runner_setting() {
    for k in "$@"; do
      case "$k" in
        gitHubUrl) echo "https://github.com/acme" ;;
        agentName) echo "test-mac-homefield" ;;
      esac
    done
  }
  cmd_install --url https://github.com/other-org --org --ephemeral
' >/dev/null 2>&1; ephem_retry_rc=$?
st_body="$(cat "$WORK/state/homefield.state")"
record "retry install --ephemeral when already registered (ephemeral): reconciles actual guest settings" "0/yes/yes" "$ephem_retry_rc/$(has "$st_body" "ephemeral=1")/$(has "$st_body" "ephemeral_url=https://github.com/acme")"

# shellcheck disable=SC2016  # inner bash -c expands $REPO_ROOT
env -i HOME="$WORK/home" PATH="$STUBS" REPO_ROOT="$REPO_ROOT" CALLS="$CALLS" HOMEFIELD_STATE_DIR="$WORK/state" /bin/bash -c '
  HOMEFIELD_SOURCE_ONLY=1
  . "$REPO_ROOT/bin/homefield"
  check_host() { :; }
  verify_isolation() { :; }
  ensure_vm() { :; }
  cmd_preflight() { return 0; }
  is_registered() { return 0; }
  guest_has_file() { return 0; }
  upgrade_registered() { :; }
  runner_setting() {
    for k in "$@"; do
      case "$k" in
        gitHubUrl) echo "https://github.com/acme" ;;
        agentName) echo "test-mac-homefield" ;;
      esac
    done
  }
  cmd_install --url https://github.com/acme --org --ephemeral --group unapplied-grp --label unapplied-lbl
' >/dev/null 2>&1
st_body="$(cat "$WORK/state/homefield.state")"
record "upgrade existing ephemeral with empty defaults: does not overwrite with unapplied flags" "no/no" "$(has "$st_body" "unapplied-grp")/$(has "$st_body" "unapplied-lbl")"

# shellcheck disable=SC2016  # inner bash -c expands $REPO_ROOT
pers_out="$(env -i HOME="$WORK/home" PATH="$STUBS" REPO_ROOT="$REPO_ROOT" CALLS="$CALLS" HOMEFIELD_STATE_DIR="$WORK/state" /bin/bash -c '
  HOMEFIELD_SOURCE_ONLY=1
  . "$REPO_ROOT/bin/homefield"
  check_host() { :; }
  verify_isolation() { :; }
  ensure_vm() { :; }
  cmd_preflight() { return 0; }
  is_registered() { return 0; }
  guest_has_file() { return 1; }
  cmd_install --url https://github.com/acme --org --ephemeral
' 2>&1)"; pers_rc=$?
record "install --ephemeral on already-registered persistent runner: refused" "nonzero/yes" "$(nonzero "$pers_rc")/$(has "$pers_out" "already registered as a persistent runner")"

# 16. re-register --watch discovers non-default ephemeral instance via vm_instances
rm -rf "$WORK/state"/*
mkdir -p "$WORK/home/.lima/custom-eph"
printf '# Lima VM for the local GitHub Actions runner.\n' >"$WORK/home/.lima/custom-eph/lima.yaml"
printf 'ephemeral=1\nephemeral_url=https://github.com/acme\n' >"$WORK/state/custom-eph.state"
: >"$CALLS"
# shellcheck disable=SC2016  # inner bash -c expands $REPO_ROOT/$INSTANCE/$CALLS
env -i HOME="$WORK/home" PATH="$STUBS" REPO_ROOT="$REPO_ROOT" CALLS="$CALLS" HOMEFIELD_STATE_DIR="$WORK/state" /bin/bash -c '
  HOMEFIELD_SOURCE_ONLY=1
  . "$REPO_ROOT/bin/homefield"
  vm_instances() { printf "custom-eph\n"; }
  is_job_running() { return 1; }
  runner_service_state() { return 1; }
  re_register_single() { echo "rereg:$INSTANCE" >>"$CALLS"; }
  cmd_re_register --watch --interval 0 --max-cycles 1
' >/dev/null 2>&1; watch_rc=$?
watch_calls="$(cat "$CALLS")"
record "re-register --watch discovers non-default ephemeral instance" "0/yes" "$watch_rc/$(has "$watch_calls" "rereg:custom-eph")"

# 17. provision.sh re_register accepts clean ephemeral exit (Result=success) after Listening for Jobs
DONE_WORK="$TMP/rereg-done"
mkdir -p "$DONE_WORK/runner"
# shellcheck disable=SC2016  # inner bash -c expands its own vars
done_rc=0
env -i \
  PATH="$STUBS" \
  RUNNER_HOME="$DONE_WORK/runner" \
  RUNNER_URL="https://github.com/acme" \
  RUNNER_TOKEN="tok-done" \
  RUNNER_NAME="test-runner" \
  RUNNER_LABELS="self-hosted,linux,arm64,homefield-ci" \
  RUNNER_GROUP="" \
  RUNNER_USER="runner" \
  /bin/bash -c '
    set -euo pipefail
    pgrep() { return 1; }
    systemctl() {
      case "${1:-}" in
        is-active) return 1 ;;
        show) echo "success"; return 0 ;;
        *) return 0 ;;
      esac
    }
    journalctl() { echo "Listening for Jobs"; }
    install() { :; }
    runner_config() { : >"$RUNNER_HOME/.runner"; return 0; }
    ensure_service() { printf "actions.runner.test.service\n" >"$RUNNER_HOME/.service"; return 0; }
    . "$1"
    re_register
  ' _ "$REREG_FN" >/dev/null 2>&1 || done_rc=$?
record "provision.sh re_register: accepts clean ephemeral job completion after Listening for Jobs" "0" "$done_rc"

summary
