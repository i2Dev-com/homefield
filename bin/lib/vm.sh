#!/usr/bin/env bash
# The VM: Lima queries, the guest shell, isolation, the loopback probe,
# the runner's service and settings as seen from the guest.

# ── Host and VM ─────────────────────────────────────────────────────────────
check_host() {
  [ "$(uname -s)" = "Darwin" ] || die "needs macOS (Lima with Apple's Virtualization.framework)"
  [ "$(uname -m)" = "arm64" ] || die "needs an Apple Silicon Mac: the VM is arm64"
  command -v limactl >/dev/null || die "needs Lima >= 2.0: brew install lima"
  local version major minor
  version="$(limactl --version | awk '{print $NF}')"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  # 2.0 is the first release documented to accept the `template:` locator in
  # vm/lima.yaml; it deprecated `template://` (Lima 2.0.0 release notes).
  if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || [ "$major" -lt 2 ]; then
    die "needs Lima >= 2.0, found ${version}"
  fi
}

check_instance() {
  local re='^[A-Za-z0-9]+([._-][A-Za-z0-9]+)*$'
  [[ "$INSTANCE" =~ $re && ${#INSTANCE} -le 76 && ! "$INSTANCE" =~ [.][Yy][Aa]?[Mm][Ll]$ ]] ||
    die "--instance (or HOMEFIELD_INSTANCE) must be a Lima instance name: letters and digits, with a single '.', '_' or '-' between them, at most 76 characters, not ending in .yml or .yaml; got: $INSTANCE"
}

# vm_status: prints the VM's status (Running, Stopped, ...), or nothing when
# there is no such VM. Returns 2 when Lima could not be asked, or lists the VM
# without a status. It lists every instance and picks its own: `limactl list
# NAME` exits 1 for a missing VM ("unmatched instances", Lima 2.2.0) as it
# does when Lima itself fails, so only a successful list can say "no VM".
vm_status() {
  local rows name status
  rows="$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null)" || return 2
  while read -r name status; do
    if [ "$name" = "$INSTANCE" ]; then
      # Listed with no status: its config is broken (Lima warns and lists it
      # with an empty status). It exists, so it is not "no VM".
      [ -n "$status" ] || return 2
      echo "$status"
      return 0
    fi
  done <<<"$rows"
  return 0
}

# is_homefield_vm <name>: whether that instance's stored config carries it.
is_homefield_vm() {
  local f="${LIMA_HOME:-$HOME/.lima}/$1/lima.yaml" first=""
  [ -f "$f" ] || return 1
  IFS= read -r first <"$f" || true
  [ "$first" = "$HF_VM_MARKER" ]
}

# vm_instances: every HomeField VM on this Mac, one name per line, in Lima's
# order. The default instance counts even without the marker (a config edited by
# hand), because install creates it under that name. Returns 1 when Lima is not
# installed or cannot list; a command then falls back to its single-instance path.
vm_instances() {
  local rows name status found=""
  command -v limactl >/dev/null || return 1
  rows="$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null)" || return 1
  while read -r name status; do
    [ -n "$name" ] || continue
    if is_homefield_vm "$name" || [ "$name" = "$DEFAULT_INSTANCE" ]; then
      found="${found}${name}"$'\n'
    fi
  done <<<"$rows"
  printf '%s' "$found"
}

instance_command() {
  local name="$1"; shift
  # The shell running this script, so a PATH without bash (a test's stub-only
  # one) still works: the shebang would need /usr/bin/env to find it.
  "${BASH:-bash}" "$HF_SELF" ${COLOR_ARG:+"$COLOR_ARG"} --instance "$name" "$@" </dev/null
}

# vm_dispatch <command> <function> [args...]: the single-instance implementation
# for one VM. With --instance (or HOMEFIELD_INSTANCE) that is INSTANCE; by
# default it covers every HomeField VM on this Mac, each as its own process,
# continuing after a failure and returning 0 only when every run did. No VMs at
# all, or a Lima that cannot be asked, falls back to the single-instance path
# for INSTANCE (the default name), whose messages then stand.
vm_dispatch() {
  local cmd="$1" fn="$2"; shift 2
  if [ "$EXPLICIT_INSTANCE" = 1 ]; then
    "$fn" "$@"
    return
  fi
  local list="" name n=0 first=1 rc=0
  if ! list="$(vm_instances)"; then
    "$fn" "$@"
    return
  fi
  while IFS= read -r name; do
    [ -z "$name" ] || n=$((n + 1))
  done <<<"$list"
  case "$n" in
    0)
      # Nothing found: INSTANCE's own report ("not created", or the command's
      # refusal) says what to do, as it did before this default.
      "$fn" "$@"
      return
      ;;
    1)
      while IFS= read -r name; do [ -z "$name" ] || break; done <<<"$list"
      INSTANCE="$name"
      "$fn" "$@"
      return
      ;;
  esac
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$first" = 1 ] || echo ""
    first=0
    # The child's own lines mostly start with its VM's name (status, start,
    # stop); memory's table does not, so it heads the block when told.
    HOMEFIELD_ONE_OF_MANY=1 instance_command "$name" "$cmd" "$@" || rc=1
  done <<<"$list"
  return "$rc"
}

# refuse_unnamed_vm <command>: destructive commands never act on a VM the user
# did not name when this Mac has another one, or when its only HomeField VM is
# not the default instance. They list what is there and stop instead (#182).
refuse_unnamed_vm() {
  [ "$EXPLICIT_INSTANCE" = 0 ] || return 0
  local cmd="$1" list="" names="" name n=0 only=""
  if ! list="$(vm_instances)"; then return 0; fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    only="$name"
    names="${names:+${names}, }${name}"
  done <<<"$list"
  case "$n" in
    0) return 0 ;;
    1) [ "$only" = "$INSTANCE" ] && return 0 ;;
  esac
  die "${cmd}: this Mac has HomeField VMs (${names}); name the one to act on with --instance <name>"
}

vm_lookup() {
  VM_STATUS="$(vm_status)" || die "could not ask Lima about VM ${INSTANCE} (limactl list failed, or lists it without a status); stopping here"
}

ensure_vm() {
  local cpus="$1" memory="$2" status
  vm_lookup
  status="$VM_STATUS"
  if [ -z "$status" ]; then
    log "creating VM ${INSTANCE}"
    local args=(--name="$INSTANCE" --mount-none --tty=false)
    [ -n "$cpus" ] && args+=(--cpus="$cpus")
    [ -n "$memory" ] && args+=(--memory="$memory")
    limactl create "${args[@]}" "$LIMA_YAML"
    status="Stopped"
  fi
  if [ "$status" != "Running" ]; then
    log "starting VM ${INSTANCE}"
    limactl start --tty=false "$INSTANCE"
  fi
}

isolation_fail() {
  ISOLATION_WHY="$2"
  ISOLATION_SUFFIX="$3"
  return "$1"
}

isolation_probe() {
  local mounts users=0
  ISOLATION_WHY=""
  ISOLATION_SUFFIX=""
  # mount is run on its own: in a pipe its failure would be hidden, and grep
  # would count nothing in its empty output. grep -c exits 1 for a count of 0,
  # which is an answer; a status above 1 is not.
  # shellcheck disable=SC2016  # the guest's shell expands these, not this one
  if ! mounts="$(guest sh -c 'out="$(mount)" || exit 3; printf "%s\n" "$out" | grep -Ec "virtiofs|9p|sshfs|reverse-sshfs"; test $? -le 1')"; then
    isolation_fail 2 "could not run the isolation check in VM ${INSTANCE}" "; is it running? (see docs/runbook.md, Setup)" || return
  fi
  case "$mounts" in
    ''|*[!0-9]*) isolation_fail 2 "could not read the mount count from VM ${INSTANCE}" "; refusing to continue (see docs/runbook.md, Setup)" || return ;;
  esac
  [ "$mounts" = "0" ] || { isolation_fail 1 "VM ${INSTANCE} has host mounts" "; refusing to continue (see docs/runbook.md, Setup)" || return; }
  guest_sees /Users || users=$?
  case "$users" in
    0) isolation_fail 1 "VM ${INSTANCE} can see /Users" "; refusing to continue" || return ;;
    1) ;;
    *) isolation_fail 2 "could not run the /Users check in VM ${INSTANCE}" "; refusing to continue (see docs/runbook.md, Setup)" || return ;;
  esac
  return 0
}

verify_isolation() {
  local rc=0
  isolation_probe || rc=$?
  [ "$rc" -eq 0 ] || die "${ISOLATION_WHY}${ISOLATION_SUFFIX}"
  log "isolation verified: no host mounts"
  verify_loopback
}

# lima_at_least MAJOR MINOR: is the installed limactl at least that release?
# The same version parsing as check_host's; an unreadable version answers no.
lima_at_least() {
  local version major minor
  version="$(limactl --version 2>/dev/null | awk '{print $NF}')"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  if [ "$major" -gt "$1" ]; then return 0; fi
  [ "$major" -eq "$1" ] && [ "$minor" -ge "$2" ]
}

# verify_loopback: the #18 probe. vm/lima.yaml asks Lima to stop mapping the
# host's loopback to host.lima.internal (networkOpts.hostLoopback: false);
# Lima >= 2.3.0 (lima-vm/lima#5581) honours that, Lima 2.0-2.2 warn about the
# unknown field and ignore it. The isolation claim is tested, not inferred: a
# throwaway listener on the Mac's 127.0.0.1 answers whether the guest can
# really reach it, and open, closed and unknown stay three different answers
# (an unknown is never read as closed).
#   closed  - logged; loopback-only services are out of PR code's reach.
#   open    - fatal only when the VM's own config asks for the block AND the
#             Lima is new enough to honour it: the boundary is claimed but
#             broken. Otherwise a warning naming the way to close it, because
#             this is the documented state until Lima 2.3.0 is released.
#   unknown - a warning that nothing was proven; the run goes on.
verify_loopback() {
  local port listener answer config asks_closed i got token tokenfile ok
  if ! command -v nc >/dev/null 2>&1; then
    echo "homefield: warning: #18 probe skipped (no nc on PATH); assume the guest can still reach the Mac's loopback (docs/runbook.md, Host loopback exposure)" >&2
    return 0
  fi
  port=$((20000 + RANDOM % 20000))
  # What answers on the port must be provably this probe's listener: nc
  # serves this token from its stdin, and a local connect that reads it
  # back found our nc rather than some service that already held the port
  # (whose answer would say nothing about the guest). HOMEFIELD_PROBE_TOKEN
  # lets the test suite know the token in advance.
  token="${HOMEFIELD_PROBE_TOKEN:-homefield-probe-$$-$port}"
  tokenfile="$(mktemp)" || tokenfile=""
  if [ -z "$tokenfile" ]; then
    echo "homefield: warning: #18 probe skipped (no temp file for the port token); assume the guest can still reach the Mac's loopback (docs/runbook.md, Host loopback exposure)" >&2
    return 0
  fi
  printf '%s' "$token" >"$tokenfile"
  # stderr goes to a file, not to /dev/null: it is how the listener reports
  # that it never bound the port (a foreign service holds it), which is a
  # different story from a listener that bound and then died.
  errfile="$(mktemp)" || errfile=""
  if [ -z "$errfile" ]; then
    rm -f "$tokenfile"
    echo "homefield: warning: #18 probe skipped (no temp file for the listener's report); assume the guest can still reach the Mac's loopback (docs/runbook.md, Host loopback exposure)" >&2
    return 0
  fi
  nc -k -l 127.0.0.1 "$port" <"$tokenfile" >"$errfile" 2>&1 &
  listener=$!
  # A Ctrl-C (or a TERM) during the ~5 s probe would orphan the listener:
  # the handler kills it and the probe dies with the signal. Cleared on
  # every path below that gets here on its own.
  trap 'kill "$listener" 2>/dev/null; exit 130' INT TERM
  # The guest's answer means nothing until the token comes back locally:
  # the bind is asynchronous (retry a moment), and an answer that is not the
  # token is some service that already held the port — attribution is lost
  # and the probe skips rather than misread.
  got=""
  i=0
  while [ "$i" -lt 6 ]; do
    got="$(nc -w 2 127.0.0.1 "$port" 2>/dev/null || true)"
    [ "$got" = "$token" ] && break
    i=$((i + 1))
    sleep 0.5
  done
  if [ "$got" != "$token" ]; then
    trap - INT TERM
    kill "$listener" 2>/dev/null || true
    wait "$listener" 2>/dev/null || true
    # The wait reaps the listener, so what it left behind is final: its
    # stderr naming a taken port is the surest sign the bind was lost — a
    # liveness check cannot see this before the reap (an exited child is
    # still kill -0-able as a zombie), and that is why no check lives in
    # the loop above.
    bind_lost=0
    if [ -s "$errfile" ] && grep -qi "Address already in use" "$errfile"; then bind_lost=1; fi
    rm -f "$tokenfile" "$errfile"
    if [ -n "$got" ]; then
      echo "homefield: warning: #18 probe skipped (127.0.0.1:${port} answered, but not with the token: another service holds the port); assume the guest can still reach the Mac's loopback (docs/runbook.md, Host loopback exposure)" >&2
    elif [ "$bind_lost" = 1 ]; then
      echo "homefield: warning: #18 probe skipped (127.0.0.1:${port} was already taken: the probe's listener could not bind it); assume the guest can still reach the Mac's loopback (docs/runbook.md, Host loopback exposure)" >&2
    else
      echo "homefield: warning: #18 probe skipped (nothing answered on 127.0.0.1:${port}; is the port in use?); assume the guest can still reach the Mac's loopback (docs/runbook.md, Host loopback exposure)" >&2
    fi
    return 0
  fi
  rm -f "$errfile"
  # Still accepting after serving the token: an nc without -k dies with the
  # connection it served, and its dead port would read as a false closed
  # from the guest. A second local connect is the real test — liveness
  # checks on processes would read a killed-but-unreaped one as alive. The
  # token is gone from nc's stdin by now (one-shot file), so this connect
  # only needs to succeed: the token above already proved the port is ours.
  i=0 ok=0
  while [ "$i" -lt 3 ]; do
    if nc -w 2 127.0.0.1 "$port" >/dev/null 2>&1; then ok=1; break; fi
    i=$((i + 1))
    sleep 0.2
  done
  if [ "$ok" != 1 ]; then
    trap - INT TERM
    kill "$listener" 2>/dev/null || true
    wait "$listener" 2>/dev/null || true
    rm -f "$tokenfile"
    echo "homefield: warning: #18 probe skipped (the nc listener died after one connection; does it support -k?); assume the guest can still reach the Mac's loopback (docs/runbook.md, Host loopback exposure)" >&2
    return 0
  fi
  # The guest's side: a TCP connect to the same port. bash's /dev/tcp exits
  # 1 for a refused connect AND for a name that did not resolve, so status
  # alone is not a boundary: only bash's own "Connection refused" message
  # closes. The words are open, closed-1 (refused), closed-124 (the 3 s
  # connect timeout), tools (a guest without timeout/bash/grep cannot be
  # asked) and unknown-<status> (unresolved name, no route, anything
  # else); an empty answer is the limactl call having failed.
  # shellcheck disable=SC2016  # the guest's shell expands these, not this one
  answer="$(guest sh -c 'if ! command -v timeout >/dev/null 2>&1 || ! command -v bash >/dev/null 2>&1 || ! command -v grep >/dev/null 2>&1; then echo tools; else out=$(timeout 3 bash -c "exec 3<>/dev/tcp/host.lima.internal/$1" 2>&1); rc=$?; if [ "$rc" = 0 ]; then echo open; elif [ "$rc" = 124 ]; then echo closed-124; elif [ "$rc" = 1 ] && printf %s "$out" | grep -q "Connection refused"; then echo closed-1; else echo "unknown-$rc"; fi; fi' sh "$port")" || answer=""
  kill "$listener" 2>/dev/null || true
  wait "$listener" 2>/dev/null || true
  rm -f "$tokenfile"
  trap - INT TERM
  case "$answer" in
    open)
      # Was this VM asked to block the loopback? Its own stored config says
      # (the file limactl create wrote; a custom LIMA_HOME is honoured). A
      # config that cannot be read is not evidence of a block, so it takes
      # the warning path, never the fatal one.
      config="${LIMA_HOME:-$HOME/.lima}/${INSTANCE}/lima.yaml"
      asks_closed=0
      [ -f "$config" ] && grep -Eq '^[[:space:]]*hostLoopback:[[:space:]]*false' "$config" && asks_closed=1
      if [ "$asks_closed" = 1 ] && lima_at_least 2 3; then
        # The gate is the limactl binary; a VM still running from before a
        # Lima upgrade keeps its old gateway, so the message makes the first
        # step a restart, and only what survives a restart is a broken
        # boundary.
        die "VM ${INSTANCE} reaches the Mac's loopback through host.lima.internal although its config sets networkOpts.hostLoopback: false. If the VM has been running since before Lima was upgraded, its gateway is the old one: stop it, start it, and run this again (the mapping is applied at VM start). If it still reaches the loopback after that the boundary is broken — nothing was registered, but a fresh install leaves the VM (and possibly the runner group) behind: docs/runbook.md, Host loopback exposure"
      fi
      if lima_at_least 2 3; then
        echo "homefield: warning: #18: jobs in VM ${INSTANCE} can reach the Mac's loopback; its stored config does not show networkOpts.hostLoopback: false (absent, or unreadable): recreate the VM, or stop it and add the setting with limactl edit (docs/runbook.md, Host loopback exposure)" >&2
      else
        echo "homefield: warning: #18: jobs in VM ${INSTANCE} can reach the Mac's loopback; Lima $(limactl --version 2>/dev/null | awk '{print $NF}') ignores networkOpts.hostLoopback — it closes for VMs created on Lima >= 2.3.0 (docs/runbook.md, Host loopback exposure)" >&2
      fi
      ;;
    closed-1|closed-124)
      log "loopback probe: closed (the guest cannot reach the Mac's 127.0.0.1)"
      ;;
    *)
      echo "homefield: warning: #18 probe got no clear answer from VM ${INSTANCE} (answer: ${answer:-none}); assume it can reach the Mac's loopback (docs/runbook.md, Host loopback exposure)" >&2
      ;;
  esac
  return 0
}

# guest_sees PATH: like guest_has_file for any kind of path, without sudo:
# 0 if the guest can see it, 1 if not, 2 if the guest could not be asked.
guest_sees() {
  local answer
  # shellcheck disable=SC2016  # the guest's shell expands $1, not this one
  answer="$(guest sh -c 'if test -e "$1"; then echo yes; else echo no; fi' sh "$1")" || return 2
  case "$answer" in
    yes) return 0 ;;
    no) return 1 ;;
    *) return 2 ;;
  esac
}

# guest_has_file PATH: 0 if the file is there, 1 if the guest says it is not,
# 2 if the guest could not be asked (limactl or sudo failed, or the answer was
# neither). The test runs in the guest and prints its answer, so a failed call
# cannot pass for "no": `test -f` alone exits 1 for a missing file and for a
# `limactl shell` that never reached the guest. A caller that acts on "no"
# has to stop on 2.
guest_has_file() {
  local answer
  # shellcheck disable=SC2016  # the guest's shell expands $1, not this one
  answer="$(guest sudo sh -c 'if test -f "$1"; then echo yes; else echo no; fi' sh "$1")" || return 2
  case "$answer" in
    yes) return 0 ;;
    no) return 1 ;;
    *) return 2 ;;
  esac
}

# is_registered: registered, for the commands that act on "no". A VM that could
# not be asked ends the command: read as "not registered", it would let
# uninstall delete the VM and leave the registration on GitHub, and let install
# register again, where --replace removes this VM's own registration.
is_registered() {
  local rc=0
  registered || rc=$?
  [ "$rc" -lt 2 ] || die "could not ask VM ${INSTANCE} whether its runner is registered; is it running? Try again when bin/homefield status answers"
  return "$rc"
}

# removed_recovery <url> <name>: how to register a runner GitHub removed again,
# under its old name. The label and group are not stored in the VM.
removed_recovery() {
  echo "bin/homefield uninstall --instance ${INSTANCE} --keep-vm, then bin/homefield install --instance ${INSTANCE} --url $1${2:+ --name $2}, with the --label and --group of the first install if they were not the defaults"
}

# job_running: 0 if a job is running, 1 if not, 2 if the guest could not be
# asked (the call failed, or pgrep did not run). `pgrep` alone exits 1 for "no
# job" and for a `limactl shell` that never reached the guest. The [R] keeps
# the pattern from matching this shell's own command line.
job_running() {
  local answer
  # shellcheck disable=SC2016  # the guest's shell expands these, not this one
  answer="$(guest sh -c 'pgrep -f "[R]unner.Worker" >/dev/null; case $? in 0) echo yes ;; 1) echo no ;; esac')" || return 2
  case "$answer" in
    yes) return 0 ;;
    no) return 1 ;;
    *) return 2 ;;
  esac
}

# is_job_running: job_running, for the commands that go on when it says "no".
# A guest that could not be asked ends the command, with --force too: --force
# overrides a job that is running, not a runner that cannot be reached.
is_job_running() {
  local rc=0
  job_running || rc=$?
  [ "$rc" -lt 2 ] || die "could not ask VM ${INSTANCE} whether a job is running; nothing was stopped. Try again when bin/homefield status answers"
  return "$rc"
}

# npm_state: whether the runner's bundled npm runs (#110), as with
# job_running: 0 ok, 1 broken, 2 the VM could not be asked. Verify only: the
# repair belongs to the job-started hook (vm/provision.sh), which relinks the
# externals symlinks a runner self-update flattens (actions/runner#2094)
# before every job. `cd /` keeps a project .npmrc out of the check.
npm_state() {
  local answer
  # shellcheck disable=SC2016  # the guest's shell expands these, not this one
  answer="$(guest sh -c 'for n in node20 node24; do d="/opt/actions-runner/externals/$n/bin"; [ -e "$d/npm" ] || continue; (cd / && "$d/node" "$d/npm" --version >/dev/null 2>&1) || { echo broken; exit 0; }; done; echo ok')" || return 2
  case "$answer" in
    ok) return 0 ;;
    broken) return 1 ;;
    *) return 2 ;;
  esac
}

# Maintenance (upgrade, uninstall) takes the runner offline first, straight
# after the idle check: a runner that is still listening can be handed a job
# at any moment, and apt restarting Docker or the service being uninstalled
# would then take that job down. If the command then fails, the runner is
# started again on the way out; a command that succeeds calls runner_back.
stopped_unit=""

stop_runner() {
  # No .service is a state of its own (provisioning never finished, or the
  # service was removed): nothing to stop. A guest that cannot be asked is not
  # that state, or the maintenance would go on with the runner listening.
  local has=0 unit
  guest_has_file "$RUNNER_HOME/.service" || has=$?
  case "$has" in
    0) ;;
    1) return 0 ;;
    *) die "could not ask VM ${INSTANCE} whether the runner has a service; nothing was stopped. Try again when bin/homefield status answers" ;;
  esac
  if ! unit="$(guest sudo cat "$RUNNER_HOME/.service")"; then
    die "could not read the runner's service name in VM ${INSTANCE}; nothing was stopped. Try again when bin/homefield status answers"
  fi
  # A file the guest answered for, with no name in it: no unit to stop.
  [ -n "$unit" ] || return 0
  # A name whose unit file is gone (an uninstall cut off before it deleted
  # .service) names nothing that runs. systemctl stop would fail with "not
  # loaded" and end the command before provisioning could repair it (#99).
  local load
  if ! load="$(guest systemctl show -p LoadState --value "$unit")"; then
    die "could not ask VM ${INSTANCE} whether ${unit} is installed; nothing was stopped. Try again when bin/homefield status answers"
  fi
  if [ "$load" = not-found ]; then
    log "${unit} is not installed; nothing to stop"
    return 0
  fi
  stopped_unit="$unit"
  trap restart_runner_on_failure EXIT
  log "stopping ${stopped_unit}: the runner takes no jobs until this finishes"
  guest sudo systemctl stop "$stopped_unit"
}

restart_runner_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$stopped_unit" ]; then
    echo "homefield: failed; starting ${stopped_unit} again" >&2
    guest sudo systemctl start "$stopped_unit" ||
      echo "homefield: could not start ${stopped_unit}; check bin/homefield status" >&2
  fi
  # deregister_runner's staging directory (#185): a failure past the copy
  # exits through this trap, so the cleanup rides on it. Empty for every
  # other caller.
  if [ -n "${RS_STAGE:-}" ]; then
    guest_unstage "$RS_STAGE"
    RS_STAGE=""
  fi
}

runner_back() {
  trap - EXIT
  stopped_unit=""
}

# Prints the named settings from the runner's config, one per line (empty for
# one that is missing): a name may contain spaces.
runner_setting() {
  guest sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8-sig")); print(*(d.get(k, "") for k in sys.argv[2:]), sep="\n")' \
    "$RUNNER_HOME/.runner" "$@"
}

# What status and diagnose both say about a registered runner, from the VM.
# load_runner_settings: the runner's name, URL and id into RS_NAME / RS_URL /
# RS_ID (each empty when the settings could not be read). RS_STAGE is the
# staging directory deregister_runner creates and restart_runner_on_failure
# cleans up when a failure ends the command through its EXIT trap.
RS_NAME=""
RS_URL=""
RS_ID=""
RS_STAGE=""

load_runner_settings() {
  RS_NAME=""
  RS_URL=""
  RS_ID=""
  # A read at end of input fails, and under `set -e` that ends the command:
  # fewer than three lines must reach the caller's check, not stop here.
  # shellcheck disable=SC2034  # read by cmd-install.sh's setup lines
  { read -r RS_NAME || true; read -r RS_URL || true; read -r RS_ID || true; } < <(runner_setting agentName gitHubUrl agentId)
}

# runner_service_state: 0 if the runner's service is running, 1 if not (or none
# is installed). SERVICE_UNIT is its name, empty when there is none.
SERVICE_UNIT=""

runner_service_state() {
  SERVICE_UNIT="$(guest sudo cat "$RUNNER_HOME/.service" 2>/dev/null)" || SERVICE_UNIT=""
  [ -n "$SERVICE_UNIT" ] && guest systemctl is-active --quiet "$SERVICE_UNIT"
}

# ── Provisioning ────────────────────────────────────────────────────────────
# guest_stage_dir: a per-run private directory in the guest, 0700 and owned by
# the login user: the runner user cannot read what is staged in it, and the
# name is not guessable. Files the guest later runs as root (provision.sh, the
# preset hooks) are staged through it, never at a fixed /tmp path a live job
# could have pre-planted (#185). HOMEFIELD_STAGE_DIR pins the directory (the
# suites drive it: they pre-build what the copy would place there). 
# guest_unstage removes one; a leftover after a killed run is harmless (0700,
# its name dies with the run).
guest_stage_dir() {
  if [ -n "${HOMEFIELD_STAGE_DIR:-}" ]; then
    printf '%s' "$HOMEFIELD_STAGE_DIR"
    return 0
  fi
  local dir
  dir="$(guest mktemp -d /tmp/homefield-stage-XXXXXXXX)" ||
    die "could not create a staging directory in VM ${INSTANCE}"
  printf '%s' "$dir"
}

guest_unstage() {
  [ -n "$1" ] || return 0
  guest rm -rf -- "$1" </dev/null 2>/dev/null || true
}

# run_provision <stdin text> [VAR=value ...]
run_provision() {
  local input="$1" stage
  shift
  stage="$(guest_stage_dir)"
  trap 'guest_unstage "$stage"' RETURN
  limactl copy "$PROVISION" "${INSTANCE}:${stage}/provision.sh"
  # The guest helpers provision.sh installs from its own directory (vm/guest/).
  # The uninstall path stages provision.sh alone and runs ensure-service, which
  # needs none of them.
  limactl copy -r "$GUEST_DIR" "${INSTANCE}:${stage}/guest"
  printf '%s' "$input" | guest_stdin sudo "$@" bash "${stage}/provision.sh"
  guest_unstage "$stage"
  trap - RETURN
}

enable_autostart() {
  if limactl autostart enable "$INSTANCE" >/dev/null 2>&1 ||
    limactl start-at-login --enabled "$INSTANCE" >/dev/null 2>&1; then
    log "VM ${INSTANCE} starts at login"
  else
    log "could not enable autostart; see docs/runbook.md, Setup (Autostart)" >&2
  fi
}
