#!/usr/bin/env bash
# tests/update.sh — homefield update: ref checks, version policy, idle gate,
# apply, verify and rollback.
#
# Run:  bash tests/update.sh
# Exit: 0 when every case passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/homefield-update-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# make_tarball <dest_tar> <top_dir> <upgrade_rc> <diagnose_rc>
make_tarball() {
  local dest="$1" top="$2" up_rc="$3" dg_rc="$4"
  local stage="$TMP/pkg-${top}"
  rm -rf "$stage"
  mkdir -p "$stage/$top/bin" "$stage/$top/vm"
  touch "$stage/$top/vm/lima.yaml" "$stage/$top/vm/provision.sh"
  cat >"$stage/$top/bin/homefield" <<EOF
#!/usr/bin/env bash
printf '%s\n' "NEW_HF:\$*" >>"\${UPD_CALL_LOG:?}"
for a in "\$@"; do
  case "\$a" in
    upgrade) exit ${up_rc} ;;
    diagnose) exit ${dg_rc} ;;
  esac
done
exit 0
EOF
  chmod +x "$stage/$top/bin/homefield"
  # Embed a 40-char commit in the archive name suffix so update_tarball_commit reads it.
  local parent
  parent="$(dirname "$dest")"
  mkdir -p "$parent"
  tar -czf "$dest" -C "$stage" "$top"
}

# setup_env <case_name>: creates an isolated HOME, STUB_BIN, and installed TOOL_ROOT.
setup_env() {
  local name="$1"
  CASE_DIR="$TMP/$name"
  rm -rf "$CASE_DIR"
  mkdir -p "$CASE_DIR/home/.lima/homefield" "$CASE_DIR/stubs" "$CASE_DIR/tool/bin/lib" "$CASE_DIR/tool/vm"
  cp "$REPO_ROOT/bin/homefield" "$CASE_DIR/tool/bin/homefield"
  cp "$REPO_ROOT"/bin/cmd-*.sh "$CASE_DIR/tool/bin/"
  cp "$REPO_ROOT"/bin/lib/*.sh "$CASE_DIR/tool/bin/lib/"
  cp "$REPO_ROOT/vm/lima.yaml" "$CASE_DIR/tool/vm/lima.yaml"
  cp "$REPO_ROOT/vm/provision.sh" "$CASE_DIR/tool/vm/provision.sh"
  printf '# Lima VM for the local GitHub Actions runner.\n' >"$CASE_DIR/home/.lima/homefield/lima.yaml"

  CALL_LOG="$CASE_DIR/calls.log"
  : >"$CALL_LOG"

  cat >"$CASE_DIR/stubs/limactl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    printf '%s\n' "${STUB_LIMA_LIST:-homefield Running}"
    exit "${STUB_LIMA_LIST_RC:-0}"
    ;;
  shell)
    if [ "${STUB_JOB_RC:-1}" = "0" ]; then
      echo "yes"
    elif [ "${STUB_JOB_RC:-1}" = "1" ]; then
      echo "no"
    else
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$CASE_DIR/stubs/limactl"

  cat >"$CASE_DIR/stubs/curl" <<'EOF'
#!/usr/bin/env bash
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *"/tags"*)
    printf '%s\n' "${STUB_TAGS_JSON:-[]}"
    exit "${STUB_CURL_RC:-0}"
    ;;
  *"/commits/"*)
    printf '%s\n' "${STUB_COMMIT_SHA:-}"
    exit "${STUB_CURL_RC:-0}"
    ;;
  *"codeload.github.com"*"/tar.gz/"*)
    [ -n "${STUB_TARBALL:-}" ] || exit 1
    cp "$STUB_TARBALL" "$out"
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$CASE_DIR/stubs/curl"

  cat >"$CASE_DIR/stubs/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$CASE_DIR/stubs/gh"

  cat >"$CASE_DIR/stubs/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "LAUNCHCTL:$*" >>"${UPD_CALL_LOG:?}"
if [ "${1:-}" = "list" ]; then
  exit "${STUB_LAUNCHCTL_LIST_RC:-0}"
fi
exit 0
EOF
  chmod +x "$CASE_DIR/stubs/launchctl"

  # Override old tool's diagnose/upgrade? Real cmd-diagnose needs many lima/gh calls;
  # for rollback verification we wrap cmd_diagnose in a tiny test hook only if STUB_OLD_DG is set.
  if [ "${STUB_OLD_DG:-0}" = "1" ]; then
    cat >"$CASE_DIR/tool/bin/cmd-diagnose.sh" <<'EOF'
#!/usr/bin/env bash
cmd_diagnose() {
  printf '%s\n' "OLD_DIAGNOSE:$*" >>"${UPD_CALL_LOG:?}"
  exit "${STUB_OLD_DG_RC:-0}"
}
EOF
  fi
}

run_update() {
  env -i \
    HOME="$CASE_DIR/home" \
    PATH="$CASE_DIR/stubs:$PATH" \
    UPD_CALL_LOG="$CALL_LOG" \
    HOMEFIELD_STATE_DIR="$CASE_DIR/state" \
    HOMEFIELD_LAUNCH_AGENTS_DIR="$CASE_DIR/launch_agents" \
    HOMEFIELD_AUTO_UPDATE="${HOMEFIELD_AUTO_UPDATE:-}" \
    HOMEFIELD_UPDATE_INTERVAL="${HOMEFIELD_UPDATE_INTERVAL:-}" \
    HOMEFIELD_AUTO_UPDATE_MINOR="${HOMEFIELD_AUTO_UPDATE_MINOR:-}" \
    HOMEFIELD_NOW_EPOCH="${HOMEFIELD_NOW_EPOCH:-}" \
    STUB_TAGS_JSON="${STUB_TAGS_JSON:-}" \
    STUB_COMMIT_SHA="${STUB_COMMIT_SHA:-}" \
    STUB_CURL_RC="${STUB_CURL_RC:-0}" \
    STUB_TARBALL="${STUB_TARBALL:-}" \
    STUB_LIMA_LIST="${STUB_LIMA_LIST:-homefield Running}" \
    STUB_LIMA_LIST_RC="${STUB_LIMA_LIST_RC:-0}" \
    STUB_JOB_RC="${STUB_JOB_RC:-1}" \
    STUB_OLD_DG_RC="${STUB_OLD_DG_RC:-0}" \
    STUB_LAUNCHCTL_LIST_RC="${STUB_LAUNCHCTL_LIST_RC:-0}" \
    bash "$CASE_DIR/tool/bin/homefield" update "$@" 2>&1 </dev/null
}

AAA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BBB="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# 1. Refuses git checkout (no .homefield-ref)
setup_env git_checkout
mkdir -p "$CASE_DIR/tool/.git"
out="$(run_update)"; rc=$?
record "git checkout: refused with git pull hint" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" "git pull")"

# 2. Refuses Homebrew install (empty commit in .homefield-ref)
setup_env brew_install
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=\n' >"$CASE_DIR/tool/.homefield-ref"
out="$(run_update)"; rc=$?
record "homebrew install: refused with brew upgrade hint" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" "brew upgrade homefield")"

# 3. --check when up to date
setup_env check_uptodate
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.5.3"\n  },\n  {\n    "name": "v0.5.2"\n  }\n]'
out="$(run_update --check)"; rc=$?
record "--check up-to-date: exits 0 and reports up to date" "0/yes" "$rc/$(has "$out" "up to date (v0.5.3")"

# 4. --check with minor bump only (does not fail, mentions --allow-minor)
setup_env check_minor
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.6.0"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
out="$(run_update --check)"; rc=$?
record "--check minor available: exits 0 and mentions --allow-minor" "0/yes" "$rc/$(has "$out" "--allow-minor")"

# 5. Refuses minor bump without --allow-minor
setup_env refuse_minor
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.6.0"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
out="$(run_update)"; rc=$?
record "minor bump without --allow-minor: refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" "refusing minor/major bump v0.6.0")"

# 6. Idle gate: refuses when a job is running, without modifying .homefield-ref
setup_env busy_vm
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.5.4"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
STUB_JOB_RC=0
out="$(run_update)"; rc=$?
ref_after="$(cat "$CASE_DIR/tool/.homefield-ref")"
record "busy VM: refused and .homefield-ref untouched" "nonzero/yes/yes" "$(nonzero "$rc")/$(has "$out" "a job is running")/$(has "$ref_after" "ref=v0.5.3")"

# 7. Idle gate: fails closed when job state is unknown
setup_env unknown_job
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.5.4"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
STUB_JOB_RC=2
out="$(run_update)"; rc=$?
record "unknown job state: fails closed" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" "could not ask VM")"

# 8. Patch bump applies cleanly, updates .homefield-ref, runs upgrade + diagnose
setup_env patch_apply
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
TAR_OK="$TMP/patch-ok.tar.gz"
make_tarball "$TAR_OK" "homefield-${BBB}" 0 0
STUB_TARBALL="$TAR_OK"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.6.0"\n  },\n  {\n    "name": "v0.5.4"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
STUB_JOB_RC=1
out="$(run_update)"; rc=$?
ref_after="$(cat "$CASE_DIR/tool/.homefield-ref")"
calls="$(cat "$CALL_LOG")"
record "patch bump: exits 0 and notes minor" "0/yes/yes" "$rc/$(has "$out" "updated homefield to v0.5.4")/$(has "$out" "v0.6.0 is also available")"
record "patch bump: .homefield-ref updated and upgrade+diagnose ran" "yes/yes/yes" "$(has "$ref_after" "ref=v0.5.4")/$(has "$calls" "NEW_HF:--instance homefield upgrade")/$(has "$calls" "NEW_HF:--instance homefield diagnose")"

# 9. --allow-minor applies minor bump with warning
setup_env minor_apply
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
STUB_TARBALL="$TAR_OK"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.6.0"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
STUB_JOB_RC=1
out="$(run_update --allow-minor)"; rc=$?
ref_after="$(cat "$CASE_DIR/tool/.homefield-ref")"
record "--allow-minor: exits 0 and updates to v0.6.0" "0/yes/yes" "$rc/$(has "$out" "warning: applying minor/major bump v0.6.0")/$(has "$ref_after" "ref=v0.6.0")"

# 10. Rollback when upgrade fails
STUB_OLD_DG=1 setup_env rollback_upgrade
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
TAR_FAIL_UP="$TMP/fail-up.tar.gz"
make_tarball "$TAR_FAIL_UP" "homefield-${BBB}" 1 0
STUB_TARBALL="$TAR_FAIL_UP"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.5.4"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
STUB_JOB_RC=1
out="$(run_update)"; rc=$?
ref_after="$(cat "$CASE_DIR/tool/.homefield-ref")"
calls="$(cat "$CALL_LOG")"
record "rollback on upgrade failure: nonzero, restored .homefield-ref, re-ran diagnose" "nonzero/yes/yes/yes" "$(nonzero "$rc")/$(has "$out" "rolled back to v0.5.3")/$(has "$ref_after" "ref=v0.5.3")/$(has "$calls" "OLD_DIAGNOSE:")"

# 11. Rollback when post-update diagnose fails
STUB_OLD_DG=1 setup_env rollback_diagnose
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
TAR_FAIL_DG="$TMP/fail-dg.tar.gz"
make_tarball "$TAR_FAIL_DG" "homefield-${BBB}" 0 1
STUB_TARBALL="$TAR_FAIL_DG"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.5.4"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
STUB_JOB_RC=1
out="$(run_update)"; rc=$?
ref_after="$(cat "$CASE_DIR/tool/.homefield-ref")"
calls="$(cat "$CALL_LOG")"
record "rollback on diagnose failure: nonzero, restored .homefield-ref, re-ran diagnose" "nonzero/yes/yes/yes" "$(nonzero "$rc")/$(has "$out" "post-update diagnose failed")/$(has "$ref_after" "ref=v0.5.3")/$(has "$calls" "OLD_DIAGNOSE:")"

# 12. Interrupted update (SIGTERM during upgrade) restores backup
setup_env sigterm_rollback
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
TAR_TERM="$TMP/term.tar.gz"
term_stage="$TMP/pkg-term"
rm -rf "$term_stage"
mkdir -p "$term_stage/homefield-${BBB}/bin" "$term_stage/homefield-${BBB}/vm"
touch "$term_stage/homefield-${BBB}/vm/lima.yaml" "$term_stage/homefield-${BBB}/vm/provision.sh"
cat >"$term_stage/homefield-${BBB}/bin/homefield" <<'EOF'
#!/usr/bin/env bash
kill -TERM "$PPID"
sleep 5
EOF
chmod +x "$term_stage/homefield-${BBB}/bin/homefield"
tar -czf "$TAR_TERM" -C "$term_stage" "homefield-${BBB}"
STUB_TARBALL="$TAR_TERM"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.5.4"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
STUB_JOB_RC=1
out="$(run_update)"; rc=$?
ref_after="$(cat "$CASE_DIR/tool/.homefield-ref")"
record "interrupted update (SIGTERM): restores backup .homefield-ref" "nonzero/yes/yes" "$(nonzero "$rc")/$(has "$out" "update interrupted; restoring previous copy")/$(has "$ref_after" "ref=v0.5.3")"

# 13. --auto with HOMEFIELD_AUTO_UPDATE=off (default)
setup_env auto_off
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
out="$(HOMEFIELD_AUTO_UPDATE=off HOMEFIELD_NOW_EPOCH=1000 run_update --auto)"; rc=$?
record "--auto off: exits 0 without creating state file" "0/yes/no" "$rc/$(has "$out" "auto-update is disabled")/$([ -f "$CASE_DIR/state/update-check.state" ] && echo yes || echo no)"

# 14. --auto notify mode + interval gating
setup_env auto_notify
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.5.4"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
out="$(HOMEFIELD_AUTO_UPDATE=notify HOMEFIELD_UPDATE_INTERVAL=3600 HOMEFIELD_NOW_EPOCH=10000 run_update --auto)"; rc=$?
ref_after="$(cat "$CASE_DIR/tool/.homefield-ref")"
record "--auto notify: exits 0, reports update, does not modify tool" "0/yes/yes" "$rc/$(has "$out" "update available: v0.5.4")/$(has "$ref_after" "ref=v0.5.3")"
out="$(HOMEFIELD_AUTO_UPDATE=notify HOMEFIELD_UPDATE_INTERVAL=3600 HOMEFIELD_NOW_EPOCH=11000 run_update --auto)"; rc=$?
record "--auto interval gate: skips within interval" "0/yes" "$rc/$(has "$out" "checked recently")"
out="$(HOMEFIELD_AUTO_UPDATE=notify HOMEFIELD_UPDATE_INTERVAL=3600 HOMEFIELD_NOW_EPOCH=14000 run_update --auto)"; rc=$?
record "--auto interval gate: checks again after interval" "0/yes" "$rc/$(has "$out" "update available: v0.5.4")"

# 15. --auto patch mode skips cleanly (exit 0) when VM is busy
setup_env auto_busy
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
STUB_TARBALL="$TAR_OK"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.5.4"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
STUB_JOB_RC=0
out="$(HOMEFIELD_AUTO_UPDATE=patch HOMEFIELD_NOW_EPOCH=20000 run_update --auto)"; rc=$?
ref_after="$(cat "$CASE_DIR/tool/.homefield-ref")"
record "--auto patch busy VM: skips with exit 0 and leaves .homefield-ref untouched" "0/yes/yes" "$rc/$(has "$out" "auto-update: skipping; a job is running")/$(has "$ref_after" "ref=v0.5.3")"

# 16. --auto patch mode skips minor bump cleanly without HOMEFIELD_AUTO_UPDATE_MINOR=1
setup_env auto_minor_skip
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.6.0"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
out="$(HOMEFIELD_AUTO_UPDATE=patch HOMEFIELD_NOW_EPOCH=20000 run_update --auto)"; rc=$?
record "--auto patch minor-only: skips with exit 0" "0/yes" "$rc/$(has "$out" "auto-update: skipping v0.6.0")"

# 17. --auto patch mode applies patch bump when idle
setup_env auto_patch_apply
printf 'repo=i2Dev-com/homefield\nref=v0.5.3\ncommit=%s\n' "$AAA" >"$CASE_DIR/tool/.homefield-ref"
STUB_TARBALL="$TAR_OK"
STUB_TAGS_JSON=$'[\n  {\n    "name": "v0.5.4"\n  },\n  {\n    "name": "v0.5.3"\n  }\n]'
STUB_JOB_RC=1
out="$(HOMEFIELD_AUTO_UPDATE=patch HOMEFIELD_NOW_EPOCH=20000 run_update --auto)"; rc=$?
ref_after="$(cat "$CASE_DIR/tool/.homefield-ref")"
record "--auto patch idle VM: applies v0.5.4" "0/yes/yes" "$rc/$(has "$out" "updated homefield to v0.5.4")/$(has "$ref_after" "ref=v0.5.4")"

# 18. --schedule install, status, remove
setup_env schedule_cmd
out="$(HOMEFIELD_UPDATE_INTERVAL=7200 run_update --schedule install)"; rc=$?
plist="$CASE_DIR/launch_agents/com.homefield.update.plist"
plist_body="$(cat "$plist")"
calls="$(cat "$CALL_LOG")"
record "--schedule install: writes plist and loads via launchctl" "0/yes/yes/yes/yes" "$rc/$(has "$out" "installed update schedule")/$(has "$plist_body" "<integer>7200</integer>")/$(has "$plist_body" "<string>notify</string>")/$(has "$calls" "LAUNCHCTL:load -w")"
out="$(run_update --schedule status)"; rc=$?
record "--schedule status: reports installed and loaded=yes" "0/yes" "$rc/$(has "$out" "installed (${plist}, loaded=yes)")"
out="$(run_update --schedule remove)"; rc=$?
record "--schedule remove: unloads and deletes plist" "0/yes/no" "$rc/$(has "$out" "removed update schedule")/$([ -f "$plist" ] && echo yes || echo no)"

# 19. --schedule install preserves --instance, HOMEFIELD_STATE_DIR, and LIMA_HOME (with XML escaping)
setup_env schedule_overrides
out="$(env -i HOME="$CASE_DIR/home" PATH="$CASE_DIR/stubs:$PATH" UPD_CALL_LOG="$CALL_LOG" HOMEFIELD_STATE_DIR="$CASE_DIR/custom_state" HOMEFIELD_LAUNCH_AGENTS_DIR="$CASE_DIR/launch_agents" LIMA_HOME="$CASE_DIR/lima<1>&2" bash "$CASE_DIR/tool/bin/homefield" --instance runner-2 update --schedule install 2>&1 </dev/null)"; rc=$?
plist="$CASE_DIR/launch_agents/com.homefield.update.plist"
plist_body="$(cat "$plist")"
record "--schedule install with overrides: preserves --instance, STATE_DIR, and escaped LIMA_HOME" "0/yes/yes/yes/yes" "$rc/$(has "$plist_body" "<string>--instance</string>")/$(has "$plist_body" "<string>runner-2</string>")/$(has "$plist_body" "<string>${CASE_DIR}/custom_state</string>")/$(has "$plist_body" "<string>${CASE_DIR}/lima&lt;1&gt;&amp;2</string>")"

summary
