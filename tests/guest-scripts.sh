#!/usr/bin/env bash
# The two guest helpers the suites did not cover before they became vm/guest
# files (#189): homefield-cleanup (the workspace-age rule, the _* skip, the
# re-check before an rm -rf) and homefield-maintenance (the stop, the trap
# that brings the runner back, the reboot branch). Both are run against fakes
# the way tests/workspace-owner.sh runs its scripts: stub pgrep/docker/system
#ctl/apt-get on the PATH, the absolute paths rewritten into a scratch tree,
# real find/touch/rm. Nothing reaches a VM, Docker, systemd or apt.
#
# Run:  bash tests/guest-scripts.sh
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
stub pgrep 'echo "pgrep $*" >>"$CALLS"
[ "${PGREP_ANSWER:-none}" = running ]'
stub docker 'echo "docker $*" >>"$CALLS"'
stub systemctl 'echo "systemctl $*" >>"$CALLS"
case "$1 $2" in
  "reboot ") [ -n "${REBOOT_FAILS:-}" ] && exit 1 ;;
esac
exit 0'
stub apt-get 'echo "apt-get $*" >>"$CALLS"
[ "${APT_FAIL:-}" = "$1" ] && exit 1
exit 0'

# The age rule is the script's to test, not find's: the script targets GNU
# find's -newermt '-7 days', which the Mac's BSD find does not parse. A find
# stub answers from a marker file instead — a .fresh file inside a workspace
# says find found something newer than 7 days — so the branching (empty
# output removes, non-empty keeps) is what runs.
stub find 'for a in "$@"; do
  case "$a" in -*) ;; *) d="$a" ;; esac
done
[ -f "$d/.fresh" ] && echo "$d/.fresh"
exit 0'

# cleanup <env assignments...> -- <workspaces...>: a homefield-cleanup run
# against a scratch _work. The assignments before -- reach the run (the pgrep
# stub's answer). A workspace with a .fresh file is "recently used"; one
# without is idle for the age rule.
cleanup() {
  : >"$calls"
  rm -rf "$work/runner"; mkdir -p "$work/runner/_work"
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  local dir cmd=(env -i PATH="$stubs:$PATH" CALLS="$calls" WORK="$work" PAGER=cat)
  [ ${#envs[@]} -gt 0 ] && cmd+=("${envs[@]}")
  for dir in "$@"; do
    mkdir -p "$work/runner/_work/$dir"
    case "$dir" in *.fresh) : >"$work/runner/_work/$dir/.fresh" ;; esac
  done
  sed -e "s|/opt/actions-runner/_work|$work/runner/_work|g" \
    "$ROOT/vm/guest/homefield-cleanup" >"$work/cleanup.sh"
  out="$("${cmd[@]}" bash "$work/cleanup.sh" 2>&1 </dev/null)"
  rc=$?
}

echo "homefield-cleanup"
cleanup --
record "no _work entries: docker is pruned, nothing iterated, exit 0" "0/1/0" \
  "$rc/$(grep -c 'docker system prune' "$calls")/$(grep -c 'rm -rf' "$calls")"
cleanup PGREP_ANSWER=running -- feat-a.fresh
record "a job running: skipped before docker, exit 0" "0/yes/0" \
  "$rc/$(has "$out" 'job in progress, skipping')/$(grep -c 'docker system prune' "$calls")"
cleanup -- feat-a.fresh old
record "a fresh workspace and an idle one: only the idle one is removed" "0/1/yes/0" \
  "$rc/$(grep -c 'docker system prune' "$calls")/$(has "$out" 'removing idle workspace')/$([ -d "$work/runner/_work/feat-a.fresh" ] && echo 0 || echo 1)"
cleanup -- _staging old
record "a _* workspace, however idle: skipped, kept" "0/1/0" \
  "$rc/$(has "$out" 'removing idle workspace _staging' | grep -c no)/$([ -d "$work/runner/_work/_staging" ] && echo 0 || echo 1)"
# The re-check: pgrep answers "none" at the top and "running" from the second
# call on, so the job starts between the find and the rm.
: >"$stubs/pgrep"
cat >"$stubs/pgrep" <<'EOF'
#!/usr/bin/env bash
echo "pgrep $*" >>"$CALLS"
n=$(($(cat "$WORK/pgrep-n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$WORK/pgrep-n"
[ "${PGREP_ANSWER:-none}" = running ] || [ "$n" -gt 1 ]
EOF
cleanup -- old
record "a job starting mid-run: the re-check leaves the workspace, exit 0" "0/yes/0" \
  "$rc/$(has "$out" 'job started, leaving')/$([ -d "$work/runner/_work/old" ] && echo 0 || echo 1)"
rm -f "$stubs/pgrep"
stub pgrep 'echo "pgrep $*" >>"$CALLS"
[ "${PGREP_ANSWER:-none}" = running ]'

echo
echo "homefield-maintenance"
# maintenance <env assignments...>: a homefield-maintenance run with the unit
# read from a scratch .service and the reboot-required check pointed into the
# tree. REBOOT_REQUIRED creates the flag file; REBOOT_FAILS makes
# systemctl reboot fail.
maintenance() {
  : >"$calls"
  rm -rf "$work/runner" "$work/reboot-required"
  mkdir -p "$work/runner"
  echo "actions.runner.test.service" >"$work/runner/.service"
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  # REBOOT_REQUIRED is one of the run's env assignments; the flag file it
  # names is created here, in the tree the sed points the check at.
  case "${envs[*]}" in *REBOOT_REQUIRED*) : >"$work/reboot-required" ;; esac
  local cmd=(env -i PATH="$stubs:$PATH" CALLS="$calls" WORK="$work" PAGER=cat)
  [ ${#envs[@]} -gt 0 ] && cmd+=("${envs[@]}")
  sed -e "s|/opt/actions-runner|$work/runner|g" \
    -e "s|/var/run/reboot-required|$work/reboot-required|g" \
    "$ROOT/vm/guest/homefield-maintenance" >"$work/maint.sh"
  out="$("${cmd[@]}" bash "$work/maint.sh" 2>&1 </dev/null)"
  rc=$?
}
systemctl_calls() { grep -c "systemctl $1" "$calls" || true; }
maintenance
record "idle: the unit is stopped, the packages are upgraded, the unit is started" "0/1/1/1/1/1" \
  "$rc/$(systemctl_calls 'stop')/$(grep -c 'apt-get update' "$calls")/$(grep -c 'apt-get upgrade' "$calls")/$(grep -c 'apt-get autoremove' "$calls")/$(systemctl_calls 'start')"
maintenance PGREP_ANSWER=running --
record "a job running: skipped until tomorrow, nothing stopped" "0/yes/0" \
  "$rc/$(has "$out" 'job in progress, skipping until tomorrow')/$(systemctl_calls 'stop')"
maintenance REBOOT_REQUIRED=1 --
record "a reboot is required: the runner is not started, the guest reboots" "0/yes/1/1/0" \
  "$rc/$(has "$out" 'rebooting to finish the upgrade')/$(systemctl_calls 'reboot')/$(systemctl_calls 'stop')/$(systemctl_calls 'start')"
maintenance REBOOT_REQUIRED=1 REBOOT_FAILS=1 --
record "the reboot is refused: the runner is started instead" "0/1/1/yes" \
  "$rc/$(systemctl_calls 'reboot')/$(systemctl_calls 'start')/$(has "$out" 'rebooting to finish the upgrade')"
maintenance APT_FAIL=upgrade --
record "an apt-get failure: the trap starts the unit back up, exit nonzero" "nonzero/1/1" \
  "$(nonzero "$rc")/$(systemctl_calls 'stop')/$(systemctl_calls 'start')"

if command -v shellcheck >/dev/null; then
  record "shellcheck of both helpers" "clean" \
    "$(shellcheck "$ROOT/vm/guest/homefield-cleanup" "$ROOT/vm/guest/homefield-maintenance" >/dev/null 2>&1 && echo clean || echo findings)"
else
  echo "  skip shellcheck (not installed)"
fi

summary