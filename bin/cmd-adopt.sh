#!/usr/bin/env bash
# The adopt command: routing a repository's workflows to the runner.

# Set by the steps below, for the ones after them and the summary.
ADOPT_TMP=""
ADOPT_REPO_ID=""
ADOPT_BRANCH=""
ADOPT_OWNER_TYPE=""
ADOPT_GROUP_OUTCOME=""
ADOPT_SWITCH_OUTCOME=""
ADOPT_READY=0
ADOPT_REASONS=""
ADOPT_NOTES=""
ADOPT_LABEL=""
# The label of the first routing guard that passes its check, when
# adopt did not get --label: a passing guard says which label the repository
# actually routes on, and that is the one to advise with.
ADOPT_LABEL_OK=""
ADOPT_GUARDS=0
ADOPT_ROUTED=""
ADOPT_WORKFLOWS=0

# adopt_repository <owner/repo>: sets ADOPT_REPO_ID, ADOPT_BRANCH and
# ADOPT_OWNER_TYPE. Only private repositories may reach the runner.
adopt_repository() {
  local repo="$1" info private
  if ! info="$(gh api "repos/${repo}" --jq '[.private, .id, .default_branch, .owner.type] | @tsv' 2>/dev/null)"; then
    die "adopt: could not read ${repo} with gh: it does not exist, or this gh login cannot see it"
  fi
  IFS=$'\t' read -r private ADOPT_REPO_ID ADOPT_BRANCH ADOPT_OWNER_TYPE <<<"$info"
  case "$private" in
    true) ;;
    false) die "adopt: ${repo} is public. The runner is for private repositories only: a pull request runs the workflow files from its own branch, so anyone who can open one could run code on the VM (README, \"Security model\")" ;;
    *) die "adopt: gh gave an answer for ${repo} that this tool cannot read: ${info}" ;;
  esac
  [[ -n "$ADOPT_REPO_ID" && -n "$ADOPT_BRANCH" ]] || die "adopt: gh gave an answer for ${repo} that this tool cannot read: ${info}"
  log "repository: ${repo} is private (default branch ${ADOPT_BRANCH})"
}

# adopt_group_access <owner/repo> <group> <dry>: makes sure the runner group
# admits the repository, but only writes to it (the PUT) when the routing is
# ready (ADOPT_READY): group access is what lets a repository's jobs reach the
# runner, so it must not come before the routing that keeps them to its own
# pull requests. When the routing is not ready this still reads the group, to
# say whether the repository is already in it. Not being able to check is a
# warning, not an error: group access is an organization-admin matter that the
# person running this may not be, and the rest of the checks are still worth
# having. A group that allows public repositories is a warning too, and goes on
# into the outcome line: whatever else it says, the group is not the boundary
# the docs describe.
adopt_group_access() {
  local repo="$1" group="$2" dry="$3" org="${1%%/*}" rows="" listed=0 name vis pub gid
  local found="" members byhand="" widen=""
  [ "$ADOPT_READY" = 0 ] || byhand="; add ${repo} by hand (docs/adopting.md step 5)"
  if [ "$ADOPT_OWNER_TYPE" != Organization ]; then
    ADOPT_GROUP_OUTCOME="none needed (${org} is a personal account)"
    log "runner group: skipped, ${org} is a personal account and has no runner groups"
    return 0
  fi
  if [ "$(lower "$group")" = default ]; then
    ADOPT_GROUP_OUTCOME="none needed (Default group)"
    log "runner group: skipped, the Default group is open to every repository in ${org}"
    return 0
  fi
  if rows="$(list_groups_ids "$org")"; then
    listed=1
  elif offer_scope_refresh && rows="$(list_groups_ids "$org")"; then
    listed=1
  fi
  if [ "$listed" = 0 ]; then
    ADOPT_GROUP_OUTCOME="not checked"
    adopt_warn "could not check runner group access${byhand}"
    return 0
  fi
  while IFS=$'\t' read -r name vis pub gid; do
    [ -n "$name" ] || continue
    [ "$(lower "$name")" = "$(lower "$group")" ] || continue
    found="$name"
    break
  done <<<"$rows"
  if [ -z "$found" ]; then
    ADOPT_GROUP_OUTCOME="none needed (no group ${group})"
    log "runner group: ${org} has no group ${group}; the runner may be repository-scoped or in another group, so nothing was changed"
    return 0
  fi
  [ "$pub" != true ] || widen=", but the group allows public repositories"
  if [ "$vis" != selected ]; then
    ADOPT_GROUP_OUTCOME="already open (${vis})${widen}"
    adopt_warn "runner group ${found} is open to ${vis} repositories in ${org}${widen:+ and allows public ones}, so ${repo} already has access and nothing was added; narrow it to selected repositories with public ones off (docs/runbook.md, \"Runner group\")"
    return 0
  fi
  if [ -n "$widen" ]; then
    adopt_warn "runner group ${found} allows public repositories. ${repo} is private, but anyone who can add a public repository to the group lets that repository's pull requests run their own workflow files on the runner, and the README's security model rests on there being none. The group stays that way after this adoption; turn off Allow public repositories for it (docs/runbook.md, \"Runner group\")"
  fi
  if ! members="$(gh api --paginate "orgs/${org}/actions/runner-groups/${gid}/repositories?per_page=100" --jq '.repositories[].id' 2>/dev/null)"; then
    ADOPT_GROUP_OUTCOME="not checked${widen}"
    adopt_warn "could not read the repositories of runner group ${found}${byhand}"
    return 0
  fi
  if printf '%s\n' "$members" | grep -qx "$ADOPT_REPO_ID"; then
    ADOPT_GROUP_OUTCOME="already a member${widen}"
    log "runner group: ${repo} already has access to ${found}"
    if [ "$ADOPT_READY" = 0 ]; then
      adopt_warn "${repo} is already in runner group ${found}, so its workflows can already send jobs to the runner although its routing is not ready; take it out of the group until the routing is merged (docs/runbook.md, \"Runner group\")"
    fi
  elif [ "$ADOPT_READY" = 0 ]; then
    ADOPT_GROUP_OUTCOME="not added (the routing is not ready)"
    log "runner group: not added, because the routing is not ready"
  elif [ "$dry" = 1 ]; then
    ADOPT_GROUP_OUTCOME="would be added (dry run)${widen}"
    log "runner group: would add ${repo} to ${found} (dry run)"
  else
    gh api -X PUT "orgs/${org}/actions/runner-groups/${gid}/repositories/${ADOPT_REPO_ID}" >/dev/null ||
      die "adopt: could not add ${repo} to runner group ${found}; add it by hand (docs/adopting.md step 5)"
    ADOPT_GROUP_OUTCOME="added${widen}"
    log "runner group: added ${repo} to ${found}"
  fi
}

# adopt_fetch_workflows <owner/repo> <branch> <dir>: the repository's
# .github/workflows at the branch, into dir; sets ADOPT_WORKFLOWS to how many.
# A repository without the directory has none, which is not an error here.
adopt_fetch_workflows() {
  local repo="$1" branch="$2" dir="$3" names name enc
  mkdir -p "$dir"
  ADOPT_WORKFLOWS=0
  if ! names="$(gh api -X GET "repos/${repo}/contents/.github/workflows" -f ref="$branch" \
    --jq '.[] | select(.type == "file") | .name' 2>"$ADOPT_TMP/err")"; then
    if grep -q 404 "$ADOPT_TMP/err"; then
      names=""
    else
      die "adopt: could not list .github/workflows in ${repo} with gh: $(head -1 "$ADOPT_TMP/err")"
    fi
  fi
  while IFS= read -r name; do
    case "$name" in
      */* | "") continue ;;
      *.yml | *.yaml) ;;
      *) continue ;;
    esac
    # A name may have spaces or other characters a URL path cannot carry.
    enc="$(python3 -I "$ROOT/tools/adopt.py" quote "$name" </dev/null)" ||
      die "adopt: could not quote the workflow name ${name}"
    gh api -X GET "repos/${repo}/contents/.github/workflows/${enc}" -f ref="$branch" \
      -H 'Accept: application/vnd.github.raw' >"$dir/$name" 2>"$ADOPT_TMP/err" </dev/null ||
      die "adopt: could not download .github/workflows/${name} from ${repo}: $(head -1 "$ADOPT_TMP/err")"
    ADOPT_WORKFLOWS=$((ADOPT_WORKFLOWS + 1))
  done <<<"$names"
}

# adopt_reason <text>: one reason the routing is not ready.
adopt_reason() {
  ADOPT_READY=0
  ADOPT_REASONS="${ADOPT_REASONS}  - $1"$'\n'
}

# adopt_note <text>: one thing to check about the guard, once.
adopt_note() {
  case $'\n'"$ADOPT_NOTES" in
    *$'\n'"$1"$'\n'*) ;;
    *) ADOPT_NOTES="${ADOPT_NOTES}$1"$'\n' ;;
  esac
}

# adopt_each <command> <items>: runs the command on each of the items, which
# tools/adopt.py joins with ";" ("-" is none).
adopt_each() {
  local cmd="$1" rest="$2" item
  [ "$rest" != - ] || return 0
  while [ -n "$rest" ]; do
    item="${rest%%;*}"
    if [ "$item" = "$rest" ]; then rest=""; else rest="${rest#*;}"; fi
    [ -z "$item" ] || "$cmd" "$item"
  done
}

# adopt_events_key <events>: the events in canonical order, comma-separated,
# so two spellings of the same set compare equal (the order of the list and
# the separators do not matter to routing_guard.py). Names it does not know
# are dropped; the guard check reports those.
adopt_events_key() {
  local padded e key=""
  padded=" $(printf '%s' "$1" | tr ',\n\t' '   ') "
  for e in pull_request push workflow_dispatch schedule; do
    case "$padded" in
      *" $e "*) key="${key:+${key},}${e}" ;;
    esac
  done
  printf '%s' "$key"
}

# adopt_routing_check <dir> <label> <label_given>: sets ADOPT_READY (1 when a
# usable routing-guard step is there, passes, and at least one job is routed),
# ADOPT_REASONS (why not), ADOPT_LABEL, ADOPT_EVENTS, ADOPT_DEPENDABOT,
# ADOPT_FALLBACK and ADOPT_ROUTED. The workflows' own guard says which label,
# options and jobs to expect; --events, --dependabot and --fallback arrive as
# ADOPT_FLAG_EVENTS, ADOPT_FLAG_DEPENDABOT and ADOPT_FLAG_FALLBACK (empty when
# not given) and are held to the guard the way --label is. The guard's arch is
# read too, and refused unless arm64: adopt sets up the arm64 VM, and there is
# no flag to change that (#21 is the x86-64 future). The checks are routing_guard.py,
# the same script the guard runs in CI, with the step's own arch, so what they
# report is what CI runs. A usable step is the action pinned to
# this copy's release or a commit, in a workflow that runs on pull requests
# (tools/adopt.py says which are).
# adopt_routing_init <label>: sets the outcome globals the check reports
# through — ADOPT_READY, ADOPT_REASONS, ADOPT_NOTES, ADOPT_LABEL, ADOPT_EVENTS,
# ADOPT_DEPENDABOT, ADOPT_FALLBACK, ADOPT_MODE, ADOPT_GUARDS, ADOPT_ROUTED —
# to their defaults: ready until a reason, the flags' values where --events,
# --dependabot and --fallback were given, and the expression's shape in
# ADOPT_MODE. ADOPT_LABEL starts at the --label value; a guard's own label
# replaces it below.
adopt_routing_init() {
  local label="$1"
  ADOPT_READY=1
  ADOPT_REASONS=""
  ADOPT_NOTES=""
  ADOPT_LABEL="$label"
  ADOPT_LABEL_OK=""
  ADOPT_EVENTS="${ADOPT_FLAG_EVENTS:-pull_request}"
  ADOPT_DEPENDABOT="${ADOPT_FLAG_DEPENDABOT:-hosted}"
  ADOPT_FALLBACK="${ADOPT_FLAG_FALLBACK:-ubuntu-latest}"
  # The expression's shape: --guards asks for the guarded one; without it, an
  # existing guard keeps its own shape and a repository without one gets
  # simple, the shape a personal repository reads at a glance.
  ADOPT_MODE=guards
  if [ "$ADOPT_FLAG_GUARDS" = 0 ]; then
    ADOPT_MODE=simple
  fi
  ADOPT_GUARDS=0
  ADOPT_ROUTED=""
}

# adopt_routing_first <label> <label_given> <glabel> <gevents> <gdependabot>
# <gfallback> <gmode>: the first usable guard row names the label and options
# the repository routes on; they stand wherever a flag did not pick the value.
# Sets ADOPT_LABEL, ADOPT_EVENTS, ADOPT_DEPENDABOT, ADOPT_FALLBACK and
# ADOPT_MODE.
adopt_routing_first() {
  local label="$1" label_given="$2" glabel="$3" gevents="$4" gdependabot="$5" gfallback="$6" gmode="$7"
  [ "$label_given" = 1 ] || ADOPT_LABEL="$glabel"
  [ -n "$ADOPT_FLAG_EVENTS" ] || ADOPT_EVENTS="$gevents"
  [ -n "$ADOPT_FLAG_DEPENDABOT" ] || ADOPT_DEPENDABOT="$gdependabot"
  [ -n "$ADOPT_FLAG_FALLBACK" ] || ADOPT_FALLBACK="$gfallback"
  [ "$ADOPT_FLAG_GUARDS" = 1 ] || ADOPT_MODE="$gmode"
}

# adopt_routing_mismatches <label> <label_given> <where> <glabel> <gevents>
# <gdependabot> <gfallback> <garch> <gmode>: one reason on ADOPT_REASONS for
# every guard option that disagrees with a flag (--label, --events,
# --dependabot, --fallback) and for the ones adopt cannot route (a non-arm64
# arch, a non-guarded mode under --guards). Returns 1 when a mismatch was
# added, 0 when the guard's own options speak for the repository.
adopt_routing_mismatches() {
  local label="$1" label_given="$2" where="$3" glabel="$4" gevents="$5" gdependabot="$6" gfallback="$7" garch="$8" gmode="$9"
  local match=1
  if [ "$label_given" = 1 ] && [ "$glabel" != "$label" ]; then
    match=0
    adopt_reason "the routing-guard step at ${where} uses label ${glabel}, but --label is ${label}"
  fi
  if [ -n "$ADOPT_FLAG_EVENTS" ] && [ "$(adopt_events_key "$gevents")" != "$(adopt_events_key "$ADOPT_FLAG_EVENTS")" ]; then
    match=0
    adopt_reason "the routing-guard step at ${where} uses events ${gevents}, but --events is ${ADOPT_FLAG_EVENTS}"
  fi
  if [ -n "$ADOPT_FLAG_DEPENDABOT" ] && [ "$gdependabot" != "$ADOPT_FLAG_DEPENDABOT" ]; then
    match=0
    adopt_reason "the routing-guard step at ${where} uses dependabot ${gdependabot}, but --dependabot is ${ADOPT_FLAG_DEPENDABOT}"
  fi
  if [ -n "$ADOPT_FLAG_FALLBACK" ] && [ "$gfallback" != "$ADOPT_FLAG_FALLBACK" ]; then
    match=0
    adopt_reason "the routing-guard step at ${where} uses fallback ${gfallback}, but --fallback is ${ADOPT_FLAG_FALLBACK}"
  fi
  if [ "$garch" != arm64 ]; then
    match=0
    adopt_reason "the routing-guard step at ${where} uses arch ${garch}, but adopt sets up an arm64 VM; a guard step for another architecture routes its jobs to a runner this Mac does not have (docs/adopting.md, step 3)"
  fi
  if [ "$ADOPT_FLAG_GUARDS" = 1 ] && [ "$gmode" != guards ]; then
    match=0
    adopt_reason "the routing-guard step at ${where} uses mode ${gmode}, but --guards is given: simple mode is the one-clause expression whose only guardrail is CI_RUNNER, and it cannot check the guarded one's clauses; drop --guards, or edit the guard (docs/adopting.md, step 3)"
  fi
  [ "$match" = 1 ]
}

# adopt_routing_routed <dir> <guard options...>: the jobs routed under the
# guard's label and options, into ADOPT_ROUTED. A repository can carry several
# routing-guard steps; jobs routed under any of them count, not only the first
# guard's — unless a flag picked a value, in which case only steps carrying it
# speak for it and the others are already reported as a mismatch above. A
# guard whose own options the script refuses fails here too: the guard check
# reports that, so an empty list is right for now.
adopt_routing_routed() {
  local dir="$1" routed routedjob
  shift
  routed="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --workflows-dir "$dir" "$@" --list 2>/dev/null)" || routed=""
  while IFS= read -r routedjob; do
    [ -n "$routedjob" ] || continue
    case $'\n'"$ADOPT_ROUTED"$'\n' in
      *"$'\n'${routedjob}"$'\n'*) ;;
      *) ADOPT_ROUTED="${ADOPT_ROUTED:+${ADOPT_ROUTED}$'\n'}${routedjob}" ;;
    esac
  done <<<"$routed"
}

# adopt_routing_ok <gmatch> <glabel> <gevents> <gdependabot> <gfallback>
# <gmode>: the first guard that passes and agrees with the flags names the
# label and options; they equal the flags' wherever one was given. Sets
# ADOPT_LABEL_OK and ADOPT_OK_EVENTS, ADOPT_OK_DEPENDABOT, ADOPT_OK_FALLBACK
# and ADOPT_OK_MODE.
adopt_routing_ok() {
  local gmatch="$1" glabel="$2" gevents="$3" gdependabot="$4" gfallback="$5" gmode="$6"
  if [ "$gmatch" = 1 ] && [ -z "$ADOPT_LABEL_OK" ]; then
    ADOPT_LABEL_OK="$glabel"
    ADOPT_OK_EVENTS="$gevents"
    ADOPT_OK_DEPENDABOT="$gdependabot"
    ADOPT_OK_FALLBACK="$gfallback"
    ADOPT_OK_MODE="$gmode"
  fi
}

# adopt_routing_failure <where> <out>: one reason for a guard that would fail,
# from the routing_guard.py output <out>: the failure lines only, no colours,
# no passes, no header or totals.
adopt_routing_failure() {
  local where="$1" out="$2" lines
  lines="$(printf '%s\n' "$out" | sed $'s/\033\\[[0-9;]*m//g' |
    grep -v -e PASS -e '^self-hosted runner routing' -e ' passed, ' -e '^$' || true)"
  adopt_reason "the routing-guard step at ${where} would fail:"
  ADOPT_REASONS="${ADOPT_REASONS}$(printf '%s\n' "$lines" | sed 's/^ */      /')"$'\n'
}

# adopt_routing_guards <dir> <label> <label_given>: reads the guard rows
# tools/adopt.py finds in dir and checks each one. Sets ADOPT_GUARDS (the
# usable guards found) and ADOPT_CANDIDATES (the guard steps at all), and
# hands the blocked rows' reasons back through ADOPT_DEFERRED — they are only
# a reason when no step is usable. The outcome globals the row helpers set
# (ADOPT_LABEL, ADOPT_EVENTS, ADOPT_DEPENDABOT, ADOPT_FALLBACK, ADOPT_MODE,
# ADOPT_REASONS, ADOPT_NOTES, ADOPT_ROUTED, ADOPT_LABEL_OK, ADOPT_OK_*) are
# what the rest of the check and the caller read.
adopt_routing_guards() {
  local dir="$1" label="$2" label_given="$3" rows where gstatus glabel gblocks gwarns gevents gdependabot gfallback garch gmode gjobs
  local gmatch opts out rc
  ADOPT_CANDIDATES=0
  ADOPT_DEFERRED=""
  rows="$(python3 -I "$ROOT/tools/adopt.py" guards "$dir")" || die "adopt: could not read the downloaded workflows"
  while IFS=$'\t' read -r where gstatus glabel gblocks gwarns gevents gdependabot gfallback garch gmode gjobs; do
    [ -n "$where" ] || continue
    ADOPT_CANDIDATES=$((ADOPT_CANDIDATES + 1))
    case "$gstatus" in
      source)
        adopt_each adopt_reason "$gblocks"
        continue
        ;;
      blocked)
        # Only a reason when no step is usable: a leftover that cannot run is
        # not a guard, and does no harm next to one that can.
        [ "$gblocks" = - ] || ADOPT_DEFERRED="${ADOPT_DEFERRED:+${ADOPT_DEFERRED};}${gblocks}"
        continue
        ;;
    esac
    if [ "$ADOPT_GUARDS" = 0 ]; then
      adopt_routing_first "$label" "$label_given" "$glabel" "$gevents" "$gdependabot" "$gfallback" "$gmode"
    fi
    ADOPT_GUARDS=$((ADOPT_GUARDS + 1))
    adopt_each adopt_note "$gwarns"
    gmatch=1
    adopt_routing_mismatches "$label" "$label_given" "$where" "$glabel" "$gevents" "$gdependabot" "$gfallback" "$garch" "$gmode" || gmatch=0
    opts=(--label "$glabel" --events "$gevents" --dependabot "$gdependabot" --fallback "$gfallback" --arch "$garch" --mode "$gmode")
    if [ "$gmatch" = 1 ]; then
      adopt_routing_routed "$dir" "${opts[@]}"
    fi
    rc=0
    out="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --workflows-dir "$dir" "${opts[@]}" --jobs "$gjobs" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      adopt_routing_ok "$gmatch" "$glabel" "$gevents" "$gdependabot" "$gfallback" "$gmode"
      continue
    fi
    adopt_routing_failure "$where" "$out"
  done <<<"$rows"
}

# adopt_routing_noguard <dir> <deferred>: what a repository with no usable
# guard step is told. The blocked rows' reasons (<deferred>) become reasons
# after all, then the no-guard reason, and the routed jobs are listed by
# routing_guard.py itself: no guard to say which label applies, so the check
# looks with the expected one, as before. The options were checked above, so a
# failure here is the script not running, not "no jobs": an empty list would
# hide it. The shape is the resolved one — simple without --guards, the
# guarded one with it. Sets ADOPT_ROUTED.
adopt_routing_noguard() {
  local dir="$1" deferred="$2"
  adopt_each adopt_reason "${deferred:--}"
  if [ "$ADOPT_CANDIDATES" = 0 ]; then
    adopt_reason "no routing-guard step in .github/workflows (docs/adopting.md, step 3)"
  else
    adopt_reason "no routing-guard step that runs on pull requests (docs/adopting.md, step 3)"
  fi
  if [ "$ADOPT_MODE" = guards ]; then
    ADOPT_ROUTED="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --workflows-dir "$dir" --label "$ADOPT_LABEL" \
      --events "$ADOPT_EVENTS" --dependabot "$ADOPT_DEPENDABOT" --fallback "$ADOPT_FALLBACK" --list 2>/dev/null)" ||
      die "adopt: routing_guard.py could not list the routed jobs; run it by hand on the workflows to see why"
  else
    ADOPT_ROUTED="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --workflows-dir "$dir" --label "$ADOPT_LABEL" \
      --mode simple --fallback "$ADOPT_FALLBACK" --list 2>/dev/null)" ||
      die "adopt: routing_guard.py could not list the routed jobs; run it by hand on the workflows to see why"
  fi
}

# adopt_routing_norunson <dir>: the jobs with no runs-on, into ADOPT_NORUNSON.
# They run on GitHub's ubuntu-latest default and are left hosted silently —
# the routing-completeness gap: nothing else surfaces them until --verify
# after the switch. The scanner's own parse, so the ready report says so.
adopt_routing_norunson() {
  local dir="$1"
  if [ "$ADOPT_MODE" = guards ]; then
    ADOPT_NORUNSON="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --workflows-dir "$dir" --label "$ADOPT_LABEL" \
      --events "$ADOPT_EVENTS" --dependabot "$ADOPT_DEPENDABOT" --fallback "$ADOPT_FALLBACK" --list-unroutable 2>/dev/null)" || ADOPT_NORUNSON=""
  else
    ADOPT_NORUNSON="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --workflows-dir "$dir" --label "$ADOPT_LABEL" \
      --mode simple --fallback "$ADOPT_FALLBACK" --list-unroutable 2>/dev/null)" || ADOPT_NORUNSON=""
  fi
}

# adopt_routing_report: what the check found, as the caller and the person
# running it read it: ready with the routed jobs, or not ready with its
# reasons, plus the notes on guards that may not run on every pull request.
# Reads the ADOPT_* outcome globals; changes nothing.
adopt_routing_report() {
  if [ "$ADOPT_READY" = 1 ]; then
    log "routing: ready, the guard passes and these jobs are routed: $(printf '%s' "$ADOPT_ROUTED" | tr '\n' ' ')"
    [ -z "$ADOPT_NORUNSON" ] || log "routing: these jobs have no runs-on and stay hosted on GitHub's default: $(printf '%s' "$ADOPT_NORUNSON" | tr '\n' ' ')"
  else
    log "routing: not ready"
    printf '%s' "$ADOPT_REASONS"
  fi
  if [ -n "$ADOPT_NOTES" ]; then
    adopt_warn "the routing guard may not run on every pull request. Check that every pull request that changes .github/workflows still runs it:"
    printf '%s' "$ADOPT_NOTES" | sed 's/^/homefield:   /' >&2
  fi
}

# adopt_routing_check <dir> <label> <label_given>: sets ADOPT_READY (1 when a
# usable routing-guard step is there, passes, and at least one job is routed),
# ADOPT_REASONS (why not), ADOPT_LABEL, ADOPT_EVENTS, ADOPT_DEPENDABOT,
# ADOPT_FALLBACK and ADOPT_ROUTED. The workflows' own guard says which label,
# options and jobs to expect; --events, --dependabot and --fallback arrive as
# ADOPT_FLAG_EVENTS, ADOPT_FLAG_DEPENDABOT and ADOPT_FLAG_FALLBACK (empty when
# not given) and are held to the guard the way --label is. The guard's arch is
# read too, and refused unless arm64: adopt sets up the arm64 VM, and there is
# no flag to change that (#21 is the x86-64 future). The checks are routing_guard.py,
# the same script the guard runs in CI, with the step's own arch, so what they
# report is what CI runs. A usable step is the action pinned to
# this copy's release or a commit, in a workflow that runs on pull requests
# (tools/adopt.py says which are). The work goes to adopt_routing_init,
# adopt_routing_guards, adopt_routing_noguard, adopt_routing_norunson and
# adopt_routing_report.
adopt_routing_check() {
  local dir="$1" label="$2" label_given="$3"
  adopt_routing_init "$label"
  adopt_routing_guards "$dir" "$label" "$label_given"
  if [ "$ADOPT_MODE" = simple ] && [ -n "$ADOPT_FLAG_EVENTS$ADOPT_FLAG_DEPENDABOT" ]; then
    die "adopt: --events and --dependabot have no effect in simple mode, which routes every event; drop them, or pass --guards for the guarded expression"
  fi
  if [ "$ADOPT_GUARDS" = 0 ]; then
    adopt_routing_noguard "$dir" "$ADOPT_DEFERRED"
  elif [ -n "$ADOPT_LABEL_OK" ]; then
    ADOPT_LABEL="$ADOPT_LABEL_OK"
    ADOPT_EVENTS="$ADOPT_OK_EVENTS"
    ADOPT_DEPENDABOT="$ADOPT_OK_DEPENDABOT"
    ADOPT_FALLBACK="$ADOPT_OK_FALLBACK"
    ADOPT_MODE="$ADOPT_OK_MODE"
  fi
  if [ -z "$ADOPT_ROUTED" ]; then
    adopt_reason "no job uses the routing expression for label ${ADOPT_LABEL} (docs/adopting.md, step 2)"
  fi
  adopt_routing_norunson "$dir"
  adopt_routing_report
}

# adopt_fallback <image>: a warning only. routing_guard.py accepts any
# ubuntu-*, windows-* or macos-* name, so a typo such as ubuntu-lates passes
# the guard, and the jobs then wait for a runner that does not exist whenever
# CI_RUNNER is not local. This list is GitHub's standard hosted labels
# (docs.github.com, "GitHub-hosted runners", 2026-10). A label it does not
# know, a new image or a larger runner, only gets the warning.
adopt_fallback() {
  case "$1" in
    ubuntu-slim | ubuntu-latest | ubuntu-2[246].04 | ubuntu-2[246].04-arm | \
      windows-latest | windows-2022 | windows-2025 | windows-2025-vs2026 | \
      windows-11-arm | windows-11-vs2026-arm | \
      macos-latest | macos-1[45] | macos-26 | macos-1[45]-intel | macos-26-intel)
      log "fallback image: $1 is a standard GitHub-hosted label"
      ;;
    *)
      adopt_warn "fallback $1 is not one of GitHub's standard hosted labels that this version knows. If it is a typo, jobs wait for a runner that does not exist whenever CI_RUNNER is not local. Ignore this for a larger runner or an image newer than this list."
      ;;
  esac
}

# adopt_cache_keys <dir>: warnings only. See tools/adopt.py for what counts.
adopt_cache_keys() {
  local dir="$1" hits
  if [ "$ADOPT_WORKFLOWS" = 0 ]; then
    log "cache keys: no workflow files to look at"
    return 0
  fi
  hits="$(python3 -I "$ROOT/tools/adopt.py" cache-keys "$dir")" || die "adopt: could not read the downloaded workflows"
  # Only the routed jobs share caches across architectures, so once some are
  # routed, files without any routed job are left out (a nightly that stays
  # hosted is no concern). Before that, every file is a candidate.
  if [ -n "$ADOPT_ROUTED" ]; then
    local hit kept=""
    while IFS= read -r hit; do
      # ADOPT_ROUTED is file:job lines; a hit is file:line: text.
      case $'\n'"$ADOPT_ROUTED" in
        *$'\n'"${hit%%:*}":*) kept="${kept}${hit}"$'\n' ;;
      esac
    done <<<"$hits"
    hits="${kept%$'\n'}"
  fi
  if [ -z "$hits" ]; then
    log "cache keys: none found with runner.os and without runner.arch"
    return 0
  fi
  adopt_warn "cache keys with runner.os and no runner.arch (a text match; check what each one is the key of):"
  printf '%s\n' "$hits" | sed 's/^/homefield:   /' >&2
  adopt_warn "runner.os is Linux on the hosted runners and on this arm64 VM, so such a key lets the two architectures restore each other's build outputs. Add \${{ runner.arch }} (docs/adopting.md, step 4)."
}

# adopt_snippets <label> <jobs>: what to add to the workflows, with the
# options in ADOPT_MODE, ADOPT_EVENTS, ADOPT_DEPENDABOT and ADOPT_FALLBACK.
# The expression and the guard step come from the same code that checks them.
adopt_snippets() {
  local label="$1" jobs="$2" expr
  if [ "$ADOPT_MODE" = guards ]; then
    expr="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --print-expression --label "$label" \
      --events "$ADOPT_EVENTS" --dependabot "$ADOPT_DEPENDABOT" --fallback "$ADOPT_FALLBACK")" ||
      die "adopt: the routing options cannot be routed on (label ${label}, events ${ADOPT_EVENTS}, dependabot ${ADOPT_DEPENDABOT}, fallback ${ADOPT_FALLBACK})"
  else
    expr="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --print-expression --mode simple --label "$label" \
      --fallback "$ADOPT_FALLBACK")" ||
      die "adopt: the routing options cannot be routed on (label ${label}, fallback ${ADOPT_FALLBACK})"
  fi
  echo
  echo "Replace each job's runs-on with this expression, verbatim (docs/adopting.md, step 2):"
  echo
  echo "    runs-on: ${expr}"
  echo
  echo "Add the guard to a job that runs on every pull request, after checkout (step 3),"
  echo "listing every job you routed:"
  echo
  if [ "$ADOPT_MODE" = guards ]; then
    python3 -I "$ROOT/tools/adopt.py" guard-snippet --label "$label" --jobs "$jobs" \
      --events "$ADOPT_EVENTS" --dependabot "$ADOPT_DEPENDABOT" --fallback "$ADOPT_FALLBACK"
  else
    python3 -I "$ROOT/tools/adopt.py" guard-snippet --label "$label" --jobs "$jobs" \
      --mode simple --fallback "$ADOPT_FALLBACK"
  fi
  echo
}

# adopt_switch <owner/repo> <label> <dry> <switch> <jobs>: sets CI_RUNNER to
# local through cmd_route when the routing is ready; otherwise prints what is
# missing and stops the command.
adopt_switch() {
  local repo="$1" label="$2" dry="$3" switch="$4" jobs="$5" current
  current="$(gh variable get CI_RUNNER --repo "$repo" 2>/dev/null || echo "(unset)")"
  if [ "$ADOPT_READY" = 1 ]; then
    if [ "$current" = local ]; then
      ADOPT_SWITCH_OUTCOME="is already local"
      log "switch: ${repo}: CI_RUNNER is already local; nothing to change"
    elif [ "$switch" = 0 ]; then
      ADOPT_SWITCH_OUTCOME="is ${current} (--no-switch)"
      log "switch: ${repo}: CI_RUNNER is ${current}; not switching (--no-switch)"
    elif [ "$dry" = 1 ]; then
      ADOPT_SWITCH_OUTCOME="would be set to local (dry run)"
      cmd_route local --repo "$repo" --label "$label" --dry-run
    else
      ADOPT_SWITCH_OUTCOME="set to local"
      cmd_route local --repo "$repo" --label "$label"
    fi
    return 0
  fi
  if [ "$current" = local ]; then
    adopt_warn "CI_RUNNER is already local on ${repo} although its routing is not in place; bin/homefield route hosted --repo ${repo} undoes that"
  fi
  adopt_snippets "$ADOPT_LABEL" "${jobs:-$(printf '%s' "$ADOPT_ROUTED" | tr '\n' ',')}"
  die "not switched: merge the routing first, then run homefield adopt again"
}

# adopt_verify_commands <owner/repo>: the check, for someone who does it by hand.
adopt_verify_commands() {
  log "to check that the jobs land on the local runner (docs/adopting.md, step 6), re-run the latest pull-request run of a workflow other than the routing guard (\"HomeField routing\": hosted by design) and read each job's runner:"
  echo "  gh run list --repo $1 --event pull_request --limit 15"
  echo "  gh run rerun <run-id> --repo $1"
}

adopt_verify_poll() {
  local repo="$1" id="$2" attempt="$3" tries=0 settled has_local label_lc _name jstatus _conclusion runner labels
  label_lc="$(printf '%s' "$ADOPT_LABEL" | tr '[:upper:]' '[:lower:]')"
  while :; do
    adopt_check_parent
    gh api --paginate "repos/${repo}/actions/runs/${id}/jobs?per_page=100" >"$ADOPT_TMP/v.json" 2>"$ADOPT_TMP/v.err" </dev/null || {
      adopt_warn "could not verify: gh could not list the jobs of run ${id}: $(head -1 "$ADOPT_TMP/v.err")"
      return 1
    }
    ADOPT_VERIFY_ROWS="$(python3 -I "$ROOT/tools/adopt.py" verify-jobs "$attempt" <"$ADOPT_TMP/v.json" 2>"$ADOPT_TMP/v.err")" || {
      adopt_warn "could not verify: gh gave a list of jobs that this tool cannot read ($(head -1 "$ADOPT_TMP/v.err"))"
      return 1
    }
    gh api "repos/${repo}/actions/runs/${id}" >"$ADOPT_TMP/v.json" 2>"$ADOPT_TMP/v.err" </dev/null || {
      adopt_warn "could not verify: gh could not read run ${id}: $(head -1 "$ADOPT_TMP/v.err")"
      return 1
    }
    ADOPT_VERIFY_RUN_STATUS="$(python3 -I "$ROOT/tools/adopt.py" verify-status <"$ADOPT_TMP/v.json" 2>"$ADOPT_TMP/v.err")" || {
      adopt_warn "could not verify: gh gave a run that this tool cannot read ($(head -1 "$ADOPT_TMP/v.err"))"
      return 1
    }
    settled=0
    has_local=0
    if [ -n "$ADOPT_VERIFY_ROWS" ]; then
      settled=1
      while IFS="$ADOPT_FS" read -r _name jstatus _conclusion runner labels; do
        if [ -z "$runner" ] && [ "$jstatus" != completed ]; then settled=0; fi
        case ",$(printf '%s' "$labels" | tr '[:upper:]' '[:lower:]')," in
          *",${label_lc},"*) has_local=1 ;;
        esac
      done <<<"$ADOPT_VERIFY_ROWS"
      if [ "$ADOPT_VERIFY_RUN_STATUS" != completed ] && [ "$has_local" = 0 ]; then settled=0; fi
    fi
    tries=$((tries + 1))
    [ "$settled" = 0 ] || break
    [ "$tries" -lt "$ADOPT_VERIFY_TRIES" ] || break
    adopt_nap "$ADOPT_VERIFY_INTERVAL"
  done
}

# adopt_verify_report: one line per row of ADOPT_VERIFY_ROWS, and a warning for
# each job that ran on a hosted runner. Everything here was read from the jobs
# API; nothing is assumed from the routing.
adopt_verify_report() {
  local label_lc name jstatus conclusion runner labels verb state
  local nlocal=0 nhosted=0 nwait=0 nnone=0 nfailed=0 budget=$((ADOPT_VERIFY_TRIES * ADOPT_VERIFY_INTERVAL))
  label_lc="$(printf '%s' "$ADOPT_LABEL" | tr '[:upper:]' '[:lower:]')"
  while IFS="$ADOPT_FS" read -r name jstatus conclusion runner labels; do
    if [ -z "$runner" ]; then
      if [ "$jstatus" = completed ]; then
        log "verify: ${name}: ${conclusion:-completed} without a runner"
        nnone=$((nnone + 1))
      else
        log "verify: ${name}: still waiting for a runner (${jstatus}) after ${budget} s; see \"Failure modes\" in docs/runbook.md"
        nwait=$((nwait + 1))
      fi
      continue
    fi
    verb="is running on"
    state="$jstatus"
    if [ "$jstatus" = completed ]; then
      verb="ran on"
      state="$conclusion"
    fi
    case ",$(printf '%s' "$labels" | tr '[:upper:]' '[:lower:]')," in
      *",${label_lc},"*)
        nlocal=$((nlocal + 1))
        case "$conclusion" in
          failure | timed_out | startup_failure)
            log "verify: ${name}: failed on the local runner ${runner} (${conclusion})"
            nfailed=$((nfailed + 1))
            ;;
          *) log "verify: ${name}: ${verb} the local runner ${runner} (${state})" ;;
        esac
        ;;
      *)
        nhosted=$((nhosted + 1))
        log "verify: ${name}: ${verb} a GitHub-hosted runner (${runner}; labels ${labels:-none})"
        adopt_warn "${name} did not run on the local runner. Either it stays hosted by design (docs/adopting.md, step 1), or the routing did not take effect for it: check its runs-on, that CI_RUNNER is local, and that the re-run workflow file has the merged routing (a re-run uses the files of the original commit)"
        ;;
    esac
  done <<<"$ADOPT_VERIFY_ROWS"
  log "verify: ${nlocal} on the local runner, ${nhosted} on GitHub-hosted runners, ${nwait} still waiting for a runner, ${nnone} without a runner"
  if [ "$nfailed" -gt 0 ]; then
    log "verify: a job that fails only on the local runner usually needs a tool the VM lacks: re-run it hosted to confirm, then add the tool or keep it hosted (docs/adopting.md, step 6, item 2; docs/runbook.md, \"Job fails only on the local runner\")"
  fi
}

# adopt_verify <owner/repo> <ask|yes|no> <dry> <switch>: offers, and on a yes
# does, the check described above. Only after a switch that happened (or a
# CI_RUNNER that already was local): with a dry run or --no-switch there is
# nothing new to check. Nothing here fails adopt, whose own work succeeded: a
# gh error is reported as "could not verify".
adopt_verify() {
  local repo="$1" mode="$2" dry="$3" switch="$4" answer="" row id jstatus url title attempt
  # Reached only with the routing ready (adopt_switch stops otherwise), so
  # CI_RUNNER is local now, or would be, or was left alone on request.
  if [ "$dry" = 1 ] || [ "$switch" = 0 ]; then
    if [ "$mode" = yes ]; then
      if [ "$dry" = 1 ]; then log "verify: skipped (dry run)"; else log "verify: skipped (--no-switch)"; fi
    fi
    return 0
  fi
  [ "$mode" != no ] || return 0
  if [ "$mode" = ask ]; then
    if have_terminal; then
      printf 'Re-run the latest pull-request run of %s (uses CI minutes) to confirm the local runner takes it? [y/N] ' "$repo" >&2
      # End of input (Ctrl-D) is not a yes.
      read -r answer || answer=""
    fi
    case "$answer" in
      [Yy]*) ;;
      *)
        adopt_verify_commands "$repo"
        return 0
        ;;
    esac
  fi

  gh run list --repo "$repo" --event pull_request --limit 1 --json databaseId,status,url,displayTitle,workflowName >"$ADOPT_TMP/v.json" 2>"$ADOPT_TMP/v.err" </dev/null || {
    adopt_warn "could not verify: gh could not list the runs of ${repo}: $(head -1 "$ADOPT_TMP/v.err")"
    return 0
  }
  row="$(python3 -I "$ROOT/tools/adopt.py" verify-run <"$ADOPT_TMP/v.json" 2>"$ADOPT_TMP/v.err")" || {
    adopt_warn "could not verify: gh gave a list of runs that this tool cannot read ($(head -1 "$ADOPT_TMP/v.err"))"
    return 0
  }
  IFS="$ADOPT_FS" read -r tag id jstatus url title <<<"$row"
  if [ "$tag" = "guard-only" ]; then
    # The newest pull-request run is the routing guard's own, which is hosted
    # by design (routing_workflow, tools/adopt.py): re-running it would prove
    # nothing and end in the hosted warning whatever the routing does. A run
    # of a real workflow may sit below it, which one row cannot show: fetch a
    # wider window before concluding there is nothing to re-run.
    gh run list --repo "$repo" --event pull_request --limit 15 --json databaseId,status,url,displayTitle,workflowName >"$ADOPT_TMP/v.json" 2>"$ADOPT_TMP/v.err" </dev/null || {
      adopt_warn "could not verify: gh could not list the runs of ${repo}: $(head -1 "$ADOPT_TMP/v.err")"
      return 0
    }
    row="$(python3 -I "$ROOT/tools/adopt.py" verify-run <"$ADOPT_TMP/v.json" 2>"$ADOPT_TMP/v.err")" || {
      adopt_warn "could not verify: gh gave a list of runs that this tool cannot read ($(head -1 "$ADOPT_TMP/v.err"))"
      return 0
    }
    IFS="$ADOPT_FS" read -r tag id jstatus url title <<<"$row"
  fi
  if [ -z "$row" ]; then
    log "verify: ${repo} has no pull-request run yet, so there is nothing to re-run. Open a pull request and look at where its jobs run (docs/adopting.md, step 6)"
    return 0
  fi
  if [ "$tag" = "guard-only" ]; then
    log "verify: the newest pull-request runs are all the routing guard's own (hosted by design), so there is nothing to re-run. Open a pull request on the repository and look at where its jobs run (docs/adopting.md, step 6)"
    return 0
  fi
  if [ "$jstatus" != completed ]; then
    log "verify: run ${id} (${title}) is still ${jstatus}, and a run can only be re-run once it has completed. Later: gh run rerun ${id} --repo ${repo}"
    return 0
  fi
  gh api "repos/${repo}/actions/runs/${id}" >"$ADOPT_TMP/v.json" 2>"$ADOPT_TMP/v.err" </dev/null || {
    adopt_warn "could not verify: gh could not read run ${id}: $(head -1 "$ADOPT_TMP/v.err")"
    return 0
  }
  attempt="$(python3 -I "$ROOT/tools/adopt.py" verify-attempt <"$ADOPT_TMP/v.json" 2>"$ADOPT_TMP/v.err")" || {
    adopt_warn "could not verify: gh gave a run that this tool cannot read ($(head -1 "$ADOPT_TMP/v.err"))"
    return 0
  }
  gh run rerun "$id" --repo "$repo" >/dev/null 2>"$ADOPT_TMP/v.err" </dev/null || {
    adopt_warn "could not verify: gh could not re-run run ${id}: $(head -1 "$ADOPT_TMP/v.err")"
    return 0
  }
  log "verify: re-running run ${id} (${title}), ${url}; waiting up to $((ADOPT_VERIFY_TRIES * ADOPT_VERIFY_INTERVAL)) s for its jobs to be picked up"
  adopt_verify_poll "$repo" "$id" "$attempt" || return 0
  if [ -z "$ADOPT_VERIFY_ROWS" ]; then
    adopt_warn "could not verify: no job of the re-run (attempt $((attempt + 1))) was listed in time; look at ${url}"
    return 0
  fi
  ADOPT_VERIFIED=1
  adopt_verify_report
  if [ "$ADOPT_VERIFY_RUN_STATUS" != completed ]; then
    log "verify: the run is still ${ADOPT_VERIFY_RUN_STATUS}: a job that starts only after others finish is not in this list yet; look at ${url}"
  fi
}

# adopt_setup_cleanup: a run that died after creating the branch would leave
# its commits on GitHub with no pull request to review, and would refuse its
# own retry on the existing branch. Take the branch back. A branch that
# already existed, one whose pull request was opened, and one whose pull
# request may be about to exist (the POST was in flight when the run was
# signalled: gh can still finish it, and deleting the branch would close it)
# are never touched.
adopt_setup_cleanup() {
  [ "$ADOPT_SETUP_BRANCH_MADE" = 1 ] && [ "$ADOPT_SETUP_PR_MADE" = 0 ] && [ "$ADOPT_SETUP_PR_PENDING" = 0 ] || return 0
  ADOPT_SETUP_BRANCH_MADE=0
  echo "homefield: removing ${SETUP_BRANCH} on ${ADOPT_SETUP_REPO}, which has no pull request" >&2
  gh api -X DELETE "repos/${ADOPT_SETUP_REPO}/git/refs/heads/${SETUP_BRANCH}" >/dev/null 2>&1 ||
    echo "homefield: could not remove ${SETUP_BRANCH} on ${ADOPT_SETUP_REPO} (it may not have been created): delete it by hand if it exists" >&2
}

# adopt_setup_exit: the EXIT trap of a --setup run. Besides the cleanup, a
# --wait run that fails once its pull request exists (a die in the wait, or
# anywhere after the merge) exits ADOPT_EXIT_OPEN or ADOPT_EXIT_MERGED instead
# of 1, so a caller can tell it from a run that opened nothing.
adopt_setup_exit() {
  local rc=$?
  adopt_setup_cleanup
  rm -rf "$ADOPT_TMP"
  [ "$rc" -ne 0 ] && [ "$rc" -ne 130 ] && [ "$rc" -ne 143 ] &&
    [ "$ADOPT_WAIT" = 1 ] && [ "$ADOPT_SETUP_PR_MADE" = 1 ] || return 0
  if [ "$ADOPT_WAIT_MERGED" = 1 ]; then exit "$ADOPT_EXIT_MERGED"; fi
  exit "$ADOPT_EXIT_OPEN"
}

# adopt_workflow_scope: whether the token gh will use may write files under
# .github/workflows/. GitHub requires a classic PAT's workflow scope for
# Contents writes there and answers a bare 404 without it (#165): the same
# token writes everywhere else in the repository, so the failure reads as
# "not found" when it means "not allowed". Only a scope list GitHub reports
# proves anything; a login whose scopes are not reported (an App or
# fine-grained token), an env-var token, or a gh that cannot answer cannot be
# judged, and must not be read as "missing". 0 = proven present, 1 = proven
# absent, 2 = cannot tell.
adopt_workflow_scope() {
  local account scopes
  if [ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ]; then
    # gh uses the variable instead of its stored login, and gh's status does
    # not answer for it; what the token may do is told by the write itself.
    return 2
  fi
  account="$(gh_active_account)" || return 2
  scopes="${account#*|}"
  [ -n "$scopes" ] || return 2
  case ",$scopes," in
    *,workflow,*) return 0 ;;
    *) return 1 ;;
  esac
}

# adopt_write_denied <name> <repo> <errfile>: the message for a failed
# Contents write. A 404 here means "not allowed": GitHub answers one when the
# token lacks the workflow scope, which Contents writes under
# .github/workflows/ need, though the same token writes everywhere else
# (#165) — the preflight above catches a scope it can see missing, this
# catches the tokens it cannot (an env-var token, one that reports no
# scopes). The branch goes back through the EXIT trap. This is a plain
# message, not a block on the write: a `cmd || { ... }` here defers the
# pending INT trap past die, and a Ctrl-C mid-write would end the run
# without its interrupted note (the adopt.sh interrupt tests caught it).
adopt_write_denied() {
  if grep -q 404 "$3"; then
    printf 'adopt: setup: GitHub refused to write .github/workflows/%s (404): the token gh is using most likely lacks the workflow scope, which Contents writes under .github/workflows/ need. Add it to gh%s login: gh auth refresh -h github.com -s workflow (a GITHUB_TOKEN or GH_TOKEN must carry the scope itself)\n' "$1" "'"
  else
    printf 'adopt: setup: could not write .github/workflows/%s to %s on %s: %s\n' "$1" "${SETUP_BRANCH}" "$2" "$(head -1 "$3")"
  fi
}

# adopt_setup <owner/repo> <label> <jobs> <dry>: the --setup path, the
# workflow edits of docs/adopting.md steps 1-4 opened as a pull request. The
# plan comes from tools/adopt.py setup over the same downloaded workflows a
# normal adopt checks; it is verified with routing_guard.py before anything
# leaves the Mac, then written to SETUP_BRANCH through the Contents API and
# opened with POST /pulls. Nothing here touches the runner group or CI_RUNNER:
# that is step 5, after the pull request is merged. Needs gh with write access
# to the repository; needs no VM.
#
# The expression's shape (--mode): --guards asks for the guarded one; without
# it, a guard already in the repository keeps its own shape and a repository
# without one gets simple — the shape a personal repository reads at a
# glance. events and dependabot have no effect in simple mode, which routes
# every event, so they are refused there.
# State adopt_setup's helpers hand each other: ADOPT_SETUP_EXPR, the
# expression tools/adopt.py setup writes into the workflows; ADOPT_SETUP_OPTS,
# its options; ADOPT_SETUP_GOPTS, the options the guard check of the staged
# files runs with; and the plan's outcome, ADOPT_SETUP_ROUTED (the planned
# jobs, comma-joined) and ADOPT_SETUP_FILES (the files it touches, one per
# line). The caller's summary and the interrupt handler read
# ADOPT_SETUP_ROUTED too.
ADOPT_SETUP_EXPR=""
ADOPT_SETUP_OPTS=()
ADOPT_SETUP_GOPTS=()
ADOPT_SETUP_ROUTED=""
ADOPT_SETUP_FILES=""

# adopt_setup_expression <label>: resolves the expression's shape and the
# routing_guard.py invocations the plan and its check run with, into
# ADOPT_SETUP_EXPR, ADOPT_SETUP_OPTS and ADOPT_SETUP_GOPTS. The shape
# (--mode): --guards asks for the guarded one; without it, a guard
# already in the repository keeps its own shape and a repository without one
# gets simple — the shape a personal repository reads at a glance. events and
# dependabot have no effect in simple mode, which routes every event, so they
# are refused there. Dies when the options cannot be routed on.
adopt_setup_expression() {
  local label="$1" mode expr
  local opts=(--label "$label") gopts
  if [ "$ADOPT_FLAG_GUARDS" = 1 ]; then
    mode=guards
  else
    mode="$(python3 -I "$ROOT/tools/adopt.py" guards "$ADOPT_TMP/workflows" |
      awk -F'\t' '$2 == "ok" { print $10; exit }')" ||
    die "adopt: setup: could not read the downloaded workflows"
    mode="${mode:-simple}"
  fi
  if [ "$mode" = guards ]; then
    expr="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --print-expression --label "$label" \
      --events "${ADOPT_FLAG_EVENTS:-pull_request}" --dependabot "${ADOPT_FLAG_DEPENDABOT:-hosted}" \
      --fallback "${ADOPT_FLAG_FALLBACK:-ubuntu-latest}" 2>&1)" ||
      die "adopt: the routing options cannot be routed on: $(printf '%s' "$expr" | sed $'s/\033\\[[0-9;]*m//g')"
    [ -z "$ADOPT_FLAG_EVENTS" ] || opts+=(--events "$ADOPT_FLAG_EVENTS")
    [ -z "$ADOPT_FLAG_DEPENDABOT" ] || opts+=(--dependabot "$ADOPT_FLAG_DEPENDABOT")
  else
    if [ -n "$ADOPT_FLAG_EVENTS" ] || [ -n "$ADOPT_FLAG_DEPENDABOT" ]; then
      die "adopt: --events and --dependabot have no effect in simple mode, which routes every event; drop them, or pass --guards for the guarded expression"
    fi
    expr="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --print-expression --mode simple --label "$label" \
      --fallback "${ADOPT_FLAG_FALLBACK:-ubuntu-latest}" 2>&1)" ||
      die "adopt: the routing options cannot be routed on: $(printf '%s' "$expr" | sed $'s/\033\\[[0-9;]*m//g')"
  fi
  [ -z "$ADOPT_FLAG_FALLBACK" ] || opts+=(--fallback "$ADOPT_FLAG_FALLBACK")
  opts+=(--mode "$mode")
  # The guard check runs the way the generated step will: with the mode, and
  # without events/dependabot in simple mode, which refuses them.
  gopts=(--label "$label" --mode "$mode")
  if [ "$mode" = guards ]; then
    gopts+=(--events "${ADOPT_FLAG_EVENTS:-pull_request}" --dependabot "${ADOPT_FLAG_DEPENDABOT:-hosted}")
  fi
  gopts+=(--fallback "${ADOPT_FLAG_FALLBACK:-ubuntu-latest}")
  ADOPT_SETUP_EXPR="$expr"
  ADOPT_SETUP_OPTS=("${opts[@]}")
  ADOPT_SETUP_GOPTS=("${gopts[@]}")
}

# adopt_setup_plan <jobs>: runs tools/adopt.py setup over the downloaded
# workflows with ADOPT_SETUP_EXPR and ADOPT_SETUP_OPTS, into $ADOPT_TMP/setup,
# and reads its plan into ADOPT_SETUP_ROUTED and ADOPT_SETUP_FILES. Dies when
# nothing was planned; warns the plan's own lines (setup-err), and logs the
# routes and the files it will change.
adopt_setup_plan() {
  local jobs="$1" setup="$ADOPT_TMP/setup" plan kind value name
  local routed="" files=""
  plan="$(python3 -I "$ROOT/tools/adopt.py" setup "$ADOPT_TMP/workflows" "$setup" \
    --expression "$ADOPT_SETUP_EXPR" --jobs "$jobs" "${ADOPT_SETUP_OPTS[@]}" 2>"$ADOPT_TMP/setup-err")" ||
    die "adopt: setup: $(head -1 "$ADOPT_TMP/setup-err")"
  while IFS=$'\t' read -r kind value; do
    case "$kind" in
      ROUTED) routed="${routed:+${routed},}${value}" ;;
      FILE) files="${files}${value}"$'\n' ;;
    esac
  done <<<"$plan"
  [ -n "$routed" ] || die "adopt: setup: no job was planned; run bin/homefield adopt without --setup to see why"
  while IFS= read -r line; do adopt_warn "$line"; done <"$ADOPT_TMP/setup-err"
  ADOPT_SETUP_ROUTED="$routed"
  ADOPT_SETUP_FILES="$files"
  log "setup: routes $(printf '%s' "$routed" | tr ',' ' ')"
  while IFS= read -r name; do
    [ -n "$name" ] && log "setup: changes .github/workflows/${name}"
  done <<<"$files"
  # The file list's trailing empty line makes the loop above end with the
  # failed test of it; the run goes on, so the status is not the plan's.
  return 0
}

# adopt_setup_check <repo> <dir>: checks the staged files in dir with the very
# script the guard step runs (ADOPT_SETUP_GOPTS, ADOPT_SETUP_ROUTED), so
# merging what we generate cannot fail CI on routing. Dies, printing the
# guard's failures, when they would not pass.
adopt_setup_check() {
  local repo="$1" dir="$2" check
  check="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --workflows-dir "$dir" "${ADOPT_SETUP_GOPTS[@]}" --jobs "$ADOPT_SETUP_ROUTED" 2>&1)" || {
    printf '%s\n' "$check" | sed $'s/\033\\[[0-9;]*m//g' |
      grep -v -e PASS -e '^self-hosted runner routing' -e ' passed, ' -e '^$' >&2 || true
    die "adopt: setup: the generated workflows would fail the routing guard; nothing was sent to ${repo}"
  }
}

# adopt_setup_scope: the Contents writes of a --setup run need the workflow
# scope of a classic PAT, and GitHub answers a bare 404 without it (#165): the
# same token writes everywhere else. A scope proven absent stops here, before
# the branch exists; one that cannot be told goes on, and the write's own 404
# below says so.
adopt_setup_scope() {
  local ws=0
  adopt_workflow_scope || ws=$?
  if [ "$ws" = 1 ]; then
    die "adopt: setup: gh's active login has no workflow scope, and writing .github/workflows/ needs it (a bare 404 is all GitHub says): gh auth refresh -h github.com -s workflow, then run this again"
  fi
}

# adopt_setup_branch <repo>: creates SETUP_BRANCH from ADOPT_BRANCH, after
# reading the head commit and refusing a branch that is already there. The
# cleanup is armed before the call: a signal while it is in flight can find gh
# finishing it, and the branch would be left with no one to remove it. Where
# gh was killed before it created the ref, the cleanup's delete finds nothing,
# and says so. Sets ADOPT_SETUP_BRANCH_MADE for the trap.
adopt_setup_branch() {
  local repo="$1" head_sha
  head_sha="$(gh api "repos/${repo}/commits/${ADOPT_BRANCH}" --jq .sha 2>"$ADOPT_TMP/err")" ||
    die "adopt: setup: could not read ${ADOPT_BRANCH} on ${repo}: $(head -1 "$ADOPT_TMP/err")"
  if gh api "repos/${repo}/git/ref/heads/${SETUP_BRANCH}" --jq .object.sha >/dev/null 2>&1; then
    die "adopt: setup: the branch ${SETUP_BRANCH} already exists on ${repo}: merge or close its pull request, or delete the branch, and run again"
  fi
  ADOPT_SETUP_BRANCH_MADE=1
  trap adopt_setup_exit EXIT
  gh api -X POST "repos/${repo}/git/refs" -f ref="refs/heads/${SETUP_BRANCH}" -f sha="$head_sha" >/dev/null || {
    ADOPT_SETUP_BRANCH_MADE=0
    die "adopt: setup: could not create ${SETUP_BRANCH} on ${repo}"
  }
  log "setup: created ${SETUP_BRANCH} from ${ADOPT_BRANCH}"
}

# adopt_setup_write_files <repo> <dir>: writes every file of ADOPT_SETUP_FILES
# to SETUP_BRANCH through the Contents API.
adopt_setup_write_files() {
  local repo="$1" dir="$2" name enc sha
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    enc="$(python3 -I "$ROOT/tools/adopt.py" quote "$name" </dev/null)" ||
      die "adopt: setup: could not quote the workflow name ${name}"
    # A workflow that does not exist on the branch yet (the new guard file)
    # has no sha to update, and the Contents API creates it. -X GET matters:
    # -f alone would switch gh api to POST, which never answers this lookup.
    sha="$(gh api -X GET "repos/${repo}/contents/.github/workflows/${enc}" -f ref="$SETUP_BRANCH" --jq .sha 2>/dev/null)" || sha=""
    python3 -I "$ROOT/tools/adopt.py" contents-payload "$dir/$name" "${sha:-none}" "$SETUP_MSG" "$SETUP_BRANCH" \
      >"$ADOPT_TMP/put.json" || die "adopt: setup: could not stage .github/workflows/${name}"
    gh api -X PUT "repos/${repo}/contents/.github/workflows/${enc}" --input "$ADOPT_TMP/put.json" >/dev/null 2>"$ADOPT_TMP/err" ||
      die "$(adopt_write_denied "$name" "$repo" "$ADOPT_TMP/err")"
    log "setup: wrote .github/workflows/${name}"
  done <<<"$ADOPT_SETUP_FILES"
}

# adopt_setup_pr <repo> <label>: opens the pull request whose body lists
# ADOPT_SETUP_ROUTED, sets the ADOPT_SETUP_PR_* state the interrupt handler
# and the EXIT trap read, and logs what comes next.
adopt_setup_pr() {
  local repo="$1" label="$2" url body
  # shellcheck disable=SC2016  # `${{ runner.arch }}` is literal text for the PR body, not this shell's
  body="$(printf 'This PR routes these jobs to the local HomeField runner. See [docs/adopting.md](docs/adopting.md).\n\n%s\n\nGenerated by `homefield adopt --repo %s --setup`:\n\n- Every routed job now carries the canonical `runs-on` expression for label %s (docs/adopting.md, step 2).\n- The routing guard lists exactly these jobs (step 3).\n- Cache keys in the routed files that were built from `runner.os` gained `${{ runner.arch }}` (step 4).\n\nNothing is switched on by this PR: `CI_RUNNER` stays unset, so everything runs hosted. After merging, `%s` adds the repository to the runner group and routes (step 5); if the `--wait` run that opened this PR is still going, it does that for you.\n' \
    "$(printf '%s\n' "$ADOPT_SETUP_ROUTED" | tr ',' '\n' | sed 's/^/- /')" "$repo" "$label" "$ADOPT_PLAIN_CMD")"
  ADOPT_SETUP_PR_PENDING=1
  url="$(gh api -X POST "repos/${repo}/pulls" -f title="$SETUP_MSG" -f head="$SETUP_BRANCH" -f base="$ADOPT_BRANCH" -f body="$body" --jq .html_url 2>"$ADOPT_TMP/err")" || {
    ADOPT_SETUP_PR_PENDING=0
    die "adopt: setup: could not open the pull request on ${repo}: $(head -1 "$ADOPT_TMP/err")"
  }
  ADOPT_SETUP_PR_MADE=1
  ADOPT_SETUP_PR_PENDING=0
  ADOPT_SETUP_PR_URL="$url"
  ADOPT_SETUP_PR_NUMBER="${url##*/}"
  log "created pull request: ${url}"
  if [ "$ADOPT_WAIT" = 1 ]; then
    log "next: review and merge it; this run waits for that"
  else
    log "next: review and merge it, then ${ADOPT_PLAIN_CMD} (docs/adopting.md, step 5); adopt --setup --wait does both in one run"
  fi
}

# adopt_setup <owner/repo> <label> <jobs> <dry>: the --setup path, the
# workflow edits of docs/adopting.md steps 1-4 opened as a pull request. The
# plan comes from tools/adopt.py setup over the same downloaded workflows a
# normal adopt checks; it is verified with routing_guard.py before anything
# leaves the Mac, then written to SETUP_BRANCH through the Contents API and
# opened with POST /pulls. Nothing here touches the runner group or CI_RUNNER:
# that is step 5, after the pull request is merged. Needs gh with write access
# to the repository; needs no VM. The work goes to adopt_setup_expression,
# adopt_setup_plan, adopt_setup_check, adopt_setup_scope, adopt_setup_branch,
# adopt_setup_write_files and adopt_setup_pr, which hand each other the
# ADOPT_SETUP_* state above.
adopt_setup() {
  local repo="$1" label="$2" jobs="$3" dry="$4"
  local setup="$ADOPT_TMP/setup"
  adopt_setup_expression "$label"
  ADOPT_SETUP_REPO="$repo"
  adopt_setup_plan "$jobs"
  adopt_setup_check "$repo" "$setup"
  if [ "$dry" = 1 ]; then
    log "setup: dry run: nothing was sent to ${repo}"
    return 0
  fi
  adopt_setup_scope
  adopt_setup_branch "$repo"
  adopt_setup_write_files "$repo" "$setup"
  adopt_setup_pr "$repo" "$label"
}

# adopt_interrupted <status> [parent]: Ctrl-C or SIGTERM during a --setup run
# (cmd_adopt installs it for INT and TERM, so it runs in every phase), or, with
# "parent", setup having gone away (adopt_check_parent). It says where things
# stand, which depends on how far the run got, and exits with <status>; the EXIT
# trap (adopt_setup_exit) keeps 130 and 143, and takes back a branch that has
# no pull request. Every statement below holds for its phase, and none is made
# for a phase that cannot be told apart: a pull request being opened may exist.
# A second signal (a double Ctrl-C, INT then TERM) ends the run at once and
# silently with the first signal's status: the note is not printed twice, and a
# cleanup call that hangs can still be aborted.
adopt_interrupted() {
  local status="$1" lead="interrupted"
  # expanded now, so that the first status wins
  # shellcheck disable=SC2064
  trap "exit $status" INT TERM
  if [ -n "$ADOPT_WAIT_SLEEPER" ]; then
    # it may have ended on its own just now
    kill "$ADOPT_WAIT_SLEEPER" 2>/dev/null || :
  fi
  [ "${2:-}" != parent ] || lead="setup has ended, so adopt stopped"
  echo >&2
  if [ "$ADOPT_SWITCH_DONE" = 1 ]; then
    # ADOPT_SWITCH_OUTCOME is set before the switch runs, so only this flag,
    # set once adopt_switch returned, says that it is over.
    echo "homefield: ${lead} after its work was done (runner group ${ADOPT_GROUP_OUTCOME}; routing ready; CI_RUNNER ${ADOPT_SWITCH_OUTCOME}). Only the optional check that the jobs land on the local runner was cut short, and a re-run of the latest run may be in flight. To check by hand:" >&2
    adopt_verify_commands "$ADOPT_SETUP_REPO" >&2
  elif [ "$ADOPT_WAIT_MERGED" = 1 ]; then
    echo "homefield: ${lead} after ${ADOPT_SETUP_PR_URL} was merged, before adopt finished: ${ADOPT_SETUP_REPO} may or may not have been added to the runner group, and CI_RUNNER may or may not be set. Run again to finish (it is safe to repeat): ${ADOPT_PLAIN_CMD}" >&2
  elif [ "$ADOPT_SETUP_PR_MADE" = 1 ] && [ "$ADOPT_WAIT" = 1 ]; then
    echo "homefield: ${lead} while waiting for ${ADOPT_SETUP_PR_URL}. It and its branch are untouched, and nothing was switched or added to the runner group. Once it is merged, run: ${ADOPT_PLAIN_CMD}" >&2
  elif [ "$ADOPT_SETUP_PR_MADE" = 1 ]; then
    echo "homefield: ${lead} after opening ${ADOPT_SETUP_PR_URL}. It and its branch are untouched, and nothing was switched or added to the runner group. Once it is merged, run: ${ADOPT_PLAIN_CMD}" >&2
  elif [ "$ADOPT_SETUP_PR_PENDING" = 1 ]; then
    echo "homefield: ${lead} while the pull request was being opened; it may exist: look at https://github.com/${ADOPT_SETUP_REPO}/pulls. If there is none, delete the branch (gh api -X DELETE repos/${ADOPT_SETUP_REPO}/git/refs/heads/${SETUP_BRANCH}) and run again. The branch was left in place. Nothing was switched or added to the runner group." >&2
  else
    echo "homefield: ${lead} before the pull request was opened. Nothing was switched or added to the runner group." >&2
  fi
  exit "$status"
}

# adopt_check_parent: when setup started this adopt (ADOPT_PARENT_PID) and has
# ended, stop. A SIGTERM sent to setup alone ends setup at once (it cannot act
# on the signal while its foreground subshell runs, so it traps nothing) and
# leaves this adopt, which would wait for the merge for up to an hour. The poll
# loops call this, so adopt notices within one poll interval; a step already in
# progress (the group access, the switch) finishes first. A parent that is
# killed but not yet reaped is a zombie that still answers kill -0, so its
# state is read too (no ps, or no answer from it, is "not a zombie").
adopt_check_parent() {
  local stat
  [ -n "$ADOPT_PARENT_PID" ] || return 0
  kill -0 "$ADOPT_PARENT_PID" 2>/dev/null || adopt_interrupted 143 parent
  stat="$(ps -o stat= -p "$ADOPT_PARENT_PID" 2>/dev/null)" || stat=""
  stat="${stat#"${stat%%[! ]*}"}"
  case "$stat" in Z*) adopt_interrupted 143 parent ;; esac
}

# adopt_nap <seconds>: sleep that a trapped signal cuts short. Bash runs a trap
# only after a foreground command ends, but cuts a wait short, so with the
# handler installed (a --setup run) the sleep is a background job that is
# waited for, which the handler takes down. Without it (a plain adopt, whose
# Ctrl-C kills the shell) it stays in the foreground: a background job of a
# non-interactive shell ignores SIGINT, and would outlive the shell holding its
# stdout open.
adopt_nap() {
  if [ "$ADOPT_HANDLER" = 1 ]; then
    sleep "$1" &
    ADOPT_WAIT_SLEEPER=$!
    wait "$ADOPT_WAIT_SLEEPER" || :
    ADOPT_WAIT_SLEEPER=""
  else
    sleep "$1"
  fi
}

# adopt_wait_merged <owner/repo> <minutes>: until the pull request adopt_setup
# opened is merged, reading it every ADOPT_WAIT_INTERVAL seconds for about
# that many minutes. Returns once merged; otherwise ends the run (a pull
# request closed without a merge, one still open at the timeout, or a state
# that stayed unreadable for 5 reads in a row). One failed read is not an
# answer: the network or the API can blip, and a pull request that is not
# known to be closed must not be reported closed.
adopt_wait_merged() {
  local repo="$1" minutes="$2" interval="$ADOPT_WAIT_INTERVAL"
  local url="$ADOPT_SETUP_PR_URL" number="$ADOPT_SETUP_PR_NUMBER"
  local tries per_minute polls=0 failures=0 row state merged reason
  local hand="$ADOPT_PLAIN_CMD"
  [[ "$number" =~ ^[0-9]+$ ]] ||
    die "adopt: setup: could not read the pull request number from ${url}, so --wait cannot follow it; once it is merged, run: ${hand}"
  tries=$((minutes * 60 / (interval > 0 ? interval : 1)))
  [ "$tries" -ge 1 ] || tries=1
  # an if, not a ?: in $(( )): bash 3.2 divides by zero in the branch not taken
  if [ "$interval" -gt 0 ]; then per_minute=$((60 / interval)); else per_minute=60; fi
  [ "$per_minute" -ge 1 ] || per_minute=1
  log "waiting for ${url} to be merged (up to ${minutes} min). Ctrl-C is safe: nothing is switched while waiting, and you can carry on by hand once it is merged: ${hand}"
  while :; do
    adopt_check_parent
    polls=$((polls + 1))
    # An answer is a state of open or closed and a merged_at (or "-"), tab-separated.
    if row="$(gh api "repos/${repo}/pulls/${number}" --jq '[.state, (.merged_at // "-")] | @tsv' 2>"$ADOPT_TMP/err" </dev/null)" &&
      state="${row%%$'\t'*}" && merged="${row#*$'\t'}" && [ "$merged" != "$row" ] &&
      { [ "$state" = open ] || [ "$state" = closed ]; }; then
      failures=0
      if [ "$merged" != "-" ]; then
        break
      elif [ "$state" = closed ]; then
        die "adopt: ${url} was closed without being merged. Nothing was switched and no group access was changed. Its branch ${SETUP_BRANCH} is still there: delete it before running --setup again"
      fi
    else
      failures=$((failures + 1))
      if [ "$failures" -ge 5 ]; then
        reason="$(head -1 "$ADOPT_TMP/err")"
        die "adopt: could not read the state of ${url}: 5 reads in a row failed (${reason:-an answer this tool cannot read: ${row:-none}}). Nothing was switched. Once it is merged, run: ${hand}"
      fi
    fi
    if [ "$polls" -ge "$tries" ]; then
      die "adopt: ${url} is still open after ${minutes} min. Nothing was switched and no group access was changed. Once it is merged, run: ${hand}"
    fi
    if [ $((polls % per_minute)) -eq 0 ]; then
      log "still waiting for ${url} to be merged ($((polls * interval / 60)) of ${minutes} min)"
    fi
    if [ "$interval" -gt 0 ]; then adopt_nap "$interval"; fi
  done
  ADOPT_WAIT_MERGED=1
  log "${url} is merged; carrying on with what adopt does after the merge"
}

cmd_adopt() {
  local repo="" nrepo=0 label="homefield-ci" label_given=0 group="homefield-ci" jobs="" switch=1 dry=0 setup=0 entry out
  local verify=ask
  local wait_timeout="" wait_minutes=60
  ADOPT_FLAG_EVENTS="" ADOPT_FLAG_DEPENDABOT="" ADOPT_FLAG_FALLBACK="" ADOPT_FLAG_GUARDS=0
  ADOPT_WAIT=0 ADOPT_WAIT_MERGED=0 ADOPT_SWITCH_DONE=0 ADOPT_HANDLER=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:?--repo needs a value}"; nrepo=$((nrepo + 1)); shift 2 ;;
      --label) label="${2:?--label needs a value}"; label_given=1; shift 2 ;;
      --events) ADOPT_FLAG_EVENTS="${2:?--events needs a value}"; shift 2 ;;
      --dependabot) ADOPT_FLAG_DEPENDABOT="${2:?--dependabot needs a value}"; shift 2 ;;
      --fallback) ADOPT_FLAG_FALLBACK="${2:?--fallback needs a value}"; shift 2 ;;
      --guards) ADOPT_FLAG_GUARDS=1; shift ;;
      --group) group="${2:?--group needs a value}"; shift 2 ;;
      --jobs) jobs="${2:?--jobs needs a value}"; shift 2 ;;
      --setup) setup=1; shift ;;
      --wait) ADOPT_WAIT=1; shift ;;
      --wait-timeout) wait_timeout="${2:?--wait-timeout needs a value}"; shift 2 ;;
      --no-switch) switch=0; shift ;;
      --dry-run) dry=1; shift ;;
      --verify) [ "$verify" != no ] || die "adopt: --verify and --no-verify contradict each other"; verify=yes; shift ;;
      --no-verify) [ "$verify" != yes ] || die "adopt: --verify and --no-verify contradict each other"; verify=no; shift ;;
      *) die "adopt: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  [ "$nrepo" -gt 0 ] || die "adopt: --repo <owner>/<repo> is required"
  [ "$nrepo" -eq 1 ] || die "adopt: one --repo at a time"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "adopt: --repo must be <owner>/<repo>, got: $repo"
  [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || die "adopt: --label must be one label"
  [ -n "$group" ] || die "adopt: --group needs a name"
  ADOPT_PLAIN_CMD="homefield adopt --repo $(printf '%q' "$repo")"
  [ "$label_given" = 0 ] || ADOPT_PLAIN_CMD="$ADOPT_PLAIN_CMD --label $(printf '%q' "$label")"
  [ "$group" = homefield-ci ] || ADOPT_PLAIN_CMD="$ADOPT_PLAIN_CMD --group $(printf '%q' "$group")"
  if [ -n "$wait_timeout" ]; then
    [[ "$wait_timeout" =~ ^[1-9][0-9]{0,5}$ ]] || die "adopt: --wait-timeout is a whole number of minutes, 1 or more; got: $wait_timeout"
    [ "$ADOPT_WAIT" = 1 ] || die "adopt: --wait-timeout only goes with --wait"
    wait_minutes="$wait_timeout"
  fi
  if [ "$ADOPT_WAIT" = 1 ] && [ "$setup" = 0 ]; then
    die "adopt: --wait goes with --setup: it waits for the pull request that --setup opens. For a pull request you opened yourself, merge it and run: ${ADOPT_PLAIN_CMD}"
  fi
  for entry in $(printf '%s' "$jobs" | tr ',' ' '); do
    [[ "$entry" =~ ^[A-Za-z0-9._-]+\.ya?ml:[A-Za-z0-9_-]+$ ]] || die "adopt: --jobs entries are <workflow-file>:<job-id>, such as ci.yml:lint; got: $entry"
  done
  command -v gh >/dev/null || die "adopt needs gh (https://cli.github.com)"
  command -v python3 >/dev/null || die "adopt needs python3"
  # The same label and option rules as the guard, and a message from it when
  # they fail. The shape is resolved later — an existing guard's own mode wins
  # over the default — so both validators run here: the simple one always
  # (it checks the label and the fallback), the guards one when --events or
  # --dependabot was given (their syntax is checked there too).
  out="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --print-expression --mode simple --label "$label" \
    --fallback "${ADOPT_FLAG_FALLBACK:-ubuntu-latest}" 2>&1)" ||
    die "adopt: the routing options cannot be routed on: $(printf '%s' "$out" | sed $'s/\033\\[[0-9;]*m//g')"
  if [ -n "$ADOPT_FLAG_EVENTS$ADOPT_FLAG_DEPENDABOT" ]; then
    out="$(python3 -I "$ROOT/routing-guard/routing_guard.py" --print-expression --label "$label" \
      --events "${ADOPT_FLAG_EVENTS:-pull_request}" --dependabot "${ADOPT_FLAG_DEPENDABOT:-hosted}" \
      --fallback "${ADOPT_FLAG_FALLBACK:-ubuntu-latest}" 2>&1)" ||
      die "adopt: the routing options cannot be routed on: $(printf '%s' "$out" | sed $'s/\033\\[[0-9;]*m//g')"
  fi
  [ "$dry" = 0 ] || log "dry run: nothing will be changed"

  ADOPT_TMP="$(mktemp -d)"
  trap 'rm -rf "$ADOPT_TMP"' EXIT
  if [ "$setup" = 1 ]; then
    # Ctrl-C and SIGTERM end a --setup run in any phase with a note that says
    # where things stand and exit 130 or 143 (adopt_interrupted), instead of
    # dying by the default action with no word. A plain adopt changes nothing
    # on GitHub before its group access, and keeps the default.
    trap 'adopt_interrupted 130' INT
    trap 'adopt_interrupted 143' TERM
    ADOPT_HANDLER=1
  fi
  adopt_repository "$repo"
  adopt_fetch_workflows "$repo" "$ADOPT_BRANCH" "$ADOPT_TMP/workflows"
  if [ "$setup" = 1 ]; then
    # --setup stops at the pull request: steps 1-4 as a review, no group
    # access and no switch, which stay the plain adopt run of step 5. With
    # --wait that run follows in this process once the pull request is merged:
    # the workflows are read again, at the default branch, and everything
    # below is what a plain adopt does.
    adopt_setup "$repo" "$label" "$jobs" "$dry"
    if [ "$ADOPT_WAIT" = 0 ]; then
      return 0
    elif [ "$dry" = 1 ]; then
      log "dry run: --wait has nothing to wait for, as no pull request was opened"
      return 0
    fi
    adopt_wait_merged "$repo" "$wait_minutes"
    rm -rf "${ADOPT_TMP:?}/workflows"
    adopt_repository "$repo"
    adopt_fetch_workflows "$repo" "$ADOPT_BRANCH" "$ADOPT_TMP/workflows"
  fi
  adopt_routing_check "$ADOPT_TMP/workflows" "$label" "$label_given"
  adopt_cache_keys "$ADOPT_TMP/workflows"
  adopt_fallback "$ADOPT_FALLBACK"
  adopt_group_access "$repo" "$group" "$dry"
  adopt_switch "$repo" "$ADOPT_LABEL" "$dry" "$switch" "$jobs"
  ADOPT_SWITCH_DONE=1

  log "done: ${repo}: runner group ${ADOPT_GROUP_OUTCOME}; routing ready; CI_RUNNER ${ADOPT_SWITCH_OUTCOME}"
  adopt_verify "$repo" "$verify" "$dry" "$switch"
  if [ "$ADOPT_VERIFIED" = 1 ]; then
    log "still by hand: add any tools the jobs lack, and note why a job stays hosted if you want to (docs/adopting.md, step 7)"
  else
    log "still by hand: open a pull request and check the jobs ran on the local runner, add any tools they lack, and note why a job stays hosted if you want to (docs/adopting.md, steps 6 and 7)"
  fi
}

# 1 once a report of the jobs was printed (what the last line of adopt says).
ADOPT_VERIFIED=0
# The field separator of tools/adopt.py verify-*: not whitespace, so `read`
# keeps an empty field (a job no runner has taken) in its place.
ADOPT_FS=$'\x1f'
ADOPT_VERIFY_ROWS=""



# adopt_verify_poll <owner/repo> <run-id> <attempt>: reads the jobs of the
# re-run (every job whose run_attempt is greater than <attempt>) into
# ADOPT_VERIFY_ROWS until each has a runner or is completed, or the tries run
# out. Jobs of the previous attempt can still be listed just after the re-run;
# verify-jobs leaves them out. A job behind another one (a reusable workflow
# called after a job it needs) may not be listed until that one is done, so while
# the run is still going the poll does not settle before a job that asked for
# the routing label is listed: a hosted job alone says nothing about the
# routing. The run's status is read each time, into ADOPT_VERIFY_RUN_STATUS.
# Returns 1, after saying why, when gh or the answer fails.
ADOPT_VERIFY_RUN_STATUS=""




# The branch `adopt --setup` writes its pull request from (#124). A fixed
# name keeps a re-run pointed at the same pull request; an existing branch is
# refused rather than rewritten.
SETUP_BRANCH="homefield/route-to-local"
SETUP_MSG="Route CI jobs to the local HomeField runner"


# adopt_verify (#149) is docs/adopting.md step 6 done for you: it re-runs the
# repository's latest pull-request run and reports, from the jobs API, where
# each job landed. A job counts as local when the labels it asked for hold the
# routing label: adopt works from any machine, so the runner's name is not
# looked up in the VM. ADOPT_VERIFY_TRIES and ADOPT_VERIFY_INTERVAL are seams
# for the tests, as ONLINE_WAIT_TRIES and ONLINE_WAIT_INTERVAL are.
ADOPT_VERIFY_TRIES=${ADOPT_VERIFY_TRIES:-18}
ADOPT_VERIFY_INTERVAL=${ADOPT_VERIFY_INTERVAL:-10}
# What adopt_setup has done so far, for the EXIT cleanup it installs.
ADOPT_SETUP_REPO=""
# the plain adopt to run once the routing pull request is merged: this run's
# repo, and its --label and --group when given (cmd_adopt sets it)
ADOPT_PLAIN_CMD=""
ADOPT_SETUP_BRANCH_MADE=0
ADOPT_SETUP_PR_MADE=0
# 1 while the POST that opens the pull request is in flight: the pull request
# may exist although adopt has not seen the answer, so the branch must stay.
ADOPT_SETUP_PR_PENDING=0
# The pull request adopt_setup opened, for --wait to poll.
ADOPT_SETUP_PR_URL=""
ADOPT_SETUP_PR_NUMBER=""
# --wait: set by cmd_adopt; how often the pull request is read, in seconds
# (tests set the interval to 0 or a value with a stub sleep); and the sleep in
# flight, which an interrupt takes down.
ADOPT_WAIT=0
ADOPT_WAIT_INTERVAL=${ADOPT_WAIT_INTERVAL:-10}
[ "$ADOPT_WAIT_INTERVAL" -ge 0 ] 2>/dev/null || ADOPT_WAIT_INTERVAL=10
ADOPT_WAIT_SLEEPER=""
# Set once the wait saw the pull request merged.
ADOPT_WAIT_MERGED=0
# Set once adopt_switch returned: after that only the optional --verify is left.
ADOPT_SWITCH_DONE=0
# 1 once cmd_adopt installed the INT and TERM handler (a --setup run).
ADOPT_HANDLER=0
# The pid of the process that started this adopt, when that is not the user's
# terminal: setup_route_repo sets it to setup's pid. Empty for a standalone
# adopt, which has no parent to watch.
ADOPT_PARENT_PID=""
# What adopt --setup --wait exits with when it fails after opening the pull
# request (setup_route_repo reads them): ADOPT_EXIT_OPEN while it is not
# merged, ADOPT_EXIT_MERGED once it is. Ctrl-C and SIGTERM keep 130 and 143.
# Every other failure, and every run without --wait, exits 1 as before.
# shellcheck disable=SC2034  # read by cmd-install.sh's setup_route_repo
ADOPT_EXIT_OPEN=4
ADOPT_EXIT_MERGED=5

# _preset_load <name>: the work behind load_presets. Recursive so that an
# `include` puts the other preset's packages where it is written, and a name
# already loaded (an include cycle) is skipped rather than followed again.