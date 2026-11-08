#!/usr/bin/env bash
# Every VM on this Mac by default (#182): vm_instances finds HomeField's Lima
# instances (the stored lima.yaml carries the marker; other Lima VMs do not),
# vm_dispatch runs a command for each of them as its own process, and the
# destructive commands refuse to guess which VM was meant.
#
# The real bin/homefield is sourced in a subshell with limactl, vm_instances,
# instance_command and the guest helpers replaced by functions that answer from
# the environment: nothing reaches Lima, a VM or GitHub.
#
# Run:  bash tests/instances.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

harness="$work/harness.sh"
cat >"$harness" <<'EOF'
HOMEFIELD_SOURCE_ONLY=1
. "$ROOT/bin/homefield"
# The Lima list vm_instances asks for (LIMA_ROWS), or a failure.
limactl() {
  [ -z "${LIMA_LIST_FAIL:-}" ] || return 1
  printf '%b\n' "${LIMA_ROWS-}"
}
vm_status() { echo Running; }
check_host() { return 0; }
instance_command() {
  local name="$1"
  shift
  printf 'child %s: %s\n' "$name" "$*"
  return "${CHILD_RC:-0}"
}
fn() { printf 'one %s%s\n' "$INSTANCE" "${1:+ $*}"; return "${FN_RC:-0}"; }
case "$1" in
  vm_instances) shift; vm_instances ;;
  dispatch)
    shift
    EXPLICIT_INSTANCE="${EXPLICIT-0}"
    INSTANCE="${INSTANCE_NAME-homefield}"
    vm_instances() { printf '%b\n' "${NAMES-homefield}"; }
    # The flag that heads a memory block is visible to the child; show it.
    instance_command() {
      local name="$1"
      shift
      printf 'child %s%s: %s\n' "$name" "${HOMEFIELD_ONE_OF_MANY:+ (multi)}" "$*"
      return "${CHILD_RC:-0}"
    }
    vm_dispatch status fn "$@"
    ;;
  refuse)
    EXPLICIT_INSTANCE="${EXPLICIT-0}"
    INSTANCE="${INSTANCE_NAME-homefield}"
    vm_instances() { printf '%b\n' "${NAMES-homefield}"; }
    refuse_unnamed_vm "${CMD-uninstall}" >/dev/null
    ;;
  memory_bad_days) cmd_memory --days nope ;;
  upgrade_bad_option) cmd_upgrade --bogus ;;
  upgrade_bad_preset) cmd_upgrade --preset nope ;;
  env_explicit)
    # HOMEFIELD_INSTANCE is read at source time, so this case must not touch it.
    vm_instances() { printf '%b\n' "${NAMES-homefield}"; }
    vm_dispatch status fn
    ;;
  upgrade_registered)
    # install/setup's fallback on an already-registered instance upgrades that
    # VM only, even when the Mac has several (#182 review).
    EXPLICIT_INSTANCE=0
    INSTANCE=homefield
    vm_instances() { printf '%b\n' "${NAMES-homefield}"; }
    upgrade_single() { printf 'single %s %s\n' "$INSTANCE" "$*"; }
    instance_command() {
      local name="$1"
      shift
      printf 'child %s: %s\n' "$name" "$*"
    }
    upgrade_registered --packages xvfb
    echo "explicit=$EXPLICIT_INSTANCE"
    ;;
  start_many) EXPLICIT_INSTANCE=0; vm_instances() { printf '%b\n' "${NAMES-homefield}"; }; cmd_start ;;
  stop_many) EXPLICIT_INSTANCE=0; vm_instances() { printf '%b\n' "${NAMES-homefield}"; }; cmd_stop ;;
  uninstall_refuse)
    EXPLICIT_INSTANCE="${EXPLICIT-0}"
    INSTANCE="${INSTANCE_NAME-homefield}"
    vm_instances() { printf '%b\n' "${NAMES-homefield}"; }
    cmd_uninstall
    ;;
  reset_refuse)
    EXPLICIT_INSTANCE="${EXPLICIT-0}"
    INSTANCE="${INSTANCE_NAME-homefield}"
    vm_instances() { printf '%b\n' "${NAMES-homefield}"; }
    cmd_reset
    ;;
esac
EOF

# run <case> [VAR=value ...]: out (stdout and stderr), rc. The harness answers
# from the environment, so a case is one env(1) run with nothing else set.
run() {
  local name="$1"
  shift
  out="$(env -i PATH="$PATH" HOME="${HOME_DIR:-$work/home}" ROOT="$ROOT" "$@" bash "$harness" "$name" 2>&1 </dev/null)"
  rc=$?
}
lines_of() { printf '%s\n' "$out" | grep -c -e "$1" || true; }

mkdir -p "$work/home/.lima/marked" "$work/home/.lima/plain"
printf '%s\n' '# Lima VM for the local GitHub Actions runner.' >"$work/home/.lima/marked/lima.yaml"
printf '%s\n' 'other: config' >"$work/home/.lima/plain/lima.yaml"

echo "vm_instances: HomeField's VMs only, other Lima instances ignored"
run vm_instances HOME_DIR="$work/home" LIMA_ROWS='marked Running\nforeign Stopped\nhomefield Stopped'
record "the marked instance and the default name are listed, in Lima's order" \
  "marked
homefield" "$out"
run vm_instances HOME_DIR="$work/home" LIMA_ROWS='plain Running\nforeign Running'
record "...an unmarked config that is not the default name is left out" "" "$out"
run vm_instances HOME_DIR="$work/home" LIMA_LIST_FAIL=1
record "Lima cannot be asked: nothing printed, nonzero so callers take their own path" \
  "nonzero/" "$(case "$rc" in 0) echo zero ;; *) echo nonzero ;; esac)/$out"

echo "is_homefield_vm"
# is_marked <name>: yes when the function says it carries the header.
is_marked() {
  # shellcheck disable=SC2016  # expanded by the inner bash
  env -i PATH="$PATH" HOME="$work/home" HOMEFIELD_SOURCE_ONLY=1 "${BASH:-bash}" -c \
    '. "$1"; shift; is_homefield_vm "$@"' _ "$ROOT/bin/homefield" "$1" >/dev/null &&
    echo yes || echo no
}
record "a stored config with the header: yes" "yes" "$(is_marked marked)"
record "...without it: no" "no" "$(is_marked plain)"
# shellcheck disable=SC2016  # expanded by the inner bash, not here
record "...an instance that does not exist: no, and nothing printed" \
  "no/" "$(is_marked absent)/$(env -i PATH="$PATH" HOME="$work/home" HOMEFIELD_SOURCE_ONLY=1 "${BASH:-bash}" -c '. "$1"; is_homefield_vm nope' _ "$ROOT/bin/homefield" 2>&1)"

echo "vm_dispatch: one run per VM by default"
run dispatch NAMES=''
record "no VMs found: the single-instance path, for the default name" "0/one homefield" "$rc/$out"
run dispatch NAMES='codesamplez'
record "the only VM is not named homefield: it is the one reported" "0/one codesamplez" "$rc/$out"
run dispatch NAMES='homefield\ncodesamplez'
record "several VMs: each as its own process and told it is one of many" "yes/yes/in-order" \
  "$(has "$out" 'child homefield (multi): status')/$(has "$out" 'child codesamplez (multi): status')/$([ "$(printf '%s\n' "$out" | grep -n '^child' | cut -d: -f1 | paste -sd, -)" = "1,3" ] && echo in-order || echo out-of-order)"
record "...one blank line between them and exit 0" "1/0" "$(printf '%s\n' "$out" | grep -c '^$')/$rc"
run dispatch NAMES='homefield\ncodesamplez' CHILD_RC=1
record "...a failing run is reported, the rest still runs, exit 1" \
  "1/yes/yes" "$rc/$(has "$out" 'child homefield (multi): status')/$(has "$out" 'child codesamplez (multi): status')"
run dispatch NAMES='homefield\ncodesamplez' EXPLICIT=1 INSTANCE_NAME=codesamplez
record "--instance: that VM alone, even with several on the Mac" "0/one codesamplez" "$rc/$out"
run env_explicit NAMES='homefield\ncodesamplez' HOMEFIELD_INSTANCE=codesamplez
record "...HOMEFIELD_INSTANCE does the same, read when the tool starts" \
  "0/one codesamplez/no" "$rc/$out/$(has "$out" 'child ')"

echo "refuse_unnamed_vm: destructive commands never guess"
run refuse NAMES='homefield'
record "the default instance only: allowed" "0" "$rc"
run refuse NAMES='codesamplez' CMD=uninstall
record "one VM under another name: refused, naming it and --instance" \
  "1/yes/yes" "$rc/$(has "$out" 'this Mac has HomeField VMs (codesamplez)')/$(has "$out" 'with --instance <name>')"
run refuse NAMES='homefield\ncodesamplez' CMD=reset
record "...several: refused too, listing both" \
  "1/yes/yes" "$rc/$(has "$out" 'HomeField VMs (homefield, codesamplez)')/$(has "$out" 'reset:')"
run refuse NAMES='homefield\ncodesamplez' EXPLICIT=1 INSTANCE_NAME=codesamplez
record "...--instance always goes ahead" "0" "$rc"

echo "commands that validate once before any VM is asked"
run memory_bad_days NAMES='homefield\ncodesamplez'
record "memory --days nope: refused, no VM run started" "1/yes/no" \
  "$rc/$(has "$out" '--days must be a positive number')/$(has "$out" 'child ')"
run upgrade_bad_option NAMES='homefield\ncodesamplez'
record "upgrade --bogus: refused before any VM is stopped or asked" "1/yes/no" \
  "$rc/$(has "$out" 'unknown option --bogus')/$(has "$out" 'child ')"
run upgrade_bad_preset NAMES='homefield\ncodesamplez'
record "upgrade --preset nope: refused before any VM is stopped or asked" "1/yes/no" \
  "$rc/$(has "$out" 'nope')/$(has "$out" 'child ')"

run upgrade_registered NAMES='homefield\ncodesamplez'
record "install/setup's registered fallback: its own instance only, not both" \
  "single homefield --packages xvfb/0/no" \
  "$(printf '%s' "$out" | head -n 1)/$rc/$(has "$out" 'child ')"

echo "start and stop cover every VM by default"
run start_many NAMES='homefield\ncodesamplez'
record "start: one run per VM, each with its name and no options passed on" \
  "0/yes/yes/no" "$rc/$(has "$out" 'child homefield: start')/$(has "$out" 'child codesamplez: start')/$(has "$out" ': start --')"
run stop_many NAMES='homefield\ncodesamplez' CHILD_RC=1
record "...stop likewise; a refused VM makes the command exit 1 but does not skip the next" \
  "1/yes/yes" "$rc/$(has "$out" 'child homefield: stop')/$(has "$out" 'child codesamplez: stop')"

echo "uninstall and reset through their own parsers"
run uninstall_refuse NAMES='homefield\ncodesamplez'
record "uninstall with two VMs and no name: refused before anything is touched" \
  "1/yes/no" "$rc/$(has "$out" 'HomeField VMs (homefield, codesamplez)')/$(has "$out" 'deregistering')"
run reset_refuse NAMES='codesamplez'
record "reset with only a non-default VM: refused too" \
  "1/yes" "$rc/$(has "$out" 'HomeField VMs (codesamplez)')"

summary
