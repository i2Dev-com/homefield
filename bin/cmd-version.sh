#!/usr/bin/env bash
# The version command and its update check.

# update_command <repo> <ref>: the install.sh one-liner (README, Quick start)
# for that ref, plus the settings that differ from install.sh's defaults, so
# that it replaces this copy and not some other one. The default ref here is
# install.sh's: change both when a release is cut.
update_command() {
  local repo="$1" ref="$2" settings=""
  [ "$repo" = i2Dev-com/homefield ] || settings="${settings}HOMEFIELD_REPO=${repo} "
  [ "$ref" = v0.5.1 ] || settings="${settings}HOMEFIELD_REF=${ref} "
  [ "$ROOT" = "$HOME/.local/share/homefield" ] || settings="${settings}HOMEFIELD_HOME='${ROOT}' "
  echo "  curl -fsSL https://raw.githubusercontent.com/${repo}/${ref}/install.sh | ${settings}bash"
}

# public_api <repo> <commits REF|tags>: the commit REF resolves to, or the
# repository's tag names (first 100), one per line. Unauthenticated HTTPS
# against api.github.com with curl: no login and no gh are involved, which is
# all this check needs for a public repository. A private fork cannot be read
# this way. A branch with a slash (release/1) goes into the path encoded, and
# curl follows redirects (a renamed repository answers 301).
public_api() {
  local repo="$1" what="$2" ref="${3:-}"
  ref="${ref//\//%2F}"
  case "$what" in
    commits) curl -fsSL --max-time 15 -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/${repo}/commits/${ref}" ;;
    tags)
      curl -fsSL --max-time 15 "https://api.github.com/repos/${repo}/tags?per_page=100" |
        sed -n 's/^ *"name": *"\([^"]*\)".*/\1/p'
      ;;
  esac
}

# update_check <repo> <ref> <commit>: says whether the ref this copy was
# installed from has moved, and whether a later release exists (the highest
# vMAJOR.MINOR.PATCH tag, when the installed ref is such a tag too). Reads
# GitHub's public API with curl alone (public_api), so no gh login can break
# it. Its own output is dropped: whatever goes wrong is one line here, and
# nothing here fails the command.
update_check() {
  local repo="$1" ref="$2" commit="$3" current="" tags="" tag="" latest="" advised=0
  local la="" lb="" lc="" a b c
  local repo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ref_re='^[A-Za-z0-9_./-]+$' sha_re='^[0-9a-f]{40}$'
  local tag_re='^v([0-9]+)[.]([0-9]+)[.]([0-9]+)$'
  local hint="the update check reads the public GitHub API, so a private fork cannot be checked"
  if ! command -v curl >/dev/null; then
    log "could not check for updates (curl is not installed)"
    return 0
  fi
  if [[ ! "$repo" =~ $repo_re || "$repo" == *..* || ! "$ref" =~ $ref_re || "$ref" == *..* || "$ref" == -* ]]; then
    log "could not check for updates (.homefield-ref has no usable repo and ref)"
    return 0
  fi
  if [ -z "$commit" ]; then
    log "could not check for updates (.homefield-ref records no commit)"
    return 0
  fi
  # A branch or tag name resolves to the commit it points at (an annotated tag
  # is followed to its commit). A full commit hash cannot move.
  if [[ ! "$ref" =~ $sha_re ]]; then
    if ! current="$(public_api "$repo" commits "$ref" 2>/dev/null)"; then
      log "could not check for updates (curl could not read ${ref} in ${repo}; ${hint})"
      return 0
    fi
    if [[ ! "$current" =~ $sha_re ]]; then
      log "could not check for updates (unexpected answer from curl for ${ref} in ${repo})"
      return 0
    fi
  fi
  if ! tags="$(public_api "$repo" tags 2>/dev/null)"; then
    log "could not check for updates (curl could not list the tags of ${repo}; ${hint})"
    return 0
  fi
  # The highest release tag, compared part by part as numbers (no sort -V on
  # the bash 3.2 and BSD tools macOS ships).
  while IFS= read -r tag; do
    [[ "$tag" =~ $tag_re ]] || continue
    a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}"
    if [ -z "$latest" ] || [ "$a" -gt "$la" ] ||
      { [ "$a" -eq "$la" ] && { [ "$b" -gt "$lb" ] || { [ "$b" -eq "$lb" ] && [ "$c" -gt "$lc" ]; }; }; }; then
      latest="$tag" la="$a" lb="$b" lc="$c"
    fi
  done <<<"$tags"

  # The recorded commit may be a short hash (install.sh falls back to one).
  if [ -z "$current" ]; then
    log "installed at a fixed commit (${commit:0:7}), so there is no ref to compare"
  elif [[ "$current" == "$commit"* ]]; then
    log "up to date with ${ref}"
  else
    log "${ref} has moved to ${current:0:7} since this copy was installed; update with:"
    update_command "$repo" "$ref"
    advised=1
  fi
  # Only when the installed ref is a release tag too: a branch follows its own
  # head, and a fixed commit has no release to compare.
  if [ -n "$latest" ] && [[ "$ref" =~ $tag_re ]]; then
    a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}"
    if [ "$la" -gt "$a" ] || { [ "$la" -eq "$a" ] && { [ "$lb" -gt "$b" ] || { [ "$lb" -eq "$b" ] && [ "$lc" -gt "$c" ]; }; }; }; then
      log "${latest} is out (installed: ${ref}); read CHANGELOG.md for breaking changes, then update with:"
      update_command "$repo" "$latest"
      advised=1
    fi
  fi
  if [ "$advised" = 1 ]; then
    echo "That replaces the tool and leaves the VM alone; homefield upgrade updates the VM."
  fi
}

# What install.sh recorded when it installed this copy (repo, ref, commit),
# and whether that ref has moved on; a git checkout says where it is instead.
cmd_version() {
  [ $# -eq 0 ] || die "version takes no options besides --instance"
  local key value repo="" ref="" commit=""
  if [ -f "$ROOT/.homefield-ref" ]; then
    # `|| [ -n "$key" ]`: a final line with no trailing newline is still read.
    while IFS='=' read -r key value || [ -n "$key" ]; do
      case "$key" in
        repo) repo="$value" ;;
        ref) ref="$value" ;;
        commit) commit="$value" ;;
      esac
    done <"$ROOT/.homefield-ref"
    echo "homefield ${ref:-unknown}${commit:+ (${commit:0:7})}, installed from ${repo:-unknown} in ${ROOT}"
    update_check "$repo" "$ref" "$commit"
  elif git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "homefield $(git -C "$ROOT" describe --always), from a checkout in ${ROOT}"
  else
    echo "homefield (version unknown), in ${ROOT}"
  fi
}
