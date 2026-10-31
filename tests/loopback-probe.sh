#!/usr/bin/env bash
# The #18 host-loopback probe (verify_loopback) and the version gate
# (lima_at_least) in bin/homefield. bin/homefield is sourced
# (HOMEFIELD_SOURCE_ONLY=1) with a stub limactl, a stub nc standing in for
# the Mac's listener, and — for most cases — LIMA_RUN_GUEST, which makes the
# stub limactl run the real guest probe script locally against a stub
# timeout/bash, so the guest-side classification (refused vs unresolved vs
# open) is itself under test, not a canned answer. The VM's stored config is
# a file under a temp HOME. Nothing reaches a VM or the network: the stub nc
# never binds or connects, and no /dev/tcp connect is ever attempted (bash
# is stubbed before that).
#
# Run:  bash tests/loopback-probe.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
nonzero() { [ "$1" -ne 0 ] && echo nonzero || echo "$1"; }

stubs="$work/stubs"
mkdir -p "$stubs" "$work/home/.lima/homefield"
# limactl: the version under test (LIMA_VER); the guest is asked by
# `limactl shell ... sh -c <script> sh <port>` — LIMA_RUN_GUEST execs that
# script for real here (against the stub timeout/bash), otherwise the answer
# is canned (PROBE_ANSWER); PROBE_GUEST_FAIL is the call never landing.
cat >"$stubs/limactl" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "limactl version ${LIMA_VER:-2.2.0}" ;;
  shell)
    [ -z "${PROBE_GUEST_FAIL:-}" ] || { echo "limactl: could not connect" >&2; exit 1; }
    if [ -n "${LIMA_RUN_GUEST:-}" ]; then
      while [ "$#" -gt 0 ]; do
        if [ "$1" = sh ] && [ "$2" = -c ]; then exec "$1" "$2" "$3" "$4" "$5"; fi
        shift
      done
      exit 9
    fi
    printf '%s\n' "${PROBE_ANSWER:-closed-1}"
    ;;
esac
EOF
# nc: a listener records its pid and sits (a real nc holds the port and
# serves its stdin; the token is answered from here instead). Connects
# answer what the listener would: the probe's token while it holds the
# port. NC_ANSWER replaces that answer (another service holds the port);
# NC_BIND_FAIL answers nothing at all (our bind never happened because the
# port was taken); NC_NO_K serves the token on the first connect and then
# dies with it, as an nc without -k does — the probe must notice the dead
# listener instead of reading its silence as closed.
cat >"$stubs/nc" <<'EOF'
#!/bin/sh
case " $* " in
  *" -l "*)
    if [ -n "${NC_BIND_LOST:-}" ]; then
      # The port was already taken: a real nc says so and is gone. (The
      # foreign holder stays quiet here, so the token loop can only see
      # silence; the report is what the probe must find.)
      echo "nc: Connect to 127.0.0.1 port $6: Address already in use" >&2
      exit 1
    fi
    # The stub IS the listener: its own pid in the file (atomically, so a
    # reader never sees it half-written), then exec sleep to keep that pid
    # alive as the process the killer must stop. No re-spawned sh: the
    # probe's stub PATH is a chosen minimal set and may not contain one.
    printf '%s\n' "$$" >"$NC_PIDFILE.tmp.$$"
    mv -f "$NC_PIDFILE.tmp.$$" "$NC_PIDFILE"
    exec sleep 30
    ;;
  *)
    [ -z "${NC_BIND_FAIL:-}${NC_BIND_LOST:-}" ] || exit 1
    if [ -n "${NC_NO_K:-}" ]; then
      i=0
      while [ ! -f "$NC_PIDFILE" ] && [ "$i" -lt 100 ]; do sleep 0.01; i=$((i + 1)); done
      if [ -f "$NC_PIDFILE" ]; then
        printf '%s' "${NC_ANSWER-${HOMEFIELD_PROBE_TOKEN:-}}"
        kill "$(cat "$NC_PIDFILE")" 2>/dev/null
        rm -f "$NC_PIDFILE"
        exit 0
      fi
      exit 1
    fi
    printf '%s' "${NC_ANSWER-${HOMEFIELD_PROBE_TOKEN:-}}"
    ;;
esac
EOF
# timeout: the duration buys nothing here; run the command.
cat >"$stubs/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
# bash: the guest's /dev/tcp connect, canned by PROBE_BASH. The messages
# are bash's own words (verified against a real guest): status 1 covers a
# refusal AND an unresolved name, which is why the probe greps for the one.
cat >"$stubs/bash" <<'EOF'
#!/bin/sh
case "${PROBE_BASH:-open}" in
  open)    exit 0 ;;
  refused) echo "bash: connect: Connection refused" >&2; exit 1 ;;
  dnsfail)
    echo "bash: line 1: host.lima.internal: Name or service not known" >&2
    echo "bash: line 1: /dev/tcp/host.lima.internal/x: Invalid argument" >&2
    exit 1 ;;
  noroute) echo "bash: connect: No route to host" >&2; exit 1 ;;
  hang)    exit 124 ;;   # what coreutils timeout reports when it killed the connect
  boom)    exit 137 ;;
esac
exit 137
EOF
chmod +x "$stubs/limactl" "$stubs/nc" "$stubs/timeout" "$stubs/bash"
# cat/mv/rm are used by the nc stub itself, mktemp/awk/dirname/grep/sleep
# by the code under test, sh/timeout/bash by a run-guest script; a missing
# tool would hide as a silent failure.
for t in awk cat dirname grep mktemp mv rm sleep sh; do ln -s "$(command -v "$t")" "$stubs/$t"; done

# The VM's stored config, as limactl create writes it under ~/.lima/<name>/.
cat >"$work/config-blocks.yaml" <<'EOF'
vmType: vz
networkOpts:
  hostLoopback: false
EOF
cat >"$work/config-plain.yaml" <<'EOF'
vmType: vz
EOF
cat >"$work/config-allows.yaml" <<'EOF'
vmType: vz
networkOpts:
  hostLoopback: true
EOF
cp "$work/config-blocks.yaml" "$work/home/.lima/homefield/lima.yaml"

# set_config <file> <name>: what the VM <name> (<name> is read by
# HOMEFIELD_INSTANCE) has stored as its instance config.
set_config() {
  mkdir -p "$work/home/.lima/$2"
  cp "$1" "$work/home/.lima/$2/lima.yaml"
}

# run_probe [VAR=value ...] -- [function]: source-only run with no terminal.
# NO_NC/NO_TOOLS shed nc / timeout from the PATH the probe sees.
run_probe() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  local path="$stubs"
  if [ -n "${NO_NC:-}" ]; then
    path="$work/no-nc"
    [ -d "$path" ] || { mkdir -p "$path"; for t in awk bash cat dirname grep limactl mktemp mv rm sh sleep timeout; do ln -s "$stubs/$t" "$path/$t"; done; }
  fi
  if [ -n "${NO_TOOLS:-}" ]; then
    path="$work/no-timeout"
    [ -d "$path" ] || { mkdir -p "$path"; for t in awk bash cat dirname grep limactl mktemp mv nc rm sh sleep; do ln -s "$stubs/$t" "$path/$t"; done; }
  fi
  rm -f "$work/nc.pid"
  # shellcheck disable=SC2016  # the -c script is expanded by the inner bash
  out="$(env -i HOME="$work/home" PATH="$path" NC_PIDFILE="$work/nc.pid" \
    HOMEFIELD_PROBE_TOKEN=probe-token HOMEFIELD_SOURCE_ONLY=1 "${envs[@]+"${envs[@]}"}" \
    "$BASH" -c '. "$1"; shift; "$@"' _ "$ROOT/bin/homefield" "${@:-verify_loopback}" 2>&1 </dev/null)"
  rc=$?
}

echo "loopback probe: the guest-side classification (the real script, a stubbed connect)"

run_probe LIMA_RUN_GUEST=1 PROBE_BASH=refused --
record "a refused connect is the only closed-1, and it passes" "0/yes" "$rc/$(has "$out" 'loopback probe: closed')"
run_probe LIMA_RUN_GUEST=1 PROBE_BASH=hang --
record "the 3 s connect timeout is closed too" "0/yes" "$rc/$(has "$out" 'loopback probe: closed')"
run_probe LIMA_RUN_GUEST=1 PROBE_BASH=dnsfail --
record "an unresolved name is not a closed (same status 1, review #135 P1)" "0/yes/no" \
  "$rc/$(has "$out" 'no clear answer from VM homefield (answer: unknown-1)')/$(has "$out" 'probe: closed')"
run_probe LIMA_RUN_GUEST=1 PROBE_BASH=noroute --
record "no route to host is not a closed either" "0/yes/no" \
  "$rc/$(has "$out" 'no clear answer from VM homefield (answer: unknown-1)')/$(has "$out" 'probe: closed')"
run_probe LIMA_RUN_GUEST=1 PROBE_BASH=boom --
record "an unexpected status is no clear answer" "0/yes/no" \
  "$rc/$(has "$out" 'no clear answer from VM homefield (answer: unknown-137)')/$(has "$out" 'probe: closed')"
NO_TOOLS=1 run_probe LIMA_RUN_GUEST=1 --
record "a guest without the probe tools: no clear answer, not a false closed" "0/yes/no" \
  "$rc/$(has "$out" 'no clear answer from VM homefield (answer: tools)')/$(has "$out" 'probe: closed')"

echo "loopback probe: the host side (a stubbed listener owns the port, token proven)"

run_probe LIMA_RUN_GUEST=1 PROBE_BASH=open LIMA_VER=2.2.0 --
record "open on an old Lima: a warning naming the ignoring version" "0/yes/yes" \
  "$rc/$(has "$out" 'warning: #18: jobs in VM homefield can reach')/$(has "$out" 'Lima 2.2.0 ignores networkOpts.hostLoopback')"
record "...and it does not stop the run, nor claim a closed" "no" "$(has "$out" 'probe: closed')"

run_probe LIMA_RUN_GUEST=1 PROBE_BASH=open LIMA_VER=2.3.0 --
record "open although the config asks for the block, on a Lima that honours it: refused" "nonzero/yes" \
  "$(nonzero "$rc")/$(has "$out" 'although its config sets networkOpts.hostLoopback: false')"

set_config "$work/config-plain.yaml" homefield
run_probe LIMA_RUN_GUEST=1 PROBE_BASH=open LIMA_VER=2.3.0 --
record "open on a new Lima with a config that never asked: warned, not fatal" "0/yes" \
  "$rc/$(has "$out" 'does not show networkOpts.hostLoopback: false')"
set_config "$work/config-allows.yaml" homefield
run_probe LIMA_RUN_GUEST=1 PROBE_BASH=open LIMA_VER=2.3.0 --
record "...an explicit hostLoopback: true is the same" "0/yes" \
  "$rc/$(has "$out" 'does not show networkOpts.hostLoopback: false')"
set_config "$work/config-blocks.yaml" homefield

NO_NC=1 run_probe --
record "no nc: the probe skips itself and says the exposure stands" "0/yes/no" \
  "$rc/$(has "$out" 'probe skipped (no nc on PATH)')/$(has "$out" 'probe: closed')"

run_probe NC_BIND_FAIL=1 --
record "a port that answers nothing (bind lost): skipped, never read as closed" "0/yes/no" \
  "$rc/$(has "$out" 'probe skipped (nothing answered')/$(has "$out" 'probe: closed')"

run_probe NC_BIND_LOST=1 --
record "the listener itself reports the port was taken: named, not guessed" "0/yes/yes/no" \
  "$rc/$(has "$out" 'already taken: the probe')/$(has "$out" 'could not bind it')/$(has "$out" 'probe: closed')"

run_probe NC_ANSWER=some-other-service --
record "a foreign answer on the port is not the probe's listener (review #135 P2)" "0/yes/no" \
  "$rc/$(has "$out" 'answered, but not with the token: another service holds the port')/$(has "$out" 'probe: closed')"

run_probe NC_NO_K=1 LIMA_RUN_GUEST=1 PROBE_BASH=refused --
record "a listener that dies with the self-test: skipped, never a false closed" "0/yes/no" \
  "$rc/$(has "$out" 'died after one connection')/$(has "$out" 'probe: closed')"

run_probe PROBE_GUEST_FAIL=1 --
record "the guest cannot be asked: no clear answer, never read as closed" "0/yes/no" \
  "$rc/$(has "$out" 'no clear answer from VM homefield (answer: none)')/$(has "$out" 'probe: closed')"

run_probe PROBE_ANSWER='can of beans' --
record "a garbled answer: no clear answer, quoting it" "0/yes" \
  "$rc/$(has "$out" 'no clear answer from VM homefield (answer: can of beans)')"
run_probe PROBE_ANSWER=closed-113 --
record "a status the guest script cannot print is still no clear answer" "0/yes/no" \
  "$rc/$(has "$out" 'no clear answer from VM homefield (answer: closed-113)')/$(has "$out" 'probe: closed')"

# The config read is the one under the instance's own name.
set_config "$work/config-plain.yaml" other
run_probe LIMA_RUN_GUEST=1 PROBE_BASH=open LIMA_VER=2.3.0 HOMEFIELD_INSTANCE=other --
record "the instance's own config decides, not homefield's" "0/yes" \
  "$rc/$(has "$out" 'does not show networkOpts.hostLoopback: false')"
run_probe LIMA_RUN_GUEST=1 PROBE_BASH=open LIMA_VER=2.3.0 HOMEFIELD_INSTANCE=missing-vm --
record "an instance whose config cannot be read: warned, never fatal" "0/yes" \
  "$rc/$(has "$out" 'does not show networkOpts.hostLoopback: false')"

echo "lima_at_least"
version_case() {
  local want="$1" ver="$2" major="$3" minor="$4" got
  # shellcheck disable=SC2016  # the -c script is expanded by the inner bash
  got="$(env -i HOME="$work/home" PATH="$stubs" HOMEFIELD_SOURCE_ONLY=1 LIMA_VER="$ver" \
    "$BASH" -c '. "$1"; lima_at_least "$2" "$3" && echo yes || echo no' _ "$ROOT/bin/homefield" "$major" "$minor" 2>&1)"
  record "Lima $ver >= $major.$minor: $want" "$want" "$got"
}
version_case yes 2.3.0 2 3
version_case no 2.2.0 2 3
version_case yes 2.10.0 2 3
version_case yes 3.0.0 2 3
version_case no garbage 2 3

summary
