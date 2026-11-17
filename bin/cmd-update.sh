#!/usr/bin/env bash
# The update command: detect, download, idle-gate, apply, verify and roll back.

UPD_CHECK=0
UPD_ALLOW_MINOR=0
UPD_WORK=""
UPD_SWAPPED=0

# update_cleanup: restores the backup if interrupted mid-transaction, and
# removes the staging dir only when no un-restored backup remains.
update_cleanup() {
  [ -n "$UPD_WORK" ] && [ -d "$UPD_WORK" ] || return 0
  if [ "$UPD_SWAPPED" = 1 ] && [ -d "$UPD_WORK/backup" ]; then
    echo "homefield: update interrupted; restoring previous copy from ${UPD_WORK}/backup" >&2
    if [ -e "$ROOT" ]; then
      mv "$ROOT" "$UPD_WORK/failed" 2>/dev/null || true
    fi
    if ! mv "$UPD_WORK/backup" "$ROOT" 2>/dev/null; then
      echo "homefield: could not restore ${ROOT}; backup preserved at ${UPD_WORK}/backup" >&2
      return 0
    fi
    UPD_SWAPPED=0
  fi
  rm -rf "$UPD_WORK"
}

# update_parse_args: parses --check and --allow-minor.
update_parse_args() {
  UPD_CHECK=0
  UPD_ALLOW_MINOR=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) UPD_CHECK=1; shift ;;
      --allow-minor) UPD_ALLOW_MINOR=1; shift ;;
      *) die "update: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
}

# update_api <repo> <commits REF|tags>: queries GitHub via curl first, falling
# back to gh api for private repositories.
update_api() {
  local repo="$1" what="$2" ref="${3:-}" out=""
  if command -v curl >/dev/null 2>&1; then
    if out="$(public_api "$repo" "$what" "$ref" 2>/dev/null)" && [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  if command -v gh >/dev/null 2>&1; then
    case "$what" in
      commits)
        if out="$(gh api "repos/${repo}/commits/${ref}" --jq '.sha' 2>/dev/null)" && [ -n "$out" ]; then
          printf '%s\n' "$out"
          return 0
        fi
        ;;
      tags)
        if out="$(gh api "repos/${repo}/tags?per_page=100" --jq '.[].name' 2>/dev/null)" && [ -n "$out" ]; then
          printf '%s\n' "$out"
          return 0
        fi
        ;;
    esac
  fi
  return 1
}

# update_fetch_tarball <repo> <ref> <dest>: downloads the tarball via curl
# first, falling back to gh api for private repositories.
update_fetch_tarball() {
  local repo="$1" ref="$2" dest="$3"
  if command -v curl >/dev/null 2>&1 && curl -fsSL -o "$dest" "https://codeload.github.com/${repo}/tar.gz/${ref}" 2>/dev/null; then
    log "downloaded ${repo} at ${ref}"
    return 0
  fi
  if command -v gh >/dev/null 2>&1 && gh api "repos/${repo}/tarball/${ref}" >"$dest" 2>/dev/null; then
    log "downloaded ${repo} at ${ref} with gh"
    return 0
  fi
  die "update: could not download ${repo} at ${ref} (check network or gh auth)"
}

# update_tarball_commit <tarball> <top_dir>: extracts commit SHA from git
# archive comment or directory suffix, matching install.sh.
update_tarball_commit() {
  local sha=""
  sha="$(gzip -dc "$1" 2>/dev/null | head -c 1024 | grep -a -o 'comment=[0-9a-f]\{40\}' | head -1 | cut -d= -f2)" || true
  if [ -z "$sha" ] && [[ "$2" =~ -([0-9a-f]{7,40})$ ]]; then
    sha="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$sha"
}

# update_read_ref: reads repo, ref, commit from $ROOT/.homefield-ref and
# refuses git checkouts or Homebrew installs.
UPD_REPO="" UPD_REF="" UPD_COMMIT=""
update_read_ref() {
  local key value
  UPD_REPO="" UPD_REF="" UPD_COMMIT=""
  if [ ! -f "$ROOT/.homefield-ref" ]; then
    if [ -e "$ROOT/.git" ] || git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      die "update: ${ROOT} is a git checkout; update with git pull"
    fi
    die "update: ${ROOT} was not installed by install.sh (no .homefield-ref)"
  fi
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      repo) UPD_REPO="$value" ;;
      ref) UPD_REF="$value" ;;
      commit) UPD_COMMIT="$value" ;;
    esac
  done <"$ROOT/.homefield-ref"
  if [ -z "$UPD_COMMIT" ]; then
    die "update: ${ROOT} was installed by Homebrew; update with brew upgrade homefield"
  fi
  local repo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ref_re='^[A-Za-z0-9_./-]+$'
  if [[ ! "$UPD_REPO" =~ $repo_re || "$UPD_REPO" == *..* || ! "$UPD_REF" =~ $ref_re || "$UPD_REF" == *..* || "$UPD_REF" == -* ]]; then
    die "update: .homefield-ref has an unusable repo or ref"
  fi
}

# update_resolve: determines UPD_STATUS (up-to-date, fixed, patch, minor,
# minor-blocked, branch) and UPD_TARGET_REF / UPD_LATEST_OVERALL.
UPD_STATUS="" UPD_TARGET_REF="" UPD_TARGET_COMMIT="" UPD_LATEST_OVERALL=""
update_resolve() {
  local repo="$UPD_REPO" ref="$UPD_REF" commit="$UPD_COMMIT" allow_minor="$UPD_ALLOW_MINOR"
  local sha_re='^[0-9a-f]{40}$' tag_re='^v([0-9]+)[.]([0-9]+)[.]([0-9]+)$'
  UPD_STATUS="" UPD_TARGET_REF="" UPD_TARGET_COMMIT="" UPD_LATEST_OVERALL=""

  if [[ "$ref" =~ $sha_re ]]; then
    UPD_STATUS="fixed"
    return 0
  fi

  if [[ "$ref" =~ $tag_re ]]; then
    local cur_a="${BASH_REMATCH[1]}" cur_b="${BASH_REMATCH[2]}" cur_c="${BASH_REMATCH[3]}"
    local tags="" tag="" a b c
    local best_patch="" best_pc="$cur_c"
    local best_all="" la="$cur_a" lb="$cur_b" lc="$cur_c"

    tags="$(update_api "$repo" tags)" || die "update: could not list tags of ${repo}"
    while IFS= read -r tag; do
      [[ "$tag" =~ $tag_re ]] || continue
      a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}"
      if [ "$a" -eq "$cur_a" ] && [ "$b" -eq "$cur_b" ] && [ "$c" -gt "$best_pc" ]; then
        best_patch="$tag"
        best_pc="$c"
      fi
      if [ "$a" -gt "$la" ] || { [ "$a" -eq "$la" ] && { [ "$b" -gt "$lb" ] || { [ "$b" -eq "$lb" ] && [ "$c" -gt "$lc" ]; }; }; }; then
        best_all="$tag"
        la="$a" lb="$b" lc="$c"
      fi
    done <<<"$tags"

    if [ -z "$best_all" ]; then
      UPD_STATUS="up-to-date"
      return 0
    fi
    if [ "$la" -eq "$cur_a" ] && [ "$lb" -eq "$cur_b" ]; then
      UPD_STATUS="patch"
      UPD_TARGET_REF="$best_all"
      return 0
    fi
    UPD_LATEST_OVERALL="$best_all"
    if [ "$allow_minor" = 1 ]; then
      UPD_STATUS="minor"
      UPD_TARGET_REF="$best_all"
    elif [ -n "$best_patch" ]; then
      UPD_STATUS="patch"
      UPD_TARGET_REF="$best_patch"
    else
      UPD_STATUS="minor-blocked"
      UPD_TARGET_REF="$best_all"
    fi
    return 0
  fi

  local current=""
  current="$(update_api "$repo" commits "$ref")" || die "update: could not read ${ref} in ${repo}"
  [[ "$current" =~ $sha_re ]] || die "update: unexpected commit response for ${ref} in ${repo}"
  if [[ "$current" == "$commit"* ]]; then
    UPD_STATUS="up-to-date"
    return 0
  fi
  UPD_STATUS="branch"
  UPD_TARGET_REF="$ref"
  UPD_TARGET_COMMIT="$current"
}

# update_collect_vms: populates UPD_VMS with target VM names.
UPD_VMS=()
update_collect_vms() {
  UPD_VMS=()
  if [ "$EXPLICIT_INSTANCE" = 1 ]; then
    local st="" rc=0
    st="$(vm_status)" || rc=$?
    [ "$rc" -lt 2 ] || die "update: could not check status of VM ${INSTANCE}"
    [ -n "$st" ] || die "no VM ${INSTANCE}; run bin/homefield install"
    UPD_VMS=("$INSTANCE")
    return 0
  fi
  local list="" name
  if ! list="$(vm_instances)"; then
    if command -v limactl >/dev/null 2>&1; then
      die "update: could not list Lima VMs"
    fi
    return 0
  fi
  while IFS= read -r name; do
    [ -z "$name" ] || UPD_VMS+=("$name")
  done <<<"$list"
}

# update_check_idle: fails closed if any target VM is running a job or cannot
# be asked.
update_check_idle() {
  local vm st="" rc=0
  for vm in ${UPD_VMS[@]+"${UPD_VMS[@]}"}; do
    INSTANCE="$vm"
    rc=0
    st="$(vm_status)" || rc=$?
    [ "$rc" -lt 2 ] || die "update: could not check status of VM ${vm}"
    if [ "$st" = "Running" ]; then
      if is_job_running; then
        die "update: a job is running on ${vm}; try again when it is idle"
      fi
    fi
  done
}

# update_stage <repo> <ref> <tarball> <stage_dir>: unpacks and validates the
# downloaded tool tree, writing .homefield-ref.
update_stage() {
  local repo="$1" ref="$2" tarball="$3" stage="$4" f top commit
  mkdir -p "$stage"
  tar -xzf "$tarball" -C "$stage" --strip-components=1 || die "update: could not unpack the download"
  for f in bin/homefield vm/lima.yaml vm/provision.sh; do
    [ -f "$stage/$f" ] || die "update: downloaded archive is not homefield ($f is missing)"
  done
  [ -x "$stage/bin/homefield" ] || die "update: bin/homefield in the download is not executable"
  top="$(tar -tzf "$tarball" | sed -n '1s,/.*,,p')"
  commit="$(update_tarball_commit "$tarball" "$top")"
  printf 'repo=%s\nref=%s\ncommit=%s\n' "$repo" "$ref" "$commit" >"$stage/.homefield-ref"
  UPD_TARGET_COMMIT="$commit"
}

# update_rollback <backup_dir> <work_dir>: restores the previous tool copy and
# re-verifies every target VM with diagnose.
update_rollback() {
  local backup="$1" work="$2" vm verify_rc=0
  log "update: rolling back to ${UPD_REF}${UPD_COMMIT:+ (${UPD_COMMIT:0:7})}"
  if [ -e "$ROOT" ]; then
    mv "$ROOT" "$work/failed" || true
  fi
  mv "$backup" "$ROOT" || die "update: rollback failed: could not restore ${ROOT} from ${backup}"
  UPD_SWAPPED=0
  for vm in ${UPD_VMS[@]+"${UPD_VMS[@]}"}; do
    if ! "${BASH:-bash}" "$ROOT/bin/homefield" ${COLOR_ARG:+"$COLOR_ARG"} --instance "$vm" diagnose </dev/null; then
      verify_rc=1
    fi
  done
  if [ "$verify_rc" != 0 ]; then
    die "update: rolled back tool, but post-rollback diagnose failed on at least one VM"
  fi
}

cmd_update() {
  update_parse_args "$@"
  update_read_ref
  update_resolve

  case "$UPD_STATUS" in
    fixed)
      log "installed at a fixed commit (${UPD_COMMIT:0:7}), so there is no ref to update"
      return 0
      ;;
    up-to-date)
      log "homefield is up to date (${UPD_REF}${UPD_COMMIT:+ (${UPD_COMMIT:0:7})})"
      return 0
      ;;
    minor-blocked)
      log "warning: ${UPD_TARGET_REF} is a minor/major bump from ${UPD_REF} and may include breaking routing-guard changes; read CHANGELOG.md"
      if [ "$UPD_CHECK" = 1 ]; then
        log "pass --allow-minor to apply ${UPD_TARGET_REF}"
        return 0
      fi
      die "update: refusing minor/major bump ${UPD_TARGET_REF} without --allow-minor"
      ;;
  esac

  if [ -n "$UPD_LATEST_OVERALL" ] && [ "$UPD_STATUS" = "patch" ]; then
    log "note: ${UPD_LATEST_OVERALL} is also available (minor/major bump; pass --allow-minor to apply)"
  fi
  if [ "$UPD_STATUS" = "minor" ]; then
    log "warning: applying minor/major bump ${UPD_TARGET_REF} from ${UPD_REF}; read CHANGELOG.md for any routing-guard changes"
  fi

  if [ "$UPD_CHECK" = 1 ]; then
    if [ "$UPD_STATUS" = "branch" ]; then
      log "update available: ${UPD_REF} moved to ${UPD_TARGET_COMMIT:0:7} (installed: ${UPD_COMMIT:0:7})"
    else
      log "update available: ${UPD_TARGET_REF} (installed: ${UPD_REF})"
    fi
    return 0
  fi

  update_collect_vms
  update_check_idle

  trap update_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  UPD_WORK="$(mktemp -d "$(dirname "$ROOT")/.homefield-update.XXXXXX")"
  update_fetch_tarball "$UPD_REPO" "$UPD_TARGET_REF" "$UPD_WORK/homefield.tar.gz"
  update_stage "$UPD_REPO" "$UPD_TARGET_REF" "$UPD_WORK/homefield.tar.gz" "$UPD_WORK/new"

  # Re-check idle gate right before swapping and stopping any runner.
  update_check_idle

  mv "$ROOT" "$UPD_WORK/backup"
  if ! mv "$UPD_WORK/new" "$ROOT"; then
    mv "$UPD_WORK/backup" "$ROOT" || true
    die "update: could not move new copy into ${ROOT}"
  fi
  UPD_SWAPPED=1

  local vm
  for vm in ${UPD_VMS[@]+"${UPD_VMS[@]}"}; do
    log "upgrading VM ${vm}"
    if ! "${BASH:-bash}" "$ROOT/bin/homefield" ${COLOR_ARG:+"$COLOR_ARG"} --instance "$vm" upgrade </dev/null; then
      update_rollback "$UPD_WORK/backup" "$UPD_WORK"
      die "update: upgrade failed on ${vm}; rolled back to ${UPD_REF}"
    fi
  done

  for vm in ${UPD_VMS[@]+"${UPD_VMS[@]}"}; do
    log "verifying VM ${vm}"
    if ! "${BASH:-bash}" "$ROOT/bin/homefield" ${COLOR_ARG:+"$COLOR_ARG"} --instance "$vm" diagnose </dev/null; then
      update_rollback "$UPD_WORK/backup" "$UPD_WORK"
      die "update: post-update diagnose failed on ${vm}; rolled back to ${UPD_REF}"
    fi
  done

  UPD_SWAPPED=0
  update_cleanup
  UPD_WORK=""
  trap - EXIT INT TERM
  log "updated homefield to ${UPD_TARGET_REF}${UPD_TARGET_COMMIT:+ (${UPD_TARGET_COMMIT:0:7})}"
}
