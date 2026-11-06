#!/usr/bin/env bash
# setup/install and their summaries, presets, and the multi-VM
# install/upgrade/status/start/stop commands.

# ── Waiting for the runner ──────────────────────────────────────────────────
# ONLINE_WAIT_TRIES / ONLINE_WAIT_INTERVAL / ONLINE_PROGRESS_CYCLES can be
# overridden by environment variables (tests run the wait with 3 tries and no
# interval); the defaults below are for real runs.
ONLINE_WAIT_TRIES=${ONLINE_WAIT_TRIES:-18}
ONLINE_WAIT_INTERVAL=${ONLINE_WAIT_INTERVAL:-5}
# Progress reports during the wait: one every 3 poll cycles (every 15 seconds),
# so a long wait is never silent and never looks hung. If the runner comes
# online sooner, no progress output is needed. A value below 1 would make the
# divide in the loop below fail, so a non-number or non-positive falls back.
ONLINE_PROGRESS_CYCLES=${ONLINE_PROGRESS_CYCLES:-3}
[ "$ONLINE_PROGRESS_CYCLES" -ge 1 ] 2>/dev/null || ONLINE_PROGRESS_CYCLES=3

# wait_online <url> <name> <group>: until the runner shows as online on
# GitHub, up to about 90 seconds. Never fails: it only reports, because the
# registration has already happened and GitHub can be slow to list it. The
# runners list does not say which group a runner is in, so once the runner is
# online an organization's groups are asked for it (find_runner_group); when
# that cannot be done, the report says what was observed instead of assuming
# the expected group.
#
# What it saw is also left for setup's summary, whatever the log said:
# WAIT_RESULT is "online", "not-online" (the wait ran out; WAIT_SEEN is the
# status GitHub listed, if any) or "unchecked" (nothing could be asked).
# When online, WAIT_LABELS is GitHub's comma-separated label list, and for an
# organization WAIT_GROUP_STATE says whether the groups confirmed the runner is
# in the expected group ("match"), in another ("mismatch", WAIT_GROUP naming it)
# or could not say ("unconfirmed"); empty when the groups were not asked.
WAIT_RESULT=""
WAIT_SEEN=""
WAIT_LABELS=""
WAIT_GROUP=""
WAIT_GROUP_STATE=""

wait_online() {
  local url="$1" name="$2" group="$3" scope org rows="" n status rid labels grp row rc tries=0 page seen=""
  WAIT_RESULT="unchecked"
  WAIT_SEEN=""
  WAIT_LABELS=""
  WAIT_GROUP=""
  WAIT_GROUP_STATE=""
  page="$(runners_page "$url")" || exit 1
  if [ -z "$name" ] || ! command -v gh >/dev/null; then
    log "check that the runner is online at ${page}"
    return 0
  fi
  scope="$(api_scope "$url")" || exit 1
  log "waiting for ${name} to show as online (up to $((ONLINE_WAIT_TRIES * ONLINE_WAIT_INTERVAL)) s)"
  while [ "$tries" -lt "$ONLINE_WAIT_TRIES" ]; do
    # Progress: the first 15 seconds give no feedback, then a message every
    # 15 seconds while the wait continues.
    if [ $((tries % ONLINE_PROGRESS_CYCLES)) -eq 0 ] && [ "$tries" -gt 0 ]; then
      log "waiting for ${name} (up to $((ONLINE_WAIT_TRIES * ONLINE_WAIT_INTERVAL)) s, waited $((tries * ONLINE_WAIT_INTERVAL)) s)"
    fi
    if ! rows="$(gh api --paginate "${scope}/actions/runners?per_page=100" \
      --jq '.runners[] | [.name, .status, (.id | tostring), (.labels | map(.name) | join(","))] | @tsv' 2>/dev/null)"; then
      log "could not read the runners list with gh; check that the runner is online at ${page}"
      return 0
    fi
    while IFS=$'\t' read -r n status rid labels; do
      [ "$n" = "$name" ] || continue
      seen="$status"
      if [ "$status" = online ]; then
        WAIT_RESULT=online
        WAIT_LABELS="$labels"
        if [[ "$scope" == orgs/* ]]; then
          org="${scope#orgs/}"
          rc=0
          row="$(find_runner_group "$org" "$rid")" || rc=$?
          case $rc in
            0)
              IFS=$'\t' read -r grp _ <<<"$row"
              WAIT_GROUP="$grp"
              if [ "$grp" = "$group" ]; then
                WAIT_GROUP_STATE=match
                log "${name} is online: labels ${labels}, group ${grp}"
              else
                WAIT_GROUP_STATE=mismatch
                log "${name} is online: labels ${labels}, group ${grp} (expected ${group})"
              fi
              ;;
            1)
              WAIT_GROUP_STATE=unconfirmed
              log "${name} is online: labels ${labels}, in none of the runner groups gh listed for ${org}"
              ;;
            2)
              WAIT_GROUP_STATE=unconfirmed
              log "${name} is online: labels ${labels}, group not found (gh could not list the runners of every runner group in ${org})"
              ;;
            *)
              WAIT_GROUP_STATE=unconfirmed
              log "${name} is online: labels ${labels}, group not checked (gh could not list the runner groups of ${org})"
              ;;
          esac
        else
          log "${name} is online: labels ${labels}"
        fi
        return 0
      fi
    done <<<"$rows"
    tries=$((tries + 1))
    [ "$tries" -ge "$ONLINE_WAIT_TRIES" ] || sleep "$ONLINE_WAIT_INTERVAL"
  done
  WAIT_RESULT="not-online"
  WAIT_SEEN="$seen"
  echo "homefield: warning: ${name} is not online after $((ONLINE_WAIT_TRIES * ONLINE_WAIT_INTERVAL)) s (${seen:-not listed yet}); check ${page} and bin/homefield status" >&2
  return 0
}

# ── Commands ────────────────────────────────────────────────────────────────
# group_advice <group> <slug> <first> <rest>: the advice about the runner group
# that ensure_group found (GROUP_STATE), for install's closing message and
# setup's next steps. <first> starts its first line and <rest> the following
# ones, so each caller can make it a bullet or a numbered item.
group_advice() {
  local group="${1:-homefield-ci}" slug="$2" first="$3" rest="$4" verb=install
  [ "$SETUP" != 1 ] || verb=setup
  case "$GROUP_STATE" in
    narrow | created)
      echo "${first}It is in the runner group ${group}, which admits only the"
      echo "${rest}repositories added to it: homefield adopt --repo <owner>/<repo> adds one."
      ;;
    default)
      echo "${first}It is in the Default group: every repository in the organization can"
      echo "${rest}use it (docs/runbook.md, \"Runner group\")."
      ;;
    wide)
      echo "${first}Narrow the runner group ${group} as warned above, then add"
      echo "${rest}the repositories that should use it (docs/runbook.md, \"Runner group\")."
      ;;
    unchecked)
      echo "${first}Check the runner group ${group} by hand: selected repositories,"
      echo "${rest}public ones off (docs/runbook.md, \"Runner group\")."
      ;;
    personal)
      echo "${first}It serves only ${slug}: a personal account has no account-wide runners or"
      echo "${rest}runner groups. Another repository needs its own registration and its own VM:"
      echo "${rest}homefield ${verb} --instance <name> --url https://github.com/<owner>/<repo>."
      ;;
  esac
}

# registered_next_steps <group> <url>: install's closing advice, by what
# ensure_group found (GROUP_STATE).
registered_next_steps() {
  local group="$1" slug="${2%/}"
  slug="${slug#https://github.com/}"
  echo
  echo "Registered. Next:"
  group_advice "$group" "$slug" "  - " "    "
  cat <<EOF
  - Route jobs from a repository: docs/adopting.md, then
    homefield adopt --repo <owner>/<repo> (group access and the switch).
  - bin/homefield status   shows the runner at any time.
EOF
}

# ── setup's summary ─────────────────────────────────────────────────────────
# `homefield setup` is install behind a stricter gate (preflight must pass in
# full) and with a closing summary instead of registered_next_steps. A line
# starts with a check mark for what was done and is true, or "!" for what
# needs attention; nothing is claimed that was not seen. SETUP is 1 for setup.
SETUP=0
# What the VM's status was before install touched it (empty: there was none).
SETUP_VM_WAS=""

# setup_vm_lines: the VM and its isolation. Both are facts by the time this is
# called: ensure_vm left the VM running, and verify_isolation dies otherwise.
setup_vm_lines() {
  if [ -z "$SETUP_VM_WAS" ]; then
    echo "✓ VM ${INSTANCE} created (Running)"
  elif [ "$SETUP_VM_WAS" = Running ]; then
    echo "✓ VM ${INSTANCE} already existed (Running)"
  else
    echo "✓ VM ${INSTANCE} already existed (${SETUP_VM_WAS}); started"
  fi
  echo "✓ Isolation verified (no host mounts)"
}

# setup_group_line <group> <slug>: the runner group, by what ensure_group found.
setup_group_line() {
  local group="${1:-homefield-ci}" slug="$2"
  case "$GROUP_STATE" in
    created) echo "✓ Runner group ${group} created (selected repositories, public off)" ;;
    narrow) echo "✓ Runner group ${group} exists (selected repositories, public off)" ;;
    default) echo "✓ Runner group Default (every repository in the organization can use it)" ;;
    wide) echo "! Runner group ${group} is wider than recommended: narrow it (docs/runbook.md, \"Runner group\")" ;;
    unchecked) echo "! Runner group ${group} was not checked: confirm it by hand (selected repositories, public off)" ;;
    personal) echo "✓ Registered to ${slug} only (a personal account has no runner groups)" ;;
    repo) echo "✓ Registered to ${slug} only (a repository has no runner groups)" ;;
  esac
}

# setup_runner_lines <url> <name> <id>: the registration, and what wait_online
# saw of the runner on GitHub.
setup_runner_lines() {
  local url="$1" name="$2" id="$3"
  if [ -z "$name" ]; then
    echo "! Runner registered, but its name could not be read from the VM: see $(runners_page "$url")"
  elif [ -n "$id" ]; then
    echo "✓ Runner registered (${name}, id ${id})"
  else
    echo "✓ Runner registered (${name})"
  fi
  case "$WAIT_RESULT" in
    online)
      case "$WAIT_GROUP_STATE" in
        match) echo "✓ Runner online (labels: ${WAIT_LABELS//,/ }; group ${WAIT_GROUP})" ;;
        *) echo "✓ Runner online (labels: ${WAIT_LABELS//,/ })" ;;
      esac
      case "$WAIT_GROUP_STATE" in
        mismatch) echo "! Runner is in the runner group ${WAIT_GROUP}, not the one asked for: check it at $(runners_page "$url")" ;;
        unconfirmed) echo "! Its runner group could not be confirmed: check it at $(runners_page "$url")" ;;
      esac
      ;;
    not-online)
      echo "! Runner not online yet (GitHub lists it as: ${WAIT_SEEN:-not listed yet}): check $(runners_page "$url") and homefield status"
      ;;
    *)
      echo "! Runner online check skipped (GitHub could not be asked): check $(runners_page "$url")"
      ;;
  esac
}

# setup_repositories <slug>: who can use the runner now. This is group access,
# not whether a repository's CI_RUNNER switch is on, so it says "can use". A
# list that could not be read is said so, never printed as an empty one.
setup_repositories() {
  local slug="$1" org="${1%%/*}" repos r
  echo
  echo "Repositories that can use this runner:"
  case "$GROUP_STATE" in
    personal | repo)
      echo "  ${slug} (this runner is registered to it)"
      ;;
    narrow | created)
      if [ -z "$GROUP_ID" ]; then
        echo "  could not be listed (the group's id is not known); see the runner group's page in ${org}'s settings"
      elif repos="$(group_repositories "$org" "$GROUP_ID")"; then
        if [ -z "$repos" ]; then
          echo "  none yet: homefield adopt --repo <owner>/<repo> adds one"
        else
          while IFS= read -r r; do
            if [ -n "$r" ]; then echo "  ${r}"; fi
          done <<<"$repos"
        fi
      else
        echo "  could not be listed (gh could not read the runner group's repositories); see the runner group's page in ${org}'s settings"
      fi
      ;;
    default) echo "  every repository in ${org} (the Default group admits them all)" ;;
    wide) echo "  not listed: this group admits repositories by kind, not from a list (narrow it, as warned above)" ;;
    *) echo "  not listed: the runner group was not checked, so who can use it is unknown" ;;
  esac
}

# setup_next_steps <group> <slug>: what to do now, then who can use the runner.
setup_next_steps() {
  local group="$1" slug="$2"
  echo
  echo "Next steps:"
  echo "  1. Route a repository: homefield adopt --repo <owner>/<repo>"
  echo "     (add --setup and it opens the pull request with the routing edits)"
  echo "  2. See docs/adopting.md for the full guide"
  group_advice "$group" "$slug" "  3. " "     "
  setup_repositories "$slug"
}

# setup_summary <group> <url> <name> <id>: the end of a fresh setup.
setup_summary() {
  local group="$1" url="$2" slug="${2%/}"
  slug="${slug#https://github.com/}"
  echo
  setup_vm_lines
  setup_group_line "$group" "$slug"
  setup_runner_lines "$url" "$3" "$4"
  setup_next_steps "$group" "$slug"
}

setup_routing_args() {
  SETUP_ROUTING_ARGS=(--repo "$1" --setup --wait)
  [ -z "$SETUP_LABEL" ] || SETUP_ROUTING_ARGS+=(--label "$SETUP_LABEL")
  [ -z "$SETUP_GROUP" ] || SETUP_ROUTING_ARGS+=(--group "$SETUP_GROUP")
}

# setup_plain_adopt <owner/repo>: the plain adopt that finishes what the
# routing pull request starts, with the label and group the runner was
# registered with (a plain adopt without --group looks at homefield-ci, and
# would add the repository to the wrong group). Words are shell-quoted: a group
# name may hold a space.
setup_plain_adopt() {
  local c
  c="homefield adopt --repo $(printf '%q' "$1")"
  [ -z "$SETUP_LABEL" ] || c="$c --label $(printf '%q' "$SETUP_LABEL")"
  [ -z "$SETUP_GROUP" ] || c="$c --group $(printf '%q' "$SETUP_GROUP")"
  printf '%s' "$c"
}

# setup_route_repo <owner/repo>: opens the routing pull request and waits for
# its merge, by running adopt --setup --wait. It runs in a subshell, so adopt's
# die cannot end setup, and a failure leaves setup a success: adopt has said
# why, and this says what is left. errexit is off around the subshell and on
# inside it, because a subshell tested with `||` or `if` would run adopt with
# errexit off. adopt's exit status tells the cases apart (see ADOPT_EXIT_OPEN):
#   ADOPT_EXIT_OPEN    the pull request is open and the wait did not end in a
#                      merge (timeout, closed, unreadable): no --setup retry,
#                      the branch exists
#   ADOPT_EXIT_MERGED  merged, but adopt did not finish what follows
#   130, 143           Ctrl-C or SIGTERM: setup ends with that status, as the
#                      user cancelled. adopt handles both signals in every
#                      phase of a --setup run (before the pull request, while
#                      waiting, after the merge, in --verify), says where things
#                      stand and exits with the signal's status, so this note
#                      only points at what adopt printed
#   other              nothing was opened (a public repository, no write
#                      access, no workflow to route, the branch already there)
# The terminal sends Ctrl-C to setup as well as to adopt. Setup traps nothing:
# while it waits for a foreground subshell bash defers its own SIGINT, and acts
# on it afterwards only if the subshell died of SIGINT. adopt exits 130 itself,
# so setup carries on to its note. A SIGTERM sent to setup alone ends it at
# once, and its adopt (not a background job, which would ignore SIGINT and lose
# stdin) would wait on: it is told setup's pid in ADOPT_PARENT_PID and stops
# within one poll interval of setup being gone (adopt_check_parent).
# tests/adopt.sh signals the process group and setup alone for real, on bash 3.2
# and 5.
setup_route_repo() {
  local rc
  setup_routing_args "$1"
  set +e
  # $$ inside the subshell is still setup's pid
  # shellcheck disable=SC2034  # read by cmd-adopt.sh's adopt_check_parent
  ADOPT_PARENT_PID=$$
  ( set -e; cmd_adopt "${SETUP_ROUTING_ARGS[@]}" )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && return 0
  echo
  case "$rc" in
    "$ADOPT_EXIT_OPEN")
      echo "The runner is set up. The routing pull request is open; adopt stopped waiting for it (what it printed above says what to run next)."
      ;;
    130 | 143)
      echo "The runner is set up. adopt was interrupted (what it printed above says where things stand and what to run next)."
      exit "$rc"
      ;;
    "$ADOPT_EXIT_MERGED")
      echo "The runner is set up. The routing pull request was merged but adopt did not finish switching the repository (what it printed above says why); run: $(setup_plain_adopt "$1")"
      ;;
    *)
      echo "The runner is set up. The routing pull request was not opened (adopt says why above)."
      echo "To try again: homefield adopt ${SETUP_ROUTING_ARGS[*]}"
      ;;
  esac
}

# setup_skip_routing <owner/repo>: a declined offer, with the command for later.
setup_skip_routing() {
  setup_routing_args "$1"
  echo "Route it later with: homefield adopt ${SETUP_ROUTING_ARGS[*]}"
}

# setup_offer_routing <url>: the end of a fresh setup on a terminal. The
# registration names the repository when it is repository-scoped (a personal
# account, or a repository URL), so setup offers to open its routing pull
# request; for an organization it asks which repository first. Nothing is
# created on GitHub without the answer; adopt keeps refusing public
# repositories and needing write access. End of input (Ctrl-D) is a no.
setup_offer_routing() {
  local slug="${1%/}" answer repo
  slug="${slug#https://github.com/}"
  have_terminal || return 0
  echo
  if [[ "$slug" == */* ]]; then
    printf 'Open the routing pull request for %s now, and carry on once you merge it? [Y/n] ' "$slug" >&2
    if ! read -r answer; then
      echo >&2
      answer=n
    fi
    case "$answer" in
      [Nn]*) setup_skip_routing "$slug" ;;
      *) setup_route_repo "$slug" ;;
    esac
    return 0
  fi
  printf 'Repository to route first (name or owner/repo; Enter to skip): ' >&2
  if ! read -r answer; then
    echo >&2
    answer=""
  fi
  if [ -z "$answer" ]; then
    setup_skip_routing "<owner>/<repo>"
    return 0
  fi
  case "$answer" in
    */*) repo="$answer" ;;
    *) repo="${slug}/${answer}" ;;
  esac
  if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "homefield: not a repository name or owner/repo: ${answer}; no pull request was opened" >&2
    setup_skip_routing "<owner>/<repo>"
    return 0
  fi
  setup_route_repo "$repo"
}

# setup_upgrade_summary: the end of a setup that found its runner registered and
# upgraded it. The registration and its group were not looked at again, so
# neither is claimed. Its settings are read back from the VM for the line.
setup_upgrade_summary() {
  local name="" id=""
  { IFS= read -r name || true; IFS= read -r id || true; } < <(runner_setting agentName agentId)
  echo
  setup_vm_lines
  if [ -n "$name" ] && [ -n "$id" ]; then
    echo "✓ Runner ${name} (id ${id}) was already registered: upgraded in place"
  elif [ -n "$name" ]; then
    echo "✓ Runner ${name} was already registered: upgraded in place"
  else
    echo "✓ The runner was already registered: upgraded in place"
  fi
  echo
  echo "Next steps:"
  echo "  1. Route a repository: homefield adopt --repo <owner>/<repo>"
  echo "     (add --setup and it opens the pull request with the routing edits)"
  echo "  2. See docs/adopting.md for the full guide"
  echo "  3. homefield status shows the runner at any time"
}

# cmd_setup: install's options and steps, with the stricter preflight gate and
# the summary (SETUP, read by cmd_install).
cmd_setup() {
  # `homefield setup --exists`: install.sh's sturdier probe for whether this
  # copy has the setup command at all — a check of the command, not of the
  # help text's layout (which a reflow would break). Exits 0, prints nothing.
  [ "${1:-}" = "--exists" ] && [ $# -eq 1 ] && return 0
  SETUP=1
  cmd_install "$@"
}

# ── Presets ─────────────────────────────────────────────────────────────────
# Shipped sets for closing a hosted-parity gap in one command (#175): each is
# vm/presets/<name>/, with `packages` (apt names, one or more per line; blank
# lines and # comments allowed) and any *.sh files beside it, which are hooks
# copied into the guest's /etc/homefield/provision.d/ for provision.sh to run.
# A preset may be another's superset: `include <name>` on its own line pulls in
# that preset's packages and hooks. Presets ADD to what a VM already has; only
# plain --packages replaces the saved list (and then says so).
PRESETS="$ROOT/vm/presets"
GUEST_HOOKS="/etc/homefield/provision.d"
# The manifest of the preset hooks this VM's provision.d got, one name per
# line: what copy_preset_hooks prunes retired hooks against (#188).
GUEST_MANIFEST="/etc/homefield/preset-hooks"

# preset_list: the shipped presets, for messages.
preset_list() {
  local d names=""
  for d in "$PRESETS"/*/; do
    [ -f "$d/packages" ] || continue
    d="${d%/}"
    names="$names ${d##*/}"
  done
  printf '%s' "${names# }"
}

_preset_load() {
  local name="$1" dir line words pkg f base
  case "$SEEN_PRESETS" in *" $name "*) return ;; esac
  SEEN_PRESETS="$SEEN_PRESETS$name "
  dir="$PRESETS/$name"
  [ -f "$dir/packages" ] || die "--preset $name: no such preset; shipped presets are $(preset_list)"
  while IFS= read -r line || [ -n "$line" ]; do
    # Trim, then skip blank lines and comments.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in '' | '#'*) continue ;; esac
    read -ra words <<<"$line"
    if [ "${words[0]}" = include ]; then
      [ ${#words[@]} -eq 2 ] || die "--preset $name: $dir/packages: 'include' takes one preset name, got: $line"
      _preset_load "${words[1]}"
      continue
    fi
    for pkg in "${words[@]}"; do
      # The same rule provision.sh applies to the names it hands apt-get.
      [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] ||
        die "--preset $name: $dir/packages: not a package name: $pkg"
      case " $PRESET_PKGS " in *" $pkg "*) continue ;; esac
      PRESET_PKGS="${PRESET_PKGS:+$PRESET_PKGS }$pkg"
    done
  done <"$dir/packages"
  for f in "$dir"/*.sh; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    case "$HOOK_NAMES" in *" $base "*) die "--preset: two hooks named $base (one is $f); a preset set cannot carry both into ${GUEST_HOOKS}" ;; esac
    HOOK_NAMES="$HOOK_NAMES$base "
    PRESET_HOOKS+=("$f")
  done
}

# load_presets <name>...: validates the names and everything they include, then
# sets PRESET_PKGS (apt names, space-separated, first-seen order) and
# PRESET_HOOKS (absolute hook paths). Dies before anything is stopped or
# created on an unknown preset, a bad name, an ambiguous include, or two hooks
# with the same file name.
load_presets() {
  local name
  # Leading space, so the first name is matched like every later one: `--preset
  # hosted --preset hosted` loads it once instead of colliding with itself.
  SEEN_PRESETS=" "
  HOOK_NAMES=" "
  PRESET_PKGS=""
  PRESET_HOOKS=()
  for name in "$@"; do _preset_load "$name"; done
}

# merge_packages <space-separated list>...: the lists joined, first-seen order,
# duplicates dropped. Presets and --packages both feed it; a preset never drops
# what is already there.
merge_packages() {
  local out="" seen=" " arg pkg
  # The caller's globbing is saved and restored: set -f is global, and the
  # unquoted $have split below needs it off only inside this function.
  case "$-" in *f*) local had_f=1 ;; *) local had_f=0 ;; esac
  set -f
  for arg in "$@"; do
    # shellcheck disable=SC2086  # the lists are space-separated words by design
    for pkg in $arg; do
      case "$seen" in *" $pkg "*) continue ;; esac
      seen="$seen$pkg "
      out="${out:+$out }$pkg"
    done
  done
  if [ "$had_f" = 1 ]; then set -f; else set +f; fi
  printf '%s' "$out"
}

# copy_preset_hooks: puts PRESET_HOOKS in the guest's provision.d, so this and
# every later provisioning run executes them (a plain `upgrade` keeps them).
# Staged through a private directory (#185): each hook is installed by root
# from the guest's /tmp, and a fixed name there is a live job's to pre-plant.
copy_preset_hooks() {
  local f base stage have removed="" names=""
  stage="$(guest_stage_dir)"
  trap 'guest_unstage "$stage"' RETURN
  # The manifest from the last copy names what this VM's provision.d got from
  # presets: a hook the current set no longer ships is removed, so a retired
  # hook does not keep running as root on every provision run (#188). A
  # missing manifest is a first copy, nothing to prune; a failed read of one
  # that exists must not read as empty — the write below would replace it and
  # the retired hooks' ownership records would be lost for good — so it dies.
  if guest_stdin sudo test -f "$GUEST_MANIFEST" </dev/null 2>/dev/null; then
    have="$(guest_stdin sudo cat "$GUEST_MANIFEST" </dev/null 2>/dev/null)" ||
      die "could not read the preset hook manifest of VM ${INSTANCE}; nothing was stopped"
  else
    have=""
  fi
  for f in ${PRESET_HOOKS[@]+"${PRESET_HOOKS[@]}"}; do
    base="${f##*/}"
    limactl copy "$f" "${INSTANCE}:${stage}/${base}" </dev/null ||
      die "could not copy preset hook ${base} into VM ${INSTANCE}; nothing was stopped"
    names="${names:+$names }$base"
  done
  # Only a plain file name of a hook this manifest installed: the manifest
  # sits in the guest, so a tampered line must not become a root rm path.
  # set -f: unquoted $have splits the manifest's lines, and a glob line must
  # not expand against this directory before the check runs.
  set -f
  # shellcheck disable=SC2086  # the manifest is newline-separated words by design
  for base in $have; do
    [[ "$base" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    case " $names " in *" $base "*) ;; *) removed="${removed:+$removed }$base" ;; esac
  done
  set +f
  for f in ${PRESET_HOOKS[@]+"${PRESET_HOOKS[@]}"}; do
    base="${f##*/}"
    guest_stdin sudo install -D -m 0755 "${stage}/${base}" "${GUEST_HOOKS}/${base}" </dev/null ||
      die "could not install preset hook ${base} in VM ${INSTANCE}; nothing was stopped"
  done
  for base in $removed; do
    guest_stdin sudo rm -f "${GUEST_HOOKS}/${base}" </dev/null ||
      die "could not remove retired preset hook ${base} in VM ${INSTANCE}; nothing was stopped"
    log "${INSTANCE}: removed preset hook ${base}; the preset no longer ships it"
  done
  # The manifest is what the next copy prunes against: the names this copy
  # installed, one per line. Through the guest: the stage dir is the guest's
  # and there is no shared mount, so a host-side redirection has no path to
  # write to (found by review on this PR). The parent does not exist on a
  # fresh install of a preset with no hooks — nothing else creates it — so it
  # is made here.
  guest_stdin sudo install -d -m 0755 "${GUEST_MANIFEST%/*}" </dev/null ||
    die "could not create ${GUEST_MANIFEST%/*} in VM ${INSTANCE}; nothing was stopped"
  # shellcheck disable=SC2086  # unquoted: word splitting puts each name on its own line
  printf '%s\n' $names | guest_stdin sudo tee "$GUEST_MANIFEST" >/dev/null ||
    die "could not write the preset hook manifest in VM ${INSTANCE}; nothing was stopped"
  guest_unstage "$stage"
  trap - RETURN
}

# preset_saved_drops <replacement>: names from any shipped preset that are in
# the VM's saved list but not in the replacement --packages value. Plain
# --packages replaces the whole list, so these would stop being reinstalled.
preset_saved_drops() {
  local replacement=" $1 " d name pkg drops="" tops=()
  for d in "$PRESETS"/*/; do
    [ -f "$d/packages" ] || continue
    d="${d%/}"
    tops+=("${d##*/}")
  done
  load_presets ${tops[@]+"${tops[@]}"}
  for pkg in $PRESET_PKGS; do
    case " $(runner_extra_packages) " in *" $pkg "*) ;; *) continue ;; esac
    case "$replacement" in *" $pkg "*) continue ;; esac
    drops="${drops:+$drops }$pkg"
  done
  printf '%s' "$drops"
}

cmd_install() {
  local url="" label="" name="" group="" packages="" packages_set=0 cpus="" memory="" autostart=1 replace=0 cmd=install
  local presets=()
  [ "$SETUP" != 1 ] || cmd=setup
  while [ $# -gt 0 ]; do
    # GROUP_EXISTS and replace are read by lib/github.sh (ensure_group,
    # check_name_free), so shellcheck's per-file view calls them unused.
    # shellcheck disable=SC2034
    case "$1" in
      --url) url="${2:?--url needs a value}"; shift 2 ;;
      --label) label="${2:?--label needs a value}"; shift 2 ;;
      --name) name="${2:?--name needs a value}"; shift 2 ;;
      --group) group="${2:?--group needs a value}"; shift 2 ;;
      --packages) packages="${2?--packages needs a value (may be empty)}"; packages_set=1; shift 2 ;;
      --preset) presets+=("${2:?--preset needs a value}"); shift 2 ;;
      --cpus) cpus="${2:?--cpus needs a value}"; shift 2 ;;
      --memory) memory="${2:?--memory needs a value}"; shift 2 ;;
      --no-autostart) autostart=0; shift ;;
      --group-exists) GROUP_EXISTS=1; shift ;;
      --replace) replace=1; shift ;;
      --personal)
        [ "$ACCOUNT_FORCE" != org ] || die "${cmd}: --personal and --org cannot be used together"
        ACCOUNT_FORCE=personal; shift ;;
      --org)
        [ "$ACCOUNT_FORCE" != personal ] || die "${cmd}: --personal and --org cannot be used together"
        ACCOUNT_FORCE=org; shift ;;
      *) die "${cmd}: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  # A preset that does not exist stops here: nothing has been created yet.
  [ ${#presets[@]} -eq 0 ] || load_presets ${presets[@]+"${presets[@]}"}
  # The readiness report comes first, before anything is created, and install
  # then gates on its own subset of it — macOS, arm64, Lima — which check_host
  # is: gh, python3 and brew are what the tool needs elsewhere (adopt, report,
  # the one-liner), and install itself can proceed without them.
  # setup stops on a failed check instead (FAIL only: a WARN is not one), and
  # before anything else, so a failed setup has created and touched nothing.
  # On a terminal, setup first offers to log gh in, so that check can pass.
  if [ "$SETUP" = 1 ]; then
    local preflight_rc=0
    offer_gh_login "$url"
    cmd_preflight || preflight_rc=$?
    [ "$preflight_rc" -eq 0 ] ||
      die "setup stopped: fix the failed checks above and run it again; nothing was created"
  else
    cmd_preflight || true
  fi
  check_host
  # Everything that can be checked is checked before anything is created: the
  # URL (asked for if it was not given), the organization, the runner group.
  # Whether the instance is registered is only known once its VM is up and
  # verified, but a VM that does not exist yet is certainly not registered, so
  # in that case it all happens first. With a VM already there, a URL that
  # was given is still validated before the VM is started, and the rest waits
  # for the answer to "registered?" (a registered instance is just upgraded).
  local prepared=0
  vm_lookup
  SETUP_VM_WAS="$VM_STATUS"
  if [ -z "$VM_STATUS" ]; then
    prepare_registration
    prepared=1
  elif [ -n "$url" ]; then
    validate_scope "$url"
  fi
  ensure_vm "$cpus" "$memory"
  verify_isolation

  if is_registered; then
    log "${INSTANCE} is already registered; upgrading instead (registration settings are kept)"
    local args=()
    [ "$packages_set" = 1 ] && args+=(--packages "$packages")
    local p
    for p in ${presets[@]+"${presets[@]}"}; do args+=(--preset "$p"); done
    upgrade_registered "${args[@]+"${args[@]}"}"
    [ "$SETUP" != 1 ] || setup_upgrade_summary
    return
  fi

  [ "$prepared" = 1 ] || prepare_registration
  local env=(RUNNER_URL="$url" RUNNER_NAME="$name")
  [ -n "$label" ] && env+=(RUNNER_LABEL="$label")
  [ -n "$group" ] && env+=(RUNNER_GROUP="$group")
  if [ ${#presets[@]} -gt 0 ]; then
    # Presets add to whatever the VM already had, and --packages adds to both.
    local extra="" merged=""
    [ "$packages_set" = 1 ] && extra="$packages"
    merged="$(merge_packages "$(runner_extra_packages)" "$extra" "$PRESET_PKGS")"
    env+=(RUNNER_EXTRA_PACKAGES="$merged")
    copy_preset_hooks
  elif [ "$packages_set" = 1 ]; then
    env+=(RUNNER_EXTRA_PACKAGES="$packages")
  fi

  local token
  token="$(get_token registration "$url")"
  remove_taken_name "$url" "$name"
  log "provisioning ${INSTANCE} and registering at ${url}"
  run_provision "RUNNER_TOKEN=${token}"$'\n' "${env[@]}"
  token=""
  [ "$autostart" = 1 ] && enable_autostart
  # The name and id the runner registered under, read back from its config.
  local registered_name="" registered_id=""
  { IFS= read -r registered_name || true; IFS= read -r registered_id || true; } < <(runner_setting agentName agentId)
  wait_online "$url" "$registered_name" "${group:-homefield-ci}"
  if [ "$SETUP" = 1 ]; then
    setup_summary "${group:-homefield-ci}" "$url" "$registered_name" "$registered_id"
    SETUP_LABEL="$label" SETUP_GROUP="$group"
    setup_offer_routing "$url"
  else
    registered_next_steps "${group:-homefield-ci}" "$url"
  fi
}

# upgrade_single: one VM's upgrade; vm_dispatch runs it for every VM by default.
upgrade_single() {
  local packages="" packages_set=0 force=0 presets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --packages) packages="${2?--packages needs a value (may be empty)}"; packages_set=1; shift 2 ;;
      --preset) presets+=("${2:?--preset needs a value}"); shift 2 ;;
      --force) force=1; shift ;;
      *) die "upgrade: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  [ ${#presets[@]} -eq 0 ] || load_presets ${presets[@]+"${presets[@]}"}
  check_host
  vm_lookup
  [ -n "$VM_STATUS" ] || die "no VM ${INSTANCE}; run bin/homefield install"
  ensure_vm "" ""
  verify_isolation
  is_registered || die "${INSTANCE} is not registered; run bin/homefield install --url ..."
  # A registration GitHub removed would only fail at the end, when the runner
  # cannot start a session; one that cannot be checked goes ahead.
  local url="" id="" name="" on=0
  { read -r url || true; read -r id || true; read -r name || true; } < <(runner_setting gitHubUrl agentId agentName)
  runner_on_github "$url" "$id" || on=$?
  [ "$on" != 1 ] || die "GitHub no longer has ${INSTANCE}'s runner (id ${id}) at ${url}: it removes runners that have not connected for more than 14 days. Nothing was stopped. Register it again: $(removed_recovery "$url" "$name")"
  # An upgrade can restart Docker (apt) or the runner (a new binary), which
  # would take down a running job.
  if is_job_running && [ "$force" != 1 ]; then
    die "a job is running on ${INSTANCE}; try again when it is idle, or pass --force"
  fi
  # Presets add to the saved list (and to any --packages), so nothing a VM had
  # stops being reinstalled. Plain --packages still replaces the whole list;
  # say which preset names that takes out of it.
  local merged=""
  if [ ${#presets[@]} -gt 0 ]; then
    copy_preset_hooks
    local extra="" saved=""
    [ "$packages_set" = 1 ] && extra="$packages"
    saved="$(runner_extra_packages)"
    merged="$(merge_packages "$saved" "$extra" "$PRESET_PKGS")"
  elif [ "$packages_set" = 1 ]; then
    local dropped=""
    dropped="$(preset_saved_drops "$packages")"
    if [ -n "$dropped" ]; then
      log "warning: --packages replaces the saved list; preset packages not in it will stop being reinstalled (hooks stay): $dropped"
    fi
  fi
  stop_runner
  local env=()
  if [ ${#presets[@]} -gt 0 ]; then
    env+=(RUNNER_EXTRA_PACKAGES="$merged")
  elif [ "$packages_set" = 1 ]; then
    env+=(RUNNER_EXTRA_PACKAGES="$packages")
  fi
  log "upgrading ${INSTANCE}"
  # provision.sh starts the service again at the end, and waits until it is
  # listening for jobs.
  run_provision "" "${env[@]+"${env[@]}"}"
  runner_back
}

cmd_upgrade() {
  # The options are validated once here: an unknown one, or a malformed preset,
  # fails before any VM is stopped and does not repeat per instance (#182).
  local opts=("$@") packages_set=0 presets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --packages)
        [ $# -ge 2 ] || die "--packages needs a value (may be empty)"
        shift 2
        ;;
      --preset)
        presets+=("${2:?--preset needs a value}")
        shift 2
        ;;
      --force) shift ;;
      *) die "upgrade: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  [ ${#presets[@]} -eq 0 ] || load_presets "${presets[@]+"${presets[@]}"}"
  vm_dispatch upgrade upgrade_single "${opts[@]+"${opts[@]}"}"
}

# runner_report <verbose>: the runner half of a status/start report — the
# registration, GitHub's listing, the service — the ~40 lines the two reports
# share. "verbose" is start's form of the GitHub line (it names the status and
# points at the runners page when the runner is listed but not online).
# Leaves the answers in RR_NAME/RR_URL/RR_ID/RR_REMOVED/RR_UNKNOWN/RR_NOTREG/
# RR_SVC/RR_ON for the caller: status ends on a removed runner, start computes
# "taking jobs" from the service and the listing, and the not-registered extra
# line is start's, not status's. A guest that cannot be asked is reported as
# unknown, never read as "not registered" (#80).
RR_NAME="" RR_URL="" RR_ID="" RR_REMOVED=0 RR_UNKNOWN=0 RR_NOTREG=0 RR_SVC=0 RR_ON=2 RR_ASKFAIL=0
runner_report() {
  local reg=0 on=0
  RR_REMOVED=0; RR_UNKNOWN=0; RR_NOTREG=0; RR_SVC=0; RR_ON=2; RR_ASKFAIL=0
  registered || reg=$?
  if [ "$reg" -ge 2 ]; then
    echo "runner: unknown (could not ask the VM)"
    RR_UNKNOWN=1
    RR_ASKFAIL=1
    return 0
  fi
  if [ "$reg" = 1 ]; then
    echo "runner: not registered"
    RR_NOTREG=1
    return 0
  fi
  # Fewer than three lines read must reach the check below, not stop here.
  load_runner_settings
  # RS_NAME/RS_URL/RS_ID are lib/vm.sh's load_runner_settings' output.
  # shellcheck disable=SC2153
  RR_NAME="$RS_NAME" RR_URL="$RS_URL" RR_ID="$RS_ID"
  if [ -n "$RR_NAME" ] && [ -n "$RR_URL" ]; then
    echo "runner: ${RR_NAME}, registered at ${RR_URL}"
  else
    # The registration exists (.runner is there) but its details could not be
    # read just now; the rest of the report still stands on its own, and the
    # GitHub ask needs an id.
    echo "runner: registered, but its details could not be read"
  fi
  runner_on_github "$RR_URL" "$RR_ID" || on=$?
  RR_ON="$on"
  case "$on" in
    0)
      if [ "${1:-}" = verbose ]; then
        echo "github: listed (${RUNNER_GH_STATUS})"
        if [ "$RUNNER_GH_STATUS" != online ]; then
          echo "  GitHub lists it, but not online (${RUNNER_GH_STATUS}): check $(runners_page "$RR_URL")"
        fi
      else
        echo "github: listed"
      fi
      ;;
    1)
      echo "github: NOT listed: GitHub removes runners that have not connected for more than 14 days."
      echo "  Register it again: $(removed_recovery "$RR_URL" "$RR_NAME")"
      RR_REMOVED=1
      ;;
    3)
      echo "github: not checked (timed out after ${GH_TIMEOUT}s; the network may be down)"
      # start counts an unproven GitHub answer as unknown; status's report
      # stands on its own and exits 0 (its job/npm rows carry the unknowns).
      [ "${1:-}" = verbose ] && RR_UNKNOWN=1
      ;;
    *)
      if [ -n "$RR_ID" ]; then
        echo "github: not checked (needs gh with admin access to ${RR_URL})"
      else
        echo "github: not checked (no runner id in the VM's settings)"
      fi
      [ "${1:-}" = verbose ] && RR_UNKNOWN=1
      ;;
  esac
  if runner_service_state; then
    echo "service: running"
  else
    RR_SVC=1
    echo "service: NOT running (${SERVICE_UNIT:-no service installed})"
  fi
  return 0
}

# status_single: one VM's report; vm_dispatch runs it for every VM by default.
status_single() {
  [ $# -eq 0 ] || die "status takes no options besides --instance"
  command -v limactl >/dev/null || die "Lima is not installed"
  local status
  if ! status="$(vm_status)"; then
    echo "VM ${INSTANCE}: unknown (could not ask Lima)"
    return 1
  fi
  if [ -z "$status" ]; then
    echo "VM ${INSTANCE}: not created"
    return
  fi
  echo "VM ${INSTANCE}: ${status}"
  [ "$status" = "Running" ] || return 0
  runner_report
  [ "$RR_ASKFAIL" = 0 ] || return 1
  [ "$RR_NOTREG" = 0 ] || return 0
  local job=0 npm=0
  job_running || job=$?
  case "$job" in
    0) echo "job: running" ;;
    1) echo "job: idle" ;;
    *) echo "job: unknown (could not ask the VM)"; RR_UNKNOWN=1 ;;
  esac
  echo "runner version: $(runner_version)"
  npm_state || npm=$?
  case "$npm" in
    0) echo "npm: ok" ;;
    1)
      echo "npm: BROKEN (a runner self-update can flatten the externals symlinks; docs/runbook.md, \"Runner updates\")"
      RR_UNKNOWN=1
      ;;
    *) echo "npm: unknown (could not ask the VM)"; RR_UNKNOWN=1 ;;
  esac
  echo "extra packages: $(runner_extra_packages)"
  [ -n "$RR_URL" ] && echo "labels: see $(runners_page "$RR_URL") (not stored in the VM)"
  [ "$RR_REMOVED" = 0 ] || return 1
  return "$RR_UNKNOWN"
}

# upgrade_registered <upgrade args...>: the fallback install/setup take on an
# instance that is already registered. It upgrades THAT VM only — never every
# VM on the Mac, which a default `homefield upgrade` covers (#182 review): the
# packages and presets given to install belong to its own instance.
upgrade_registered() {
  local saved="$EXPLICIT_INSTANCE"
  EXPLICIT_INSTANCE=1
  cmd_upgrade "$@"
  EXPLICIT_INSTANCE="$saved"
}

cmd_status() {
  [ $# -eq 0 ] || die "status takes no options besides --instance"
  vm_dispatch status status_single
}

# ── start / stop ────────────────────────────────────────────────────────────
# The VM lifecycle the failure mode needs. Until now only install, upgrade,
# uninstall and reset started or stopped a VM internally (ensure_vm,
# uninstall's deregister path), so diagnose named limactl for the most common
# "CI is not running" state. Starting a stopped VM does what ensure_vm's start
# does: `--tty=false`, and stdin closed. Booting
# is not the same fact as serving jobs, so start asks afterwards: registered,
# service running and GitHub listing it online. status's helpers answer both
# (runner_service_state, runner_on_github) and its GH_TIMEOUT bounds the GitHub
# ask; install's 90 s wait (wait_online) is not used here: start reports now,
# not after a poll. Read-only in the guest: nothing is provisioned or changed.
# start_single / stop_single: one VM; vm_dispatch runs them for every VM by default.
start_single() {
  [ $# -eq 0 ] || die "start takes no options besides --instance"
  check_host
  vm_lookup
  [ -n "$VM_STATUS" ] || die "no VM ${INSTANCE}; run bin/homefield install --instance ${INSTANCE} --url https://github.com/<org>[/<repo>]"
  if [ "$VM_STATUS" != "Running" ]; then
    log "starting VM ${INSTANCE}"
    limactl start --tty=false "$INSTANCE" </dev/null ||
      die "could not start VM ${INSTANCE} (Lima failed; docs/runbook.md, \"Failure modes\" names the states that keep it from booting)"
  fi
  echo "VM ${INSTANCE}: Running"
  # The guest answers only now; a VM that could not be asked is reported as
  # unknown, never read as "not registered" (#80).
  runner_report verbose
  [ "$RR_ASKFAIL" = 0 ] || return 1
  if [ "$RR_NOTREG" = 1 ]; then
    echo "  Register it, then run this again: bin/homefield install --instance ${INSTANCE} --url https://github.com/<org>[/<repo>]"
    return 1
  fi
  local svc="$RR_SVC" on="$RR_ON" online=0
  # Online needs both answers: the service is listening and GitHub lists it as
  # online. Either one unproven keeps "taking jobs: yes" unsaid.
  if [ "$svc" = 0 ] && [ "$on" = 0 ] && [ "$RUNNER_GH_STATUS" = online ]; then
    online=1
  fi
  if [ "$online" = 0 ]; then
    echo "taking jobs: no"
    # One fix line per cause, so a booted VM that is not serving jobs says what
    # stands in the way instead of leaving it to status. The removed case (on=1)
    # already named its recovery above; this adds nothing to it.
    if [ "$svc" != 0 ]; then
      echo "  The runner's service is not running: bin/homefield upgrade --instance ${INSTANCE} (docs/runbook.md, \"Runner updates\")"
    fi
    if [ "$on" -eq 2 ] || [ "$on" -eq 3 ]; then
      echo "  GitHub was not asked, so online is unproven: bin/homefield status --instance ${INSTANCE}"
    fi
    return 1
  fi
  echo "taking jobs: yes"
  return 0
}

stop_single() {
  [ $# -eq 0 ] || die "stop takes no options besides --instance"
  command -v limactl >/dev/null || die "Lima is not installed: brew install lima"
  vm_lookup
  [ -n "$VM_STATUS" ] || die "no VM ${INSTANCE}; nothing to stop"
  if [ "$VM_STATUS" != "Running" ]; then
    echo "VM ${INSTANCE}: already ${VM_STATUS}, nothing to stop"
    return 0
  fi
  # A live job would be cancelled by the stop, so it is refused; a VM that
  # cannot be asked whether one is running fails closed (is_job_running dies,
  # nothing stopped, as upgrade and uninstall do).
  if is_job_running; then
    echo "homefield: a job is running on ${INSTANCE}; stopping now would cancel it" >&2
    echo "  Try again when it is idle (bin/homefield status), or keep the repository on hosted runners: bin/homefield route hosted --repo <owner>/<repo>" >&2
    return 1
  fi
  log "stopping VM ${INSTANCE}: its runner takes no jobs until it starts again"
  limactl stop "$INSTANCE" </dev/null ||
    die "could not stop VM ${INSTANCE} (Lima failed; docs/runbook.md, \"Failure modes\")"
  echo "VM ${INSTANCE}: Stopped"
}

cmd_start() {
  [ $# -eq 0 ] || die "start takes no options besides --instance"
  vm_dispatch start start_single
}

cmd_stop() {
  [ $# -eq 0 ] || die "stop takes no options besides --instance"
  vm_dispatch stop stop_single
}

HOOK_NAMES=" "

# adopt's arguments for the routing pull request setup offers: the one place
# to add a flag to. Set by setup_routing_args. --wait carries on in the same
# run once the pull request is merged (#156). The label and group the runner
# was registered with (cmd_install sets SETUP_LABEL and SETUP_GROUP from
# --label and --group, empty when not given) go along: the pull request must
# route on the label this runner carries, and the adopt that follows must look
# at the group it joined.
SETUP_ROUTING_ARGS=()
SETUP_LABEL=""
SETUP_GROUP=""
SEEN_PRESETS=""
