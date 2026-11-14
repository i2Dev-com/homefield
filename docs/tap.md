# The Homebrew tap

`brew tap i2Dev-com/homefield && brew install homefield` installs HomeField from
the release tarball in the
[Homebrew tap repository](https://github.com/i2Dev-com/homebrew-homefield),
whose formula is updated by the release automation on every release.

## The formula

`formula/homefield.rb` in this repository is the template the tap carries. On
every release it is filled with the release's values and committed to the tap
repository by the release automation in
[`.github/workflows/tap-release.yml`](.github/workflows/tap-release.yml), which
runs `bin/cmd-tap-release.sh <tag>` on `release: published`:

1. `bin/cmd-tap-release.sh` downloads the release tarball (the same codeload
   URL `install.sh` fetches, with `gh api` as the fallback), computes its
   sha256, and rewrites the formula's `url`, `version` and `sha256` with the
   release's values.
2. It clones the tap repository, commits the filled formula and pushes it.

## The token

`TAP_TOKEN` is the token that can write to the tap repository. The workflow
runs in this repository, so `TAP_TOKEN` is a secret **of i2Dev-com/homefield**
(a secret on the tap repository would be invisible to it); the token itself
must have write access to i2Dev-com/homebrew-homefield. The workflow passes it
to the job as `GH_TOKEN`. `bin/cmd-tap-release.sh` reads `GH_TOKEN` from the
environment only — a git credential helper writes it into the credentials store
when git needs credentials to push, so the token is never on a command line,
and it stays out of the job log and of every process list.

## The release process

1. Cut the release tag on `main` (an exact semver tag, never moved) and publish
   it.
2. The workflow runs and updates the formula with the release's url, version and
   sha256.
3. `brew install homefield` installs the tool from the release tarball;
   `brew upgrade homefield` is the update path for the host tool.

A tap repository that does not exist yet is a warning, not a failure: the
formula can land in this repository first and the release automation updates it
once the tap is created.
