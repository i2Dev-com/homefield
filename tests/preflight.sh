#!/usr/bin/env bash
# tests/preflight.sh — `homefield preflight`, the pre-install readiness check.
#
# Sources bin/homefield and calls cmd_preflight with a PATH holding only stubs,
# so every check passes or fails by what the stubs provide, never by what this
# machine has: gh, limactl, brew and python3 are left out of the stub dir to
# make them missing, and the stubs print the formats the real tools print.
# Every failing case asserts the exit code as well as the message, so a suite
# with a command that returns 0 on failure cannot pass.
#
# Run:  bash tests/preflight.sh
# Exit: 0 when every case passes, 1 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# stub_dir <dir> <cmd...>: write a stub for each command, emulating the real
# output format. The heredocs are quoted so the stubs carry no shell
# expansions of the test's own; nothing here uses bash-only syntax, as the
# stubs run under `#!/bin/sh` (dash on the CI runner).
stub_dir() {
  local dir="$1"; shift
  mkdir -p "$dir"
  for cmd in "$@"; do
    case "$cmd" in
      limactl)
        cat >"$dir/limactl" <<'EOF'
#!/bin/sh
echo "limactl version ${LIMA_VERSION:-2.3.0}"
EOF
        ;;
      gh)
        cat >"$dir/gh" <<'EOF'
#!/bin/sh
echo "$*" >>"$GH_CALLS"
# `gh --version` decides preflight's gh-version row (GH_MIN_MAJOR/MINOR).
if [ "$1" = "--version" ]; then
  echo "gh version ${GH_VERSION:-2.90.0}"
  exit 0
fi
# `gh auth status --json hosts` exits 0 even when nobody is logged in and
# prints {"hosts":{}}; the message goes to stderr. --jq prints one line.
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  if [ "$3" = "--json" ] && [ "$5" = "--jq" ]; then
    echo "${GH_JQ_OUT:-stub-user|admin:org, repo}"
  elif [ "$3" = "--json" ]; then
    echo "${GH_HOSTS:-{\"hosts\":{\"github.com\":[{\"state\":\"success\",\"active\":true,\"host\":\"github.com\",\"login\":\"stub-user\",\"tokenSource\":\"keyring\",\"scopes\":\"admin:org, repo\",\"gitProtocol\":\"ssh\"}]}}}"
  fi
  echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2
  exit 0
fi
echo "stub gh $*"
exit 0
EOF
        ;;
      python3)
        cat >"$dir/python3" <<'EOF'
#!/bin/sh
# PY_BROKEN=1 emulates a shim that resolves on PATH but cannot run: it prints
# an error and exits non-zero.
if [ "${PY_BROKEN:-}" = "1" ]; then
  echo "python3: interpreter unavailable"
  exit 1
fi
echo "Python ${PY_VERSION:-3.12.0}"
EOF
        ;;
      brew)
        cat >"$dir/brew" <<'EOF'
#!/bin/sh
echo "Homebrew ${BREW_VERSION:-4.3.0}"
EOF
        ;;
      uname)
        cat >"$dir/uname" <<'EOF'
#!/bin/sh
case "$1" in
  -s) echo "${FAKE_UNAME_S:-Darwin}" ;;
  -m) echo "${FAKE_UNAME_M:-arm64}" ;;
  -r) echo "${FAKE_UNAME_R:-25.6.0}" ;;
esac
EOF
        ;;
      sw_vers)
        cat >"$dir/sw_vers" <<'EOF'
#!/bin/sh
echo "${FAKE_SW_VERS:-26.6.2}"
EOF
        ;;
      awk)
        # bin/homefield passes awk a program (`'{print $NF}'`); the real awk
        # reads it, so the stub must not print the whole input line.
        cat >"$dir/awk" <<'EOF'
#!/bin/sh
exec /usr/bin/awk "$@"
EOF
        ;;
      dirname)
        cat >"$dir/dirname" <<'EOF'
#!/bin/sh
case "$1" in
  */*) echo "${1%/*}" ;;
  *) echo "." ;;
esac
EOF
        ;;
    esac
    chmod +x "$dir/$cmd"
  done
}

# The bash that runs the sourced tool, resolved before the PATH swap: a stub
# PATH holds no bash, and CI sets no $BASH (Homebrew happens to).
BASH_BIN="$(command -v bash)"

# preflight <stub-dir> [env assignments...]: run cmd_preflight against the stubs.
# Sets pf_out (stdout) and pf_rc. GH_HOSTS/GH_JQ_OUT default to a logged-in
# account with admin:org, so a case overrides only the one it is testing.
# The -c script is expanded by that bash, not by this suite. Color options and
# HOMEFIELD_COLOR/NO_COLOR among the assignments are handed to color_init, the
# same entry point main uses, so the tests exercise the real switch handling.
# shellcheck disable=SC2016
preflight() {
  local dir="$1"; shift
  local color_args="" env_pairs=() a
  for a in "$@"; do
    case "$a" in
      --color=*) color_args="$color_args $a" ;;
      HOMEFIELD_COLOR=*|NO_COLOR=*) env_pairs+=("$a") ;;
      *) env_pairs+=("$a") ;;
    esac
  done
  pf_out="$(env PATH="$dir" HOMEFIELD_SOURCE_ONLY=1 \
    GH_HOSTS="${GH_HOSTS-}" GH_JQ_OUT="${GH_JQ_OUT-}" ${env_pairs[@]+"${env_pairs[@]}"} \
    "$BASH_BIN" -c '. "$1"; color_init'"$color_args"'; cmd_preflight' _ "$ROOT/bin/homefield" 2>&1)"
  pf_rc=$?
}

# ok_stub <dir>: the stubs every check needs, all healthy. The gh stub prints
# whatever GH_HOSTS and GH_JQ_OUT hold, so a case can swap in another account.
ok_stub() {
  stub_dir "$1" limactl gh python3 brew uname sw_vers awk dirname
}

# has <text> <substring>: whether a preflight line contains the substring.
has() {
  case "$1" in *"$2"*) return 0 ;; esac
  return 1
}

# ── Cases ──────────────────────────────────────────────────────────────────

# case_all_pass: everything present and healthy → 0, 6 OK lines, no FAIL/WARN.
case_all_pass() {
  local d="$work/all"; ok_stub "$d"
  preflight "$d" GH_CALLS="$d/calls"
  local oks
  oks="$(printf '%s\n' "$pf_out" | grep -c '^  OK')"
  if [ "$pf_rc" -eq 0 ] && [ "$oks" -eq 6 ] && has "$pf_out" "All checks passed (6/6)."; then
    record "all pass: exit 0, 6 OK, summary" "$pf_rc/$oks" "0/6"
  else
    record "all pass: exit 0, 6 OK, summary" "$pf_rc/$oks" "0/6 (got: $pf_out)"
  fi
}

# case_missing <name> <cmd> <expected FAIL substring>: leaving one command out
# of the stubs must fail that check, name its fix command, and exit 1.
case_missing() {
  local name="$1" skip="$2" want="$3" d="$work/missing-$2" cmd
  stub_dir "$d" limactl gh python3 brew uname sw_vers awk dirname
  rm -f "$d/$skip"
  preflight "$d"
  if [ "$pf_rc" -eq 1 ] && has "$pf_out" "$want" && has "$pf_out" "FAILED 1/6 check(s)."; then
    record "$name: FAIL with fix command, exit 1" "$pf_rc" "1"
  else
    record "$name: FAIL with fix command, exit 1" "$pf_rc" "1 (got: $pf_out)"
  fi
}

# case_lima_old: Lima 1.x present → FAIL naming the found version, exit 1.
case_lima_old() {
  local d="$work/lima-old"; ok_stub "$d"
  preflight "$d" LIMA_VERSION="1.5.0"
  if [ "$pf_rc" -eq 1 ] && has "$pf_out" "Lima >= 2.3 required, found 1.5.0"; then
    record "Lima 1.5.0: FAIL with found version, exit 1" "$pf_rc" "1"
  else
    record "Lima 1.5.0: FAIL with found version, exit 1" "$pf_rc" "1 (got: $pf_out)"
  fi
}

# case_gh_logged_out: gh present, nobody logged in (empty hosts) → FAIL, exit 1.
case_gh_logged_out() {
  local d="$work/gh-out"; ok_stub "$d"
  preflight "$d" GH_HOSTS='{"hosts":{}}' GH_JQ_OUT='|'
  if [ "$pf_rc" -eq 1 ] && has "$pf_out" "FAIL  gh not logged in: run 'gh auth login'"; then
    record "gh logged out: FAIL with fix command, exit 1" "$pf_rc" "1"
  else
    record "gh logged out: FAIL with fix command, exit 1" "$pf_rc" "1 (got: $pf_out)"
  fi
}

# case_gh_logged_out_terminal: even on a terminal (have_terminal forced true),
# preflight only reports a logged-out gh: it never offers `gh auth login`, which
# is setup's alone (#146), and never runs it. The report is the same as without
# a terminal.
# shellcheck disable=SC2016
case_gh_logged_out_terminal() {
  local d="$work/gh-out-tty" out rc calls="$work/gh-out-tty-calls"
  ok_stub "$d"
  : >"$calls"
  # The token variables are cleared: with one set, the offer would be skipped
  # for that reason, not because preflight never makes it.
  out="$(env -u GITHUB_TOKEN -u GH_TOKEN PATH="$d" HOMEFIELD_SOURCE_ONLY=1 GH_HOSTS='{"hosts":{}}' GH_JQ_OUT='|' GH_CALLS="$calls" \
    "$BASH_BIN" -c '. "$1"; have_terminal() { true; }; cmd_preflight' _ "$ROOT/bin/homefield" 2>&1 </dev/null)"
  rc=$?
  if [ "$rc" -eq 1 ] && has "$out" "FAIL  gh not logged in: run 'gh auth login'" &&
    ! has "$out" "[Y/n]" && ! grep -q '^auth login' "$calls"; then
    record "gh logged out on a terminal: preflight reports it, never offers or runs a login" "$rc" "1"
  else
    record "gh logged out on a terminal: preflight reports it, never offers or runs a login" "$rc" "1 (got: $out; calls: $(cat "$calls"))"
  fi
}

# case_gh_uses_helper: preflight's gh row comes from gh_active_account, the
# helper setup's login offer asks too (#146). The helper is replaced after the
# tool is sourced, with an account the gh stub knows nothing about, so a
# preflight that asked gh on its own would report the stub's account instead.
# And a helper that cannot answer (non-zero) is a logged-out gh, as it was
# before the helper existed.
# shellcheck disable=SC2016
case_gh_uses_helper() {
  local d="$work/gh-helper" out rc
  ok_stub "$d"
  out="$(env PATH="$d" HOMEFIELD_SOURCE_ONLY=1 \
    "$BASH_BIN" -c '. "$1"; gh_active_account() { echo "override-user|admin:org"; }; cmd_preflight' _ "$ROOT/bin/homefield" 2>&1 </dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ] && has "$out" "OK    gh authenticated as override-user (admin:org scope)"; then
    record "preflight's gh row comes from gh_active_account" "$rc" "0"
  else
    record "preflight's gh row comes from gh_active_account" "$rc" "0 (got: $out)"
  fi
  out="$(env PATH="$d" HOMEFIELD_SOURCE_ONLY=1 \
    "$BASH_BIN" -c '. "$1"; gh_active_account() { return 1; }; cmd_preflight' _ "$ROOT/bin/homefield" 2>&1 </dev/null)"
  rc=$?
  if [ "$rc" -eq 1 ] && has "$out" "FAIL  gh not logged in: run 'gh auth login'"; then
    record "...a helper that cannot answer reads as not logged in, as before" "$rc" "1"
  else
    record "...a helper that cannot answer reads as not logged in, as before" "$rc" "1 (got: $out)"
  fi
}

# case_gh_app_token: the active account is an App-installed token, which
# reports no scopes, and an inactive account with scopes sits beside it. That
# must be OK (not FAIL, not WARN), exit 0.
case_gh_app_token() {
  local d="$work/gh-app"; ok_stub "$d"
  preflight "$d" GH_HOSTS='{"hosts":{"github.com":[{"active":true,"login":"bot[bot]"},{"active":false,"login":"person","scopes":"repo"}]}}' \
    GH_JQ_OUT='bot[bot]|'
  if [ "$pf_rc" -eq 0 ] && has "$pf_out" "OK    gh authenticated as bot[bot]" &&
    ! has "$pf_out" "FAIL" && ! has "$pf_out" "WARN"; then
    record "gh App token active: OK, exit 0" "$pf_rc" "0"
  else
    record "gh App token active: OK, exit 0" "$pf_rc" "0 (got: $pf_out)"
  fi
}

# case_gh_scope_warn: active account with scopes but no admin:org → WARN with
# the refresh command, still exit 0 (the check is only a warning).
case_gh_scope_warn() {
  local d="$work/gh-warn"; ok_stub "$d"
  preflight "$d" GH_JQ_OUT='person|repo, read:org'
  if [ "$pf_rc" -eq 0 ] && has "$pf_out" "WARN  gh authenticated as person" &&
    has "$pf_out" "gh auth refresh -s admin:org" && has "$pf_out" "All checks passed (6/6)."; then
    record "gh no admin:org scope: WARN, exit 0" "$pf_rc" "0"
  else
    record "gh no admin:org scope: WARN, exit 0" "$pf_rc" "0 (got: $pf_out)"
  fi
}

# case_gh_scope_order: GitHub reports the scopes comma-space separated, and
# the order is its own ("repo, admin:org" was seen). The check must match
# admin:org wherever it sits in the string, not only first (#165).
case_gh_scope_order() {
  local d="$work/gh-order"; ok_stub "$d"
  preflight "$d" GH_JQ_OUT='person|repo, admin:org, workflow'
  if [ "$pf_rc" -eq 0 ] && has "$pf_out" "OK    gh authenticated as person (admin:org scope)"; then
    record "gh admin:org not first in the scopes: OK, exit 0" "$pf_rc" "0"
  else
    record "gh admin:org not first in the scopes: OK, exit 0" "$pf_rc" "0 (got: $pf_out)"
  fi
}

# case_mixed: Lima and gh both fail → 2 failures, exit 1.
case_mixed() {
  local d="$work/mixed"; ok_stub "$d"
  rm -f "$d/limactl"
  preflight "$d" GH_JQ_OUT='|'
  if [ "$pf_rc" -eq 1 ] && has "$pf_out" "FAILED 2/6 check(s)." &&
    has "$pf_out" "FAIL  Lima not found" && has "$pf_out" "FAIL  gh not logged in"; then
    record "Lima + gh fail: FAILED 2/6, exit 1" "$pf_rc" "1"
  else
    record "Lima + gh fail: FAILED 2/6, exit 1" "$pf_rc" "1 (got: $pf_out)"
  fi
}

# case_not_macos: uname says Linux → macOS FAIL, exit 1.
case_not_macos() {
  local d="$work/linux"; ok_stub "$d"
  preflight "$d" FAKE_UNAME_S="Linux" FAKE_UNAME_M="x86_64"
  if [ "$pf_rc" -eq 1 ] && has "$pf_out" "FAIL  needs macOS (Darwin): found Linux"; then
    record "not macOS: FAIL with found value, exit 1" "$pf_rc" "1"
  else
    record "not macOS: FAIL with found value, exit 1" "$pf_rc" "1 (got: $pf_out)"
  fi
}

# case_not_arm64: Darwin on x86_64 → arm64 FAIL, exit 1.
case_not_arm64() {
  local d="$work/intel"; ok_stub "$d"
  preflight "$d" FAKE_UNAME_M="x86_64"
  if [ "$pf_rc" -eq 1 ] && has "$pf_out" "FAIL  needs Apple Silicon (arm64): found x86_64"; then
    record "not arm64: FAIL with found value, exit 1" "$pf_rc" "1"
  else
    record "not arm64: FAIL with found value, exit 1" "$pf_rc" "1 (got: $pf_out)"
  fi
}

# case_macos_version: the OK line carries the product version, not the kernel.
case_macos_version() {
  local d="$work/version"; ok_stub "$d"
  preflight "$d" FAKE_SW_VERS="14.5" FAKE_UNAME_R="23.4.0"
  if [ "$pf_rc" -eq 0 ] && has "$pf_out" "OK    macOS 14.5" && ! has "$pf_out" "23.4.0"; then
    record "macOS line: product version, not kernel" "$pf_rc" "0"
  else
    record "macOS line: product version, not kernel" "$pf_rc" "0 (got: $pf_out)"
  fi
}

# case_broken_python: python3 resolves but cannot run (prints an error, exits
# 1) → the version status makes it a FAIL, not an OK, and exit 1.
case_broken_python() {
  local d="$work/python-broken"; ok_stub "$d"
  preflight "$d" PY_BROKEN=1
  if [ "$pf_rc" -eq 1 ] && has "$pf_out" "FAIL  python3 cannot run (python3: interpreter unavailable)" &&
    has "$pf_out" "FAILED 1/6 check(s)." && ! has "$pf_out" "OK    python3"; then
    record "python3 cannot run: FAIL, exit 1" "$pf_rc" "1"
  else
    record "python3 cannot run: FAIL, exit 1" "$pf_rc" "1 (got: $pf_out)"
  fi
}

# case_gh_too_old: gh resolves but reports a version below the floor
# (GH_MIN_MAJOR/MINOR in github.sh). That is a FAIL with the upgrade command —
# an old gh would otherwise surface as an opaque API error mid-setup.
case_gh_too_old() {
  local d="$work/gh-old"; ok_stub "$d"
  preflight "$d" GH_VERSION="2.28.3" GH_JQ_OUT='stub-user|admin:org, repo'
  if [ "$pf_rc" -eq 1 ] && has "$pf_out" "FAIL  gh >= 2.81 required (auth status --json, api --jq), found 2.28: run 'brew upgrade gh'"; then
    record "gh below the 2.81 floor: FAIL with the upgrade command, exit 1" "$pf_rc" "1"
  else
    record "gh below the 2.81 floor: FAIL with the upgrade command, exit 1" "$pf_rc" "1 (got: $pf_out)"
  fi
  # At the floor exactly: OK.
  preflight "$d" GH_VERSION="2.81.0"
  if [ "$pf_rc" -eq 0 ] && has "$pf_out" "OK    gh authenticated as"; then
    record "gh at the 2.81 floor exactly: OK, exit 0" "$pf_rc" "0"
  else
    record "gh at the 2.81 floor exactly: OK, exit 0" "$pf_rc" "0 (got: $pf_out)"
  fi
}

case_all_pass
case_missing "limactl missing" limactl "FAIL  Lima not found: run 'brew install lima'"
case_lima_old
case_missing "gh missing" gh "FAIL  gh (GitHub CLI) not found: run 'brew install gh'"
case_gh_too_old
case_gh_logged_out
case_gh_logged_out_terminal
case_gh_uses_helper
case_gh_app_token
case_gh_scope_warn
case_gh_scope_order
case_missing "python3 missing" python3 "FAIL  python3 not found: run 'brew install python'"
case_broken_python
case_missing "brew missing" brew "FAIL  brew not found: install Homebrew from https://brew.sh"
case_mixed
case_not_macos
case_not_arm64
case_macos_version

# ── Color ───────────────────────────────────────────────────────────────────
# Colors are off unless stdout is a terminal or --color=always / HOMEFIELD_COLOR
# says so; NO_COLOR wins over everything; --color=never wins over the variable.
# Every case here runs with stdout piped (command substitution), so "auto"
# means off, and any case wanting color passes --color=always.

# case_color_off_by_default: piped output carries no ANSI escapes, and the
# plain-text prefixes the other cases assert on are untouched.
case_color_off_by_default() {
  local d="$work/color-default"; ok_stub "$d"
  preflight "$d"
  if [ "$pf_rc" -eq 0 ] && ! printf '%s' "$pf_out" | grep -q "$(printf '\033')" &&
    has "$pf_out" "OK    Lima" && has "$pf_out" "All checks passed (6/6)."; then
    record "color: piped output has no ANSI and plain prefixes" "plain" "plain"
  else
    record "color: piped output has no ANSI and plain prefixes" "plain" "colored (got: $pf_out)"
  fi
}

# case_color_always: --color=always colors the level prefixes and the summary,
# keeping the message text itself unchanged. The grep patterns escape [ with a
# backslash: a literal `\033[32m` inside a BRE bracket expression is not what
# it looks like.
case_color_always() {
  local d="$work/color-always"; ok_stub "$d"
  preflight "$d" --color=always
  if [ "$pf_rc" -eq 0 ] && printf '%s' "$pf_out" | grep -q "$(printf '\033\[32m')" &&
    has "$pf_out" "OK" && has "$pf_out" "Lima 2.3.0" &&
    has "$pf_out" "All checks passed (6/6)."; then
    record "color: --color=always colors OK green, text intact" "green" "green"
  else
    record "color: --color=always colors OK green, text intact" "green" "not green (got: $pf_out)"
  fi
}

# case_color_no_color_env: NO_COLOR=1 beats --color=always.
case_color_no_color_env() {
  local d="$work/color-nocolor"; ok_stub "$d"
  preflight "$d" --color=always NO_COLOR=1
  if [ "$pf_rc" -eq 0 ] && ! printf '%s' "$pf_out" | grep -q "$(printf '\033')"; then
    record "color: NO_COLOR beats --color=always" "plain" "plain"
  else
    record "color: NO_COLOR beats --color=always" "plain" "colored (got: $pf_out)"
  fi
}

# case_color_never: --color=never beats HOMEFIELD_COLOR=always.
case_color_never() {
  local d="$work/color-never"; ok_stub "$d"
  preflight "$d" --color=never HOMEFIELD_COLOR=always
  if [ "$pf_rc" -eq 0 ] && ! printf '%s' "$pf_out" | grep -q "$(printf '\033')"; then
    record "color: --color=never beats HOMEFIELD_COLOR" "plain" "plain"
  else
    record "color: --color=never beats HOMEFIELD_COLOR" "plain" "colored (got: $pf_out)"
  fi
}

# case_color_env: HOMEFIELD_COLOR=always colors piped output.
case_color_env() {
  local d="$work/color-env"; ok_stub "$d"
  preflight "$d" HOMEFIELD_COLOR=always
  if [ "$pf_rc" -eq 0 ] && printf '%s' "$pf_out" | grep -q "$(printf '\033\[32m')"; then
    record "color: HOMEFIELD_COLOR=always colors piped output" "green" "green"
  else
    record "color: HOMEFIELD_COLOR=always colors piped output" "green" "not green (got: $pf_out)"
  fi
}

# case_color_warn_fail: WARN is yellow, FAIL red. The gh stub is given scopes
# without admin:org (the WARN source) and brew is removed (the FAIL source),
# so one run carries both a yellow and a red marker.
case_color_warn_fail() {
  local d="$work/color-levels"
  stub_dir "$d" limactl gh python3 brew uname sw_vers awk dirname
  rm -f "$d/brew"
  preflight "$d" --color=always GH_JQ_OUT='person|repo, read:org'
  local yellow red
  yellow="$(printf '\033\[33m')"; red="$(printf '\033\[31m')"
  if [ "$pf_rc" -eq 1 ] && printf '%s' "$pf_out" | grep -q "$yellow" &&
    printf '%s' "$pf_out" | grep -q "$red"; then
    record "color: WARN yellow, FAIL red" "yellow+red" "yellow+red"
  else
    record "color: WARN yellow, FAIL red" "yellow+red" "(got: $pf_out)"
  fi
}

case_color_off_by_default
case_color_always
case_color_no_color_env
case_color_never
case_color_env
case_color_warn_fail

summary
