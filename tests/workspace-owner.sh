#!/usr/bin/env bash
# The job-started hook that repairs the runner's npm (#110) and gives _work
# back to the runner user after a container job (#54), both embedded in
# provision.sh: lint the two scripts as extracted, check that the hook, the
# sudo rule and the runner's .env name the same paths, run the npm repair
# against a fake externals tree, and the ownership fix against a scratch _work.
#
# The runs use the real find, cmp and ln with chown stubbed, so they need no
# root and run the same everywhere, including on a HomeField runner, where
# runner may sudo only the script itself.
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
in_run() { has "$work/run.out" "$1"; }
record "the hook runs the script through sudo, without a prompt" "yes" "$(has "$hook" 'exec sudo -n /usr/local/sbin/homefield-workspace-owner')"
record "sudoers allows that script, with no arguments" "yes" "$(has "$prov" "runner ALL=(root) NOPASSWD: /usr/local/sbin/homefield-workspace-owner \"\"")"
record "the runner's .env names the hook" "yes" "$(has "$prov" 'hook_line="ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/sbin/homefield-job-started.sh"')"

# The runs: the real find, cmp and ln against a scratch tree, with chown
# stubbed to record what it would change, so no root is needed and nothing
# depends on this machine's sudo or users. The user the script hands files to
# is swapped for one the test controls: the test's own user (whose files need
# nothing) or root (all of the test's files are then someone else's). The
# runner home is $work/runner through HOMEFIELD_RUNNER_HOME, the same override
# provision.sh's script reads; the hook sets none.
stubs="$work/stubs"
mkdir -p "$stubs"
cat >"$stubs/chown" <<EOF
#!/bin/sh
printf '%s\\n' "\$@" >>"$work/chown.log"
EOF
chmod +x "$stubs/chown"
run_as() { # run_as <user>: the script, aimed at $work/runner and <user>
  sed -e "s|runner:runner|$1:$1|" -e "s|! -user runner|! -user $1|" "$owner" >"$work/run.sh"
  rm -f "$work/chown.log"
  HOMEFIELD_RUNNER_HOME="$work/runner" PATH="$stubs:$PATH" bash "$work/run.sh" >"$work/run.out" 2>&1
}
chowned() { [ -f "$work/chown.log" ] && cat "$work/chown.log"; }

# ── Workspace ownership (#54) ───────────────────────────────────────────────
mkdir -p "$work/runner/_work/repo/repo/.github" "$work/outside"
echo a >"$work/runner/_work/repo/repo/.github/ci.yml"
echo b >"$work/outside/secret"
ln -s "$work/outside" "$work/runner/_work/repo/repo/link"

me="$(id -un)"
run_as "$me"
record "everything already the runner user's: runs, changes nothing" "0/0" "$?/$(chowned | grep -c .)"

run_as root
rc=$?
log="$(chowned)"
record "files of another user: runs" "0" "$rc"
record "...changes the link itself, not its target (-h)" "-h/root:root" "$(echo "$log" | sed -n 1p)/$(echo "$log" | sed -n 2p)"
record "...every file and directory under _work, _work included" "yes/yes/yes" "$(echo "$log" | grep -qx "$work/runner/_work" && echo yes || echo no)/$(echo "$log" | grep -qx "$work/runner/_work/repo/repo/.github/ci.yml" && echo yes || echo no)/$(echo "$log" | grep -qx "$work/runner/_work/repo/repo/link" && echo yes || echo no)"
# Followed, the link's target would show up under the link's own path.
record "...nothing through the symlink, outside _work" "0" "$(echo "$log" | grep -c -e "$work/outside" -e '/link/')"

rm -rf "$work/runner/_work"
run_as root
record "no _work yet and no externals (a fresh runner home): runs, changes nothing" "0/0" "$?/$(chowned | grep -c .)"

# ── npm repair (#110) ───────────────────────────────────────────────────────
# A fake externals tree: node20 and node24 with npm, npx and corepack laid out
# like the runner's (bin/<name> linked into lib/node_modules). The fake node
# models the real breakage: the runner's node runs the npm entry point only
# through a proper link, which resolves npm's own relative require(); a
# flattened regular file dies with MODULE_NOT_FOUND. So: exit 0 through a
# link, 1 through a regular file.
mk_externals() { # mk_externals <externals dir>: a healthy node20+node24 tree
  local v bin lib
  for v in node20 node24; do
    bin="$1/$v/bin"
    lib="$1/$v/lib/node_modules"
    mkdir -p "$bin" "$lib/npm/bin" "$lib/corepack/dist"
    printf '#!/bin/sh\necho fake\n' >"$lib/npm/bin/npm-cli.js"
    printf '#!/bin/sh\necho fake\n' >"$lib/npm/bin/npx-cli.js"
    printf '#!/bin/sh\necho fake\n' >"$lib/corepack/dist/corepack.js"
    # shellcheck disable=SC2016  # the fake node stub must see "$1" literally
    printf '#!/bin/sh\ncase "$1" in *npm) [ -L "$1" ] && exit 0 || exit 1 ;; *) exit 0 ;; esac\n' >"$bin/node"
    chmod 755 "$bin/node"
    ln -sf ../lib/node_modules/npm/bin/npm-cli.js "$bin/npm"
    ln -sf ../lib/node_modules/npm/bin/npx-cli.js "$bin/npx"
    ln -sf ../lib/node_modules/corepack/dist/corepack.js "$bin/corepack"
  done
}
# flatten <bin dir>: the artifact, as the self-update leaves it — each of the
# three names a regular file holding a copy of exactly what the link points at.
flatten() {
  local name target
  for name in npm npx corepack; do
    target="$(readlink "$1/$name")"
    rm "$1/$name"
    cp "$1/$target" "$1/$name"
  done
}
linked() { # linked <bin dir> <name> <expected target>: the name is that link again
  [ -L "$1/$2" ] && [ "$(readlink "$1/$2")" = "$3" ]
}
ext="$work/runner/externals"

mk_externals "$ext"
run_as root
record "healthy externals: runs and relinks nothing" "0/0" "$?/$(grep -c relinked "$work/run.out")"

mk_externals "$ext"
flatten "$ext/node20/bin"
flatten "$ext/node24/bin"
run_as root
rc=$?
record "the self-update's artifact in both node copies: runs" "0" "$rc"
record "...relinked all six" "6" "$(grep -c relinked "$work/run.out")"
record "...as the exact links again" "yes/yes/yes/yes" "$(linked "$ext/node20/bin" npm ../lib/node_modules/npm/bin/npm-cli.js && echo yes || echo no)/$(linked "$ext/node24/bin" npm ../lib/node_modules/npm/bin/npm-cli.js && echo yes || echo no)/$(linked "$ext/node24/bin" npx ../lib/node_modules/npm/bin/npx-cli.js && echo yes || echo no)/$(linked "$ext/node24/bin" corepack ../lib/node_modules/corepack/dist/corepack.js && echo yes || echo no)"

mk_externals "$ext"
rm "$ext/node24/bin/npm"
echo changed-by-someone >"$ext/node24/bin/npm"
run_as root
rc=$?
record "a regular npm that is not the artifact: left alone, run fails loudly" "1/yes/yes" \
  "$rc/$(in_run 'leaving it alone')/$(in_run 'is broken and the repair did not hold')"
record "...the file is untouched" "yes" "$([ -f "$ext/node24/bin/npm" ] && [ ! -L "$ext/node24/bin/npm" ] && echo yes || echo no)"

rm -rf "$ext"
mk_externals "$work/runner/externals.2.338.0"
ln -s "$work/runner/externals.2.338.0" "$ext"
flatten "$work/runner/externals.2.338.0/node24/bin"
run_as root
rc=$?
record "externals a symlink to the versioned dir, as after an update: runs" "0" "$rc"
record "...relinked the three, once" "3" "$(grep -c relinked "$work/run.out")"
record "...npm runs through the link again" "yes" "$(linked "$work/runner/externals.2.338.0/node24/bin" npm ../lib/node_modules/npm/bin/npm-cli.js && echo yes || echo no)"

summary