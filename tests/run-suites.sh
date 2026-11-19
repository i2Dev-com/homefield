#!/bin/bash
# Run every test suite: the CI "Test suites" step, and a local convenience
# (`bash tests/run-suites.sh`). lib.sh and fakes.sh are helpers, not suites,
# and this script is the driver, not a suite.
#
# The suites run in a bounded worker pool instead of one by one: they are
# independent processes whose cost is spawning thousands of short-lived
# stub commands, and run sequentially they sum to minutes that the pool
# collapses to roughly the slowest few. TEST_CONCURRENCY overrides the pool
# size (the default is the machine's CPU count, capped at 8 — more workers
# than that buys nothing on a CI runner and only multiplies the process
# trees). Each suite's output is captured and printed in order afterwards,
# so the log reads like the sequential loop this replaced, with one
# ::group:: per suite. A failing suite does not stop the others: every
# failure is reported, and the exit status is 1 when any failed.
# DOCS_ONLY=true runs only the release-refs check, as CI's docs-only
# short-circuit did before this script existed.
set -uo pipefail

if [ "${DOCS_ONLY:-false}" = "true" ]; then
  echo "::group::tests/release-refs.sh"
  bash tests/release-refs.sh
  rc=$?
  echo "::endgroup::"
  exit "$rc"
fi

concurrency="${TEST_CONCURRENCY:-}"
if [ -z "$concurrency" ]; then
  concurrency="$(nproc 2>/dev/null)" ||
    concurrency="$(sysctl -n hw.ncpu 2>/dev/null)" ||
    concurrency=4
fi
case "$concurrency" in '' | *[!0-9]*) concurrency=4 ;; esac
[ "$concurrency" -ge 1 ] || concurrency=4
[ "$concurrency" -le 8 ] || concurrency=8

suites=""
for suite in routing-guard/tests/run.sh tests/*.sh; do
  case "$suite" in
    tests/lib.sh | tests/fakes.sh | tests/run-suites.sh) continue ;;
  esac
  suites="$suites $suite"
done

work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT
export WORKDIR="$work"

# The pool: xargs keeps $concurrency suites running, feeding the next one
# as a worker frees. Each suite writes its own log, exit code, and wall
# time; the ordered report below prints them.
printf '%s\n' $suites |
  xargs -P "$concurrency" -n 1 bash -c '
    suite="$1"
    base="${suite//\//.}"
    log="$WORKDIR/$base.log"
    t0=$(date +%s)
    bash "$suite" >"$log" 2>&1
    echo "$?" >"$WORKDIR/$base.rc"
    echo $(( $(date +%s) - t0 )) >"$WORKDIR/$base.time"
    ' _

status=0
for suite in $suites; do
  base="${suite//\//.}"
  echo "::group::$suite"
  cat "$work/$base.log"
  rc="$(cat "$work/$base.rc" 2>/dev/null || echo 1)"
  echo "::endgroup::"
  if [ "$rc" -ne 0 ]; then
    echo "::error::$suite failed"
    status=1
  fi
done

# The wall clock the step reports does not say where it went: with the
# pool, the slowest suite is the floor, and this is how the next
# optimization target shows itself.
echo "::group::Suite wall times (slowest first)"
for suite in $suites; do
  base="${suite//\//.}"
  printf '%5ss  %s\n' "$(cat "$work/$base.time" 2>/dev/null || echo '?')" "$suite"
done | sort -rn
echo "::endgroup::"
exit "$status"