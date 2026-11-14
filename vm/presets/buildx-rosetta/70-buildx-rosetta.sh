#!/usr/bin/env bash
# Provision hook, from the `buildx-rosetta` preset: a BuildKit image without
# the bundled x86-64 QEMU emulator, so `docker buildx build --platform
# linux/amd64` steps run under Apple's Rosetta instead of segfaulting (#241).
#
# `docker run --platform linux/amd64` works on the VM out of the box: the
# kernel's Rosetta binfmt handler takes the amd64 binaries. A buildx
# docker-container builder does not reach it: buildkitd validates each
# platform by running a tiny test binary through its own bundled
# buildkit-qemu-x86_64, that dies under the Lima Rosetta mount ("signal:
# trace/breakpoint trap"), and BuildKit then wraps every amd64 RUN in QEMU —
# Node-heavy steps segfault. Upstream: moby/buildkit#7052 and
# moby/buildkit#7110, both open; when they close, this preset is retired.
# With the QEMU binary removed from the image, the validation execs directly,
# the kernel hands it to Rosetta, and amd64 steps run the same way
# `docker run --platform linux/amd64` does.
#
# Runs as root on every provisioning run, so it rebuilds only when the pinned
# base image moved: the built image carries the base's image ID in a label,
# and a matching label skips the build. The base is pinned by manifest digest,
# like every artifact a hook pulls (the AWS CLI hook's rationale applies: this
# image runs builds for PR code, as root, in the guest). Bumping is a
# deliberate change: take the multi-arch index digest from
# `docker buildx imagetools inspect moby/buildkit:buildx-stable-1` (the
# `Digest:` line), put it in BASE and the FROM line below, and note it in the
# changelog.

set -euo pipefail

BASE="moby/buildkit:buildx-stable-1@sha256:c5f8862f52499773af85bc07695b2379ef08e8002352b0df2c4864c91d78dabe"
IMAGE="buildkit-rosetta"
LABEL="homefield.base-id"

# The base image: pull only when it is not already on the VM (every provision
# run reaches here, and a pull per run is wasted bandwidth for an unchanged
# digest).
base="$(docker image inspect "$BASE" --format '{{.Id}}' 2>/dev/null || true)"
if [ -z "$base" ]; then
  docker pull "$BASE"
  base="$(docker image inspect "$BASE" --format '{{.Id}}')"
fi

# The built image, labeled with the base it came from. An image without the
# label — one built by hand from the issue's snippet — reads as stale and is
# rebuilt, which also moves it onto the pinned digest.
have="$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "homefield.base-id"}}' 2>/dev/null || true)"
if [ "$have" = "$base" ]; then
  exit 0
fi

printf 'FROM %s\nRUN rm /usr/bin/buildkit-qemu-x86_64\n' "$BASE" |
  docker build --label "$LABEL=$base" -t "$IMAGE" -