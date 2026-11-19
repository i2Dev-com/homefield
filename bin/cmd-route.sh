#!/usr/bin/env bash
# The route command: the CI_RUNNER switch, per repository.

# The routing records, next to the per-instance state files (the same
# directory, not inside them: they are per-Mac, not per-VM). `routing` holds
# one `label repo` line per repository currently routed to a local runner —
# the mirror of CI_RUNNER=local on GitHub — and `autoflip` holds the
# repositories a `stop --route-hosted` flipped to hosted, waiting for
# `start --route-local` (or the next start of an --auto-route VM) to bring
# them back. One line per repo: a repo's CI_RUNNER points one way.
routing_file() { printf '%s/routing' "${HOMEFIELD_STATE_DIR:-$HOME/.local/state/homefield}"; }
autoflip_file() { printf '%s/autoflip' "${HOMEFIELD_STATE_DIR:-$HOME/.local/state/homefield}"; }

# record_drop <file> <repo>: remove the repo's line, keeping the rest. A
# missing file is already correct. The rewrite goes through a temp file next
# to the target and moves over it, so a reader never sees half a file (the
# same rule state_set follows).
record_drop() {
  local f="$1" repo="$2" dir tmp
  [ -f "$f" ] || return 0
  dir="$(dirname "$f")"
  tmp="$(mktemp "$dir/.routing.XXXXXX")" || return 1
  awk -v r="$repo" '$2 != r' "$f" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# record_add <file> <label> <repo>: one `label repo` line for the repo,
# replacing any line it already has.
record_add() {
  local f="$1" dir tmp
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.routing.XXXXXX")" || return 1
  {
    [ ! -f "$f" ] || awk -v r="$3" '$2 != r' "$f"
    printf '%s %s\n' "$2" "$3"
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
  local scope
  scope="$(api_scope "$1" 2>/dev/null)" || return 1
  gh api --hostname github.com --paginate "${scope}/actions/runners?per_page=100" \
    --jq '.runners[] | [.id, .name, .status, (.labels | map(.name) | join(","))] | @tsv' \
    </dev/null 2>/dev/null
}

# runner_serves_repo <org> <runner id> <repo>: whether the runner can take
# the repository's jobs — its group admits the repository (a selected group
# only its listed ones, the Default group every repository in the org).
# 0 serves, 1 does not, 2 could not be asked (the caller fails safe and
# keeps the repository routed local).
runner_serves_repo() {
  local org="$1" rid="$2" repo="$3" row vis gid repos
  row="$(find_runner_group "$org" "$rid")" || return 2
  IFS=$'\t' read -r _gname vis _pub gid <<<"$row"
  case "$vis" in
    selected)
      repos="$(group_repositories "$org" "$gid" 2>/dev/null)" || return 2
      printf '%s\n' "$repos" | grep -qx "$repo" && return 0
      return 1
      ;;
    # the Default group admits every repository in the organization
    *) return 0 ;;
  esac
}

# scope_owner <url>: what a runner is registered to — the path after
# github.com in its gitHubUrl: the organization (`https://github.com/acme`
# -> `acme`) or, for a repository-scoped registration, the repository itself
# (`https://github.com/acme/api` -> `acme/api`). The fallback may only touch
# repositories in that scope: the runners it can see (and the labels it
# matched) are the scope's runners, so a record for another organization's
# repo is someone else's to flip.
scope_owner() {
  local owner="${1#*github.com/}"
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

# route_stop_fallback <url> <name>: the stop-side of the automatic fallback
# (#286). Every repository routed to one of this runner's labels goes to
# hosted, unless another online runner still serves that label — the issue's
# own "when no local runner is online" rule, with this runner (still listed
# online, the stop has not happened yet) excluded by name. Flipped repos move
# from `routing` to `autoflip`, so the next start knows what to bring back.
# A GitHub failure reads as "could not prove nobody serves the label" and
# flips nothing: leaving jobs routed local is the status quo, flipping them
# off a runner that is actually there is a regression. Returns 1 when
# anything was left undone, so stop can report it.
route_stop_fallback() {
  local url="$1" name="$2" rows rname rstatus rlabels label repo served flipped=0 rc=0
  # Nothing routed to any local runner: nothing to flip, and GitHub need not
  # be asked. (A missing file reads as empty: set -e turns a failed
  # redirection on it into an aborted command.)
  [ -f "$(routing_file)" ] || { log "no routed repository needed the fallback"; return 0; }
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
  while read -r label repo; do
    [ -n "$repo" ] || continue
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
        runner_serves_repo "$owner" "$rid" "$repo"
        case $? in 0 | 2) served=1 ;; esac
      fi
    done <<<"$rows"
    if [ "$served" = 1 ]; then
      log "${repo}: label ${label} is still served by another online runner; not switching to hosted"
      continue
    fi
    local landed=0
    if cmd_route hosted --repo "$repo" --label "$label"; then
      landed=1
    else
      rc=1
      # cmd_route also returns 1 when the variable landed but the stuck-run
      # recovery failed. The repo leaving the routing record is what a landed
      # variable looks like in the records; a failed set leaves it there.
      [ -n "$(awk -v r="$repo" '$2 == r {print; exit}' "$(routing_file)" 2>/dev/null)" ] || landed=1
    fi
    if [ "$landed" = 1 ]; then
      record_add "$(autoflip_file)" "$label" "$repo" ||
        { rc=1; echo "homefield: ${repo}: flipped to hosted but could not record it for the next start; run bin/homefield route local --repo ${repo} --label ${label} by hand" >&2; }
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
  local url="$1" name="$2" rows rname rstatus rlabels label repo rc=0 restored=0 owner
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
  while read -r label repo; do
    [ -n "$repo" ] || continue
    if ! in_scope "$repo" "$owner"; then
      log "${repo}: routed under a different scope than ${owner}; leaving it hosted"
      continue
    fi
    # The started runner must be able to take the repository's jobs: the
    # workflow's full runs-on set, not just the label (see serves_jobs).
    serves_jobs "$labels" "$label" || continue
    if cmd_route local --repo "$repo" --label "$label"; then
      record_drop "$(autoflip_file)" "$repo" ||
        { rc=1; echo "homefield: ${repo}: routed local but could not update the record; it will be routed local again on the next start" >&2; }
      restored=$((restored + 1))
    else
      rc=1
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
  local url="$1" name="$2" label="${3:-}" gid="${4:-}" scope org repos r current rc=0 n=0 preserved=0 gc
  local rows="" rid rname rstatus rlabels other conflict owner repo_scope
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
        if [ -n "$gc" ] && [ "${gc%%/*}" = "$org" ]; then gid="${gc##*/}"; fi
      fi
      if [ -n "$gid" ]; then
        repos="$(group_repositories "$org" "$gid" 2>/dev/null)" || repos=""
      fi
      if [ -z "${repos:-}" ]; then
        echo "homefield: could not list the runner group's repositories; repositories already routed local are not covered by the automatic fallback until each is recorded: bin/homefield route local --repo <owner>/<repo>" >&2
        return 1
      fi
      ;;
    repos/*)
      repos="${url#*github.com/}" ;;
    *)
      echo "homefield: unexpected scope ${scope}; the routing records were not seeded" >&2
      return 1 ;;
  esac
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    # An existing record is the truth about which label routes this
    # repository; this runner's label would be a guess (runners in one
    # group can use different labels), so never overwrite.
    if [ -n "$(awk -v r="$r" '$2 == r {print; exit}' "$(routing_file)" 2>/dev/null)" ]; then
      preserved=$((preserved + 1))
      continue
    fi
    current="$(repo_variable_get "$r" CI_RUNNER)"
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
        runner_serves_repo "$owner" "$rid" "$r"
        case $? in 0 | 2) conflict=1 ;; esac
      fi
    done <<<"$rows"
    if [ "$conflict" = 1 ]; then
      rc=1
      echo "homefield: ${r}: routed local, but ${label} is not provably the only label that can serve it here; not recorded (record it by hand: bin/homefield route local --repo ${r} --label <label>)" >&2
      continue
    fi
    if record_add "$(routing_file)" "$label" "$r"; then
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

# stuck_runs <owner/repo> <label>: ids of the repository's active runs that
# have a job still queued for a runner with the label: the jobs that keep
# waiting after a switch to hosted, because runs-on was decided when they
# were queued.
stuck_runs() {
  local repo="$1" label="$2" status ids id waiting
  label="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
  # --paginate: after a long outage there can be more than one page of
  # active runs, or of jobs in a run. With --paginate, --jq runs per page,
  # so both filters emit one line per match and a match on any page counts.
  for status in queued in_progress; do
    ids="$(gh api --paginate "repos/${repo}/actions/runs?status=${status}&per_page=100" --jq '.workflow_runs[].id')" || return 1
    for id in $ids; do
      waiting="$(gh api --paginate "repos/${repo}/actions/runs/${id}/jobs?per_page=100" \
        --jq ".jobs[] | select(.status == \"queued\" and ((.labels | map(ascii_downcase)) | index(\"${label}\"))) | .id")" || return 1
      [ -n "$waiting" ] && echo "$id"
    done
  done
  return 0
}

cmd_route() {
  local target="${1:-}" label="homefield-ci" dry=0 repos=() repo current stuck id status tries rc=0
  [ $# -gt 0 ] && shift
  case "$target" in
    hosted | local) ;;
    *) die "route: say where to: bin/homefield route <hosted|local> --repo <owner>/<repo>" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repos+=("${2:?--repo needs a value}"); shift 2 ;;
      --label) label="${2:?--label needs a value}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "route: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  [ "${#repos[@]}" -gt 0 ] || die "route: --repo <owner>/<repo> is required"
  [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || die "route: --label must be one label"
  command -v gh >/dev/null || die "route needs gh (https://cli.github.com)"

  for repo in "${repos[@]}"; do
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "route: --repo must be <owner>/<repo>, got: $repo"
    current="$(repo_variable_get "$repo" CI_RUNNER)"
    if [ "$dry" = 1 ]; then
      log "${repo}: CI_RUNNER ${current} -> ${target} (dry run)"
    else
      repo_variable_set "$repo" CI_RUNNER "$target" ||
        { rc=1; log "${repo}: could not set CI_RUNNER to ${target}; set it by hand: gh variable set CI_RUNNER --repo ${repo} --body ${target}" >&2; continue; }
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
        record_add "$(routing_file)" "$label" "$repo" ||
          { rc=1; log "${repo}: routed local but could not record it; the automatic fallback will not cover this repo ($(routing_file))" >&2; }
        record_drop "$(autoflip_file)" "$repo" || { rc=1; log "${repo}: could not update $(autoflip_file)" >&2; }
      else
        record_drop "$(routing_file)" "$repo" || { rc=1; log "${repo}: could not update $(routing_file)" >&2; }
        record_drop "$(autoflip_file)" "$repo" || { rc=1; log "${repo}: could not update $(autoflip_file)" >&2; }
      fi
      log "${repo}: CI_RUNNER ${current} -> ${target}"
    fi
    [ "$target" = hosted ] || continue

    # runs-on was fixed when these jobs were queued, so they wait for the
    # local runner whatever the variable says now. Cancel and re-run them;
    # the re-run is routed afresh, to hosted.
    # A failed lookup must not read as "nothing stuck".
    stuck="$(stuck_runs "$repo" "$label")" ||
      { rc=1; log "${repo}: could not list its runs with gh; look for stuck jobs by hand: gh run list --repo ${repo} --status queued" >&2; continue; }
    for id in $stuck; do
      if [ "$dry" = 1 ]; then
        log "${repo}: run ${id} has jobs waiting for ${label}; would cancel and re-run it"
        continue
      fi
      log "${repo}: run ${id} has jobs waiting for ${label}; cancelling and re-running it"
      gh run cancel "$id" --repo "$repo" >/dev/null ||
        { rc=1; log "${repo}: run ${id}: the cancel failed; re-run it yourself: gh run rerun ${id} --repo ${repo}" >&2; continue; }
      # Up to a minute for the cancel to land; a re-run is refused before.
      # A shell counter, so nothing outside bash can make the wait vanish.
      # ROUTE_TRIES and ROUTE_INTERVAL are seams for the tests, as the
      # verify loop's ADOPT_VERIFY_TRIES and ADOPT_VERIFY_INTERVAL are.
      status=""
      tries=0
      while [ "$tries" -lt "${ROUTE_TRIES:-30}" ]; do
        status="$(gh run view "$id" --repo "$repo" --json status --jq .status)" ||
          { rc=1; log "${repo}: run ${id}: could not read its status with gh; re-run it yourself: gh run rerun ${id} --repo ${repo}" >&2; status=""; break; }
        [ "$status" = completed ] && break
        adopt_nap "${ROUTE_INTERVAL:-2}"
        tries=$((tries + 1))
      done
      if [ "$status" = completed ]; then
        run_rerun "$repo" "$id" ||
          { rc=1; log "${repo}: run ${id}: the re-run was refused; run it yourself: gh run rerun ${id} --repo ${repo}" >&2; continue; }
        log "${repo}: run ${id} re-run"
      elif [ -n "$status" ]; then
        log "${repo}: run ${id} is still ${status} after a minute; re-run it yourself: gh run rerun ${id} --repo ${repo}" >&2
      fi
    done
  done
  return "$rc"
}
