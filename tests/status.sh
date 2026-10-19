#!/usr/bin/env bash
# `homefield status` when the runner's settings cannot be read (#63): the
# report goes on to the service, the job and the version, as the comment on
# that branch promises, instead of ending at the first failed `read` under
# `set -e`.
#
# The real cmd_status runs; the VM helpers are functions that answer from the
# environment. Nothing reaches a VM.
#
# Run:  bash tests/status.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# cmd_status keeps the errexit and nounset that bin/homefield sets, as in use.
cat >"$work/harness.sh" <<EOF
HOMEFIELD_SOURCE_ONLY=1
. "$ROOT/bin/homefield"
command() { return 0; }
vm_status() { echo Running; }
registered() { return \${REG_RC:-0}; }
job_running() { return 1; }
runner_setting() {
  [ -z "\${SETTING_FAIL:-}" ] || return 1
  printf '%b' "\$SETTING_OUT"
}
guest() {
  case "\$*" in
    "sudo cat "*/.service) echo actions.runner.acme.test.service ;;
    "systemctl is-active "*) return 0 ;;
    "sudo cat "*/.provisioned-version) echo 2.337.0 ;;
    "sh -c "*) echo "libpq-dev " ;;
  esac
}
cmd_status
EOF
# status [VAR=value ...]: out and rc.
status() {
  out="$(env "$@" bash "$work/harness.sh" 2>&1 </dev/null)"
  rc=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
# rest: the lines after the runner line, all of them or not.
rest() {
  printf '%s/%s/%s/%s' "$(has "$out" 'service: running')" "$(has "$out" 'job: idle')" \
    "$(has "$out" 'runner version: 2.337.0')" "$(has "$out" 'extra packages: libpq-dev')"
}

status SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n'
record "both settings read: exits 0" "0" "$rc"
record "...names the runner and where it is registered" "yes" "$(has "$out" 'runner: my-mac-homefield, registered at https://github.com/acme')"
record "...and reports the rest" "yes/yes/yes/yes" "$(rest)"
record "...with the runners page, which needs the URL" "yes" "$(has "$out" 'labels: see https://github.com/organizations/acme/settings/actions/runners')"

status SETTING_OUT='my-mac-homefield\n'
record "one line only: exits 0" "0" "$rc"
record "...says the details could not be read" "yes" "$(has "$out" 'runner: registered, but its details could not be read')"
record "...and reports the rest" "yes/yes/yes/yes" "$(rest)"
record "...with no runners page, as the URL is unknown" "no" "$(has "$out" 'labels: see')"

status SETTING_OUT=''
record "no output: exits 0" "0" "$rc"
record "...says the details could not be read" "yes" "$(has "$out" 'runner: registered, but its details could not be read')"
record "...and reports the rest" "yes/yes/yes/yes" "$(rest)"

status SETTING_FAIL=1 SETTING_OUT=''
record "the read fails outright: exits 0" "0" "$rc"
record "...says the details could not be read" "yes" "$(has "$out" 'runner: registered, but its details could not be read')"
record "...and reports the rest" "yes/yes/yes/yes" "$(rest)"

status REG_RC=1
record "not registered: exits 0 and says so" "0/yes/no" "$rc/$(has "$out" 'runner: not registered')/$(has "$out" 'service:')"

status REG_RC=2
record "the VM cannot be asked: exits 1" "1" "$rc"
record "...says unknown, not that it is unregistered, and stops there" "yes/no/no" "$(has "$out" 'runner: unknown')/$(has "$out" 'not registered')/$(has "$out" 'service:')"

summary
