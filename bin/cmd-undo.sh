#!/usr/bin/env bash
# uninstall and reset: taking the runner, the VM and the tool back down.

# deregister_script: what uninstall runs in the guest, as root, with an empty
# line on its stdin where a remove token used to be: the registration is
# deleted from the host through the API (deregister_runner), so the guest's
# config.sh remove --local takes down only the VM's copy and no secret
# enters the guest. Before anything is removed, the registration files are
# copied to the backup directory (deregister_runner passes RS_BACKUP, inside
# its private staging directory): the removal is only irreversible once the
# GitHub API deletion has succeeded, so a failure anywhere — here, or the
# API deletion after — is recovered by copying the files back and starting
# the service again: a runner GitHub still knows, taking jobs. config.sh
# refuses to remove a runner whose service is installed, so the service goes
# first; on a failure the script restores the backup (the removal may have
# deleted the files before failing) and provision.sh's ensure-service --start
# puts the service back (#99): this release's copy, put in the guest by
# cmd_uninstall, so a VM provisioned by an older one gets it too.
#
# deregister_script local: removes only the VM's copy of the registration
# (`config.sh remove --local`, which asks GitHub nothing), with an empty
# line for the token.
deregister_script() {
  # shellcheck disable=SC2016  # the guest's shell expands these, not this one
  local script='cd @HOME@ && read -r t && s=0 && { [ ! -f .service ] || s=1; } && mkdir -p @BACKUP@ && for f in .runner .credentials .credentials_rsaparams .env; do if [ -f "$f" ]; then cp -p "$f" @BACKUP@/ || { echo "homefield: could not back up $f in the VM; nothing was removed" >&2; exit 1; }; fi; done && restore_reg() { cd @HOME@ && for f in .runner .credentials .credentials_rsaparams .env; do { [ ! -f @BACKUP@/"$f" ] || cp -p @BACKUP@/"$f" ./; }; done; } && { [ "$s" = 0 ] || ./svc.sh uninstall || { rc=$?; restore_reg; bash @PROVISION@ ensure-service --start; exit "$rc"; }; } && { ACTIONS_RUNNER_INPUT_TOKEN="$t" sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u runner ./config.sh remove@LOCAL@ || { rc=$?; restore_reg; [ "$s" = 0 ] || bash @PROVISION@ ensure-service --start; exit "$rc"; }; }'
  local provision="$1" flag=""
  [ "${2:-}" != local ] || flag=" --local"
  script="${script//@HOME@/$RUNNER_HOME}"
  script="${script//@BACKUP@/${RS_BACKUP:?}}"
  script="${script//@LOCAL@/$flag}"
  script="${script//@PROVISION@/$provision}"
  printf '%s' "$script"
}

# deregister_restore_script: the host-side recovery when the GitHub API
# deletion fails after the guest cleanup succeeded: the registration files
# go back from the backup, and the service is installed and started — the
# runner is registered on GitHub and working again, and a re-run of the
# command can try the deletion once the cause (network, token scope) is
# fixed.
deregister_restore_script() {
  # shellcheck disable=SC2016  # the guest's shell expands these, not this one
  local script='cd @HOME@ && for f in .runner .credentials .credentials_rsaparams .env; do { [ ! -f @BACKUP@/"$f" ] || cp -p @BACKUP@/"$f" ./; }; done && bash @PROVISION@ ensure-service --start'
  script="${script//@HOME@/$RUNNER_HOME}"
  script="${script//@BACKUP@/${RS_BACKUP:?}}"
  printf '%s' "${script//@PROVISION@/$1}"
}

# deregister_runner <url> <id> <on>: deregisters a runner its caller has
# already taken out of service; <on> is runner_on_github's answer for it (1:
# GitHub no longer has it, so only the VM's copy of the registration goes).
# Shared by uninstall and reset. The caller has checked that no job is
# running and called stop_runner, which arms restart_runner_on_failure. The
# fallible guest cleanup runs first — while the registration still exists on
# GitHub, and with the registration files backed up first, so a failure
# there restores a working runner — and the irreversible API deletion goes
# last, after the trap is disarmed: a failed deletion is itself recovered
# (the backup goes back, the service starts again, the runner keeps taking
# jobs), and only its message asks for a re-run. A failure in the guest
# cleanup ends the command (die, or `set -e`) after that trap has given the
# runner its service back, so call it as a plain command, never from a
# condition: errexit is off in there and the failure would pass for
# success.
deregister_runner() {
  local url="$1" id="$2" on="$3" stage scope host
  echo "homefield: switch every repository that routes to this runner to hosted first:" >&2
  echo "homefield:   gh variable set CI_RUNNER --repo <owner>/<repo> --body hosted" >&2
  # The restore deregister_script falls back on, staged in a private
  # directory before anything is changed (#185). The registration files are
  # backed up inside it (RS_BACKUP) before the cleanup, and the cleanup and
  # the API deletion both recover from it on failure. RS_STAGE is cleaned up
  # by restart_runner_on_failure (the EXIT trap stop_runner set in the
  # caller) when a failure ends the command mid-flow, and explicitly after
  # runner_back.
  stage="$(guest_stage_dir)"
  RS_STAGE="$stage"
  RS_BACKUP="${stage}/reg-backup"
  # shellcheck disable=SC2153  # PROVISION is bin/homefield's, this file is sourced
  limactl copy "$PROVISION" "${INSTANCE}:${stage}/provision.sh" ||
    { guest_unstage "$stage"; RS_STAGE=""; die "could not copy provision.sh into VM ${INSTANCE}; nothing was deregistered"; }
  # The runner is already offline (the caller stopped it right after the idle
  # check), so nothing can start a job while the registration goes.
  if [ "$on" = 1 ]; then
    # A full removal would ask GitHub to delete a runner it does not have.
    log "GitHub no longer has this runner (id ${id}) at ${url}; removing its registration from the VM only"
    printf '\n' | guest_stdin sudo sh -c "$(deregister_script "${stage}/provision.sh" local)"
    runner_back
    guest_unstage "$stage"
    RS_STAGE=""
  else
    # The registration is deleted from the host, through the API, the way
    # install's --replace removes a taken name: the removal token never
    # enters the guest. A VM that has run jobs may hold a root process the
    # job left behind, and such a process can read a token from the
    # provisioning process's environment (/proc/<pid>/environ) — so the
    # guest's config.sh remove --local takes down only the VM's copy, with
    # no secret on its stdin. The local cleanup runs first, while the
    # registration still exists on GitHub: a failure here ends the command
    # with the registration files restored and the service running, so the
    # caller's restart trap can start it again — a runner that is still
    # registered and takes jobs. The API deletion is irreversible and goes
    # last, after the restart trap is disarmed: by then there is no service
    # left to restore through the trap, so a failed deletion runs the
    # restore itself (the backup from before the cleanup) and says what
    # happened, rather than starting a runner whose registration is gone or
    # leaving a registered one offline.
    scope="$(api_scope "$url")" || exit 1
    host="$(github_host "$url")"
    log "deregistering from ${url} (id ${id})"
    printf '\n' | guest_stdin sudo sh -c "$(deregister_script "${stage}/provision.sh" local)"
    runner_back
    # The staging directory (with the registration backup) is kept until the
    # API deletion has answered: a failure there restores from it.
    if ! gh api --hostname "$host" -X DELETE "${scope}/actions/runners/${id}" >/dev/null; then
      printf '\n' | guest_stdin sudo sh -c "$(deregister_restore_script "${stage}/provision.sh")" ||
        echo "homefield: could not restore the VM's registration either; the runner is registered on GitHub but offline — fix the guest by hand or delete the VM: limactl delete --force ${INSTANCE}" >&2
      guest_unstage "$stage"
      RS_STAGE=""
      die "could not deregister runner ${id} from ${url}; the VM's registration is restored and the service is running again, so the runner still takes jobs — fix the cause (network, gh authorization) and run this again"
    fi
    guest_unstage "$stage"
    # shellcheck disable=SC2034  # read by lib/vm.sh's restart_runner_on_failure
    RS_STAGE=""
  fi
}

# delete_vm: takes the VM out of start at login, stops it and deletes it.
# Returns limactl delete's status when that fails: uninstall calls it as a plain
# command, so errexit ends it as before; reset checks the status.
delete_vm() {
  limactl autostart disable "$INSTANCE" >/dev/null 2>&1 || limactl start-at-login --enabled=false "$INSTANCE" >/dev/null 2>&1 || true
  limactl stop --force "$INSTANCE" >/dev/null 2>&1 || true
  limactl delete --force "$INSTANCE" || return $?
  log "deleted VM ${INSTANCE}"
}

# delete_reset_base: delete the instance's reset base VM, when there is one.
# A --reset-vm install leaves <instance>-base behind (stopped, unregistered)
# as the source every later reset clones from; with the runner VM gone it is
# orphaned (~2 GiB of Lima disk), so uninstall and reset take it with the VM.
# Only a base that carries the HomeField reset-base marker is touched: an
# ordinary runner that happens to be named <instance>-base is never deleted —
# the same rule vm_instances' exclusion and install's base replacement follow.
# Returns 0 when there was no marked base or the delete succeeded; a failed
# delete returns 1 with limactl's own error on stderr, for the caller to report.
delete_reset_base() {
  local base="${INSTANCE}-base"
  is_reset_base "$base" || return 0
  limactl delete --force "$base" || return 1
  log "deleted reset base VM ${base}"
}

cmd_uninstall() {
  local keep_vm=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-vm) keep_vm=1; shift ;;
      *) die "uninstall: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  refuse_unnamed_vm uninstall
  check_host
  local status
  vm_lookup
  status="$VM_STATUS"
  [ -n "$status" ] || die "no VM ${INSTANCE}"
  [ "$status" = "Running" ] || limactl start --tty=false "$INSTANCE"
  if is_registered; then
    is_job_running && die "a job is running on ${INSTANCE}; uninstall when it is idle"
    # Offline straight after the idle check: reading the settings and asking
    # GitHub whether it still has the runner can take HOMEFIELD_GH_TIMEOUT,
    # and a job picked up in that window would be cancelled. stop_runner arms
    # the restart-on-failure trap.
    stop_runner
    local url="" id="" on=0
    { read -r url || true; read -r id || true; } < <(runner_setting gitHubUrl agentId)
    [ -n "$url" ] || die "could not read the runner's registration in VM ${INSTANCE}; nothing was deregistered"
    runner_on_github "$url" "$id" || on=$?
    deregister_runner "$url" "$id" "$on"
  else
    log "${INSTANCE} is not registered; nothing to deregister"
  fi
  if [ "$keep_vm" = 1 ]; then
    log "kept VM ${INSTANCE}"
    return
  fi
  delete_vm
  # The reset base goes with the VM (see delete_reset_base): a --reset-vm
  # install leaves it behind as the clone source, and with the runner VM gone
  # nothing clones from it. A base that cannot be deleted is a warning, not a
  # failed uninstall: the runner is gone either way, and the hand command names
  # what is left.
  delete_reset_base ||
    echo "homefield: warning: could not delete the reset base VM ${INSTANCE}-base; delete it by hand: limactl delete --force ${INSTANCE}-base" >&2
  # The sleep/wake agent is per-Mac: with this VM gone (its state file
  # outlives it — reset, not uninstall, removes that), take the agent out
  # when no remaining VM wants it. This VM's own state does not count.
  route_watcher_remove_if_unneeded "$INSTANCE" ||
    echo "homefield: warning: could not remove the route watcher LaunchAgent; remove it by hand (launchctl unload -w $(route_watcher_plist_path))" >&2
}

# The runner as the VM says, set by reset_inspect: R_REG 1 when registered,
# its URL and id, and R_ON runner_on_github's answer for it.
R_REG=0
R_URL=""
R_ID=""
R_ON=2
# reset_inspect [stop]: reads the above from a running VM. A running job ends
# the command, before anything is asked or changed. With `stop`, the runner
# goes offline right after that idle check, before its settings and GitHub
# presence are read, so a job cannot start in between (#238).
reset_inspect() {
  local stop="${1:-}"
  R_REG=0
  R_URL=""
  R_ID=""
  R_ON=2
  is_registered || return 0
  R_REG=1
  is_job_running && die "a job is running on ${INSTANCE}; reset when it is idle (no runner was touched)"
  [ "$stop" != stop ] || stop_runner
  { read -r R_URL || true; read -r R_ID || true; } < <(runner_setting gitHubUrl agentId)
  [ -n "$R_URL" ] || die "could not read the runner's registration in VM ${INSTANCE}; nothing was deregistered"
  R_ON=0
  runner_on_github "$R_URL" "$R_ID" || R_ON=$?
}

# The runner group install created, from the state file (state_get): org, name
# and id (empty when install could not read it from GitHub's answer), the host
# the group lives on (github.com for a record written before the host support,
# which was github.com-only), and RG_BAD 1 for a record that does not parse.
RG_ORG=""
RG_NAME=""
RG_ID=""
RG_BAD=0
RG_LABEL=""
RG_PAGE=""
RG_HOST=""

reset_load_group() {
  local raw re='^([A-Za-z0-9_.-]+)/(.+)/([0-9]*)(/([A-Za-z0-9_.-]+))?$'
  RG_ORG=""
  RG_NAME=""
  RG_ID=""
  RG_HOST=""
  RG_BAD=0
  raw="$(state_get group_created)"
  [ -n "$raw" ] || return 0
  if [[ "$raw" =~ $re ]]; then
    RG_ORG="${BASH_REMATCH[1]}"
    RG_NAME="${BASH_REMATCH[2]}"
    RG_ID="${BASH_REMATCH[3]}"
    # A 3-field record (written before the host support) is a github.com
    # group: the tool did not work on other hosts then.
    RG_HOST="${BASH_REMATCH[5]:-github.com}"
    RG_LABEL="${RG_ORG}/${RG_NAME}"
  else
    RG_BAD=1
  fi
}

# ── reset ───────────────────────────────────────────────────────────────────
# reset rolls back a complete or half-finished install of one instance: the
# runner's registration, the VM and the runner group install created, and with
# --remove-tool the tool itself. It works from what exists now, so a failed
# install, an uninstall that stopped partway and a VM deleted by hand are all
# one case; nothing existing is a no-op. What it removes is in the plan it
# prints and asks about before any change, and in the report it ends with.
#
# What reset did, one line each, printed at the end. RESET_RC is the exit
# status (1 once a requested step failed); RG_KEEP 1 keeps the state file,
# because a group it records still exists.
REPORT=()
RESET_RC=0
RG_KEEP=0

rep() { REPORT+=("$1"); }

# group_kept <why> [problem]: the group stays, and so does its record, so that
# a later reset can still delete it. With a second argument it is a failure.
group_kept() {
  rep "runner group ${RG_LABEL}: kept, ${1}${RG_PAGE:+ (delete it at ${RG_PAGE} if it is not wanted)}"
  RG_KEEP=1
  [ -z "${2:-}" ] || RESET_RC=1
}

# reset_group <keep> <own runner id>: deletes the runner group the state file
# says install created, only when every guard holds: it is not the Default
# group; GitHub lists it now with the recorded id (or, with no id recorded,
# the recorded name) and name; nothing but this instance's own runner (<own>,
# empty if it is not in the group) is in it, because deleting a group moves its
# runners to Default; and --keep-group was not given. A group that cannot be
# checked is not deleted.
reset_group() {
  local keep="$1" own="$2" rows="" ids="" name vis pub id rid found_id="" found_name="" others=0 out host
  # The group lives on the host the group_created record names — where this
  # install created it, which survives a failed registration and a VM deleted
  # by hand (R_URL is empty in both, and the environment may name another
  # host). A record without a host field is a pre-host-support github.com
  # group; with no record at all, the runner's registration host (R_URL) or
  # HOMEFIELD_GITHUB_HOST, as before.
  host="${RG_HOST:-$(github_host "$R_URL")}"
  RG_PAGE="https://${host}/organizations/${RG_ORG}/settings/actions/runner-groups"
  if [ "$keep" = 1 ]; then
    group_kept "--keep-group was given"
    return 0
  fi
  if [ "$(lower "$RG_NAME")" = default ]; then
    rep "runner group ${RG_LABEL}: not deleted, it is the Default group"
    return 0
  fi
  if ! command -v gh >/dev/null; then
    group_kept "gh is not installed, so it was not checked" problem
    return 0
  fi
  if ! rows="$(list_groups_ids "$RG_ORG" "$host")"; then
    group_kept "gh could not list the runner groups of ${RG_ORG} (needs an org owner with the admin:org scope)" problem
    return 0
  fi
  # shellcheck disable=SC2034  # vis and pub name the TSV columns positionally
  while IFS=$'\t' read -r name vis pub id; do
    [ -n "$id" ] || continue
    if [ -n "$RG_ID" ]; then
      [ "$id" = "$RG_ID" ] || continue
    else
      [ "$(lower "$name")" = "$(lower "$RG_NAME")" ] || continue
    fi
    found_id="$id"
    found_name="$name"
  done <<<"$rows"
  if [ -z "$found_id" ]; then
    rep "runner group ${RG_LABEL}${RG_ID:+ (id ${RG_ID})}: not on GitHub any more, nothing to delete"
    return 0
  fi
  if [ "$(lower "$found_name")" != "$(lower "$RG_NAME")" ]; then
    group_kept "group id ${found_id} is now named ${found_name}, not the group install created"
    return 0
  fi
  if ! ids="$(group_runner_ids "$RG_ORG" "$found_id" "$host")"; then
    group_kept "gh could not list its runners, so it was not checked" problem
    return 0
  fi
  while IFS= read -r rid; do
    [ -n "$rid" ] || continue
    if [ -n "$own" ] && [ "$rid" = "$own" ]; then continue; fi
    others=$((others + 1))
  done <<<"$ids"
  if [ "$others" -gt 0 ]; then
    group_kept "it holds ${others} other runner(s), and deleting a group moves its runners to Default"
    return 0
  fi
  if out="$(gh api --hostname "$host" -X DELETE "orgs/${RG_ORG}/actions/runner-groups/${found_id}" </dev/null 2>&1)"; then
    rep "runner group ${RG_LABEL} (id ${found_id}): deleted"
  else
    group_kept "gh could not delete it (${out:-no message}; needs an org owner with the admin:org scope)" problem
  fi
}

# confirm_reset: reset is destructive. HOMEFIELD_YES=1 (install.sh's switch
# for the same purpose) answers yes; otherwise a terminal is asked, and
# without one this stops, before anything is changed.
confirm_reset() {
  local answer
  [ "${HOMEFIELD_YES:-}" != 1 ] || return 0
  have_terminal || die "reset removes what is listed above and there is no terminal to ask on; run it again with HOMEFIELD_YES=1 to go ahead (nothing was changed)"
  read -rp "Remove all of the above? [y/N] " answer || answer=""
  case "$answer" in
    [Yy]*) ;;
    *) die "stopped: nothing was changed" ;;
  esac
}

# State cmd_reset's helpers share: the options (RESET_KEEP_VM, RESET_KEEP_GROUP,
# RESET_REMOVE_TOOL), what --remove-tool found (RESET_WRAPPERS, the wrapper
# commands, one per line, and RESET_TOOL_DIR, the tool directory; both empty
# when --remove-tool was not given), and RESET_ASKED_EARLY, 1 when the plan's
# runner answer came from before the confirmation. The helpers also read
# reset_inspect's R_* and reset_load_group's RG_* state and report through
# rep, RESET_RC and RG_KEEP.
RESET_KEEP_VM=0
RESET_KEEP_GROUP=0
RESET_REMOVE_TOOL=0
RESET_WRAPPERS=""
RESET_TOOL_DIR=""
RESET_ASKED_EARLY=0

# reset_options <args...>: the reset options, into RESET_KEEP_VM,
# RESET_KEEP_GROUP and RESET_REMOVE_TOOL. Dies on an unknown option, before
# anything is looked at.
reset_options() {
  RESET_KEEP_VM=0
  RESET_KEEP_GROUP=0
  RESET_REMOVE_TOOL=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-vm) RESET_KEEP_VM=1; shift ;;
      --keep-group) RESET_KEEP_GROUP=1; shift ;;
      --remove-tool) RESET_REMOVE_TOOL=1; shift ;;
      *) die "reset: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
}

# reset_plan <vm>: builds and prints the plan of what reset will do, from the
# runner state reset_inspect read (R_REG, R_ON, R_URL), the group record
# reset_load_group read (RG_ORG, RG_LABEL) and the options, and asks for the
# confirmation. Sets RESET_WRAPPERS and RESET_TOOL_DIR when RESET_REMOVE_TOOL
# is 1; the removal below reads them too.
reset_plan() {
  local vm="$1" line
  local plan=()
  if [ "$RESET_REMOVE_TOOL" = 1 ]; then
    RESET_WRAPPERS="$(tool_wrappers)"
    RESET_TOOL_DIR="$(tool_dir)"
  fi

  if [ -n "$vm" ]; then
    if [ "$vm" != Running ]; then
      plan+=("start VM ${INSTANCE} (${vm}) to look for a registered runner in it")
    elif [ "$R_REG" = 1 ] && [ "$R_ON" = 1 ]; then
      plan+=("remove the runner's registration from VM ${INSTANCE}; GitHub no longer lists it (${R_URL})")
    elif [ "$R_REG" = 1 ]; then
      plan+=("deregister the runner from ${R_URL}")
    fi
    [ "$RESET_KEEP_VM" = 1 ] || plan+=("delete VM ${INSTANCE}")
    if [ "$RESET_KEEP_VM" = 0 ] && is_reset_base "${INSTANCE}-base"; then
      plan+=("delete the reset base VM ${INSTANCE}-base, which install --reset-vm created (nothing clones from it once the VM is gone)")
    fi
  elif [ "$RESET_KEEP_VM" = 0 ] && is_reset_base "${INSTANCE}-base"; then
    plan+=("delete the orphaned reset base VM ${INSTANCE}-base (the runner VM is already gone)")
  fi
  if [ -n "$RG_ORG" ] && [ "$RESET_KEEP_GROUP" = 0 ]; then
    plan+=("delete the runner group ${RG_LABEL}, which install created, unless it holds other runners")
  fi
  if [ -n "$RESET_WRAPPERS" ]; then
    plan+=("remove the command ${RESET_WRAPPERS}, shared by every instance on this Mac")
  fi
  if [ -n "$RESET_TOOL_DIR" ]; then
    plan+=("remove the tool in ${RESET_TOOL_DIR}, shared by every instance on this Mac")
  fi
  if [ "${#plan[@]}" -gt 0 ]; then
    echo "Reset of ${INSTANCE} will:"
    for line in "${plan[@]}"; do echo "  - ${line}"; done
    confirm_reset
  fi
}

# reset_vm <vm>: the VM part of the plan, after the confirmation. Starts a
# stopped VM to inspect it, deregisters a registered runner and deletes the
# VM unless RESET_KEEP_VM. Reports through rep; sets RESET_RC 1 when the
# deletion fails. Reads reset_inspect's R_* state, and leaves R_ID for
# reset_group: it is set only for a runner that was registered here and is
# now deregistered (or the command would have ended), the one runner that may
# still show in the group for a moment.
# reset_base_cleanup: the reset side of delete_reset_base — delete the
# instance's marked base and report it, failing the run's cleanup when the
# delete fails. A no-op when there is no marked base. Runs after the runner
# VM is deleted, and also when it is already gone: a base left behind by a
# failed delete (the report named the hand command) or by a re-register clone
# that failed after the delete is what a retry cleans.
reset_base_cleanup() {
  is_reset_base "${INSTANCE}-base" || return 0
  if delete_reset_base; then
    rep "reset base VM ${INSTANCE}-base: deleted"
  else
    rep "reset base VM ${INSTANCE}-base: could not be deleted (limactl said why above); delete it by hand: limactl delete --force ${INSTANCE}-base"
    RESET_RC=1
  fi
}

reset_vm() {
  local vm="$1"
  if [ -n "$vm" ]; then
    if [ "$vm" != Running ]; then
      log "starting VM ${INSTANCE}"
      limactl start --tty=false "$INSTANCE" ||
        die "could not start VM ${INSTANCE} to look for a registered runner; if one registered, remove it on GitHub's runners page, then delete the VM by hand: limactl delete --force ${INSTANCE}"
      # Started after the confirmation: idle check, stop, then the settings
      # and GitHub reads, in that order, with no window between.
      reset_inspect stop
    fi
    if [ "$R_REG" = 1 ]; then
      # A runner that was online while the plan was read and confirmed may
      # have taken a job since; nothing has been changed yet.
      if [ "$RESET_ASKED_EARLY" = 1 ]; then
        if is_job_running; then
          die "a job started on ${INSTANCE} while you were deciding; reset when it is idle (no runner was touched)"
        fi
        # Offline straight after that check, before the deregistration work.
        stop_runner
      fi
      # Plain command, not a condition: a failure here ends reset with the VM
      # kept and the runner's service back, and nothing after it is done.
      deregister_runner "$R_URL" "$R_ID" "$R_ON"
      if [ "$R_ON" = 1 ]; then
        rep "runner: removed from the VM only, GitHub no longer listed it (${R_URL})"
      else
        rep "runner: deregistered from ${R_URL}"
      fi
    else
      rep "runner: not registered"
    fi
    if [ "$RESET_KEEP_VM" = 1 ]; then
      rep "VM ${INSTANCE}: kept (--keep-vm)"
      RESET_VM_KEPT=1
    elif delete_vm; then
      rep "VM ${INSTANCE}: deleted"
      # The reset base goes with the VM (see delete_reset_base): with the
      # runner VM gone nothing clones from it. A base that cannot be deleted
      # fails the reset's cleanup, like a VM that cannot be deleted.
      reset_base_cleanup
    else
      rep "VM ${INSTANCE}: could not be deleted (limactl said why above); delete it by hand: limactl delete --force ${INSTANCE}"
      RESET_RC=1
      # The VM is still there: the token guard's record has to survive (see
      # reset_state_file).
      RESET_VM_KEPT=1
    fi
  elif [ "$RESET_KEEP_VM" = 0 ]; then
    # No runner VM, but a marked base can still be there: a previous reset's
    # base delete failed (its report named the hand command), or a re-register
    # clone failed after deleting the VM. The base is what a retry cleans —
    # and a reset --remove-tool must not report success around it.
    reset_base_cleanup
  fi
}

# reset_state_file: removes the state file, keeping it when the group record
# it carries is still live (RG_KEEP, from reset_group), and keeping the token
# guard's ever_registered record when the VM was retained (RESET_VM_KEPT: a
# --keep-vm, or a delete that failed) — a VM that has been registered may
# have run jobs, and dropping the record would let a later install put a
# registration token into it if a job deleted its _work marker. The record
# is rewritten into the file (state_set keeps the other keys); a file with
# nothing left to say is removed as before. Sets RESET_RC 1 when a removal
# or rewrite fails.
reset_state_file() {
  local f
  f="$(state_file)"
  if [ -e "$f" ]; then
    if [ "$RG_KEEP" = 1 ]; then
      rep "state file $f: kept, it still records the group"
    elif [ "$RESET_VM_KEPT" = 1 ] && [ "$(state_get ever_registered)" = "1" ]; then
      if state_set ever_registered 1; then
        rep "state file $f: ever_registered kept, the VM was retained (it may have run jobs; reset without --keep-vm, or delete the VM by hand, to clear it)"
      else
        rep "state file $f: could not rewrite it to keep ever_registered; remove it by hand once the VM is gone"
        RESET_RC=1
      fi
    elif rm -f "$f"; then
      rep "state file $f: removed"
    else
      rep "state file $f: could not be removed"
      RESET_RC=1
    fi
  fi
}

# reset_tool: the tool removal, last and only when the rest went well
# (RESET_RC 0): the tool is how the rest is run again. After this nothing
# reads from it, and the script exits. Removes the wrappers and the directory
# --remove-tool found (RESET_WRAPPERS, RESET_TOOL_DIR); sets RESET_RC 1 when
# a removal fails.
reset_tool() {
  local line
  if [ "$RESET_REMOVE_TOOL" = 1 ]; then
    if [ "$RESET_RC" != 0 ]; then
      rep "tool: kept, a step above failed; run reset --remove-tool again after fixing it"
    else
      if [ -z "$RESET_WRAPPERS" ]; then
        rep "command: no homefield wrapper of this install found in $(tool_bin_dirs | tr '\n' ' ')(HOMEFIELD_BIN_DIR names another place)"
      else
        while IFS= read -r line; do
          if rm -f -- "$line"; then rep "command ${line}: removed"; else rep "command ${line}: could not be removed"; RESET_RC=1; fi
        done <<<"$RESET_WRAPPERS"
      fi
      if [ -n "$RESET_TOOL_DIR" ]; then
        if rm -rf -- "$RESET_TOOL_DIR"; then rep "tool ${RESET_TOOL_DIR}: removed"; else rep "tool ${RESET_TOOL_DIR}: could not be removed"; RESET_RC=1; fi
      else
        rep "tool: $(tool_install_dir) was not put there by install.sh (no .homefield-ref), left alone"
      fi
    fi
  fi
}

cmd_reset() {
  reset_options "$@"
  refuse_unnamed_vm reset
  check_host
  local vm line
  # Not vm_lookup: a VM Lima cannot describe is the usual half-built one, and
  # the way out has to be named.
  VM_STATUS="$(vm_status)" || die "could not ask Lima about VM ${INSTANCE} (limactl list failed, or lists it without a status), so reset cannot tell what is there. If its runner registered, remove that on GitHub's runners page first; then delete the VM by hand: limactl delete --force ${INSTANCE}"
  vm="$VM_STATUS"
  R_REG=0
  R_ON=2
  reset_load_group
  # A running VM can be asked now; a stopped one is started only after the
  # answer, which makes the plan say so. asked_early: the answer is from before
  # the confirmation, so it is checked again after it.
  RESET_ASKED_EARLY=0
  if [ "$vm" = Running ]; then
    RESET_ASKED_EARLY=1
    reset_inspect
  fi
  reset_plan "$vm"

  REPORT=()
  RESET_RC=0
  RG_KEEP=0
  RESET_VM_KEPT=0
  reset_vm "$vm"
  if [ -n "$RG_ORG" ]; then
    reset_group "$RESET_KEEP_GROUP" "$R_ID"
  elif [ "$RG_BAD" = 1 ]; then
    rep "runner group: the group_created record in $(state_file) does not parse, so no group was touched"
    RG_KEEP=1
  fi
  reset_state_file
  # The sleep/wake agent is per-Mac: with this VM's state gone (or kept, when
  # a group record in it is still live), take the agent out when no remaining
  # VM wants it.
  if ! route_watcher_remove_if_unneeded; then
    rep "route watcher: could not remove the LaunchAgent $(route_watcher_plist_path); remove it by hand"
    RESET_RC=1
  fi
  reset_tool

  if [ "${#REPORT[@]}" -eq 0 ]; then
    log "nothing to reset for ${INSTANCE}: no VM and no runner group it created"
  else
    echo "Reset of ${INSTANCE}:"
    for line in "${REPORT[@]}"; do echo "  - ${line}"; done
  fi
  if [ "$RESET_REMOVE_TOOL" = 1 ]; then exit "$RESET_RC"; fi
  return "$RESET_RC"
}
