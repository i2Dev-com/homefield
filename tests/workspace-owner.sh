#!/usr/bin/env bash
# The job-started hook that gives _work back to the runner user after a
# container job (#54), embedded in provision.sh: lint the two scripts as
# extracted, check that the hook, the sudo rule and the runner's .env name the
# same paths, and run the ownership fix against root-owned files.
#
# The run needs passwordless sudo and GNU find/chown (a hosted Ubuntu runner
# has both). Without them, the lint and the path checks still run and the run
# is reported as skipped.
#
# Run:  bash tests/workspace-owner.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'sudo -n rm -rf "$work" 2>/dev/null || rm -rf "$work"' EXIT
prov="$ROOT/vm/provision.sh"

# extract <path>: the heredoc that writes <path>, between its opening line and
# its terminator.
extract() {
  sed -n "\\|^cat > $1 <<'EOF'\$|,/^EOF\$/p" "$prov" | sed '1d;$d'
}
owner="$work/homefield-workspace-owner"
hook="$work/homefield-job-started.sh"
extract /usr/local/sbin/homefield-workspace-owner >"$owner"
extract /usr/local/sbin/homefield-job-started.sh >"$hook"
record "extracted both scripts" "yes/yes" "$([ -s "$owner" ] && echo yes || echo no)/$([ -s "$hook" ] && echo yes || echo no)"

if command -v shellcheck >/dev/null; then
  record "shellcheck" "clean" "$(shellcheck "$owner" "$hook" >/dev/null 2>&1 && echo clean || echo findings)"
else
  echo "  skip shellcheck (not installed)"
fi

# The hook runs exactly what sudoers allows, and .env points at the hook.
has() { grep -qF -- "$2" "$1" && echo yes || echo no; }
record "the hook runs the script through sudo, without a prompt" "yes" "$(has "$hook" 'exec sudo -n /usr/local/sbin/homefield-workspace-owner')"
record "sudoers allows that script, with no arguments" "yes" "$(has "$prov" "runner ALL=(root) NOPASSWD: /usr/local/sbin/homefield-workspace-owner \"\"")"
record "the runner's .env names the hook" "yes" "$(has "$prov" 'hook_line="ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/sbin/homefield-job-started.sh"')"

if ! sudo -n true 2>/dev/null || ! find "$work" -maxdepth 0 -printf "" 2>/dev/null; then
  echo "  skip run (needs passwordless sudo and GNU find)"
  summary
  exit
fi

# Point the script at a scratch _work and at this user instead of runner.
me="$(id -un)"
grp="$(id -gn)"
sed -e "s|/opt/actions-runner/_work|$work/_work|" -e "s|runner:runner|$me:$grp|" -e "s|! -user runner|! -user $me|" "$owner" >"$work/run.sh"
mkdir -p "$work/_work/repo/repo"
echo mine >"$work/_work/repo/repo/mine"
sudo -n mkdir "$work/_work/repo/repo/.github"
sudo -n sh -c "echo root >'$work/_work/repo/repo/.github/ci.yml'"
sudo -n sh -c "echo outside >'$work/outside'"
sudo -n ln -s "$work/outside" "$work/_work/repo/repo/link"
sudo -n bash "$work/run.sh"
rc=$?
record "runs" "0" "$rc"
record "root-owned files and directories now belong to the runner user" "0" "$(find "$work/_work" ! -user "$me" | grep -c .)"
record "...so they can be deleted as that user" "0" "$(rm -rf "$work/_work/repo/repo/.github" && echo 0 || echo 1)"
record "a symlink's target outside _work is left alone" "root" "$(stat -c %U "$work/outside")"
sudo -n bash "$work/run.sh"
record "a second run, nothing to change" "0" "$?"
rm -rf "$work/_work"
sudo -n bash "$work/run.sh"
record "no _work yet (before the first job)" "0" "$?"

summary
