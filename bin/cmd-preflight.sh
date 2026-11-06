#!/usr/bin/env bash
# The preflight command: what this Mac needs before a VM can be set up.

# preflight_collect: everything an install needs, checked one by one instead of
# stopping at the first failure like check_host, into PF_NAME / PF_LEVEL /
# PF_MSG (parallel arrays, in the order preflight prints them). PF_LEVEL is ok,
# warn or fail, and a failure's message carries the command that fixes it.
# cmd_preflight prints the arrays; diagnose reads them, so the two cannot
# disagree about what a prerequisite is.
# gh is not strictly needed: without it, install asks for a pasted token, so
# gh missing is a failure to fix, gh logged out is a failure too, and a token
# without admin:org only warns (an organization URL is what needs that scope,
# a repository URL is registered with repo; `gh auth refresh -s admin:org`).
# Lima >= 2.0 is the same check as check_host's.
PF_NAME=()
PF_LEVEL=()
PF_MSG=()

preflight_collect() {
  local login scopes whoami py_version
  PF_NAME=()
  PF_LEVEL=()
  PF_MSG=()
  # Lima
  if ! command -v limactl >/dev/null 2>&1; then
    pf_add lima fail "Lima not found: run 'brew install lima'"
  else
    lima_major_minor
    if [ -z "$LIMA_MAJOR" ] || [ "$LIMA_MAJOR" -lt 2 ]; then
      pf_add lima fail "Lima >= 2.0 required, found ${LIMA_VERSION:-unknown}: run 'brew install lima'"
    else
      pf_add lima ok "Lima $LIMA_VERSION"
    fi
  fi
  # gh: the active account, by login and scopes. App-installed tokens report no
  # scopes; the `Token scopes` line of `gh auth status` is absent for them, and
  # `gh auth status` also lists accounts that are not active.
  if ! command -v gh >/dev/null 2>&1; then
    pf_add gh fail "gh (GitHub CLI) not found: run 'brew install gh'"
  else
    whoami="$(gh_active_account)" || whoami="|"
    login="${whoami%%|*}"
    scopes="${whoami#*|}"
    # GitHub reports scopes comma-space separated ("repo, admin:org"); the
    # spaces come off here, so the `,scope,` match works whichever order they
    # come back in (gh_active_account strips them too; an override in a test
    # may not).
    scopes="${scopes// /}"
    if [ -z "$login" ]; then
      pf_add gh fail "gh not logged in: run 'gh auth login'"
    elif [ -z "$scopes" ]; then
      pf_add gh ok "gh authenticated as $login (no scope reported; an organization URL needs admin:org)"
    elif case ",$scopes," in *,admin:org,*) true ;; *) false ;; esac; then
      pf_add gh ok "gh authenticated as $login (admin:org scope)"
    else
      pf_add gh warn "gh authenticated as $login, no admin:org scope (an organization URL needs it: gh auth refresh -s admin:org)"
    fi
  fi
  # python3: resolving on PATH is not enough — a broken shim prints but exits
  # non-zero, so the version command's own status decides.
  if ! command -v python3 >/dev/null 2>&1; then
    pf_add python3 fail "python3 not found: run 'brew install python'"
  elif py_version="$(python3 --version 2>&1)"; then
    pf_add python3 ok "python3 ($py_version)"
  else
    pf_add python3 fail "python3 cannot run (${py_version:-no output}): reinstall it, e.g. run 'brew install python'"
  fi
  # brew
  if command -v brew >/dev/null 2>&1; then
    pf_add brew ok "brew available"
  else
    pf_add brew fail "brew not found: install Homebrew from https://brew.sh"
  fi
  # macOS (Darwin), by product version rather than kernel release
  if [ "$(uname -s)" = "Darwin" ]; then
    pf_add macos ok "macOS $(sw_vers -productVersion)"
  else
    pf_add macos fail "needs macOS (Darwin): found $(uname -s)"
  fi
  # Apple Silicon
  if [ "$(uname -m)" = "arm64" ]; then
    pf_add arm64 ok "arm64 (Apple Silicon)"
  else
    pf_add arm64 fail "needs Apple Silicon (arm64): found $(uname -m)"
  fi
}

# cmd_preflight: preflight_collect's checks, one line each, each failure with
# the command that fixes it. Exits 0 when every check passes, 1 otherwise.
cmd_preflight() {
  local failed=0 total i level level_color
  preflight_collect
  total=${#PF_NAME[@]}
  for ((i = 0; i < total; i++)); do
    case "${PF_LEVEL[i]}" in
      ok) level=OK; level_color=1 ;;
      warn) level=WARN; level_color=2 ;;
      *) level=FAIL; level_color=3; failed=$((failed + 1)) ;;
    esac
    printf '  %s%-6s%s%s\n' "$(hf_color "$level_color")" "$level" "$(hf_color 0)" "${PF_MSG[i]}"
  done
  # Summary
  echo ""
  if [ "$failed" -eq 0 ]; then
    printf '%s\n' "$(color_wrap 1 "All checks passed (${total}/${total}).")"
    return 0
  fi
  printf '%s ' "$(color_wrap 3 "FAILED ${failed}/${total} check(s).")"
  echo "Fix the above and retry."
  return 1
}
