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
echo "limactl version ${LIMA_VERSION:-2.2.0}"
EOF
        ;;
      gh)
        cat >"$dir/gh" <<'EOF'
#!/bin/sh
echo "$*" >>"$GH_CALLS"
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
# The -c script is expanded by that bash, not by this suite.
# shellcheck disable=SC2016
preflight() {
  local dir="$1"; shift
  pf_out="$(env PATH="$dir" HOMEFIELD_SOURCE_ONLY=1 \
    GH_HOSTS="${GH_HOSTS-}" GH_JQ_OUT="${GH_JQ_OUT-}" "$@" \
    "$BASH_BIN" -c '. "$1"; cmd_preflight' _ "$ROOT/bin/homefield" 2>&1)"
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
  if [ "$pf_rc" -eq 1 ] && has "$pf_out" "Lima >= 2.0 required, found 1.5.0"; then
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

case_all_pass
case_missing "limactl missing" limactl "FAIL  Lima not found: run 'brew install lima'"
case_lima_old
case_missing "gh missing" gh "FAIL  gh (GitHub CLI) not found: run 'brew install gh'"
case_gh_logged_out
case_gh_app_token
case_gh_scope_warn
case_missing "python3 missing" python3 "FAIL  python3 not found: run 'brew install python'"
case_broken_python
case_missing "brew missing" brew "FAIL  brew not found: install Homebrew from https://brew.sh"
case_mixed
case_not_macos
case_not_arm64
case_macos_version

summary
