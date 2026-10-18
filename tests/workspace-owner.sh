#!/usr/bin/env bash
# The job-started hook that gives _work back to the runner user after a
# container job (#54), embedded in provision.sh: lint the two scripts as
# extracted, check that the hook, the sudo rule and the runner's .env name the
# same paths, and run the ownership fix against a scratch _work.
#
# The run uses the real find with chown stubbed, so it needs no root and runs
# the same everywhere, including on a HomeField runner, where runner may sudo
# only the script itself.
#
# Run:  bash tests/workspace-owner.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
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

# The run: the real find against a scratch _work, with chown stubbed to record
# what it would change, so no root is needed and nothing depends on this
# machine's sudo or users. The user the script hands files to is swapped for
# one the test controls: the test's own user (whose files need nothing) or
# root (all of the test's files are then someone else's).
stubs="$work/stubs"
mkdir -p "$stubs"
cat >"$stubs/chown" <<EOF
#!/bin/sh
printf '%s\\n' "\$@" >>"$work/chown.log"
EOF
chmod +x "$stubs/chown"
# run_as <user>: the script, aimed at $work/_work and <user>.
run_as() {
  sed -e "s|/opt/actions-runner/_work|$work/_work|" -e "s|runner:runner|$1:$1|" -e "s|! -user runner|! -user $1|" "$owner" >"$work/run.sh"
  rm -f "$work/chown.log"
  PATH="$stubs:$PATH" bash "$work/run.sh"
}
chowned() { [ -f "$work/chown.log" ] && cat "$work/chown.log"; }

mkdir -p "$work/_work/repo/repo/.github" "$work/outside"
echo a >"$work/_work/repo/repo/.github/ci.yml"
echo b >"$work/outside/secret"
ln -s "$work/outside" "$work/_work/repo/repo/link"

me="$(id -un)"
run_as "$me"
record "everything already the runner user's: runs, changes nothing" "0/0" "$?/$(chowned | grep -c .)"

run_as root
rc=$?
log="$(chowned)"
record "files of another user: runs" "0" "$rc"
record "...changes the link itself, not its target (-h)" "-h/root:root" "$(echo "$log" | sed -n 1p)/$(echo "$log" | sed -n 2p)"
record "...every file and directory under _work, _work included" "yes/yes/yes" "$(echo "$log" | grep -qx "$work/_work" && echo yes || echo no)/$(echo "$log" | grep -qx "$work/_work/repo/repo/.github/ci.yml" && echo yes || echo no)/$(echo "$log" | grep -qx "$work/_work/repo/repo/link" && echo yes || echo no)"
# Followed, the link's target would show up under the link's own path.
record "...nothing through the symlink, outside _work" "0" "$(echo "$log" | grep -c -e "$work/outside" -e '/link/')"

rm -rf "$work/_work"
run_as root
record "no _work yet (before the first job): runs, changes nothing" "0/0" "$?/$(chowned | grep -c .)"

summary
