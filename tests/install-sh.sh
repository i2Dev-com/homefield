#!/usr/bin/env bash
# install.sh, the one-line installer: how it fetches the tarball (gh, then
# curl), what it installs and where, the wrapper on the PATH, the Lima prompt
# and the checks on the host and the settings. Every outside command is a stub
# on a PATH of its own, the tarball is built here, and HOME is a temp dir, so
# nothing is downloaded, installed or run for real.
#
# Run:  bash tests/install-sh.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# ── Fixture and stubs ──────────────────────────────────────────────────────
# What GitHub's source tarball looks like: one top directory, named after the
# repository and the short commit.
mkdir -p "$work/src/homefield-abc1234/bin" "$work/src/homefield-abc1234/vm"
printf '#!/bin/sh\necho "homefield stub: $*"\n' >"$work/src/homefield-abc1234/bin/homefield"
chmod +x "$work/src/homefield-abc1234/bin/homefield"
echo "name: homefield" >"$work/src/homefield-abc1234/vm/lima.yaml"
echo "#!/bin/sh" >"$work/src/homefield-abc1234/vm/provision.sh"
tar -czf "$work/fixture.tgz" -C "$work/src" homefield-abc1234
# A tarball that is not this tool.
mkdir -p "$work/other/something-1234567"
echo hi >"$work/other/something-1234567/README"
tar -czf "$work/other.tgz" -C "$work/other" something-1234567

tpl="$work/templates"
mkdir -p "$tpl"
cat >"$tpl/uname" <<'EOF'
#!/bin/sh
case "$1" in
  -s) echo "${FAKE_UNAME_S:-Darwin}" ;;
  -m) echo "${FAKE_UNAME_M:-arm64}" ;;
esac
EOF
# gh prints the error body on stdout and exits 1, as the real one does.
cat >"$tpl/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$CALLS"
if [ -n "${FAKE_GH_FAIL:-}" ]; then echo '{"message":"Not Found"}'; exit 1; fi
cat "${FIXTURE_FOR_GH:-$FIXTURE}"
EOF
cat >"$tpl/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$CALLS"
[ -z "${FAKE_CURL_FAIL:-}" ] || exit 22
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then cp "$FIXTURE" "$2"; fi
  shift
done
EOF
cat >"$tpl/brew" <<'EOF'
#!/bin/sh
echo "brew $*" >>"$CALLS"
[ "$1" != --prefix ] || echo "$BREW_PREFIX"
EOF
cat >"$tpl/limactl" <<'EOF'
#!/bin/sh
echo "limactl $*" >>"$CALLS"
[ "$1" != --version ] || echo "limactl version ${FAKE_LIMA_VERSION:-2.2.0}"
# `limactl list --format ... <name>` prints the status of an existing VM only.
if [ "$1" = list ]; then
  [ -z "${FAKE_VM_STATUS:-}" ] || echo "$FAKE_VM_STATUS"
fi
exit 0
EOF
chmod +x "$tpl"/*

# new_env [stub ...]: a fresh HOME and a PATH with just those stubs and the
# system tools install.sh uses. Without gh in the list there is no gh at all,
# whatever the machine has.
new_env() {
  local t
  rm -rf "$work/env"
  stubs="$work/env/stubs"
  home="$work/env/home"
  calls="$work/env/calls"
  mkdir -p "$stubs" "$home" "$work/env/brew/bin"
  : >"$calls"
  for t in "$@"; do cp "$tpl/$t" "$stubs/$t"; done
  [ -e "$stubs/uname" ] || cp "$tpl/uname" "$stubs/uname"
  for t in awk cat chmod cp cut dirname grep gzip head mkdir mktemp mv rm sed tar tr; do
    ln -s "$(command -v "$t")" "$stubs/$t"
  done
}

# run_install [VAR=value ...] [-- install.sh args]: sets out and rc. No
# terminal unless HOMEFIELD_TTY is given.
run_install() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  [ "${1:-}" != -- ] || shift
  out="$(env -i HOME="$home" PATH="$stubs" CALLS="$calls" FIXTURE="$work/fixture.tgz" \
    BREW_PREFIX="$work/env/brew" HOMEFIELD_HOME="$home/share" HOMEFIELD_BIN_DIR="$home/bin" \
    HOMEFIELD_TTY=/nonexistent "${envs[@]+"${envs[@]}"}" \
    "$BASH" "$ROOT/install.sh" "$@" 2>&1 </dev/null)"
  rc=$?
}
called() { grep -c "$1" "$calls" || true; }
nonzero() { [ "$1" -ne 0 ] && echo nonzero || echo "$1"; }

# ── Fetching ───────────────────────────────────────────────────────────────
echo "fetching"
new_env gh curl limactl
run_install
record "gh is used when it works" "1/0" "$(called '^gh api repos/i2Dev-com/homefield/tarball/v0.2.1$')/$(called '^curl')"
record "installed with exit 0" "0" "$rc"
record "the tool is unpacked with the top directory stripped" "yes" "$([ -x "$home/share/bin/homefield" ] && [ -f "$home/share/vm/lima.yaml" ] && echo yes || echo no)"
record "the ref and commit are recorded" "repo=i2Dev-com/homefield ref=v0.2.1 commit=abc1234" "$(tr '\n' ' ' <"$home/share/.homefield-ref" | sed 's/ $//')"
record "no staging directory is left behind" "0" "$(find "$home" -name '.homefield-install*' | wc -l | tr -d ' ')"
record "no arguments and no terminal: install is not run" "no" "$(has "$out" 'homefield stub')"
record "...and the next command is printed" "yes" "$(has "$out" 'homefield install --url https://github.com/<org>')"
record "the summary names the ref and commit" "yes" "$(has "$out" 'installed homefield v0.2.1 (abc1234)')"

new_env curl limactl
run_install
record "curl is used when gh is absent" "1" "$(called '^curl .*https://codeload.github.com/i2Dev-com/homefield/tar.gz/v0\.2\.1')"
record "...and installs" "0" "$rc"

new_env gh curl limactl
run_install FAKE_GH_FAIL=1
record "curl is the fallback when gh fails (not logged in, no access)" "1/1" "$(called '^gh api')/$(called '^curl')"
record "...and the error body gh printed is not the tarball" "0" "$rc"

new_env gh curl limactl
run_install FAKE_GH_FAIL=1 FAKE_CURL_FAIL=1
record "both failing is an error" "nonzero" "$(nonzero "$rc")"
record "...that says a private repository needs gh" "yes" "$(has "$out" 'private repository needs gh logged in with access to it')"
record "...and installs nothing" "no" "$([ -e "$home/share" ] && echo yes || echo no)"
record "...or leaves a staging directory" "0" "$(find "$home" -name '.homefield-install*' | wc -l | tr -d ' ')"

new_env gh curl limactl
run_install HOMEFIELD_REPO=acme/tool HOMEFIELD_REF=feat/x
record "HOMEFIELD_REPO and HOMEFIELD_REF choose the download" "1" "$(called '^gh api repos/acme/tool/tarball/feat/x$')"

# ── Settings are checked ───────────────────────────────────────────────────
echo "settings"
for bad in '../x' 'v0.1.0;rm' 'a b' '-x' '' 'a..b'; do
  [ -n "$bad" ] || continue
  new_env gh curl limactl
  run_install "HOMEFIELD_REF=$bad"
  record "ref [$bad] is rejected before any download" "nonzero/0" "$(nonzero "$rc")/$(wc -l <"$calls" | tr -d ' ')"
done
new_env gh curl limactl
run_install HOMEFIELD_REF=
record "an empty ref is the default" "1" "$(called 'tarball/v0.2.1$')"
# shellcheck disable=SC2016  # the values are meant to stay literal
for bad in 'acme' 'a/b/c' 'a/..' '$(x)/y' 'a/b;c'; do
  new_env gh curl limactl
  run_install "HOMEFIELD_REPO=$bad"
  record "repo [$bad] is rejected" "nonzero/0" "$(nonzero "$rc")/$(wc -l <"$calls" | tr -d ' ')"
done
new_env gh curl limactl
run_install 'HOMEFIELD_HOME=relative/dir'
record "a relative HOMEFIELD_HOME is rejected" "nonzero" "$(nonzero "$rc")"
new_env gh curl limactl
run_install "HOMEFIELD_HOME=$home/it's"
record "a HOMEFIELD_HOME that would break the wrapper is rejected" "nonzero" "$(nonzero "$rc")"

# ── Host ───────────────────────────────────────────────────────────────────
echo "host"
new_env gh curl limactl
run_install FAKE_UNAME_S=Linux
record "not macOS is rejected" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'needs macOS')/$(called '^gh')"
new_env gh curl limactl
run_install FAKE_UNAME_M=x86_64
record "not arm64 is rejected" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'Apple Silicon')/$(called '^gh')"

# ── Installed copy, wrapper ────────────────────────────────────────────────
echo "installed copy and wrapper"
new_env gh curl limactl
run_install -- --url https://github.com/acme --packages "x y"
record "arguments are passed to the installed homefield install" "homefield stub: install --url https://github.com/acme --packages x y" "$(echo "$out" | grep 'homefield stub' || true)"
record "the wrapper runs the installed homefield by its real path, with arguments" "homefield stub: status --instance x" "$(env -i "$home/bin/homefield" status --instance x)"
record "the wrapper is a script, not a symlink" "yes" "$([ -f "$home/bin/homefield" ] && [ ! -L "$home/bin/homefield" ] && echo yes || echo no)"
record "the wrapper is two lines" "2" "$(wc -l <"$home/bin/homefield" | tr -d ' ')"
record "the wrapper names the tool's directory" "exec \"$home/share/bin/homefield\" \"\$@\"" "$(sed -n 2p "$home/bin/homefield")"
record "a bin dir off the PATH is reported with the line to add" "yes" "$(has "$out" "export PATH=\"$home/bin:\$PATH\"")"

# Piped, as the one-liner runs it: the script is on stdin.
out="$(env -i HOME="$home" PATH="$stubs" CALLS="$calls" FIXTURE="$work/fixture.tgz" HOMEFIELD_TTY=/nonexistent \
  HOMEFIELD_HOME="$home/share" HOMEFIELD_BIN_DIR="$home/bin" "$BASH" -s -- --url https://github.com/piped <"$ROOT/install.sh" 2>&1)"
record "piped into bash -s, arguments still reach install" "homefield stub: install --url https://github.com/piped" "$(echo "$out" | grep 'homefield stub' || true)"

# Running it again replaces the copy.
echo old >"$home/share/leftover"
run_install
record "installing again replaces the old copy" "no/yes" "$([ -e "$home/share/leftover" ] && echo yes || echo no)/$([ -x "$home/share/bin/homefield" ] && echo yes || echo no)"

# A directory that is not ours is not replaced.
new_env gh curl limactl
mkdir -p "$home/share"
echo precious >"$home/share/file"
run_install
record "a HOMEFIELD_HOME holding something else is left alone" "nonzero/precious" "$(nonzero "$rc")/$(cat "$home/share/file")"
# Nor is a checkout of this repository: it has bin/homefield, but it is
# someone's work, not a copy this script installed.
new_env gh curl limactl
mkdir -p "$home/share/bin" "$home/share/.git"
echo '#!/bin/sh' >"$home/share/bin/homefield"
echo unpushed >"$home/share/work"
run_install
record "a checkout with bin/homefield but no .homefield-ref is left alone" "nonzero/unpushed/yes" "$(nonzero "$rc")/$(cat "$home/share/work")/$([ -d "$home/share/.git" ] && echo yes || echo no)"

# A download that is not the tool.
new_env gh curl limactl
run_install FIXTURE_FOR_GH="$work/other.tgz"
record "a tarball without bin/homefield is refused" "nonzero/yes/no" "$(nonzero "$rc")/$(has "$out" 'the download is not homefield')/$([ -e "$home/share" ] && echo yes || echo no)"

# The wrapper only replaces a wrapper.
new_env gh curl limactl
mkdir -p "$home/bin"
echo 'something else' >"$home/bin/homefield"
run_install
record "a foreign homefield on the PATH dir is not overwritten" "nonzero/something else" "$(nonzero "$rc")/$(cat "$home/bin/homefield")"

# Where the wrapper goes without HOMEFIELD_BIN_DIR.
new_env gh curl limactl brew
run_install HOMEFIELD_BIN_DIR=
record "Homebrew's bin when brew is there and it is writable" "yes" "$([ -x "$work/env/brew/bin/homefield" ] && echo yes || echo no)"
new_env gh curl limactl
run_install HOMEFIELD_BIN_DIR=
# shellcheck disable=SC2016  # the PATH line is printed with a literal $HOME
record "else ~/.local/bin" "yes/yes" "$([ -x "$home/.local/bin/homefield" ] && echo yes || echo no)/$(has "$out" 'export PATH="$HOME/.local/bin:$PATH"')"
new_env gh curl limactl brew
chmod a-w "$work/env/brew/bin"
run_install HOMEFIELD_BIN_DIR=
# A directory the owner cannot write is not writable to the test either, unless it runs as root.
if [ -w "$work/env/brew/bin" ]; then
  echo "  skip brew bin not writable (cannot be made read-only here)"
else
  record "...and ~/.local/bin when Homebrew's bin is not writable" "yes" "$([ -x "$home/.local/bin/homefield" ] && echo yes || echo no)"
fi
chmod u+w "$work/env/brew/bin"

# ── Lima ───────────────────────────────────────────────────────────────────
echo "lima"
new_env gh curl brew
run_install
record "no Lima, brew there, no terminal: stops, naming the command" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'brew install lima')/$(called '^brew install')"
new_env gh curl brew
run_install HOMEFIELD_YES=1
record "HOMEFIELD_YES=1 installs it" "0/1" "$rc/$(called '^brew install lima$')"
new_env gh curl brew
echo y >"$work/answer"
run_install HOMEFIELD_TTY="$work/answer"
record "answering y at the terminal installs it" "1" "$(called '^brew install lima$')"
record "...and with a terminal and no arguments, homefield install runs" "homefield stub: install" "$(echo "$out" | grep 'homefield stub' || true)"
new_env gh curl brew
echo "" >"$work/answer"
run_install HOMEFIELD_TTY="$work/answer"
record "just Enter is yes" "1" "$(called '^brew install lima$')"
new_env gh curl brew
echo n >"$work/answer"
run_install HOMEFIELD_TTY="$work/answer"
record "answering n stops, naming the command" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'brew install lima')/$(called '^brew install')"
new_env gh curl
run_install
record "no Lima and no brew: stops, pointing at Lima's install page" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'lima-vm.io')"
new_env gh curl limactl brew
run_install
record "Lima 1.1 or later present: nothing is installed or upgraded" "0/0/0" "$rc/$(called '^brew install')/$(called '^brew upgrade')"
new_env gh curl limactl brew
run_install FAKE_LIMA_VERSION=0.23.2
record "Lima older than 1.1, no terminal: stops, naming brew upgrade" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'brew upgrade lima')/$(called '^brew upgrade')"
new_env gh curl limactl brew
run_install FAKE_LIMA_VERSION=1.0.7 HOMEFIELD_YES=1
record "Lima 1.0 with HOMEFIELD_YES=1: upgraded" "0/1" "$rc/$(called '^brew upgrade lima$')"

# ── Running it again ───────────────────────────────────────────────────────
echo "running it again"
new_env gh curl limactl
: >"$work/answer"
run_install HOMEFIELD_TTY="$work/answer" FAKE_VM_STATUS=Running
record "VM exists, terminal, no arguments: tool only, install not run" "0/no/yes" "$rc/$(has "$out" 'homefield stub')/$(has "$out" 'homefield upgrade')"
new_env gh curl limactl
run_install FAKE_VM_STATUS=Running
record "VM exists, no terminal, no arguments: says it exists, no set-up advice" "0/no/yes/no" \
  "$rc/$(has "$out" 'homefield stub')/$(has "$out" 'already exists and was not changed')/$(has "$out" 'Next, set up the runner')"
new_env gh curl limactl
run_install
record "no VM, no terminal, no arguments: set-up advice" "0/yes" "$rc/$(has "$out" 'Next, set up the runner')"
new_env gh curl limactl
run_install HOMEFIELD_TTY="$work/answer" FAKE_VM_STATUS=Running HOMEFIELD_INSTANCE=other
record "...the instance named by HOMEFIELD_INSTANCE is the one looked up" "1" "$(called '^limactl list --format {{.Status}} other$')"
new_env gh curl limactl
run_install HOMEFIELD_TTY="$work/answer"
record "no VM yet, terminal, no arguments: install runs" "homefield stub: install" "$(echo "$out" | grep 'homefield stub' || true)"
new_env gh curl limactl
run_install FAKE_VM_STATUS=Running -- --url https://github.com/acme
record "VM exists but arguments given: install runs with them" "homefield stub: install --url https://github.com/acme" "$(echo "$out" | grep 'homefield stub' || true)"

summary
