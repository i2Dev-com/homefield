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
      fleet_watch_status_line
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
    fleet_watch_status_line
  fi
}

cmd_fleet() {
  local sub="status"
  local json=0
  local -a pass=()

  if [ "$#" -gt 0 ]; then
    case "$1" in
      status | start | stop | watch)
        sub="$1"
        shift
        ;;
      -h | --help)
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
        die "unknown fleet subcommand: $1 (expected status, start, stop, or watch)"
        ;;
    esac
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        [ "$sub" = "status" ] || die "--json is only supported with 'fleet status'"
        json=1
        ;;
      --route-local)
        [ "$sub" = "start" ] || die "--route-local is only supported with 'fleet start'"
        pass+=("$1")
        ;;
      --route-hosted)
        [ "$sub" = "stop" ] || die "--route-hosted is only supported with 'fleet stop'"
        pass+=("$1")
        ;;
      --interval)
        [ "$sub" = "watch" ] || die "--interval is only supported with 'fleet watch'"
        pass+=("$1" "${2:?--interval needs a value}")
        shift
        ;;
      --max-ticks)
        [ "$sub" = "watch" ] || die "--max-ticks is only supported with 'fleet watch'"
        pass+=("$1" "${2:?--max-ticks needs a value}")
        shift
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
      vm_dispatch start start_single ${pass[@]+"${pass[@]}"}
      fleet_status 0
      ;;
    stop)
      vm_dispatch stop stop_single ${pass[@]+"${pass[@]}"}
      ;;
    watch)
      cmd_fleet_watch ${pass[@]+"${pass[@]}"}
      ;;
  esac
}

# ── The demand scaler (fleet watch, #291) ───────────────────────────────────
# Part 3 of the #286 automatic fallback. Parts 1 and 2 move work OFF the
# fleet when a VM stops or the Mac sleeps; neither scales capacity UP: a
# fleet of one busy VM queues every other routed job behind it even though
# the Mac has headroom for another VM. `fleet watch` is the tick that fixes
# that: on an interval it asks GitHub for queued runs whose jobs still wait
# for a routing label (the same shape route's stuck-run lookup uses), and
# when such jobs have waited longer than a threshold while every Running VM
# is busy, it boots — or creates — one spare VM registered like the runner
# that serves the queued label. The label is the load balancer: the spare
# self-registers with the same label in the same group, so GitHub hands it
# the queued jobs with no routing change at all. After an idle cooldown it
# is stopped (never deleted), and the next demand spike boots it again.
#
# The route-watcher LaunchAgent (#290) drives the ticks: its helper runs
# `fleet watch --max-ticks 1` every HOMEFIELD_SCALE_INTERVAL seconds, one
# more loop in the same agent. A tick yields to a watcher run in progress —
# one owner per VM at a time — and is fail-safe in the same direction as
# the rest of the fallback: a VM that cannot be asked whether a job is
# running, a GitHub that cannot be asked, or a budget that cannot be proven
# scales nothing and says so.
#
# The scaler's records live in the route-watcher subdirectory of the state
# directory (the agent's files, per-Mac). `scale` holds one `|`-separated
# line per secondary it created — `name|label|host|url|group|last-busy-epoch`
# (the group may be empty: a repository-scoped registration has none, and a
# group name may contain spaces) — and `scale-state` holds the last tick's
# summary, the way the watcher's `state` holds its last run; `fleet status`
# prints it.

scale_file() { printf '%s/scale' "$(route_watcher_dir)"; }
scale_state_file() { printf '%s/scale-state' "$(route_watcher_dir)"; }

# iso_to_epoch <iso8601-utc>: seconds since the epoch, in pure bash
# arithmetic. macOS's date and GNU date cannot parse the same input, and the
# tick runs on both, so GitHub's "2026-11-20T10:00:00Z" (a run's created_at)
# is parsed here with Howard Hinnant's days_from_civil. 1 for anything else.
iso_to_epoch() {
  local s="$1" y m d hh mm ss
  [[ "$s" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]] || return 1
  # 10#: GitHub's timestamps are zero-padded, and bash would read 08 and 09
  # as octal (an error, or worse a wrong value) without the base.
  y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  hh=$((10#${BASH_REMATCH[4]})) mm=$((10#${BASH_REMATCH[5]})) ss=$((10#${BASH_REMATCH[6]}))
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] || return 1
  [ "$d" -ge 1 ] && [ "$d" -le 31 ] || return 1
  [ "$hh" -le 23 ] && [ "$mm" -le 59 ] && [ "$ss" -le 60 ] || return 1
  # The days since 1970-01-01: March is the last month of the civil year,
  # so January and February belong to the previous one (leap days then land
  # at the era's end, where the yoe/4 - yoe/100 correction is exact).
  local yy=$((y - (m <= 2 ? 1 : 0)))
  local era=$((yy / 400))
  local yoe=$((yy - era * 400))
  local mo=$((m + (m > 2 ? -3 : 9)))
  local doy=$(( (153 * mo + 2) / 5 + d - 1 ))
  local doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  local days=$((era * 146097 + doe - 719468))
  printf '%s\n' $((days * 86400 + hh * 3600 + mm * 60 + ss))
}

# mem_to_bytes <size>: Lima's memory form as bytes — "5GiB" (the template's
# unit), "512MiB", "4G"/"4M"/"4K" (read as their binary cousins, which only
# overestimates a budget), plain bytes. 1 for anything else.
mem_to_bytes() {
  local s="$1" num unit
  case "$s" in
    '' | *[!0-9A-Za-z]*) return 1 ;;
  esac
  num="${s%%[A-Za-z]*}"
  unit="${s#"$num"}"
  case "$num" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$unit" in
    "" | B | b) printf '%s\n' "$num" ;;
    K | k | KiB | kiB) printf '%s\n' $((num * 1024)) ;;
    M | m | MiB | miB) printf '%s\n' $((num * 1024 * 1024)) ;;
    G | g | GiB | giB) printf '%s\n' $((num * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac
}

# mem_to_gib <size>: Lima's memory form as the numeric GiB limactl create
# --memory takes ("Memory in GiB", a number — "5GiB" is refused). Every unit
# mem_to_bytes accepts is a binary multiple, so the division is exact; 5GiB
# reads 5 and 512MiB reads 0.5. 1 for anything else.
mem_to_gib() {
  local b
  b="$(mem_to_bytes "$1")" || return 1
  awk -v b="$b" 'BEGIN { printf "%.6g\n", b / 1073741824 }'
}

# vm_size <name>: what the VM's stored Lima config asks for, as
# "<cpus> <memory as written>" — the fleet's template for a secondary's size,
# and the inputs of the headroom budget. 1 when the config cannot be read or
# does not carry both at the top level (Lima writes the effective values
# there, including the ones install passed as --cpus/--memory): an
# unprovable size is a refused create, not a guessed one.
vm_size() {
  local f="${LIMA_HOME:-$HOME/.lima}/$1/lima.yaml" line cpus="" mem=""
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      cpus:*) cpus="${line#cpus:}" ;;
      memory:*) mem="${line#memory:}" ;;
    esac
  done <"$f"
  cpus="${cpus//[[:space:]]/}"
  mem="${mem//[[:space:]]/}"
  [ -n "$cpus" ] && [ -n "$mem" ] || return 1
  case "$cpus" in
    '' | *[!0-9]*) return 1 ;;
  esac
  mem_to_bytes "$mem" >/dev/null || return 1
  printf '%s %s\n' "$cpus" "$mem"
}

# scale_headroom <cpus> <memory bytes>: whether a VM of that size keeps the
# runbook's budget ("Scaling on one Mac"): after every HomeField VM on this
# Mac — stopped ones too; a VM that starts later counts now — at least 2
# host cores and 8 GiB stay unallocated for macOS and Lima's own overhead.
# 1 (refuse) when the budget would be oversubscribed, or when any VM's size
# or the host's cannot be read: the install-time warning's inputs are the
# same ones, and an unprovable budget is not a proven one.
scale_headroom() {
  local new_cpus="$1" new_mem="$2" cores mem row used_cores=0 used_mem=0 i
  local row_cpus row_mem row_mem_bytes
  cores="$(sysctl -n hw.ncpu 2>/dev/null)" || return 1
  mem="$(sysctl -n hw.memsize 2>/dev/null)" || return 1
  case "$cores$mem" in
    '' | *[!0-9]*) return 1 ;;
  esac
  for ((i = 0; i < ${#FLEET_NAME[@]}; i++)); do
    row="$(vm_size "${FLEET_NAME[i]}")" || return 1
    row_cpus="${row%% *}"
    row_mem="${row##* }"
    row_mem_bytes="$(mem_to_bytes "$row_mem")" || return 1
    used_cores=$((used_cores + row_cpus))
    used_mem=$((used_mem + row_mem_bytes))
  done
  used_cores=$((used_cores + new_cpus))
  used_mem=$((used_mem + new_mem))
  [ $((cores - used_cores)) -ge 2 ] &&
    [ $((mem - used_mem)) -ge $((8 * 1024 * 1024 * 1024)) ]
}

# scale_record_read: the scale record into SCALE_NAME/SCALE_LABEL/SCALE_HOST/
# SCALE_URL/SCALE_GROUP/SCALE_BUSY (parallel arrays). The fields are
# `|`-separated: a runner group can be empty (a repository-scoped
# registration has none) or contain spaces, and both space- and tab-separated
# records lose those fields (IFS whitespace collapses consecutive
# delimiters, so an empty field vanishes). A line with fewer than six fields
# is not one the scaler wrote; it is skipped. A missing file reads as none.
SCALE_NAME=()
SCALE_LABEL=()
SCALE_HOST=()
SCALE_URL=()
SCALE_GROUP=()
SCALE_BUSY=()

scale_record_read() {
  SCALE_NAME=()
  SCALE_LABEL=()
  SCALE_HOST=()
  SCALE_URL=()
  SCALE_GROUP=()
  SCALE_BUSY=()
  local f sname slabel shost surl sgroup sbusy
  f="$(scale_file)"
  [ -f "$f" ] || return 0
  while IFS='|' read -r sname slabel shost surl sgroup sbusy; do
    [ -n "$sname" ] && [ -n "$slabel" ] && [ -n "$shost" ] && [ -n "$surl" ] &&
      [ -n "$sbusy" ] || continue
    case "$sbusy" in
      '' | *[!0-9]*) continue ;;
    esac
    SCALE_NAME+=("$sname")
    SCALE_LABEL+=("$slabel")
    SCALE_HOST+=("$shost")
    SCALE_URL+=("$surl")
    SCALE_GROUP+=("$sgroup")
    SCALE_BUSY+=("$sbusy")
  done <"$f"
  return 0
}

# scale_record_write: the arrays back to the scale record, whole, through a
# temp file moved over the target (the records' rule: a reader never sees
# half a file). The tick is the only writer.
scale_record_write() {
  local f dir tmp i
  f="$(scale_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.scale.XXXXXX")" || return 1
  : >"$tmp" || { rm -f "$tmp"; return 1; }
  for ((i = 0; i < ${#SCALE_NAME[@]}; i++)); do
    printf '%s|%s|%s|%s|%s|%s\n' "${SCALE_NAME[i]}" "${SCALE_LABEL[i]}" "${SCALE_HOST[i]}" "${SCALE_URL[i]}" "${SCALE_GROUP[i]}" "${SCALE_BUSY[i]}" >>"$tmp" ||
      { rm -f "$tmp"; return 1; }
  done
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# fleet_index <name>: the FLEET_* arrays' index of that VM, or -1.
fleet_index() {
  local i
  for ((i = 0; i < ${#FLEET_NAME[@]}; i++)); do
    if [ "${FLEET_NAME[i]}" = "$1" ]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  printf '%s\n' -1
}

# scale_exec <args...>: run this tool for one VM — the scaler's only way to
# create, start or stop. A subprocess of its own, so a failure (or a die)
# inside install cannot end the tick, the way vm_dispatch keeps one VM's
# failure from the next.
scale_exec() {
  "${BASH:-bash}" "$HF_SELF" "$@" </dev/null
}

# queued_wait_since <repo> <label> <host>: the earliest created_at of the
# repository's runs that still have a job queued for <label> — the jobs
# waiting for a local runner behind a busy fleet — as an epoch. Empty when
# nothing waits; 1 when GitHub could not be asked (the caller fails safe and
# scales nothing). The lookup is the same shape as route's stuck-run one —
# one paginated runs call per status, then the run's jobs — and it is
# host-agnostic: a GHES host's API answers it like github.com's, so demand
# scaling needs no hosted runners (#287). In-progress runs count too: a
# matrix or parallel run goes in_progress as soon as one of its jobs starts,
# while the rest of its jobs are still queued behind the busy fleet.
queued_wait_since() {
  local repo="$1" label="$2" host="$3" status ids id created waiting best="" epoch
  label="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
  for status in queued in_progress; do
    ids="$(gh api --hostname "$host" --paginate "repos/${repo}/actions/runs?status=${status}&per_page=100" \
      --jq '.workflow_runs[] | [.id, .created_at] | @tsv' </dev/null 2>/dev/null)" || return 1
    while IFS=$'\t' read -r id created; do
      [ -n "$id" ] || continue
      waiting="$(gh api --hostname "$host" --paginate "repos/${repo}/actions/runs/${id}/jobs?per_page=100" \
        --jq ".jobs[] | select(.status == \"queued\" and ((.labels | map(ascii_downcase)) | index(\"${label}\"))) | .id" \
        </dev/null 2>/dev/null)" || return 1
      [ -n "$waiting" ] || continue
      epoch="$(iso_to_epoch "$created")" || continue
      if [ -z "$best" ] || [ "$epoch" -lt "$best" ]; then
        best="$epoch"
      fi
    done <<<"$ids"
  done
  if [ -n "$best" ]; then
    printf '%s\n' "$best"
  fi
  return 0
}

# scale_demand: the queued demand across the routing records — for every
# `label repo host` line, the oldest wait for that label — into
# SCALE_DEMAND_LABEL/HOST/REPO/SINCE (parallel arrays, one entry per label
# and host). 1 when GitHub could not be asked for any record: a failed
# lookup must not read as "nothing waits".
SCALE_DEMAND_LABEL=()
SCALE_DEMAND_HOST=()
SCALE_DEMAND_REPO=()
SCALE_DEMAND_SINCE=()

scale_demand() {
  SCALE_DEMAND_LABEL=()
  SCALE_DEMAND_HOST=()
  SCALE_DEMAND_REPO=()
  SCALE_DEMAND_SINCE=()
  local label repo host since i found
  [ -f "$(routing_file)" ] || return 0
  while read -r label repo host; do
    [ -n "$repo" ] || continue
    host="${host:-github.com}"
    since="$(queued_wait_since "$repo" "$label" "$host")" || return 1
    [ -n "$since" ] || continue
    found=0
    for ((i = 0; i < ${#SCALE_DEMAND_LABEL[@]}; i++)); do
      if [ "${SCALE_DEMAND_LABEL[i]}" = "$label" ] && [ "${SCALE_DEMAND_HOST[i]}" = "$host" ]; then
        found=1
        if [ "$since" -lt "${SCALE_DEMAND_SINCE[i]}" ]; then
          SCALE_DEMAND_SINCE[i]="$since"
          SCALE_DEMAND_REPO[i]="$repo"
        fi
      fi
    done
    if [ "$found" = 0 ]; then
      SCALE_DEMAND_LABEL+=("$label")
      SCALE_DEMAND_HOST+=("$host")
      SCALE_DEMAND_REPO+=("$repo")
      SCALE_DEMAND_SINCE+=("$since")
    fi
  done <"$(routing_file)"
  return 0
}

# What scale_find_primary found: the Running VM whose runner can take the
# queued jobs, and everything the secondary's registration needs from it.
PRIMARY_NAME="" PRIMARY_URL="" PRIMARY_GROUP=""
PRIMARY_AUTO_ROUTE="" PRIMARY_CPUS="" PRIMARY_MEM="" PRIMARY_MEM_GIB="" PRIMARY_ROWS=""
PRIMARY_PKGS="" PRIMARY_HOOKS=""

# scale_find_primary <label> <host> <repo>: 0 found, 1 no Running VM serves
# the demand (the label's runner is on another Mac, or its VM is stopped:
# neither is this Mac's to scale — a stopped VM's settings cannot be read
# without starting it), 2 a runner list that could not be asked (a VM that
# might be the primary is unproven: fail safe, scale nothing).
scale_find_primary() {
  local label="$1" host="$2" repo="$3" list name st rows labels rname rlabels
  PRIMARY_NAME="" PRIMARY_URL="" PRIMARY_GROUP=""
  PRIMARY_AUTO_ROUTE="" PRIMARY_CPUS="" PRIMARY_MEM="" PRIMARY_MEM_GIB="" PRIMARY_ROWS=""
  PRIMARY_PKGS="" PRIMARY_HOOKS=""
  list="$(vm_instances)" || return 2
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    st="$(vm_status_of "$name")" || st=""
    [ "$st" = Running ] || continue
    INSTANCE="$name"
    load_runner_settings
    [ -n "$RS_NAME" ] && [ -n "$RS_URL" ] && [ -n "$RS_ID" ] || continue
    [ "$(github_host "$RS_URL")" = "$host" ] || continue
    rows="$(runners_on_github "$RS_URL")" || return 2
    labels=""
    while IFS=$'\t' read -r _rid rname _rstatus rlabels; do
      [ "$rname" = "$RS_NAME" ] && labels="$rlabels"
    done <<<"$rows"
    [ -n "$labels" ] || continue
    case ",$(lower "$labels")," in
      *",$(lower "$label"),"* ) ;; *) continue ;;
    esac
    in_scope "$repo" "$(scope_owner "$RS_URL")" || continue
    # The runner's group must admit the queued repository too: two VMs can
    # share a label in different selected-repository groups, and a spare
    # created in a group that excludes the repo cannot take the queued jobs
    # no matter what label it carries (route's own permission check,
    # runner_serves_repo). A group that cannot be asked is the same
    # fail-safe as a runner list that cannot.
    local serves=0
    runner_serves_repo "$(scope_owner "$RS_URL")" "$RS_ID" "$repo" "$host" || serves=$?
    case "$serves" in
      0) ;;
      1) continue ;;
      *) return 2 ;;
    esac
    PRIMARY_NAME="$name"
    PRIMARY_URL="$RS_URL"
    PRIMARY_ROWS="$rows"
    PRIMARY_AUTO_ROUTE="$(state_get auto_route)"
    if [[ "$(api_scope "$RS_URL" 2>/dev/null)" == orgs/* ]]; then
      local row rc=0
      row="$(find_runner_group "$(scope_owner "$RS_URL")" "$RS_ID" "$host")" || rc=$?
      [ "$rc" = 0 ] || return 2
      IFS=$'\t' read -r PRIMARY_GROUP _ <<<"$row"
    fi
    local size
    size="$(vm_size "$name")" || return 2
    PRIMARY_CPUS="${size%% *}"
    PRIMARY_MEM="${size##* }"
    # The memory limactl create takes is a number of GiB, not Lima's size
    # form ("5GiB" is refused at the flag): converted here, once, and an
    # unreadable size is the same refusal as an unreadable config.
    PRIMARY_MEM_GIB="$(mem_to_gib "$PRIMARY_MEM")" || return 2
    # What the secondary has to carry for the primary's workflows to keep
    # passing on it: the saved extra apt packages (preset packages included),
    # readable from the guest, and — a refusal, not a copy — the provisioning
    # hooks in the guest's provision.d (user hooks and preset hooks alike):
    # install has no flag that stages another VM's hooks, and a spare without
    # them takes jobs whose tools it does not have (runbook, "Adding tools").
    PRIMARY_PKGS="$(runner_extra_packages)" || return 2
    PRIMARY_HOOKS="$(guest sudo sh -c 'ls /etc/homefield/provision.d 2>/dev/null')" || return 2
    return 0
  done <<<"$list"
  return 1
}

# scale_grow <label> <host> <repo> <wait> <now>: one demand entry's
# response. Every guard the issue names sits here, in order: a watcher run
# in progress (one owner per VM at a time), the fleet-size cap, the
# headroom budget. Then the spare itself: a recorded secondary that matches
# the demand and is stopped is booted (seconds), and only when there is none
# is one created (minutes) — installed like the runner that serves the
# queued label: same url, label and group, same size, and the automatic
# fallback switch when the primary has it on. The secondary is persistent,
# not --ephemeral: it is started and stopped on demand, and an ephemeral
# registration would not survive its first stop. Returns 1 when something
# failed (the tick records it); 0 when the demand was answered, refused, or
# is not this Mac's.
scale_grow() {
  local label="$1" host="$2" repo="$3" wait="$4" now="$5"
  if route_watcher_is_running; then
    echo "homefield: fleet watch: the sleep/wake watcher is running; not scaling (one owner per VM at a time)" >&2
    return 1
  fi
  local found=0
  scale_find_primary "$label" "$host" "$repo" || found=$?
  if [ "$found" = 2 ]; then
    echo "homefield: fleet watch: could not read the runner that serves ${label} from GitHub; not scaling (fail safe)" >&2
    return 1
  fi
  if [ "$found" = 1 ]; then
    log "fleet watch: no running runner serves label ${label} at ${host}; not scaling"
    return 0
  fi

  # A spare that matches the demand and is stopped comes back first: booting
  # it adds no VM and no allocation, so the create-only guards below do not
  # apply to it. The match is by label, host, registration url and runner
  # group — the same label can be used by another registration on the same
  # host, and a spare from that one cannot serve this demand (its runner is
  # scoped elsewhere, and a group change since the spare was recorded is the
  # same mismatch).
  local i idx
  for ((i = 0; i < ${#SCALE_NAME[@]}; i++)); do
    [ "${SCALE_LABEL[i]}" = "$label" ] && [ "${SCALE_HOST[i]}" = "$host" ] || continue
    [ "${SCALE_URL[i]}" = "$PRIMARY_URL" ] || continue
    [ "${SCALE_GROUP[i]}" = "$PRIMARY_GROUP" ] || continue
    idx="$(fleet_index "${SCALE_NAME[i]}")"
    [ "$idx" != -1 ] && [ "${FLEET_STATUS[idx]}" = Stopped ] || continue
    if scale_exec start --instance "${SCALE_NAME[i]}"; then
      SCALE_BUSY[i]="$now"
      scale_record_write ||
        echo "homefield: fleet watch: started ${SCALE_NAME[i]} but could not record it; it will be recorded again on the next demand ($(scale_file))" >&2
      log "fleet watch: started secondary ${SCALE_NAME[i]} for the queued ${label} jobs (waiting ${wait}s)"
      SCALE_ACTION="started ${SCALE_NAME[i]}"
      return 0
    fi
    echo "homefield: fleet watch: could not start secondary ${SCALE_NAME[i]} (log above); it stays stopped" >&2
    return 1
  done

  # Creating one is where the issue's guards sit: what the spare must carry,
# the fleet-size cap, then the headroom budget.
  if [ -n "$PRIMARY_HOOKS" ]; then
    log "fleet watch: the primary ${PRIMARY_NAME} carries provisioning hooks the scaler cannot copy; add the spare by hand (runbook, \"More runners\")"
    return 0
  fi
  local cap="${HOMEFIELD_SCALE_MAX:-4}"
  case "$cap" in
    '' | *[!0-9]*) cap=4 ;;
  esac
  if [ "${#FLEET_NAME[@]}" -ge "$cap" ]; then
    log "fleet watch: the fleet is at its cap (${cap} VMs); not creating another"
    return 0
  fi
  if ! scale_headroom "$PRIMARY_CPUS" "$(mem_to_bytes "$PRIMARY_MEM")"; then
    log "fleet watch: creating a ${PRIMARY_CPUS}-vCPU VM would oversubscribe this Mac's CPU or RAM (runbook, \"Scaling on one Mac\"); not creating"
    return 0
  fi

  # The next spare's name: the fleet's first VM's, with -scale and a number,
  # free on this Mac, in the scale record, and in the scope's runner list
  # (GitHub refuses a taken name only after the VM is built).
  local base="${FLEET_NAME[0]}-scale" cand taken rn n=2
  cand="$base"
  while :; do
    taken=0
    for ((i = 0; i < ${#FLEET_NAME[@]}; i++)); do
      [ "${FLEET_NAME[i]}" = "$cand" ] && taken=1
    done
    for ((i = 0; i < ${#SCALE_NAME[@]}; i++)); do
      [ "${SCALE_NAME[i]}" = "$cand" ] && taken=1
    done
    while IFS=$'\t' read -r _rid rn _rst _rl; do
      [ "$rn" = "$cand" ] && taken=1
    done <<<"$PRIMARY_ROWS"
    [ "$taken" = 0 ] && break
    cand="${base}${n}"
    n=$((n + 1))
    if [ "$n" -gt 100 ]; then
      echo "homefield: fleet watch: no free secondary name under ${base}; not creating" >&2
      return 1
    fi
  done

  log "fleet watch: queued ${label} jobs waited ${wait}s behind a busy fleet; creating secondary ${cand} (installed like ${PRIMARY_NAME}: ${PRIMARY_CPUS} vCPUs, ${PRIMARY_MEM})"
  local -a argv=(install --instance "$cand" --url "$PRIMARY_URL" --label "$label")
  if [ -n "$PRIMARY_GROUP" ]; then
    argv+=(--group "$PRIMARY_GROUP")
  fi
  if [ "$PRIMARY_AUTO_ROUTE" = 1 ]; then
    argv+=(--auto-route)
  fi
  if [ -n "$PRIMARY_PKGS" ]; then
    argv+=(--packages "$PRIMARY_PKGS")
  fi
  argv+=(--cpus "$PRIMARY_CPUS" --memory "$PRIMARY_MEM_GIB")
  if ! scale_exec ${argv[@]+"${argv[@]}"}; then
    echo "homefield: fleet watch: creating ${cand} failed; remove the half-made VM with bin/homefield reset --instance ${cand} (the next demand tries again)" >&2
    return 1
  fi
  SCALE_NAME+=("$cand")
  SCALE_LABEL+=("$label")
  SCALE_HOST+=("$host")
  SCALE_URL+=("$PRIMARY_URL")
  SCALE_GROUP+=("$PRIMARY_GROUP")
  SCALE_BUSY+=("$now")
  scale_record_write ||
    echo "homefield: fleet watch: created ${cand} but could not record it; delete it by hand or the next demand creates another ($(scale_file))" >&2
  SCALE_ACTION="created ${cand}"
  return 0
}

# What the tick did, for the run record.
SCALE_ACTION="none"

# fleet_watch_record <rc>: the tick's summary, written whole (the watcher's
# record shape); `fleet status` prints it.
fleet_watch_record() {
  local rc="$1" f dir tmp
  f="$(scale_state_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.scale-state.XXXXXX")" || return 1
  {
    printf 'last_tick=%s\n' "$(date +%s)"
    printf 'last_tick_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'last_result=%s\n' "$([ "$rc" = 0 ] && echo ok || echo failed)"
    printf 'last_action=%s\n' "$SCALE_ACTION"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# fleet_watch_status_line: the one-line answer `fleet status` prints for the
# scaler — whether it has run, and what the last tick did. The log carries
# the detail.
fleet_watch_status_line() {
  local f at="" result="" action="" key value
  f="$(scale_state_file)"
  [ -f "$f" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      last_tick_at) at="$value" ;;
      last_result) result="$value" ;;
      last_action) action="$value" ;;
    esac
  done <"$f"
  [ -n "$at" ] || return 0
  echo "scaler: last tick at ${at}: ${result} (${action})"
  return 0
}

# fleet_watch_tick: one evaluation. The order is the lifecycle: reconcile
# the scale record with the Mac (a secondary deleted by hand leaves it),
# then the stop side (the idle cooldown), then the demand side (the queued
# threshold). Every failure is fail-safe: nothing scales on an unprovable
# answer, and the tick says so.
fleet_watch_tick() {
  SCALE_ACTION="none"
  local rc=0 now list name st jrc saw_running=0 all_busy=1 unaskable=0 i idx idle
  if route_watcher_is_running; then
    log "fleet watch: the sleep/wake watcher is running; standing down until it is done"
    SCALE_ACTION="yielded to the watcher"
    fleet_watch_record 0 || true
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "homefield: fleet watch needs gh (https://cli.github.com); skipping this tick" >&2
    SCALE_ACTION="skipped: no gh"
    fleet_watch_record 0 || true
    return 0
  fi
  if ! list="$(vm_instances)"; then
    echo "homefield: fleet watch: could not list the HomeField VMs; skipping this tick" >&2
    SCALE_ACTION="skipped: Lima could not be asked"
    fleet_watch_record 0 || true
    return 0
  fi
  if [ -z "$list" ]; then
    log "fleet watch: no HomeField VMs on this Mac; nothing to scale"
    fleet_watch_record 0 || true
    return 0
  fi

  # The fleet's state, one pass: FLEET_NAME/STATUS/JOB (parallel arrays),
  # plus whether every Running VM is busy and whether any could not be
  # asked. A job probe that fails is not "idle": the demand side needs
  # "every VM busy" proven, and the stop side needs each secondary's own
  # answer, so an unaskable VM blocks both.
  FLEET_NAME=()
  FLEET_STATUS=()
  FLEET_JOB=()
  local saved_instance="$INSTANCE"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    st=""
    st="$(vm_status_of "$name")" || st=""
    FLEET_NAME+=("$name")
    idx=$((${#FLEET_NAME[@]} - 1))
    FLEET_STATUS+=("${st:-unknown}")
    FLEET_JOB+=("-")
    [ -n "$st" ] || continue
    [ "$st" = Running ] || continue
    saw_running=1
    INSTANCE="$name"
    jrc=0
    job_running || jrc=$?
    case "$jrc" in
      0) FLEET_JOB[idx]=yes ;;
      1) FLEET_JOB[idx]=no; all_busy=0 ;;
      *)
        FLEET_JOB[idx]=unknown
        unaskable=1
        all_busy=0
        ;;
    esac
  done <<<"$list"
  INSTANCE="$saved_instance"

  # A recorded secondary that is gone from the Mac (deleted by hand) leaves
  # the record here; the next write drops it.
  scale_record_read

  # ── the stop side: the idle cooldown ──
  # A secondary with no job for HOMEFIELD_SCALE_IDLE seconds is stopped by
  # the real `stop`, which refuses under a live job the same way `fleet
  # stop` does — the cooldown must be proven idle, not assumed — and, with
  # the automatic fallback on, flips the repositories only it is still
  # serving to hosted before it stops. A stopped secondary stays recorded:
  # it is the spare the next demand boots. One deleted by hand leaves the
  # record here (the kept lines are what the write below puts back).
  now="$(date +%s)"
  local idle_max="${HOMEFIELD_SCALE_IDLE:-900}"
  case "$idle_max" in
    '' | *[!0-9]*) idle_max=900 ;;
  esac
  local -a keep_name=() keep_label=() keep_host=() keep_url=() keep_group=() keep_busy=()
  for ((i = 0; i < ${#SCALE_NAME[@]}; i++)); do
    idx="$(fleet_index "${SCALE_NAME[i]}")"
    if [ "$idx" = -1 ]; then
      log "fleet watch: secondary ${SCALE_NAME[i]} is gone from the Mac; dropping it from the scale record"
      continue
    fi
    if [ "${FLEET_STATUS[idx]}" = Running ]; then
      case "${FLEET_JOB[idx]}" in
        yes)
          SCALE_BUSY[i]="$now"
          ;;
        no)
          idle=$((now - SCALE_BUSY[i]))
          if [ "$idle" -ge "$idle_max" ]; then
            if scale_exec stop --instance "${SCALE_NAME[i]}"; then
              log "fleet watch: stopped secondary ${SCALE_NAME[i]} (idle ${idle}s); it stays recorded as the spare"
              SCALE_ACTION="stopped ${SCALE_NAME[i]}"
            else
              echo "homefield: fleet watch: could not stop secondary ${SCALE_NAME[i]} (log above); it stays up" >&2
              rc=1
            fi
          fi
          ;;
        *)
          echo "homefield: fleet watch: could not ask whether a job is running on ${SCALE_NAME[i]}; not stopping it (fail safe)" >&2
          rc=1
          ;;
      esac
    fi
    keep_name+=("${SCALE_NAME[i]}")
    keep_label+=("${SCALE_LABEL[i]}")
    keep_host+=("${SCALE_HOST[i]}")
    keep_url+=("${SCALE_URL[i]}")
    keep_group+=("${SCALE_GROUP[i]}")
    keep_busy+=("${SCALE_BUSY[i]}")
  done
  SCALE_NAME=("${keep_name[@]+"${keep_name[@]}"}")
  SCALE_LABEL=("${keep_label[@]+"${keep_label[@]}"}")
  SCALE_HOST=("${keep_host[@]+"${keep_host[@]}"}")
  SCALE_URL=("${keep_url[@]+"${keep_url[@]}"}")
  SCALE_GROUP=("${keep_group[@]+"${keep_group[@]}"}")
  SCALE_BUSY=("${keep_busy[@]+"${keep_busy[@]}"}")
  scale_record_write || { echo "homefield: fleet watch: could not update $(scale_file)" >&2; rc=1; }

  # ── the demand side ──
  # Only when the queue is real: at least one VM running, every one of them
  # busy (an idle runner is taking jobs; nothing waits behind anything), and
  # every job probe answered. The lookup itself is the expensive part, so it
  # never runs for a fleet that is not fully busy.
  if [ "$saw_running" = 0 ]; then
    log "fleet watch: no VM is running; nothing to scale"
  elif [ "$unaskable" = 1 ]; then
    echo "homefield: fleet watch: could not ask whether a job is running on every VM; not scaling (fail safe)" >&2
    rc=1
  elif [ "$all_busy" = 1 ]; then
    local wait_max="${HOMEFIELD_SCALE_WAIT:-300}"
    case "$wait_max" in
      '' | *[!0-9]*) wait_max=300 ;;
    esac
    if scale_demand; then
      for ((i = 0; i < ${#SCALE_DEMAND_LABEL[@]}; i++)); do
        idle=$((now - SCALE_DEMAND_SINCE[i]))
        if [ "$idle" -ge "$wait_max" ]; then
          # One VM per tick — but only one that actually added capacity: an
          # entry the scaler cannot serve (a label served on another Mac, a
          # primary with hooks it cannot copy) must not win every tick and
          # starve a later local label it could answer.
          local action_before="$SCALE_ACTION"
          if scale_grow "${SCALE_DEMAND_LABEL[i]}" "${SCALE_DEMAND_HOST[i]}" \
            "${SCALE_DEMAND_REPO[i]}" "$idle" "$now"; then
            [ "$SCALE_ACTION" = "$action_before" ] || break
          else
            rc=1
          fi
        fi
      done
    else
      echo "homefield: fleet watch: could not read the queued runs from GitHub; not scaling (fail safe)" >&2
      rc=1
    fi
  fi

  fleet_watch_record "$rc" || rc=1
  return "$rc"
}

# cmd_fleet_watch [--interval SEC] [--max-ticks N]: the scaler's loop. One
# tick per interval until --max-ticks (0, the default, is unlimited); the
# route-watcher agent runs it with --max-ticks 1. --instance does not apply:
# the scaler covers every HomeField VM on this Mac.
cmd_fleet_watch() {
  local interval="${HOMEFIELD_SCALE_INTERVAL:-60}" max_ticks=0 ticks=0 rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) interval="${2:?--interval needs a value}"; shift 2 ;;
      --max-ticks) max_ticks="${2:?--max-ticks needs a value}"; shift 2 ;;
      -h | --help)
        usage_for fleet
        return 0
        ;;
      *)
        die "fleet watch: unknown option $1 (see bin/homefield help)"
        ;;
    esac
  done
  case "$interval" in
    '' | *[!0-9]*) die "fleet watch: --interval must be a number of seconds, got: $interval" ;;
  esac
  case "$max_ticks" in
    '' | *[!0-9]*) die "fleet watch: --max-ticks must be a number, got: $max_ticks" ;;
  esac
  [ "${EXPLICIT_INSTANCE:-0}" = 0 ] ||
    die "fleet watch: --instance does not apply: the scaler covers every HomeField VM on this Mac"
  check_host
  while :; do
    fleet_watch_tick || rc=1
    ticks=$((ticks + 1))
    if [ "$max_ticks" -gt 0 ] && [ "$ticks" -ge "$max_ticks" ]; then
      break
    fi
    adopt_nap "$interval"
  done
  return "$rc"
}
