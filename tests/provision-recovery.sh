#!/usr/bin/env bash
# provision.sh on a runner that is running (#61): once it has stopped the
# service to replace the runner binary, any failure before the service is
# started again must leave the runner running, as the host-side `upgrade`
# does for the VM it stops itself. A move also restores the old service if
# uninstall or registration removal fails (#81). A first registration is
# followed straight away by its service, with the steps that can fail before
# it (#83).
#
# The real script runs, cut off before its cleanup timer, in a scratch tree:
# its absolute paths are rewritten into it and every command that would touch
# the machine (systemctl, apt-get, tar, chown, sudo, ...) is a stub on PATH.
# The systemctl stub keeps the service's state in a file and logs its calls.
# A failure is injected at one stub, named by FAIL_AT.
#
# Run:  bash tests/provision-recovery.sh
# shellcheck disable=SC2016  # the stub bodies expand when they run, not when defined
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stubs="$work/stubs"
mkdir -p "$stubs"

# stub <name> <body>: an executable on the stubs' PATH. The bodies are single
# quoted on purpose: they expand when the stub runs, not here.
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$stubs/$1"; chmod +x "$stubs/$1"; }

stub id 'case "$1" in -u) echo 0 ;; esac'
stub hostname 'echo lima-test'
stub apt-get 'exit 0'
stub useradd 'exit 0'
stub usermod 'exit 0'
stub sleep 'exit 0'
stub pgrep 'exit 1'
stub curl 'while [ $# -gt 0 ]; do [ "$1" = -o ] && : >"$2"; shift; done'
stub sha256sum 'exit 0'
# tar -xzf <tarball> -C <dir>: fails on FAIL_AT=tar.
stub tar '[ "${FAIL_AT:-}" != tar ] || { echo "tar: injected failure" >&2; exit 1; }'
# chown -R runner:runner <home> is provision.sh's own; the rest come from the
# workspace hook. FAIL_AT=chown fails the first only.
stub chown '[ "${FAIL_AT:-}" = chown ] && [ "$1" = -R ] && { echo "chown: injected failure" >&2; exit 1; }; exit 0'
stub visudo '[ "${FAIL_AT:-}" != visudo ] || { echo "visudo: injected failure" >&2; exit 1; }'
# install [-o u] [-g g] [-m mode] <src> <dst>: a copy; FAIL_AT=env fails the
# one onto the runner's .env.
stub install 'while [ $# -gt 2 ]; do case "$1" in -o|-g|-m) shift 2 ;; *) shift ;; esac; done
[ "${FAIL_AT:-}" = env ] && case "$2" in */.env) echo "install: injected failure" >&2; exit 1 ;; esac
cp "$1" "$2"'
# sudo [-n] [-u user] [--preserve-env=...] <command...>: the command, as this user.
stub sudo 'while [ $# -gt 0 ]; do case "$1" in -u) shift 2 ;; -n|--preserve-env=*) shift ;; *) break ;; esac; done
exec "$@"'
stub systemctl 'echo "systemctl $*" >>"$STATE.log"
case "$1" in
  is-active) [ -e "$STATE.active" ] ;;
  stop) rm -f "$STATE.active" ;;
  disable) rm -f "$STATE.enabled"; [ "${FAIL_AT:-}" != disable ] ;;
  enable) [ "$2" = --now ] && exit 0; [ -f "$UNIT_DIR/$2" ] || exit 1; : >"$STATE.enabled" ;;
  start|restart)
    [ "${FAIL_AT:-}" = start ] && [ "$1" = restart ] && exit 1
    [ -f "$UNIT_DIR/$2" ] || exit 1
    : >"$STATE.active" ;;
  *) exit 0 ;;
esac'
stub journalctl '[ "${FAIL_AT:-}" != listen ] && [ -e "$STATE.active" ] && echo "Listening for Jobs"; exit 0'

# The script up to the cleanup timer, with its absolute paths in the scratch
# tree. BSD mktemp keeps a template's suffix literally, so the tarball's goes.
sed -n '1,/^# ── Cleanup timer/p' "$ROOT/vm/provision.sh" |
  sed -e "s|/opt/actions-runner|$work/runner|g" \
    -e "s|/usr/local/sbin|$work/sbin|g" \
    -e "s|/etc/sudoers.d|$work/sudoers.d|g" \
    -e "s|/etc/systemd/system|$work/systemd|g" \
    -e "s|/etc/homefield|$work/etc|g" \
    -e "s|mktemp /tmp/actions-runner.XXXXXX.tar.gz|mktemp $work/tarball.XXXXXX|" \
    >"$work/provision.sh"
record "the script was cut at its cleanup timer" "yes" "$(grep -q '^# ── Cleanup timer' "$work/provision.sh" && echo yes || echo no)"

unit="actions.runner.test.service"
# fresh <version> <active|stopped>: a registered runner at that version.
fresh() {
  rm -rf "${work:?}/runner" "${work:?}/sbin" "${work:?}/sudoers.d" "${work:?}/etc" "${work:?}/systemd" "${work:?}"/state*
  mkdir -p "$work/runner/bin" "$work/sbin" "$work/sudoers.d" "$work/etc" "$work/systemd"
  printf '#!/bin/sh\nexit 0\n' >"$work/runner/bin/installdependencies.sh"
  chmod +x "$work/runner/bin/installdependencies.sh"
  cat >"$work/runner/config.sh" <<'EOF'
#!/usr/bin/env bash
echo "config $*" >>"$STATE.log"
if [ "$1" = remove ]; then
  [ "${FAIL_AT:-}" != remove ] || exit 1
  rm -f "$(dirname "$0")/.runner"
else
  [ "${FAIL_AT:-}" != register ] || exit 1
  echo '{"gitHubUrl":"https://github.com/new-scope"}' >"$(dirname "$0")/.runner"
fi
EOF
  chmod +x "$work/runner/config.sh"
  cat >"$work/runner/svc.sh" <<'EOF'
#!/usr/bin/env bash
SVC_NAME="actions.runner.test.service"
echo "svc $*" >>"$STATE.log"
case "$1" in
  uninstall)
    systemctl disable "$UNIT" || exit 1
    [ "${FAIL_AT:-}" != unit_remove ] || exit 1
    rm -f "$UNIT_DIR/$UNIT"
    [ "${FAIL_AT:-}" != marker_remove ] || exit 1
    rm -f "$(dirname "$0")/.service"
    [ "${FAIL_AT:-}" != uninstall ] || exit 1
    systemctl daemon-reload
    ;;
  install)
    [ "${FAIL_AT:-}" != svc_install ] || exit 1
    [ ! -f "$UNIT_DIR/$UNIT" ] || exit 1
    : >"$UNIT_DIR/$UNIT"
    systemctl daemon-reload
    systemctl enable "$UNIT"
    echo "$UNIT" >"$(dirname "$0")/.service"
    ;;
esac
EOF
  chmod +x "$work/runner/svc.sh"
  echo "$unit" >"$work/runner/.service"
  : >"$work/systemd/$unit"
  : >"$work/state.enabled"
  echo "$1" >"$work/runner/.provisioned-version"
  echo '{"gitHubUrl":"https://github.com/acme"}' >"$work/runner/.runner"
  echo 'LANG=C' >"$work/runner/.env"
  [ "$2" = active ] && : >"$work/state.active"
  return 0
}
# run [FAIL_AT]: provision, as root, against the scratch tree.
run() {
  PATH="$stubs:$PATH" STATE="$work/state" UNIT="$unit" UNIT_DIR="$work/systemd" FAIL_AT="${1:-}" bash "$work/provision.sh" </dev/null >"$work/out" 2>&1
}
run_move() {
  printf 'RUNNER_REMOVE_TOKEN=old-token\nRUNNER_TOKEN=new-token\n' |
    PATH="$stubs:$PATH" STATE="$work/state" UNIT="$unit" UNIT_DIR="$work/systemd" FAIL_AT="$1" \
      RUNNER_REREGISTER=1 RUNNER_URL=https://github.com/new-scope \
      bash "$work/provision.sh" >"$work/out" 2>&1
}
# run_first [FAIL_AT]: the first registration, on an unregistered runner.
run_first() {
  rm -f "$work/runner/.runner" "$work/runner/.service" "$work/systemd/$unit" "$work/state.enabled"
  printf 'RUNNER_TOKEN=new-token\n' |
    PATH="$stubs:$PATH" STATE="$work/state" UNIT="$unit" UNIT_DIR="$work/systemd" FAIL_AT="${1:-}" \
      RUNNER_URL=https://github.com/new-scope \
      bash "$work/provision.sh" >"$work/out" 2>&1
}
running() { [ -e "$work/state.active" ] && echo running || echo stopped; }
enabled() { [ -e "$work/state.enabled" ] && echo enabled || echo disabled; }
unit_present() { [ -f "$work/systemd/$unit" ] && echo present || echo absent; }
calls() { grep -c "^systemctl $1 " "$work/state.log" 2>/dev/null || true; }
svc_calls() { grep -c "^svc $1" "$work/state.log" 2>/dev/null || true; }

# The version in provision.sh, so every case replaces the binary (old) or none.
current="$(sed -n 's/^RUNNER_VERSION="\(.*\)"$/\1/p' "$ROOT/vm/provision.sh")"

echo "a running runner, replaced:"
fresh 2.0.0 active
run
rc=$?
record "success: exits 0" "0" "$rc"
record "...the runner is running" "running" "$(running)"
record "...stopped once to replace the binary, then restarted once" "1/1" "$(calls stop)/$(calls restart)"
record "...records the new version" "$current" "$(cat "$work/runner/.provisioned-version")"

for at in tar chown visudo env; do
  fresh 2.0.0 active
  run "$at"
  rc=$?
  record "$at fails: provisioning fails" "1" "$rc"
  record "...and the runner is running again" "running" "$(running)"
done

fresh 2.0.0 active
run start
rc=$?
record "the final restart fails: provisioning fails" "1" "$rc"
record "...and the runner is started again, by the trap" "running/1" "$(running)/$(calls start)"

fresh 2.0.0 active
run listen
rc=$?
record "it never logs \"Listening for Jobs\": provisioning fails" "1" "$rc"
record "...and the trap starts the service once more" "running/1" "$(running)/$(calls start)"

echo "a running runner, already current:"
fresh "$current" active
run chown
rc=$?
record "chown fails: provisioning fails" "1" "$rc"
record "...the runner was never stopped, and is still running" "0/running" "$(calls stop)/$(running)"

echo "a stopped runner (the host stopped it for \`upgrade\`):"
fresh 2.0.0 stopped
run chown
rc=$?
record "chown fails: provisioning fails" "1" "$rc"
record "...and does not start what it did not stop" "stopped" "$(running)"
fresh 2.0.0 stopped
run
record "success: the runner is started" "0/running" "$?/$(running)"

echo "a move fails before old registration removal:"
fresh 2.0.0 active
run_move tar
rc=$?
record "binary replacement fails during a move: provisioning fails" "1" "$rc"
record "...the move recovery still starts the old runner" "running/1" "$(running)/$(calls start)"
for at in disable unit_remove marker_remove uninstall remove; do
  fresh "$current" active
  run_move "$at"
  rc=$?
  record "$at fails: provisioning fails" "1" "$rc"
  record "...old registration remains" "https://github.com/acme" "$(sed -n 's/.*"gitHubUrl":"\([^"]*\)".*/\1/p' "$work/runner/.runner")"
  record "...service marker is restored" "$unit" "$(cat "$work/runner/.service")"
  record "...unit exists and is enabled" "present/enabled" "$(unit_present)/$(enabled)"
  case "$at" in disable|unit_remove) installs=0 ;; *) installs=1 ;; esac
  record "...service install matches the unit state" "$installs" "$(svc_calls install)"
  record "...old service is running" "running/1" "$(running)/$(calls start)"
done
record "...removal was attempted only after successful uninstall" "1" "$(grep -c '^config remove$' "$work/state.log")"

fresh "$current" active
run_move visudo
rc=$?
record "the workspace hook's sudo rule fails during a move: provisioning fails" "1" "$rc"
record "...before the old registration is removed, which keeps its service and runs" "https://github.com/acme/$unit/0/running" "$(sed -n 's/.*"gitHubUrl":"\([^"]*\)".*/\1/p' "$work/runner/.runner")/$(cat "$work/runner/.service")/$(svc_calls install)/$(running)"

echo "a move after old registration removal:"
fresh "$current" active
run_move ""
rc=$?
record "success: provisioning exits 0" "0" "$rc"
record "...new registration replaces old" "https://github.com/new-scope" "$(sed -n 's/.*"gitHubUrl":"\([^"]*\)".*/\1/p' "$work/runner/.runner")"
record "...new service is running" "$unit/running" "$(cat "$work/runner/.service")/$(running)"
record "...old service was not restarted" "0" "$(calls start)"

fresh "$current" active
run_move register
rc=$?
record "registration fails after removal: provisioning fails" "1" "$rc"
record "...old registration is gone" "absent" "$([ -e "$work/runner/.runner" ] && echo present || echo absent)"
record "...old service is not reinstalled" "absent/0" "$([ -e "$work/runner/.service" ] && echo present || echo absent)/$(svc_calls install)"
record "...old service is not restarted" "stopped/0" "$(running)/$(calls start)"

echo "the first registration (#83):"
registration() { [ -e "$work/runner/.runner" ] && echo registered || echo unregistered; }
fresh "$current" stopped
run_first
rc=$?
record "success: exits 0" "0" "$rc"
record "...registered, with its service installed and running" "registered/$unit/present/running" "$(registration)/$(cat "$work/runner/.service")/$(unit_present)/$(running)"
fresh "$current" stopped
run_first visudo
rc=$?
record "the workspace hook's sudo rule fails: provisioning fails" "1" "$rc"
record "...before registering, so no registration is left without a service" "0/unregistered" "$(grep -c '^config ' "$work/state.log")/$(registration)"
fresh "$current" stopped
run_first env
rc=$?
record "writing .env fails after registering: provisioning fails" "1" "$rc"
record "...with the service already installed and enabled" "registered/$unit/present/enabled" "$(registration)/$(cat "$work/runner/.service")/$(unit_present)/$(enabled)"

echo "a service left half done (#83):"
fresh "$current" active
rm -f "$work/runner/.service" "$work/state.active"
run
rc=$?
record "a unit file with no .service (an svc.sh install cut off): provisioning succeeds" "0" "$rc"
record "...the unit is replaced, enabled and running" "$unit/present/enabled/running/1" "$(cat "$work/runner/.service")/$(unit_present)/$(enabled)/$(running)/$(svc_calls install)"
fresh "$current" active
rm -f "$work/systemd/$unit" "$work/state.active" "$work/state.enabled"
run
rc=$?
record "a .service with no unit file (an uninstall cut off): provisioning succeeds" "0" "$rc"
record "...the service is installed again, enabled and running" "$unit/present/enabled/running/1" "$(cat "$work/runner/.service")/$(unit_present)/$(enabled)/$(running)/$(svc_calls install)"

echo "provision.sh ensure-service, as uninstall runs it (#99):"
# ensure [--start]: only the subcommand, with FAIL_AT.
ensure() {
  PATH="$stubs:$PATH" STATE="$work/state" UNIT="$unit" UNIT_DIR="$work/systemd" FAIL_AT="${FAIL_AT:-}" \
    bash "$work/provision.sh" ensure-service "$@" </dev/null >"$work/out" 2>&1
}
fresh "$current" stopped
rm -f "$work/state.enabled"
ensure --start
rc=$?
record "intact but disabled (an uninstall cut off): exits 0" "0" "$rc"
record "...enabled and started, not reinstalled, nothing else run" "enabled/running/0/0" "$(enabled)/$(running)/$(svc_calls install)/$(grep -c '^config ' "$work/state.log")"
fresh "$current" stopped
rm -f "$work/runner/.service"
ensure
rc=$?
record "a unit file with no .service, no --start: exits 0" "0" "$rc"
record "...reinstalled and enabled, not started" "$unit/enabled/stopped/1" "$(cat "$work/runner/.service")/$(enabled)/$(running)/$(svc_calls install)"
fresh "$current" stopped
rm -f "$work/runner/.service" "$work/systemd/$unit"
FAIL_AT=svc_install ensure --start
rc=$?
record "svc.sh install fails: exits 1, says so, starts nothing" "1/yes/0" "$rc/$(grep -q 'could not install the runner service' "$work/out" && echo yes || echo no)/$(calls start)"
for args in --strt "--start extra"; do
  fresh "$current" stopped
  rm -f "$work/runner/.service"
  # shellcheck disable=SC2086  # split on purpose: "--start extra" is two arguments
  ensure $args
  rc=$?
  record "ensure-service $args: refused with exit 2, saying so" "2/yes" "$rc/$(grep -q 'takes only --start' "$work/out" && echo yes || echo no)"
  record "...and runs nothing: no svc.sh, systemctl or config.sh call" "0/stopped" "$(if [ -f "$work/state.log" ]; then wc -l <"$work/state.log" | tr -d ' '; else echo 0; fi)/$(running)"
done

summary
