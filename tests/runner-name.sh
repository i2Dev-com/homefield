#!/usr/bin/env bash
# RUNNER_NAME and RUNNER_GROUP validation in provision.sh: both reach
# config.sh and the group API as single argv elements, so this is not
# injection — the checks make a bad value fail locally, before provisioning,
# instead of as a round-trip to GitHub with a confusing error. A runner
# group's name may carry spaces (the host creates and finds them:
# tests/runner-group.sh), so the validation allows them too.
#
# Run:  bash tests/runner-name.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck disable=SC1091  # lib.sh is sourced, not followed

name() { record "RUNNER_NAME [$1]" "$2" "$(provision_verdict RUNNER_NAME "$1")"; }
# RUNNER_GROUP is only kept for an organization URL (a repository runner has
# no group), so the verdict runs with one set.
group_verdict() {
  local out
  out="$(env RUNNER_URL=https://github.com/acme RUNNER_GROUP="$1" bash "$ROOT/vm/provision.sh" </dev/null 2>&1 | head -1)"
  case "$out" in
    "provision.sh: run as root (sudo)") echo ok ;;
    "provision.sh: RUNNER_GROUP"*) echo reject ;;
    *) echo "unexpected: $out" ;;
  esac
}
group() { record "RUNNER_GROUP [$1]" "$2" "$(group_verdict "$1")"; }

# The default name is the hostname; any letter/digit form is taken.
name "mds-mac-book-pro" ok
name "homefield-2.ci_x" ok
name "" ok
name "-leading dash" ok
name "bad/name" reject
name "bad;id" reject
# shellcheck disable=SC2016  # the literal text is the point
name 'bad$(id)' reject
# Group names with spaces exist and are supported by the host side.
group "homefield-ci" ok
group "Local CI" ok
group "ci.v2_x-1" ok
group "" ok
group "bad/group" reject
group "bad;id" reject

summary