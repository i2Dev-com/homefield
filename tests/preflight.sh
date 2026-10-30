#!/usr/bin/env bash
# tests/preflight.sh — verify homefield preflight subcommand
#
# Sources bin/homefield with HOMEFIELD_SOURCE_ONLY=1, sets a stubbed PATH,
# and calls cmd_preflight directly. Nothing reaches the network or the real
# machine.
#
# Run:  bash tests/preflight.sh
# Exit: 0 when all tests pass, 1 otherwise

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/tests/lib.sh"

# Find bash (may be /bin/bash on macOS or homebrew)
BASH_BIN="$(command -v bash || /bin/bash)"

# Create a stub directory with fake commands.
# $1 = directory to create. Remaining args = command names.
stub_bin() {
  local dir="$1"; shift
  mkdir -p "$dir"
  for cmd in "$@"; do
    case "$cmd" in
      limactl)
        printf '#!/bin/sh\necho "%s"\n' "${LIMA_VERSION:-2.0}" > "$dir/limactl"
        ;;
      gh)
        printf '#!/bin/sh\nif [ "$1" = "auth" ]; then\n  echo "Token scopes: admin:org,repo"\n  exit 0\nfi\necho "stub gh"\n' > "$dir/gh"
        ;;
      python3)
        printf '#!/bin/sh\necho "Python 3.12.0"\n' > "$dir/python3"
        ;;
      brew)
        printf '#!/bin/sh\necho "Homebrew 4.3.0"\n' > "$dir/brew"
        ;;
      uname)
        printf '#!/bin/sh\nif [ "$1" = "-m" ]; then\n  echo "arm64"\nelse\n  echo "%s"\nfi\n' "${UNAME_S:-Darwin}" > "$dir/uname"
        ;;
      awk)
        printf '#!/bin/sh\nset -- $(/usr/bin/awk 1)\necho "$*"\n' > "$dir/awk"
        ;;
      grep)
        printf '#!/bin/sh\npat=""; while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) pat="$1"; shift ;; esac; done; while IFS= read -r line; do if [[ "$line" =~ $pat ]]; then exit 0; fi; done; exit 1\n' > "$dir/grep"
        ;;
      dirname)
        printf '#!/bin/sh\necho "${1%%/*}"\n' > "$dir/dirname"
        ;;
      cat)
        printf '#!/bin/sh\ncase $# in 0) /usr/bin/awk 1; exit;; esac; echo "$@"\n' > "$dir/cat"
        ;;
    esac
    chmod +x "$dir/$cmd"
  done
}

# Create a stub gh that reports not logged in (gh auth returns exit 1)
stub_gh_not_logged_in() {
  local dir="$1"
  printf '#!/bin/sh\nexit 1\n' > "$dir/gh"
  chmod +x "$dir/gh"
}

# Global variables set by test_preflight
pf_output="" pf_ec=0

# Source bin/homefield and call cmd_preflight with a stubbed PATH.
# $1 = stub directory path
test_preflight() {
  local work_dir="$1"
  LIMA_VERSION="${LIMA_VERSION:-2.0}"
  pf_output=$(env PATH="$work_dir" HOMEFIELD_SOURCE_ONLY=1 LIMA_VERSION="$LIMA_VERSION" "$BASH_BIN" -c "
    source '$SCRIPT_DIR/bin/homefield'
    cmd_preflight
  " 2>&1)
  pf_ec=$?
}

# ── Tests ──────────────────────────────────────────────────────────────────

# All checks pass
run_test_all_pass() {
  local work; work="$(mktemp -d)"
  LIMA_VERSION="2.0"
  stub_bin "$work" limactl gh python3 brew uname awk grep dirname cat
  test_preflight "$work"

  if [ "$pf_ec" -eq 0 ] && echo "$pf_output" | grep -q "All checks passed"; then
    local ok_count; ok_count=$(echo "$pf_output" | grep -c "  OK" || true)
    record "all pass: exit 0, 6 OK" "$ok_count" "6"
  else
    record "all pass: exit 0, 6 OK" "pass" "fail (exit $pf_ec)"
  fi
}

# Lima missing (no limactl in stub)
run_test_lima_missing() {
  local work; work="$(mktemp -d)"
  stub_bin "$work" gh python3 brew uname awk grep dirname cat
  test_preflight "$work"

  if echo "$pf_output" | grep -q "FAIL.*Lima.*brew install lima"; then
    record "Lima missing: fix command present" "present" "present"
  else
    record "Lima missing: fix command present" "present" "not found"
  fi
}

# Lima version < 2.0
run_test_lima_old() {
  local work; work="$(mktemp -d)"
  LIMA_VERSION="1.5.0"
  stub_bin "$work" limactl gh python3 brew uname awk grep dirname cat
  test_preflight "$work"

  if echo "$pf_output" | grep -q ">= 2.0"; then
    record "Lima < 2.0: reports version" "present" "present"
  else
    record "Lima < 2.0: reports version" "present" "not found"
  fi
}

# gh missing (no gh in stub)
run_test_gh_missing() {
  local work; work="$(mktemp -d)"
  stub_bin "$work" limactl python3 brew uname awk grep dirname cat
  test_preflight "$work"

  if echo "$pf_output" | grep -q "FAIL.*gh.*brew install gh"; then
    record "gh missing: fix command present" "present" "present"
  else
    record "gh missing: fix command present" "present" "not found"
  fi
}

# gh not logged in
run_test_gh_not_logged_in() {
  local work; work="$(mktemp -d)"
  stub_bin "$work" limactl gh python3 brew uname awk grep dirname cat
  stub_gh_not_logged_in "$work"  # overrides the gh stub
  test_preflight "$work"

  if echo "$pf_output" | grep -q "FAIL.*gh not logged in"; then
    record "gh not logged in: message present" "present" "present"
  else
    record "gh not logged in: message present" "present" "not found"
  fi
}

# python3 missing (no python3 in stub)
run_test_python_missing() {
  local work; work="$(mktemp -d)"
  stub_bin "$work" limactl gh brew uname awk grep dirname cat
  test_preflight "$work"

  if echo "$pf_output" | grep -q "FAIL.*python3"; then
    record "python3 missing: message present" "present" "present"
  else
    record "python3 missing: message present" "present" "not found"
  fi
}

# brew missing (no brew in stub)
run_test_brew_missing() {
  local work; work="$(mktemp -d)"
  stub_bin "$work" limactl gh python3 uname awk grep dirname cat
  test_preflight "$work"

  if echo "$pf_output" | grep -q "FAIL.*brew"; then
    record "brew missing: message present" "present" "present"
  else
    record "brew missing: message present" "present" "not found"
  fi
}

# Not macOS (Linux)
run_test_not_darwin() {
  local work; work="$(mktemp -d)"
  stub_bin "$work" limactl gh python3 brew uname awk grep dirname cat
  printf '#!/bin/sh\nif [ "$1" = "-m" ]; then\n  echo "x86_64"\nelse\n  echo "Linux"\nfi\n' > "$work/uname"
  chmod +x "$work/uname"
  test_preflight "$work"

  if echo "$pf_output" | grep -q "FAIL.*macOS"; then
    record "not macOS: message present" "present" "present"
  else
    record "not macOS: message present" "present" "not found"
  fi
}

# Not arm64 (x86_64)
run_test_not_arm64() {
  local work; work="$(mktemp -d)"
  stub_bin "$work" limactl gh python3 brew uname awk grep dirname cat
  printf '#!/bin/sh\nif [ "$1" = "-m" ]; then\n  echo "x86_64"\nelse\n  echo "Darwin"\nfi\n' > "$work/uname"
  chmod +x "$work/uname"
  test_preflight "$work"

  if echo "$pf_output" | grep -q "FAIL.*arm64"; then
    record "not arm64: message present" "present" "present"
  else
    record "not arm64: message present" "present" "not found"
  fi
}

# Run all tests
run_test_all_pass
run_test_lima_missing
run_test_lima_old
run_test_gh_missing
run_test_gh_not_logged_in
run_test_python_missing
run_test_brew_missing
run_test_not_darwin
run_test_not_arm64

# Summary
summary
