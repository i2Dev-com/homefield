#!/usr/bin/env bash
# `homefield status` when the runner's settings cannot be read (#63): the
# report goes on to the service, the job and the version, as the comment on
# that branch promises, instead of ending at the first failed `read` under
# `set -e`. And whether GitHub still lists the runner (#76): it removes one
# that has not connected for more than 14 days, and the VM cannot tell — with
# the check bounded so a dead network cannot stall status (#103).
#
# The real cmd_status runs; the VM helpers and gh are functions that answer
# from the environment. Nothing reaches a VM or GitHub.
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
job_running() { return \${JOB_RC:-1}; }
runner_setting() {
  [ -z "\${SETTING_FAIL:-}" ] || return 1
  printf '%b' "\$SETTING_OUT"
}
# The runner ids GitHub lists (GH_IDS), or a gh that fails unless GH_FAIL=0.
# GH_SLEEP=1 black-holes the call: it answers after the test's timeout, so
# the timer must kill it.
gh() {
  echo "gh \$*" >>"$work/gh-calls"
  if [ "\${GH_SLEEP:-}" = 1 ]; then sleep 3; fi
  [ "\${GH_FAIL:-1}" = 0 ] || return 1
  printf '%b' "\${GH_IDS:-}"
}
offer_scope_refresh() { echo "offer_scope_refresh" >>"$work/gh-calls"; return 1; }
guest() {
  case "\$*" in
    "sudo cat "*/.service) echo actions.runner.acme.test.service ;;
    "systemctl is-active "*) return 0 ;;
    "sudo cat "*/.provisioned-version) echo 2.338.0 ;;
    "sh -c "*npm*) case "\${NPM_RC:-0}" in 0) echo ok ;; 1) echo broken ;; *) return 2 ;; esac ;;
    "sh -c "*) echo "libpq-dev " ;;
  esac
}
cmd_status
EOF
# status [VAR=value ...]: out and rc.
status() {
  : >"$work/gh-calls"
  out="$(env "$@" bash "$work/harness.sh" 2>&1 </dev/null)"
  rc=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
# rest: the lines after the runner line, all of them or not.
rest() {
  printf '%s/%s/%s/%s' "$(has "$out" 'service: running')" "$(has "$out" 'job: idle')" \
    "$(has "$out" 'runner version: 2.338.0')" "$(has "$out" 'extra packages: libpq-dev')"
}

status SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n42\n'
record "all settings read, GitHub not asked: exits 0" "0" "$rc"
record "...names the runner and where it is registered" "yes" "$(has "$out" 'runner: my-mac-homefield, registered at https://github.com/acme')"
record "...and reports the rest" "yes/yes/yes/yes" "$(rest)"
record "...with the runners page, which needs the URL" "yes" "$(has "$out" 'labels: see https://github.com/organizations/acme/settings/actions/runners')"
record "...says GitHub was not checked" "yes" "$(has "$out" 'github: not checked (needs gh with admin access to https://github.com/acme)')"

echo "GitHub's list (#76):"
gh_calls() { grep -c -e "$1" "$work/gh-calls" || true; }
status GH_FAIL=0 GH_IDS='41\n42\n' SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n42\n'
record "listed: exits 0 and says so" "0/yes" "$rc/$(has "$out" 'github: listed')"
record "...asking github.com for the scope's runners, paginated" "1" "$(gh_calls 'api --hostname github.com --paginate orgs/acme/actions/runners')"
record "...and reports the rest" "yes/yes/yes/yes" "$(rest)"
status GH_FAIL=0 GH_IDS='41\n420\n4\n' SETTING_OUT='my-mac-homefield\nhttps://github.com/acme/app\n42\n'
record "not listed: exits 1, says so" "1/yes" "$rc/$(has "$out" 'github: NOT listed')"
record "...matching the id whole, not a prefix or part" "no" "$(has "$out" 'github: listed')"
record "...asks the repository's list for a repository URL" "1" "$(gh_calls 'repos/acme/app/actions/runners')"
record "...with the way to register it again, under its old name" "yes" "$(has "$out" 'uninstall --instance homefield --keep-vm, then bin/homefield install --instance homefield --url https://github.com/acme/app --name my-mac-homefield, with the --label and --group of the first install')"
record "...and reports the rest" "yes/yes/yes/yes" "$(rest)"
status GH_FAIL=0 GH_IDS='' SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n42\n'
record "an empty list is not listed either" "1/yes" "$rc/$(has "$out" 'github: NOT listed')"
status GH_FAIL=1 SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n42\n'
record "gh fails: not checked, exit unchanged" "0/yes/no" "$rc/$(has "$out" 'github: not checked')/$(has "$out" 'NOT listed')"
record "...and no scope refresh is offered" "0" "$(gh_calls offer_scope_refresh)"
status GH_FAIL=0 GH_IDS='42\n' GH_SLEEP=1 HOMEFIELD_GH_TIMEOUT=1 SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n42\n'
record "gh stalls past the timeout: killed, not checked, exit unchanged (#103)" "0/yes/no" "$rc/$(has "$out" 'github: not checked (timed out after 1s')/$(has "$out" 'github: listed')"
record "...and the rest is still answered from the VM" "yes/yes/yes/yes" "$(rest)"
status GH_FAIL=0 GH_IDS='42\n' SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n'
record "no id read: not checked, saying why, gh not called" "0/yes/0" "$rc/$(has "$out" "github: not checked (no runner id in the VM's settings)")/$(gh_calls 'gh ')"
status GH_FAIL=0 GH_IDS='' JOB_RC=2 SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n42\n'
record "not listed and the job probe cannot ask: exits 1" "1/yes" "$rc/$(has "$out" 'job: unknown')"

# The npm probe's guest command is answered by a stub above, so a malformed
# command would pass every assertion and only fail on a real VM. Parse the
# command npm_state would actually send (the #111 review found exactly that
# break: an unmatched quote every stubbed run missed).
echo "the npm probe's guest command parses:"
cat >"$work/npm-harness.sh" <<EOF
HOMEFIELD_SOURCE_ONLY=1
. "$ROOT/bin/homefield"
guest() { printf '%s' "\$3" >"$work/npm-guest-cmd"; echo ok; }
npm_state >/dev/null
EOF
bash "$work/npm-harness.sh"
sh -n "$work/npm-guest-cmd"
record "sh -n accepts it" "0" "$?"

# runner_setting itself, on a .runner without one of the keys: the others
# still come back, the missing one as an empty line.
printf '\xef\xbb\xbf{"agentName": "my-mac-homefield", "gitHubUrl": "https://github.com/acme"}' >"$work/.runner"
# shellcheck disable=SC2016  # expanded by the inner bash
settings="$(HOMEFIELD_SOURCE_ONLY=1 bash -c '. "$1"; RUNNER_HOME="$2"; guest() { shift; "$@"; }; runner_setting agentName gitHubUrl agentId | tr "\n" "|"' _ "$ROOT/bin/homefield" "$work" 2>&1)"
record "runner_setting: a missing key is an empty line, not a failure" "my-mac-homefield|https://github.com/acme||" "$settings"

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

status JOB_RC=0 SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n'
record "a job is running: says so" "0/yes" "$rc/$(has "$out" 'job: running')"
status JOB_RC=2 SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n'
record "the job probe cannot ask: says unknown, not idle, and exits 1" "1/yes/no" "$rc/$(has "$out" 'job: unknown')/$(has "$out" 'job: idle')"
record "...after the rest of the report" "yes/yes" "$(has "$out" 'service: running')/$(has "$out" 'runner version: 2.338.0')"

# The runner's bundled npm (#110): ok, BROKEN when even the hook's repair did
# not hold (the next jobs then fail at "Set up runner"), or unknown.
echo "npm (#110):"
status SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n42\n'
record "npm runs: says ok, exit unchanged" "0/yes" "$rc/$(has "$out" 'npm: ok')"
status NPM_RC=1 SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n42\n'
record "npm broken: says so, with the way out, and exits 1" "1/yes/yes" "$rc/$(has "$out" 'npm: BROKEN')/$(has "$out" 'Runner updates')"
status NPM_RC=2 SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n42\n'
record "the npm probe cannot ask: says unknown and exits 1" "1/yes" "$rc/$(has "$out" 'npm: unknown')"

status REG_RC=1
record "not registered: exits 0 and says so" "0/yes/no" "$rc/$(has "$out" 'runner: not registered')/$(has "$out" 'service:')"

status REG_RC=2
record "the VM cannot be asked: exits 1" "1" "$rc"
record "...says unknown, not that it is unregistered, and stops there" "yes/no/no" "$(has "$out" 'runner: unknown')/$(has "$out" 'not registered')/$(has "$out" 'service:')"

summary
