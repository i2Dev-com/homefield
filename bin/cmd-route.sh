#!/usr/bin/env bash
# The route command: the CI_RUNNER switch, per repository.

# The routing records, next to the per-instance state files (the same
# directory, not inside them: they are per-Mac, not per-VM). `routing` holds
# one line per repository currently routed to a local runner — the mirror of
# CI_RUNNER=local on GitHub — and `autoflip` holds the repositories a `stop
# --route-hosted` flipped to hosted, waiting for `start --route-local` (or
# the next start of an --auto-route VM) to bring them back. One line per repo
# and host: a Mac may host runners for the same owner/repo on github.com and
# a GitHub Enterprise Server, and the records must not mix them — a restore
# against one host must not consume the other host's pending entry. The host
# is the third field; a line without one (a record written before #287) reads
# as github.com.
#
# The fourth through sixth fields are the consumer's routing-guard options
# that change which runs may take the local runner: `events` (comma list,
# default pull_request), `dependabot` (hosted|local, default hosted) and
# `mode` (guards|simple, default guards) — the same names and defaults as
# the guard's (routing-guard/routing_guard.py EVENTS, DEPENDABOT, MODES).
# The demand side reads them (#315): a run counts as demand for a dark VM
# only when the consumer's own expression would have sent it to the runner.
# A line without them (a record written before #315) reads as the defaults.
routing_file() { printf '%s/routing' "${HOMEFIELD_STATE_DIR:-$HOME/.local/state/homefield}"; }
autoflip_file() { printf '%s/autoflip' "${HOMEFIELD_STATE_DIR:-$HOME/.local/state/homefield}"; }

# The awk condition shared by the record readers: the line's repo is r and
# its host is hval (an empty third field is github.com, so a legacy line and
# a github.com line are the same record).
RECORD_IS='($2 == r && ($3 == "" ? "github.com" : $3) == hval)'

# The events a record's demand filter can name, and the values the other two
# option fields take: the routing-guard's own (routing_guard.py EVENTS,
# DEPENDABOT, MODES — tests/routing.sh pins the two lists together). An event
# outside the list cannot appear in the guard's expression, so naming it in a
# record would only ever exclude demand the runner could have taken.
ROUTE_EVENTS="pull_request push workflow_dispatch schedule"
ROUTE_DEPENDABOT="hosted local"
ROUTE_MODE="guards simple"

# record_drop <file> <repo> <host>: remove the repo's line for <host>,
# keeping the rest. A missing file is already correct. The rewrite goes
# through a temp file next to the target and moves over it, so a reader never
# sees half a file (the same rule state_set follows).
record_drop() {
  local f="$1" repo="$2" host="$3" dir tmp
  [ -f "$f" ] || return 0
  dir="$(dirname "$f")"
  tmp="$(mktemp "$dir/.routing.XXXXXX")" || return 1
  awk -v r="$repo" -v hval="$host" "!$RECORD_IS" "$f" >"$tmp" ||
    { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# record_add <file> <label> <repo> <host> [events] [dependabot] [mode]: one
# line for the repo on the host, replacing any line it already has for that
# pair (a record for the same repo on another host stays). With the three
# option arguments the line carries them (the demand side reads them, #315);
# without them the line is the three-field legacy shape: the record's
# routing profile is unknown, and the demand side stays permissive until
# `route local` or `adopt` records the profile.
record_add() {
  local f="$1" dir tmp
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.routing.XXXXXX")" || return 1
  {
    [ ! -f "$f" ] || awk -v r="$3" -v hval="$4" "!$RECORD_IS" "$f"
    if [ $# -ge 5 ]; then
      printf '%s %s %s %s %s %s\n' "$2" "$3" "$4" \
        "${5:-pull_request}" "${6:-hosted}" "${7:-guards}"
    else
      printf '%s %s %s\n' "$2" "$3" "$4"
    fi
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# runners_on_github <url>: the scope's runners as `id name status labels`
# lines (labels comma-separated), or nothing when GitHub lists none; 1 when
# GitHub could not be asked. One paginated call serves the fallback's halves:
# this runner's labels, and which other online runners still serve them —
# which needs the id, because a runner serves a repository only if its group
# admits it (runners in different groups can share a label).
runners_on_github() {
  local scope host
  scope="$(api_scope "$1" 2>/dev/null)" || return 1
  host="$(github_host "$1")"
  gh api --hostname "$host" --paginate "${scope}/actions/runners?per_page=100" \
    --jq '.runners[] | [.id, .name, .status, (.labels | map(.name) | join(","))] | @tsv' \
    </dev/null 2>/dev/null
}

# runner_serves_repo <org> <runner id> <repo> <host>: whether the runner can take
# the repository's jobs — its group admits the repository (a selected group
# only its listed ones, the Default group every repository in the org).
# 0 serves, 1 does not, 2 could not be asked (the caller fails safe and
# keeps the repository routed local).
runner_serves_repo() {
  local org="$1" rid="$2" repo="$3" host="$4" row vis gid repos
  row="$(find_runner_group "$org" "$rid" "$host")" || return 2
  IFS=$'\t' read -r _gname vis _pub gid <<<"$row"
  case "$vis" in
    selected)
      repos="$(group_repositories "$org" "$gid" "$host" 2>/dev/null)" || return 2
      printf '%s\n' "$repos" | grep -qx "$repo" && return 0
      return 1
      ;;
    # the Default group admits every repository in the organization
    *) return 0 ;;
  esac
}

# scope_owner <url>: what a runner is registered to — the path after the
# host in its gitHubUrl: the organization (`https://github.com/acme`
# -> `acme`) or, for a repository-scoped registration, the repository itself
# (`https://github.com/acme/api` -> `acme/api`). The fallback may only touch
# repositories in that scope: the runners it can see (and the labels it
# matched) are the scope's runners, so a record for another organization's
# repo is someone else's to flip.
scope_owner() {
  local host owner
  host="$(github_host "$1")"
  owner="${1#*${host}/}"
  printf '%s' "${owner%/}"
}

# in_scope <repo> <owner>: whether the repo belongs to the runner's
# registration scope — the exact repository for a repository-scoped
# registration, anything under the organization otherwise.
in_scope() {
  case "$1" in
    "$2" | "$2"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# serves_jobs <labels> <label>: whether a runner advertising <labels> can
# take an adopted workflow's jobs. The workflow's runs-on is the canonical
# expression (routing-guard/routing_guard.py canonical_expression):
# self-hosted, linux, arm64 and the routing label — a runner missing any of
# them (an x64 runner, for one) cannot execute the workflow, however well
# its custom labels match. Comparisons are case-insensitive, as GitHub
# treats labels.
serves_jobs() {
  local labels
  labels=",$(lower "$1"),"
  case "$labels" in *",self-hosted,"*) ;; *) return 1 ;; esac
  case "$labels" in *",linux,"*) ;; *) return 1 ;; esac
  case "$labels" in *",arm64,"*) ;; *) return 1 ;; esac
  case "$labels" in *",$(lower "$2"),"* ) ;; *) return 1 ;; esac
  return 0
}

# route_stop_fallback <url> <name> [exclude]: the stop-side of the automatic
# fallback (#286). Every repository routed to one of this runner's labels goes
# to hosted, unless another online runner still serves that label — the issue's
# own "when no local runner is online" rule, with this runner (still listed
# online, the stop has not happened yet) excluded by name. <exclude> (a
# newline-separated list, optional) names more runners to treat as gone: the
# sleep/wake watcher (#290) passes every HomeField runner on this Mac, because
# they all stop answering when the Mac sleeps, while the stop of one VM leaves
# the Mac's others up. Flipped repos move from `routing` to `autoflip`, so the
# next start knows what to bring back. A GitHub failure reads as "could not
# prove nobody serves the label" and flips nothing: leaving jobs routed local
# is the status quo, flipping them off a runner that is actually there is a
# regression. Returns 1 when anything was left undone, so stop can report it.
route_stop_fallback() {
  local url="$1" name="$2" exclude="${3:-}" rows rname rstatus rlabels label repo served flipped=0 rc=0 host
  host="$(github_host "$url")"
  # Nothing routed to any local runner: nothing to flip, and GitHub need not
  # be asked. (A missing file reads as empty: set -e turns a failed
  # redirection on it into an aborted command.)
  [ -f "$(routing_file)" ] || { log "no routed repository needed the fallback"; return 0; }
  # "hosted" is GitHub's hosted runners: github.com has them, and so do the
  # *.ghe.com data-residency subdomains (Linux and Windows; the fallback's
  # labels are Linux ones). A GitHub Enterprise Server has none: on one, the
  # flip would send the jobs to a label nothing serves. The stop still
  # happens; the repositories stay routed local, where the local runner (or a
  # human) can be reached.
  if ! hosted_runners "$host"; then
    log "the hosted fallback needs GitHub's hosted runners, which ${host} does not have; leaving the routed repositories as they are"
    return 0
  fi
  rows="$(runners_on_github "$url")" || {
    echo "homefield: could not read the runners from GitHub; leaving the routed repositories as they are (jobs will queue while the VM is down)" >&2
    return 1
  }
  # This runner's labels, from the row that matches by name. Not listed:
  # nothing is known about what it serves, so nothing is flipped.
  local labels="" rid rname rstatus rlabels
  while IFS=$'\t' read -r rid rname rstatus rlabels; do
    [ "$rname" = "$name" ] && labels="$rlabels"
  done <<<"$rows"
  if [ -z "$labels" ]; then
    echo "homefield: ${name} is not in GitHub's runner list; leaving the routed repositories as they are" >&2
    return 1
  fi
  # GitHub matches runner labels case-insensitively (adopt's checks do too),
  # so the comparisons do as well: a record for HomeField-CI and a runner
  # advertising homefield-ci are the same label.
  labels="$(lower "$labels")"
  local owner repo_scope=org
  owner="$(scope_owner "$url")"
  case "$owner" in */*) repo_scope=repo ;; esac
  while read -r label repo rhost revents rdependabot rmode; do
    [ -n "$repo" ] || continue
    # The host field (a legacy line without one reads as github.com): this
    # stop only flips github.com records — it refused other hosts above —
    # and a record for another host belongs to that host's runner, whose
    # stop is the one that may flip it.
    [ "${rhost:-github.com}" = github.com ] || {
      log "${repo}: routed on ${rhost}, not github.com; not switching it to hosted"
      continue
    }
    # The rows describe this scope's runners only, so a record for a repo in
    # another scope (a Mac hosting runners for two organizations) is not this
    # stop's to flip: its own runner is invisible here and may be online.
    if ! in_scope "$repo" "$owner"; then
      log "${repo}: routed under a different scope than ${owner}; not switching it to hosted"
      continue
    fi
    case ",${labels}," in *",$(lower "$label"),"* ) ;; *) continue ;; esac
    # Another online runner (not this one) that can take the repository's
    # jobs keeps the label served, so the repositories stay routed local.
    served=0
    while IFS=$'\t' read -r rid rname rstatus rlabels; do
      [ "$rname" = "$name" ] && continue
      # A runner in the exclusion list goes away with this Mac (the watcher's
      # sleep side), so it does not keep the label served, however online
      # GitHub still lists it. -F -x: a literal whole-line match — a runner
      # name is data, not a pattern.
      if [ -n "$exclude" ] && printf '%s\n' "$exclude" | grep -Fxq "$rname"; then
        continue
      fi
      [ "$rstatus" = online ] || continue
      # The custom label is not enough: the workflow's runs-on also needs
      # self-hosted, linux and arm64 (the canonical expression), and the
      # runner's group must admit the repository (two runners can share a
      # label from different groups). On a repository-scoped registration
      # every listed runner serves the repository by definition; a group
      # that cannot be asked keeps the status quo (routed local).
      serves_jobs "$rlabels" "$label" || continue
      if [ "$repo_scope" = repo ]; then
        served=1
      else
        runner_serves_repo "$owner" "$rid" "$repo" "$host"
        case $? in 0 | 2) served=1 ;; esac
      fi
    done <<<"$rows"
    if [ "$served" = 1 ]; then
      log "${repo}: label ${label} is still served by another online runner; not switching to hosted"
      continue
    fi
    local landed=0
    # cmd_route reads its GitHub host from the environment (it takes no
    # --url), so lend it this instance's for the flip. The assignment is
    # temporary: it does not outlive the function call. HOMEFIELD_ROUTE_AUTOFLIP
    # says the caller is the automatic fallback, so cmd_route persists the
    # restore intent (the autoflip entry) before its stuck-run recovery — the
    # one part of the flip that can wait a minute, longer than the watcher's
    # sleep budget: killed there, the repo would be CI_RUNNER=hosted with
    # neither record left, and no start or wake could bring it back. Adding it
    # again below is a no-op (one line per repo and host). A record without
    # option fields flips with --profile unknown: the entry stays legacy
    # three-field, so the wake side keeps counting every active run instead
    # of guessing this record's profile (#315).
    if [ -n "$rmode" ]; then
      HOMEFIELD_ROUTE_AUTOFLIP=1 HOMEFIELD_GITHUB_HOST="$host" cmd_route hosted --repo "$repo" --label "$label" \
        --events "$revents" --dependabot "$rdependabot" --mode "$rmode" && landed=1
    else
      HOMEFIELD_ROUTE_AUTOFLIP=1 HOMEFIELD_GITHUB_HOST="$host" cmd_route hosted --repo "$repo" --label "$label" --profile unknown && landed=1
    fi
    if [ "$landed" != 1 ]; then
      rc=1
      # cmd_route also returns 1 when the variable landed but the stuck-run
      # recovery failed. The repo leaving the routing record is what a landed
      # variable looks like in the records; a failed set leaves it there.
      [ -n "$(awk -v r="$repo" -v hval="$host" "$RECORD_IS { print; exit }" "$(routing_file)" 2>/dev/null)" ] || landed=1
    fi
    if [ "$landed" = 1 ]; then
      if [ -n "$rmode" ]; then
        record_add "$(autoflip_file)" "$label" "$repo" "$host" "$revents" "$rdependabot" "$rmode" ||
          { rc=1; echo "homefield: ${repo}: flipped to hosted but could not record it for the next start; run bin/homefield route local --repo ${repo} --label ${label} by hand" >&2; }
      else
        record_add "$(autoflip_file)" "$label" "$repo" "$host" ||
          { rc=1; echo "homefield: ${repo}: flipped to hosted but could not record it for the next start; run bin/homefield route local --repo ${repo} --label ${label} by hand" >&2; }
      fi
      flipped=$((flipped + 1))
    fi
  done <"$(routing_file)"
  if [ "$flipped" -eq 0 ] && [ "$rc" = 0 ]; then
    log "no routed repository needed the fallback"
  fi
  return "$rc"
}

# route_start_restore <url> <name>: the start-side of the automatic fallback
# (#286): the repositories this runner flipped to hosted go back to local,
# and leave `autoflip` only when the flip landed (a failure keeps it for the
# next start). Only entries this runner can actually serve are restored: the
# repo's label must be one of the runner's (a Mac with VMs on different
# labels must not restore another, still stopped VM's repositories) and the
# repo must be in the runner's registration scope (the stop side only ever
# flips that scope, so anything else in the file is not this runner's).
# GitHub being unanswerable or the runner missing from its list reads as
# "cannot prove what this runner serves": nothing restored, entries kept,
# 1 to the caller.
route_start_restore() {
  local url="$1" name="$2" rows rname rstatus rlabels label repo rc=0 restored=0 owner host
  host="$(github_host "$url")"
  # Nothing waiting: quiet, and GitHub need not be asked.
  [ -f "$(autoflip_file)" ] || { log "no repository waiting to be routed back"; return 0; }
  rows="$(runners_on_github "$url")" || {
    echo "homefield: could not read the runners from GitHub; the flipped repositories stay hosted until the next start" >&2
    return 1
  }
  local labels="" rid rname rstatus rlabels
  while IFS=$'\t' read -r rid rname rstatus rlabels; do
    [ "$rname" = "$name" ] && labels="$rlabels"
  done <<<"$rows"
  if [ -z "$labels" ]; then
    echo "homefield: ${name} is not in GitHub's runner list; the flipped repositories stay hosted until the next start" >&2
    return 1
  fi
  labels="$(lower "$labels")"
  owner="$(scope_owner "$url")"
  while read -r label repo rhost revents rdependabot rmode; do
    [ -n "$repo" ] || continue
    # The host field (a legacy line without one reads as github.com): only
    # this host's records are this start's to restore — a pending entry for
    # the same owner/repo on another host belongs to that host's runner.
    # The option fields ride back into the routing record: dropping them
    # here would lose the consumer's demand profile on the next stop (#315).
    if [ "${rhost:-github.com}" != "$host" ]; then
      log "${repo}: flipped on ${rhost:-github.com}, not ${host}; leaving it hosted"
      continue
    fi
    if ! in_scope "$repo" "$owner"; then
      log "${repo}: routed under a different scope than ${owner}; leaving it hosted"
      continue
    fi
    # The started runner must be able to take the repository's jobs: the
    # workflow's full runs-on set, not just the label (see serves_jobs).
    serves_jobs "$labels" "$label" || continue
    # See route_stop_fallback: cmd_route reads its host from the environment.
    # A legacy three-field entry (no option fields) restores with
    # --profile unknown: the routing record stays legacy three-field, so
    # the next stop writes a legacy entry again and the demand side keeps
    # counting every active run — guessing the guard's defaults here would
    # silence a simple-mode repository's push and schedule demand on the
    # following cycle (#315).
    if [ -n "$rmode" ]; then
      if HOMEFIELD_GITHUB_HOST="$host" cmd_route local --repo "$repo" --label "$label" \
        --events "$revents" --dependabot "$rdependabot" --mode "$rmode"; then
        record_drop "$(autoflip_file)" "$repo" "$host" ||
          { rc=1; echo "homefield: ${repo}: routed local but could not update the record; it will be routed local again on the next start" >&2; }
        restored=$((restored + 1))
      else
        rc=1
      fi
    else
      if HOMEFIELD_GITHUB_HOST="$host" cmd_route local --repo "$repo" --label "$label" --profile unknown; then
        record_drop "$(autoflip_file)" "$repo" "$host" ||
          { rc=1; echo "homefield: ${repo}: routed local but could not update the record; it will be routed local again on the next start" >&2; }
        restored=$((restored + 1))
      else
        rc=1
      fi
    fi
  done <"$(autoflip_file)"
  if [ "$restored" -eq 0 ] && [ "$rc" = 0 ]; then
    log "no repository waiting to be routed back"
  fi
  return "$rc"
}

# routing_label <labels>: the runner's routing label — the first label that
# is not one of the standard labels GitHub gives every self-hosted runner.
# Empty when there is none (nothing can be routed to such a runner).
routing_label() {
  local l found=""
  (
    IFS=,
    for l in $1; do
      [ -n "$found" ] && continue
      case ",$(lower "$l")," in
        *,self-hosted,* | *,linux,* | *,arm64,* | *,x64,* | *,arm,* | *,windows,* | *,macos,*) ;;
        *) printf '%s\n' "$l" && found=1 ;;
      esac
    done
  )
}

# routing_label_from_rows <rows> <name>: the routing label of the runner
# named <name> (see routing_label). Empty when the runner is not in the
# rows or carries no custom label (nothing can be routed to it, so there is
# nothing to seed).
routing_label_from_rows() {
  local rid rname rstatus rlabels labels=""
  while IFS=$'\t' read -r rid rname rstatus rlabels; do
    [ "$rname" = "$2" ] && labels="$rlabels"
  done <<<"$1"
  [ -n "$labels" ] || return 0
  routing_label "$labels"
}

# seed_routing_records <url> <name> [label] [gid]: populate the routing
# record for the repositories that are already routed local when the
# automatic fallback is switched on, so an install that adopted before
# --auto-route existed is still covered. The candidates are the
# registration's repositories: the group's repositories for an organization
# runner (the group id, or the one this install created, from the state),
# the registration's own repository for a repository-scoped one. A
# repository that is already recorded keeps its record — runners in one
# group can use different routing labels, and the record, not this runner,
# says which label routes the repository. A repository routed local but not
# recorded is recorded under the actual routing label: the caller's when
# known, otherwise the runner's routing label derived from GitHub's runner
# list — but only when no other runner in the scope with a different label
# can also take the repository's jobs (its group admits it), because a
# record under this runner's label would make the stop side flip a
# repository another runner is still serving. Ambiguous repositories are
# left unrecorded with the by-hand command, like every other seeding
# failure: the fallback stays silent-but-uncovered until the repositories
# are recorded by hand, which is exactly what the warnings say to do.
seed_routing_records() {
  local url="$1" name="$2" label="${3:-}" gid="${4:-}" scope org repos r current rc=0 n=0 preserved=0 gc host
  local rows="" rid rname rstatus rlabels other conflict owner repo_scope
  host="$(github_host "$url")"
  scope="$(api_scope "$url" 2>/dev/null)" || {
    echo "homefield: could not read the scope of ${url}; the routing records were not seeded (repositories already routed local are not covered by the automatic fallback until each is recorded: bin/homefield route local --repo <owner>/<repo>)" >&2
    return 1
  }
  # The runner list serves two purposes: deriving the routing label when
  # the caller does not know it (the upgrade path), and telling which other
  # runners can take a repository's jobs. Both need it, whatever the
  # registration scope.
  rows="$(runners_on_github "$url")" || {
    echo "homefield: could not read the runners from GitHub; the routing records were not seeded (repositories already routed local are not covered by the automatic fallback until each is recorded: bin/homefield route local --repo <owner>/<repo> --label <label>)" >&2
    return 1
  }
  if [ -z "$label" ]; then
    label="$(routing_label_from_rows "$rows" "$name")"
    if [ -z "$label" ]; then
      log "no routing label on ${name}; nothing routes to it, so there is nothing to seed"
      return 0
    fi
  fi
  owner="$(scope_owner "$url")"
  case "$owner" in */*) repo_scope=repo ;; *) repo_scope=org ;; esac
  case "$scope" in
    orgs/*)
      org="${scope#orgs/}"
      if [ -z "$gid" ]; then
        gc="$(state_get group_created)"
        if [ -n "$gc" ] && [ "${gc%%/*}" = "$org" ]; then
          # org/group/id, or org/group/id/host since the host support: the id
          # is the last field when it is numeric, the one before the host
          # otherwise (an empty id stays empty).
          last="${gc##*/}"
          case "$last" in
            *[!0-9]*) rest="${gc%/*}"; gid="${rest##*/}" ;;
            *) gid="$last" ;;
          esac
        fi
      fi
      if [ -n "$gid" ]; then
        repos="$(group_repositories "$org" "$gid" "$host" 2>/dev/null)" || repos=""
      fi
      if [ -z "${repos:-}" ]; then
        echo "homefield: could not list the runner group's repositories; repositories already routed local are not covered by the automatic fallback until each is recorded: bin/homefield route local --repo <owner>/<repo>" >&2
        return 1
      fi
      ;;
    repos/*)
      repos="${scope#repos/}" ;;
    *)
      echo "homefield: unexpected scope ${scope}; the routing records were not seeded" >&2
      return 1 ;;
  esac
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    # An existing record is the truth about which label routes this
    # repository; this runner's label would be a guess (runners in one
    # group can use different labels), so never overwrite.
    if [ -n "$(awk -v r="$r" -v hval="$host" "$RECORD_IS { print; exit }" "$(routing_file)" 2>/dev/null)" ]; then
      preserved=$((preserved + 1))
      continue
    fi
    current="$(repo_variable_get "$r" CI_RUNNER "$host")"
    if [ "$current" != local ]; then continue; fi
    # Establish the actual routing label. Another runner in the scope with
    # a different custom label that can take this repository's jobs (its
    # group admits the repository; a group that cannot be asked counts as
    # able to) makes this runner's label a guess, and a wrong label makes
    # the stop side flip a repository another runner is still serving.
    conflict=0
    while IFS=$'\t' read -r rid rname rstatus rlabels; do
      if [ "$rname" = "$name" ]; then continue; fi
      other="$(routing_label "$rlabels")"
      if [ -z "$other" ]; then continue; fi
      if [ "$(lower "$other")" = "$(lower "$label")" ]; then continue; fi
      # A runner that cannot take the workflow's jobs (missing the
      # canonical platform labels) is no alternative label source.
      serves_jobs "$rlabels" "$other" || continue
      if [ "$repo_scope" = repo ]; then
        conflict=1
      else
        runner_serves_repo "$owner" "$rid" "$r" "$host"
        case $? in 0 | 2) conflict=1 ;; esac
      fi
    done <<<"$rows"
    if [ "$conflict" = 1 ]; then
      rc=1
      echo "homefield: ${r}: routed local, but ${label} is not provably the only label that can serve it here; not recorded (record it by hand: bin/homefield route local --repo ${r} --label <label>)" >&2
      continue
    fi
    if record_add "$(routing_file)" "$label" "$r" "$host"; then
      n=$((n + 1))
    else
      rc=1
      echo "homefield: ${r}: routed local but could not record it; the automatic fallback will not cover this repo ($(routing_file))" >&2
    fi
  done <<<"$repos"
  if [ "$n" -gt 0 ]; then
    log "seeded the routing records with ${n} repositories already routed local"
  fi
  if [ "$preserved" -gt 0 ]; then
    log "kept ${preserved} existing routing record(s)"
  fi
  return "$rc"
}

# stuck_runs <owner/repo> <label> <host>: ids of the repository's active runs
# that have a job still queued for a runner with the label: the jobs that keep
# waiting after a switch to hosted, because runs-on was decided when they
# were queued.
stuck_runs() {
  local repo="$1" label="$2" host="$3" status ids id waiting
  label="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
  # --paginate: after a long outage there can be more than one page of
  # active runs, or of jobs in a run. With --paginate, --jq runs per page,
  # so both filters emit one line per match and a match on any page counts.
  for status in queued in_progress; do
    ids="$(gh api --hostname "$host" --paginate "repos/${repo}/actions/runs?status=${status}&per_page=100" --jq '.workflow_runs[].id')" || return 1
    for id in $ids; do
      waiting="$(gh api --hostname "$host" --paginate "repos/${repo}/actions/runs/${id}/jobs?per_page=100" \
        --jq ".jobs[] | select(.status == \"queued\" and ((.labels | map(ascii_downcase)) | index(\"${label}\"))) | .id")" || return 1
      [ -n "$waiting" ] && echo "$id"
    done
  done
  return 0
}

cmd_route() {
  local target="${1:-}" label="homefield-ci" dry=0 repos=() repo current stuck id status tries rc=0 host
  local events="pull_request" dependabot="hosted" mode="guards" profile="guard" e
  [ $# -gt 0 ] && shift
  case "$target" in
    hosted | local) ;;
    *) die "route: say where to: bin/homefield route <hosted|local> --repo <owner>/<repo>" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repos+=("${2:?--repo needs a value}"); shift 2 ;;
      --label) label="${2:?--label needs a value}"; shift 2 ;;
      --events) events="${2:?--events needs a value}"; shift 2 ;;
      --dependabot) dependabot="${2:?--dependabot needs a value}"; shift 2 ;;
      --mode) mode="${2:?--mode needs a value}"; shift 2 ;;
      --profile) profile="${2:?--profile needs a value}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "route: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  [ "${#repos[@]}" -gt 0 ] || die "route: --repo <owner>/<repo> is required"
  [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || die "route: --label must be one label"
  # The record's routing profile: `guard` (the default) records the options
  # below, so the demand scaler counts exactly the runs the consumer's
  # expression would route (#315). `unknown` records the three-field legacy
  # shape: the profile is not known — the automatic fallback's stop and
  # start preserve a record they read without options, rather than guessing
  # one — and the demand side stays permissive (every active run counts,
  # the model the scaler had before #315) until `route local` or `adopt`
  # records the profile. Guessing the guard's defaults for a repository
  # adopted in simple mode would silence its push and schedule demand for
  # good, so unknown is never resolved by guessing.
  case "$profile" in
    guard | unknown) ;;
    *) die "route: --profile must be guard or unknown" ;;
  esac
  if [ "$profile" = unknown ] && [ "$events$dependabot$mode" != "pull_requesthostedguards" ]; then
    die "route: --profile unknown carries no options; drop --events/--dependabot/--mode"
  fi
  # The events go into the record canonicalized to one comma-separated
  # field: the record's fields are whitespace-delimited, so a list with
  # spaces ("push schedule", which adopt's --events accepts) would smear
  # across the option fields and be misread on the demand side.
  local ev canonic=""
  for ev in $events; do
    canonic="${canonic:+$canonic,}$ev"
  done
  events="$canonic"
  # The option fields are the guard's own (the record mirrors the consumer's
  # guard step, #315): an event the guard cannot route, or a value outside
  # the guard's enums, would make the record describe an expression the
  # consumer does not have.
  for e in $(printf '%s' "$events" | tr ',' ' '); do
    case " $ROUTE_EVENTS " in *" $e "*) ;; *)
      die "route: --events: $e is not one of $(echo $ROUTE_EVENTS) (pull_request_target is never routable: it runs with the repository's secrets on code from forks)"
    ;; esac
  done
  case " $ROUTE_DEPENDABOT " in *" $dependabot "*) ;;
    *) die "route: --dependabot must be hosted or local" ;;
  esac
  case " $ROUTE_MODE " in *" $mode "*) ;;
    *) die "route: --mode must be guards or simple" ;;
  esac
  if [ "$mode" = simple ] && { [ "$events" != pull_request ] || [ "$dependabot" != hosted ]; }; then
    die "route: --mode simple routes every event; --events and --dependabot have no effect there (the guard refuses them too)"
  fi
  command -v gh >/dev/null || die "route needs gh (https://cli.github.com)"
  host="$(github_host "")"
  # "hosted" means GitHub's hosted runners: github.com has them, and so do the
  # *.ghe.com data-residency subdomains (Linux and Windows; macOS is the only
  # kind missing there, and the fallback's labels are Linux ones). On a GHES
  # host the fallback label matches no runner and the jobs would queue
  # forever, so refuse instead of switching them off.
  if [ "$target" = hosted ] && ! hosted_runners "$host"; then
    die "route: GitHub's hosted runners do not exist on ${host}; keep the repository routed local (bin/homefield route local --repo <owner>/<repo>)"
  fi

  for repo in "${repos[@]}"; do
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "route: --repo must be <owner>/<repo>, got: $repo"
    current="$(repo_variable_get "$repo" CI_RUNNER "$host")"
    if [ "$dry" = 1 ]; then
      log "${repo}: CI_RUNNER ${current} -> ${target} (dry run)"
    else
      repo_variable_set "$repo" CI_RUNNER "$target" "$host" ||
        { rc=1; log "${repo}: could not set CI_RUNNER to ${target}; set it by hand: gh variable set CI_RUNNER --repo $(host_repo "$host" "$repo") --body ${target}" >&2; continue; }
      # The records mirror the variable, so the automatic fallback (#286)
      # knows what a stop may flip and a start may bring back. A record
      # failure is a real gap — the fallback would not cover the repo — so
      # it fails the command, but the routing itself has landed. A local
      # route also clears a pending restore it supersedes: an operator's
      # `route local` after a stop has decided the repository's routing
      # label, and a later start must not overwrite that choice with the
      # stop's label (the start would flip it back, and the next stop of
      # the operator's runner would then skip the repo and queue its jobs).
      if [ "$target" = local ]; then
        # `guard` records the options; `unknown` records the legacy
        # three-field shape (see the profile check above).
        if [ "$profile" = unknown ]; then
          record_add "$(routing_file)" "$label" "$repo" "$host" ||
            { rc=1; log "${repo}: routed local but could not record it; the automatic fallback will not cover this repo ($(routing_file))" >&2; }
        else
          record_add "$(routing_file)" "$label" "$repo" "$host" "$events" "$dependabot" "$mode" ||
            { rc=1; log "${repo}: routed local but could not record it; the automatic fallback will not cover this repo ($(routing_file))" >&2; }
        fi
        record_drop "$(autoflip_file)" "$repo" "$host" || { rc=1; log "${repo}: could not update $(autoflip_file)" >&2; }
      else
        record_drop "$(routing_file)" "$repo" "$host" || { rc=1; log "${repo}: could not update $(routing_file)" >&2; }
        if [ -n "${HOMEFIELD_ROUTE_AUTOFLIP:-}" ]; then
          # The automatic fallback's caller (#286, route_stop_fallback) wants
          # the restore intent on disk before the stuck-run recovery below:
          # the recovery can wait a minute, longer than the watcher's sleep
          # budget, and a kill there must leave the entry a start or wake can
          # restore from. A direct `route hosted` has no restore intent — the
          # operator decided for hosted — and keeps dropping the entry. The
          # option fields ride along: the wake side's demand filter (#315)
          # reads them from this entry; an unknown profile stays legacy
          # three-field, so the wake side stays permissive instead of
          # guessing one.
          if [ "$profile" = unknown ]; then
            record_add "$(autoflip_file)" "$label" "$repo" "$host" ||
              { rc=1; log "${repo}: flipped to hosted but could not record it for the next start; run bin/homefield route local --repo ${repo} --label ${label} by hand" >&2; }
          else
            record_add "$(autoflip_file)" "$label" "$repo" "$host" "$events" "$dependabot" "$mode" ||
              { rc=1; log "${repo}: flipped to hosted but could not record it for the next start; run bin/homefield route local --repo ${repo} --label ${label} by hand" >&2; }
          fi
        else
          record_drop "$(autoflip_file)" "$repo" "$host" || { rc=1; log "${repo}: could not update $(autoflip_file)" >&2; }
        fi
      fi
      log "${repo}: CI_RUNNER ${current} -> ${target}"
    fi
    [ "$target" = hosted ] || continue

    # runs-on was fixed when these jobs were queued, so they wait for the
    # local runner whatever the variable says now. Cancel and re-run them;
    # the re-run is routed afresh, to hosted.
    # A failed lookup must not read as "nothing stuck".
    stuck="$(stuck_runs "$repo" "$label" "$host")" ||
      { rc=1; log "${repo}: could not list its runs with gh; look for stuck jobs by hand: gh run list --repo $(host_repo "$host" "$repo") --status queued" >&2; continue; }
    for id in $stuck; do
      if [ "$dry" = 1 ]; then
        log "${repo}: run ${id} has jobs waiting for ${label}; would cancel and re-run it"
        continue
      fi
      log "${repo}: run ${id} has jobs waiting for ${label}; cancelling and re-running it"
      gh run cancel "$id" --repo "$(host_repo "$host" "$repo")" >/dev/null ||
        { rc=1; log "${repo}: run ${id}: the cancel failed; re-run it yourself: gh run rerun ${id} --repo $(host_repo "$host" "$repo")" >&2; continue; }
      # Up to a minute for the cancel to land; a re-run is refused before.
      # A shell counter, so nothing outside bash can make the wait vanish.
      # ROUTE_TRIES and ROUTE_INTERVAL are seams for the tests, as the
      # verify loop's ADOPT_VERIFY_TRIES and ADOPT_VERIFY_INTERVAL are.
      status=""
      tries=0
      while [ "$tries" -lt "${ROUTE_TRIES:-30}" ]; do
        status="$(gh run view "$id" --repo "$(host_repo "$host" "$repo")" --json status --jq .status)" ||
          { rc=1; log "${repo}: run ${id}: could not read its status with gh; re-run it yourself: gh run rerun ${id} --repo $(host_repo "$host" "$repo")" >&2; status=""; break; }
        [ "$status" = completed ] && break
        adopt_nap "${ROUTE_INTERVAL:-2}"
        tries=$((tries + 1))
      done
      if [ "$status" = completed ]; then
        run_rerun "$repo" "$id" ||
          { rc=1; log "${repo}: run ${id}: the re-run was refused; run it yourself: gh run rerun ${id} --repo $(host_repo "$host" "$repo")" >&2; continue; }
        log "${repo}: run ${id} re-run"
      elif [ -n "$status" ]; then
        log "${repo}: run ${id} is still ${status} after a minute; re-run it yourself: gh run rerun ${id} --repo $(host_repo "$host" "$repo")" >&2
      fi
    done
  done
  return "$rc"
}
