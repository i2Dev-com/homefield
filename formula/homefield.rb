# HomeField: run pull-request CI on your own Mac, in an isolated VM, with a
# hosted fallback.
#
# This is the template for the Homebrew tap formula: the version, the url and
# the sha256 below are placeholders, filled with the release's values by the
# release automation (see bin/cmd-tap-release.sh), and the filled formula is
# committed to the tap repository i2Dev-com/homebrew-homefield. This
# repository is the source of truth for the template, and the tap repository is
# separate from it.
#
#   brew tap i2Dev-com/homefield && brew install homefield
class Homefield < Formula
  desc "Run pull-request CI on your own Mac, in an isolated VM, with a hosted fallback"
  homepage "https://github.com/i2Dev-com/homefield"
  license "MIT"

  # The version and the url version are kept in sync by the release automation:
  # both are rewritten together from the release tag, and the sha256 is that
  # of the release tarball the url points at.
  version "0.0.0"
  url "https://codeload.github.com/i2Dev-com/homefield/tar.gz/v0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  def install
    # The tarball ships bin/homefield: the executable that the wrapper on the
    # user's PATH execs from its installed directory.
    bin.install "homefield"
  end

  test do
    # `homefield version` is the smallest smoke test of the installed command.
    system bin/"homefield", "version"
  end
end
