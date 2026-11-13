#!/usr/bin/env bash
# The tree claims exactly one release. A release is cut by editing several
# independent declarations — install.sh's REF and header, the update check's
# comparison, tools/adopt.py's RELEASE, the README/docs pins and the suites
# that assert them. Nothing at runtime derives one from another, so a missed
# edit is silent until the affected suite runs. This suite derives the release
# once from tools/adopt.py and checks every declaration point that must track
# it; historical releases in CHANGELOG/docs/security stay untouched.
#
# Run:  bash tests/release-refs.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

release="$(python3 -B -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import adopt; print(adopt.RELEASE)' "$ROOT/tools")"
if [[ ! "$release" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "tests: tools/adopt.py RELEASE is not a vX.Y.Z release: '${release}'" >&2
  exit 1
fi
action="i2Dev-com/homefield/routing-guard@${release}"

has_text() {
  [ -f "$1" ] && grep -qF -- "$2" "$1" && echo yes || echo no
}
check_text() {
  record "$1" yes "$(has_text "$2" "$3")"
}

check_text "install.sh's default REF is ${release}" install.sh "REF=\"\${HOMEFIELD_REF:-${release}}\""
check_text "install.sh's header one-liner names ${release}" install.sh "/homefield/${release}/install.sh"
check_text "cmd-version.sh's update-check comparison is ${release}" bin/cmd-version.sh "[ \"\$ref\" = ${release} ]"
check_text "tools/adopt.py RELEASE is ${release}" tools/adopt.py "RELEASE = \"${release}\""

check_text "README.md pins the routing guard at ${release}" README.md "${action}"
check_text "README.md's quick start names ${release}" README.md "/homefield/${release}/install.sh"
check_text "docs/cli.md's one-liner names ${release}" docs/cli.md "/homefield/${release}/install.sh"

# Every guard pin in the adoption guide is the current release (this file has
# no historical pins; docs/security.md deliberately does, so it is excluded).
pins="$(grep -oE 'i2Dev-com/homefield/routing-guard@v[0-9]+\.[0-9]+\.[0-9]+' docs/adopting.md | sort -u | tr '\n' ' ')"
pins="${pins% }"
record "docs/adopting.md pins only ${release}" "${action}" "${pins}"

# The suite fixtures that encode the default release must move with it.
check_text "tests/install-sh.sh expects the default gh tarball at ${release}" tests/install-sh.sh "tarball/${release}\$"
check_text "tests/install-sh.sh expects the default codeload URL at ${release}" tests/install-sh.sh "tar.gz/${release}"
check_text "tests/install-sh.sh expects the recorded ref ${release}" tests/install-sh.sh "ref=${release} commit=abc1234"
check_text "tests/install-sh.sh expects the installed summary at ${release}" tests/install-sh.sh "installed homefield ${release}"
check_text "tests/runner-group.sh's default-ref fixture is ${release}" tests/runner-group.sh "ref=${release}"
check_text "tests/adopt.sh's guard fixture is ${release}" tests/adopt.sh "action=\"${action}\""
check_text "tests/adopt.sh's guide URL is at ${release}" tests/adopt.sh "blob/${release}/docs/adopting.md"
check_text "tests/adopt.sh's mode-release default is ${release}" tests/adopt.sh "HOMEFIELD_MODE_RELEASE=\"\${HOMEFIELD_MODE_RELEASE:-${release}}\""

# No tagged install one-liner in a current-facing file may name another
# release. CHANGELOG.md and tasks/ keep history and are not scanned.
stale=""
for f in install.sh README.md docs/cli.md docs/adopting.md tests/runner-group.sh; do
  [ -f "$f" ] || continue
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    case "$url" in
      "/homefield/${release}/install.sh") ;;
      *) stale="${stale} ${f}:${url}" ;;
    esac
  done < <(grep -oE '/homefield/v[0-9]+\.[0-9]+\.[0-9]+/install\.sh' "$f" || true)
done
record "every tagged install one-liner names ${release}" "" "${stale# }"

summary
