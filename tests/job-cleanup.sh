#!/usr/bin/env bash
# The per-job cleanup hook (#285): vm/guest/homefield-job-cleanup (what runs
# after every job when RUNNER_JOB_CLEANUP=1) and the plumbing that opts a VM
# into it — the runner's .env line, the saved switch in the guest, the host
# flags, and re-register keeping the switch.
#
# The guest script runs against a scratch tree the way tests/guest-scripts.sh
# runs homefield-cleanup: stub docker/rm/install on the PATH, the runner home
# and /tmp pointed into the tree through HOMEFIELD_RUNNER_HOME and
# HOMEFIELD_TMP, real find and bash. Nothing reaches a VM, Docker or /tmp.
# provision.sh's settings checks run through lib.sh's provision_verdict, and
# the re-register .env handling runs as a function against stubs, the way
# tests/ephemeral.sh runs it.
#
# Run:  bash tests/job-cleanup.sh
# The stub bodies are single-quoted and expand when the stub runs, not here.
# shellcheck disable=SC2016
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

stubs="$work/stubs"
calls="$work/calls"
mkdir -p "$stubs"
: >"$calls"
# stub <name> <body>: an executable on the stubs' PATH. The bodies are single
# quoted on purpose: they expand when the stub runs, not here.
# shellcheck disable=SC2016  # the stub's body is expanded by the stub, not here
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$stubs/$1"; chmod +x "$stubs/$1"; }
# docker <subcommand> ...: DOCKER_FAIL names a subcommand that fails, as a
# guest with Docker being repaired would.
stub docker 'echo "docker $*" >>"$CALLS"
[ "${DOCKER_FAIL:-}" = "$1" ] && exit 1
exit 0'
# rm: every call logged; FAIL_RM is a path an rm must refuse, as a stuck
# mount point would be. /bin/rm, not `command rm`: command would resolve
# through this PATH, back to the stub itself.
stub rm 'echo "rm $*" >>"$CALLS"
for a in "$@"; do
  case "$a" in "${FAIL_RM:-}") echo "rm: injected failure" >&2; exit 1 ;; esac
done
exec /bin/rm "$@"'
# install [-o u] [-g g] [-m mode] <src> <dst>: a plain copy, so the .env
# rewrites land where the script puts them. cp, not `command cp`: exec
# cannot run a builtin, and the external command(1) is a macOS-only script.
stub install 'while [ $# -gt 2 ]; do case "$1" in -o|-g|-m) shift 2 ;; *) shift ;; esac; done
exec cp "$1" "$2"'

# reset_tree: a scratch runner home (empty _work) and scratch /tmp.
reset_tree() {
  : >"$calls"
  rm -rf "$work/runner" "$work/tmp"
  mkdir -p "$work/runner/_work" "$work/tmp"
}
# run_hook <env assignments...>: one homefield-job-cleanup run against the
# scratch tree. The assignments before -- reach the run (injected failures).
run_hook() {
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  local cmd=(env -i PATH="$stubs:$PATH" CALLS="$calls" WORK="$work" \
    HOMEFIELD_RUNNER_HOME="$work/runner" HOMEFIELD_TMP="$work/tmp" PAGER=cat)
  [ ${#envs[@]} -gt 0 ] && cmd+=("${envs[@]}")
  out="$("${cmd[@]}" bash "$ROOT/vm/guest/homefield-job-cleanup" 2>&1 </dev/null)"
  rc=$?
}
gone() { [ ! -e "$1" ] && echo yes || echo no; }
grep_has() { grep -qF -- "$2" "$1" && echo yes || echo no; }

echo "homefield-job-cleanup"
reset_tree
run_hook --
record "an empty _work and /tmp: both docker prunes ran, nothing removed, exit 0" "0/1/1/0" \
  "$rc/$(grep -c 'docker container prune' "$calls")/$(grep -c 'docker network prune' "$calls")/$(grep -c '^rm ' "$calls")"

reset_tree
mkdir -p "$work/runner/_work/acme__api" "$work/runner/_work/_diag" "$work/runner/_work/_temp"
touch "$work/runner/_work/acme__api/build.log" "$work/runner/_work/runner-lock"
run_hook --
record "the job's workspace and the file beside it are removed, exit 0" "0/yes/yes/yes" \
  "$rc/$(has "$out" 'removing')/$(gone "$work/runner/_work/acme__api")/$(gone "$work/runner/_work/runner-lock")"
record "...the runner's own _diag and _temp are kept" "yes/yes" \
  "$([ -d "$work/runner/_work/_diag" ] && echo yes || echo no)/$([ -d "$work/runner/_work/_temp" ] && echo yes || echo no)"

reset_tree
: >"$work/tmp/job-scratch"
mkdir -p "$work/tmp/.hidden-dir"
echo keep >"$work/outside"
run_hook --
record "/tmp is emptied, dotfile directories included, exit 0" "0/0" \
  "$rc/$(find "$work/tmp" -mindepth 1 | wc -l | tr -d ' ')"
record "...a file outside the scratch /tmp is untouched" "yes" "$([ -f "$work/outside" ] && echo yes || echo no)"

# The guest's own /tmp state outlives the job: the PrivateTmp services hold
# their /tmp in /tmp/systemd-private-*, and a provision run staging files for
# the next upgrade keeps them in /tmp/homefield-stage-* (guest_stage_dir).
# Wiping either breaks the service or the run that owns it (#323).
reset_tree
mkdir -p "$work/tmp/systemd-private-1ab2c3-resolved" "$work/tmp/homefield-stage-9f3e21ac"
: >"$work/tmp/job-scratch"
run_hook --
record "the job scratch goes; systemd-private and homefield-stage dirs survive" "0/yes/yes/yes" \
  "$rc/$(gone "$work/tmp/job-scratch")/$([ -d "$work/tmp/systemd-private-1ab2c3-resolved" ] && echo yes || echo no)/$([ -d "$work/tmp/homefield-stage-9f3e21ac" ] && echo yes || echo no)"

# The completed hook runs as a post step of the job itself (the runner
# registers it in Runner.Worker's job pipeline, before the result is
# finalized): a job-running guard would match the Worker that invoked the
# hook and skip every run, so the script must not carry one — the daily
# timer's guard is right for a timer and wrong here.
record "the script has no job-running guard of its own" "0/0" \
  "$(grep -c 'Runner\.Worker>' "$ROOT/vm/guest/homefield-job-cleanup" || true)/$(grep -c 'job_running' "$ROOT/vm/guest/homefield-job-cleanup")"

reset_tree
mkdir -p "$work/runner/_work/acme__api"
: >"$work/tmp/job-scratch"
run_hook DOCKER_FAIL=container --
record "docker prune fails: the run warns, still cleans the filesystem, exit 0" "0/yes/yes/yes" \
  "$rc/$(has "$out" 'docker container prune failed')/$(gone "$work/runner/_work/acme__api")/$(gone "$work/tmp/job-scratch")"

reset_tree
mkdir -p "$work/runner/_work/acme__api"
: >"$work/tmp/job-scratch"
run_hook FAIL_RM="$work/runner/_work/acme__api" --
record "a workspace rm that fails: the run warns, exits 0, cleans /tmp anyway" "0/yes/yes/yes" \
  "$rc/$(has "$out" 'could not remove')/$([ -d "$work/runner/_work/acme__api" ] && echo yes || echo no)/$(gone "$work/tmp/job-scratch")"

echo
echo "the hook wrapper and provision.sh"
record "the hook wrapper runs the script through sudo, without a prompt" "yes" \
  "$(grep -qF 'exec sudo -n /usr/local/sbin/homefield-job-cleanup' "$ROOT/vm/guest/homefield-job-cleanup.sh" && echo yes || echo no)"
prov="$ROOT/vm/provision.sh"
record "RUNNER_JOB_CLEANUP is a switch: anything but 1 or 0 is refused" "reject" \
  "$(provision_verdict RUNNER_JOB_CLEANUP yes)"
record "RUNNER_JOB_CLEANUP=1 is accepted" "ok" "$(provision_verdict RUNNER_JOB_CLEANUP 1)"
record "RUNNER_JOB_CLEANUP=0 is accepted" "ok" "$(provision_verdict RUNNER_JOB_CLEANUP 0)"
record "the switch is saved in the guest only after the .env carries it" "yes" \
  "$(grep_has "$prov" 'printf '"'"'%s\n'"'"' "$job_cleanup" >"$CONFIG_DIR/job-cleanup"')"
record "a saved switch is read back and must be 1 or 0" "yes/yes" \
  "$(grep_has "$prov" 'saved_job_cleanup=""')/$(grep_has "$prov" '$CONFIG_DIR/job-cleanup must hold 1 or 0')"
record "the main flow adds and removes the .env line per the switch" "yes/yes" \
  "$(grep_has "$prov" 'completed_line="ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/sbin/homefield-job-cleanup.sh"')/$(grep_has "$prov" '[ "$job_cleanup" = "1" ]; then')"
record "re-register applies the same rule to the .env line" "yes" \
  "$(grep_has "$prov" 'ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/sbin/homefield-job-cleanup.sh')"
record "both hook scripts are installed from the staged vm/guest tree" "yes/yes" \
  "$(grep_has "$prov" 'install -m 755 "$script_dir/guest/homefield-job-cleanup" /usr/local/sbin/homefield-job-cleanup')/$(grep_has "$prov" 'install -m 755 "$script_dir/guest/homefield-job-cleanup.sh" /usr/local/sbin/homefield-job-cleanup.sh')"
record "the hook gets its own narrow sudoers rule, validated like the others" "yes/yes" \
  "$(grep_has "$prov" 'install_sudoers /etc/sudoers.d/homefield-job-cleanup')/$(grep_has "$prov" "'runner ALL=(root) NOPASSWD: /usr/local/sbin/homefield-job-cleanup \"\"'")"

echo
echo "re-register's .env handling"
# The function, extracted the way tests/ephemeral.sh extracts it, with the
# switch and the guest config dir the caller provides.
REREG_WORK="$work/rereg"
mkdir -p "$REREG_WORK/runner" "$work/etc"
REREG_FN="$work/rereg_fn.sh"
sed -n '/^REREG_BACKUP_DIR=/,/^if /p' "$prov" | sed '$d' >"$REREG_FN"
rereg_calls="$REREG_WORK/calls.log"
# rereg <job_cleanup> <line in .env 0|1> [RUNNER_JOB_CLEANUP]: one
# re-register against a runner whose .env holds the started hook line plus
# LANG=C, and optionally the completed hook line.
rereg() {
  rm -f "$rereg_calls"
  printf 'LANG=C\nACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/sbin/homefield-job-started.sh\n' >"$REREG_WORK/runner/.env"
  [ "$2" = 1 ] && echo 'ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/sbin/homefield-job-cleanup.sh' >>"$REREG_WORK/runner/.env"
  printf '{"agentName":"old-runner"}\n' >"$REREG_WORK/runner/.runner"
  printf 'actions.runner.test.service\n' >"$REREG_WORK/runner/.service"
  rm -f "$work/etc/job-cleanup"
  local jc="$1"; shift 2
  # shellcheck disable=SC2016  # inner bash -c expands its own vars
  out="$(env -i \
    PATH="$stubs:$PATH" \
    RUNNER_HOME="$REREG_WORK/runner" \
    RUNNER_URL="https://github.com/acme" \
    RUNNER_TOKEN="tok-new" \
    RUNNER_NAME="test-runner" \
    RUNNER_LABELS="self-hosted,linux,arm64,homefield-ci" \
    RUNNER_GROUP="" \
    RUNNER_USER="runner" \
    job_cleanup="$jc" \
    CONFIG_DIR="$work/etc" \
    REREG_CALLS="$rereg_calls" \
    ${1:+RUNNER_JOB_CLEANUP=$1} \
    bash -c '
      set -euo pipefail
      pgrep() { return 1; }
      systemctl() { return 0; }
      journalctl() { echo "Listening for Jobs"; }
      runner_config() { : >"$RUNNER_HOME/.runner"; return 0; }
      ensure_service() { printf "actions.runner.test.service\n" >"$RUNNER_HOME/.service"; return 0; }
      . "$1"
      re_register
    ' _ "$REREG_FN" 2>&1)"
  rc=$?
}
completed_line='ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/sbin/homefield-job-cleanup.sh'
rereg 1 0
record "the switch on and the line missing: the .env gains the hook line" "0/yes" \
  "$rc/$(grep -qx "$completed_line" "$REREG_WORK/runner/.env" && echo yes || echo no)"
rereg 0 1
record "the switch off and the line present: the .env loses the hook line" "0/no" \
  "$rc/$(grep -qx "$completed_line" "$REREG_WORK/runner/.env" && echo yes || echo no)"
rereg 0 0
record "the switch off and the line missing: the .env is left alone" "0/0/yes" \
  "$rc/$(grep -c 'ACTIONS_RUNNER_HOOK_JOB_COMPLETED' "$REREG_WORK/runner/.env")/$(grep -qx 'ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/sbin/homefield-job-started.sh' "$REREG_WORK/runner/.env" && echo yes || echo no)"
rereg 1 0 1
record "RUNNER_JOB_CLEANUP=1 saves the switch in the guest" "0/1" \
  "$rc/$(cat "$work/etc/job-cleanup" 2>/dev/null || echo missing)"
rereg 0 1 0
record "RUNNER_JOB_CLEANUP=0 saves the switch off" "0/0" \
  "$rc/$(cat "$work/etc/job-cleanup" 2>/dev/null || echo missing)"

summary