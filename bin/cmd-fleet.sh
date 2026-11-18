# shellcheck shell=bash
# HomeField CLI: fleet command (multi-VM status and start/stop sweep).
# Sourced by bin/homefield after bin/lib/*.sh and bin/cmd-install.sh.

_fleet_json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

fleet_status() {
  local json="${1:-0}"
  local instances=""
  if [ "${EXPLICIT_INSTANCE:-0}" = "1" ]; then
    instances="$INSTANCE"
  else
    if ! instances="$(vm_instances)"; then
      die "could not list HomeField VMs (is Lima installed?)"
    fi
  fi

  if [ -z "$instances" ]; then
    if [ "$json" = "1" ]; then
      printf '{"total":0,"online":0,"idle":0,"busy":0,"offline":0,"vms":[]}\n'
    else
      printf 'No HomeField VMs found on this Mac.\n'
    fi
    return 0
  fi

  local total=0 online=0 idle=0 busy=0 offline=0
  local json_items=""
  local rows=""
  local inst=""

  while IFS= read -r inst; do
    [ -n "$inst" ] || continue
    INSTANCE="$inst"
    # st_collect does not clear ST_NAME/ST_URL/ST_ID when a VM is stopped or unregistered.
    ST_NAME="" ST_GH_STATUS=""
    st_collect

    local vm_state="${ST_STATUS:-not created}"
    local runner_name="${ST_NAME:-—}"
    local gh_state="${ST_GH:-—}"
    if [ "$gh_state" = "listed" ]; then
      gh_state="${ST_GH_STATUS:-unknown}"
    fi
    local svc_state="${ST_SVC:-—}"
    local job_state="${ST_JOB:-—}"
    local mode="persistent"
    if [ "$(state_get ephemeral 2>/dev/null || true)" = "1" ]; then
      mode="ephemeral"
    fi

    total=$((total + 1))
    case "$gh_state" in
      online)
        online=$((online + 1))
        case "$job_state" in
          idle|"—")
            idle=$((idle + 1))
            ;;
          running)
            busy=$((busy + 1))
            ;;
        esac
        ;;
      busy)
        online=$((online + 1))
        busy=$((busy + 1))
        ;;
      *)
        offline=$((offline + 1))
        ;;
    esac

    if [ "$json" = "1" ]; then
      local item
      item=$(printf '{"instance":"%s","vm":"%s","runner":"%s","github":"%s","service":"%s","job":"%s","mode":"%s"}' \
        "$(_fleet_json_escape "$inst")" \
        "$(_fleet_json_escape "$vm_state")" \
        "$(_fleet_json_escape "$runner_name")" \
        "$(_fleet_json_escape "$gh_state")" \
        "$(_fleet_json_escape "$svc_state")" \
        "$(_fleet_json_escape "$job_state")" \
        "$(_fleet_json_escape "$mode")")
      if [ -n "$json_items" ]; then
        json_items="${json_items},${item}"
      else
        json_items="$item"
      fi
    else
      rows="${rows}$(printf '%-18s %-10s %-18s %-10s %-10s %-10s %s\n' \
        "$inst" "$vm_state" "$runner_name" "$gh_state" "$svc_state" "$job_state" "$mode")"$'\n'
    fi
  done <<< "$instances"

  if [ "$json" = "1" ]; then
    printf '{"total":%d,"online":%d,"idle":%d,"busy":%d,"offline":%d,"vms":[%s]}\n' \
      "$total" "$online" "$idle" "$busy" "$offline" "$json_items"
  else
    printf '%-18s %-10s %-18s %-10s %-10s %-10s %s\n' \
      "INSTANCE" "VM" "RUNNER" "GITHUB" "SERVICE" "JOB" "MODE"
    printf '%s' "$rows"
    printf 'Fleet: %d total, %d online (%d idle, %d busy), %d offline\n' \
      "$total" "$online" "$idle" "$busy" "$offline"
  fi
}

cmd_fleet() {
  local sub="status"
  local json=0

  if [ "$#" -gt 0 ]; then
    case "$1" in
      status|start|stop)
        sub="$1"
        shift
        ;;
      -h|--help)
        usage_for fleet
        return 0
        ;;
      --json)
        sub="status"
        ;;
      -*)
        die "unknown option for fleet: $1"
        ;;
      *)
        die "unknown fleet subcommand: $1 (expected status, start, or stop)"
        ;;
    esac
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        [ "$sub" = "status" ] || die "--json is only supported with 'fleet status'"
        json=1
        ;;
      -h|--help)
        usage_for fleet
        return 0
        ;;
      *)
        die "unknown option for fleet $sub: $1"
        ;;
    esac
    shift
  done

  case "$sub" in
    status)
      fleet_status "$json"
      ;;
    start)
      vm_dispatch start start_single
      fleet_status 0
      ;;
    stop)
      vm_dispatch stop stop_single
      ;;
  esac
}
