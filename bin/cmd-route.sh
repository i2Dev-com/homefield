#!/usr/bin/env bash
# The route command: the CI_RUNNER switch, per repository.

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
    current="$(gh variable get CI_RUNNER --repo "$repo" 2>/dev/null || echo "(unset)")"
    if [ "$dry" = 1 ]; then
      log "${repo}: CI_RUNNER ${current} -> ${target} (dry run)"
    else
      gh variable set CI_RUNNER --repo "$repo" --body "$target" >/dev/null ||
        { rc=1; log "${repo}: could not set CI_RUNNER to ${target}; set it by hand: gh variable set CI_RUNNER --repo ${repo} --body ${target}" >&2; continue; }
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
        gh run rerun "$id" --repo "$repo" >/dev/null ||
          { rc=1; log "${repo}: run ${id}: the re-run was refused; run it yourself: gh run rerun ${id} --repo ${repo}" >&2; continue; }
        log "${repo}: run ${id} re-run"
      elif [ -n "$status" ]; then
        log "${repo}: run ${id} is still ${status} after a minute; re-run it yourself: gh run rerun ${id} --repo ${repo}" >&2
      fi
    done
  done
  return "$rc"
}
