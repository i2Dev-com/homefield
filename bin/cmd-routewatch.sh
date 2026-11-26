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
#   route-watch wake   the Mac woke up or logged in: every VM the sleep side
#                      recorded as running (auto_route on) is started if it
#                      is not running, waited for until its runner is listed
#                      online, and the repositories a flip sent to hosted
#                      come back to local. A VM the user stopped by hand, or
#                      one the demand scaler put dark, was not running at
#                      sleep and stays down — a stop's own paths bring it
#                      back (the explicit start, or the tick's wake on
#                      demand), not the Mac's next wake.
#
# Both sides only touch VMs whose own auto_route is on: the watcher covers
# every HomeField VM on the Mac, but a VM whose automatic fallback is off
# keeps its explicit control (its pending autoflip entries keep waiting for
# the explicit `start --route-local`).
#
# Each run is recorded in the watcher's state file (read by status and
# diagnose); the agent's stdout and stderr land in the watcher's log. The
# agent itself is a thin Python helper (bin/route-watcher.py) that translates
# IOKit's power events into these two commands — everything else is shell, so
# the tests can drive both modes with stubs.

# The watcher's own records, in a subdirectory of the per-Mac state
# directory (the same directory the routing records live in: per-Mac, not
# per-VM). The subdirectory keeps the watcher's files out of the per-instance
# `<name>.state` namespace — check_instance accepts a VM named route-watcher,
# and its state file would otherwise be this record, with the run summary
# overwriting the VM's auto_route and group records. `state` holds the last
# run (status and diagnose surface it); `log` is the agent's stdout and
# stderr, where every flip, skip and failure is told in full.
route_watcher_dir() { printf '%s/route-watcher' "${HOMEFIELD_STATE_DIR:-$HOME/.local/state/homefield}"; }
route_watcher_state_file() { printf '%s/state' "$(route_watcher_dir)"; }
route_watcher_log_file() { printf '%s/log' "$(route_watcher_dir)"; }
route_watcher_plist_path() { printf '%s/com.homefield.route-watcher.plist' "${HOMEFIELD_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"; }
# The watcher's run marker: written around every cmd_route_watch run, read
# by the demand scaler (#291) — one owner per VM at a time, so a tick that
# overlaps a watcher run stands down. It carries the run's pid and start
# time: a run killed by a budget (or a crash) leaves the marker behind, and
# a dead pid — or one alive but from a run started too long ago to still be
# working, which is a pid reuse or a leaked marker — does not stop the
# scaler.
route_watcher_running_file() { printf '%s/running' "$(route_watcher_dir)"; }

route_watcher_running_write() {
  local f dir tmp
  f="$(route_watcher_running_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.running.XXXXXX")" || return 1
  {
    printf 'pid=%s\n' "$$"
    printf 'started=%s\n' "$(date +%s)"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

route_watcher_running_clear() { rm -f "$(route_watcher_running_file)"; }

# The sleep side's record of what was running: one instance name per line,
# the VMs that were Running with the automatic fallback on when the Mac last
# slept. The wake side starts only these — a VM the user stopped by hand, or
# one the demand scaler's scale-to-zero put dark, was not running at sleep
# and must not be woken by the Mac's next wake (a stop's own paths bring a
# VM back: the explicit start, or the tick's wake on demand for a dark
# line). The record is rewritten whole by every sleep run's pre-pass, and a
# line goes when its VM is up again (the wake side) or stopped again (the
# stop side), so a wake that runs without an intervening sleep — a LaunchAgent
# restart — does not start a VM that has since been stopped by hand.
route_watcher_sleep_running_file() { printf '%s/sleep-running' "$(route_watcher_dir)"; }

# route_watcher_sleep_running_store: SLEEP_RUNNING (one instance name per
# line, possibly empty) to the record, whole, through a temp file moved over
# the target — the way the run record and the dark record are written, under
# the record's lock (a store that overwrites a concurrent drop's result
# would resurrect the line the drop removed).
# Called by the multi-VM sleep run's pre-pass, between the status pass and
# the guest identity reads (a guest that hangs in its read must not erase
# the record the proven statuses earned), and never by a dispatched child
# (the parent's pre-pass wrote the whole record already).
route_watcher_sleep_running_store_transaction() {
  local f dir lockpid tmp name saved status verified=""
  f="$(route_watcher_sleep_running_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  # The snapshot was taken before this lock was held: a stop that completed
  # in between has removed its VM's line, and storing the stale snapshot
  # would put the line back — the next wake would start a VM someone
  # explicitly stopped. Re-prove each recorded VM under the lock: a VM that
  # is no longer Running (stopped by hand, or gone from the list) does not
  # go into the record, but a Lima that cannot be asked at the re-prove
  # keeps its line — the phase-1 proof stands, the same fail-safe direction
  # as a pre-pass that cannot ask. A stop that has not stopped its VM yet
  # removes the line after this store — its drop waits for this same lock.
  saved="$INSTANCE"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    INSTANCE="$name"
    status=""
    vrc=0
    status="$(vm_status_of "$name")" || vrc=$?
    if [ "$vrc" = 2 ]; then
      # Lima could not be asked at the re-prove: the phase-1 proof that the
      # VM was Running stands — the same fail-safe direction as a pre-pass
      # that cannot ask leaves the previous record. Only a confirmed
      # Stopped (or a VM gone from the list) loses its line here.
      verified="${verified}${name}"$'\n'
      continue
    fi
    [ "$status" = "Running" ] && verified="${verified}${name}"$'\n'
  done <<<"$SLEEP_RUNNING"
  INSTANCE="$saved"
  SLEEP_RUNNING="$verified"
  tmp="$(mktemp "$dir/.sleep-running.XXXXXX")" || return 1
  # The lock must still be mine: a reclamation by another writer could
  # have replaced it while this transaction ran (the reclamation is
  # fenced, but the fence's windows are measured in microseconds, not
  # zero). If it is not mine, the write must not land under another
  # writer's lock — the transaction gives up and the wrapper retries.
  lockpid="$(sed -n 's/^pid=//p' "$(route_watcher_sleep_running_lock_dir)/owner" 2>/dev/null)"
  if [ "$lockpid" != "$$" ]; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s' "$SLEEP_RUNNING" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  return 0
}

route_watcher_sleep_running_store() {
  local attempt=0 rc
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    rc=0
    route_watcher_sleep_running_with_lock || return 1
    route_watcher_sleep_running_store_transaction || rc=$?
    route_watcher_sleep_running_unlock
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
  done
  return "$rc"
}

# route_watcher_sleep_running_lock: the record's writers — the pre-pass's
# store, the explicit-instance sleep's add, and the stop and wake sides'
# drop — run one at a time. The record is rewritten whole through a temp
# file and an atomic rename, but rename alone does not serialize two
# writers that both read the same record before either replaces it: the
# last rename would resurrect the line the other removed, and a stopped VM
# would be started again by the next wake. The lock is a directory (mkdir
# is atomic); its owner file carries the pid, so a writer killed
# mid-transaction — the sleep budget kills a whole sleep run — leaves a
# lock the next writer steals once the owner is gone. The reclamation is
# fenced twice: it only removes a lock whose owner is still the same dead
# pid the contender saw, and it removes the directory by renaming it to a
# unique name, so of two reclaimers only one gets the directory — the
# other's removal cannot take a replacement lock with it. A live owner is
# never stolen, however long it holds the lock: the transaction may run
# Lima reads, and taking a live writer's lock would reintroduce the race
# the lock exists to prevent. Instead a writer waits a live holder out —
# by default half a minute, which covers a sleep-side store (the sleep
# budget kills a sleep run at HOMEFIELD_WATCH_SLEEP_BUDGET, 20 s, before
# it could hold the lock longer) — and a writer that still cannot get the
# lock leaves the record as it is, loudly on the stop side. A lock with no
# owner at all — a writer killed between the mkdir and the owner write —
# has nothing alive to check and is stolen once it has stayed undescribed
# for a fraction of a second.
route_watcher_sleep_running_lock_dir() { printf '%s/.sleep-running.lock' "$(route_watcher_dir)"; }

# The wait for a live holder, in seconds. HOMEFIELD_SLEEP_RUNNING_LOCK_WAIT
# overrides it (the tests drive it down; nothing else should).
route_watcher_sleep_running_lock_wait() {
  case "${HOMEFIELD_SLEEP_RUNNING_LOCK_WAIT:-}" in
    ''|*[!0-9.]*) echo 30 ;;
    *) echo "${HOMEFIELD_SLEEP_RUNNING_LOCK_WAIT}" ;;
  esac
}

route_watcher_sleep_running_with_lock() {
  local curpid dir ownerless=0 pid rounds trash waited=0
  dir="$(route_watcher_sleep_running_lock_dir)"
  mkdir -p "$(dirname "$dir")" || return 1
  rounds="$(awk -v w="$(route_watcher_sleep_running_lock_wait)" 'BEGIN { print int(w / 0.05) }')"
  until mkdir "$dir" 2>/dev/null; do
    if [ -f "$dir/owner" ]; then
      pid="$(sed -n 's/^pid=//p' "$dir/owner" 2>/dev/null)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        waited=$((waited + 1))
        if [ "$waited" -gt "$rounds" ]; then
          return 1
        fi
        sleep 0.05
        continue
      fi
      # The owner is gone: a writer killed mid-transaction. Reclaim the
      # lock, but only if it is still this same dead owner — another
      # writer may have reclaimed it first, and this reclamation must not
      # delete the replacement lock. The reclaim itself is a rename to a
      # unique name, so of two reclaimers only one gets the directory.
      curpid="$(sed -n 's/^pid=//p' "$dir/owner" 2>/dev/null)"
      if [ "$curpid" != "$pid" ]; then
        continue
      fi
      trash="${dir}.stale.$$.$RANDOM.$(date +%s)"
      if mv "$dir" "$trash" 2>/dev/null; then
        rm -rf "${trash:?}" 2>/dev/null || true
      fi
      continue
    fi
    # No owner: a live writer publishes it within the first retry, so a
    # lock still undescribed after a fraction of a second is a writer
    # killed between the mkdir and the owner write. Reclaim it the same
    # way, but only if it is still undescribed.
    if [ "$ownerless" -le 20 ]; then
      ownerless=$((ownerless + 1))
      sleep 0.05
      continue
    fi
    if [ -f "$dir/owner" ]; then
      continue
    fi
    trash="${dir}.stale.$$.$RANDOM.$(date +%s)"
    if mv "$dir" "$trash" 2>/dev/null; then
      rm -rf "${trash:?}" 2>/dev/null || true
    fi
    continue
  done
  printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" >"$dir/owner" 2>/dev/null
  return 0
}

# The release: only the owner removes the lock. A transaction that lost
# its lock to a reclamation (the transactions check, see below) must not
# take the new owner's lock down with it.
route_watcher_sleep_running_unlock() {
  local dir pid
  dir="$(route_watcher_sleep_running_lock_dir)"
  pid="$(sed -n 's/^pid=//p' "$dir/owner" 2>/dev/null)"
  if [ "$pid" = "$$" ]; then
    rm -rf "${dir:?}" 2>/dev/null || true
  fi
  return 0
}

# route_watcher_sleep_running_has <name>: whether the VM was running when
# the Mac slept. A read needs no lock: the writers' rename is atomic, so a
# concurrent read sees the old or the new record, both whole.
route_watcher_sleep_running_has() {
  local f
  f="$(route_watcher_sleep_running_file)"
  [ -f "$f" ] || return 1
  grep -Fxq "$1" "$f"
}

# route_watcher_sleep_running_add <name>: one line for a VM the pre-pass did
# not see — an explicit `route-watch sleep --instance` runs no pre-pass, so
# it maintains its own VM's line itself. The record is rewritten whole (the
# name's line replaced, the rest kept), through a temp file, under the
# record's lock.
route_watcher_sleep_running_add_transaction() {
  local f dir lockpid tmp rc name="$1"
  f="$(route_watcher_sleep_running_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.sleep-running.XXXXXX")" || return 1
  rc=0
  if [ -f "$f" ]; then
    # `cmd || rc=$?` captures the status without tripping set -e: grep's
    # "no line kept" answer (1) is normal here, not an error.
    grep -Fxv "$name" "$f" >"$tmp" || rc=$?
    if [ "$rc" -gt 1 ]; then
      rm -f "$tmp"
      return 1
    fi
  else
    : >"$tmp" || { rm -f "$tmp"; return 1; }
  fi
  printf '%s\n' "$name" >>"$tmp" || { rm -f "$tmp"; return 1; }
  # The lock must still be mine (see the store's transaction).
  lockpid="$(sed -n 's/^pid=//p' "$(route_watcher_sleep_running_lock_dir)/owner" 2>/dev/null)"
  if [ "$lockpid" != "$$" ]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  return 0
}

route_watcher_sleep_running_add() {
  local attempt=0 rc
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    rc=0
    route_watcher_sleep_running_with_lock || return 1
    route_watcher_sleep_running_add_transaction "$1" || rc=$?
    route_watcher_sleep_running_unlock
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
  done
  return "$rc"
}

# route_watcher_sleep_running_drop <name>: the VM is up, stopped by hand, or
# gone; its line goes with it, the record rewritten whole through a temp
# file, under the record's lock. A missing record is already without the
# line.
route_watcher_sleep_running_drop_transaction() {
  local f dir lockpid tmp rc name="$1"
  f="$(route_watcher_sleep_running_file)"
  [ -f "$f" ] || return 0
  dir="$(dirname "$f")"
  tmp="$(mktemp "$dir/.sleep-running.XXXXXX")" || return 1
  rc=0
  grep -Fxv "$name" "$f" >"$tmp" || rc=$?
  if [ "$rc" -gt 1 ]; then
    rm -f "$tmp"
    return 1
  fi
  # The lock must still be mine (see the store's transaction).
  lockpid="$(sed -n 's/^pid=//p' "$(route_watcher_sleep_running_lock_dir)/owner" 2>/dev/null)"
  if [ "$lockpid" != "$$" ]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  return 0
}

route_watcher_sleep_running_drop() {
  local attempt=0 rc
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    rc=0
    route_watcher_sleep_running_with_lock || return 1
    route_watcher_sleep_running_drop_transaction "$1" || rc=$?
    route_watcher_sleep_running_unlock
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
  done
  return "$rc"
}

# route_watcher_is_running: whether a watcher run is live — the marker
# exists, its pid is alive, and the run started within the last half hour
# (a watcher run is bounded by the sleep and wake budgets, so anything that
# old is a leftover, not a run). The scaler stands down only while this
# answers yes.
route_watcher_is_running() {
  local f pid started age
  f="$(route_watcher_running_file)"
  [ -f "$f" ] || return 1
  pid="$(awk -F= '$1 == "pid" {print $2}' "$f" 2>/dev/null)"
  started="$(awk -F= '$1 == "started" {print $2}' "$f" 2>/dev/null)"
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  case "$started" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  age="$(($(date +%s) - started))"
  [ "$age" -ge 0 ] && [ "$age" -lt 1800 ]
}

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
  dir="${HOMEFIELD_STATE_DIR:-$HOME/.local/state/homefield}"
  [ -d "$dir" ] || return 1
  # The demand scaler's scale-to-zero (#305): a VM the scaler put dark
  # still needs the agent — its ticks are what wake it on demand. The dark
  # record is the same `scale-dark` file the tick writes and clears; a
  # line the VM left by coming back up is dropped by the tick's reconcile.
  [ -s "$dir/route-watcher/scale-dark" ] && return 0
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
# through /bin/sh, re-resolving python3 from the baked PATH at every start
# so it survives python3 moving (a brew upgrade), with the PATH it needs
# for gh and limactl — launchd's own PATH has neither.
route_watcher_install() {
  local plist dir state_dir log
  command -v python3 >/dev/null 2>&1 || {
    echo "homefield: the route watcher needs python3 (its power-event helper); install it (xcode-select --install, or brew install python3) and run bin/homefield upgrade --auto-route" >&2
    return 1
  }
  command -v launchctl >/dev/null 2>&1 || {
    echo "homefield: launchctl is required to install the route watcher" >&2
    return 1
  }
  plist="$(route_watcher_plist_path)"
  dir="$(dirname "$plist")"
  state_dir="$(dirname "$(route_watcher_state_file)")"
  log="$(route_watcher_log_file)"
  # The demand scaler's spare installs arrive here with --auto-route from a
  # subprocess of the tick (HOMEFIELD_SCALE_INSTALL): the agent that runs
  # the tick is already installed and loaded, and an unload would stop the
  # very helper supervising the tick mid-install. Leave it as it is — the
  # plist on disk is the one it loaded, and a hand-run `upgrade --auto-route`
  # is the path that refreshes it.
  if [ -n "${HOMEFIELD_SCALE_INSTALL:-}" ] && [ -f "$plist" ]; then
    log "the route watcher is already installed; the spare's install leaves it running as it is"
    return 0
  fi
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
  if [ -n "${HOMEFIELD_WATCH_WAKE_BUDGET:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_WATCH_WAKE_BUDGET</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_WATCH_WAKE_BUDGET")</string>"$'\n'
  fi
  # The demand scaler's (#291) tuning reaches the agent the same way: the
  # tick is a child of the helper, and launchd does not inherit a shell's
  # environment, so every HOMEFIELD_SCALE_* the docs document must be baked
  # into the plist's own environment block.
  if [ -n "${HOMEFIELD_SCALE_INTERVAL:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_SCALE_INTERVAL</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_SCALE_INTERVAL")</string>"$'\n'
  fi
  if [ -n "${HOMEFIELD_SCALE_TICK_BUDGET:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_SCALE_TICK_BUDGET</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_SCALE_TICK_BUDGET")</string>"$'\n'
  fi
  if [ -n "${HOMEFIELD_SCALE_WAIT:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_SCALE_WAIT</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_SCALE_WAIT")</string>"$'\n'
  fi
  if [ -n "${HOMEFIELD_SCALE_IDLE:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_SCALE_IDLE</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_SCALE_IDLE")</string>"$'\n'
  fi
  if [ -n "${HOMEFIELD_SCALE_MAX:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_SCALE_MAX</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_SCALE_MAX")</string>"$'\n'
  fi
  if [ -n "${HOMEFIELD_SCALE_ZERO:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_SCALE_ZERO</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_SCALE_ZERO")</string>"$'\n'
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
    <string>exec "\$(command -v python3)" "$(route_watcher_xml_escape "$ROOT/bin/route-watcher.py")"</string>
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

# route_watch_collect_runners: every Running HomeField VM's registration
# (url and runner name, tab-separated per line), into ROUTE_EXCLUDE_RUNNERS —
# the pre-pass of the sleep side. The flip's "another online runner serves the
# label" check excludes the runner being stopped by name, but at sleep time
# every runner on this Mac goes away together, so all of their names must be
# excluded: without that, two VMs sharing a label would each leave the
# repositories to the other and nothing would be flipped. The registrations
# carry their scope (the url) because the names alone do not: a Mac with
# runners for two organizations must not let one org's local runner name
# exclude a same-named remote runner of the other org, which still serves its
# repositories. Only names from the same registration scope are excluded, and
# a Stopped VM's runner is not heartbeating and is no threat, so only Running
# VMs are asked (a `limactl shell` on a stopped VM starts it). A VM that
# cannot be asked poisons the whole flip — its runner may still be listed
# online and serving the label — so a failure here flips nothing (fail safe,
# the same direction as Part 1's).
#
# The same pass collects the wake side's record: SLEEP_RUNNING, one name per
# line, every Running VM whose own automatic fallback is on. A VM whose flip
# was later skipped (a job was running) is still recorded — it was running
# when the Mac slept, and the wake side brings it back. A Stopped VM —
# stopped by hand, or scaled dark — is not: the wake side must not start it.
# The pass runs in two phases, and the parent stores the record between
# them: phase one proves every VM's status and collects the record (the
# record needs only Running and auto_route on), phase two reads the Running
# VMs' runner identities for the flip's exclusions. The store sits before
# any guest identity read because a guest can hang in its `limactl shell`
# until the sleep budget kills the whole run — the VMs' proven Running
# statuses must already be on disk by then, or the next wake (the previous
# record having been consumed) would refuse to start them. An identity read
# that fails returns 2: the flip is poisoned (the exclusions are incomplete
# and a runner that may still be online must not lose its jobs), but the
# record is already stored. A failure that leaves a status unproven — the
# VM list, or Lima not answering about a VM — returns 1 and the previous
# record stays: it holds the VMs running at the last proven sleep, and
# nothing newer is known.
route_watch_collect_runners() {
  local identity_failed=0 list name running="" saved status
  saved="$INSTANCE"
  SLEEP_RUNNING=""
  if ! list="$(vm_instances)"; then
    echo "homefield: could not list the VMs; the routed repositories stay as they are" >&2
    return 1
  fi
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
    running="${running}${name}"$'\n'
    if [ "$(state_get auto_route)" = "1" ]; then
      SLEEP_RUNNING="${SLEEP_RUNNING}${name}"$'\n'
    fi
  done <<<"$list"
  INSTANCE="$saved"
  # The record goes to disk here, before any guest is contacted: this is
  # the last point at which a later hang cannot erase it.
  if ! route_watcher_sleep_running_store; then
    echo "homefield: could not write $(route_watcher_sleep_running_file); the wake side will not start VMs it cannot prove were running" >&2
  fi
  ROUTE_EXCLUDE_RUNNERS=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    INSTANCE="$name"
    load_runner_settings
    if [ -z "$RS_NAME" ] || [ -z "$RS_URL" ]; then
      echo "homefield: could not read VM ${name}'s runner identity; the routed repositories stay as they are (fail safe: a runner that may still be online must not lose its jobs)" >&2
      identity_failed=1
      continue
    fi
    ROUTE_EXCLUDE_RUNNERS="${ROUTE_EXCLUDE_RUNNERS}${RS_URL}"$'\t'"${RS_NAME}"$'\n'
  done <<<"$running"
  INSTANCE="$saved"
  [ "$identity_failed" = 0 ] && return 0
  return 2
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
  if [ "$(state_get auto_route)" != "1" ]; then
    log "VM ${INSTANCE}: the automatic fallback is off; leaving its routing alone"
    # An explicit --instance sleep runs no pre-pass, so it maintains its own
    # VM's line itself: the fallback is off, the line goes. A dispatched
    # child must not — the parent's pre-pass wrote the whole record already.
    if [ "$EXPLICIT_INSTANCE" = 1 ] && [ "${HOMEFIELD_ONE_OF_MANY:-0}" != 1 ]; then
      route_watcher_sleep_running_drop "$INSTANCE" || true
    fi
    return 0
  fi
  if [ "$EXPLICIT_INSTANCE" = 1 ] && [ "${HOMEFIELD_ONE_OF_MANY:-0}" != 1 ]; then
    if [ "$VM_STATUS" = "Running" ]; then
      route_watcher_sleep_running_add "$INSTANCE" || true
    else
      route_watcher_sleep_running_drop "$INSTANCE" || true
    fi
  fi
  [ "$VM_STATUS" = "Running" ] || { log "VM ${INSTANCE}: ${VM_STATUS}; its runner is not taking jobs, so there is nothing to flip"; return 0; }
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
  # Only the exclusions from this VM's own registration scope: the flip asks
  # GitHub for the runners of RS_URL's scope, so a same-named runner of
  # another org is not in the list to begin with — and its name must not
  # exclude one of this scope's runners that is still there.
  local scoped="" eurl ename
  while IFS=$'\t' read -r eurl ename; do
    [ -n "$eurl" ] || continue
    if [ "$eurl" = "$RS_URL" ]; then
      scoped="${scoped}${ename}"$'\n'
    fi
  done <<<"${ROUTE_EXCLUDE_RUNNERS:-}"
  route_stop_fallback "$RS_URL" "$RS_NAME" "$scoped"
}

# route_watch_wake_single: one VM's wake side. Start it if it is not running
# and the sleep side recorded it as running (the Lima VMs do not survive
# sleep cleanly), wait for its runner to be listed online — the restore needs
# GitHub's row for the runner, and restoring while it is still offline would
# point the repositories at a runner that is not taking jobs — then bring the
# flipped repositories back to local. A VM the sleep side did not record was
# not running when the Mac slept — stopped by hand, or scaled dark — and
# stays down: a stop's own paths bring it back (the explicit start, or the
# tick's wake on demand for a dark line), not the Mac's next wake. The waits
# are bounded (HOMEFIELD_WATCH_WAKE_WAIT, default 120 s): a VM that does not
# come back keeps its entries for the next start or the next wake, and the
# run says so loudly.
route_watch_wake_single() {
  vm_lookup
  if [ -z "$VM_STATUS" ]; then
    log "VM ${INSTANCE}: does not exist; nothing to watch"
    # Lima answered and named no VM: a stale line would only wait for a VM
    # that is gone.
    route_watcher_sleep_running_drop "$INSTANCE" || true
    return 0
  fi
  if [ "$(state_get auto_route)" != "1" ]; then
    log "VM ${INSTANCE}: the automatic fallback is off; leaving its routing alone"
    return 0
  fi
  if [ "$VM_STATUS" != "Running" ]; then
    if ! route_watcher_sleep_running_has "$INSTANCE"; then
      log "VM ${INSTANCE}: was not running when the Mac slept (stopped by hand, or scaled dark); not starting it — its pending repositories wait for the next start or a demand wake"
      return 0
    fi
    log "VM ${INSTANCE}: starting it (it was running when the Mac slept)"
    limactl start --tty=false "$INSTANCE" </dev/null ||
      { echo "homefield: could not start VM ${INSTANCE}; its flipped repositories stay hosted until the next start" >&2; return 1; }
  fi
  # The VM is up: its line in the sleep record goes, so a wake that runs
  # again before the next sleep — a LaunchAgent restart — does not start a
  # VM the user has since stopped by hand.
  route_watcher_sleep_running_drop "$INSTANCE" || true
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
  # The run marker goes up before any work and comes down after it, on every
  # path: the demand scaler stands down while it is up (one owner per VM at
  # a time, #291). Only the parent run writes it — a multi-VM dispatch's
  # children re-run this command with --instance, and each would otherwise
  # overwrite the marker with its own pid and clear it while the others are
  # still working. A run killed by a budget leaves the marker behind; the
  # marker's pid and age tell the scaler that run is gone.
  if [ "${HOMEFIELD_ONE_OF_MANY:-0}" != 1 ]; then
    route_watcher_running_write || true
  fi
  local rc=0
  # The mode goes with the dispatch: a multi-VM run's per-VM children re-run
  # the command with --instance, and the mode must survive that.
  if [ "$mode" = sleep ] && [ "$EXPLICIT_INSTANCE" = 0 ]; then
    collect_rc=0
    route_watch_collect_runners || collect_rc=$?
    if [ "$collect_rc" != 0 ]; then
      route_watcher_record sleep 1 || true
      if [ "${HOMEFIELD_ONE_OF_MANY:-0}" != 1 ]; then
        route_watcher_running_clear
      fi
      return 1
    fi
    export ROUTE_EXCLUDE_RUNNERS
  fi
  vm_dispatch "route-watch" "route_watch_${mode}_single" "$mode" || rc=1
  route_watcher_record "$mode" "$rc" || rc=1
  if [ "${HOMEFIELD_ONE_OF_MANY:-0}" != 1 ]; then
    route_watcher_running_clear
  fi
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