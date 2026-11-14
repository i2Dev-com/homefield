#!/usr/bin/env bash
# The Homebrew formula template and the release automation that fills its
# url/version/sha256: a no-network suite that stubs gh, curl, sha256sum and git,
# so the formula's rendering, the release update and the "tap does not exist
# yet" warning are all verifiable without touching the network, on a Mac's
# stock bash 3.2 (no mapfile, no ${var,,}, no declare -a, no inherit_errexit).
#
# Run:  bash tests/formula.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

stubs="$work/stubs"
calls="$work/calls"
mkdir -p "$stubs"
: >"$calls"

# The system tools the release automation needs: the stubs are first on PATH,
# whatever the machine has.
for t in awk cat chmod cp cut dirname grep mkdir mktemp rm sed; do
  ln -s "$(command -v "$t")" "$stubs/$t"
done

# Fixture: the formula the tap repository carries after the previous release,
# and the new release's values (the version and the tarball's sha256).
old_version="0.5.3"
old_sha256="0000000000000000000000000000000000000000000000000000000000000001"
new_version="0.5.4"
# The sha256 the sha256sum stub returns for the release tarball.
new_sha256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

fixture="$work/fixture"
mkdir -p "$fixture/formula"
# The template: version, url and sha256 placeholders, filled by the release
# automation for every release.
cat >"$fixture/formula/homefield.rb" <<EOF
class Homefield < Formula
  desc "Run pull-request CI on your own Mac, in an isolated VM, with a hosted fallback"
  homepage "https://github.com/i2Dev-com/homefield"
  license "MIT"

  version "${old_version}"
  url "https://codeload.github.com/i2Dev-com/homefield/tar.gz/v${old_version}"
  sha256 "${old_sha256}"

  def install
    bin.install "homefield"
  end

  test do
    system bin/"homefield", "version"
  end
end
EOF

# A stub of the release tarball the codeload URL serves: a bin/homefield to
# install, the same tree install.sh unpacks.
mkdir -p "$fixture/src/homefield-$new_version/bin"
printf '#!/bin/sh\nexec "%s/bin/homefield" "$@"\n' "$fixture/src" >"$fixture/src/homefield-$new_version/bin/homefield"
chmod +x "$fixture/src/homefield-$new_version/bin/homefield"
tar -czf "$fixture/release.tgz" -C "$fixture/src" "homefield-$new_version"

# curl: a stub that copies the release tarball to the -o destination, the same
# way the codeload URL would.
fake_stub "$stubs" curl CALLS <<'EOF'
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then cp "${FIXTURE_FOR_CURL:-$fixture/release.tgz}" "$2"; fi
  shift
done
EOF

# sha256sum: a stub that prints the release tarball's sha256, the way the real
# one would for the downloaded file.
fake_stub "$stubs" sha256sum CALLS <<'EOF'
printf '%s  %s\n' "$SHA256_FOR_CURL" "$1"
EOF

# gh: a stub that creates the tap repository for the clone, and fails (a tap
# repository that does not exist yet) when GH_TAP_FAIL is set.
fake_stub "$stubs" gh CALLS <<'EOF'
case "$*" in
  *repo\ clone*)
    if [ -n "${GH_TAP_FAIL:-}" ]; then
      echo "gh: repository not found: $TAP_REPO" >&2
      exit 128
    fi
    # The destination is the argument before --: the call is
    # gh repo clone <repo> <dest> -- --force.
    dest=""
    for a in $*; do
      [ "$a" = -- ] && break
      dest="$a"
    done
    mkdir -p "$dest/formula"
    cp "$TAP_TEMPLATE" "$dest/formula/homefield.rb"
    ;;
  *)
    ;;
esac
EOF

# git: a stub that records every call, the real git would commit and push.
fake_stub "$stubs" git CALLS <<'EOF'
:
EOF

# sha256_ok <hash>: yes when the hash is a 64-hex value: a formula version or
# sha256 has to be, and the sha256 of the tarball always is.
sha256_ok() {
  local s="$1"
  [ ${#s} -eq 64 ] || { echo no; return 0; }
  case "$s" in *[!0-9a-f]*) echo no ;; *) echo yes ;; esac
}

# formula_value <file> <key>: the value of the version, the url or the sha256
# line in a formula (the first match).
formula_value() {
  sed -n "s/^  ${2} \"\([^\"]*\)\".*$/\1/p" "$1" | head -1
}

# run_release [VAR=value ...] <tag> <work>: sources the release automation with
# the stubs and runs tap_release; out and rc. Leading VAR=value entries are
# environment overrides for the run.
run_release() {
  local envs=() tag work
  # Leading VAR=value entries are environment overrides for the run. The last
  # two arguments are the tag and the work directory.
  while [ $# -gt 2 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  [ "${1:-}" != -- ] || shift
  tag="$1"
  work="$2"
  shift 2
  out="$(env -i HOME="$work/env/home" PATH="$stubs" \
    TAP_REPO="$TAP_REPO" TAP_TEMPLATE="$fixture/formula/homefield.rb" \
    FIXTURE_FOR_CURL="$fixture/release.tgz" \
    SHA256_FOR_CURL="$new_sha256" CALLS="$calls" \
    "${envs[@]+"${envs[@]}"}" \
    "$BASH_BIN" -c '. "$1"; tap_release "$2" "$3"' _ "$ROOT/bin/cmd-tap-release.sh" "$tag" "$work" 2>&1)"
  rc=$?
}

BASH_BIN="$(command -v bash)"
TAP_REPO="i2Dev-com/homebrew-homefield"

# ── The formula ──────────────────────────────────────────────────────────────

echo "the formula"
formula="$ROOT/formula/homefield.rb"
version="$(formula_value "$formula" version)"
url="$(formula_value "$formula" url)"
sha256="$(formula_value "$formula" sha256)"
record "the formula carries a version" "0.0.0" "$version"
record "the url carries the same version placeholder" "yes" "$(has "$url" "tar.gz/v${version}")"
record "the url is the release tarball install.sh fetches" "yes" "$(has "$url" "codeload.github.com/i2Dev-com/homefield/tar.gz")"
record "the formula's sha256 is a 64-hex placeholder" "yes" "$(sha256_ok "$sha256")"
record "the formula installs bin/homefield" "yes" "$(has "$(cat "$formula")" 'bin.install "homefield"')"
record "the formula tests homefield version" "yes" "$(has "$(cat "$formula")" 'system bin/"homefield", "version"')"

# ── The release update ───────────────────────────────────────────────────────

echo "the release update"
TAP_TEMPLATE="$fixture/formula/homefield.rb" "$BASH_BIN" -c \
  '. "$1"; update_formula "$2" "$3" "$4" "$5"' _ "$ROOT/bin/cmd-tap-release.sh" \
  "$fixture/formula/homefield.rb" "v${new_version}" "$new_sha256" "$work/updated/homefield.rb"
record "the version is rewritten" "$new_version" "$(formula_value "$work/updated/homefield.rb" version)"
record "the url version is rewritten" "$new_version" "$(formula_value "$work/updated/homefield.rb" url | sed 's|^.*tar\.gz/v\([^"]*\).*|\1|')"
record "the sha256 is rewritten" "$new_sha256" "$(formula_value "$work/updated/homefield.rb" sha256)"
record "the rest of the formula is untouched" "yes" "$(has "$(cat "$work/updated/homefield.rb")" 'def install')"
record "the version and the url version are still the same" "$new_version" "$(formula_value "$work/updated/homefield.rb" url | sed 's|^.*tar\.gz/v\([^"]*\).*|\1|')"

# ── The release flow ─────────────────────────────────────────────────────────

echo "the release flow"
run_release v0.5.4 "$work/release"
record "the release flow exits 0" "0" "$rc"
record "the tap repository is cloned with gh" "1" "$(called '^gh repo clone')"
record "the release tarball is downloaded from the codeload url" "1" "$(called '^curl .*https://codeload.github.com/i2Dev-com/homefield/tar.gz/v0.5.4$')"
record "the tarball's sha256 is computed" "1" "$(called '^sha256sum')"
record "the formula is added" "1" "$(called '^git add')"
record "the formula is committed" "1" "$(called '^git -c .*commit')"
record "the formula is pushed" "1" "$(called '^git push')"
record "the formula in the tap has the new values" "$new_version" "$(formula_value "$work/release/tap/formula/homefield.rb" version)"
record "the formula in the tap has the new url" "$new_version" "$(formula_value "$work/release/tap/formula/homefield.rb" url | sed 's|^.*tar\.gz/v\([^"]*\).*|\1|')"
record "the formula in the tap has the new sha256" "$new_sha256" "$(formula_value "$work/release/tap/formula/homefield.rb" sha256)"
record "the release summary is printed" "yes" "$(has "$out" "the formula of $TAP_REPO is updated for v0.5.4")"

# ── The no-tap-repo warning ──────────────────────────────────────────────────

echo "the no-tap-repo warning"
run_release GH_TAP_FAIL=1 v0.5.4 "$work/warn"
record "the missing tap is not a failure" "0" "$rc"
record "the warning is printed" "yes" "$(has "$out" "the tap repository $TAP_REPO does not exist yet")"
record "the formula is not written" "no" "$([ -e "$work/warn/tap" ] && echo yes || echo no)"
record "no update is committed" "0" "$(called '^git commit')"

summary
