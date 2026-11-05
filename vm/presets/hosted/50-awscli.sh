#!/usr/bin/env bash
# Provision hook, from the `hosted` preset: the official AWS CLI v2 bundle.
#
# Ubuntu noble has no `awscli` package (removed from the archive in February
# 2024), so RUNNER_EXTRA_PACKAGES cannot supply it; see docs/runbook.md,
# "Adding tools". Runs as root on every provisioning run, so it skips when aws
# is already installed and otherwise installs upstream's current bundle for
# this architecture (the hosted image rebuilds weekly; a job whose version
# matters pins its own).
set -euo pipefail

if [ -x /usr/local/bin/aws ]; then
  exit 0
fi

case "$(uname -m)" in
  aarch64 | arm64) arch=aarch64 ;;
  x86_64 | amd64) arch=x86_64 ;;
  *)
    echo "50-awscli.sh: unsupported architecture $(uname -m); install the AWS CLI by hand" >&2
    exit 1
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$tmp/awscliv2.zip"
unzip -q "$tmp/awscliv2.zip" -d "$tmp"
# The bundle's installer puts the CLI in /usr/local/aws-cli and links
# /usr/local/bin/aws, as it does on a hosted runner.
"$tmp/aws/install"
[ -x /usr/local/bin/aws ] || {
  echo "50-awscli.sh: aws is not at /usr/local/bin after the official install" >&2
  exit 1
}
