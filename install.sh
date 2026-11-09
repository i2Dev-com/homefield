#!/usr/bin/env bash
# One-line installer for homefield: downloads the tool, puts `homefield` on the
# PATH, makes sure Lima and gh are there (one question covers both), and hands
# over to `homefield setup` (`install` for a release older than setup).
#
#   curl -fsSL https://raw.githubusercontent.com/i2Dev-com/homefield/v0.5.2/install.sh | bash
#   ... | bash -s -- --url https://github.com/<org>      # install options pass through
#   ... | bash -s -- --url https://github.com/<you>/<repo>   # a personal account: a repository
#
# Settings, all optional:
#   HOMEFIELD_REPO      owner/repo to download from (default i2Dev-com/homefield)
#   HOMEFIELD_REF       branch, tag or commit to install (default v0.5.2)
#   HOMEFIELD_HOME      where the tool goes (default ~/.local/share/homefield)
#   HOMEFIELD_BIN_DIR   where the `homefield` command goes (default: Homebrew's
#                       bin when writable, else ~/.local/bin)
#   HOMEFIELD_YES=1     install Lima and gh with Homebrew without asking
#                       (needed when there is no terminal to ask on)
#   HOMEFIELD_INSTANCE  the VM's Lima instance name (default homefield), as for
#                       bin/homefield
#
# Lima is required: if it is missing or older than 2.3 and you decline, or
# there is no terminal and no HOMEFIELD_YES, this stops with the brew command
# to run, and without Homebrew it stops before downloading anything. gh is not:
# the one question offers `brew install gh` when it is missing, but declining,
# no terminal or no Homebrew just goes on, and `homefield setup` reports it
# with the command to run. Once gh is there, setup offers `gh auth login`.
#
# Everything is inside functions and `main` is the last line, so a download
# that stops half way runs nothing. Runs on macOS's stock bash 3.2. Running it
# again replaces the installed copy, which is how the tool is upgraded.
set -euo pipefail

REPO="${HOMEFIELD_REPO:-i2Dev-com/homefield}"
REF="${HOMEFIELD_REF:-v0.5.2}"
INSTALL_DIR="${HOMEFIELD_HOME:-$HOME/.local/share/homefield}"
INSTANCE="${HOMEFIELD_INSTANCE:-homefield}"
# The terminal to ask on. Under `curl | bash` stdin is this script, so prompts
# read from the controlling terminal instead. Settable so the tests can stand
# in for it with a file, or with nothing.
TTY="${HOMEFIELD_TTY:-/dev/tty}"
WORK=""

die() {
  echo "install.sh: $*" >&2
  exit 1
}
log() { echo "install.sh: $*"; }

cleanup() {
  [ -z "$WORK" ] || rm -rf "$WORK"
}

have_tty() { { : <"$TTY"; } 2>/dev/null; }

# Same checks, same messages as check_host in bin/homefield, so the failure
# comes before anything is downloaded.
check_host() {
  [ "$(uname -s)" = "Darwin" ] || die "needs macOS (Lima with Apple's Virtualization.framework)"
  [ "$(uname -m)" = "arm64" ] || die "needs an Apple Silicon Mac: the VM is arm64"
}

# The values end up in URLs, paths and a generated script, so they are
# checked against a short list of characters.
check_settings() {
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$REPO" != *..* ]] ||
    die "HOMEFIELD_REPO must be <owner>/<repo>, got: $REPO"
  [[ "$REF" =~ ^[A-Za-z0-9_./-]+$ && "$REF" != *..* && "$REF" != -* ]] ||
    die "HOMEFIELD_REF must be a branch, tag or commit name (letters, digits, '_', '.', '/', '-'), got: $REF"
  local dir_re='^/[A-Za-z0-9_./@+ -]+$'
  [[ "$INSTALL_DIR" =~ $dir_re && "$INSTALL_DIR" != *..* ]] ||
    die "HOMEFIELD_HOME must be an absolute path of letters, digits and _./@+- (and spaces), got: $INSTALL_DIR"
  if [ -n "${HOMEFIELD_BIN_DIR:-}" ]; then
    [[ "$HOMEFIELD_BIN_DIR" =~ ^/ ]] || die "HOMEFIELD_BIN_DIR must be an absolute path, got: $HOMEFIELD_BIN_DIR"
  fi
}

# check_instance: Lima's rule for an instance name, the same check as
# check_instance in bin/homefield (tests/install-sh.sh runs the same names
# through both). Anything else would reach limactl as an option, such as
# --help. Only for a run with no arguments, the one that looks the VM up:
# with arguments, bin/homefield checks the instance, and an --instance among
# them wins over HOMEFIELD_INSTANCE.
check_instance() {
  local instance_re='^[A-Za-z0-9]+([._-][A-Za-z0-9]+)*$'
  [[ "$INSTANCE" =~ $instance_re && ${#INSTANCE} -le 76 && ! "$INSTANCE" =~ [.][Yy][Aa]?[Mm][Ll]$ ]] ||
    die "HOMEFIELD_INSTANCE must be a Lima instance name: letters and digits, with a single '.', '_' or '-' between them, at most 76 characters, not ending in .yml or .yaml; got: $INSTANCE"
}

# fetch_tarball <file>: the source of REF. A plain download first: the default
# repository is public, so no gh and no login are needed. gh api is the
# fallback, which also reads a private fork (HOMEFIELD_REPO).
fetch_tarball() {
  local dest="$1"
  # A failed attempt's output is overwritten by the next one.
  if command -v curl >/dev/null 2>&1 && curl -fsSL -o "$dest" "https://codeload.github.com/${REPO}/tar.gz/${REF}" 2>/dev/null; then
    log "downloaded ${REPO} at ${REF}"
    return 0
  fi
  # gh prints an error body on stdout, so the exit status decides.
  if command -v gh >/dev/null 2>&1 && gh api "repos/${REPO}/tarball/${REF}" >"$dest" 2>/dev/null; then
    log "downloaded ${REPO} at ${REF} with gh"
    return 0
  fi
  die "could not download ${REPO} at ${REF}. A private repository needs gh logged in with access to it (gh auth login); otherwise check the name, the ref and your network"
}

# tarball_commit <file> <top dir>: the full commit, from the comment that
# `git archive` puts in the first block of the archive (GitHub's tarballs have
# it); failing that, the short hash the API's directory name ends in. Empty
# if neither is there. head closes the pipe early, so a failing gzip is fine.
tarball_commit() {
  local sha=""
  sha="$(gzip -dc "$1" 2>/dev/null | head -c 1024 | grep -a -o 'comment=[0-9a-f]\{40\}' | head -1 | cut -d= -f2)" || true
  if [ -z "$sha" ] && [[ "$2" =~ -([0-9a-f]{7,40})$ ]]; then
    sha="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$sha"
}

# install_tree <tarball>: unpacks next to the destination (same filesystem, so
# the final move is a rename), checks it is this tool, records where it came
# from and swaps it in. The old copy is put back only if the swap itself
# fails; after that it goes with $WORK when the script exits, even if a later
# step fails. Running this again (HOMEFIELD_REF=<tag> for an older one) is the
# way back.
install_tree() {
  local tarball="$1" stage="$WORK/tree" top commit f
  mkdir -p "$stage"
  tar -xzf "$tarball" -C "$stage" --strip-components=1 || die "could not unpack the download"
  for f in bin/homefield vm/lima.yaml vm/provision.sh; do
    [ -f "$stage/$f" ] || die "the download is not homefield: $f is missing"
  done
  # The wrapper execs it; provision.sh is run with bash, so only this one.
  [ -x "$stage/bin/homefield" ] || die "bin/homefield in the download is not executable; it was not packed with its file modes"
  top="$(tar -tzf "$tarball" | sed -n '1s,/.*,,p')"
  commit="$(tarball_commit "$tarball" "$top")"
  printf 'repo=%s\nref=%s\ncommit=%s\n' "$REPO" "$REF" "$commit" >"$stage/.homefield-ref"
  COMMIT="$commit"

  # Only a copy this script installed (it writes .homefield-ref) is replaced:
  # anything else there, such as a git checkout of this repository, could be
  # someone's work, and the old copy is deleted once the new one is in.
  if [ -e "$INSTALL_DIR" ] && [ ! -f "$INSTALL_DIR/.homefield-ref" ]; then
    die "$INSTALL_DIR exists and was not installed by this script; remove it or set HOMEFIELD_HOME"
  fi
  if [ -e "$INSTALL_DIR" ]; then
    mv "$INSTALL_DIR" "$WORK/old"
  fi
  if ! mv "$stage" "$INSTALL_DIR"; then
    [ ! -e "$WORK/old" ] || mv "$WORK/old" "$INSTALL_DIR"
    die "could not move the new copy to $INSTALL_DIR"
  fi
}

# pick_bin_dir: where the `homefield` command goes.
pick_bin_dir() {
  local prefix
  if [ -n "${HOMEFIELD_BIN_DIR:-}" ]; then
    printf '%s' "$HOMEFIELD_BIN_DIR"
  elif command -v brew >/dev/null 2>&1 && prefix="$(brew --prefix 2>/dev/null)" && [ -d "$prefix/bin" ] && [ -w "$prefix/bin" ]; then
    printf '%s' "$prefix/bin"
  else
    printf '%s' "$HOME/.local/bin"
  fi
}

# write_wrapper <dir>: bin/homefield finds the rest of the tool from the path
# it is run by, so the command is a script that runs it by its real path, not
# a symlink. An existing file is only replaced if it is this wrapper.
# `homefield reset --remove-tool` (tool_wrappers in bin/homefield) recognizes
# the wrapper by its exec line below, so the two change together.
write_wrapper() {
  local dir="$1" wrapper="$1/homefield" tmp
  mkdir -p "$dir"
  if [ -e "$wrapper" ] || [ -L "$wrapper" ]; then
    { [ -f "$wrapper" ] && [ ! -L "$wrapper" ] && grep -q '/bin/homefield" "\$@"$' "$wrapper"; } ||
      die "$wrapper exists and is not a homefield wrapper; remove it or set HOMEFIELD_BIN_DIR.
The new copy is in place and the previous one is gone, so 'homefield' is not on the PATH until this succeeds: rerun the install one-liner."
  fi
  tmp="$(mktemp "$dir/.homefield.XXXXXX")"
  printf '#!/bin/sh\nexec "%s/bin/homefield" "$@"\n' "$INSTALL_DIR" >"$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$wrapper"
}

# path_hint: the bin dir is often off the PATH. Editing ~/.zshrc only helps a
# future terminal, so lead with the same line copy-pasted into this one: the
# tool works now, and making it permanent is the second step, not the first.
path_hint() {
  local dir="$1" shown="$1"
  case ":$PATH:" in *":$dir:"*) return 0 ;; esac
  [ "$dir" != "$HOME/.local/bin" ] || shown="\$HOME/.local/bin"
  echo
  echo "$dir is not on your PATH. Copy-paste this line to add it now, in this terminal:"
  echo "  export PATH=\"$shown:\$PATH\""
  echo "To make it permanent, put the same line in ~/.zshrc:"
  echo "  export PATH=\"$shown:\$PATH\""
}

# lima_new_enough: limactl reports 2.3 or later, the minimum bin/homefield's
# check_host asks for (same parsing). 2.3 is the first stable release that
# honours networkOpts.hostLoopback (lima-vm/lima#5581).
lima_new_enough() {
  local version major minor
  version="$(limactl --version 2>/dev/null | awk '{print $NF}')"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  [ "$major" -gt 2 ] && return 0
  [ "$major" -eq 2 ] && [ "$minor" -ge 3 ]
}

# plan_packages: what Homebrew has to install for this Mac, set before
# anything is downloaded: LIMA_VERB (install or upgrade) and LIMA_WHAT (why)
# when Lima is missing or older than 2.3, NEED_GH=1 when gh is not on the PATH
# (setup's preflight needs it and `gh auth login` follows). A Lima that cannot
# be had, with no Homebrew to get it, is told now, before anything is written.
# Without Homebrew gh is only left for preflight to report, never a failure here.
plan_packages() {
  LIMA_VERB=""
  LIMA_WHAT=""
  NEED_GH=0
  if ! command -v limactl >/dev/null 2>&1; then
    LIMA_VERB=install
    LIMA_WHAT="is not installed"
  elif ! lima_new_enough; then
    LIMA_VERB=upgrade
    LIMA_WHAT="is older than 2.3"
  fi
  command -v gh >/dev/null 2>&1 || NEED_GH=1
  if ! command -v brew >/dev/null 2>&1; then
    [ -z "$LIMA_VERB" ] ||
      die "Lima ${LIMA_WHAT}. Install 2.3 or later (https://lima-vm.io/docs/installation/, or install Homebrew from https://brew.sh and run: brew install lima), then run this again"
    NEED_GH=0
  fi
}

# ensure_packages: installs what plan_packages found with one question for all
# of it. Lima is required: declining, no terminal to ask on, or a failed brew
# stops with the command to run. gh is not: setup's preflight reports a missing
# gh with its fix command, so nothing about gh makes a failure here.
ensure_packages() {
  local cmds="" answer
  [ -z "$LIMA_VERB" ] || cmds="brew ${LIMA_VERB} lima"
  [ "$NEED_GH" != 1 ] || cmds="${cmds:+$cmds and }brew install gh"
  [ -n "$cmds" ] || return 0
  if [ "${HOMEFIELD_YES:-}" != 1 ]; then
    if ! have_tty; then
      [ -z "$LIMA_VERB" ] ||
        die "Lima ${LIMA_WHAT} and there is no terminal to ask on. Run: brew ${LIMA_VERB} lima   (or run this again with HOMEFIELD_YES=1 to have it done)"
      log "gh is not installed and there is no terminal to ask on; setup will report it. To install it: brew install gh"
      return 0
    fi
    if [ -n "$LIMA_VERB" ]; then
      printf 'Lima %s.' "$LIMA_WHAT" >&2
      [ "$NEED_GH" != 1 ] || printf ' gh is not installed.' >&2
      printf ' Run %s? [Y/n] ' "$cmds" >&2
    else
      printf 'gh is not installed. Run %s? [Y/n] ' "$cmds" >&2
    fi
    read -r answer <"$TTY" || answer=""
    case "$answer" in
      "" | [Yy]*) ;;
      *)
        [ -z "$LIMA_VERB" ] || die "Lima 2.3 or later is required. Run: brew ${LIMA_VERB} lima"
        log "gh was not installed; setup will report it. To install it: brew install gh"
        return 0
        ;;
    esac
  fi
  if [ -n "$LIMA_VERB" ]; then
    brew "$LIMA_VERB" lima || die "brew ${LIMA_VERB} lima failed"
  fi
  if [ "$NEED_GH" = 1 ]; then
    brew install gh ||
      log "warning: brew install gh failed; setup will report it. To retry: brew install gh"
  fi
}

vm_exists() {
  [ -n "$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null)" ]
}

main() {
  trap cleanup EXIT
  check_host
  check_settings
  [ $# -gt 0 ] || check_instance
  plan_packages

  # Next to the destination, so that the swap below is a rename.
  mkdir -p "$(dirname "$INSTALL_DIR")"
  WORK="$(mktemp -d "$(dirname "$INSTALL_DIR")/.homefield-install.XXXXXX")"
  COMMIT=""
  fetch_tarball "$WORK/homefield.tar.gz"
  install_tree "$WORK/homefield.tar.gz"

  local bin_dir
  bin_dir="$(pick_bin_dir)"
  write_wrapper "$bin_dir"
  ensure_packages

  log "installed homefield ${REF}${COMMIT:+ (${COMMIT:0:7})} from ${REPO}"
  log "tool: ${INSTALL_DIR}"
  log "command: ${bin_dir}/homefield"
  path_hint "$bin_dir"

  # Past this point the installed tool takes over. exec does not run the exit
  # trap, so clean up first.
  cleanup
  WORK=""
  trap - EXIT
  local installed="$INSTALL_DIR/bin/homefield"
  # HOMEFIELD_INSTANCE may have been set for this run only, so the commands
  # printed below name the instance themselves.
  local on=""
  [ "$INSTANCE" = homefield ] || on=" --instance ${INSTANCE}"
  # The first-time command, for the hand-over and the advice below: `setup` when the
  # tool just installed has it, else `install`. REF may be a release older than
  # `setup` (the default is a pinned tag), so what exists is asked, not assumed.
  local first=install
  if "$installed" setup --exists 2>/dev/null </dev/null; then first=setup
# A release that has setup but predates the --exists probe (v0.5.0 and
# earlier): the probe's nonzero is "no such option", not "no setup", so
# fall back to the help text, as before the probe existed.
elif "$installed" help 2>/dev/null </dev/null | grep -q '^  setup '; then first=setup; fi
  # Run again with no arguments on a Mac that already has the VM, this is a
  # tool update, with or without a terminal: `install` there would upgrade the
  # VM and briefly stop the runner, which nobody asked for, and advice to set
  # up a runner would be wrong.
  if [ $# -eq 0 ] && vm_exists; then
    echo
    echo "The VM ${INSTANCE} already exists and was not changed. To update it too:"
    echo "  homefield upgrade${on}"
    echo "If its setup never finished (homefield status${on} shows no registration), finish it with:"
    echo "  homefield ${first}${on}"
    return 0
  fi
  if [ $# -gt 0 ] || have_tty; then
    echo
    if have_tty; then
      exec "$installed" "$first" "$@" <"$TTY"
    fi
    exec "$installed" "$first" "$@" </dev/null
  fi
  echo
  echo "Next, set up the runner:"
  echo "  homefield ${first}${on} --url https://github.com/<org>      # or https://github.com/<owner>/<repo> (a personal account needs a repository)"
}

main "$@"
