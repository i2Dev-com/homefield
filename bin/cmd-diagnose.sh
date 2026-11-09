#!/usr/bin/env bash
# The diagnose command: collection and the two renderings.

# What diagnose found. A state is a short word; "skipped" says the question was
# not asked, and DG_SKIP_WHY why (the first reason the guest checks stopped).
DG_CREATED="" DG_VM_STATUS="" DG_GUEST="" DG_SKIP_WHY=""
DG_ISO="" DG_ISO_WHY="" DG_REG="" DG_NAME="" DG_URL="" DG_ID=""
DG_GH="" DG_GH_WHY="" DG_GH_STATUS="" DG_GH_BUSY=""
DG_SVC="" DG_UNIT="" DG_VER="" DG_PKGS_STATE="" DG_PKGS="" DG_NPM=""
DG_SCOPE="" DG_GROUP="" DG_GROUP_WHY="" DG_GROUP_NAME="" DG_GROUP_ID=""
DG_GROUP_VIS="" DG_GROUP_PUB="" DG_REPOS=""
DG_P_CHECK=() DG_P_MSG=() DG_P_FIX=() DG_WARN=() DG_HINT=()

dg_reset() {
  DG_CREATED="unknown" DG_VM_STATUS="" DG_GUEST="skipped" DG_SKIP_WHY=""
  DG_ISO="skipped" DG_ISO_WHY="" DG_REG="skipped" DG_NAME="" DG_URL="" DG_ID=""
  DG_GH="skipped" DG_GH_WHY="" DG_GH_STATUS="" DG_GH_BUSY=""
  DG_SVC="skipped" DG_UNIT="" DG_VER="" DG_PKGS_STATE="skipped" DG_PKGS="" DG_NPM="skipped"
  DG_SCOPE="" DG_GROUP="skipped" DG_GROUP_WHY="" DG_GROUP_NAME="" DG_GROUP_ID=""
  DG_GROUP_VIS="" DG_GROUP_PUB="" DG_REPOS=""
  DG_P_CHECK=() DG_P_MSG=() DG_P_FIX=() DG_WARN=() DG_HINT=()
}

# dg_problem <check> <what is wrong> <what fixes it>: makes the run exit 1.
dg_problem() {
  DG_P_CHECK+=("$1")
  DG_P_MSG+=("$2")
  DG_P_FIX+=("$3")
}

# dg_collect_guest: the checks that ask the VM, for one that is Running. They
# stop at the first answer that makes the rest meaningless (the guest cannot be
# asked, no runner is registered), saying so in DG_SKIP_WHY.
dg_collect_guest() {
  local rc=0 on=0 raw words=() i
  DG_GUEST="checked"
  isolation_probe || rc=$?
  case "$rc" in
    0) DG_ISO="verified" ;;
    1)
      DG_ISO="failed"
      DG_ISO_WHY="$ISOLATION_WHY"
      dg_problem isolation "$ISOLATION_WHY" "recreate the VM without host mounts: bin/homefield uninstall --instance ${INSTANCE}, then install again (docs/runbook.md, \"Setup\")"
      ;;
    *)
      DG_ISO="unknown"
      DG_ISO_WHY="$ISOLATION_WHY"
      DG_SKIP_WHY="the VM could not be asked"
      dg_problem isolation "$ISOLATION_WHY" "limactl shell ${INSTANCE} true shows why the VM does not answer"
      return 0
      ;;
  esac
  rc=0
  registered || rc=$?
  case "$rc" in
    0) DG_REG="yes" ;;
    1)
      DG_REG="no"
      DG_SKIP_WHY="no runner is registered"
      dg_problem registration "no runner is registered in VM ${INSTANCE}" "bin/homefield install --instance ${INSTANCE} --url https://github.com/<org>[/<repo>]"
      return 0
      ;;
    *)
      DG_REG="unknown"
      DG_SKIP_WHY="the VM could not be asked"
      dg_problem registration "could not ask VM ${INSTANCE} whether its runner is registered" "limactl shell ${INSTANCE} true shows why the VM does not answer"
      return 0
      ;;
  esac
  load_runner_settings
  DG_NAME="$RS_NAME" DG_URL="$RS_URL" DG_ID="$RS_ID"
  if [ -z "$DG_NAME" ] || [ -z "$DG_URL" ]; then
    DG_GH_WHY="the runner's settings could not be read"
    dg_problem registration "the runner is registered, but its settings (${RUNNER_HOME}/.runner) could not be read" "see docs/runbook.md, \"Failure modes\""
  else
    runner_on_github "$DG_URL" "$DG_ID" || on=$?
    case "$on" in
      0)
        DG_GH="listed"
        DG_GH_STATUS="$RUNNER_GH_STATUS"
        DG_GH_BUSY="$RUNNER_GH_BUSY"
        if [ "$DG_GH_STATUS" = offline ]; then
          dg_problem github "GitHub lists the runner ${DG_NAME} as offline" "see docs/runbook.md, \"Failure modes\" (the service below, and the VM's network)"
        fi
        ;;
      1)
        DG_GH="not-listed"
        dg_problem github "GitHub does not list the runner ${DG_NAME}: it removes runners that have not connected for more than 14 days" "$(removed_recovery "$DG_URL" "$DG_NAME")"
        ;;
      3)
        DG_GH="timed-out"
        DG_GH_WHY="timed out after ${GH_TIMEOUT}s; the network may be down"
        dg_warn "GitHub was not asked: ${DG_GH_WHY}"
        ;;
      *)
        DG_GH="not-checked"
        if [ -n "$DG_ID" ]; then
          DG_GH_WHY="needs gh with admin access to ${DG_URL}"
        else
          DG_GH_WHY="no runner id in the VM's settings"
        fi
        dg_warn "GitHub was not asked: ${DG_GH_WHY}"
        ;;
    esac
  fi
  if runner_service_state; then
    DG_SVC="running"
    DG_UNIT="$SERVICE_UNIT"
  else
    DG_SVC="stopped"
    DG_UNIT="$SERVICE_UNIT"
    if [ -n "$SERVICE_UNIT" ]; then
      dg_problem service "the runner's service ${SERVICE_UNIT} is not running" "limactl shell ${INSTANCE} sudo systemctl start ${SERVICE_UNIT}"
    else
      dg_problem service "the runner has no service installed" "bin/homefield install --instance ${INSTANCE} (on a registered runner this re-provisions it)"
    fi
  fi
  DG_VER="$(runner_version)"
  raw="$(runner_extra_packages)"
  read -ra words <<<"$raw"
  for ((i = 0; i < ${#words[@]}; i++)); do
    DG_PKGS="${DG_PKGS:+$DG_PKGS }${words[i]}"
  done
  DG_PKGS_STATE="listed"
  rc=0
  npm_state || rc=$?
  case "$rc" in
    0) DG_NPM="ok" ;;
    1)
      DG_NPM="broken"
      dg_problem npm "the runner's bundled npm is broken: JS actions fail at \"Set up runner\"" "bin/homefield upgrade --instance ${INSTANCE} (docs/runbook.md, \"Runner updates\")"
      ;;
    *)
      DG_NPM="unknown"
      dg_problem npm "could not ask VM ${INSTANCE} whether the runner's npm works" "limactl shell ${INSTANCE} true shows why the VM does not answer"
      ;;
  esac
}

# dg_collect_vm: whether the VM is there, and for a Running one the guest
# checks. Anything else is reported and the guest is left alone.
dg_collect_vm() {
  if ! command -v limactl >/dev/null 2>&1; then
    # The prerequisites already carry this as a problem.
    DG_SKIP_WHY="Lima is not installed"
    return 0
  fi
  if ! DG_VM_STATUS="$(vm_status)"; then
    DG_VM_STATUS=""
    DG_SKIP_WHY="Lima could not be asked"
    dg_problem vm "could not ask Lima about VM ${INSTANCE} (limactl list failed, or lists it without a status)" "limactl list"
    return 0
  fi
  if [ -z "$DG_VM_STATUS" ]; then
    DG_CREATED="no"
    DG_SKIP_WHY="the VM does not exist"
    dg_problem vm "VM ${INSTANCE} is not created" "bin/homefield install --instance ${INSTANCE} --url https://github.com/<org>[/<repo>]"
    return 0
  fi
  DG_CREATED="yes"
  if [ "$DG_VM_STATUS" != "Running" ]; then
    DG_SKIP_WHY="the VM is ${DG_VM_STATUS}, and diagnose never starts it"
    dg_problem vm "VM ${INSTANCE} is ${DG_VM_STATUS}, not Running: the runner takes no jobs" "bin/homefield start --instance ${INSTANCE}"
    return 0
  fi
  dg_collect_guest
}

# dg_collect_group: the runner group the runner is in, from GitHub. Only an
# organization's runner has one; a repository's (and so a personal account's)
# registration has none, which is not an error.
dg_collect_group() {
  local scope org row name vis pub gid rc wide="" repos
  if [ -z "$DG_URL" ]; then
    DG_GROUP_WHY="$DG_SKIP_WHY"
    [ -n "$DG_GROUP_WHY" ] || DG_GROUP_WHY="the runner's registration was not read"
    return 0
  fi
  if ! scope="$(api_scope "$DG_URL" 2>/dev/null)"; then
    DG_GROUP_WHY="the runner's URL (${DG_URL}) is not an organization or repository"
    return 0
  fi
  case "$scope" in
    repos/*)
      DG_SCOPE="repository"
      DG_GROUP="n/a"
      return 0
      ;;
  esac
  DG_SCOPE="organization"
  org="${scope#orgs/}"
  if [ "$DG_GH" != "listed" ]; then
    DG_GROUP_WHY="GitHub did not list the runner, so its group is unknown"
    return 0
  fi
  # Reached only after GitHub answered the runner list in time (see above).
  # The runner list names no group, so find_runner_group asks each group which
  # runners it holds.
  rc=0
  row="$(find_runner_group "$org" "$DG_ID")" || rc=$?
  if [ "$rc" = 3 ]; then
    DG_GROUP="not-checked"
    DG_GROUP_WHY="gh could not list the runner groups of ${org} (needs an organization owner with the admin:org scope)"
    dg_warn "runner group not checked: ${DG_GROUP_WHY}; gh auth refresh -h github.com -s admin:org"
    return 0
  fi
  if [ "$rc" != 0 ]; then
    DG_GROUP="not-checked"
    if [ "$rc" = 2 ]; then
      DG_GROUP_WHY="gh could not list the runners of every runner group in ${org}, and the runner is in none of the others"
    else
      DG_GROUP_WHY="the runner (id ${DG_ID}) is in none of the runner groups gh listed for ${org}"
    fi
    dg_warn "runner group not checked: ${DG_GROUP_WHY}"
    return 0
  fi
  IFS=$'\t' read -r name vis pub gid <<<"$row"
  DG_GROUP="checked"
  DG_GROUP_NAME="$name" DG_GROUP_ID="$gid" DG_GROUP_VIS="$vis" DG_GROUP_PUB="$pub"
  # The same test as ensure_group's. The Default group is open to the whole
  # organization on purpose on a plan without custom groups (docs/runbook.md,
  # "Plans"), so that alone is a note; public repositories are never fine.
  wide="$(group_wide "$org" "$vis" "$pub")"
  if [ -n "$wide" ]; then
    if [ "$(lower "$name")" = default ] && [ "$pub" != true ]; then
      dg_warn "runner group ${name}: ${wide}; right only if you trust every repository in ${org} (docs/runbook.md, \"Runner group\")"
    else
      dg_problem group "runner group ${name} is wider than it should be: ${wide}" "narrow it to selected repositories with public ones off in ${org}'s Actions settings, Runner groups (docs/runbook.md, \"Runner group\")"
    fi
  fi
  if [ "$vis" = selected ]; then
    if repos="$(group_repositories "$org" "$gid")"; then
      DG_REPOS="$repos"
      if [ -z "$repos" ]; then
        dg_hint "no repository is in runner group ${name} yet: bin/homefield adopt --repo <owner>/<repo>"
      fi
    else
      DG_GROUP="not-checked"
      DG_GROUP_WHY="gh could not list the repositories of runner group ${name}"
      dg_warn "runner group ${name}: ${DG_GROUP_WHY}"
    fi
  fi
}

# dg_collect_prerequisites: preflight's checks, from the same code. A failed
# check is a problem (its message names the fix); a warning is shown with the
# checks and is not a problem, as in preflight.
dg_collect_prerequisites() {
  local i
  # In a run over several VMs the prerequisites are collected and printed once,
  # by the parent: they do not differ per instance (#182).
  [ "${HOMEFIELD_DIAGNOSE_SKIP_PREREQS:-}" != 1 ] || return 0
  preflight_collect
  for ((i = 0; i < ${#PF_NAME[@]}; i++)); do
    [ "${PF_LEVEL[i]}" != fail ] || dg_problem "prerequisite:${PF_NAME[i]}" "${PF_MSG[i]}" ""
  done
}

# dg_render_prereqs: the Prerequisites section, between two blank lines as in
# the single-VM report; a multi-VM run prints it once before its VM blocks.
dg_render_prereqs() {
  local i n=${#PF_NAME[@]}
  echo ""
  echo "Prerequisites:"
  for ((i = 0; i < n; i++)); do
    pf_render_row "- " "$i"
  done
  echo ""
}

# dg_json_prereqs: the prerequisites array alone, for both JSON forms.
dg_json_prereqs() {
  local i n=${#PF_NAME[@]} first=1
  printf '['
  for ((i = 0; i < n; i++)); do
    [ "$first" = 1 ] || printf ','
    first=0
    printf '\n    {"name": %s, "status": %s, "message": %s}' "$(json_str "${PF_NAME[i]}")" "$(json_str "${PF_LEVEL[i]}")" "$(json_str "${PF_MSG[i]}")"
  done
  printf '\n  ]'
}

# dg_gh_text: the "On GitHub" line.
dg_gh_text() {
  case "$DG_GH" in
    listed)
      if [ -n "$DG_GH_STATUS" ]; then
        local busy=""
        if [ "$DG_GH_BUSY" = true ]; then busy=", busy"; elif [ "$DG_GH_BUSY" = false ]; then busy=", idle"; fi
        echo "listed (${DG_GH_STATUS}${busy})"
      else
        echo "listed"
      fi
      ;;
    not-listed) echo "NOT listed (GitHub removes runners that have not connected for more than 14 days)" ;;
    timed-out | not-checked) echo "not checked (${DG_GH_WHY})" ;;
    *) echo "skipped (${DG_SKIP_WHY:-${DG_GH_WHY}})" ;;
  esac
}

dg_render_human() {
  local i n why repo list
  why="${DG_SKIP_WHY:-nothing to ask}"
  echo "VM ${INSTANCE}:"
  case "$DG_CREATED" in
    yes) echo "  - Created: yes (${DG_VM_STATUS})" ;;
    no) echo "  - Created: no" ;;
    *) echo "  - Created: unknown" ;;
  esac
  if [ "$DG_GUEST" != "checked" ]; then
    echo "  - Guest checks: skipped (${why})"
  else
    case "$DG_ISO" in
      verified) echo "  - Isolation: verified (no host data mounts, /Users hidden)" ;;
      failed) echo "  - Isolation: $(color_wrap 3 "BROKEN") (${DG_ISO_WHY})" ;;
      *) echo "  - Isolation: unknown (${DG_ISO_WHY})" ;;
    esac
    case "$DG_REG" in
      yes)
        if [ -n "$DG_NAME" ] && [ -n "$DG_URL" ]; then
          echo "  - Registered: yes (${DG_NAME}${DG_ID:+, id ${DG_ID}}, at ${DG_URL})"
        else
          echo "  - Registered: yes (its details could not be read)"
        fi
        ;;
      no) echo "  - Registered: no" ;;
      unknown) echo "  - Registered: unknown (could not ask the VM)" ;;
      *) echo "  - Registered: skipped (${why})" ;;
    esac
    if [ "$DG_REG" = yes ]; then
      echo "  - On GitHub: $(dg_gh_text)"
      case "$DG_SVC" in
        running) echo "  - Service: running (${DG_UNIT})" ;;
        *) echo "  - Service: $(color_wrap 3 "NOT running") (${DG_UNIT:-no service installed})" ;;
      esac
      echo "  - Version: ${DG_VER}"
      echo "  - Extra packages: ${DG_PKGS:-none}"
      case "$DG_NPM" in
        ok) echo "  - npm: $(color_wrap 1 ok)" ;;
        broken) echo "  - npm: $(color_wrap 3 "BROKEN") (a runner self-update can flatten the externals symlinks; docs/runbook.md, \"Runner updates\")" ;;
        *) echo "  - npm: unknown (could not ask the VM)" ;;
      esac
    else
      echo "  - On GitHub: skipped (${why})"
      echo "  - Service: skipped (${why})"
      echo "  - Version: skipped (${why})"
      echo "  - Extra packages: skipped (${why})"
      echo "  - npm: skipped (${why})"
    fi
  fi
  echo ""
  echo "GitHub:"
  case "$DG_GROUP" in
    n/a)
      echo "  - Group: n/a (repository-scoped registration)"
      echo "  - Repositories in group: n/a (a repository-scoped runner serves only ${DG_URL#https://github.com/})"
      ;;
    checked | not-checked)
      if [ -n "$DG_GROUP_NAME" ]; then
        list="${DG_GROUP_VIS} repositories"
        [ "$DG_GROUP_VIS" != selected ] || list="selected repositories"
        echo "  - Group: ${DG_GROUP_NAME} (${list}, public $([ "$DG_GROUP_PUB" = true ] && echo on || echo off))"
        case "$DG_GROUP_VIS" in
          selected)
            if [ "$DG_GROUP" = "not-checked" ]; then
              echo "  - Repositories in group: not checked (${DG_GROUP_WHY})"
            elif [ -z "$DG_REPOS" ]; then
              echo "  - Repositories in group: none (run 'bin/homefield adopt --repo <owner>/<repo>')"
            else
              list=""
              while IFS= read -r repo; do
                [ -n "$repo" ] || continue
                list="${list:+${list}, }${repo}"
              done <<<"$DG_REPOS"
              echo "  - Repositories in group: ${list}"
            fi
            ;;
          private) echo "  - Repositories in group: every private repository in the organization" ;;
          *) echo "  - Repositories in group: every repository in the organization" ;;
        esac
      else
        echo "  - Group: not checked (${DG_GROUP_WHY})"
      fi
      ;;
    *) echo "  - Group: skipped (${DG_GROUP_WHY:-${why}})" ;;
  esac
  [ "${HOMEFIELD_DIAGNOSE_SKIP_PREREQS:-}" = 1 ] || dg_render_prereqs
  n=${#DG_P_MSG[@]}
  if [ "$n" -eq 0 ]; then
    if [ "${#DG_WARN[@]}" -eq 0 ]; then
      printf '%s\n' "$(color_wrap 1 "Summary: healthy.")"
    else
      printf '%s\n' "$(color_wrap 1 "Summary: healthy as far as it could be checked.")"
    fi
  else
    if [ "$n" -eq 1 ]; then printf '%s\n' "$(color_wrap 3 "Summary: 1 problem found.")"; else printf '%s\n' "$(color_wrap 3 "Summary: ${n} problems found.")"; fi
    for ((i = 0; i < n; i++)); do
      printf '  %d. %s\n' "$((i + 1))" "$(color_wrap 3 "${DG_P_MSG[i]}")"
      [ -z "${DG_P_FIX[i]}" ] || echo "     Fix: ${DG_P_FIX[i]}"
    done
  fi
  for ((i = 0; i < ${#DG_WARN[@]}; i++)); do
    echo "  Note: ${DG_WARN[i]}"
  done
  if [ "$n" -eq 0 ]; then
    for ((i = 0; i < ${#DG_HINT[@]}; i++)); do
      echo "  Next: ${DG_HINT[i]}"
    done
  else
    echo "  The other failure modes: docs/runbook.md, \"Failure modes\"."
  fi
}

dg_render_json() {
  local i n first
  printf '{\n'
  printf '  "instance": %s,\n' "$(json_str "$INSTANCE")"
  if [ "${#DG_P_MSG[@]}" -eq 0 ]; then printf '  "healthy": true,\n'; else printf '  "healthy": false,\n'; fi
  printf '  "vm": {\n'
  printf '    "created": %s,\n' "$(json_bool "$DG_CREATED")"
  printf '    "status": %s,\n' "$(json_nstr "$DG_VM_STATUS")"
  printf '    "guest_checked": %s,\n' "$([ "$DG_GUEST" = checked ] && echo true || echo false)"
  printf '    "skipped_reason": %s,\n' "$(json_nstr "$DG_SKIP_WHY")"
  printf '    "isolation": {"state": %s, "detail": %s},\n' "$(json_str "$DG_ISO")" "$(json_nstr "$DG_ISO_WHY")"
  printf '    "registered": %s,\n' "$(json_bool "$DG_REG")"
  if [ "$DG_REG" = yes ]; then
    printf '    "runner": {"name": %s, "id": %s, "url": %s},\n' "$(json_nstr "$DG_NAME")" "$(json_nstr "$DG_ID")" "$(json_nstr "$DG_URL")"
  else
    printf '    "runner": null,\n'
  fi
  printf '    "on_github": {"state": %s, "status": %s, "busy": %s, "detail": %s},\n' \
    "$(json_str "$DG_GH")" "$(json_nstr "$DG_GH_STATUS")" "$(json_bool "$DG_GH_BUSY")" "$(json_nstr "$DG_GH_WHY")"
  printf '    "service": {"state": %s, "unit": %s},\n' "$(json_str "$DG_SVC")" "$(json_nstr "$DG_UNIT")"
  printf '    "version": %s,\n' "$(json_nstr "$DG_VER")"
  if [ "$DG_PKGS_STATE" = listed ]; then
    printf '    "extra_packages": %s,\n' "$(json_words "$DG_PKGS")"
  else
    printf '    "extra_packages": null,\n'
  fi
  printf '    "npm": %s\n' "$(json_str "$DG_NPM")"
  printf '  },\n'
  printf '  "github": {\n'
  printf '    "scope": %s,\n' "$(json_nstr "$DG_SCOPE")"
  printf '    "group": {"state": %s, "name": %s, "id": %s, "visibility": %s, "allows_public": %s, "repositories": ' \
    "$(json_str "$DG_GROUP")" "$(json_nstr "$DG_GROUP_NAME")" "$(json_nstr "$DG_GROUP_ID")" "$(json_nstr "$DG_GROUP_VIS")" "$(json_bool "$DG_GROUP_PUB")"
  if [ "$DG_GROUP_VIS" = selected ] && [ "$DG_GROUP" = checked ]; then json_lines "$DG_REPOS"; else printf null; fi
  printf ', "detail": %s}\n' "$(json_nstr "$DG_GROUP_WHY")"
  printf '  },\n'
  if [ "${HOMEFIELD_DIAGNOSE_SKIP_PREREQS:-}" != 1 ]; then
    printf '  "prerequisites": '
    dg_json_prereqs
    printf ',\n'
  fi
  printf '  "problems": ['
  n=${#DG_P_MSG[@]}
  first=1
  for ((i = 0; i < n; i++)); do
    [ "$first" = 1 ] || printf ','
    first=0
    printf '\n    {"check": %s, "message": %s, "fix": %s}' "$(json_str "${DG_P_CHECK[i]}")" "$(json_str "${DG_P_MSG[i]}")" "$(json_nstr "${DG_P_FIX[i]}")"
  done
  if [ "$n" -eq 0 ]; then printf '],\n'; else printf '\n  ],\n'; fi
  printf '  "warnings": ['
  n=${#DG_WARN[@]}
  first=1
  for ((i = 0; i < n; i++)); do
    [ "$first" = 1 ] || printf ', '
    first=0
    json_str "${DG_WARN[i]}"
  done
  printf '],\n'
  printf '  "hints": ['
  n=${#DG_HINT[@]}
  first=1
  for ((i = 0; i < n; i++)); do
    [ "$first" = 1 ] || printf ', '
    first=0
    json_str "${DG_HINT[i]}"
  done
  printf ']\n}\n'
}

# diagnose_single: one VM's report, prerequisites included; cmd_diagnose runs it
# for every VM by default and prints the prerequisites once instead.
diagnose_single() {
  local json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      *) die "diagnose: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  dg_reset
  dg_collect_prerequisites
  dg_collect_vm
  dg_collect_group
  if [ "$json" = 1 ]; then dg_render_json; else dg_render_human; fi
  [ "${#DG_P_MSG[@]}" -eq 0 ]
}

# diagnose_many <names> <json>: every VM on this Mac, each its own report as
# its own process (so one cannot affect the next), with the prerequisites
# collected and printed once because they do not differ per instance. The JSON
# form wraps the single-VM objects: instances, healthy, prerequisites, vms.
diagnose_many() {
  local names="$1" json="$2" name rc=0 first=1 i fails=0 out child_rc=0
  preflight_collect
  for ((i = 0; i < ${#PF_NAME[@]}; i++)); do
    [ "${PF_LEVEL[i]}" != fail ] || fails=$((fails + 1))
  done
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
      out="$(HOMEFIELD_DIAGNOSE_SKIP_PREREQS=1 instance_command "$name" diagnose --json)" || child_rc=$?
      [ "$child_rc" = 0 ] || rc=1
      vms="${vms}${sep}${out}"
      sep=",
"
    done <<<"$names"
    if [ "$fails" != 0 ]; then rc=1; fi
    printf '  "healthy": %s,\n' "$([ "$rc" = 0 ] && echo true || echo false)"
    printf '  "prerequisites": '
    dg_json_prereqs
    printf ',\n'
    printf '  "vms": [\n%s\n  ]\n}\n' "$vms"
    return "$rc"
  fi
  dg_render_prereqs
  first=1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$first" = 1 ] || echo ""
    first=0
    HOMEFIELD_DIAGNOSE_SKIP_PREREQS=1 instance_command "$name" diagnose || rc=1
  done <<<"$names"
  if [ "$fails" != 0 ]; then
    echo "homefield: ${fails} prerequisite check(s) failed above; they affect every VM on this Mac." >&2
    rc=1
  fi
  return "$rc"
}

cmd_diagnose() {
  local json=0 opts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; opts+=(--json); shift ;;
      *) die "diagnose: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  local list="" name n=0
  if [ "$EXPLICIT_INSTANCE" = 0 ] && list="$(vm_instances)"; then
    while IFS= read -r name; do
      [ -z "$name" ] || n=$((n + 1))
    done <<<"$list"
    case "$n" in
      0)
        diagnose_single "${opts[@]+"${opts[@]}"}"
        return
        ;;
      1)
        while IFS= read -r name; do [ -z "$name" ] || break; done <<<"$list"
        INSTANCE="$name"
        diagnose_single "${opts[@]+"${opts[@]}"}"
        return
        ;;
    esac
    diagnose_many "$list" "$json"
    return
  fi
  # Explicit --instance, or a Lima that cannot be asked: the single report,
  # whose own messages stand (and include the prerequisites).
  diagnose_single "${opts[@]+"${opts[@]}"}"
}
