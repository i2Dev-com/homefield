#!/usr/bin/env bash
# `homefield start` and `homefield stop`: booting is not the same fact as
# serving jobs, so start reports whether the runner is registered, its service
# is running and GitHub lists it online; stop refuses under a live job (#171).
#
# The real bin/homefield runs, through main, with a PATH that holds only stubs
# (limactl, gh, uname, sw_vers, python3): nothing reaches a VM, GitHub or the
# real machine. limactl logs every call and acts as the guest; only what it is
# asked answers from the environment.
#
# Run:  bash tests/start-stop.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

BASH_BIN="$(command -v bash)"
stubs="$work/stubs"
calls="$work/calls"
mkdir -p "$stubs"

for t in awk cat dirname grep mktemp rm sleep; do ln -s "$(command -v "$t")" "$stubs/$t"; done

# limactl: a Lima whose only instance is homefield when LIMA_STATUS is set
# (empty = no VM). Every call logged. `start`/`stop` fail on their own switches.
# `shell` is the guest: registered (REG), its service name, a live job (JOB).
cat >"$stubs/limactl" <<'EOF'
#!/bin/sh
echo "limactl $*" >>"$CALLS"
case "$1" in
  --version) echo "limactl version ${LIMA_VERSION:-2.3.0}" ;;
  list)
    [ -z "${LIMA_LIST_FAIL:-}" ] || { echo "limactl: list failed" >&2; exit 1; }
    [ -z "${LIMA_STATUS:-}" ] || echo "homefield ${LIMA_STATUS}"
    ;;
  start)
    [ -z "${START_FAIL:-}" ] || { echo "limactl: could not start" >&2; exit 1; }
    ;;
  stop)
    [ -z "${STOP_FAIL:-}" ] || { echo "limactl: could not stop" >&2; exit 1; }
    ;;
  shell)
    shift 4
    [ -z "${SHELL_FAIL:-}" ] || { echo "limactl: could not connect" >&2; exit 1; }
    [ "$1" != sudo ] || shift
    case "$1" in
      sh)
        script="$3"
        case "$script" in
          *'test -f'*)
            if [ "${REG:-0}" = 0 ]; then echo yes; else echo no; fi ;;
          *pgrep*)
            if [ "${JOB:-no}" = yes ]; then echo yes; else echo no; fi ;;
          *extra-packages*) printf '%s' "${GUEST_PKGS-}" ;;
        esac
        ;;
      python3) printf '%b' "${SETTING_OUT-}" ;;
      cat)
        case "$2" in
          */.service) [ -z "${SVC_NAME:-}" ] || printf '%s' "$SVC_NAME" ;;
          *) echo "limactl stub: unexpected cat: $*" >&2; exit 99 ;;
        esac
        ;;
      systemctl) exit "${SVC_ACTIVE:-0}" ;;
      *) echo "limactl stub: unexpected guest command: $*" >&2; exit 99 ;;
    esac
    ;;
esac
EOF

# gh: the runners list, by id and status (GH_RUNNERS rows); a failure switch,
# and GH_SLEEP black-holes it so the code's own timer must kill it.
cat >"$stubs/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$CALLS"
case "$*" in
  *"/actions/runners?"*)
    if [ -n "${GH_SLEEP:-}" ]; then sleep 3; fi
    [ -z "${GH_FAIL:-}" ] || exit 1
    printf '%b' "${GH_RUNNERS-}"
    ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 99 ;;
esac
EOF

cat >"$stubs/uname" <<'EOF'
#!/bin/sh
case "$1" in
  -s) echo Darwin ;;
  -m) echo arm64 ;;
esac
EOF
cat >"$stubs/sw_vers" <<'EOF'
#!/bin/sh
echo "26.6.2"
EOF

chmod +x "$stubs/limactl" "$stubs/gh" "$stubs/uname" "$stubs/sw_vers"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
called() { grep -c -e "$1" "$calls" || true; }

# hf <VAR=value ...> -- <command and options>: out, rc and stderr.
hf() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : >"$calls"
  out="$(env -i HOME="$work/home" PATH="$stubs" CALLS="$calls" HOMEFIELD_GH_TIMEOUT=5 \
    "${envs[@]+"${envs[@]}"}" "$BASH_BIN" "$ROOT/bin/homefield" "$@" 2>"$work/err" </dev/null)"
  rc=$?
  err="$(cat "$work/err")"
}

# A registered organization runner named my-mac-homefield, id 42. The settings
# come back one field per line, as runner_setting's python3 prints them.
settings='my-mac-homefield\nhttps://github.com/acme\n42\n'
online=(LIMA_STATUS=Stopped REG=0 SETTING_OUT="$settings" SVC_NAME='actions.runner.acme.test.service' \
  GH_RUNNERS='42\tonline\tfalse\n')

echo "start: booted is not the same fact as serving jobs"
hf "${online[@]}" -- start
record "a stopped VM with a healthy runner: exits 0" "0/yes" "$rc/$(has "$out" 'taking jobs: yes')"
record "...starts it with --tty=false, exactly once" "1/yes" "$(called '^limactl start --tty=false homefield')/$(has "$out" 'homefield: starting VM homefield')"
record "...then reports the VM, the runner, the service and GitHub" "yes/yes/yes/yes" \
  "$(has "$out" 'VM homefield: Running')/$(has "$out" 'runner: my-mac-homefield, registered at https://github.com/acme')/$(has "$out" 'service: running')/$(has "$out" 'github: listed (online)')"
record "...and asks GitHub only for the runner list, bounded" "1/0" "$(called '^gh api.*orgs/acme/actions/runners?')/$(called '-X ')"

hf "${online[@]}" LIMA_STATUS=Running -- start
record "a VM already running: no boot, still reports online" "0/0/no" "$rc/$(called '^limactl start')/$(has "$out" 'starting VM')"

hf "${online[@]}" LIMA_STATUS=Stopped REG=1 -- start
record "booted, but no runner registered: exits 1 with the way to register it" "1/yes/yes" \
  "$rc/$(has "$out" 'runner: not registered')/$(has "$err+$out" 'bin/homefield install --instance homefield --url https://github.com/<org>[/<repo>]')"
record "...the boot happened, and GitHub was not asked (no id)" "1/0" "$(called '^limactl start')/$(called '/actions/runners?')"

hf "${online[@]}" LIMA_STATUS=Stopped SVC_ACTIVE=1 -- start
record "booted, but the service is stopped: exits 1 saying so" "1/yes/no" "$rc/$(has "$out" 'service: NOT running (actions.runner.acme.test.service)')/$(has "$out" 'taking jobs: yes')"
record "...with the upgrade fix and a GitHub online answer that does not stand alone" "yes/yes" \
  "$(has "$err+$out" 'bin/homefield upgrade --instance homefield')/$(has "$out" 'taking jobs: no')"

hf "${online[@]}" LIMA_STATUS=Stopped GH_RUNNERS='42\toffline\tfalse\n' -- start
record "booted, GitHub lists it offline: exits 1, not taking jobs" "1/yes/yes" \
  "$rc/$(has "$out" 'github: listed (offline)')/$(has "$err+$out" "check https://github.com/organizations/acme/settings/actions/runners")"

hf "${online[@]}" LIMA_STATUS=Stopped GH_RUNNERS='' -- start
record "booted, GitHub no longer has the runner: exits 1 with how to register it again" "1/yes/yes" \
  "$rc/$(has "$out" 'github: NOT listed')/$(has "$err+$out" 'bin/homefield uninstall --instance homefield --keep-vm, then bin/homefield install')"

hf "${online[@]}" LIMA_STATUS=Stopped GH_FAIL=1 -- start
record "booted, GitHub could not be asked: exits 1, online unproven" "1/yes/yes" \
  "$rc/$(has "$out" 'github: not checked')/$(has "$err+$out" 'bin/homefield status --instance homefield')"
record "...never read as taking jobs" "no" "$(has "$out" 'taking jobs: yes')"

# The timer kills a gh that sleeps past GH_TIMEOUT (sleep 3 > timeout 1), so
# the answer is the timed-out wording, not a plain failure.
hf "${online[@]}" GH_SLEEP=1 HOMEFIELD_GH_TIMEOUT=1 -- start
record "booted, GitHub times out: exits 1, online unproven" "1/yes/yes/no" \
  "$rc/$(has "$out" 'github: not checked (timed out after 1s')/$(has "$err+$out" 'bin/homefield status --instance homefield')/$(has "$out" 'taking jobs: yes')"

hf "${online[@]}" LIMA_STATUS=Stopped SHELL_FAIL=1 -- start
record "booted, but the guest cannot be asked: exits 1 as unknown, not 'not registered'" "1/yes/no" \
  "$rc/$(has "$out" 'runner: unknown (could not ask the VM)')/$(has "$out" 'not registered')"

hf "${online[@]}" LIMA_STATUS=Stopped START_FAIL=1 -- start
record "a boot that fails: exits 1 naming Lima, nothing reported afterwards" "1/yes/no" \
  "$rc/$(has "$err+$out" 'could not start VM homefield')/$(has "$out" 'VM homefield: Running')"

hf LIMA_STATUS= -- start
record "no VM: exits 1 naming install, and starts nothing" "1/yes/0/no" \
  "$rc/$(has "$err+$out" 'no VM homefield; run bin/homefield install')/$(called '^limactl start')/$(has "$out" 'VM homefield: Running')"

hf LIMA_STATUS=Stopped LIMA_LIST_FAIL=1 -- start
record "Lima cannot be asked: exits 1, nothing started" "1/yes/0" \
  "$rc/$(has "$err+$out" 'could not ask Lima about VM homefield')/$(called '^limactl start')"

hf "${online[@]}" -- start --dry-run
record "an option it does not take: refused, nothing started" "1/yes/0" \
  "$rc/$(has "$err+$out" 'start takes no options besides --instance')/$(called '^limactl start')"

echo
echo "stop: refuses under a live job, and fails closed when it cannot tell"
hf LIMA_STATUS=Running -- stop
record "an idle runner: stops the VM, exits 0" "0/1/yes" \
  "$rc/$(called '^limactl stop homefield')/$(has "$out" 'VM homefield: Stopped')"

hf LIMA_STATUS=Running JOB=yes -- stop
record "a live job: refused, nothing stopped" "1/0/yes" \
  "$rc/$(called '^limactl stop')/$(has "$err+$out" 'a job is running on homefield; stopping now would cancel it')"
record "...and says how to keep the repository hosted" "yes" "$(has "$err+$out" 'bin/homefield route hosted --repo <owner>/<repo>')"

hf LIMA_STATUS=Running SHELL_FAIL=1 -- stop
record "the VM cannot be asked whether a job is running: fails closed, nothing stopped" "1/0/yes" \
  "$rc/$(called '^limactl stop')/$(has "$err+$out" 'could not ask VM homefield whether a job is running; nothing was stopped')"

hf LIMA_STATUS=Stopped -- stop
record "already stopped: not an error, nothing called" "0/0/yes" \
  "$rc/$(called '^limactl stop')/$(has "$out" 'VM homefield: already Stopped, nothing to stop')"

hf LIMA_STATUS= -- stop
record "no VM: refused naming it, nothing stopped" "1/yes/0" \
  "$rc/$(has "$err+$out" 'no VM homefield; nothing to stop')/$(called '^limactl stop')"

hf LIMA_STATUS=Running STOP_FAIL=1 -- stop
record "a stop that fails: exits 1 naming Lima, and does not say Stopped" "1/yes/no" \
  "$rc/$(has "$err+$out" 'could not stop VM homefield')/$(has "$out" 'VM homefield: Stopped')"

hf LIMA_STATUS=Running -- stop extra
record "an option it does not take: refused, nothing stopped" "1/yes/0" \
  "$rc/$(has "$err+$out" 'stop takes no options besides --instance')/$(called '^limactl stop')"

hf LIMA_STATUS=Stopped -- start extra
record "start refuses an option too" "1/yes/0" "$rc/$(has "$err+$out" 'start takes no options besides --instance')/$(called '^limactl start')"

summary
