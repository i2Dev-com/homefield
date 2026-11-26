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
  local url="$1" name="$2" group="$3" scope org rows="" n status rid labels grp row rc tries=0 page seen="" host
  WAIT_RESULT="unchecked"
  WAIT_SEEN=""
  WAIT_LABELS=""
  WAIT_GROUP=""
  WAIT_GROUP_STATE=""
  page="$(runners_page "$url")" || exit 1
  host="$(github_host "$url")"
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
    if ! rows="$(gh api --hostname "$host" --paginate "${scope}/actions/runners?per_page=100" \
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
          row="$(find_runner_group "$org" "$rid" "$host")" || rc=$?
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
      echo "${rest}repositories added to it: $(setup_adopt_hint) --repo <owner>/<repo> adds one."
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
  slug="$(url_path "$slug")"
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
# called: ensure_vm left the VM running, and verify_isolation dies otherwise;
# when the #18 loopback probe could not verify the boundary (e.g. nc lacks
# -k), the summary flags it instead of reporting a plain pass.
setup_vm_lines() {
  if [ -z "$SETUP_VM_WAS" ]; then
    echo "✓ VM ${INSTANCE} created (Running)"
  elif [ "$SETUP_VM_WAS" = Running ]; then
    echo "✓ VM ${INSTANCE} already existed (Running)"
  else
    echo "✓ VM ${INSTANCE} already existed (${SETUP_VM_WAS}); started"
  fi
  if [ "${LOOPBACK_STATE:-}" = "not-verified" ]; then
    echo "! Isolation verified (no host data mounts); host loopback not verified"
  else
    echo "✓ Isolation verified (no host data mounts)"
  fi
}

WARM_STATE=""
WARM_DETAIL=""

# warm_vm: bounded post-registration warm-up check in the guest (docker daemon,
# runner service, cleanup/maintenance timers). Never fails install/setup; sets
# WARM_STATE to warm, incomplete, or unknown (with WARM_DETAIL for incomplete).
warm_vm() {
  local answer=""
  WARM_STATE="unknown"
  WARM_DETAIL=""
  # shellcheck disable=SC2016  # the guest's shell expands these, not this one
  answer="$(guest sudo sh -c '
    missing=""
    if ! timeout 10 docker info >/dev/null 2>&1; then missing="docker"; fi
    svc="$(systemctl list-unit-files "actions.runner.*.service" --no-legend 2>/dev/null | awk "NR==1{print \$1}")"
    if [ -z "$svc" ] || ! systemctl is-active --quiet "$svc"; then
      missing="${missing:+${missing}, }runner"
    fi
    for t in homefield-cleanup.timer homefield-maintenance.timer; do
      if ! systemctl is-enabled --quiet "$t" 2>/dev/null || ! systemctl is-active --quiet "$t" 2>/dev/null; then
        missing="${missing:+${missing}, }timers"
        break
      fi
    done
    if [ -z "$missing" ]; then
      echo "warm"
    else
      echo "incomplete:${missing}"
    fi
  ')" || answer=""
  case "$answer" in
    warm)
      WARM_STATE="warm"
      ;;
    incomplete:*)
      WARM_STATE="incomplete"
      WARM_DETAIL="${answer#incomplete:}"
      ;;
    *)
      WARM_STATE="unknown"
      ;;
  esac
}

setup_warm_line() {
  case "$WARM_STATE" in
    warm) echo "✓ VM warm (docker, runner, timers)" ;;
    incomplete) echo "! Warm-up incomplete (${WARM_DETAIL:-unknown}): run homefield diagnose" ;;
    *) echo "! Warm-up not verified (could not ask the VM): run homefield diagnose" ;;
  esac
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
      elif repos="$(group_repositories "$org" "$GROUP_ID" "$SETUP_GH_HOST")"; then
        if [ -z "$repos" ]; then
          echo "  none yet: $(setup_adopt_hint) --repo <owner>/<repo> adds one"
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
  slug="$(url_path "$slug")"
  echo
  setup_vm_lines
  setup_warm_line
  setup_group_line "$group" "$slug"
  setup_runner_lines "$url" "$3" "$4"
  setup_next_steps "$group" "$slug"
}

# adopt's arguments for the routing pull request setup offers: the one place
# to add a flag to. Set by setup_routing_args. --wait carries on in the same
# run once the pull request is merged (#156). The label and group the runner
# was registered with (cmd_install sets SETUP_LABEL and SETUP_GROUP from
# --label and --group, empty when not given) go along: the pull request must
# route on the label this runner carries, and the adopt that follows must look
# at the group it joined.
SETUP_ROUTING_ARGS=()
# SETUP_GH_HOST: the GitHub host the registration used, for the setup-to-adopt
# delegation and the hand-run hints: adopt takes its host from
# HOMEFIELD_GITHUB_HOST (it has no --url), so a host other than github.com has
# to travel in the environment, the way cmd_route's delegation carries it.
SETUP_GH_HOST=""
SETUP_LABEL=""
SETUP_GROUP=""

setup_routing_args() {
  SETUP_ROUTING_ARGS=(--repo "$1" --setup --wait)
  [ -z "$SETUP_LABEL" ] || SETUP_ROUTING_ARGS+=(--label "$SETUP_LABEL")
  [ -z "$SETUP_GROUP" ] || SETUP_ROUTING_ARGS+=(--group "$SETUP_GROUP")
}

# setup_adopt_hint: the adopt command for the hand-run hints, with the
# registration's host when it is not github.com (a HOMEFIELD_GITHUB_HOST=host
# prefix): the user's shell has no such variable, and without it the command
# would work on github.com.
setup_adopt_hint() {
  if [ -n "$SETUP_GH_HOST" ] && [ "$SETUP_GH_HOST" != github.com ]; then
    printf 'HOMEFIELD_GITHUB_HOST=%s ' "$SETUP_GH_HOST"
  fi
  printf 'homefield adopt'
}

# setup_plain_adopt <owner/repo>: the plain adopt that finishes what the
# routing pull request starts, with the label and group the runner was
# registered with (a plain adopt without --group looks at homefield-ci, and
# would add the repository to the wrong group). Words are shell-quoted: a group
# name may hold a space.
setup_plain_adopt() {
  local c
  c="$(setup_adopt_hint) --repo $(printf '%q' "$1")"
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
  ( set -e
  # adopt takes its host from HOMEFIELD_GITHUB_HOST (no --url): the
  # registration's host must win over the ambient one, the way cmd_route's
  # delegation carries it. The assignment stays in the subshell.
  # shellcheck disable=SC2034  # read by github_host inside cmd_adopt
  HOMEFIELD_GITHUB_HOST="$SETUP_GH_HOST"
  cmd_adopt "${SETUP_ROUTING_ARGS[@]}" )
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
      echo "To try again: $(setup_adopt_hint) ${SETUP_ROUTING_ARGS[*]}"
      ;;
  esac
}

# setup_skip_routing <owner/repo>: a declined offer, with the command for later.
setup_skip_routing() {
  setup_routing_args "$1"
  echo "Route it later with: $(setup_adopt_hint) ${SETUP_ROUTING_ARGS[*]}"
}

# setup_offer_routing <url>: the end of a fresh setup on a terminal. The
# registration names the repository when it is repository-scoped (a personal
# account, or a repository URL), so setup offers to open its routing pull
# request; for an organization it asks which repository first. Nothing is
# created on GitHub without the answer; adopt keeps refusing public
# repositories and needing write access. End of input (Ctrl-D) is a no.
setup_offer_routing() {
  local slug="${1%/}" answer repo
  slug="$(url_path "$slug")"
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

HOOK_NAMES=" "
SEEN_PRESETS=""

# _preset_load <name>: the work behind load_presets. Recursive so that an
# `include` puts the other preset's packages where it is written, and a name
# already loaded (an include cycle) is skipped rather than followed again.
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
      die "could not read the preset hook manifest of VM ${INSTANCE}."
  else
    have=""
  fi
  for f in ${PRESET_HOOKS[@]+"${PRESET_HOOKS[@]}"}; do
    base="${f##*/}"
    limactl copy "$f" "${INSTANCE}:${stage}/${base}" </dev/null ||
      die "could not copy preset hook ${base} into VM ${INSTANCE}."
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
      die "could not install preset hook ${base} in VM ${INSTANCE}."
  done
  for base in $removed; do
    guest_stdin sudo rm -f "${GUEST_HOOKS}/${base}" </dev/null ||
      die "could not remove retired preset hook ${base} in VM ${INSTANCE}."
    log "${INSTANCE}: removed preset hook ${base}; the preset no longer ships it"
  done
  # The manifest is what the next copy prunes against: the names this copy
  # installed, one per line. Through the guest: the stage dir is the guest's
  # and there is no shared mount, so a host-side redirection has no path to
  # write to (found by review on this PR). The parent does not exist on a
  # fresh install of a preset with no hooks — nothing else creates it — so it
  # is made here.
  guest_stdin sudo install -d -m 0755 "${GUEST_MANIFEST%/*}" </dev/null ||
    die "could not create ${GUEST_MANIFEST%/*} in VM ${INSTANCE}."
  # shellcheck disable=SC2086  # unquoted: word splitting puts each name on its own line
  guest_stdin sudo tee "$GUEST_MANIFEST" >/dev/null <<<"$(printf '%s\n' $names)" ||
    die "could not write the preset hook manifest in VM ${INSTANCE}."
  guest_unstage "$stage"
  trap - RETURN
}

# preset_saved_drops <replacement>: names from any shipped preset that are in
# the VM's saved list but not in the replacement --packages value. Plain
# --packages replaces the whole list, so these would stop being reinstalled.
preset_saved_drops() {
  local replacement=" $1 " d name pkg drops="" tops=() saved
  for d in "$PRESETS"/*/; do
    [ -f "$d/packages" ] || continue
    d="${d%/}"
    tops+=("${d##*/}")
  done
  load_presets ${tops[@]+"${tops[@]}"}
  # One read of the saved list for the whole loop: it is a guest call.
  saved=" $(runner_extra_packages) "
  for pkg in $PRESET_PKGS; do
    case "$saved" in *" $pkg "*) ;; *) continue ;; esac
    case "$replacement" in *" $pkg "*) continue ;; esac
    drops="${drops:+$drops }$pkg"
  done
  printf '%s' "$drops"
}

cmd_install() {
  local url="" label="" name="" group="" packages="" packages_set=0 cpus="" memory="" autostart=1 replace=0 ephemeral=0 cmd=install
  local job_cleanup=0 job_cleanup_set=0
  local auto_route=0 auto_route_set=0
  local reset_vm=0 reset_vm_set=0
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
      --ephemeral) ephemeral=1; shift ;;
      --job-cleanup) job_cleanup=1; job_cleanup_set=1; shift ;;
      --no-job-cleanup) job_cleanup=0; job_cleanup_set=1; shift ;;
      --auto-route) auto_route=1; auto_route_set=1; shift ;;
      --no-auto-route) auto_route=0; auto_route_set=1; shift ;;
      --reset-vm) reset_vm=1; reset_vm_set=1; shift ;;
      --no-reset-vm) reset_vm=0; reset_vm_set=1; shift ;;
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
  # --reset-vm only makes sense for an ephemeral runner: the reset is driven
  # by re-register --watch after each job.
  if [ "$reset_vm" = 1 ] && [ "$ephemeral" != 1 ]; then
    die "${cmd}: --reset-vm needs --ephemeral (the reset runs from re-register --watch)"
  fi
  # The sleep/wake watcher's power-event helper is Python: without python3
  # the automatic fallback would cover stop and start but not sleep, so say
  # so before anything is created.
  if [ "$auto_route" = 1 ] && ! command -v python3 >/dev/null 2>&1; then
    die "${cmd}: --auto-route needs python3 (the sleep/wake watcher's power-event helper): install it (xcode-select --install, or brew install python3) and run this again"
  fi
  # The readiness report comes first, before anything is created, and install
  # then gates on its own subset of it — macOS, arm64, Lima — which check_host
  # is: gh, python3 and brew are what the tool needs elsewhere (adopt, report,
  # the one-liner), and install itself can proceed without them.
  # setup stops on a failed check instead (FAIL only: a WARN is not one), and
  # before anything else, so a failed setup has created and touched nothing.
  # On a terminal, setup first offers to log gh in, so that check can pass.
  if [ "$SETUP" = 1 ]; then
    local preflight_rc=0
    # The gh check and the login offer ask the registration host's login, not
    # github.com's (PF_HOST is read by preflight_collect).
    # shellcheck disable=SC2034  # read by cmd-preflight.sh's preflight_collect
    PF_HOST="$(github_host "$url")"
    offer_gh_login "$url"
    cmd_preflight --no-prefetch || preflight_rc=$?
    [ "$preflight_rc" -eq 0 ] ||
      die "setup stopped: fix the failed checks above and run it again; nothing was created"
  else
    # shellcheck disable=SC2034  # read by cmd-preflight.sh's preflight_collect
    PF_HOST="$(github_host "$url")"
    cmd_preflight --no-prefetch || true
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
    local existing_vms=0 existing_name=""
    while IFS= read -r existing_name; do
      [ -n "$existing_name" ] || continue
      [ "$existing_name" != "$INSTANCE" ] || continue
      existing_vms=$((existing_vms + 1))
    done < <(vm_instances 2>/dev/null || true)
    if [ "$existing_vms" -ge 1 ]; then
      log "warning: ${existing_vms} other HomeField VM(s) already exist on this Mac; this VM will request ${cpus} vCPU(s) and ${memory} memory. Size the fleet to avoid CPU/RAM contention (see docs/runbook.md, \"Scaling on one Mac\")."
    fi
    prepare_registration
    prepared=1
  elif [ -n "$url" ]; then
    validate_scope "$url"
  fi
  ensure_vm "$cpus" "$memory"
  verify_isolation

  if is_registered; then
    if [ "$ephemeral" = 1 ]; then
      local eph_rc=0
      guest_has_file /opt/actions-runner/.ephemeral || eph_rc=$?
      [ "$eph_rc" -lt 2 ] || die "could not ask VM ${INSTANCE} whether its registration is ephemeral"
      [ "$eph_rc" = 0 ] || die "${INSTANCE} is already registered as a persistent runner; uninstall it first before switching to --ephemeral"
    fi
    log "${INSTANCE} is already registered; upgrading instead (registration settings are kept)"
    if [ "$reset_vm_set" = 1 ]; then
      # The base only comes from install (the VM is prepared unregistered and
      # cloned before registration), so an existing VM can turn the reset on
      # only when its base is already there; turning it off is always possible.
      if [ "$reset_vm" = 1 ]; then
        check_reset_base
        local bs=""
        bs="$(vm_status_of "$RESET_BASE")" ||
          die "${cmd}: could not ask Lima about the base VM ${RESET_BASE}"
        if [ -z "$bs" ]; then
          die "${cmd}: no base VM ${RESET_BASE}; --reset-vm needs a base created by install --ephemeral --reset-vm (uninstall this VM and install again with --reset-vm)"
        fi
        is_reset_base "$RESET_BASE" ||
          die "${cmd}: VM ${RESET_BASE} exists but is not a HomeField reset base VM (an ordinary runner may be named that); --reset-vm needs the base install --ephemeral --reset-vm creates (uninstall this VM and install again with --reset-vm)"
        state_set reset_vm 1
        log "vm reset on: each re-register clones a fresh VM from ${RESET_BASE}"
      else
        state_set reset_vm 0
        state_set reset_error ""
      fi
    fi
    local args=()
    [ "$packages_set" = 1 ] && args+=(--packages "$packages")
    local p
    for p in ${presets[@]+"${presets[@]}"}; do args+=(--preset "$p"); done
    [ "$job_cleanup_set" = 1 ] && args+=("$([ "$job_cleanup" = 1 ] && echo --job-cleanup || echo --no-job-cleanup)")
    [ "$auto_route_set" = 1 ] && args+=("$([ "$auto_route" = 1 ] && echo --auto-route || echo --no-auto-route)")
    upgrade_registered "${args[@]+"${args[@]}"}"
    if [ "$ephemeral" = 1 ]; then
      local r_url="" r_name="" was_eph=""
      { IFS= read -r r_url || true; IFS= read -r r_name || true; } < <(runner_setting gitHubUrl agentName 2>/dev/null || true)
      was_eph="$(state_get ephemeral)"
      state_set ephemeral 1
      state_set ephemeral_url "${r_url:-$url}"
      state_set ephemeral_name "${r_name:-$name}"
      if [ "$was_eph" != "1" ]; then
        state_set ephemeral_group "$group"
        state_set ephemeral_label "$label"
      fi
      state_set ephemeral_error ""
    fi
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

  # A registration token reaches the guest on stdin and sits in the
  # provisioning process's environment for the whole provision run (minutes:
  # the package upgrade alone). A VM that has run jobs may hold a root
  # process the job left behind, and such a process can read the token from
  # /proc/<pid>/environ — so a token only goes into a VM that has not run
  # one. The boundary is host-side: the state file records whether a runner
  # has ever been registered on this VM, and a registered runner can run
  # jobs the host never sees, so "never registered" is the only freshness
  # the host can vouch for. The guest's _work probe is the second line: a
  # VM that has never been registered cannot have run a job (jobs need a
  # registered runner), so there its answer is sound, and it catches a lost
  # state file — but a VM that has run jobs cannot prove anything about
  # itself (the directory is under the job's root's control), which is why
  # the state, not the probe, is the boundary. The base a reset clones from
  # was cloned before any job, so `reset` then `install` re-registers on a
  # fresh VM.
  if [ -n "$VM_STATUS" ]; then
    if [ "$(state_get ever_registered)" = "1" ]; then
      die "${cmd}: ${INSTANCE} has been registered before, so it may have run jobs, and a registration token must not go into it (a job's leftover root process could read it from the provisioning process); re-register on a fresh VM: bin/homefield reset --instance ${INSTANCE}, then install again"
    fi
    local ran_rc=0
    ran_jobs || ran_rc=$?
    case "$ran_rc" in
      0)
        die "${cmd}: ${INSTANCE} has run jobs, so a registration token must not go into it (a job's leftover root process could read it from the provisioning process); re-register on a fresh VM: bin/homefield reset --instance ${INSTANCE}, then install again"
        ;;
      2)
        die "${cmd}: could not ask whether ${INSTANCE} has run jobs; a registration token must not go into a VM this command cannot check (is it running?)"
        ;;
    esac
  fi

  if [ "$reset_vm" = 1 ]; then
    # The base VM: this install is provisioned unregistered first (provision.sh
    # RUNNER_PREPARE_ONLY), cloned to <instance>-base while stopped, and only
    # then registered — the registration below runs on the working VM, and the
    # base stays behind as the stopped, unregistered source every later reset
    # clones from. A clone of a registered VM would inherit its registration,
    # and the clone's listener would never reach "Listening for Jobs".
    check_reset_base
    local bstatus=""
    bstatus="$(vm_status_of "$RESET_BASE")" ||
      die "${cmd}: could not ask Lima about the base VM ${RESET_BASE}"
    if [ -n "$bstatus" ]; then
      if is_reset_base "$RESET_BASE"; then
        log "deleting the previous base VM ${RESET_BASE} (a fresh one is cloned from this install)"
        limactl delete -f "$RESET_BASE" </dev/null ||
          die "${cmd}: could not delete the previous base VM ${RESET_BASE}"
      else
        die "${cmd}: a VM named ${RESET_BASE} already exists and is not a HomeField reset base VM (an ordinary runner may be named that); remove or rename it first (limactl delete -f ${RESET_BASE})"
      fi
    fi
    local penv=()
    if [ ${#presets[@]} -gt 0 ]; then
      penv+=(RUNNER_EXTRA_PACKAGES="$merged")
    elif [ "$packages_set" = 1 ]; then
      penv+=(RUNNER_EXTRA_PACKAGES="$packages")
    fi
    log "provisioning ${INSTANCE} (prepare-only: the base VM ${RESET_BASE} is cloned from this state)"
    run_provision "" RUNNER_PREPARE_ONLY=1 ${penv[@]+"${penv[@]}"}
    log "stopping ${INSTANCE} to clone the base VM ${RESET_BASE} from it"
    limactl stop "$INSTANCE" </dev/null ||
      die "${cmd}: could not stop VM ${INSTANCE} to clone the base VM ${RESET_BASE}"
    limactl clone --start=false "$INSTANCE" "$RESET_BASE" </dev/null ||
      die "${cmd}: could not clone the base VM ${RESET_BASE} from ${INSTANCE}"
    # Mark the base as a reset base, so a later install replaces only a VM it
    # created for this purpose and never an ordinary runner that happens to
    # be named <instance>-base. A marking failure leaves the base unmarked:
    # the next install refuses it instead of deleting it.
    printf '%s\n' "$HF_RESET_BASE_MARKER" >>"${LIMA_HOME:-$HOME/.lima}/${RESET_BASE}/lima.yaml" ||
      die "${cmd}: could not mark the base VM ${RESET_BASE} as a reset base"
    log "base VM ${RESET_BASE} is ready (stopped, unregistered); starting ${INSTANCE} to register it"
    ensure_vm "" ""
    verify_isolation
  fi

  local token
  token="$(get_token registration "$url")"
  remove_taken_name "$url" "$name"
  if [ "$ephemeral" = 1 ]; then
    env+=(RUNNER_EPHEMERAL=1)
  fi
  if [ "$job_cleanup_set" = 1 ]; then
    env+=(RUNNER_JOB_CLEANUP="$job_cleanup")
  fi
  log "provisioning ${INSTANCE} and registering at ${url}"
  # Written before the token enters the guest, not after provisioning
  # returns: provisioning registers the runner and starts it before its
  # later (fallible) steps finish, and a failure past that point would exit
  # here without the record — a VM running jobs the host does not know
  # about, exactly what this key exists to prevent. A failed install now
  # needs reset (deletes the VM) + install, which the guard's message says.
  # The check is explicit for the same reason as re_register_single's.
  state_set ever_registered 1 ||
    die "${cmd}: could not record the registration for ${INSTANCE}; no token goes into the VM (fix the state directory: $(state_file))"
  run_provision "RUNNER_TOKEN=${token}"$'\n' "${env[@]}"
  token=""
  state_set job_cleanup "$job_cleanup"
  state_set reset_vm "$reset_vm"
  state_set reset_error ""
  # The automatic hosted fallback follows the VM's stop/start (host-side
  # only): 1 makes plain `stop` route the routed repositories to hosted and
  # plain `start` route them back.
  state_set auto_route "$auto_route"
  if [ "$auto_route" = 1 ]; then
    # Cover the repositories that were already routed local before the
    # fallback existed; a failure only means they are not covered yet, and
    # seed_routing_records says exactly what to do about it.
    seed_routing_records "$url" "$name" "${label:-homefield-ci}" "${GROUP_ID:-}" || true
    # The sleep/wake half (#290): the LaunchAgent that flips on sleep and
    # restores on wake. A failure leaves the fallback covering stop and
    # start only; the warning names the retry.
    route_watcher_install ||
      echo "homefield: the route watcher could not be installed; the automatic fallback covers stop and start but not sleep and wake (retry: bin/homefield upgrade --auto-route)" >&2
  elif [ "$auto_route_set" = 1 ]; then
    # An explicit --no-auto-route takes the agent back out when no other VM
    # on this Mac wants it.
    route_watcher_remove_if_unneeded || true
  fi
  if [ "$ephemeral" = 1 ]; then
    state_set ephemeral 1
    state_set ephemeral_url "$url"
    state_set ephemeral_name "$name"
    state_set ephemeral_group "$group"
    state_set ephemeral_label "$label"
    state_set ephemeral_error ""
  elif [ "$(state_get ephemeral)" = "1" ]; then
    state_set ephemeral 0
    state_set ephemeral_url ""
    state_set ephemeral_name ""
    state_set ephemeral_group ""
    state_set ephemeral_label ""
    state_set ephemeral_error ""
    state_set reset_vm 0
    state_set reset_error ""
  fi
  [ "$autostart" = 1 ] && enable_autostart
  # The name and id the runner registered under, read back from its config.
  local registered_name="" registered_id=""
  { IFS= read -r registered_name || true; IFS= read -r registered_id || true; } < <(runner_setting agentName agentId)
  wait_online "$url" "$registered_name" "${group:-homefield-ci}"
  warm_vm
  # The host the routing offer and its hand-run hints work on: the
  # registration's (setup_summary, setup_offer_routing, setup_route_repo read
  # SETUP_GH_HOST).
  SETUP_GH_HOST="$(github_host "$url")"
  if [ "$SETUP" = 1 ]; then
    setup_summary "${group:-homefield-ci}" "$url" "$registered_name" "$registered_id"
    SETUP_LABEL="$label" SETUP_GROUP="$group"
    setup_offer_routing "$url"
  else
    if [ "$WARM_STATE" = "incomplete" ]; then
      log "warning: VM warm-up incomplete (${WARM_DETAIL}); run bin/homefield diagnose"
    fi
    registered_next_steps "${group:-homefield-ci}" "$url"
  fi
}

# upgrade_single: one VM's upgrade; vm_dispatch runs it for every VM by default.
upgrade_single() {
  parse_upgrade_args "$@"
  local packages="$UP_PACKAGES" packages_set="$UP_PACKAGES_SET" force="$UP_FORCE"
  [ ${#UP_PRESETS[@]} -eq 0 ] || load_presets ${UP_PRESETS[@]+"${UP_PRESETS[@]}"}
  check_host
  vm_lookup
  [ -n "$VM_STATUS" ] || die "no VM ${INSTANCE}; run bin/homefield install"
  ensure_vm "" ""
  verify_isolation
  is_registered || die "${INSTANCE} is not registered; run bin/homefield install --url ..."
  # The base only comes from install (the VM is prepared unregistered and
  # cloned before registration), so --reset-vm can only be turned on here when
  # the base is already there; turning it off is always possible. Checked
  # before anything is stopped: a doomed request must not take the runner
  # down.
  if [ "$UP_RESET_VM_SET" = 1 ] && [ "$UP_RESET_VM" = 1 ]; then
    check_reset_base
    local bs=""
    bs="$(vm_status_of "$RESET_BASE")" ||
      die "upgrade: could not ask Lima about the base VM ${RESET_BASE}"
    if [ -z "$bs" ]; then
      die "upgrade: no base VM ${RESET_BASE}; --reset-vm needs a base created by install --ephemeral --reset-vm (uninstall this VM and install again with --reset-vm)"
    fi
    is_reset_base "$RESET_BASE" ||
      die "upgrade: VM ${RESET_BASE} exists but is not a HomeField reset base VM (an ordinary runner may be named that); --reset-vm needs the base install --ephemeral --reset-vm creates (uninstall this VM and install again with --reset-vm)"
  fi
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
  # Offline straight after the idle check, before the preset work below: that
  # is a stage directory, one copy and one install per hook, and the saved
  # list read, so a job picked up in the gap would be cancelled by the stop.
  # stop_runner arms the restart-on-failure trap, so a failure from here on
  # gives the service back (#238).
  stop_runner
  # Presets add to the saved list (and to any --packages), so nothing a VM had
  # stops being reinstalled. Plain --packages still replaces the whole list;
  # say which preset names that takes out of it.
  local merged=""
  if [ ${#UP_PRESETS[@]} -gt 0 ]; then
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
  local env=()
  if [ ${#UP_PRESETS[@]} -gt 0 ]; then
    env+=(RUNNER_EXTRA_PACKAGES="$merged")
  elif [ "$packages_set" = 1 ]; then
    env+=(RUNNER_EXTRA_PACKAGES="$packages")
  fi
  if [ "$UP_JOB_CLEANUP_SET" = 1 ]; then
    env+=(RUNNER_JOB_CLEANUP="$UP_JOB_CLEANUP")
  fi
  log "upgrading ${INSTANCE}"
  # provision.sh starts the service again at the end, and waits until it is
  # listening for jobs.
  run_provision "" "${env[@]+"${env[@]}"}"
  # The VM is registered (the upgrade would not be here otherwise): record
  # it, so a later token-carrying install refuses this VM even when this
  # state file predates the record.
  state_set ever_registered 1
  if [ "$UP_JOB_CLEANUP_SET" = 1 ]; then
    state_set job_cleanup "$UP_JOB_CLEANUP"
  fi
  if [ "$UP_RESET_VM_SET" = 1 ]; then
    state_set reset_vm "$UP_RESET_VM"
    state_set reset_error ""
  fi
  if [ "$UP_AUTO_ROUTE_SET" = 1 ]; then
    state_set auto_route "$UP_AUTO_ROUTE"
    if [ "$UP_AUTO_ROUTE" = 1 ]; then
      seed_routing_records "$url" "$name" || true
      # The sleep/wake half (#290); see install. A failure leaves the
      # fallback covering stop and start only.
      if route_watcher_install; then
        # The webhook receiver's agent bakes the same HOMEFIELD_SCALE_*
        # policy (webhook setup copied it from the shell or from the
        # route watcher's plist, which this install just rewrote): an
        # upgrade --auto-route that refreshes the route watcher must
        # refresh this copy too, or the receiver's ticks keep scaling
        # with the settings the last webhook setup baked. Nothing to
        # refresh when the receiver was never set up.
        if [ -f "$(webhook_plist_path)" ]; then
          local wh_port
          wh_port="$(webhook_config_get port || true)"
          # A custom state dir the upgrading shell does not carry leaves
          # this config read empty (it reads the shell's resolution, not
          # the one the refresh preserves); the installed plist bakes the
          # port the receiver has actually been serving, so that is the
          # fallback.
          [ -n "$wh_port" ] ||
            wh_port="$(plist_env "$(webhook_plist_path)" HOMEFIELD_WEBHOOK_PORT)"
          webhook_agent_install "${wh_port:-8787}" refresh ||
            echo "homefield: the webhook receiver's agent could not be refreshed; its scaler policy is stale (re-run 'homefield webhook setup --hostname <fqdn>')" >&2
        fi
      else
        echo "homefield: the route watcher could not be installed; the automatic fallback covers stop and start but not sleep and wake (retry: bin/homefield upgrade --auto-route)" >&2
      fi
    else
      route_watcher_remove_if_unneeded || true
    fi
  fi
  runner_back
}

# parse_upgrade_args: the --packages/--preset/--force options, into
# UP_PACKAGES/UP_PACKAGES_SET/UP_FORCE/UP_PRESETS. cmd_upgrade runs it once
# for the early refusal (#182) and hands the same arguments to vm_dispatch;
# upgrade_single runs it again for the values — one parser, so the two can
# never disagree about what the options are.
parse_upgrade_args() {
  UP_PACKAGES="" UP_PACKAGES_SET=0 UP_FORCE=0
  UP_JOB_CLEANUP="" UP_JOB_CLEANUP_SET=0
  UP_AUTO_ROUTE="" UP_AUTO_ROUTE_SET=0
  UP_RESET_VM="" UP_RESET_VM_SET=0
  UP_PRESETS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --packages)
        [ $# -ge 2 ] || die "--packages needs a value (may be empty)"
        UP_PACKAGES="$2" UP_PACKAGES_SET=1
        shift 2
        ;;
      --preset)
        UP_PRESETS+=("${2:?--preset needs a value}")
        shift 2
        ;;
      --force) UP_FORCE=1; shift ;;
      --job-cleanup) UP_JOB_CLEANUP=1 UP_JOB_CLEANUP_SET=1; shift ;;
      --no-job-cleanup) UP_JOB_CLEANUP=0 UP_JOB_CLEANUP_SET=1; shift ;;
      --auto-route) UP_AUTO_ROUTE=1 UP_AUTO_ROUTE_SET=1; shift ;;
      --no-auto-route) UP_AUTO_ROUTE=0 UP_AUTO_ROUTE_SET=1; shift ;;
      --reset-vm) UP_RESET_VM=1 UP_RESET_VM_SET=1; shift ;;
      --no-reset-vm) UP_RESET_VM=0 UP_RESET_VM_SET=1; shift ;;
      *) die "upgrade: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
}

cmd_upgrade() {
  # The options are validated once here: an unknown one, or a malformed
  # preset, fails before any VM is stopped and does not repeat per instance
  # (#182). The values are parsed again per instance, by the same parser.
  parse_upgrade_args "$@"
  # The watcher's helper is Python; without it --auto-route would cover stop
  # and start but not sleep, so refuse before any VM is stopped.
  if [ "${UP_AUTO_ROUTE:-}" = 1 ] && ! command -v python3 >/dev/null 2>&1; then
    die "upgrade: --auto-route needs python3 (the sleep/wake watcher's power-event helper): install it (xcode-select --install, or brew install python3) and run this again"
  fi
  local opts=("$@")
  [ ${#UP_PRESETS[@]} -eq 0 ] || load_presets "${UP_PRESETS[@]+"${UP_PRESETS[@]}"}"
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
# RR_* : one runner's facts, set by runner_report_collect and rendered by
# runner_report_human. RR_ASKFAIL is 1 when the VM could not be asked;
# RR_SVC is 1 when the service is not running; RR_ON is runner_on_github's
# code (3 and * are "not checked", which only start counts as unknown, via
# its own read of RR_ON).
RR_NAME="" RR_URL="" RR_ID="" RR_REMOVED=0 RR_NOTREG=0 RR_SVC=0 RR_ON=2 RR_ASKFAIL=0
runner_report_collect() {
  local reg=0 on=0
  RR_REMOVED=0; RR_NOTREG=0; RR_SVC=0; RR_ON=2; RR_ASKFAIL=0
  registered || reg=$?
  if [ "$reg" -ge 2 ]; then
    RR_ASKFAIL=1
    return 0
  fi
  if [ "$reg" = 1 ]; then
    RR_NOTREG=1
    return 0
  fi
  # Fewer than three lines read must reach the check below, not stop here.
  load_runner_settings
  # RS_NAME/RS_URL/RS_ID are lib/vm.sh's load_runner_settings' output.
  # shellcheck disable=SC2153
  RR_NAME="$RS_NAME" RR_URL="$RS_URL" RR_ID="$RS_ID"
  runner_on_github "$RR_URL" "$RR_ID" || on=$?
  RR_ON="$on"
  case "$on" in
    1) RR_REMOVED=1 ;;
    3)
      # start counts an unproven GitHub answer as unknown; status's report
      # stands on its own and exits 0 (its job/npm rows carry the unknowns).
      ;;
    *)
      ;;
  esac
  if runner_service_state; then
    RR_SVC=0
  else
    RR_SVC=1
  fi
  return 0
}

runner_report() {
  runner_report_collect "$@"
  runner_report_human "${1:-}"
}

runner_report_human() {
  local verbose="$1"
  if [ "$RR_ASKFAIL" = 1 ]; then
    echo "runner: unknown (could not ask the VM)"
    return 0
  fi
  if [ "$RR_NOTREG" = 1 ]; then
    echo "runner: not registered"
    return 0
  fi
  if [ -n "$RR_NAME" ] && [ -n "$RR_URL" ]; then
    echo "runner: ${RR_NAME}, registered at ${RR_URL}"
  else
    # The registration exists (.runner is there) but its details could not be
    # read just now; the rest of the report still stands on its own, and the
    # GitHub ask needs an id.
    echo "runner: registered, but its details could not be read"
  fi
  case "$RR_ON" in
    0)
      if [ "$verbose" = verbose ]; then
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
      ;;
    3)
      echo "github: not checked (timed out after ${GH_TIMEOUT}s; the network may be down)"
      ;;
    *)
      if [ -n "$RR_ID" ]; then
        echo "github: not checked (needs gh with admin access to ${RR_URL})"
      else
        echo "github: not checked (no runner id in the VM's settings)"
      fi
      ;;
  esac
  if [ "$RR_SVC" = 0 ]; then
    echo "service: running"
  else
    echo "service: NOT running (${SERVICE_UNIT:-no service installed})"
  fi
  return 0
}

# ST_* : one VM's status facts, collected by st_collect and rendered by
# st_render_human / st_render_json, so the human and the --json form say the
# same thing. ST_REG is yes/no/unknown; ST_GH is listed/not_listed/timeout/
# not_checked; ST_SVC running/not_running; ST_JOB and ST_NPM carry unknown.
ST_CREATED="" ST_STATUS="" ST_REG="unknown" ST_GH="not_checked" ST_GH_STATUS=""
ST_SVC="unknown" ST_UNIT="" ST_JOB="unknown" ST_VER="" ST_NPM="unknown"
ST_PKGS_STATE="unknown" ST_PKGS="" ST_ASKFAIL=0 ST_REMOVED=0
ST_LB_STATE="unknown" ST_LB_DETAIL=""

st_collect() {
  ST_CREATED=""; ST_STATUS=""; ST_REG="unknown" ST_GH="not_checked" ST_GH_STATUS=""
  ST_SVC="unknown" ST_UNIT="" ST_JOB="unknown" ST_VER="" ST_NPM="unknown"
  ST_PKGS_STATE="unknown" ST_PKGS=""; ST_ASKFAIL=0; ST_REMOVED=0
  ST_LB_STATE="unknown"; ST_LB_DETAIL=""
  local job=0 npm=0
  # Always 0: the ask-fail case is ST_STATUS empty (a `return 1` here would
  # end status_single under set -e, before it renders anything).
  if ! ST_STATUS="$(vm_status)"; then
    ST_STATUS=""
    return 0
  fi
  if [ -z "$ST_STATUS" ]; then
    ST_CREATED="no"
    return 0
  fi
  ST_CREATED="yes"
  [ "$ST_STATUS" = "Running" ] || return 0
  loopback_recorded_state
  ST_LB_STATE="$LB_RECORDED_STATE"
  ST_LB_DETAIL="$LB_RECORDED_DETAIL"
  runner_report_collect
  ST_ASKFAIL="$RR_ASKFAIL"; ST_REMOVED="$RR_REMOVED"
  if [ "$RR_ASKFAIL" = 0 ] && [ "$RR_NOTREG" = 0 ]; then
    ST_REG="yes"
    ST_NAME="$RR_NAME" ST_URL="$RR_URL" ST_ID="$RR_ID"
    case "$RR_ON" in
      0) ST_GH="listed"; ST_GH_STATUS="$RUNNER_GH_STATUS" ;;
      1) ST_GH="not_listed" ;;
      3) ST_GH="timeout" ;;
      *) ST_GH="not_checked" ;;
    esac
    if [ "$RR_SVC" = 0 ]; then ST_SVC="running"; else ST_SVC="not_running"; fi
    ST_UNIT="${SERVICE_UNIT:-}"
    ST_VER="$(runner_version)"
    # The probe's failure is absorbed: the original printed its (empty)
    # output inside echo, so a guest that cannot be asked never aborted the
    # report, and the JSON form renders the same facts it does.
    ST_PKGS="$(runner_extra_packages)" || ST_PKGS=""
    ST_PKGS_STATE="listed"
    job_running || job=$?
    case "$job" in
      0) ST_JOB="running" ;;
      1) ST_JOB="idle" ;;
      *) ST_JOB="unknown" ;;
    esac
    npm_state || npm=$?
    case "$npm" in
      0) ST_NPM="ok" ;;
      1) ST_NPM="broken" ;;
      *) ST_NPM="unknown" ;;
    esac
  elif [ "$RR_ASKFAIL" = 0 ]; then
    ST_REG="no"
  fi
  return 0
}

st_render_ephemeral() {
  [ "$(state_get ephemeral)" = "1" ] || return 0
  echo "mode: ephemeral (one job per registration)"
  if [ "$(state_get reset_vm)" = "1" ]; then
    echo "vm reset: on (each re-register clones a fresh VM from ${INSTANCE}-base)"
  fi
  local reset_err=""
  reset_err="$(state_get reset_error)"
  if [ -n "$reset_err" ]; then
    echo "vm reset: ERROR (${reset_err}); the runner still re-registers; run homefield re-register --instance ${INSTANCE} to retry the reset"
  fi
  local eph_err=""
  eph_err="$(state_get ephemeral_error)"
  if [ -n "$eph_err" ]; then
    echo "ephemeral: ERROR (${eph_err}); run homefield re-register --instance ${INSTANCE}"
  elif [ "$ST_SVC" != "running" ] || [ "$ST_REG" = "no" ]; then
    echo "ephemeral: awaiting re-registration (homefield re-register --instance ${INSTANCE})"
  fi
}

st_render_human() {
  if [ -z "$ST_CREATED" ] && [ -z "$ST_STATUS" ]; then
    echo "VM ${INSTANCE}: unknown (could not ask Lima)"
    return 1
  fi
  if [ "$ST_CREATED" = "no" ]; then
    echo "VM ${INSTANCE}: not created"
    return 0
  fi
  echo "VM ${INSTANCE}: ${ST_STATUS}"
  [ "$ST_STATUS" = "Running" ] || return 0
  case "$ST_LB_STATE" in
    verified) echo "loopback: verified" ;;
    not-verified) echo "loopback: not verified" ;;
    skipped) echo "loopback: not verified (${ST_LB_DETAIL})" ;;
    stale) echo "loopback: stale (${ST_LB_DETAIL})" ;;
    open) echo "loopback: OPEN (${ST_LB_DETAIL})" ;;
    unknown) ;;
    *) echo "loopback: ${ST_LB_STATE}${ST_LB_DETAIL:+ (${ST_LB_DETAIL})}" ;;
  esac
  if [ "$ST_ASKFAIL" = 1 ]; then
    echo "runner: unknown (could not ask the VM)"
    return 1
  fi
  if [ "$ST_REG" = "no" ]; then
    echo "runner: not registered"
    st_render_ephemeral
    return 0
  fi
  if [ -n "$ST_NAME" ] && [ -n "$ST_URL" ]; then
    echo "runner: ${ST_NAME}, registered at ${ST_URL}"
  else
    echo "runner: registered, but its details could not be read"
  fi
  case "$ST_GH" in
    listed) echo "github: listed" ;;
    not_listed)
      echo "github: NOT listed: GitHub removes runners that have not connected for more than 14 days."
      echo "  Register it again: $(removed_recovery "$ST_URL" "$ST_NAME")"
      ;;
    timeout) echo "github: not checked (timed out after ${GH_TIMEOUT}s; the network may be down)" ;;
    not_checked)
      if [ -n "$ST_ID" ]; then
        echo "github: not checked (needs gh with admin access to ${ST_URL})"
      else
        echo "github: not checked (no runner id in the VM's settings)"
      fi
      ;;
  esac
  if [ "$ST_SVC" = "running" ]; then
    echo "service: running"
  else
    echo "service: NOT running (${ST_UNIT:-no service installed})"
  fi
  st_render_ephemeral
  # The watcher is per-Mac, but it acts on this VM's routing only when the
  # automatic fallback is on, so the line belongs in this VM's report then:
  # whether the agent is installed and what the last run did.
  if [ "$(state_get auto_route)" = "1" ]; then
    route_watcher_status_line
  fi
  case "$ST_JOB" in
    running) echo "job: running" ;;
    idle) echo "job: idle" ;;
    *) echo "job: unknown (could not ask the VM)" ;;
  esac
  echo "runner version: $ST_VER"
  case "$ST_NPM" in
    ok) echo "npm: ok" ;;
    broken)
      echo "npm: BROKEN (a runner self-update can flatten the externals symlinks; docs/runbook.md, \"Runner updates\")"
      ;;
    *) echo "npm: unknown (could not ask the VM)" ;;
  esac
  echo "extra packages: $ST_PKGS"
  [ -n "$ST_URL" ] && echo "labels: see $(runners_page "$ST_URL") (not stored in the VM)"
  return 0
}

st_render_json() {
  printf '{\n'
  printf '  "instance": %s,\n' "$(json_str "$INSTANCE")"
  local healthy=true
  if [ -z "$ST_CREATED" ] && [ -z "$ST_STATUS" ]; then
    healthy=false
  elif [ "$ST_CREATED" = "no" ]; then
    : # a VM that does not exist is a clean answer, as the human form's exit 0
  elif [ "$ST_ASKFAIL" = 1 ]; then
    healthy=false
  elif [ "$ST_REG" = yes ] && { [ "$ST_REMOVED" = 1 ] || [ "$ST_JOB" = unknown ] || [ "$ST_NPM" != ok ]; }; then
    healthy=false
  fi
  printf '  "healthy": %s,\n' "$healthy"
  printf '  "vm": {"created": %s, "status": %s},\n' \
    "$(json_bool "$ST_CREATED")" "$(json_nstr "$ST_STATUS")"
  local reg_json=null
  if [ "$ST_REG" = yes ]; then reg_json=true; elif [ "$ST_REG" = no ]; then reg_json=false; fi
  printf '  "registered": %s,\n' "$reg_json"
  if [ "$ST_REG" = yes ]; then
    printf '  "runner": {"name": %s, "url": %s, "id": %s},\n' \
      "$(json_nstr "$ST_NAME")" "$(json_nstr "$ST_URL")" "$(json_nstr "$ST_ID")"
  else
    printf '  "runner": null,\n'
  fi
  printf '  "on_github": {"state": %s, "status": %s},\n' \
    "$(json_str "$ST_GH")" "$(json_nstr "$ST_GH_STATUS")"
  printf '  "service": {"state": %s, "unit": %s},\n' \
    "$(json_str "$ST_SVC")" "$(json_nstr "$ST_UNIT")"
  printf '  "job": {"state": %s},\n' "$(json_str "$ST_JOB")"
  printf '  "version": %s,\n' "$(json_nstr "$ST_VER")"
  printf '  "npm": %s,\n' "$(json_str "$ST_NPM")"
  if [ "$ST_PKGS_STATE" = listed ]; then
    printf '  "extra_packages": %s,\n' "$(json_words "$ST_PKGS")"
  else
    printf '  "extra_packages": null,\n'
  fi
  if [ "$(state_get auto_route)" = "1" ]; then
    printf '  "route_watcher": %s,\n' "$(route_watcher_json)"
  fi
  printf '  "loopback": {"state": %s, "detail": %s}\n' \
    "$(json_str "$ST_LB_STATE")" "$(json_nstr "$ST_LB_DETAIL")"
  printf '}\n'
}

# status_single: one VM's report; vm_dispatch runs it for every VM by default.
status_single() {
  local json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      *) die "status: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  command -v limactl >/dev/null || die "Lima is not installed"
  st_collect
  local rc=0
  if [ "$json" = 1 ]; then
    st_render_json || rc=$?
  else
    st_render_human || rc=$?
  fi
  # The exit status is the human form's, and the JSON form's healthy carries
  # the same facts: 1 when Lima could not be asked, the VM could not be asked,
  # a job or npm state is unknown, the runner was removed from GitHub; 0 when
  # the VM does not exist (a clean answer).
  if [ -z "$ST_CREATED" ] && [ -z "$ST_STATUS" ]; then
    return 1
  fi
  [ "$ST_CREATED" = "no" ] && return 0
  [ "$ST_STATUS" = "Running" ] || return 0
  [ "$ST_ASKFAIL" = 0 ] || return 1
  [ "$ST_REG" = "yes" ] || return 0
  [ "$ST_REMOVED" = 0 ] || return 1
  [ "$ST_JOB" != unknown ] || return 1
  [ "$ST_NPM" = ok ] || return 1
  return 0
}

# status_many <names> <json>: every VM on this Mac, each its own report as its
# own process (so one cannot affect the next), the human blocks headed by the
# instance name and the JSON form wrapping the single-VM objects: instances,
# healthy, vms -- the same shape diagnose --json wraps its reports in.
status_many() {
  local names="$1" json="$2" name rc=0 first=1 out child_rc=0
  if [ "$json" = 1 ]; then
    printf '{\n'
    printf '  "instances": ['
    first=1
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      [ "$first" = 1 ] || printf ', '
      first=0
      json_str "$name"
    done <<<"$names"
    printf '],\n'
    # healthy needs every run's answer, so collect their objects first.
    local vms="" sep=""
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      child_rc=0
      out="$(instance_command "$name" status --json)" || child_rc=$?
      [ "$child_rc" = 0 ] || rc=1
      vms="${vms}${sep}${out}"
      sep=",
"
    done <<<"$names"
    printf '  "healthy": %s,\n' "$([ "$rc" = 0 ] && echo true || echo false)"
    printf '  "vms": [\n%s\n  ]\n}\n' "$vms"
    return "$rc"
  fi
  first=1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$first" = 1 ] || echo ""
    first=0
    HOMEFIELD_ONE_OF_MANY=1 instance_command "$name" status || rc=1
  done <<<"$names"
  return "$rc"
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
  local json=0 opts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; opts+=(--json); shift ;;
      *) die "status: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  local list="" name n=0
  if [ "$EXPLICIT_INSTANCE" = 0 ] && list="$(vm_instances)"; then
    while IFS= read -r name; do
      [ -z "$name" ] || n=$((n + 1))
    done <<<"$list"
    case "$n" in
      0)
        # Nothing found: INSTANCE's own report ("not created") says what to
        # do, as vm_dispatch's single-VM path did.
        status_single "${opts[@]+"${opts[@]}"}"
        return
        ;;
      1)
        # Exactly one: report THAT VM, the name vm_dispatch assigned (the
        # default name with one VM under another would report "not created").
        while IFS= read -r name; do [ -z "$name" ] || break; done <<<"$list"
        INSTANCE="$name"
        status_single "${opts[@]+"${opts[@]}"}"
        return
        ;;
    esac
    status_many "$list" "$json"
    return
  fi
  # Explicit --instance, or a Lima that cannot be asked: the single report.
  status_single "${opts[@]+"${opts[@]}"}"
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
  local route=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --route-local) route=1; shift ;;
      *) die "start takes no options besides --instance and --route-local" ;;
    esac
  done
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
  # The other half of the automatic fallback (#286): with --route-local, or
  # on every start of an --auto-route VM, the repositories a stop flipped to
  # hosted come back to local now that this runner is taking jobs again. A
  # restore that does not land keeps its entry for the next start and fails
  # the command, so scripts notice.
  if [ "$route" = 1 ] || [ "$(state_get auto_route)" = "1" ]; then
    route_start_restore "$RR_URL" "$RR_NAME" || return 1
  fi
  return 0
}

stop_single() {
  local route=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --route-hosted) route=1; shift ;;
      *) die "stop takes no options besides --instance and --route-hosted" ;;
    esac
  done
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
  # The automatic fallback (#286): with --route-hosted, or on every stop of
  # an --auto-route VM, repositories routed to this runner go to hosted
  # before the VM stops, so queued jobs re-run on GitHub's runners instead
  # of waiting for a VM that is down. The stop itself is what was asked for,
  # so a fallback that cannot prove it should run still stops the VM — it
  # just says so and exits 1.
  local fallback_rc=0
  if [ "$route" = 1 ] || [ "$(state_get auto_route)" = "1" ]; then
    runner_report_collect
    if [ "$RR_ASKFAIL" = 1 ] || [ "$RR_NOTREG" = 1 ]; then
      echo "homefield: could not read ${INSTANCE}'s runner identity; the routed repositories stay as they are and jobs will queue while the VM is down" >&2
      fallback_rc=1
    elif ! route_stop_fallback "$RR_URL" "$RR_NAME"; then
      fallback_rc=1
    fi
  fi
  log "stopping VM ${INSTANCE}: its runner takes no jobs until it starts again"
  limactl stop "$INSTANCE" </dev/null ||
    die "could not stop VM ${INSTANCE} (Lima failed; docs/runbook.md, \"Failure modes\")"
  echo "VM ${INSTANCE}: Stopped"
  # The stop was the operator's (or the scaler's) explicit decision that this
  # VM stays down: its line in the watcher's sleep-running record goes, so
  # the Mac's next wake does not start it again. Every stop path runs through
  # here — a plain stop, --route-hosted, `fleet stop`, and the demand
  # scaler's scale-to-zero (whose dark line is the wake-on-demand source that
  # may bring the VM back). A stop that failed never gets here, and a VM
  # with no line is already without one.
  route_watcher_sleep_running_drop "$INSTANCE" || true
  return "$fallback_rc"
}

cmd_start() {
  vm_dispatch start start_single "$@"
}

cmd_stop() {
  vm_dispatch stop stop_single "$@"
}

# RESET_BASE: the base VM's name for INSTANCE, set by check_reset_base, which
# dies when the derived name is not a Lima instance name (check_instance's
# rules: the base adds "-base", so a 76-character --instance would overflow).
RESET_BASE=""
check_reset_base() {
  RESET_BASE="${INSTANCE}-base"
  local re='^[A-Za-z0-9]+([._-][A-Za-z0-9]+)*$'
  [[ "$RESET_BASE" =~ $re && ${#RESET_BASE} -le 76 ]] ||
    die "--reset-vm: the base VM would be named ${RESET_BASE}, which is not a valid Lima instance name (is --instance too long?); use a shorter --instance"
}

# reset_effective: whether this re-register should reset the VM: the command's
# --reset-vm/--no-reset-vm override (HOMEFIELD_RESET_VM, exported so it reaches
# the per-VM processes vm_dispatch runs for a multi-VM re-register), else the
# instance state (reset_vm=, saved by install/upgrade).
reset_effective() {
  if [ -n "${HOMEFIELD_RESET_VM:-}" ]; then
    printf '%s' "$HOMEFIELD_RESET_VM"
  else
    state_get reset_vm
  fi
}

# reset_vm_cycle: the reset half of a re-register: stop the VM, delete it, and
# clone a fresh one from its base (<instance>-base, the unregistered VM install
# --reset-vm left behind; limactl clone refuses a running source, so a base a
# hand started is stopped first). Returns 0 when the fresh clone exists
# (stopped — the caller starts it), 1 when the reset was skipped with the old
# VM still there (the caller re-registers it as it is): the runner staying
# available matters more than the reset happening this cycle, and the next
# cycle retries. Returns 2 when the clone failed after the delete: the VM is
# then gone, the error is recorded for status, and the caller must not try to
# re-register — the next watch cycle (or a manual re-register) clones it again
# from the base, the retry the design allows, because the base is exactly what
# it restores from.
reset_vm_cycle() {
  local base="$RESET_BASE" bs
  bs="$(vm_status_of "$base")" ||
    die "re-register: could not ask Lima about the base VM ${base}"
  if [ -z "$bs" ] || ! is_reset_base "$base"; then
    state_set reset_error "no reset base VM ${base} (install --ephemeral --reset-vm creates it)"
    log "warning: no reset base VM ${base}; re-registering ${INSTANCE} without the reset"
    return 1
  fi
  if [ "$bs" = "Running" ]; then
    log "stopping the base VM ${base} (a clone needs it stopped)"
    if ! limactl stop "$base" </dev/null; then
      state_set reset_error "could not stop the base VM ${base}"
      log "warning: could not stop the base VM ${base}; re-registering ${INSTANCE} without the reset"
      return 1
    fi
  fi
  if ! limactl stop "$INSTANCE" </dev/null; then
    state_set reset_error "could not stop the VM to reset it"
    log "warning: could not stop VM ${INSTANCE} for the reset; re-registering without it"
    return 1
  fi
  if ! limactl delete -f "$INSTANCE" </dev/null; then
    state_set reset_error "could not delete the VM to reset it"
    log "warning: could not delete VM ${INSTANCE} for the reset; re-registering without it"
    return 1
  fi
  if ! limactl clone --start=false "$base" "$INSTANCE" </dev/null; then
    state_set ephemeral_error "reset: clone from ${base} failed; the VM is gone"
    log "reset: could not clone VM ${INSTANCE} from ${base}; the next watch cycle clones it again (or run bin/homefield re-register --instance ${INSTANCE})"
    return 2
  fi
  # The clone inherited the base's config, reset-base marker included; a
  # working VM that looks like a base would be skipped by vm_instances.
  strip_base_marker "$INSTANCE"
  state_set reset_error ""
  log "cloned a fresh VM ${INSTANCE} from ${base}"
  return 0
}

# re_register_single: fetches a fresh one-hour registration token on the host
# and pipes it on stdin to provision.sh re-register, then waits for online.
# On any failure, records ephemeral_error so homefield status reports it
# visibly offline rather than silently dead.
# With the reset on (reset_effective), the re-register runs on a fresh clone:
# stop, delete, clone from <instance>-base (reset_vm_cycle), start, register.
# A VM that is already gone is cloned from the base first; a reset that cannot
# run (no base, or a step failed before the delete) is skipped and the old VM
# is re-registered as it is.
re_register_single() {
  local recovery=0
  [ "$(state_get ephemeral)" = "1" ] ||
    die "re-register: ${INSTANCE} is not configured in ephemeral mode"
  # The base's name is derived here too (the recovery clone below uses it), so
  # a reset switch set by hand for an instance whose <instance>-base is not a
  # Lima name stops here instead of failing at the clone.
  if [ "$(reset_effective)" = "1" ]; then
    check_reset_base
  fi
  check_host
  vm_lookup
  if [ -z "$VM_STATUS" ]; then
    local bs=""
    bs="$(vm_status_of "$RESET_BASE")" ||
      die "re-register: could not ask Lima about the base VM $RESET_BASE"
    if [ "$(reset_effective)" = "1" ] && [ -n "$bs" ] && is_reset_base "$RESET_BASE"; then
      log "VM ${INSTANCE} is gone; cloning it from the base VM $RESET_BASE"
      if ! limactl clone --start=false "$RESET_BASE" "$INSTANCE" </dev/null; then
        state_set ephemeral_error "reset: clone from $RESET_BASE failed"
        log "reset: could not clone VM ${INSTANCE} from $RESET_BASE; the next watch cycle retries (or run bin/homefield re-register --instance ${INSTANCE})"
        return 1
      fi
      strip_base_marker "$INSTANCE"
      state_set reset_error ""
      recovery=1
    else
      die "no VM ${INSTANCE}; run bin/homefield install --ephemeral"
    fi
  fi
  ensure_vm "" ""

  if is_job_running; then
    die "re-register: a job is running on ${INSTANCE}; try again when it is idle"
  fi

  # fresh_vm: the token below goes only into a VM this run cloned fresh from
  # the base — the recovery clone, or a reset cycle that completed. A reset
  # that was skipped (a step failed before the delete) leaves the old VM, and
  # a re-register without the reset never clones: both would re-register in
  # place, and a VM that has been registered may have run jobs the host never
  # sees, so neither may take a token.
  local fresh_vm=0
  if [ "$recovery" = 1 ]; then
    fresh_vm=1
  elif [ "$(reset_effective)" = "1" ]; then
    # The clone is stopped; the re-register below configures it. A skipped
    # reset (no base, or a step failed before the delete) leaves the old VM in
    # place, stopped or running; ensure_vm covers both. A clone that failed
    # after the delete (2) leaves the VM gone: return nonzero so a one-shot
    # re-register fails visibly while the watch loop stays alive — its next
    # cycle takes the recovery path above and clones the VM back.
    local cycle_rc=0
    reset_vm_cycle || cycle_rc=$?
    if [ "$cycle_rc" = 2 ]; then
      return 1
    fi
    if [ "$cycle_rc" = 0 ]; then
      fresh_vm=1
    fi
    ensure_vm "" ""
  else
    state_set reset_error ""
  fi
  verify_isolation

  local url="" name="" group="" label=""
  url="$(state_get ephemeral_url)"
  name="$(state_get ephemeral_name)"
  group="$(state_get ephemeral_group)"
  label="$(state_get ephemeral_label)"
  if [ -z "$url" ] || [ -z "$name" ]; then
    local r_url="" r_name=""
    { IFS= read -r r_url || true; IFS= read -r r_name || true; } < <(runner_setting gitHubUrl agentName 2>/dev/null || true)
    [ -n "$url" ] || url="$r_url"
    [ -n "$name" ] || name="$r_name"
  fi
  [ -n "$url" ] || die "re-register: could not determine registration URL for ${INSTANCE}"

  # The re-register puts a registration token into the VM (on stdin, but it
  # reaches config.sh through the provisioning process's environment). A VM
  # that has run jobs may hold a root process the job left behind, and such
  # a process can read that environment — and once a runner has been
  # registered, the host cannot know whether jobs ran. So the token goes
  # only into the fresh clone the reset paths above made; re-registering the
  # old VM in place is refused even when its _work is absent, because a VM
  # that has run jobs can delete that directory (the job's root owns it) and
  # its answer is not a boundary.
  if [ "$fresh_vm" != 1 ]; then
    # Return, not die: a reset that was skipped for a transient reason (a
    # stop or delete that failed) reaches here every cycle, and a die would
    # end the whole re-register --watch process — and with it every other
    # runner it watches. The refusal itself stands: no token goes into the
    # retained VM. The one-shot command exits 1 with the same message.
    echo "homefield: re-register: ${INSTANCE} would be re-registered in place; a VM that has been registered may have run jobs (a job's leftover root process could read the token from the provisioning process), so a registration token only goes into a VM this command clones fresh from the base. Re-register with the reset on: bin/homefield re-register --reset-vm --instance ${INSTANCE} (the base install --ephemeral --reset-vm creates), or reset + install: bin/homefield reset --instance ${INSTANCE}, then bin/homefield install --ephemeral --instance ${INSTANCE} --url ${url}" >&2
    return 1
  fi
  # The clone's own _work probe is the second line: the base was cloned
  # before any job, so a _work on the clone means the base has run jobs or
  # was tampered with, and no token goes in.
  local ran_rc=0
  ran_jobs || ran_rc=$?
  case "$ran_rc" in
    0)
      die "re-register: the fresh clone for ${INSTANCE} already has a _work directory, so the base VM it was cloned from has run jobs or was changed; a registration token must not go into it. Rebuild the base: bin/homefield reset --instance ${INSTANCE} (it deletes the base too), then bin/homefield install --ephemeral --reset-vm --instance ${INSTANCE} --url ${url}"
      ;;
    2)
      die "re-register: could not ask whether ${INSTANCE} has run jobs; a registration token must not go into a VM this command cannot check (is it running?)"
      ;;
  esac

  local token=""
  if ! token="$(get_token registration "$url")"; then
    state_set ephemeral_error "token fetch failed"
    die "re-register: could not fetch registration token for ${url}"
  fi

  local env=()
  env+=(RUNNER_URL="$url" RUNNER_EPHEMERAL=1)
  [ -z "$label" ] || env+=(RUNNER_LABEL="$label")
  [ -z "$name" ] || env+=(RUNNER_NAME="$name")
  [ -z "$group" ] || env+=(RUNNER_GROUP="$group")
  # The job-cleanup switch follows the VM's saved state, so a re-register
  # keeps the hook (or its absence) exactly as install/upgrade left it: =1
  # re-adds the .env line if a hand edit lost it, =0 takes it back out.
  local job_cleanup=""
  job_cleanup="$(state_get job_cleanup)"
  [ -z "$job_cleanup" ] || env+=(RUNNER_JOB_CLEANUP="$job_cleanup")

  log "re-registering ephemeral runner ${INSTANCE} at ${url}"
  # Written before the token enters the guest, not after provisioning
  # returns: a failure past the registration would exit here without the
  # record (see cmd_install's same write). The check is explicit because
  # the watch loop calls this function as `re_register_single || ...`,
  # which turns errexit off for the whole function — a failed write must
  # return, not pass.
  if ! state_set ever_registered 1; then
    echo "homefield: re-register: could not record the registration for ${INSTANCE}; no token goes into the VM (fix the state directory: \$(state_file))" >&2
    return 1
  fi
  if ! PROVISION_CMD=re-register run_provision "RUNNER_TOKEN=${token}"$'\n' "${env[@]}"; then
    token=""
    state_set ephemeral_error "re-registration failed"
    die "re-register: failed on ${INSTANCE}; runner left offline"
  fi
  token=""
  state_set ephemeral_error ""

  local registered_name=""
  { IFS= read -r registered_name || true; } < <(runner_setting agentName)
  wait_online "$url" "$registered_name" "${group:-homefield-ci}"
}

cmd_re_register() {
  local watch=0 interval="${HOMEFIELD_EPHEMERAL_POLL_INTERVAL:-10}" max_cycles=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --watch) watch=1; shift ;;
      --interval)
        [ $# -ge 2 ] || die "re-register: --interval needs seconds"
        interval="$2"; shift 2 ;;
      --max-cycles)
        [ $# -ge 2 ] || die "re-register: --max-cycles needs a count"
        max_cycles="$2"; shift 2 ;;
      --reset-vm) HOMEFIELD_RESET_VM=1; shift ;;
      --no-reset-vm) HOMEFIELD_RESET_VM=0; shift ;;
      *) die "re-register: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  [[ "$interval" =~ ^[0-9]+$ ]] || die "re-register: --interval must be a non-negative integer"
  [[ "$max_cycles" =~ ^[0-9]+$ ]] || die "re-register: --max-cycles must be a non-negative integer"
  # The override reaches the per-VM processes vm_dispatch runs for a
  # multi-VM re-register through the environment.
  export HOMEFIELD_RESET_VM

  if [ "$watch" = 0 ]; then
    vm_dispatch re-register re_register_single
    return
  fi

  local watch_vms=() list="" vm own_eph=0 original_instance="$INSTANCE"
  [ "$(state_get ephemeral)" = "1" ] && own_eph=1
  if [ "$EXPLICIT_INSTANCE" = 1 ]; then
    [ "$own_eph" = 1 ] ||
      die "re-register --watch: ${INSTANCE} is not configured in ephemeral mode"
    watch_vms=("$INSTANCE")
  else
    if list="$(vm_instances)"; then
      while IFS= read -r vm; do
        [ -n "$vm" ] || continue
        INSTANCE="$vm"
        [ "$(state_get ephemeral)" = "1" ] && watch_vms+=("$vm")
      done <<<"$list"
      # The instance this state describes is always watched, even when the
      # list found other ephemeral VMs: it may be absent (a failed reset
      # deletes one), and this watch is what clones it back from its base.
      if [ "$own_eph" = 1 ]; then
        local already=0
        if [ ${#watch_vms[@]} -gt 0 ]; then
          for vm in "${watch_vms[@]}"; do
            if [ "$vm" = "$original_instance" ]; then already=1; fi
          done
        fi
        if [ "$already" != 1 ]; then
          watch_vms+=("$original_instance")
          INSTANCE="$original_instance"
        fi
      fi
    elif [ "$own_eph" = 1 ]; then
      watch_vms=("$original_instance")
    fi
    [ ${#watch_vms[@]} -gt 0 ] ||
      die "re-register --watch: no ephemeral VM found"
  fi
  local cycle=0 st=""
  while :; do
    cycle=$((cycle + 1))
    for vm in "${watch_vms[@]}"; do
      INSTANCE="$vm"
      st="$(vm_status)" ||
        die "could not ask Lima about VM ${INSTANCE}; stopping the watch loop"
      if [ -z "$st" ]; then
        # Gone (a failed reset deleted it, or a hand did): with the reset on,
        # the re-register clones it back from the base; without it there is
        # nothing to watch.
        if [ "$(reset_effective)" = "1" ]; then
          log "ephemeral runner ${INSTANCE} has no VM; cloning it from its base and re-registering"
          # A failed recovery clone returns nonzero without dying: the loop
          # stays alive and the next cycle retries it.
          re_register_single ||
            echo "homefield: warning: re-register of ${INSTANCE} failed; the next cycle retries" >&2
        else
          echo "homefield: warning: ephemeral runner ${INSTANCE} has no VM; run bin/homefield install --ephemeral to bring it back" >&2
        fi
      elif ! is_job_running && ! runner_service_state; then
        log "ephemeral runner ${INSTANCE} finished a job; re-registering"
        # Tolerated for the same reason: a reset whose clone failed after the
        # delete returns nonzero, and the next cycle's recovery path retries.
        re_register_single ||
          echo "homefield: warning: re-register of ${INSTANCE} failed; the next cycle retries" >&2
      fi
    done
    if [ "$max_cycles" -gt 0 ] && [ "$cycle" -ge "$max_cycles" ]; then
      break
    fi
    [ "$interval" -eq 0 ] || sleep "$interval"
  done
}
