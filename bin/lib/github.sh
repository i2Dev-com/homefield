#!/usr/bin/env bash
# GitHub: accounts, scopes, tokens, runners, runner groups.

# gh_active_account: "login|scopes" of the active github.com login, "|" when
# there is none. The one place that asks, for preflight_collect's gh check and
# setup's offer to log in (offer_gh_login), so the two cannot disagree. gh's own
# status comes through: with --json it exits 0 when nobody is logged in, so a
# non-zero status means the question could not be answered (a gh too old for
# --json, a broken install), which is not the same as "not logged in".
# GitHub reports the scopes comma-space separated ("repo, workflow"); the
# spaces are stripped here, so a caller's `,scope,` match works whichever
# order the scopes come back in.
gh_active_account() {
  gh auth status --json hosts --jq '.hosts["github.com"] // [] | map(select(.active)) | (.[0] // {}) | "\(.login // "")|\(.scopes // "" | gsub(" "; ""))"' 2>/dev/null </dev/null
}

# runner_on_github <url> <id>: 0 if GitHub lists a runner with the id at <url>,
# 1 if it lists the scope's runners and that id is not among them, 2 if it
# could not be asked (no gh, no admin access, no network), 3 if the call was
# killed after GH_TIMEOUT seconds (a black-holed network stalls the connect
# for ~75 s on macOS, and status owes its other lines no such wait, #103).
# GitHub removes a
# runner that has not connected for more than 14 days, and the VM's .runner
# stays (#76). Matched by id: another Mac can register the name again. Never
# prompts, status calls it. On 0 it also leaves what GitHub says about that
# runner in RUNNER_GH_STATUS (online/offline) and RUNNER_GH_BUSY (true/false),
# which diagnose reports; status ignores them. (The list does not say which
# runner group a runner is in; group_of_runner asks the groups.)
RUNNER_GH_STATUS=""
RUNNER_GH_BUSY=""

runner_on_github() {
  local scope ids id st busy rc=0
  RUNNER_GH_STATUS=""
  RUNNER_GH_BUSY=""
  [ -n "$2" ] && command -v gh >/dev/null || return 2
  scope="$(api_scope "$1" 2>/dev/null)" || return 2
  # The killed-by-signal case is told from a plain failure by the exit code
  # (128 + TERM): the timer below is the only thing that kills this gh. The
  # timer's own kill can race gh finishing a heartbeat earlier; both answers
  # mean "not checked", and only the status wording differs.
  local tmp pid timer
  tmp="$(mktemp)" || return 2
  gh api --hostname github.com --paginate "${scope}/actions/runners?per_page=100" --jq '.runners[] | [.id, .status, .busy] | @tsv' </dev/null >"$tmp" 2>/dev/null &
  pid=$!
  # >/dev/null on the timer matters: sleep inherits stdout, and a caller
  # that runs status inside $(...) would wait for the whole timeout before
  # substitution closes.
  ( sleep "$GH_TIMEOUT"; kill -TERM "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 & timer=$!
  wait "$pid" || rc=$?
  kill "$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  ids="$(cat "$tmp")"
  rm -f "$tmp"
  [ "$rc" -le 128 ] || return 3
  [ "$rc" = 0 ] || return 2
  while IFS=$'\t' read -r id st busy; do
    if [ "$id" = "$2" ]; then
      # shellcheck disable=SC2034  # read by cmd-install.sh's status rendering
      RUNNER_GH_STATUS="$st"
      # shellcheck disable=SC2034  # read by cmd-install.sh
      RUNNER_GH_BUSY="$busy"
      return 0
    fi
  done <<<"$ids"
  return 1
}

# ── Tokens ──────────────────────────────────────────────────────────────────
# api_scope <url>: the REST path of the registration scope.
api_scope() {
  local url="${1%/}"
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
    echo "repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+)$ ]]; then
    echo "orgs/${BASH_REMATCH[1]}"
  else
    die "--url must be https://github.com/<org> or https://github.com/<owner>/<repo>, got: $1"
  fi
}

# runners_page <url>: the settings page listing the scope's runners. An
# organization's settings live under /organizations/<org>/.
runners_page() {
  local scope
  scope="$(api_scope "$1")" || exit 1
  case "$scope" in
    orgs/*) echo "https://github.com/organizations/${scope#orgs/}/settings/actions/runners" ;;
    *) echo "https://github.com/${scope#repos/}/settings/actions/runners" ;;
  esac
}

# The runner APIs of an organization need the admin:org scope, which gh's
# default login does not have. offer_scope_refresh asks once per run to add
# it, on a terminal; it succeeds when the caller should retry its gh call.
# Callers in $(...) do not pass the flag back to their parent, which is fine:
# the group step runs in the parent first, and get_token alone in uninstall.
scope_refresh_asked=0

offer_scope_refresh() {
  [ "$scope_refresh_asked" = 0 ] || return 1
  scope_refresh_asked=1
  [ -t 0 ] && command -v gh >/dev/null || return 1
  if [ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ]; then
    # gh uses that variable instead of its stored login, so adding a scope to
    # the stored login changes nothing for this command.
    echo "homefield: GITHUB_TOKEN or GH_TOKEN is set, and gh uses it instead of its stored login, so" >&2
    echo "homefield: 'gh auth refresh' would not help. Unset it, or use a token with admin:org." >&2
    return 1
  fi
  local answer
  read -rp "gh needs the admin:org scope. Run 'gh auth refresh -h github.com -s admin:org' now? [Y/n] " answer
  case "$answer" in [Nn]*) return 1 ;; esac
  # gh prints its one-time code on stdout; the caller may be in $(...).
  gh auth refresh -h github.com -s admin:org >&2
}

# offer_gh_login: setup's first run on a Mac where gh is installed but never
# logged in. Offers `gh auth login` on a terminal so the preflight that follows
# can pass, instead of stopping the user to run it and start over. Every
# outcome falls through to preflight, which reports whatever login state is
# left, with the same fix command; this changes nothing itself. Only setup
# calls it: preflight stays read-only and diagnose never prompts. gh asks its
# own questions (account, protocol); the admin:org scope an organization's
# runner group needs is asked for in the same login when --url names an
# organization (#152), so that is one browser authorization, not two. Without
# a URL, or for a personal account or a repository URL, the login is gh's
# default, and offer_scope_refresh adds the scope later if it turns out to be
# needed.
# Not offered when gh cannot answer (a login would not fix that), or when any
# other check fails: a browser login would only be followed by the stop.
# offer_gh_login [url]
offer_gh_login() {
  command -v gh >/dev/null 2>&1 || return 0
  have_terminal || return 0
  local account answer i url="${1:-}" scopes=""
  account="$(gh_active_account)" || return 0
  [ -z "${account%%|*}" ] || return 0
  preflight_collect
  for ((i = 0; i < ${#PF_NAME[@]}; i++)); do
    [ "${PF_LEVEL[i]}" != fail ] || [ "${PF_NAME[i]}" = gh ] || return 0
  done
  if [ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ]; then
    # gh uses that variable instead of its stored login, so logging in
    # changes nothing for this command.
    echo "homefield: GITHUB_TOKEN or GH_TOKEN is set, and gh uses it instead of its stored login, so" >&2
    echo "homefield: 'gh auth login' would not help. Unset it, or use a valid token." >&2
    return 0
  fi
  login_wants_org_scope "$url" && scopes="admin:org"
  if [ -n "$scopes" ]; then
    url="${url%/}"
    printf "gh is not logged in. Run 'gh auth login -s admin:org' now? (%s's runner group needs that scope, so you authorize once) [Y/n] " "${url##*/}" >&2
  else
    printf "gh is not logged in. Run 'gh auth login' now? [Y/n] " >&2
  fi
  # End of input (Ctrl-D) is not a yes.
  read -r answer || return 0
  case "$answer" in [Nn]*) return 0 ;; esac
  if [ -n "$scopes" ]; then
    gh auth login -h github.com -s "$scopes" || echo "homefield: 'gh auth login' did not finish" >&2
  else
    gh auth login -h github.com || echo "homefield: 'gh auth login' did not finish" >&2
  fi
}

# login_wants_org_scope <url>: whether the inline login should ask for
# admin:org: --url is an organization's owner URL (the registration that
# creates a runner group). --org says so, --personal says no, and otherwise the
# owner is looked up as check_scope_owner does (the public API when gh is not
# logged in yet). A repository URL registers one repository and needs no
# group; an owner that cannot be looked up keeps gh's default login.
login_wants_org_scope() {
  local url="${1%/}" owner
  [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+)$ ]] || return 1
  owner="${BASH_REMATCH[1]}"
  case "$ACCOUNT_FORCE" in
    org) return 0 ;;
    personal) return 1 ;;
  esac
  [ "$(owner_type "$owner")" = Organization ]
}

# get_token <registration|remove> <url>: prints the token. From gh when it can,
# else pasted; never echoed.
get_token() {
  local kind="$1" url="$2" scope out token=""
  scope="$(api_scope "$url")" || exit 1
  # On an error gh prints the error body to stdout, so only its exit status
  # says whether this is a token.
  if command -v gh >/dev/null; then
    if out="$(gh api -X POST "${scope}/actions/runners/${kind}-token" -q .token 2>/dev/null)"; then
      token="$out"
    elif [[ "$scope" == orgs/* ]] && offer_scope_refresh &&
      out="$(gh api -X POST "${scope}/actions/runners/${kind}-token" -q .token 2>/dev/null)"; then
      token="$out"
    fi
  fi
  if [ -z "$token" ]; then
    [ -t 0 ] || die "could not get a ${kind} token with gh, and no terminal to paste one"
    echo "homefield: could not get a ${kind} token with gh (needs org owner + admin:org, or repository admin)." >&2
    echo "homefield: get one from $(runners_page "$url")/new and paste only the token." >&2
    read -rsp "${kind} token: " token
    echo >&2
  fi
  [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]] || die "that does not look like a ${kind} token"
  printf '%s' "$token"
}

# Whether the URL's owner is a personal account or an organization decides the
# registration: an organization can have an account-wide runner and runner
# groups, a personal account only repository-scoped runners (GitHub's limit).
# --personal and --org set ACCOUNT_FORCE, which skips the lookup.
ACCOUNT_FORCE=""
# What check_scope_owner decided: "personal", "org", or "" when it could not
# tell (a repository URL whose owner could not be looked up).
ACCOUNT_MODE=""

# owner_type <owner>: prints GitHub's type for the account (User or
# Organization), or nothing when it cannot be told.
owner_type() {
  local out type=""
  # gh when it works, else the public API with curl (no python3 needed: a
  # stock Mac only has the stub that offers to install it).
  if command -v gh >/dev/null && out="$(gh api "users/${1}" -q .type 2>/dev/null </dev/null)"; then
    type="$out"
  elif out="$(curl -fsS "https://api.github.com/users/${1}" 2>/dev/null </dev/null)"; then
    type="$(printf '%s\n' "$out" | sed -n 's/^ *"type": *"\([A-Za-z]*\)".*/\1/p' | head -1)"
  fi
  printf '%s' "$type"
}

# check_scope_owner <url>: sets ACCOUNT_MODE for an owner or repository URL.
# An owner URL needs an organization: a personal account's is refused when
# there is no terminal to ask for a repository on, and an owner that cannot be
# looked up is refused. A repository URL worked without any lookup before, so
# one that fails is not fatal.
check_scope_owner() {
  local url="${1%/}" owner repo="" type=""
  ACCOUNT_MODE=""
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
  elif [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
  else
    return 0
  fi
  if [ -n "$ACCOUNT_FORCE" ]; then
    ACCOUNT_MODE="$ACCOUNT_FORCE"
  else
    type="$(owner_type "$owner")"
    case "$type" in
      Organization) ACCOUNT_MODE=org ;;
      User) ACCOUNT_MODE=personal ;;
      *) [ -n "$repo" ] || die "could not find ${owner} on GitHub (or reach api.github.com) to check that it is an organization; if it is one, pass --org to skip the check (--personal for a personal account)" ;;
    esac
  fi
  if [ "$ACCOUNT_MODE" = personal ] && [ -z "$repo" ] && ! have_terminal; then
    die "${owner} is a personal account, which cannot have account-wide runners; register a repository instead: --url https://github.com/${owner}/<repo>"
  fi
}

# validate_scope <url>: the URL's shape, and what kind of account owns it.
validate_scope() {
  api_scope "$1" >/dev/null
  check_scope_owner "$1"
}

# ask_url: prints the URL typed at the prompt. Needs a terminal; without one
# the URL has to come from --url.
ask_url() {
  local url
  [ -t 0 ] || die "install: --url is required for a new registration (no terminal to ask)"
  read -rp "GitHub organization or repository URL (https://github.com/<org> or https://github.com/<owner>/<repo>): " url
  [ -n "$url" ] || die "install: no URL given"
  printf '%s' "$url"
}

# ask_personal_repo <owner url>: prints the URL of the repository, in that
# personal account, that the typed answer names (a name, or a full URL).
# Needs a terminal; check_scope_owner has already refused without one.
ask_personal_repo() {
  local owner="${1%/}" answer url
  owner="${owner##*/}"
  echo "homefield: ${owner} is a personal account, which cannot have account-wide runners: a runner is registered for one repository." >&2
  read -rp "Repository of ${owner} to register for (name, or full URL): " answer
  [ -n "$answer" ] || die "install: no repository given"
  case "$answer" in
    https://*) url="${answer%/}" ;;
    *) url="https://github.com/${owner}/${answer}" ;;
  esac
  [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ && "$(lower "${BASH_REMATCH[1]}")" = "$(lower "$owner")" ]] ||
    die "install: not a repository of ${owner}: ${answer}"
  printf '%s' "$url"
}

# announce_account <url> <group>: says which kind of account the registration
# is for and, for a personal one, the two separate limits. The caller's --group
# is passed in so that it can say a personal account ignores it.
announce_account() {
  local slug="${1%/}" group="$2" how="detected"
  slug="${slug#https://github.com/}"
  [ -z "$ACCOUNT_FORCE" ] || how="forced by --${ACCOUNT_FORCE}"
  case "$ACCOUNT_MODE" in
    personal)
      log "personal account (${slug%%/*}), ${how}. Two separate limits apply:"
      log "  - GitHub: no account-wide runners and no runner groups, so each repository registers on its own."
      log "  - HomeField: one VM runs one runner (until #14), so each personal repository needs its own --instance."
      log "Registering this runner for the repository ${slug} only."
      [ -z "$group" ] || log "--group ${group} is ignored: a personal account has no runner groups."
      ;;
    org) log "organization (${slug%%/*}), ${how}." ;;
    *) log "could not check whether ${slug%%/*} is a personal account or an organization (neither gh nor api.github.com answered); going on without it. --personal or --org skips the check." ;;
  esac
}

# prepare_registration: for cmd_install, whose url, group, name and replace
# it reads and sets (bash functions see their caller's locals). Asks for the
# URL if there is none, validates it, says which kind of account it is (a
# personal one is asked for a repository if the URL is only its owner), sorts
# out the runner group and the name.
prepare_registration() {
  [ -n "$url" ] || url="$(ask_url)" || exit 1
  validate_scope "$url"
  if [ "$ACCOUNT_MODE" = personal ] && [[ "${url%/}" =~ ^https://github\.com/[A-Za-z0-9_.-]+$ ]]; then
    url="$(ask_personal_repo "$url")" || exit 1
  fi
  announce_account "$url" "$group"
  ensure_group "$url" "${group:-homefield-ci}"
  [ -n "$name" ] || name="$(default_name)" || exit 1
  check_name_free "$url" "$name" "$replace"
}

# default_name: prints <local hostname>-<instance>, lower case, with anything
# but letters, digits, '.', '_' and '-' replaced by '-'.
default_name() {
  local host
  host="$(scutil --get LocalHostName 2>/dev/null)" || host=""
  [ -n "$host" ] || die "install: could not read this Mac's name (scutil --get LocalHostName); pass --name"
  lower "${host}-${INSTANCE}" | tr -c 'a-z0-9._\n-' '-'
}

# check_name_free <url> <name> <replace>: refuses a name that is already
# registered in the scope, before anything is created. Registration would
# refuse it too (provision.sh never passes --replace), but only after the VM
# is built. Names are compared ignoring case. A runners list that cannot be
# read is not a reason to stop, except for --replace, which has to find the
# registration it removes.
#
# --replace removes the old registration (remove_taken_name, after token
# retrieval but before provisioning) rather than using config.sh's --replace,
# which keeps the old registration's runner group and ignores the one asked for
# (actions/runner#4091). Sets REPLACE_ID to the id to remove.
REPLACE_ID=""

check_name_free() {
  local url="$1" name="$2" replace="$3" scope rows n status id taken="" taken_id="" page
  scope="$(api_scope "$url")" || exit 1
  page="$(runners_page "$url")" || exit 1
  if ! command -v gh >/dev/null || ! rows="$(gh api --paginate "${scope}/actions/runners?per_page=100" \
    --jq '.runners[] | [.name, .status, (.id | tostring)] | @tsv' 2>/dev/null)"; then
    [ "$replace" != 1 ] || die "--replace needs gh to list the runners at ${url} (org owner + admin:org, or repository admin); remove ${name} at ${page} instead and run this again without --replace"
    log "could not list the runners at ${url} to check that ${name} is free; registration refuses it if it is not"
    return 0
  fi
  while IFS=$'\t' read -r n status id; do
    [ -n "$n" ] || continue
    if [ "$(lower "$n")" = "$(lower "$name")" ]; then
      taken="$status"
      taken_id="$id"
    fi
  done <<<"$rows"
  [ -n "$taken" ] || return 0
  if [ "$replace" = 1 ]; then
    if [ "$taken" = online ]; then
      echo "homefield: warning: ${name} is registered and online at ${url}; --replace removes its registration, and the runner that has it stops working" >&2
    else
      log "${name} is registered (${taken}) at ${url}; --replace removes that registration before registering"
    fi
    REPLACE_ID="$taken_id"
    return 0
  fi
  if [ "$taken" = online ]; then
    die "a runner named ${name} is already registered and online at ${url}, most likely on another machine; pick another name with --name (${page})"
  fi
  die "a runner named ${name} is already registered (${taken}) at ${url}. If it is this Mac's old registration, run this again with --replace; otherwise pick another name with --name, or remove it at ${page}"
}

# remove_taken_name <url> <name>: for --replace, removes the registration
# check_name_free found under the name, so this one registers fresh, in the
# group asked for. This follows token retrieval but precedes provisioning;
# a failure between removal and registration leaves the name unregistered.
remove_taken_name() {
  local url="$1" name="$2" scope
  [ -n "$REPLACE_ID" ] || return 0
  scope="$(api_scope "$url")" || exit 1
  log "removing the registration of ${name} (id ${REPLACE_ID}) at ${url}"
  gh api -X DELETE "${scope}/actions/runners/${REPLACE_ID}" >/dev/null ||
    die "could not remove ${name} at ${url}; remove it at $(runners_page "$url") and run this again without --replace"
  REPLACE_ID=""
}

# list_groups_ids <org>: one line per runner group, tab separated: name,
# visibility, allows_public_repositories and id (the id for the calls that
# address a group by it). Tabs, because a name may have spaces.
list_groups_ids() {
  gh api --paginate "orgs/${1}/actions/runner-groups?per_page=100" \
    --jq '.runner_groups[] | [.name, .visibility, (.allows_public_repositories | tostring), (.id | tostring)] | @tsv' 2>/dev/null </dev/null
}

# group_repositories <org> <group id>: the full names of the repositories a
# runner group admits, one per line. Meaningful for a group whose visibility is
# "selected"; the others admit repositories by their kind, not by a list.
group_repositories() {
  gh api --paginate "orgs/${1}/actions/runner-groups/${2}/repositories?per_page=100" \
    --jq '.repositories[].full_name' </dev/null 2>/dev/null
}

# group_runner_ids <org> <group id>: the ids of the runners in a runner group,
# one per line. GitHub's runner list does not say which group a runner is in,
# so the groups are asked instead.
group_runner_ids() {
  gh api --paginate "orgs/${1}/actions/runner-groups/${2}/runners?per_page=100" \
    --jq '.runners[].id' </dev/null 2>/dev/null
}

# find_runner_group <org> <runner id>: the runner-groups row (name, visibility,
# allows_public_repositories, id; tab separated) of the group the runner is in,
# found by asking each group which runners it holds. Status: 0 found (the row
# on stdout), 1 in none of the groups, 2 in none of the groups that answered
# (another group's list failed), 3 the groups cannot be listed.
find_runner_group() {
  local rows name vis pub gid ids unasked=0
  rows="$(list_groups_ids "$1" </dev/null)" || return 3
  while IFS=$'\t' read -r name vis pub gid; do
    [ -n "$gid" ] || continue
    if ids="$(group_runner_ids "$1" "$gid")"; then
      case $'\n'"$ids"$'\n' in
        *$'\n'"$2"$'\n'*)
          printf '%s\t%s\t%s\t%s\n' "$name" "$vis" "$pub" "$gid"
          return 0
          ;;
      esac
    else
      unasked=1
    fi
  done <<<"$rows"
  [ "$unasked" = 0 ] || return 2
  return 1
}

# group_unchecked <group> <why>: the group could not be checked or created.
# Registering anyway would put the runner in a group nobody has looked at, or
# fail at the end, so ask first (default no); without a terminal, stop.
group_unchecked() {
  echo "homefield: could not check or create the runner group ${1}: ${2}" >&2
  echo "homefield: create it by hand (docs/runbook.md, \"Runner group\"): selected repositories, public repositories off." >&2
  [ -t 0 ] || die "stopping: the runner group ${1} is unchecked and there is no terminal to ask (if you created and checked it, pass --group-exists)"
  local answer
  read -rp "Continue without checking the group? [y/N] " answer
  case "$answer" in
    [Yy]*) ;;
    *) die "stopped: create the group ${1}, then run this again" ;;
  esac
}

group_assumed() {
  [ "$GROUP_EXISTS" = 1 ] || return 1
  log "runner group ${1}: not checked (${2}); going on because of --group-exists"
}

# token_hint: without a terminal offer_scope_refresh says nothing, so say here
# that gh may have a login with admin:org behind GITHUB_TOKEN or GH_TOKEN.
token_hint() {
  [ ! -t 0 ] && [ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ] || return 0
  echo "homefield: GITHUB_TOKEN or GH_TOKEN is set, and gh uses it instead of its stored login. If that login has admin:org, run this again with them empty for this one command: GITHUB_TOKEN= GH_TOKEN= homefield install ..." >&2
}

# group_wide <org> <vis> <pub>: why a runner group is wider than it should be
# — "every repository in <org> can use it", "every private repository…", and
# "public repositories can use it", joined with ", and "; "" when it is
# narrow. One definition: ensure_group's warning and diagnose's problem line
# must name the same widths the same way.
group_wide() {
  local why=""
  case "$2" in
    all) why="every repository in $1 can use it" ;;
    private) why="every private repository in $1 can use it" ;;
  esac
  [ "$3" != true ] || why="${why:+${why}, and }public repositories can use it"
  printf '%s' "$why"
}

# ensure_group <url> <group>: for an organization URL, finds the group by name
# and warns when it is wider than it should be, or creates it. A repository
# URL has no groups, and Default always exists. GitHub treats group names
# case-insensitively, so they are compared that way. A personal account
# (ACCOUNT_MODE) has no groups at all: nothing is asked of GitHub.
ensure_group() {
  local url="$1" group="${2:-homefield-ci}" scope org groups="" name vis pub found=0 why="" out gid
  GROUP_ID=""
  scope="$(api_scope "$url")" || exit 1
  if [ "$ACCOUNT_MODE" = personal ]; then
    GROUP_STATE=personal
    return 0
  fi
  if [[ "$scope" != orgs/* ]]; then
    GROUP_STATE=repo
    return 0
  fi
  if [ "$(lower "$group")" = default ]; then
    GROUP_STATE=default
    return 0
  fi
  org="${scope#orgs/}"
  GROUP_STATE=unchecked

  if ! command -v gh >/dev/null; then
    group_assumed "$group" "gh is not installed" || group_unchecked "$group" "gh is not installed"
    return 0
  fi
  if ! groups="$(list_groups_ids "$org")"; then
    if offer_scope_refresh; then
      groups="$(list_groups_ids "$org")" || why="gh could not list the organization's runner groups, even after the scope refresh"
    else
      why="gh could not list the organization's runner groups (needs an org owner with the admin:org scope)"
    fi
    if [ -n "$why" ]; then
      group_assumed "$group" "$why" && return 0
      token_hint
      group_unchecked "$group" "$why"
      return 0
    fi
  fi
  # Listing groups needs admin:org, so the scope is there: a later failure
  # (the registration token) has another cause, and a refresh would not help.
  scope_refresh_asked=1

  while IFS=$'\t' read -r name vis pub gid; do
    [ "$(lower "$name")" = "$(lower "$group")" ] || continue
    found=1
    why="$(group_wide "$org" "$vis" "$pub")"
    if [ -n "$why" ]; then
      GROUP_STATE=wide
      echo "homefield: warning: runner group ${name} is wider than it should be: ${why}." >&2
      echo "homefield: narrow it to selected repositories with public ones off (docs/runbook.md, \"Runner group\")." >&2
    else
      GROUP_STATE=narrow
      # Recorded now, before the VM exists, so that a failed install still
      # leaves reset the one fact it needs to undo this (the first "id" in the
      # response is the group's). Without an id, reset finds the group by name.
      # shellcheck disable=SC2034  # read by cmd-install.sh
      GROUP_ID="$gid"
      log "runner group ${name} exists (selected repositories only, no public ones)"
    fi
  done <<<"$groups"
  [ "$found" = 0 ] || return 0

  [ "$GROUP_EXISTS" = 0 ] ||
    echo "homefield: warning: --group-exists, but gh listed the runner groups of ${org} and ${group} is not among them" >&2
  log "creating runner group ${group}: selected repositories, public repositories off"
  if ! out="$(gh api -X POST "orgs/${org}/actions/runner-groups" -f name="$group" -f visibility=selected \
    -F allows_public_repositories=false 2>&1)"; then
    # Only wording about the plan counts as a plan problem. A bare 403 or 422
    # can be SAML enforcement, a missing permission or a taken name, and the
    # plan advice (--group Default) would open the runner to every repository.
    case "$(lower "$out")" in
      *saml*)
        group_unchecked "$group" "the organization enforces SAML single sign-on and gh's token is not authorized for it (authorize it for SSO, or gh auth refresh): ${out}"
        ;;
      *plan* | *upgrade* | *"not available"*)
        echo "homefield: gh said: ${out}" >&2
        die "could not create runner group ${group}: custom runner groups need the GitHub Team plan or Enterprise. On the Free plan, pass --group Default (every repository in ${org} can then use the runner, so only do that if you trust them all) or use a repository URL (https://github.com/<owner>/<repo>)"
        ;;
      *)
        group_unchecked "$group" "gh said: ${out} (custom runner groups need the Team plan or Enterprise)"
        ;;
    esac
    return 0
  fi
  # shellcheck disable=SC2034  # read by cmd-install.sh and cmd-adopt.sh
  GROUP_STATE=created
  # Recorded now, before the VM exists, so that a failed install still leaves
  # reset the one fact it needs to undo this (the first "id" in the response is
  # the group's). Without an id, reset finds the group by its name.
  gid="$(printf '%s' "$out" | grep -o '"id": *[0-9][0-9]*' | head -1 | tr -cd '0-9')" || gid=""
  GROUP_ID="$gid"
  state_set group_created "${org}/${group}/${gid}" ||
    echo "homefield: warning: could not record that this install created the runner group ${group} (${org}); reset will not delete it, so remove it by hand if you roll back (docs/runbook.md, \"Rolling back a failed install\")" >&2
  log "created runner group ${group}. No repository can use it yet: homefield adopt --repo <owner>/<repo> adds one (docs/adopting.md, step 5)"
}

# group_assumed <group> <why>: with --group-exists, a group gh cannot list is
# What ensure_group found, for the closing message: "personal" (a personal
# The id of the group GROUP_STATE "narrow" or "created" is about (empty when

# taken as there, and the closing message still says it is unchecked. Only for
# a group gh could not look at: a list that worked and lacks it is not
# overridden. Registration fails if the group is missing after all.
# shellcheck disable=SC2034  # GROUP_EXISTS is set by cmd-install's --group-exists
GROUP_EXISTS=0

# account has no groups), "repo" (no groups), "default" (every repository in
# the org), "wide" (warned about), "narrow", "created" or "unchecked".
# shellcheck disable=SC2034  # read by cmd-install.sh's group lines
GROUP_STATE=""
# unknown, or for any other state), for the listing of its repositories.
# shellcheck disable=SC2034  # read by cmd-install.sh and cmd-adopt.sh
GROUP_ID=""
