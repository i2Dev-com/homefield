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
  list)
    # STUB_VM_GONE=1: the working VM is not listed (it is gone). STUB_BASE_PRESENT=1:
    # the reset base VM (homefield-base) is listed, stopped. STUB_EXTRA_ROWS:
    # extra Lima rows (other HomeField VMs on this Mac).
    [ "${STUB_VM_GONE:-0}" = "1" ] || echo "homefield Running"
    [ "${STUB_BASE_PRESENT:-0}" = "1" ] && echo "homefield-base Stopped"
    [ -n "${STUB_EXTRA_ROWS:-}" ] && printf '%b\n' "$STUB_EXTRA_ROWS"
    exit 0
    ;;
  stop|delete|clone|start)
    echo "limactl:$*" >>"$CALLS"
    case "${1:-}" in
      stop) [ "${STUB_STOP_FAIL:-0}" = "0" ] || exit 1 ;;
      delete) [ "${STUB_DELETE_FAIL:-0}" = "0" ] || exit 1 ;;
      clone)
        [ "${STUB_CLONE_FAIL:-0}" = "0" ] || exit 1
        # clone --start=false SRC DST: the clone's stored config is the
        # source's, as limactl copies it, so the reset-base marking and
        # is_reset_base have a file to work on.
        cp "$HOME/.lima/${3}/lima.yaml" "$HOME/.lima/${4}/lima.yaml" 2>/dev/null ||
          { mkdir -p "$HOME/.lima/${4}" && cp "$HOME/.lima/${3}/lima.yaml" "$HOME/.lima/${4}/lima.yaml"; } ||
          exit 1
        ;;
    esac
    exit 0
    ;;
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
# ran_jobs: whether the VM's runner has a _work directory (it has run jobs).
# 1 = fresh, the default: a VM the registration token may go into. 0 = it has
# run jobs, 2 = the guest could not be asked (cases below).
ran_jobs() { return "${STUB_RAN_JOBS:-1}"; }
runner_service_state() { return "${STUB_SVC_RC:-0}"; }
"$@"
EOF

hrun() {
  : >"$CALLS"
  rm -f "$CALLS.clonecount"
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
    STUB_RAN_JOBS="${STUB_RAN_JOBS:-1}" \
    STUB_VM_GONE="${STUB_VM_GONE:-0}" \
    STUB_BASE_PRESENT="${STUB_BASE_PRESENT:-0}" \
    STUB_STOP_FAIL="${STUB_STOP_FAIL:-0}" \
    STUB_DELETE_FAIL="${STUB_DELETE_FAIL:-0}" \
    STUB_CLONE_FAIL="${STUB_CLONE_FAIL:-0}" \
    bash "$HARNESS" "$@" 2>&1 </dev/null)"
  rc=$?
}

# mkbase: the reset base VM on disk, the way install --reset-vm leaves it:
# a HomeField config carrying the reset-base marker (is_reset_base).
mkbase() {
  mkdir -p "$WORK/home/.lima/homefield-base"
  {
    printf '# Lima VM for the local GitHub Actions runner.\n'
    printf '%s\n' '# HomeField reset base VM (created by install --reset-vm)'
  } >"$WORK/home/.lima/homefield-base/lima.yaml"
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

# 2b. the per-job cleanup switch: install passes it, state remembers it, and
# re-register passes it back to the guest
hrun cmd_install --url https://github.com/acme --org --ephemeral --job-cleanup
calls="$(cat "$CALLS")"
st_body="$(cat "$WORK/state/homefield.state")"
record "install --job-cleanup: passes RUNNER_JOB_CLEANUP=1 and sets state" "0/yes/yes" "$rc/$(has "$calls" "RUNNER_JOB_CLEANUP=1")/$(has "$st_body" "job_cleanup=1")"
hrun cmd_install --url https://github.com/acme --org --ephemeral --no-job-cleanup
calls="$(cat "$CALLS")"
st_body="$(cat "$WORK/state/homefield.state")"
record "install --no-job-cleanup: passes RUNNER_JOB_CLEANUP=0 and clears state" "0/yes/yes" "$rc/$(has "$calls" "RUNNER_JOB_CLEANUP=0")/$(has "$st_body" "job_cleanup=0")"
hrun cmd_install --url https://github.com/acme --org --ephemeral --job-cleanup
STUB_JOB_RC=1 hrun cmd_re_register
calls="$(cat "$CALLS")"
record "re-register passes the saved switch to the guest" "0/yes" "$rc/$(has "$calls" "RUNNER_JOB_CLEANUP=1")"

# 2c. a registration token must not go into a VM that has run jobs (a job's
# leftover root process could read it from the provisioning process): the
# fresh-registration path refuses before the token is fetched
STUB_RAN_JOBS=0 hrun cmd_install --url https://github.com/acme --org --ephemeral
calls="$(cat "$CALLS")"
record "install on a VM that has run jobs: refused before the token" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(has "$out" "has run jobs")/$(has "$calls" "get_token:")"
record "...saying how to get a fresh VM" "yes" "$(has "$out" "bin/homefield reset --instance homefield")"
# ...and a guest that cannot be asked is refused the same way: read as fresh,
# the token would go into a VM that may have run jobs
STUB_RAN_JOBS=2 hrun cmd_install --url https://github.com/acme --org --ephemeral
record "install when the guest cannot be asked: refused" "nonzero/yes" \
  "$(nonzero "$rc")/$(has "$out" "could not ask whether homefield has run jobs")"

# 3. re-register refuses when job is running
STUB_JOB_RC=0 hrun cmd_re_register
record "busy VM: re-register refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" "a job is running")"

# 4. re-register happy path: pipes token on stdin, runs PROVISION_CMD=re-register, waits online
STUB_JOB_RC=1 hrun cmd_re_register
calls="$(cat "$CALLS")"
record "re-register happy path: stdin token + PROVISION_CMD=re-register + wait_online" "0/yes/yes/yes" "$rc/$(has "$calls" "cmd=re-register")/$(has "$calls" "input=RUNNER_TOKEN=stub-tok-123")/$(has "$calls" "wait_online:https://github.com/acme")"

# 4b. the VM has run jobs and the reset is off: the re-register refuses
# rather than put a registration token into a VM a job's leftover root
# process could read
printf 'ephemeral=1\nephemeral_url=https://github.com/acme\nephemeral_name=test-mac-homefield\n' >"$WORK/state/homefield.state"
STUB_JOB_RC=1 STUB_RAN_JOBS=0 hrun cmd_re_register
calls="$(cat "$CALLS")"
record "re-register on a VM that has run jobs, reset off: refused" "nonzero/yes/no/no" \
  "$(nonzero "$rc")/$(has "$out" "has run jobs")/$(has "$calls" "get_token:")/$(has "$calls" "cmd=re-register")"
record "...naming the fresh-VM path" "yes" "$(has "$out" "bin/homefield reset --instance homefield")"

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
ran_jobs() { return 1; }
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
  job_cleanup="0" \
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
  job_cleanup="0" \
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
  job_cleanup="0" \
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
  job_cleanup="0" \
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
  vm_status() { echo Running; }
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
  job_cleanup="0" \
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

# ── 18. --reset-vm: install prepares the VM unregistered, clones the base,
# then registers (the base must be unregistered: a clone of a registered VM
# inherits its registration and its listener never reaches "Listening for
# Jobs"). The trial of the real clone step ran on throwaway VMs (issue #289).
rm -rf "$WORK/state"/*
hrun cmd_install --url https://github.com/acme --org --ephemeral --reset-vm
calls="$(cat "$CALLS")"
st_body="$(cat "$WORK/state/homefield.state")"
record "install --ephemeral --reset-vm: prepare-only provision, clone, then the registration" "0/yes/yes/yes/yes" \
  "$rc/$(has "$calls" "RUNNER_PREPARE_ONLY=1")/$(has "$calls" "limactl:stop homefield")/$(has "$calls" "limactl:clone --start=false homefield homefield-base")/$(has "$calls" "input=RUNNER_TOKEN=stub-tok-123")"
clone_line="$(grep -n 'limactl:clone' "$CALLS" | cut -d: -f1 | head -1)"
reg_line="$(grep -n 'input=RUNNER_TOKEN=stub-tok-123' "$CALLS" | cut -d: -f1 | head -1)"
record "...the clone comes before the registration" "yes" \
  "$([ -n "$clone_line" ] && [ -n "$reg_line" ] && [ "$clone_line" -lt "$reg_line" ] && echo yes || echo no)"
record "...the state remembers reset_vm=1" "yes" "$(has "$st_body" "reset_vm=1")"

# 19. --reset-vm without --ephemeral: refused before anything is created
hrun cmd_install --url https://github.com/acme --org --reset-vm
record "install --reset-vm without --ephemeral: refused" "nonzero/yes" \
  "$(nonzero "$rc")/$(has "$out" "--reset-vm needs --ephemeral")"

# 19b. a 76-character instance: <instance>-base is not a Lima name, refused
long_name="$(printf 'a%.0s' $(seq 76))"
# shellcheck disable=SC2016  # inner bash -c expands its own vars
out="$(env -i HOME="$WORK/home" PATH="$STUBS" REPO_ROOT="$REPO_ROOT" CALLS="$CALLS" \
  HOMEFIELD_STATE_DIR="$WORK/state" HOMEFIELD_INSTANCE="$long_name" /bin/bash -c '
  HOMEFIELD_SOURCE_ONLY=1
  . "$REPO_ROOT/bin/homefield"
  check_host() { :; }
  verify_isolation() { :; }
  ensure_vm() { :; }
  cmd_preflight() { return 0; }
  ensure_group() { GROUP_STATE=narrow; GROUP_ID=7; }
  check_name_free() { :; }
  remove_taken_name() { :; }
  get_token() { printf "stub-tok-123\n"; }
  run_provision() { :; }
  runner_setting() { echo x; }
  wait_online() { :; }
  warm_vm() { :; }
  is_job_running() { return 1; }
  is_registered() { return 1; }
  runner_service_state() { return 0; }
  cmd_install --url https://github.com/acme --org --ephemeral --reset-vm
' 2>&1)"; rc=$?
record "an instance whose base name would be too long: refused" "nonzero/yes" \
  "$(nonzero "$rc")/$(has "$out" "not a valid Lima instance name")"

# 20. a VM named homefield-base that is not a reset base (an ordinary runner
# may be named that): refused, not deleted
mkdir -p "$WORK/home/.lima/homefield-base"
printf '# Lima VM for the local GitHub Actions runner.\n' >"$WORK/home/.lima/homefield-base/lima.yaml"
STUB_BASE_PRESENT=1 hrun cmd_install --url https://github.com/acme --org --ephemeral --reset-vm
calls="$(cat "$CALLS")"
record "a foreign VM named homefield-base: refused, not deleted" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(has "$out" "not a HomeField reset base VM")/$(has "$calls" "limactl:delete")"

# 21. a stale HomeField base from an earlier install: deleted, then re-cloned
mkbase
STUB_BASE_PRESENT=1 hrun cmd_install --url https://github.com/acme --org --ephemeral --reset-vm
calls="$(cat "$CALLS")"
record "a stale HomeField base VM: deleted, then a fresh one cloned" "0/yes/yes" \
  "$rc/$(has "$calls" "limactl:delete -f homefield-base")/$(has "$calls" "limactl:clone --start=false homefield homefield-base")"

# 22. one-shot re-register with reset_vm=1: stop, delete, clone, re-register
rm -rf "$WORK/state"/*
printf 'ephemeral=1\nephemeral_url=https://github.com/acme\nephemeral_name=test-mac-homefield\nreset_vm=1\n' >"$WORK/state/homefield.state"
mkbase
STUB_BASE_PRESENT=1 STUB_JOB_RC=1 hrun cmd_re_register
calls="$(cat "$CALLS")"
record "re-register with reset_vm=1: stop, delete, clone, then the re-register" "0/yes/yes/yes/yes" \
  "$rc/$(has "$calls" "limactl:stop homefield")/$(has "$calls" "limactl:delete -f homefield")/$(has "$calls" "limactl:clone --start=false homefield-base homefield")/$(has "$calls" "cmd=re-register")"
clone_line="$(grep -n 'limactl:clone' "$CALLS" | cut -d: -f1 | head -1)"
rereg_line="$(grep -n 'cmd=re-register' "$CALLS" | cut -d: -f1 | head -1)"
record "...the clone comes before the re-register" "yes" \
  "$([ -n "$clone_line" ] && [ -n "$rereg_line" ] && [ "$clone_line" -lt "$rereg_line" ] && echo yes || echo no)"
record "...a successful cycle clears reset_error" "yes" \
  "$(grep -qx 'reset_error=' "$WORK/state/homefield.state" && echo yes || echo no)"
record "...the fresh working VM does not look like a base (the inherited marker is stripped)" "no" \
  "$(grep -qF '# HomeField reset base VM' "$WORK/home/.lima/homefield/lima.yaml" && echo yes || echo no)"

# 23. the stop fails: the reset is skipped, the old VM stays — and it has run
# jobs, so the re-register refuses instead of putting a token into it
mkbase
STUB_STOP_FAIL=1 STUB_BASE_PRESENT=1 STUB_JOB_RC=1 STUB_RAN_JOBS=0 hrun cmd_re_register
st_body="$(cat "$WORK/state/homefield.state")"; calls="$(cat "$CALLS")"
record "reset with a failing stop: skipped, the re-register refuses the dirty VM" "nonzero/yes/no/no/no/yes" \
  "$(nonzero "$rc")/$(has "$st_body" "reset_error=could not stop the VM to reset it")/$(has "$calls" "limactl:delete")/$(has "$calls" "limactl:clone")/$(has "$calls" "cmd=re-register")/$(has "$out" "has run jobs")"

# 24. the clone fails after the delete: the VM is gone, the error is recorded,
# the re-register does not run
mkbase
STUB_CLONE_FAIL=1 STUB_BASE_PRESENT=1 STUB_JOB_RC=1 hrun cmd_re_register
st_body="$(cat "$WORK/state/homefield.state")"; calls="$(cat "$CALLS")"
record "reset with a failing clone: exits nonzero, ephemeral_error recorded, no re-register" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(has "$st_body" "ephemeral_error=reset: clone from homefield-base failed")/$(has "$calls" "cmd=re-register")"

# 25. the VM is already gone (a failed reset): the base brings it back
mkbase
STUB_VM_GONE=1 STUB_BASE_PRESENT=1 STUB_JOB_RC=1 hrun cmd_re_register
calls="$(cat "$CALLS")"; st_body="$(cat "$WORK/state/homefield.state")"
record "VM gone with reset_vm=1: cloned from the base (no stop/delete), re-registered" "0/yes/no/no/yes/no" \
  "$rc/$(has "$calls" "limactl:clone --start=false homefield-base homefield")/$(has "$calls" "limactl:stop homefield")/$(has "$calls" "limactl:delete -f homefield")/$(has "$calls" "cmd=re-register")/$(has "$st_body" "ephemeral_error=reset")"

# 26. the VM is gone and there is no base: die naming the install
STUB_VM_GONE=1 STUB_JOB_RC=1 hrun cmd_re_register
record "VM gone with reset_vm=1 and no base: dies naming install" "nonzero/yes" \
  "$(nonzero "$rc")/$(has "$out" "no VM homefield; run bin/homefield install --ephemeral")"

# 27. the command's --reset-vm/--no-reset-vm override the saved switch
printf 'ephemeral=1\nephemeral_url=https://github.com/acme\nephemeral_name=test-mac-homefield\nreset_vm=1\n' >"$WORK/state/homefield.state"
STUB_BASE_PRESENT=1 STUB_JOB_RC=1 STUB_RAN_JOBS=0 hrun cmd_re_register --no-reset-vm
calls="$(cat "$CALLS")"; st_body="$(cat "$WORK/state/homefield.state")"
record "re-register --no-reset-vm on a VM that has run jobs: refused, no cycle" "nonzero/yes/no/no/yes" \
  "$(nonzero "$rc")/$(has "$out" "has run jobs")/$(has "$calls" "limactl:stop homefield")/$(has "$calls" "cmd=re-register")/$(grep -qx 'reset_error=' "$WORK/state/homefield.state" && echo yes || echo no)"
printf 'ephemeral=1\nephemeral_url=https://github.com/acme\nephemeral_name=test-mac-homefield\nreset_vm=0\n' >"$WORK/state/homefield.state"
mkbase
STUB_BASE_PRESENT=1 STUB_JOB_RC=1 hrun cmd_re_register --reset-vm
calls="$(cat "$CALLS")"
record "re-register --reset-vm: the cycle runs even with reset_vm=0" "0/yes/yes" \
  "$rc/$(has "$calls" "limactl:stop homefield")/$(has "$calls" "limactl:clone --start=false homefield-base homefield")"

# 28. the watch loop with the VM gone: recovery with the reset, a warning without
printf 'ephemeral=1\nephemeral_url=https://github.com/acme\nephemeral_name=test-mac-homefield\nreset_vm=1\n' >"$WORK/state/homefield.state"
mkbase
STUB_VM_GONE=1 STUB_BASE_PRESENT=1 STUB_JOB_RC=1 STUB_SVC_RC=1 hrun cmd_re_register --watch --interval 0 --max-cycles 1
calls="$(cat "$CALLS")"
record "--watch with the VM gone and reset on: clones from the base and re-registers" "0/yes/yes/yes" \
  "$rc/$(has "$out" "has no VM; cloning it from its base")/$(has "$calls" "limactl:clone --start=false homefield-base homefield")/$(has "$calls" "cmd=re-register")"
printf 'ephemeral=1\nephemeral_url=https://github.com/acme\nreset_vm=0\n' >"$WORK/state/homefield.state"
STUB_VM_GONE=1 STUB_JOB_RC=1 STUB_SVC_RC=1 hrun cmd_re_register --watch --interval 0 --max-cycles 1
calls="$(cat "$CALLS")"
record "--watch with the VM gone and reset off: warns, does not re-register, exits 0" "0/yes/no" \
  "$rc/$(has "$out" "has no VM; run bin/homefield install --ephemeral")/$(has "$calls" "cmd=re-register")"

# 28b. a clone that fails after the delete must not kill the watch loop: the
# next cycle retries the recovery (the old code died on the spot, so the
# promised next-cycle recovery never ran)
printf 'ephemeral=1\nephemeral_url=https://github.com/acme\nephemeral_name=test-mac-homefield\nreset_vm=1\n' >"$WORK/state/homefield.state"
mkbase
STUB_CLONE_FAIL=1 STUB_BASE_PRESENT=1 STUB_JOB_RC=1 STUB_SVC_RC=1 hrun cmd_re_register --watch --interval 0 --max-cycles 2
calls="$(cat "$CALLS")"; st_body="$(cat "$WORK/state/homefield.state")"
record "--watch survives a failing reset clone: loops on, retries the clone" "0/2/yes" \
  "$rc/$(grep -c 'limactl:clone' "$CALLS")/$(has "$st_body" "ephemeral_error=reset: clone from homefield-base failed")"

# 28c. the ephemeral VM is gone but a persistent HomeField VM exists: the
# watcher must recover the ephemeral instance its state describes, not watch
# the persistent one (whose service running would idle the loop forever)
mkdir -p "$WORK/home/.lima/other"
printf '# Lima VM for the local GitHub Actions runner.\n' >"$WORK/home/.lima/other/lima.yaml"
printf 'ephemeral=1\nephemeral_url=https://github.com/acme\nephemeral_name=test-mac-homefield\nreset_vm=1\n' >"$WORK/state/homefield.state"
mkbase
STUB_VM_GONE=1 STUB_BASE_PRESENT=1 STUB_EXTRA_ROWS='other Running' STUB_JOB_RC=1 STUB_SVC_RC=1 \
  hrun cmd_re_register --watch --interval 0 --max-cycles 1
calls="$(cat "$CALLS")"
record "--watch with the ephemeral VM gone beside a persistent VM: recovers the ephemeral one" "0/yes/yes/no" \
  "$rc/$(has "$calls" "limactl:clone --start=false homefield-base homefield")/$(has "$calls" "cmd=re-register")/$(has "$calls" "other")"

# 28d. the ephemeral VM is gone beside ANOTHER EPHEMERAL VM: the missing one
# is still watched and recovered (the old fallback only fired when no
# ephemeral VM was found at all)
mkdir -p "$WORK/home/.lima/second"
printf '# Lima VM for the local GitHub Actions runner.\n' >"$WORK/home/.lima/second/lima.yaml"
printf 'ephemeral=1\nephemeral_url=https://github.com/acme\n' >"$WORK/state/second.state"
printf 'ephemeral=1\nephemeral_url=https://github.com/acme\nephemeral_name=test-mac-homefield\nreset_vm=1\n' >"$WORK/state/homefield.state"
mkbase
STUB_VM_GONE=1 STUB_BASE_PRESENT=1 STUB_EXTRA_ROWS='second Running' STUB_JOB_RC=1 STUB_SVC_RC=1 \
  hrun cmd_re_register --watch --interval 0 --max-cycles 1
calls="$(cat "$CALLS")"
record "--watch with the ephemeral VM gone beside another ephemeral VM: both watched, the gone one recovered" "0/yes/yes" \
  "$rc/$(has "$calls" "limactl:clone --start=false homefield-base homefield")/$(has "$calls" "cmd=re-register")"

# 29. upgrade --reset-vm: the switch follows the base (which only install
# creates); --no-reset-vm always works
UP_HARNESS="$WORK/up_harness.sh"
cat >"$UP_HARNESS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HOMEFIELD_SOURCE_ONLY=1
. "$REPO_ROOT/bin/homefield"
check_host() { :; }
verify_isolation() { :; }
ensure_vm() { :; }
is_registered() { return 0; }
is_job_running() { return 1; }
stop_runner() { :; }
runner_back() { :; }
runner_on_github() { return 0; }
runner_setting() { echo "https://github.com/acme"; echo "41"; echo "test-mac-homefield"; }
run_provision() { shift; echo "run_provision:$*" >>"$CALLS"; }
"$@"
EOF
uprun() {
  : >"$CALLS"
  out="$(env -i \
    HOME="$WORK/home" \
    PATH="$STUBS" \
    REPO_ROOT="$REPO_ROOT" \
    CALLS="$CALLS" \
    HOMEFIELD_STATE_DIR="$WORK/state" \
    STUB_BASE_PRESENT="${STUB_BASE_PRESENT:-0}" \
    bash "$UP_HARNESS" "$@" 2>&1 </dev/null)"
  rc=$?
}
rm -rf "$WORK/state"/*
printf 'ephemeral=1\n' >"$WORK/state/homefield.state"
mkbase
STUB_BASE_PRESENT=1 uprun cmd_upgrade --reset-vm
st_body="$(cat "$WORK/state/homefield.state")"
record "upgrade --reset-vm with a base: reset_vm=1 saved" "0/yes" "$rc/$(has "$st_body" "reset_vm=1")"
rm -rf "$WORK/state"/*
printf 'ephemeral=1\n' >"$WORK/state/homefield.state"
uprun cmd_upgrade --reset-vm
calls="$(cat "$CALLS")"
record "upgrade --reset-vm without a base: refused before anything stops" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(has "$out" "no base VM homefield-base")/$(has "$calls" "run_provision")"
rm -rf "$WORK/state"/*
printf 'ephemeral=1\nreset_vm=1\nreset_error=could not stop the VM to reset it\n' >"$WORK/state/homefield.state"
uprun cmd_upgrade --no-reset-vm
st_body="$(cat "$WORK/state/homefield.state")"
record "upgrade --no-reset-vm: reset_vm=0 and the error cleared" "0/yes/yes" \
  "$rc/$(has "$st_body" "reset_vm=0")/$(grep -qx 'reset_error=' "$WORK/state/homefield.state" && echo yes || echo no)"

# 30. status renders the reset state and its error
rm -rf "$WORK/state"/*
printf 'ephemeral=1\nreset_vm=1\nreset_error=could not stop the VM to reset it\n' >"$WORK/state/homefield.state"
# shellcheck disable=SC2016  # inner bash -c expands $REPO_ROOT
st_out="$(env -i HOME="$WORK/home" PATH="$STUBS" REPO_ROOT="$REPO_ROOT" HOMEFIELD_STATE_DIR="$WORK/state" /bin/bash -c '
  HOMEFIELD_SOURCE_ONLY=1
  . "$REPO_ROOT/bin/homefield"
  INSTANCE=homefield
  st_render_ephemeral
' 2>&1)"
record "status renders the reset state and its error" "yes/yes/yes" \
  "$(has "$st_out" "vm reset: on (each re-register clones a fresh VM from homefield-base)")/$(has "$st_out" "vm reset: ERROR (could not stop the VM to reset it)")/$(has "$st_out" "mode: ephemeral")"

summary
