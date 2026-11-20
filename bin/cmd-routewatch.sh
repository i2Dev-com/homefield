#!/usr/bin/env bash
# The route watcher: the automatic hosted fallback's sleep/wake half (#290).
#
# Part 1 (#286, PR #292) makes plain `stop` route the adopted repositories to
# hosted and plain `start` route them back — but both need someone to run
# them. Two cases have no such caller: the Mac sleeping (the Lima VMs do not
# survive sleep cleanly, so the runner goes offline with the Mac and queued
# jobs wait for it), and a reboot or login (launchd autostart boots the VMs,
# but nothing restores the repositories a stop flipped). A LaunchAgent
# (`com.homefield.route-watcher`, installed by install/upgrade --auto-route)
# runs this command's two modes at those moments:
#
#   route-watch sleep  the Mac is about to sleep: every Running VM with
#                      auto_route on has its routed repositories flipped to
#                      hosted (the Part 1 flip, without stopping the VM), so
#                      jobs queued while the Mac is away run on GitHub's
#                      runners. A VM with a job running — or one that cannot
#                      be asked whether it has — is skipped, its records left
#                      alone.
#   route-watch wake   the Mac woke up or logged in: every VM with auto_route
#                      on is started if it is not running, waited for until
#                      its runner is listed online, and the repositories a
#                      flip sent to hosted come back to local.
#
# Both sides only touch VMs whose own auto_route is on: the watcher covers
# every HomeField VM on the Mac, but a VM whose automatic fallback is off
# keeps its explicit control (its pending autoflip entries keep waiting for
# the explicit `start --route-local`).
#
# Each run is recorded in route-watcher.state (read by status and diagnose);
# the agent's stdout and stderr land in route-watcher.log. The agent itself
# is a thin Python helper (bin/route-watcher.py) that translates IOKit's
# power events into these two commands — everything else is shell, so the
# tests can drive both modes with stubs.

# The watcher's own records, next to the per-Mac routing records (the same
# directory: per-Mac, not per-VM). route-watcher.state holds the last run
# (status and diagnose surface it); route-watcher.log is the agent's stdout
# and stderr, where every flip, skip and failure is told in full.
route_watcher_state_file() { printf '%s/route-watcher.state' "${HOMEFIELD_STATE_DIR:-$HOME/.local/state/homefield}"; }
route_watcher_log_file() { printf '%s/route-watcher.log' "${HOMEFIELD_STATE_DIR:-$HOME/.local/state/homefield}"; }
route_watcher_plist_path() { printf '%s/com.homefield.route-watcher.plist' "${HOMEFIELD_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"; }

# route_watcher_record <mode> <rc>: the run's summary, written whole (a temp
# file moved over the target, the way state_set and the record readers do).
# The formatted time is written here, not rendered later: `date -r` differs
# between macOS and Linux, and status must not need date at all.
route_watcher_record() {
  local mode="$1" rc="$2" f dir tmp
  f="$(route_watcher_state_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.route-watcher.XXXXXX")" || return 1
  {
    printf 'last_run=%s\n' "$(date +%s)"
    printf 'last_run_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'last_mode=%s\n' "$mode"
    printf 'last_result=%s\n' "$([ "$rc" = 0 ] && echo ok || echo failed)"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# The last run's summary, for status and diagnose. Empty values mean no run
# has been recorded yet.
RW_LAST_RUN="" RW_LAST_RUN_AT="" RW_LAST_MODE="" RW_LAST_RESULT=""
route_watcher_last_run() {
  RW_LAST_RUN=""; RW_LAST_RUN_AT=""; RW_LAST_MODE=""; RW_LAST_RESULT=""
  local f key value
  f="$(route_watcher_state_file)"
  [ -f "$f" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      last_run) RW_LAST_RUN="$value" ;;
      last_run_at) RW_LAST_RUN_AT="$value" ;;
      last_mode) RW_LAST_MODE="$value" ;;
      last_result) RW_LAST_RESULT="$value" ;;
    esac
  done <"$f"
  return 0
}

# route_watcher_needed [exclude]: whether any HomeField VM on this Mac still
# has the automatic fallback on. The agent is per-Mac and the state is per-VM,
# so removing it (upgrade --no-auto-route, uninstall, reset) is right only
# when the last VM that wanted it has stopped wanting it. <exclude> names one
# instance whose state does not count: uninstall passes the VM it just
# deleted, whose state file outlives the VM (reset, not uninstall, removes
# it) and must not keep the agent for a VM that is gone.
route_watcher_needed() {
  local dir f exclude="${1:-}"
  dir="$(dirname "$(route_watcher_state_file)")"
  [ -d "$dir" ] || return 1
  for f in "$dir"/*.state; do
    [ -f "$f" ] || continue
    if [ -n "$exclude" ] && [ "${f##*/}" = "${exclude}.state" ]; then
      continue
    fi
    grep -qx 'auto_route=1' "$f" && return 0
  done
  return 1
}

route_watcher_xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# route_watcher_install: write the LaunchAgent and load it. Idempotent: an
# existing agent is unloaded and rewritten (an upgrade may have moved the
# tool or changed the environment it needs). The agent runs the Python helper
# through /bin/sh so it survives python3 moving (a brew upgrade), with the
# PATH it needs for gh and limactl — launchd's own PATH has neither.
route_watcher_install() {
  local plist dir state_dir log py
  command -v python3 >/dev/null 2>&1 || {
    echo "homefield: the route watcher needs python3 (its power-event helper); install it (xcode-select --install, or brew install python3) and run bin/homefield upgrade --auto-route" >&2
    return 1
  }
  command -v launchctl >/dev/null 2>&1 || {
    echo "homefield: launchctl is required to install the route watcher" >&2
    return 1
  }
  py="$(command -v python3)"
  plist="$(route_watcher_plist_path)"
  dir="$(dirname "$plist")"
  state_dir="$(dirname "$(route_watcher_state_file)")"
  log="$(route_watcher_log_file)"
  mkdir -p "$dir" "$state_dir" || {
    echo "homefield: could not create ${dir} or ${state_dir}; the route watcher was not installed" >&2
    return 1
  }
  local env_xml=""
  if [ -n "${HOMEFIELD_STATE_DIR:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_STATE_DIR</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_STATE_DIR")</string>"$'\n'
  fi
  if [ -n "${LIMA_HOME:-}" ]; then
    env_xml="${env_xml}    <key>LIMA_HOME</key>"$'\n'"    <string>$(route_watcher_xml_escape "$LIMA_HOME")</string>"$'\n'
  fi
  if [ -n "${HOMEFIELD_WATCH_SLEEP_BUDGET:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_WATCH_SLEEP_BUDGET</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_WATCH_SLEEP_BUDGET")</string>"$'\n'
  fi
  if [ -n "${HOMEFIELD_WATCH_WAKE_WAIT:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_WATCH_WAKE_WAIT</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_WATCH_WAKE_WAIT")</string>"$'\n'
  fi
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.homefield.route-watcher</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>exec "$(route_watcher_xml_escape "$py")" "$(route_watcher_xml_escape "$ROOT/bin/route-watcher.py")"</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(route_watcher_xml_escape "$PATH")</string>
${env_xml}  </dict>
  <key>StandardOutPath</key>
  <string>$(route_watcher_xml_escape "$log")</string>
  <key>StandardErrorPath</key>
  <string>$(route_watcher_xml_escape "$log")</string>
</dict>
</plist>
EOF
  launchctl unload -w "$plist" 2>/dev/null || true
  launchctl load -w "$plist" || {
    echo "homefield: could not load the route watcher LaunchAgent ${plist}" >&2
    return 1
  }
  log "installed the route watcher (${plist})"
}

route_watcher_remove() {
  local plist
  plist="$(route_watcher_plist_path)"
  [ -f "$plist" ] || return 0
  if command -v launchctl >/dev/null 2>&1; then
    launchctl unload -w "$plist" 2>/dev/null || true
  fi
  rm -f "$plist" || { echo "homefield: could not remove ${plist}" >&2; return 1; }
  log "removed the route watcher (${plist})"
  return 0
}

# route_watcher_remove_if_unneeded [exclude]: take the agent down when the
# last VM that wanted it has stopped wanting it. A removal failure is the
# caller's to surface; the callers that must not fail the command run it with
# || true.
route_watcher_remove_if_unneeded() {
  if route_watcher_needed "${1:-}"; then
    return 0
  fi
  route_watcher_remove
}

# route_watch_collect_runners: every Running HomeField VM's runner name, one
# per line, into ROUTE_EXCLUDE_RUNNERS — the pre-pass of the sleep side.
# The flip's "another online runner serves the label" check excludes the
# runner being stopped by name, but at sleep time every runner on this Mac
# goes away together, so all of their names must be excluded: without that,
# two VMs sharing a label would each leave the repositories to the other and
# nothing would be flipped. A Stopped VM's runner is not heartbeating and is
# no threat, so only Running VMs are asked (a `limactl shell` on a stopped
# VM starts it). A VM that cannot be asked poisons the whole flip — its
# runner may still be listed online and serving the label — so a failure
# here flips nothing (fail safe, the same direction as Part 1's).
route_watch_collect_runners() {
  local list name saved status
  saved="$INSTANCE"
  if ! list="$(vm_instances)"; then
    echo "homefield: could not list the VMs; the routed repositories stay as they are" >&2
    return 1
  fi
  ROUTE_EXCLUDE_RUNNERS=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    INSTANCE="$name"
    status=""
    status="$(vm_status_of "$name")" || status=""
    if [ -z "$status" ]; then
      echo "homefield: could not ask Lima about VM ${name}; the routed repositories stay as they are (fail safe)" >&2
      INSTANCE="$saved"
      return 1
    fi
    [ "$status" = "Running" ] || continue
    load_runner_settings
    if [ -z "$RS_NAME" ]; then
      echo "homefield: could not read VM ${name}'s runner name; the routed repositories stay as they are (fail safe: a runner that may still be online must not lose its jobs)" >&2
      INSTANCE="$saved"
      return 1
    fi
    ROUTE_EXCLUDE_RUNNERS="${ROUTE_EXCLUDE_RUNNERS}${RS_NAME}"$'\n'
  done <<<"$list"
  INSTANCE="$saved"
  return 0
}

# route_watch_sleep_single: one VM's sleep side. The Part 1 flip, without
# stopping the VM: repositories routed to this runner go to hosted while the
# Mac is away, and wait in autoflip for the wake side (or the next start) to
# bring them back. A busy VM is skipped — a job is running, and Part 1's
# stop refuses it for the same reason — and so is a VM that cannot be asked
# whether one is: neither may be flipped, and neither's records are touched.
route_watch_sleep_single() {
  vm_lookup
  [ -n "$VM_STATUS" ] || { log "VM ${INSTANCE}: does not exist; nothing to watch"; return 0; }
  [ "$VM_STATUS" = "Running" ] || { log "VM ${INSTANCE}: ${VM_STATUS}; its runner is not taking jobs, so there is nothing to flip"; return 0; }
  if [ "$(state_get auto_route)" != "1" ]; then
    log "VM ${INSTANCE}: the automatic fallback is off; leaving its routing alone"
    return 0
  fi
  local jrc=0
  job_running || jrc=$?
  case "$jrc" in
    0)
      log "VM ${INSTANCE}: a job is running; not switching its repositories to hosted, and leaving its records alone"
      return 0
      ;;
    2)
      echo "homefield: VM ${INSTANCE}: could not ask whether a job is running; not switching its repositories to hosted (fail safe)" >&2
      return 1
      ;;
  esac
  load_runner_settings
  if [ -z "$RS_NAME" ] || [ -z "$RS_URL" ]; then
    echo "homefield: could not read VM ${INSTANCE}'s runner identity; its routed repositories stay as they are" >&2
    return 1
  fi
  log "VM ${INSTANCE}: the Mac is going to sleep; switching its routed repositories to hosted"
  route_stop_fallback "$RS_URL" "$RS_NAME" "${ROUTE_EXCLUDE_RUNNERS:-}"
}

# route_watch_wake_single: one VM's wake side. Start it if it is not running
# (the Lima VMs do not survive sleep cleanly), wait for its runner to be
# listed online — the restore needs GitHub's row for the runner, and
# restoring while it is still offline would point the repositories at a
# runner that is not taking jobs — then bring the flipped repositories back
# to local. The waits are bounded (HOMEFIELD_WATCH_WAKE_WAIT, default 120 s):
# a VM that does not come back keeps its entries for the next start or the
# next wake, and the run says so loudly.
route_watch_wake_single() {
  vm_lookup
  [ -n "$VM_STATUS" ] || { log "VM ${INSTANCE}: does not exist; nothing to watch"; return 0; }
  if [ "$(state_get auto_route)" != "1" ]; then
    log "VM ${INSTANCE}: the automatic fallback is off; leaving its routing alone"
    return 0
  fi
  if [ "$VM_STATUS" != "Running" ]; then
    log "VM ${INSTANCE}: starting it (the Mac woke up or logged in)"
    limactl start --tty=false "$INSTANCE" </dev/null ||
      { echo "homefield: could not start VM ${INSTANCE}; its flipped repositories stay hosted until the next start" >&2; return 1; }
  fi
  # The guest answers only once it is up; a boot that is still settling
  # reads as "could not ask", so the identity read retries before it gives
  # up (30 s in total, on top of the limactl start that already waited).
  local identity_ok=0 tries=0
  while [ "$tries" -lt 6 ]; do
    load_runner_settings
    if [ -n "$RS_NAME" ] && [ -n "$RS_URL" ] && [ -n "$RS_ID" ]; then
      identity_ok=1
      break
    fi
    adopt_nap 5
    tries=$((tries + 1))
  done
  if [ "$identity_ok" != 1 ]; then
    echo "homefield: could not read VM ${INSTANCE}'s runner identity; its flipped repositories stay hosted until the next start" >&2
    return 1
  fi
  local online=0 waited=0 total="${HOMEFIELD_WATCH_WAKE_WAIT:-120}"
  case "$total" in '' | *[!0-9]*) total=120 ;; esac
  while [ "$waited" -lt "$total" ]; do
    if runner_on_github "$RS_URL" "$RS_ID" && [ "$RUNNER_GH_STATUS" = online ]; then
      online=1
      break
    fi
    adopt_nap 5
    waited=$((waited + 5))
  done
  if [ "$online" != 1 ]; then
    echo "homefield: VM ${INSTANCE}'s runner is not online after ${total}s; its flipped repositories stay hosted until the next start (log: $(route_watcher_log_file))" >&2
    return 1
  fi
  log "VM ${INSTANCE}: the Mac is awake; routing its flipped repositories back to local"
  route_start_restore "$RS_URL" "$RS_NAME"
}

# cmd_route_watch <sleep|wake>: one watcher run. The per-VM work goes through
# vm_dispatch, so every VM is its own process (one VM's failure cannot stop
# the next) and the summary records the run as a whole. The sleep side's
# pre-pass runs once, here, in the parent; the per-VM children inherit
# ROUTE_EXCLUDE_RUNNERS and do not collect again (an explicit --instance run
# collects nothing: it flips one VM, excluding only that VM's own runner).
cmd_route_watch() {
  local mode="${1:-}"
  case "$mode" in
    sleep | wake) ;;
    *) die "route-watch: say what happened: bin/homefield route-watch <sleep|wake> (sleep: the Mac is about to sleep; wake: it woke up or logged in)" ;;
  esac
  if [ $# -gt 1 ]; then
    die "route-watch: unknown option $2 (see bin/homefield help)"
  fi
  check_host
  if [ "$mode" = sleep ] && [ "$EXPLICIT_INSTANCE" = 0 ]; then
    if ! route_watch_collect_runners; then
      route_watcher_record sleep 1 || true
      return 1
    fi
    export ROUTE_EXCLUDE_RUNNERS
  fi
  local rc=0
  # The mode goes with the dispatch: a multi-VM run's per-VM children re-run
  # the command with --instance, and the mode must survive that.
  vm_dispatch "route-watch" "route_watch_${mode}_single" "$mode" || rc=1
  route_watcher_record "$mode" "$rc" || rc=1
  return "$rc"
}

# route_watcher_status_line: the one-line answer status prints for a VM with
# the automatic fallback on — whether the agent is there, and what the last
# run did. The log carries the detail.
route_watcher_status_line() {
  local installed="no"
  if [ -f "$(route_watcher_plist_path)" ]; then
    installed="yes"
  fi
  route_watcher_last_run
  if [ "$installed" != "yes" ]; then
    echo "route watcher: NOT installed; the automatic fallback covers stop and start but not sleep and wake (bin/homefield upgrade --auto-route)"
    return 0
  fi
  if [ -z "$RW_LAST_RUN" ]; then
    echo "route watcher: installed, no run recorded yet (log: $(route_watcher_log_file))"
    return 0
  fi
  echo "route watcher: last ran ${RW_LAST_MODE} at ${RW_LAST_RUN_AT}: ${RW_LAST_RESULT} (log: $(route_watcher_log_file))"
  return 0
}

# route_watcher_json: the same facts for status --json (an object; the caller
# decides whether the VM's automatic fallback makes it relevant).
route_watcher_json() {
  local installed=false
  if [ -f "$(route_watcher_plist_path)" ]; then
    installed=true
  fi
  route_watcher_last_run
  printf '{"installed": %s, "last_run": %s, "last_mode": %s, "last_result": %s}' \
    "$installed" "$(json_nstr "$RW_LAST_RUN_AT")" "$(json_nstr "$RW_LAST_MODE")" "$(json_nstr "$RW_LAST_RESULT")"
}