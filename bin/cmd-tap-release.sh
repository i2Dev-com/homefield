#!/usr/bin/env bash
# The release automation for the HomeField tap. On every release, the formula's
# url/version/sha256 are updated from the release tarball and the updated
# formula is committed to the tap repository i2Dev-com/homebrew-homefield.
#
#   bin/cmd-tap-release.sh <tag> <work>
#
# The tag is the release tag, such as $GITHUB_REF_NAME (v0.5.3). The formula
# template is formula/homefield.rb in this checkout, and the tap repository is
# cloned with gh, whose token comes from the environment only (GH_TOKEN, never
# from the command line, which is how the token stays out of the job log and of
# every process list). The tarball is the same one install.sh fetches:
# https://codeload.github.com/i2Dev-com/homefield/tar.gz/<tag>.
#
# If the tap repository does not exist yet, the update is a no-op with a clear
# warning, so the formula can land in this repository before the tap is created.
#
# The <work> directory is the scratch space for the clone, the commit and the
# push; it is created and cleaned by the caller, so the caller controls the
# cleanup (the release automation must not leave it behind, and tests must be
# able to read it while it runs).
#
# Run:  bash bin/cmd-tap-release.sh v0.5.3 "$work"
# (tests: tests/formula.sh stubs gh, curl, sha256sum and git, and runs the same
# functions.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The tap repository the formula is committed to.
TAP_REPO="${TAP_REPO:-i2Dev-com/homebrew-homefield}"
# The formula template, in the checkout of this repository. Overridden by
# tests/formula.sh, which passes a fixture of its own.
TEMPLATE="${TAP_TEMPLATE:-$ROOT/formula/homefield.rb}"
# The URL the formula installs from: the release tarball install.sh fetches.
TARBALL_URL="https://codeload.github.com/i2Dev-com/homefield/tar.gz"

# version_from_tag <tag>: the bare version of a release tag (v0.5.3 → 0.5.3).
version_from_tag() {
  printf '%s' "${1#v}"
}

# release_sha256 <tag>: the sha256 of the release tarball, downloaded the same
# way install.sh does: curl first (public), gh api as the fallback (a private
# fork, with the token from the environment).
release_sha256() {
  local tag="$1" dest
  dest="$(mktemp)"
  if curl -fsSL -o "$dest" "${TARBALL_URL}/${tag}" 2>/dev/null; then
    :
  elif command -v gh >/dev/null 2>&1 && gh api "repos/i2Dev-com/homefield/tarball/${tag}" >"$dest" 2>/dev/null; then
    :
  else
    rm -f "$dest"
    return 1
  fi
  local sha256
  sha256="$(sha256sum "$dest" | cut -d' ' -f1)"
  rm -f "$dest"
  printf '%s' "$sha256"
}

# update_formula <template> <tag> <sha256> [dest]: rewrites the url, the
# version and the sha256 of the formula template with the release's values, and
# writes the filled formula to dest (the tap repository's Formula/, capitalized as Homebrew requires). The url
# carries the tag, the version the bare version: the release automation rewrites
# all three from the same release, so the two stay in sync.
update_formula() {
  local template="$1" tag="$2" sha256="$3"
  local dest="${4:-$template}"
  local version
  version="$(version_from_tag "$tag")"
  mkdir -p "$(dirname "$dest")"
  sed \
    -e "s/^  version .*/  version \"${version}\"/" \
    -e "s|^  url .*$|  url \"${TARBALL_URL}/${tag}\"|" \
    -e "s/^  sha256 .*/  sha256 \"${sha256}\"/" \
    "$template" >"$dest"
}

# git_cred_helper: a git credential helper that reads the token from the
# environment, so the token is never on the command line: it is only ever in
# the environment, and the helper reads it when git needs credentials to push.
git_cred_helper() {
  local helper="$HOME/.git-cred-helper"
  mkdir -p "$(dirname "$helper")"
  cat >"$helper" <<'EOF'
#!/bin/sh
echo "protocol=https"
echo "host=github.com"
echo "username=x-access-token"
echo "password=${GH_TOKEN}"
EOF
  chmod +x "$helper"
  git config --local credential.helper "$helper"
}

# tap_release <tag> <work>: the release automation: download the release
# tarball, update the formula's url/version/sha256 and commit the formula to the
# tap repository. A tap repository that does not exist yet is a warning, not a
# failure, so the formula can land in this repository first.
tap_release() {
  local tag="$1" work="$2" sha256
  sha256="$(release_sha256 "$tag")"

  # Clone the tap repository with gh (the token is in the environment). If the
  # tap repository does not exist yet, the tap is not there: warn and carry on
  # without the update, so the formula can land in this repository first. Any
  # other clone failure is real and must not read as "no tap": ask gh whether
  # the repository exists before deciding which of the two this is.
  if ! gh repo clone "$TAP_REPO" "$work/tap" -- --depth 1; then
    if gh repo view "$TAP_REPO" --json name >/dev/null 2>&1 </dev/null; then
      echo "homefield: cloning $TAP_REPO failed; the formula is not updated" >&2
      return 1
    fi
    echo "homefield: the tap repository $TAP_REPO does not exist yet: the formula is not updated" >&2
    return 0
  fi

  # Update the formula with the release's url/version/sha256: the url carries
  # the tag, the version the bare version (derived from it), the sha256 the
  # tarball's.
  update_formula "$TEMPLATE" "$tag" "$sha256" "$work/tap/Formula/homefield.rb"

  # Commit and push it to the tap repository.
  cd "$work/tap" || return 1
  git_cred_helper
  git add .
  git -c user.name="tom-bot-for-rana[bot]" \
      -c user.email="258975405+tom-bot-for-rana[bot]@users.noreply.github.com" \
      commit -m "formula: update url/version/sha256 for $tag"
  git push
  echo "homefield: the formula of $TAP_REPO is updated for $tag"
}

# Run directly with the release tag and a work directory, or sourced by
# tests/formula.sh, which calls tap_release on its own.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  tap_release "$1" "$work"
fi
