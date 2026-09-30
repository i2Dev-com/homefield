#!/usr/bin/env bash
# RUNNER_URL format in provision.sh: an organization or a repository on
# github.com, nothing else, checked before provisioning starts.
#
# Run:  bash tests/runner-url.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

check() { record "[$1]" "$2" "$(provision_verdict RUNNER_URL "$1")"; }

check "" ok
check "https://github.com/acme" ok
check "https://github.com/acme/" ok
check "https://github.com/acme/app" ok
check "https://github.com/Acme-Co/app.web_2" ok
check "http://github.com/acme" reject
check "https://gitlab.com/acme" reject
check "https://github.com.evil.example/acme" reject
check "https://github.com/acme/app/extra" reject
check "https://github.com/" reject
check "github.com/acme" reject
check "https://github.com/acme app" reject

summary
