#!/usr/bin/env bash
# tests/status-json.sh — `homefield status --json`, the machine-readable form
# of the status report, and the human form it must not disturb.
#
# The real bin/homefield runs, through main, with a PATH that holds only stubs
# (limactl, gh, pgrep, ...): nothing reaches a VM, GitHub or the real machine.
# The limactl stub is the guest: the probes status makes (test -f, the job
# probe, the npm probe, the package list) are the code's own scripts, executed
# here against a temp directory standing in for the guest's file system. gh
# answers the rows its --jq filter would produce. The JSON form is parsed with
# the host's python3, so a syntactically invalid report cannot pass.
#
# Run:  bash tests/status-json.sh
# Exit: 0 when every case passes, 1 otherwise.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

BASH_BIN="$(command -v bash)"
stubs="$work/stubs"
calls="$work/calls"
root="$work/guest"
home="$work/home"
mkdir -p "$stubs" "$home"
: >"$calls"

for t in awk cat dirname grep mktemp rm sh sleep tr; do ln -s "$(command -v "$t")" "$stubs/$t"; done

# A Lima listing the instance when LIMA_STATUS is set, and a second VM when
# LIMA_SECOND is set. `shell` is the guest: see the header.
cat >"$stubs/limactl" <<'EOF'
#!/bin/sh
echo "limactl $*" >>"$CALLS"
case "$1" in
  --version) echo "limactl version 2.3.0" ;;
  list)
    if [ -n "${LIMA_LIST_FAIL:-}" ]; then echo "limactl: list failed" >&2; exit 1; fi
    [ -z "${LIMA_STATUS:-}" ] || echo "homefield ${LIMA_STATUS}"
    [ -z "${LIMA_SECOND:-}" ] || echo "${LIMA_SECOND} Running"
    ;;
  start | stop | create | delete | edit) echo "limactl stub: $1 must never be called by status" >&2; exit 98 ;;
  shell)
    shift 4
    [ "$1" != sudo ] || shift
    case "$1" in
      sh)
        script="$3"
        case "$script" in
          *'test -f'*)
            if [ -n "${LIMA_SHELL_FAIL:-}" ]; then echo "limactl: could not connect" >&2; exit 1; fi
            exec sh -c "$script" sh "$FAKE_ROOT$5"
            ;;
          *'pgrep -f'*) exec sh -c "$script" sh ;;
          *extra-packages*)
            if [ -n "${LIMA_PKGS_FAIL:-}" ]; then echo "limactl: could not connect" >&2; exit 1; fi
            printf '%s' "${GUEST_PKGS-}" ;;
          *node20*) echo "${NPM_OUT:-ok}" ;;
          *) echo "limactl stub: unexpected sh -c: $script" >&2; exit 99 ;;
        esac
        ;;
      python3) printf '%b' "${SETTING_OUT-}" ;;
      cat) exec cat "$FAKE_ROOT$2" ;;
      systemctl) exit "${SVC_ACTIVE:-0}" ;;
      *) echo "limactl stub: unexpected guest command: $*" >&2; exit 99 ;;
    esac
    ;;
esac
EOF
# gh answers the rows the code's --jq filters would produce: the runners
# GitHub lists (GH_RUNNERS: id, status, busy). GH_SLEEP=1 black-holes the call.
cat >"$stubs/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$CALLS"
case "$*" in
  "auth status --json hosts"*) echo "${GH_JQ_OUT-stub-user|admin:org, repo}" ;;
  *"/actions/runners?"*)
    if [ -n "${GH_SLEEP:-}" ]; then sleep 3; fi
    [ -z "${GH_RUNNERS_FAIL:-}" ] || exit 1
    printf '%b' "${GH_RUNNERS-}"
    ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 99 ;;
esac
EOF
# The job probe: pgrep's exit code decides running (0) or idle (1); any other
# failure leaves the probe's case with no answer, which is "unknown".
cat >"$stubs/pgrep" <<'EOF'
#!/bin/sh
exit "${JOB_EXIT:-1}"
EOF
chmod +x "$stubs/limactl" "$stubs/gh" "$stubs/pgrep"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
nonzero() { [ "$1" -ne 0 ] && echo nonzero || echo "$1"; }

# guest_fs [registered|unregistered]: the guest's file system under $root. A
# registered runner has .runner, a service name and a version.
guest_fs() {
  rm -rf "$root"
  mkdir -p "$root/opt/actions-runner"
  if [ "${1:-registered}" = registered ]; then
    echo '{}' >"$root/opt/actions-runner/.runner"
    printf '%s' 'actions.runner.acme.test.service' >"$root/opt/actions-runner/.service"
    printf '%s' '2.338.0' >"$root/opt/actions-runner/.provisioned-version"
  fi
}

settings='my-mac-homefield\nhttps://github.com/acme\n42\n'
# One run of status with the stubs as PATH: out (stdout), err (stderr), rc.
# stat [VAR=value ...] -- [status arguments]
stat() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"$calls"
  out="$(env -i HOME="$home" PATH="$stubs" CALLS="$calls" FAKE_ROOT="$root" HOMEFIELD_GH_TIMEOUT=2 \
    LIMA_STATUS=Running SETTING_OUT="$settings" GH_RUNNERS='42\tonline\tfalse\n' \
    "${envs[@]+"${envs[@]}"}" \
    "$BASH_BIN" "$ROOT/bin/homefield" status "$@" 2>"$work/err" </dev/null)"
  rc=$?
  err="$(cat "$work/err")"
}

# json_field <json> <python expression on d>: evaluate a field of the parsed
# object, so a malformed report fails loudly instead of matching by luck.
json_field() {
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); e=sys.argv[2]; print(eval(e, {"d": d}))' "$1" "$2" 2>/dev/null
}

healthy=(GH_RUNNERS='42\tonline\tfalse\n' GUEST_PKGS='libpq-dev ' JOB_EXIT=1)

# ── the healthy single VM ────────────────────────────────────────────────────
guest_fs registered
stat "${healthy[@]}" -- --instance homefield --json
record "healthy: exits 0" "0" "$rc"
record "healthy: stdout is JSON only" "yes/no" "$(has "$out" '"instance": "homefield"')/$(has "$out" 'VM homefield:')"
record "healthy: parses, healthy true" "True/True" "$(json_field "$out" 'd["healthy"]')/$(json_field "$out" 'd["vm"]["status"] == "Running"')"
record "healthy: registered, with the runner's details" "True/my-mac-homefield/42" \
  "$(json_field "$out" 'd["registered"]')/$(json_field "$out" 'd["runner"]["name"]')/$(json_field "$out" 'd["runner"]["id"]')"
record "healthy: on_github listed online, service running, job idle" "listed/online/running/idle" \
  "$(json_field "$out" 'd["on_github"]["state"]')/$(json_field "$out" 'd["on_github"]["status"]')/$(json_field "$out" 'd["service"]["state"]')/$(json_field "$out" 'd["job"]["state"]')"
record "healthy: version, npm, extra packages as an array" "2.338.0/ok/['libpq-dev']" \
  "$(json_field "$out" 'd["version"]')/$(json_field "$out" 'd["npm"]')/$(json_field "$out" 'd["extra_packages"]')"

# ── the human form is unchanged ──────────────────────────────────────────────
stat "${healthy[@]}" -- --instance homefield
record "human: exits 0" "0" "$rc"
want='VM homefield: Running
runner: my-mac-homefield, registered at https://github.com/acme
github: listed
service: running
job: idle
runner version: 2.338.0
npm: ok
extra packages: libpq-dev 
labels: see https://github.com/organizations/acme/settings/actions/runners (not stored in the VM)'
record "human: the report, line for line" "yes" "$( [ "$out" = "$want" ] && echo yes || echo no )"

# ── the unhealthy answers ────────────────────────────────────────────────────
stat "${healthy[@]}" JOB_EXIT=0 -- --instance homefield --json
record "job running: state running, still healthy, exit 0" "running/True/0" \
  "$(json_field "$out" 'd["job"]["state"]')/$(json_field "$out" 'd["healthy"]')/$rc"

stat "${healthy[@]}" NPM_OUT=broken -- --instance homefield --json
record "npm broken: broken, unhealthy, exit 1" "broken/False/1" \
  "$(json_field "$out" 'd["npm"]')/$(json_field "$out" 'd["healthy"]')/$rc"

stat "${healthy[@]}" NPM_OUT=garbage -- --instance homefield --json
record "npm unknown: unknown, unhealthy, exit 1" "unknown/False/1" \
  "$(json_field "$out" 'd["npm"]')/$(json_field "$out" 'd["healthy"]')/$rc"

stat "${healthy[@]}" GH_RUNNERS='43\tonline\tfalse\n' -- --instance homefield --json
record "runner not listed: not_listed, unhealthy, exit 1" "not_listed/False/1" \
  "$(json_field "$out" 'd["on_github"]["state"]')/$(json_field "$out" 'd["healthy"]')/$rc"

stat "${healthy[@]}" GH_SLEEP=1 -- --instance homefield --json
record "gh times out: timeout, healthy (unproven is not unhealthy), exit 0" "timeout/True/0" \
  "$(json_field "$out" 'd["on_github"]["state"]')/$(json_field "$out" 'd["healthy"]')/$rc"

stat "${healthy[@]}" SVC_ACTIVE=3 -- --instance homefield --json
record "service down: not_running with its unit; the ask answered, so exit 0" "not_running/actions.runner.acme.test.service/True/0" \
  "$(json_field "$out" 'd["service"]["state"]')/$(json_field "$out" 'd["service"]["unit"]')/$(json_field "$out" 'd["healthy"]')/$rc"

stat "${healthy[@]}" LIMA_SHELL_FAIL=1 -- --instance homefield --json
record "the VM cannot be asked: unhealthy, exit 1, no runner" "1/False/None" \
  "$rc/$(json_field "$out" 'd["healthy"]')/$(json_field "$out" 'd["registered"]')"

stat "${healthy[@]}" LIMA_PKGS_FAIL=1 -- --instance homefield --json
record "the packages probe fails: the report still renders, empty list" "[]/True/0" \
  "$(json_field "$out" 'd["extra_packages"]')/$(json_field "$out" 'd["healthy"]')/$rc"

guest_fs unregistered
stat "${healthy[@]}" -- --instance homefield --json
record "unregistered: registered false, healthy, exit 0" "False/True/0" \
  "$(json_field "$out" 'd["registered"]')/$(json_field "$out" 'd["healthy"]')/$rc"

stat "${healthy[@]}" LIMA_STATUS= -- --instance homefield --json
record "not created: created false, healthy, exit 0" "False/True/0" \
  "$(json_field "$out" 'd["vm"]["created"]')/$(json_field "$out" 'd["healthy"]')/$rc"

stat "${healthy[@]}" LIMA_LIST_FAIL=1 -- --instance homefield --json
record "lima cannot be asked: status null, unhealthy, exit 1" "None/False/1" \
  "$(json_field "$out" 'd["vm"]["status"]')/$(json_field "$out" 'd["healthy"]')/$rc"

# ── option handling ──────────────────────────────────────────────────────────
stat "${healthy[@]}" -- --instance homefield --json --bogus
record "unknown option: refused, naming it" "nonzero/yes" "$(nonzero "$rc")/$(has "$err" 'status: unknown option --bogus')"

# ── every VM on the Mac ──────────────────────────────────────────────────────
guest_fs registered
mkdir -p "$home/.lima/homefield" "$home/.lima/second"
printf '%s\n' '# Lima VM for the local GitHub Actions runner.' >"$home/.lima/homefield/lima.yaml"
printf '%s\n' '# Lima VM for the local GitHub Actions runner.' >"$home/.lima/second/lima.yaml"

stat "${healthy[@]}" LIMA_SECOND=second -- --json
record "two VMs: the wrapper, both listed" "yes/yes/2" \
  "$(has "$out" '"instances": ["homefield", "second"]')/$(has "$out" '"healthy"')/$(json_field "$out" 'len(d["vms"])')"
record "two VMs: healthy, exit 0" "True/0" "$(json_field "$out" 'd["healthy"]')/$rc"

stat "${healthy[@]}" LIMA_SECOND=second NPM_OUT=broken -- --json
record "two VMs, one broken: wrapper unhealthy, exit 1" "False/1" "$(json_field "$out" 'd["healthy"]')/$rc"

stat "${healthy[@]}" LIMA_SECOND=second --
record "two VMs, human: two blocks, no JSON" "yes/no/0" \
  "$(has "$out" 'VM second: Running')/$(has "$out" '"vms"')/$rc"

# One VM under a non-default name, no --instance: the report is about THAT VM
# (vm_dispatch assigned the discovered name; the default name's "not created"
# must not stand in for it).
mkdir -p "$home/.lima/codesamplez"
printf '%s\n' '# Lima VM for the local GitHub Actions runner.' >"$home/.lima/codesamplez/lima.yaml"
rm -rf "$home/.lima/second"
stat "${healthy[@]}" LIMA_SECOND=codesamplez LIMA_STATUS= --
record "one VM, non-default name: the discovered VM is reported" "yes/no/0" \
  "$(has "$out" 'VM codesamplez: Running')/$(has "$out" 'VM homefield: not created')/$rc"
stat "${healthy[@]}" LIMA_SECOND=codesamplez LIMA_STATUS= -- --json
record "one VM, non-default name: the JSON names it" "codesamplez/True/0" \
  "$(json_field "$out" 'd["instance"]')/$(json_field "$out" 'd["healthy"]')/$rc"

summary