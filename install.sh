#!/usr/bin/env bash
# One-line installer for homefield: downloads the tool, puts `homefield` on the
# PATH, makes sure Lima is there, and hands over to `homefield install`.
#
#   gh api 'repos/i2Dev-com/homefield/contents/install.sh?ref=v0.1.0' \
#     -H 'Accept: application/vnd.github.raw' | bash
#   curl -fsSL https://raw.githubusercontent.com/i2Dev-com/homefield/v0.1.0/install.sh | bash
#   ... | bash -s -- --url https://github.com/<org>      # install options pass through
#
# Settings, all optional:
#   HOMEFIELD_REPO      owner/repo to download from (default i2Dev-com/homefield)
#   HOMEFIELD_REF       branch, tag or commit to install (default v0.1.0)
#   HOMEFIELD_HOME      where the tool goes (default ~/.local/share/homefield)
#   HOMEFIELD_BIN_DIR   where the `homefield` command goes (default: Homebrew's
#                       bin when writable, else ~/.local/bin)
#   HOMEFIELD_YES=1     install Lima with Homebrew without asking (needed when
#                       there is no terminal to ask on)
#
# Everything is inside functions and `main` is the last line, so a download
# that stops half way runs nothing. Runs on macOS's stock bash 3.2. Running it
# again replaces the installed copy, which is how the tool is upgraded.
set -euo pipefail

REPO="${HOMEFIELD_REPO:-i2Dev-com/homefield}"
REF="${HOMEFIELD_REF:-v0.1.0}"
INSTALL_DIR="${HOMEFIELD_HOME:-$HOME/.local/share/homefield}"
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

# fetch_tarball <file>: the source of REF. gh when it works, since it is the
# only way to read a private repository; otherwise a plain download.
fetch_tarball() {
  local dest="$1"
  # gh prints an error body on stdout, so the exit status decides, and a
  # failed attempt's output is overwritten by the next one.
  if command -v gh >/dev/null 2>&1 && gh api "repos/${REPO}/tarball/${REF}" >"$dest" 2>/dev/null; then
    log "downloaded ${REPO} at ${REF} with gh"
    return 0
  fi
  if command -v curl >/dev/null 2>&1 && curl -fsSL -o "$dest" "https://codeload.github.com/${REPO}/tar.gz/${REF}" 2>/dev/null; then
    log "downloaded ${REPO} at ${REF}"
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
# from and swaps it in. The old copy is only removed once the new one is in.
install_tree() {
  local tarball="$1" stage="$WORK/tree" top commit f
  mkdir -p "$stage"
  tar -xzf "$tarball" -C "$stage" --strip-components=1 || die "could not unpack the download"
  for f in bin/homefield vm/lima.yaml vm/provision.sh; do
    [ -f "$stage/$f" ] || die "the download is not homefield: $f is missing"
  done
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
write_wrapper() {
  local dir="$1" wrapper="$1/homefield" tmp
  mkdir -p "$dir"
  if [ -e "$wrapper" ] || [ -L "$wrapper" ]; then
    { [ -f "$wrapper" ] && [ ! -L "$wrapper" ] && grep -q '/bin/homefield" "\$@"$' "$wrapper"; } ||
      die "$wrapper exists and is not a homefield wrapper; remove it or set HOMEFIELD_BIN_DIR"
  fi
  tmp="$(mktemp "$dir/.homefield.XXXXXX")"
  printf '#!/bin/sh\nexec "%s/bin/homefield" "$@"\n' "$INSTALL_DIR" >"$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$wrapper"
}

path_hint() {
  local dir="$1" shown="$1"
  case ":$PATH:" in *":$dir:"*) return 0 ;; esac
  [ "$dir" != "$HOME/.local/bin" ] || shown="\$HOME/.local/bin"
  echo
  echo "$dir is not on your PATH. To add it, put this line in ~/.zshrc and open a new terminal:"
  echo "  export PATH=\"$shown:\$PATH\""
}

# lima_new_enough: limactl reports 1.1 or later, the minimum bin/homefield's
# check_host asks for (same parsing).
lima_new_enough() {
  local version major minor
  version="$(limactl --version 2>/dev/null | awk '{print $NF}')"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 1 ]; }
}

ensure_lima() {
  local verb=install what="is not installed"
  if command -v limactl >/dev/null 2>&1; then
    lima_new_enough && return 0
    verb=upgrade
    what="is older than 1.1"
  fi
  command -v brew >/dev/null 2>&1 ||
    die "Lima ${what}. Install 1.1 or later (https://lima-vm.io/docs/installation/, or install Homebrew from https://brew.sh and run: brew install lima), then run this again"
  if [ "${HOMEFIELD_YES:-}" != 1 ]; then
    have_tty || die "Lima ${what} and there is no terminal to ask on. Run: brew ${verb} lima   (or run this again with HOMEFIELD_YES=1 to have it done)"
    local answer
    printf 'Lima %s. Run brew %s lima? [Y/n] ' "$what" "$verb" >&2
    read -r answer <"$TTY" || answer=""
    case "$answer" in
      "" | [Yy]*) ;;
      *) die "Lima 1.1 or later is required. Run: brew ${verb} lima" ;;
    esac
  fi
  brew "$verb" lima || die "brew ${verb} lima failed"
}

vm_exists() {
  [ -n "$(limactl list --format '{{.Status}}' "${HOMEFIELD_INSTANCE:-homefield}" 2>/dev/null)" ]
}

main() {
  trap cleanup EXIT
  check_host
  check_settings

  # Next to the destination, so that the swap below is a rename.
  mkdir -p "$(dirname "$INSTALL_DIR")"
  WORK="$(mktemp -d "$(dirname "$INSTALL_DIR")/.homefield-install.XXXXXX")"
  COMMIT=""
  fetch_tarball "$WORK/homefield.tar.gz"
  install_tree "$WORK/homefield.tar.gz"

  local bin_dir
  bin_dir="$(pick_bin_dir)"
  write_wrapper "$bin_dir"
  ensure_lima

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
  # Run again with no arguments on a Mac that already has the VM, this is a
  # tool update, with or without a terminal: `install` there would upgrade the
  # VM and briefly stop the runner, which nobody asked for, and advice to set
  # up a runner would be wrong.
  if [ $# -eq 0 ] && vm_exists; then
    echo
    echo "The VM ${HOMEFIELD_INSTANCE:-homefield} already exists and was not changed. To update it too:"
    echo "  homefield upgrade"
    echo "If its setup never finished (homefield status shows no registration), finish it with:"
    echo "  homefield install"
    return 0
  fi
  if [ $# -gt 0 ] || have_tty; then
    echo
    if have_tty; then
      exec "$installed" install "$@" <"$TTY"
    fi
    exec "$installed" install "$@" </dev/null
  fi
  echo
  echo "Next, set up the runner:"
  echo "  homefield install --url https://github.com/<org>      # or https://github.com/<owner>/<repo>"
}

main "$@"
