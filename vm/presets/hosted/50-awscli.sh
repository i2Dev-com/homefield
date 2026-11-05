#!/usr/bin/env bash
# Provision hook, from the `hosted` preset: the official AWS CLI v2 bundle.
#
# Ubuntu noble has no `awscli` package (removed from the archive in February
# 2024), so RUNNER_EXTRA_PACKAGES cannot supply it; see docs/runbook.md,
# "Adding tools". Runs as root on every provisioning run, so it skips when the
# pinned version is already installed and otherwise installs exactly that
# version. The download is checksum-pinned, like the runner binary
# (provision.sh's RUNNER_SHA256): this is the one artifact a compromised
# endpoint would flow to root with. Bumping means a new version here plus both
# digests, taken from a fresh download of the versioned URL (AWS publishes no
# digest; confirm the versioned URL's bytes match the "latest" URL's, which is
# how 2.39.4 was pinned). A job whose version matters still pins its own.
AWSCLI_VERSION=2.39.4
AWSCLI_SHA256_AARCH64=76e4ac0f82b5b1ec68dfc747705fa3298c05e22648e5503f1869f0d035ad57bb
AWSCLI_SHA256_X86_64=5153610ddd5dff13d43b2965c92d58f16e9f3f54164eea76d3abb29f38787597

set -euo pipefail

case "$(uname -m)" in
  aarch64 | arm64) arch=aarch64; want=$AWSCLI_SHA256_AARCH64 ;;
  x86_64 | amd64) arch=x86_64; want=$AWSCLI_SHA256_X86_64 ;;
  *)
    echo "50-awscli.sh: unsupported architecture $(uname -m); install the AWS CLI by hand" >&2
    exit 1
    ;;
esac

if [ -x /usr/local/bin/aws ] && /usr/local/bin/aws --version 2>&1 | grep -q "^aws-cli/${AWSCLI_VERSION} "; then
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 "https://awscli.amazonaws.com/awscli-exe-linux-${arch}-${AWSCLI_VERSION}.zip" -o "$tmp/awscliv2.zip"
echo "${want}  ${tmp}/awscliv2.zip" | sha256sum -c - >/dev/null
unzip -q "$tmp/awscliv2.zip" -d "$tmp"
# The bundle's installer puts the CLI in /usr/local/aws-cli and links
# /usr/local/bin/aws, as it does on a hosted runner; over an older version it
# upgrades in place.
"$tmp/aws/install"
[ -x /usr/local/bin/aws ] || {
  echo "50-awscli.sh: aws is not at /usr/local/bin after the official install" >&2
  exit 1
}
/usr/local/bin/aws --version 2>&1 | grep -q "^aws-cli/${AWSCLI_VERSION} " || {
  echo "50-awscli.sh: aws is not the pinned version ${AWSCLI_VERSION} after the install" >&2
  exit 1
}