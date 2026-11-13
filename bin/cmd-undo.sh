#!/usr/bin/env bash
# uninstall and reset: taking the runner, the VM and the tool back down.

# deregister_script: what uninstall runs in the guest, as root, with the remove
# token on its stdin. config.sh refuses to remove a runner whose service is
# installed, so the service goes first, and if anything after that fails (svc.sh
# uninstall partway through, or GitHub refusing the removal: a rejected token,
# a network failure) the runner is still registered and has to get its service
# back. provision.sh's ensure-service does that and starts it (#99): this
# release's copy, put in the guest by cmd_uninstall, so a VM provisioned by an
# older one gets it too. If that fails as well, the runner is registered with
# no service, and `homefield install` sets the service up again.
#
# deregister_script local: for a runner GitHub no longer has (#76), removes
# only the VM's copy of the registration (`config.sh remove --local`, which
# asks GitHub nothing), with an empty line for the token.
deregister_script() {
  # shellcheck disable=SC2016  # the guest's shell expands these, not this one
  local script='cd @HOME@ && read -r t && s=0 && { [ ! -f .service ] || s=1; } && { [ "$s" = 0 ] || ./svc.sh uninstall || { rc=$?; bash @PROVISION@ ensure-service --start; exit "$rc"; }; } && { ACTIONS_RUNNER_INPUT_TOKEN="$t" sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u runner ./config.sh remove@LOCAL@ || { rc=$?; [ "$s" = 0 ] || bash @PROVISION@ ensure-service --start; exit "$rc"; }; }'
  local provision="$1" flag=""
  [ "${2:-}" != local ] || flag=" --local"
  script="${script//@HOME@/$RUNNER_HOME}"
  script="${script//@LOCAL@/$flag}"
  printf '%s' "${script//@PROVISION@/$provision}"
}

# deregister_runner <url> <id> <on>: deregisters a runner its caller has
# already taken out of service; <on> is runner_on_github's answer for it (1:
# GitHub no longer has it, so only the VM's copy of the registration goes).
# Shared by uninstall and reset. The caller has checked that no job is
# running and called stop_runner, which arms restart_runner_on_failure. A
# failure ends the command (die, or `set -e`) after that trap has given the
# runner its service back, so call it as a plain command, never from a
# condition: errexit is off in there and the failure would pass for success.
deregister_runner() {
  local url="$1" id="$2" on="$3" token stage
  echo "homefield: switch every repository that routes to this runner to hosted first:" >&2
  echo "homefield:   gh variable set CI_RUNNER --repo <owner>/<repo> --body hosted" >&2
  # The restore deregister_script falls back on, staged in a private
  # directory before the token is fetched (#185). RS_STAGE is cleaned up by
  # restart_runner_on_failure (the EXIT trap stop_runner set in the caller)
  # when a failure ends the command mid-flow, and explicitly after runner_back.
  stage="$(guest_stage_dir)"
  RS_STAGE="$stage"
  # shellcheck disable=SC2153  # PROVISION is bin/homefield's, this file is sourced
  limactl copy "$PROVISION" "${INSTANCE}:${stage}/provision.sh" ||
    { guest_unstage "$stage"; RS_STAGE=""; die "could not copy provision.sh into VM ${INSTANCE}; nothing was deregistered"; }
  # The runner is already offline (the caller stopped it right after the idle
  # check), so the token is fetched without a job being able to start.
  if [ "$on" = 1 ]; then
    # A full removal would ask GitHub to delete a runner it does not have.
    log "GitHub no longer has this runner (id ${id}) at ${url}; removing its registration from the VM only"
    printf '\n' | guest_stdin sudo sh -c "$(deregister_script "${stage}/provision.sh" local)"
  else
    token="$(get_token remove "$url")"
    log "deregistering from ${url}"
    printf '%s\n' "$token" | guest_stdin sudo sh -c "$(deregister_script "${stage}/provision.sh")"
    token=""
  fi
  runner_back
  guest_unstage "$stage"
  # shellcheck disable=SC2034  # read by lib/vm.sh's run_provision
  RS_STAGE=""
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
# and id (empty when install could not read it from GitHub's answer), and
# RG_BAD 1 for a record that does not parse.
RG_ORG=""
RG_NAME=""
RG_ID=""
RG_BAD=0
RG_LABEL=""
RG_PAGE=""

reset_load_group() {
  local raw re='^([A-Za-z0-9_.-]+)/(.+)/([0-9]*)$'
  RG_ORG=""
  RG_NAME=""
  RG_ID=""
  RG_BAD=0
  raw="$(state_get group_created)"
  [ -n "$raw" ] || return 0
  if [[ "$raw" =~ $re ]]; then
    RG_ORG="${BASH_REMATCH[1]}"
    RG_NAME="${BASH_REMATCH[2]}"
    RG_ID="${BASH_REMATCH[3]}"
    RG_LABEL="${RG_ORG}/${RG_NAME}"
    RG_PAGE="https://github.com/organizations/${RG_ORG}/settings/actions/runner-groups"
  else
    RG_BAD=1
  fi
}

# What reset did, one line each, printed at the end. RESET_RC is the exit
# status (1 once a requested step failed); RG_KEEP 1 keeps the state file,
# because a group it records still exists.
REPORT=()
RESET_RC=0
RG_KEEP=0

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
  local keep="$1" own="$2" rows="" ids="" name vis pub id rid found_id="" found_name="" others=0 out
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
  if ! rows="$(list_groups_ids "$RG_ORG")"; then
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
  if ! ids="$(group_runner_ids "$RG_ORG" "$found_id")"; then
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
  if out="$(gh api -X DELETE "orgs/${RG_ORG}/actions/runner-groups/${found_id}" </dev/null 2>&1)"; then
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
    elif delete_vm; then
      rep "VM ${INSTANCE}: deleted"
    else
      rep "VM ${INSTANCE}: could not be deleted (limactl said why above); delete it by hand: limactl delete --force ${INSTANCE}"
      RESET_RC=1
    fi
  fi
}

# reset_state_file: removes the state file, keeping it when the group record
# it carries is still live (RG_KEEP, from reset_group). Sets RESET_RC 1 when
# the removal fails.
reset_state_file() {
  if [ -e "$(state_file)" ]; then
    if [ "$RG_KEEP" = 1 ]; then
      rep "state file $(state_file): kept, it still records the group"
    elif rm -f "$(state_file)"; then
      rep "state file $(state_file): removed"
    else
      rep "state file $(state_file): could not be removed"
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
  reset_vm "$vm"
  if [ -n "$RG_ORG" ]; then
    reset_group "$RESET_KEEP_GROUP" "$R_ID"
  elif [ "$RG_BAD" = 1 ]; then
    rep "runner group: the group_created record in $(state_file) does not parse, so no group was touched"
    RG_KEEP=1
  fi
  reset_state_file
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
