#!/usr/bin/env bash
# `--preset` (#175): the shipped sets parse on the host's bash, add to what a
# VM already has instead of replacing it, take the runner offline before
# copying their hooks into provision.d, and refuse an unknown or broken preset
# first.
#
# bin/homefield runs in a harness: check_host, Lima lookup/start, the guest,
# GitHub checks and provisioning are replaced by recording stubs. What stays
# real is option parsing, present loading (packages files, `include`, hook
# file names), the merges, preset_saved_drops' warning path, and the order of
# steps in cmd_upgrade / cmd_install. A stub limactl on a stub-only PATH
# records copies; nothing reaches GitHub or a VM.
#
# Run:  bash tests/preset.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT


stubs="$work/stubs"
calls="$work/calls"
mkdir -p "$stubs" "$work/home"

fake_stub "$stubs" limactl CALLS <<'EOF'
exit 0
EOF
for t in awk cat dirname grep head mktemp sed sh tr; do ln -s "$(command -v "$t")" "$stubs/$t"; done

cat >"$work/harness.sh" <<'EOF'
HOMEFIELD_SOURCE_ONLY=1
. "$ROOT_DIR/bin/homefield"
# A test points PRESETS at a temp tree for the broken-manifest cases.
[ -z "${PRESETS_OVERRIDE:-}" ] || PRESETS="$PRESETS_OVERRIDE"
check_host() { :; }
vm_lookup() { VM_STATUS=Running; }
ensure_vm() { echo "ensure_vm $*" >>"$CALLS"; }
verify_isolation() { :; }
is_registered() { return 0; }
runner_setting() {
  local k
  for k in "$@"; do
    case "$k" in
      gitHubUrl) printf '%s\n' https://github.com/acme ;;
      agentId) printf '41\n' ;;
      agentName) printf 'test-mac-homefield\n' ;;
    esac
  done
}
runner_on_github() { return 0; }
is_job_running() { [ "${JOB:-idle}" = running ]; }
stop_runner() { echo stop_runner >>"$CALLS"; }
runner_back() { :; }
run_provision() {
  shift
  printf 'provision %s\n' "$*" >>"$CALLS"
}
guest_stdin() {
  printf 'guest %s\n' "$*" >>"$CALLS"
  # The manifest read is answered from GUEST_MANIFEST_EXISTS (the test -f:
  # a missing manifest is a first copy) and GUEST_HAVE (the cat: the names,
  # newline-separated). GUEST_CAT_FAIL makes the read of an existing
  # manifest fail, the transient case.
  case "$*" in
    *"test -f /etc/homefield/preset-hooks"*) [ -n "${GUEST_MANIFEST_EXISTS:-}" ] ;;
    *"cat /etc/homefield/preset-hooks"*)
      if [ -n "${GUEST_CAT_FAIL:-}" ]; then echo "cat: read error" >&2; exit 1; fi
      printf '%s\n' "${GUEST_HAVE:-}" ;;
  esac
}
runner_extra_packages() { echo runner_extra_packages >>"$CALLS"; printf '%s' "${SAVED:-}"; }
preflight_collect() {
  PF_NAME=(lima)
  PF_LEVEL=(ok)
  PF_MSG=("Lima 2.3.0")
}
mode="${MODE:-upgrade}"
case "$mode" in
  pkgs)
    load_presets ${PRESET_ARGS}
    printf 'pkgs:%s\n' "$PRESET_PKGS"
    for f in ${PRESET_HOOKS[@]+"${PRESET_HOOKS[@]}"}; do
      printf 'hook:%s\n' "${f##*/}"
      printf 'hookpath:%s\n' "$f"
    done
    ;;
  merge) printf 'merged:%s\n' "$(merge_packages "${M1:-}" "${M2:-}" "${M3:-}")" ;;
  usage) usage ;;
  *) "$@" ;;
esac
EOF

# srun [VAR=value ...] -- <harness args>: sets out and rc.
srun() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"$calls"
  mkdir -p "$work/stage"
  out="$(env -i HOME="$work/home" PATH="$stubs" CALLS="$calls" ROOT_DIR="$ROOT" \
    HOMEFIELD_STATE_DIR="$work/state" HOMEFIELD_STAGE_DIR="$work/stage" "${envs[@]+"${envs[@]}"}" \
    "$BASH" "$work/harness.sh" "$@" 2>&1 </dev/null)"
  rc=$?
}
field() { printf '%s\n' "$out" | sed -n "s/^$1://p"; }
hooks() { field hook; }
hookpaths() { field hookpath; }
envline() { sed -n 's/^provision RUNNER_EXTRA_PACKAGES=//p' "$calls"; }

browser_libs="libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libatspi2.0-0t64 libasound2t64 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2"

echo "help"
srun MODE=usage --
record "--preset is documented once for install/setup, once for upgrade" "yes/2" \
  "$(has "$out" '--preset NAME')/$(printf '%s\n' "$out" | grep -c -e '^  --preset NAME')"

echo
echo "the shipped sets"
srun MODE=pkgs PRESET_ARGS=browsers --
record "browsers: the twelve noble t64 Chromium libraries, in file order; no hooks" \
  "$browser_libs/0" "$(field pkgs)/$(hooks | grep -c . || true)"
srun MODE=pkgs PRESET_ARGS=hosted --
record "hosted includes browsers first, then its own apt names" \
  "$browser_libs gh shellcheck sqlite3 xvfb rsync" "$(field pkgs)"
record "...and carries both hooks in file order, under the hosted directory" \
  "50-awscli.sh/60-nodejs.sh/vm/presets/hosted/50-awscli.sh/vm/presets/hosted/60-nodejs.sh" \
  "$(hooks | paste -sd / -)/$(hookpaths | sed 's|.*\(vm/presets/[^/]*/[^/]*\.sh\)|\1|' | paste -sd / -)"
record "the shipped hooks are executable, as files copied to provision.d must be" \
  "yes" "$([ -x "$ROOT/vm/presets/hosted/50-awscli.sh" ] && [ -x "$ROOT/vm/presets/hosted/60-nodejs.sh" ] && echo yes || echo no)"

echo
echo "the buildx-rosetta preset (#241)"
srun MODE=pkgs PRESET_ARGS=buildx-rosetta --
record "buildx-rosetta: no apt packages, the hook beside the packages file" \
  "/70-buildx-rosetta.sh/vm/presets/buildx-rosetta/70-buildx-rosetta.sh" \
  "$(field pkgs)/$(hooks | paste -sd / -)/$(hookpaths | sed 's|.*\(vm/presets/[^/]*/[^/]*\.sh\)|\1|' | paste -sd / -)"
record "the hook is executable, as files copied to provision.d must be" \
  "yes" "$([ -x "$ROOT/vm/presets/buildx-rosetta/70-buildx-rosetta.sh" ] && echo yes || echo no)"

echo
echo "the buildx-rosetta hook, against docker stubs"
# The hook runs in the guest (bash 5) but must stay runnable on this host's
# bash 3.2, which is what runs it here. The stub docker answers
# `docker image inspect <name> --format ...` from DOCKER_BASE_ID and
# DOCKER_LABEL, records everything else, and reads docker build's Dockerfile
# from stdin.
cat >"$stubs/docker" <<'EOF'
#!/bin/sh
printf 'docker %s\n' "$*" >>"$CALLS"
case "${1:-}" in
  image)
    case "${3:-}" in
      *buildkit:*)
        # A pull makes the base present for later calls; env cannot carry
        # between the stub's processes, so the state is a file beside CALLS.
        if [ -n "${DOCKER_BASE_ID:-}" ]; then printf '%s\n' "$DOCKER_BASE_ID"
        elif [ -f "$CALLS.base" ]; then cat "$CALLS.base"
        else exit 1; fi ;;
      buildkit-rosetta) [ -n "${DOCKER_LABEL:-}" ] && printf '%s\n' "$DOCKER_LABEL" || exit 1 ;;
      *) exit 1 ;;
    esac ;;
  pull) printf '%s\n' "${DOCKER_AFTER_PULL:-sha256:base1}" >"$CALLS.base" ;;
  build)
    tr '\n' '|' <&0 >>"$CALLS"; printf '\n' >>"$CALLS" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$stubs/docker"
hook="$ROOT/vm/presets/buildx-rosetta/70-buildx-rosetta.sh"
hrun() { : >"$calls"; out="$(env -i PATH="$stubs" CALLS="$calls" "$@" "$BASH" "$hook" 2>&1 </dev/null)"; rc=$?; }

hrun DOCKER_BASE_ID=sha256:base1 DOCKER_LABEL=sha256:base1
record "the built image matches the base: no pull, no build, exit 0" \
  "exit-0/0/0" \
  "$([ "$rc" -eq 0 ] && echo exit-0 || echo exit-$rc)/$(called '^docker pull')/$(called '^docker build')"

hrun DOCKER_BASE_ID=sha256:base1
record "no built image: the base is not pulled (it is there) and the image is built from it, labeled" \
  "exit-0/0/1/1/1/1" \
  "$([ "$rc" -eq 0 ] && echo exit-0 || echo exit-$rc)/$(called '^docker pull')/$(called '^docker build')/$(called '^FROM moby/buildkit:buildx-stable-1@sha256:c5f8862f52499773af85bc07695b2379ef08e8002352b0df2c4864c91d78dabe')/$(called 'RUN rm /usr/bin/buildkit-qemu-x86_64')/$(called '--label homefield.base-id=sha256:base1')"

hrun DOCKER_BASE_ID=sha256:base2 DOCKER_LABEL=sha256:base1
record "the base moved: the image is rebuilt against the new base, not skipped" \
  "exit-0/0/1/1/0" \
  "$([ "$rc" -eq 0 ] && echo exit-0 || echo exit-$rc)/$(called '^docker pull')/$(called '^docker build')/$(called '--label homefield.base-id=sha256:base2')/$(grep -c 'homefield.base-id=sha256:base1' "$calls" || true)"

hrun
record "neither image is there: the base is pulled first, then the build" \
  "exit-0/1/1/pull-first" \
  "$([ "$rc" -eq 0 ] && echo exit-0 || echo exit-$rc)/$(called '^docker pull')/$(called '^docker build')/$(awk '/^docker pull/{p=NR} /^docker build/{b=NR} END{print (p && b && p < b) ? "pull-first" : "build-first"}' "$calls")"

echo
echo "refusals come before anything is touched"
srun MODE=pkgs PRESET_ARGS=nope --
record "an unknown preset names the shipped ones; nothing ran" "nonzero/yes/empty" \
  "$(nonzero "$rc")/$(has "$out" 'no such preset; shipped presets are browsers buildx-rosetta hosted')/$([ "$(called .)" -eq 0 ] && echo empty || echo not-empty)"
srun MODE=upgrade -- cmd_upgrade --preset nope
record "a bad preset on upgrade: refused before any VM work or stop" "nonzero/yes/0/0/0" \
  "$(nonzero "$rc")/$(has "$out" 'shipped presets are browsers buildx-rosetta hosted')/$(called '^stop_runner')/$(called 'limactl copy')/$(called 'ensure_vm')"
srun MODE=install -- cmd_install --preset nope
record "a bad preset on install: refused before the VM or preflight report" \
  "nonzero/yes/no/0" \
  "$(nonzero "$rc")/$(has "$out" 'no such preset; shipped presets are')/$(has "$out" 'All checks passed')/$(called '^limactl')"

mkdir -p "$work/presets/bad"
printf '# a comment\n\nlibcairo2 Bad_Name!\n' >"$work/presets/bad/packages"
srun MODE=pkgs PRESET_ARGS=bad PRESETS_OVERRIDE="$work/presets" --
record "a name apt would refuse stops loading, naming the file and the word" \
  "nonzero/yes/yes" \
  "$(nonzero "$rc")/$(has "$out" 'not a package name: Bad_Name!')/$(has "$out" '/presets/bad/packages')"

mkdir -p "$work/presets/a" "$work/presets/b"
printf 'libcairo2\ninclude b\n' >"$work/presets/a/packages"
printf 'shellcheck\ninclude a\n' >"$work/presets/b/packages"
srun MODE=pkgs PRESET_ARGS=a PRESETS_OVERRIDE="$work/presets" --
record "an include cycle ends, loading each preset once" \
  "libcairo2 shellcheck/exit-0" \
  "$(field pkgs)/$([ "$rc" -eq 0 ] && echo exit-0 || echo exit-$rc)"

srun MODE=pkgs PRESET_ARGS="hosted browsers hosted" --
record "a repeated preset name loads it once, without self-collision (packages)" \
  "$(printf 'exit-0/%s gh shellcheck sqlite3 xvfb rsync' "$browser_libs")" \
  "$([ "$rc" -eq 0 ] && echo exit-0 || echo "exit-$rc")/$(field pkgs)"
record "...and its hooks once each, not two pairs of the same names" \
  "50-awscli.sh/60-nodejs.sh" "$(hooks | paste -sd / -)"

mkdir -p "$work/presets/x" "$work/presets/y"
printf 'pkg-a\n' >"$work/presets/x/packages"
printf '#!/bin/sh\nexit 0\n' >"$work/presets/x/10-tool.sh"
printf 'pkg-b\ninclude x\n' >"$work/presets/y/packages"
printf '#!/bin/sh\nexit 0\n' >"$work/presets/y/10-tool.sh"
srun MODE=pkgs PRESET_ARGS=y PRESETS_OVERRIDE="$work/presets" --
record "two hooks with one file name are refused, naming it; nothing copied" \
  "nonzero/yes/empty" \
  "$(nonzero "$rc")/$(has "$out" 'two hooks named 10-tool.sh')/$([ "$(called .)" -eq 0 ] && echo empty || echo not-empty)"

echo
echo "merging"
srun MODE=merge M1="libpq-dev shellcheck" M2="" M3="$browser_libs gh shellcheck sqlite3" --
record "lists join in first-seen order, duplicates dropped" \
  "$(printf 'libpq-dev shellcheck %s gh sqlite3' "$browser_libs")" "$(field merged)"

echo
echo "upgrade --preset"
srun MODE=upgrade SAVED="libpq-dev shellcheck" -- cmd_upgrade --preset hosted
record "hosted on a VM with extras: saved first, its own names added once each" \
  "$(printf 'ok/libpq-dev shellcheck %s' "$browser_libs gh sqlite3 xvfb rsync")" \
  "$([ "$rc" -eq 0 ] && echo ok)/$(envline)"
record "...both hooks copied and installed in provision.d after the stop, once each, with the manifest" \
  "2/2/1/after/yes/2" \
  "$(grep -c 'limactl copy.*vm/presets/hosted' "$calls" || true)/$(called '^guest sudo install -D')/$(called 'sudo tee /etc/homefield/preset-hooks')/$(
    awk '/stop_runner/{s=NR} /limactl copy/{c=NR} END{print (c && s && c < s) ? "before" : "after"}' "$calls")/$(has "$out" 'upgrading homefield')/$(called '^guest sudo install -D')"

srun MODE=upgrade SAVED="libpq-dev shellcheck" -- cmd_upgrade --preset browsers
record "browsers on the same VM: saved list kept, twelve names appended; no hooks to copy" \
  "$(printf 'libpq-dev shellcheck %s' "$browser_libs")/0/yes" \
  "$(envline)/$(called 'limactl copy')/$(has "$out" 'upgrading homefield')"

srun MODE=upgrade SAVED="rsync" -- cmd_upgrade --preset browsers --packages "libpq-dev xvfb"
record "--preset with --packages: all sets merge once, saved list first" \
  "$(printf 'rsync libpq-dev xvfb %s' "$browser_libs")/0/yes" \
  "$(envline)/$(called 'limactl copy')/$(has "$out" 'upgrading homefield')"

echo
echo "plain --packages still replaces, with a warning naming preset names"
srun MODE=upgrade SAVED="libcairo2 libpq-dev" -- cmd_upgrade --packages "xvfb"
record "a left-out preset name is named in the warning; the list is replaced exactly" \
  "yes/yes/xvfb/0" \
  "$(has "$out" 'warning: --packages replaces the saved list')/$(has "$out" '(hooks stay): libcairo2')/$(envline)/$(called 'limactl copy')"
record "...the saved list is read once, after the runner is stopped" "1/after" \
  "$(called '^runner_extra_packages')/$(awk '/stop_runner/{s=NR} /runner_extra_packages/{r=NR} END{print (s && r && s < r) ? "after" : "before"}' "$calls")"
srun MODE=upgrade SAVED="libpq-dev" -- cmd_upgrade --packages "xvfb"
record "--packages with no preset name in the saved list: replaces silently, as before" \
  "no/xvfb/0/yes" \
  "$(has "$out" 'warning')/$(envline)/$(called 'limactl copy')/$(has "$out" 'upgrading homefield')"

echo
echo "a running job"
srun MODE=upgrade JOB=running -- cmd_upgrade --preset hosted
record "refused before copying hooks or stopping the runner" \
  "nonzero/yes/0/0/0" \
  "$(nonzero "$rc")/$(has "$out" 'a job is running')/$(called 'limactl copy')/$(called '/etc/homefield/provision.d/')/$(called '^stop_runner')"

echo
echo "install --preset on an already registered instance"
srun MODE=install SAVED="libpq-dev" -- cmd_install --preset hosted
record "hands the preset to upgrade, which adds it beside what was saved" \
  "$(printf 'yes/libpq-dev %s' "$browser_libs gh shellcheck sqlite3 xvfb rsync")/2/1" \
  "$(has "$out" 'upgrading instead')/$(envline)/$(called '^guest sudo install -D')/$(called 'sudo tee /etc/homefield/preset-hooks')"

echo
echo "the preset hook manifest (#188): a hook the preset no longer ships is removed"
srun MODE=upgrade SAVED="" -- cmd_upgrade --preset hosted
record "a first copy: both hooks installed, the manifest written, nothing removed" "2/1/0" \
  "$(called '^guest sudo install -D -m 0755')/$(called 'sudo tee /etc/homefield/preset-hooks')/$(called 'sudo rm -f')"
srun MODE=upgrade SAVED="" GUEST_MANIFEST_EXISTS=1 GUEST_HAVE="50-awscli.sh
60-nodejs.sh" -- cmd_upgrade --preset hosted
record "a manifest naming the current hooks: the same set is reinstalled, nothing removed" "2/1/0" \
  "$(called '^guest sudo install -D -m 0755')/$(called 'sudo tee /etc/homefield/preset-hooks')/$(called 'sudo rm -f')"
srun MODE=upgrade SAVED="" GUEST_MANIFEST_EXISTS=1 GUEST_HAVE="40-old.sh
50-awscli.sh
60-nodejs.sh" -- cmd_upgrade --preset hosted
record "a manifest with a retired hook: it is removed, and said so" "1/yes/2" \
  "$(called 'sudo rm -f /etc/homefield/provision.d/40-old.sh')/$(has "$out" 'removed preset hook 40-old.sh; the preset no longer ships it')/$(called '^guest sudo install -D -m 0755')"
srun MODE=upgrade SAVED="" GUEST_MANIFEST_EXISTS=1 GUEST_HAVE="../ssh/sshd_config
50-awscli.sh
60-nodejs.sh" -- cmd_upgrade --preset hosted
record "a tampered manifest line is not a rm path: skipped, nothing removed" "0" "$(called 'sudo rm -f')"
srun MODE=upgrade SAVED="" GUEST_MANIFEST_EXISTS=1 GUEST_HAVE="*.sh
50-awscli.sh
60-nodejs.sh" -- cmd_upgrade --preset hosted
record "a glob line in the manifest is read literally, not expanded" "0" "$(called 'sudo rm -f')"
srun MODE=upgrade SAVED="" GUEST_MANIFEST_EXISTS=1 GUEST_HAVE="50-awscli.sh" -- cmd_upgrade --preset hosted
record "a manifest missing a current hook: the hook is reinstalled, the manifest rewritten" "2/1/0" \
  "$(called '^guest sudo install -D -m 0755')/$(called 'sudo tee /etc/homefield/preset-hooks')/$(called 'sudo rm -f')"
srun MODE=upgrade SAVED="" GUEST_MANIFEST_EXISTS=1 GUEST_CAT_FAIL=1 -- cmd_upgrade --preset hosted
record "the read of an existing manifest fails: refused before any hook changes" \
  "nonzero/yes/0/0/0" \
  "$(nonzero "$rc")/$(has "$out" 'could not read the preset hook manifest')/$(called '^guest sudo install -D -m 0755')/$(called 'sudo tee /etc/homefield/preset-hooks')/$(called 'sudo rm -f')"
srun MODE=upgrade SAVED="" GUEST_MANIFEST_EXISTS=1 GUEST_HAVE="" -- cmd_upgrade --preset hosted
record "an existing empty manifest: hooks installed, manifest rewritten, nothing removed" "2/1/0" \
  "$(called '^guest sudo install -D -m 0755')/$(called 'sudo tee /etc/homefield/preset-hooks')/$(called 'sudo rm -f')"
srun MODE=install SAVED="" -- cmd_install --preset browsers
record "a hookless preset on a fresh install: the manifest directory is made, the manifest written" "1/1/0/0" \
  "$(called 'sudo install -d')/$(called 'sudo tee /etc/homefield/preset-hooks')/$(called '^guest sudo install -D -m 0755')/$(called 'sudo rm -f')"

summary
