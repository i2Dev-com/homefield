#!/usr/bin/env bash
# The #18 host-loopback probe (verify_loopback) and the version gate
# (lima_at_least) in bin/homefield. bin/homefield is sourced
# (HOMEFIELD_SOURCE_ONLY=1) with a stub limactl answering for the guest and a
# stub nc standing in for the Mac's listener; the VM's stored config is a
# file under a temp HOME. Nothing reaches a VM or the network, and the real
# nc is never used (the stub PATH has only what a probe needs).
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
# limactl: the version under test (LIMA_VER) and the guest's answer to the
# probe (PROBE_ANSWER, what the guest script printed), or a call that never
# reaches the guest (PROBE_GUEST_FAIL).
cat >"$stubs/limactl" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "limactl version ${LIMA_VER:-2.2.0}" ;;
  shell)
    [ -z "${PROBE_GUEST_FAIL:-}" ] || { echo "limactl: could not connect" >&2; exit 1; }
    printf '%s\n' "${PROBE_ANSWER:-closed-1}"
    ;;
esac
EOF
# nc: listener mode sleeps (the probe kills it); a connect answers what the
# bind managed (NC_BIND_FAIL: nothing reaches the listener, so the self-test
# fails and the probe must skip, not read the silence as closed). NC_NO_K:
# the connect kills the listener, as an nc without -k dies with the
# connection it served — the probe must notice before trusting a closed.
cat >"$stubs/nc" <<'EOF'
#!/bin/sh
case " $* " in
  *" -l "*)
    # The stub IS the listener: its own pid in the file (atomically, so a
    # reader never sees it half-written), then exec sleep to keep that pid
    # alive as the process the killer must stop. No re-spawned sh: the
    # probe's stub PATH is a chosen minimal set and may not contain one.
    echo "$$" > "$NC_PIDFILE.tmp.$$"
    mv -f "$NC_PIDFILE.tmp.$$" "$NC_PIDFILE"
    exec sleep 30
    ;;
  *)
    if [ -n "${NC_NO_K:-}" ]; then
      # The first connect is served (and kills the listener); further ones
      # find no pidfile and fail, as they do against a real dead port.
      i=0
      while [ ! -f "$NC_PIDFILE" ] && [ "$i" -lt 100 ]; do sleep 0.01; i=$((i + 1)); done
      if [ -f "$NC_PIDFILE" ]; then
        kill "$(cat "$NC_PIDFILE")" 2>/dev/null
        rm -f "$NC_PIDFILE"
        exit 0
      fi
      exit 1
    fi
    [ -z "${NC_BIND_FAIL:-}" ] && exit 0 || exit 1
    ;;
esac
EOF
chmod +x "$stubs/limactl" "$stubs/nc"
# cat/mv/rm are used by the nc stub itself, awk/dirname/grep/sleep by the
# code under test; a missing tool there would hide as a silent failure.
for t in awk cat dirname grep mv rm sleep; do ln -s "$(command -v "$t")" "$stubs/$t"; done

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
    [ -d "$path" ] || { mkdir -p "$path"; for t in awk cat dirname grep mv rm sleep limactl; do ln -s "$stubs/$t" "$path/$t"; done; }
  fi
  rm -f "$work/nc.pid"
  # shellcheck disable=SC2016  # the -c script is expanded by the inner bash
  out="$(env -i HOME="$work/home" PATH="$path" NC_PIDFILE="$work/nc.pid" HOMEFIELD_SOURCE_ONLY=1 "${envs[@]+"${envs[@]}"}" \
    "$BASH" -c '. "$1"; shift; "$@"' _ "$ROOT/bin/homefield" "${@:-verify_loopback}" 2>&1 </dev/null)"
  rc=$?
}

echo "loopback probe"

run_probe PROBE_ANSWER=closed-1 --
record "refused -> closed, and it passes" "0/yes" "$rc/$(has "$out" 'loopback probe: closed')"
run_probe PROBE_ANSWER=closed-113 --
record "host unreachable -> closed too" "0/yes" "$rc/$(has "$out" 'loopback probe: closed')"
run_probe PROBE_ANSWER=closed-124 --
record "a timeout -> closed (unreachable is unreachable)" "0/yes" "$rc/$(has "$out" 'loopback probe: closed')"

run_probe PROBE_ANSWER=open LIMA_VER=2.2.0 --
record "open on an old Lima: a warning naming the ignoring version" "0/yes/yes" \
  "$rc/$(has "$out" 'warning: #18: jobs in VM homefield can reach')/$(has "$out" 'Lima 2.2.0 ignores networkOpts.hostLoopback')"
record "...and it does not stop the run, nor claim a closed" "no" "$(has "$out" 'probe: closed')"

run_probe PROBE_ANSWER=open LIMA_VER=2.3.0 --
record "open although the config asks for the block, on a Lima that honours it: refused" "nonzero/yes" \
  "$(nonzero "$rc")/$(has "$out" 'although its config sets networkOpts.hostLoopback: false')"

set_config "$work/config-plain.yaml" homefield
run_probe PROBE_ANSWER=open LIMA_VER=2.3.0 --
record "open on a new Lima with a config that never asked: warned, not fatal" "0/yes" \
  "$rc/$(has "$out" 'does not ask Lima to block it')"
set_config "$work/config-allows.yaml" homefield
run_probe PROBE_ANSWER=open LIMA_VER=2.3.0 --
record "...an explicit hostLoopback: true is the same" "0/yes" \
  "$rc/$(has "$out" 'does not ask Lima to block it')"
set_config "$work/config-blocks.yaml" homefield

NO_NC=1 run_probe --
record "no nc: the probe skips itself and says the exposure stands" "0/yes/no" \
  "$rc/$(has "$out" 'probe skipped (no nc on PATH)')/$(has "$out" 'probe: closed')"

run_probe NC_BIND_FAIL=1 --
record "a listener nobody reaches: skipped, never read as closed" "0/yes/no" \
  "$rc/$(has "$out" 'probe skipped (nothing answered')/$(has "$out" 'probe: closed')"

run_probe NC_NO_K=1 PROBE_ANSWER=closed-1 --
record "a listener that dies with the self-test: skipped, never a false closed" "0/yes/no" \
  "$rc/$(has "$out" 'died after one connection')/$(has "$out" 'probe: closed')"

run_probe PROBE_GUEST_FAIL=1 --
record "the guest cannot be asked: no clear answer, never read as closed" "0/yes/no" \
  "$rc/$(has "$out" 'no clear answer from VM homefield (answer: none)')/$(has "$out" 'probe: closed')"

run_probe PROBE_ANSWER=tools --
record "a guest without the probe tools: no clear answer, not a false closed" "0/yes/no" \
  "$rc/$(has "$out" 'no clear answer from VM homefield')/$(has "$out" 'probe: closed')"

run_probe PROBE_ANSWER='can of beans' --
record "a garbled answer: no clear answer, quoting it" "0/yes" \
  "$rc/$(has "$out" 'no clear answer from VM homefield (answer: can of beans)')"

# The config read is the one under the instance's own name.
set_config "$work/config-plain.yaml" other
run_probe PROBE_ANSWER=open LIMA_VER=2.3.0 HOMEFIELD_INSTANCE=other --
record "the instance's own config decides, not homefield's" "0/yes" \
  "$rc/$(has "$out" 'does not ask Lima to block it')"
run_probe PROBE_ANSWER=open LIMA_VER=2.3.0 HOMEFIELD_INSTANCE=missing-vm --
record "an instance whose config cannot be read: warned, never fatal" "0/yes" \
  "$rc/$(has "$out" 'does not ask Lima to block it')"

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
