#!/usr/bin/env bash
# tests/warm.sh — vm/provision.sh's warm_guest step against stubbed docker,
# systemctl and timeout.
#
# Run:  bash tests/warm.sh
# Exit: 0 when every case passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/homefield-warm-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

STUBS="$TMP/stubs"
mkdir -p "$STUBS"
for t in awk cat dirname grep head mkdir rm sed; do
  ln -s "$(command -v "$t")" "$STUBS/$t"
done

cat >"$STUBS/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF

cat >"$STUBS/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "info" ]; then
  exit "${STUB_DOCKER_RC:-0}"
fi
exit 0
EOF

cat >"$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-}"
unit="${2:-}"
if [ "$cmd" = "--quiet" ]; then
  cmd="${2:-}"
  unit="${3:-}"
fi
case "$cmd" in
  is-active)
    unit="${3:-$unit}"
    case "$unit" in
      actions.runner.*) exit "${STUB_RUNNER_RC:-0}" ;;
      homefield-*.timer) exit "${STUB_TIMER_ACTIVE_RC:-0}" ;;
    esac
    ;;
  is-enabled)
    unit="${3:-$unit}"
    case "$unit" in
      homefield-*.timer) exit "${STUB_TIMER_ENABLED_RC:-0}" ;;
    esac
    ;;
esac
exit 0
EOF
chmod +x "$STUBS/timeout" "$STUBS/docker" "$STUBS/systemctl"

# Extract warm_guest from vm/provision.sh so we test the real function.
WARM_FN="$TMP/warm_fn.sh"
sed -n '/^warm_guest()/,/^}/p' "$REPO_ROOT/vm/provision.sh" >"$WARM_FN"

run_warm() {
  # shellcheck disable=SC2016  # inner bash -c expands $1
  env -i \
    PATH="$STUBS:$PATH" \
    STUB_DOCKER_RC="${STUB_DOCKER_RC:-0}" \
    STUB_RUNNER_RC="${STUB_RUNNER_RC:-0}" \
    STUB_TIMER_ACTIVE_RC="${STUB_TIMER_ACTIVE_RC:-0}" \
    STUB_TIMER_ENABLED_RC="${STUB_TIMER_ENABLED_RC:-0}" \
    bash -c 'set -euo pipefail; svc_unit="actions.runner.test.service"; . "$1"; warm_guest' _ "$WARM_FN" 2>&1
}

out="$(run_warm)"; rc=$?
record "all warm: exits 0 and prints warm-up complete" "0/yes" "$rc/$(has "$out" "provision.sh: warm-up complete (docker, runner, timers)")"

out="$(STUB_DOCKER_RC=1 run_warm)"; rc=$?
record "docker unresponsive: warns incomplete (docker)" "0/yes" "$rc/$(has "$out" "provision.sh: warm-up incomplete (docker)")"

out="$(STUB_RUNNER_RC=1 STUB_TIMER_ENABLED_RC=1 run_warm)"; rc=$?
record "runner + timers missing: warns incomplete (runner timers)" "0/yes" "$rc/$(has "$out" "provision.sh: warm-up incomplete (runner timers)")"

summary
