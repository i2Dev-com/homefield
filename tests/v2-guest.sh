#!/usr/bin/env bash
# provision.sh refuses a guest that ci-runner v2 provisioned: v3 uses other
# paths and does not upgrade in place. The paths it looks at are prefixed by
# PROVISION_SYSROOT, so each case builds a fixture tree and the test never
# reads this machine's /etc. The check runs before the root check, so a normal
# user sees the refusal (a clean guest gets as far as "run as root").
#
# Run:  bash tests/v2-guest.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# verdict <sysroot>: the first line provision.sh prints, and its status.
run() {
  out="$(env -i PATH="$PATH" PROVISION_SYSROOT="$1" bash "$ROOT/vm/provision.sh" </dev/null 2>&1 | head -1)"
}
nonroot="provision.sh: run as root (sudo)"

# A fixture guest: root dir under $work with /etc/systemd/system.
guest() {
  rm -rf "$work/g"
  mkdir -p "$work/g/etc/systemd/system"
}

echo "v2 guest"
guest
run "$work/g"
record "a clean guest gets past the check" "$nonroot" "$out"

# v3's own files are not v2's.
guest
mkdir -p "$work/g/etc/homefield"
touch "$work/g/etc/systemd/system/homefield-cleanup.timer" "$work/g/etc/systemd/system/homefield-memwatch.service"
run "$work/g"
record "a v3 guest (/etc/homefield, homefield-* units) is accepted" "$nonroot" "$out"

guest
mkdir -p "$work/g/etc/ci-runner"
run "$work/g"
record "/etc/ci-runner: refused" "yes/yes/yes" "$(has "$out" 'provisioned by ci-runner v2')/$(has "$out" '/etc/ci-runner')/$(has "$out" 'does not upgrade it in place')"
record "...pointing at the migration section" "yes" "$(has "$out" 'Migrating from ci-runner (v2)')"

guest
touch "$work/g/etc/systemd/system/ci-runner-cleanup.timer"
run "$work/g"
record "a ci-runner-*.timer unit: refused, naming it" "yes/yes" "$(has "$out" 'provisioned by ci-runner v2')/$(has "$out" '/etc/systemd/system/ci-runner-cleanup.timer')"

guest
touch "$work/g/etc/systemd/system/ci-runner-memwatch.service"
run "$work/g"
record "a ci-runner-*.service unit: refused, naming it" "yes/yes" "$(has "$out" 'provisioned by ci-runner v2')/$(has "$out" '/etc/systemd/system/ci-runner-memwatch.service')"

guest
mkdir -p "$work/g/etc/homefield"
touch "$work/g/etc/systemd/system/homefield-cleanup.timer" "$work/g/etc/systemd/system/ci-runner-maintenance.timer"
run "$work/g"
record "v2 units next to v3 ones: still refused" "yes" "$(has "$out" 'provisioned by ci-runner v2')"

# Settings are still checked first: a bad value is reported as itself.
guest
mkdir -p "$work/g/etc/ci-runner"
out="$(env -i PATH="$PATH" PROVISION_SYSROOT="$work/g" RUNNER_LABEL=ubuntu-latest bash "$ROOT/vm/provision.sh" </dev/null 2>&1 | head -1)"
record "a bad setting is reported before the v2 check" "yes" "$(has "$out" 'RUNNER_LABEL must be a custom label')"

summary
