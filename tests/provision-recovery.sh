#!/usr/bin/env bash
# provision.sh on a runner that is running (#61): once it has stopped the
# service to replace the runner binary, any failure before the service is
# started again must leave the runner running, as the host-side `upgrade`
# does for the VM it stops itself.
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
  start|restart) [ "${FAIL_AT:-}" = start ] && [ "$1" = restart ] && exit 1; : >"$STATE.active" ;;
  *) exit 0 ;;
esac'
stub journalctl '[ -e "$STATE.active" ] && echo "Listening for Jobs"; exit 0'

# The script up to the cleanup timer, with its absolute paths in the scratch
# tree. BSD mktemp keeps a template's suffix literally, so the tarball's goes.
sed -n '1,/^# ── Cleanup timer/p' "$ROOT/vm/provision.sh" |
  sed -e "s|/opt/actions-runner|$work/runner|g" \
    -e "s|/usr/local/sbin|$work/sbin|g" \
    -e "s|/etc/sudoers.d|$work/sudoers.d|g" \
    -e "s|/etc/homefield|$work/etc|g" \
    -e "s|mktemp /tmp/actions-runner.XXXXXX.tar.gz|mktemp $work/tarball.XXXXXX|" \
    >"$work/provision.sh"
record "the script was cut at its cleanup timer" "yes" "$(grep -q '^# ── Cleanup timer' "$work/provision.sh" && echo yes || echo no)"

unit="actions.runner.test.service"
# fresh <version> <active|stopped>: a registered runner at that version.
fresh() {
  rm -rf "${work:?}/runner" "${work:?}/sbin" "${work:?}/sudoers.d" "${work:?}/etc" "${work:?}"/state*
  mkdir -p "$work/runner/bin" "$work/sbin" "$work/sudoers.d" "$work/etc"
  printf '#!/bin/sh\nexit 0\n' >"$work/runner/bin/installdependencies.sh"
  chmod +x "$work/runner/bin/installdependencies.sh"
  : >"$work/runner/config.sh"
  chmod +x "$work/runner/config.sh"
  echo "$unit" >"$work/runner/.service"
  echo "$1" >"$work/runner/.provisioned-version"
  echo '{"gitHubUrl":"https://github.com/acme"}' >"$work/runner/.runner"
  echo 'LANG=C' >"$work/runner/.env"
  [ "$2" = active ] && : >"$work/state.active"
  return 0
}
# run [FAIL_AT]: provision, as root, against the scratch tree.
run() {
  PATH="$stubs:$PATH" STATE="$work/state" FAIL_AT="${1:-}" bash "$work/provision.sh" </dev/null >"$work/out" 2>&1
}
running() { [ -e "$work/state.active" ] && echo running || echo stopped; }
calls() { grep -c "^systemctl $1 " "$work/state.log" 2>/dev/null || true; }

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
record "the restart fails: provisioning fails" "1" "$rc"
record "...with no second start from a leftover trap" "0" "$(calls start)"

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

summary
