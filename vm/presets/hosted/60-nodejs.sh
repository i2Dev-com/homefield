#!/usr/bin/env bash
# Provision hook, from the `hosted` preset: Node, at the major ubuntu-24.04's
# image carries (22 when this was written; bump NODE_MAJOR with that table row
# in docs/runbook.md). noble's own nodejs is older, so a job that runs a bare
# `node` or `npm` without actions/setup-node would otherwise get the wrong one.
#
# NodeSource tracks the latest patch of its channel; this hook therefore gets
# upstream at provision time. Runs as root on every provisioning run: it skips
# when node is already that major, and a job's own setup action still wins for
# the job (its install goes first on PATH).
set -euo pipefail

NODE_MAJOR=22

if command -v node >/dev/null 2>&1 &&
   [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" = "$NODE_MAJOR" ]; then
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# gpg is not in the base set, and NodeSource's repository is signed.
apt-get install -y -q ca-certificates curl gnupg
install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 3 https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
  gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg
printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' \
  "$NODE_MAJOR" >/etc/apt/sources.list.d/nodesource.list
apt-get update -q
apt-get install -y -q nodejs
node --version | grep -q "^v${NODE_MAJOR}\." || {
  echo "60-nodejs.sh: node is $(node --version), wanted v${NODE_MAJOR}.x" >&2
  exit 1
}
