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
# Scale-from-zero (#305) completes the column: the tick also wakes a VM
# that is entirely stopped. The wake is armed per VM by the `scale-dark`
# record — written only for VMs the scaler's own stops put dark, so a VM
# the user stopped by hand stays down — and fired by the same demand the
# up-scale side reads, plus one more source: the runs an automatic flip
# moved to hosted, which are demand burning hosted minutes and wake at
# once. The started VM's flipped repositories come back the watcher's wake
# way (online wait, then restore). The webhook receiver a cloud autoscaler
# would use stays out on purpose: the Mac sits behind NAT, and the
# always-on watcher's tick needs no inbound configuration.
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
#
# Scale-from-zero (#305) adds two records of its own. `scale-primaries`
# holds one `|`-separated line per fleet VM the scaler did not create —
# `name|url|label|auto_route|last-busy-epoch|up|runner-id` — refreshed
# every tick while the VM is Running, because a stopped VM cannot be asked
# for its runner identity and the wake side needs the map when everything
# is down. `scale-dark` holds one `|`-separated line per VM the scaler's
# own stops put dark — `name|url|label|runner-id`: only a line's VM wakes
# on demand, so a VM the user stopped stays down, and one scope's wake
# does not strand another's dark line. A line is dropped the moment its
# VM is seen Running again.

scale_file() { printf '%s/scale' "$(route_watcher_dir)"; }
scale_state_file() { printf '%s/scale-state' "$(route_watcher_dir)"; }
scale_primaries_file() { printf '%s/scale-primaries' "$(route_watcher_dir)"; }
scale_dark_file() { printf '%s/scale-dark' "$(route_watcher_dir)"; }

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

# ── The scale-from-zero records (#305) ──────────────────────────────────────
# PRIM_NAME/PRIM_URL/PRIM_LABEL/PRIM_AUTO/PRIM_BUSY/PRIM_UP/PRIM_ID: the
# primaries record, the scale-to-zero opt-in's map of the fleet's own VMs —
# the ones the scaler did not create. It exists because a stopped VM cannot
# be asked for its runner identity (load_runner_settings reads through the
# guest), while both sides of 0 → N need the map after the VMs are down: the
# zero stops need each VM's idle clock, and the wake side needs which VM
# serves which label. The tick refreshes a line while the VM is Running (the
# identity, the automatic-fallback flag from its state file, and the routing
# label and runner id from GitHub's runner row) and drops lines for VMs gone
# from the Mac, the way the scale record does. `up` says the line was written
# for a Running VM; the reconcile clears it when the VM is not, so a VM
# seen Running again after being down starts a fresh idle cooldown instead
# of inheriting its pre-stop stamp.
PRIM_NAME=() PRIM_URL=() PRIM_LABEL=() PRIM_AUTO=() PRIM_BUSY=() PRIM_UP=() PRIM_ID=()

scale_primaries_read() {
  PRIM_NAME=()
  PRIM_URL=()
  PRIM_LABEL=()
  PRIM_AUTO=()
  PRIM_BUSY=()
  PRIM_UP=()
  PRIM_ID=()
  local f pname purl plabel pauto pbusy pup pid
  f="$(scale_primaries_file)"
  [ -f "$f" ] || return 0
  while IFS='|' read -r pname purl plabel pauto pbusy pup pid; do
    [ -n "$pname" ] || continue
    case "$pbusy" in '' | *[!0-9]*) continue ;; esac
    PRIM_NAME+=("$pname")
    PRIM_URL+=("${purl:-}")
    PRIM_LABEL+=("${plabel:-}")
    PRIM_AUTO+=("${pauto:-}")
    PRIM_BUSY+=("$pbusy")
    PRIM_UP+=("${pup:-}")
    PRIM_ID+=("${pid:-}")
  done <"$f"
  return 0
}

# scale_primaries_write: the arrays back to the primaries record, whole,
# through a temp file moved over the target (the records' rule: a reader
# never sees half a file). The tick is the only writer.
scale_primaries_write() {
  local f dir tmp i
  f="$(scale_primaries_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.scale-primaries.XXXXXX")" || return 1
  : >"$tmp" || { rm -f "$tmp"; return 1; }
  for ((i = 0; i < ${#PRIM_NAME[@]}; i++)); do
    printf '%s|%s|%s|%s|%s|%s|%s\n' "${PRIM_NAME[i]}" "${PRIM_URL[i]}" \
      "${PRIM_LABEL[i]}" "${PRIM_AUTO[i]}" "${PRIM_BUSY[i]}" "${PRIM_UP[i]}" \
      "${PRIM_ID[i]}" >>"$tmp" ||
      { rm -f "$tmp"; return 1; }
  done
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# scale_primaries_refresh <name> <job>: one Running, non-recorded VM's line,
# from what the state pass already asked the VM (it holds INSTANCE). The
# label is the runner's routing label from GitHub's row — empty when the
# runner advertises no custom label, in which case nothing routes to it and
# the wake side's match skips it (the fallback start of the fleet's first
# VM covers demand no line matches). A VM that cannot be asked for its
# identity keeps its old line (fail safe): the wake side re-reads the
# identity from the VM after it starts it, so the record only has to carry
# the match. The busy stamp tracks the last job the VM ran; a VM seen
# Running again after being down (its line's up was cleared) starts a fresh
# cooldown instead of inheriting its pre-stop stamp.
scale_primaries_refresh() {
  local name="$1" job="$2" i idx=-1 url="" label="" auto="" busy="" up="" rid=""
  local rows rn rlabels
  for ((i = 0; i < ${#PRIM_NAME[@]}; i++)); do
    [ "${PRIM_NAME[i]}" = "$name" ] && idx=$i && break
  done
  if [ "$idx" != -1 ]; then
    url="${PRIM_URL[idx]}"
    label="${PRIM_LABEL[idx]}"
    auto="${PRIM_AUTO[idx]}"
    busy="${PRIM_BUSY[idx]}"
    up="${PRIM_UP[idx]}"
    rid="${PRIM_ID[idx]}"
  fi
  load_runner_settings
  if [ -n "$RS_NAME" ] && [ -n "$RS_URL" ]; then
    url="$RS_URL"
    auto="$(state_get auto_route)"
    rows="$(runners_on_github "$RS_URL")" || rows=""
    if [ -n "$rows" ]; then
      while IFS=$'\t' read -r _rid rn _rst rlabels; do
        [ "$rn" = "$RS_NAME" ] || continue
        label="$(routing_label "$rlabels")"
        rid="$_rid"
      done <<<"$rows"
    fi
  fi
  case "$job" in
    yes)
      busy="$(date +%s)"
      up=1
      ;;
    no)
      [ "$up" = 1 ] || busy="$(date +%s)"
      up=1
      ;;
    *)
      # The job probe could not be answered: the zero stop skips this VM
      # (fail safe), and the stamp says nothing new.
      up=1
      ;;
  esac
  if [ "$idx" = -1 ]; then
    PRIM_NAME+=("$name")
    PRIM_URL+=("$url")
    PRIM_LABEL+=("$label")
    PRIM_AUTO+=("$auto")
    PRIM_BUSY+=("$busy")
    PRIM_UP+=("$up")
    PRIM_ID+=("$rid")
  else
    PRIM_URL[idx]="$url"
    PRIM_LABEL[idx]="$label"
    PRIM_AUTO[idx]="$auto"
    PRIM_BUSY[idx]="$busy"
    PRIM_UP[idx]="$up"
    PRIM_ID[idx]="$rid"
  fi
  return 0
}

# ── The dark record (#305) ──────────────────────────────────────────────────
# DARK_NAME/DARK_URL/DARK_LABEL/DARK_ID: the VMs the scaler itself stopped
# and that are down. A line is written when the tick's stop side puts a VM
# down — the scale-to-zero pass for the fleet's own VMs, the spare pass for
# a secondary — carrying the identity the wake side matches against (the
# registration url, the routing label, the runner id). The identity must be
# in hand before the stop: it is read through the guest while the VM still
# runs (or taken from the primaries record, which captured it the same
# way), because a stopped guest cannot be asked. A stop the tick cannot
# pair with a usable identity is deferred to a later tick — a line the
# wake side cannot match would leave the VM down with its demand
# unanswered. A line is dropped when the VM is seen Running again (by the
# wake, the user, or anything else) or gone from the Mac. A VM the user
# stopped by hand never gets a line: the wake side is for a dark fleet the
# scaler made, and a hand-stopped VM stays down. One VM per line is what
# keeps a multi-VM fleet's wake eligibility intact — waking one scope's VM
# must not strand another's.
DARK_NAME=() DARK_URL=() DARK_LABEL=() DARK_ID=()

scale_dark_read() {
  DARK_NAME=()
  DARK_URL=()
  DARK_LABEL=()
  DARK_ID=()
  local f dname durl dlabel did
  f="$(scale_dark_file)"
  [ -f "$f" ] || return 0
  while IFS='|' read -r dname durl dlabel did; do
    [ -n "$dname" ] || continue
    DARK_NAME+=("$dname")
    DARK_URL+=("${durl:-}")
    DARK_LABEL+=("${dlabel:-}")
    DARK_ID+=("${did:-}")
  done <"$f"
  return 0
}

# scale_dark_write: the arrays back to the dark record, whole, through a
# temp file moved over the target. The tick is the only writer.
scale_dark_write() {
  local f dir tmp i
  f="$(scale_dark_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.scale-dark.XXXXXX")" || return 1
  : >"$tmp" || { rm -f "$tmp"; return 1; }
  for ((i = 0; i < ${#DARK_NAME[@]}; i++)); do
    printf '%s|%s|%s|%s\n' "${DARK_NAME[i]}" "${DARK_URL[i]}" \
      "${DARK_LABEL[i]}" "${DARK_ID[i]}" >>"$tmp" ||
      { rm -f "$tmp"; return 1; }
  done
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# scale_dark_add_prim <i>: one dark line copied from the primaries record
# (the zero pass's stop; the line exists — the idle clock came from it).
# Returns 1 when the line already existed (nothing was added), so the
# caller can roll back exactly what it added when the write fails.
scale_dark_add_prim() {
  local i="$1"
  local j
  for ((j = 0; j < ${#DARK_NAME[@]}; j++)); do
    [ "${DARK_NAME[j]}" = "${PRIM_NAME[i]}" ] && return 1
  done
  DARK_NAME+=("${PRIM_NAME[i]}")
  DARK_URL+=("${PRIM_URL[i]}")
  DARK_LABEL+=("${PRIM_LABEL[i]}")
  DARK_ID+=("${PRIM_ID[i]}")
  return 0
}

# scale_dark_add_vm <name> <url> <label> <id>: one dark line for a VM whose
# identity was read while it ran (the spare pass's secondary, which the
# primaries record does not book). A line the tick could not read the
# identity for is not written: the wake side matches on it, and a line it
# cannot match is the stranded-jobs kind, not the wake kind. Returns 1
# when the line already existed (nothing was added), so the caller can
# roll back exactly what it added when the write fails.
scale_dark_add_vm() {
  local j
  for ((j = 0; j < ${#DARK_NAME[@]}; j++)); do
    [ "${DARK_NAME[j]}" = "$1" ] && return 1
  done
  DARK_NAME+=("$1")
  DARK_URL+=("${2:-}")
  DARK_LABEL+=("${3:-}")
  DARK_ID+=("${4:-}")
  return 0
}

# scale_dark_drop <name>: the VM is up or gone; its dark line goes with it.
scale_dark_drop() {
  local i
  for ((i = 0; i < ${#DARK_NAME[@]}; i++)); do
    [ "${DARK_NAME[i]}" = "$1" ] || continue
    unset 'DARK_NAME[i]' 'DARK_URL[i]' 'DARK_LABEL[i]' 'DARK_ID[i]'
    DARK_NAME=("${DARK_NAME[@]+"${DARK_NAME[@]}"}")
    DARK_URL=("${DARK_URL[@]+"${DARK_URL[@]}"}")
    DARK_LABEL=("${DARK_LABEL[@]+"${DARK_LABEL[@]}"}")
    DARK_ID=("${DARK_ID[@]+"${DARK_ID[@]}"}")
    return 0
  done
  return 1
}

# hosted_activity_since <repo> <host> <events> <dependabot> <mode>: the
# earliest created_at of the repository's queued or in-progress runs — the
# demand a dark fleet's flipped repositories generate. The automatic flip
# moved them to hosted (their entries live in `autoflip` until a start
# restores them), so every run they start burns hosted minutes until the
# fleet comes back. Unlike the queued lookup there is no label to match —
# the flip changed the workflow's runs-on out of the local label — and no
# wait: a queued job behind a busy fleet proves itself over the threshold,
# but a run already spending money is demand now. Empty when nothing runs;
# 1 when GitHub could not be asked (the caller fails safe and wakes nothing).
#
# A run counts only when the consumer's own routing expression would have
# sent it to the local runner had CI_RUNNER been local (#315): the record's
# option fields mirror the guard's `events`, `dependabot` and `mode`, and
# the filter applies them to the run's own metadata. In guards mode the
# run's event must be one of the record's events (default pull_request),
# a `dependabot=hosted` record excludes Dependabot's actor and head branch,
# and fork pull requests are excluded (head repository != the repository);
# a simple-mode record counts every active run, because the simple
# expression routes every event. A run the expression would keep hosted —
# a scheduled workflow, a Dependabot PR, a fork PR — can never take the
# runner, and reading it as demand would wake a dark VM on a schedule
# instead of on work. The fields are in the runs-list response, so this is
# a select() in the jq the lookup already runs — no extra API calls.
hosted_activity_since() {
  local repo="$1" host="$2" events="${3:-pull_request}" dependabot="${4:-hosted}" mode="${5:-guards}"
  local status ids id created best="" epoch active filter e first
  if [ "$mode" = simple ]; then
    filter="."
  else
    local cond="" first=1
    for e in $(printf '%s' "$events" | tr ',' ' '); do
      [ -n "$e" ] || continue
      if [ "$first" = 1 ]; then first=0; else cond+=" or "; fi
      cond+=".event == \"$e\""
    done
    if [ "$dependabot" = hosted ]; then
      cond+=" and (.actor.login != \"dependabot[bot]\" and ((.head_branch // \"\") | startswith(\"dependabot/\") | not))"
    fi
    # A fork pull request stays hosted under the guards expression (the
    # head repository is not the repository the run belongs to). A run
    # whose head repository is gone cannot take the runner either.
    cond+=" and ((.head_repository.full_name // \"\") == (.repository.full_name // \"\"))"
    filter="select($cond)"
  fi
  for status in queued in_progress; do
    ids="$(gh api --hostname "$host" --paginate "repos/${repo}/actions/runs?status=${status}&per_page=100" \
      --jq ".workflow_runs[] | $filter | [.id, .created_at] | @tsv" </dev/null 2>/dev/null)" || return 1
    while IFS=$'\t' read -r id created; do
      [ -n "$id" ] || continue
      # A run counts only while it still has active jobs: GitHub keeps a
      # run listed as queued forever when its head branch is gone, with no
      # jobs behind it, and reading such a row as demand would wake a dark
      # VM on a schedule instead of on work. The ids, not a count: across
      # --paginate pages a count would arrive one number per page, and the
      # ids concatenate into one non-empty answer whenever any page has an
      # active job.
      active="$(gh api --hostname "$host" --paginate "repos/${repo}/actions/runs/${id}/jobs?per_page=100" \
        --jq '.jobs[] | select(.status == "queued" or .status == "in_progress") | .id' \
        </dev/null 2>/dev/null)" || return 1
      [ -n "$active" ] || continue
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

# scale_exec <args...>: run this tool for one VM — the scaler's only way to
# create, start or stop. A subprocess of its own, so a failure (or a die)
# inside install cannot end the tick, the way vm_dispatch keeps one VM's
# failure from the next.
scale_exec() {
  # HOMEFIELD_SCALE_INSTALL: this run is the scaler's own subprocess — a
  # spare's install with --auto-route must not reload the route-watcher
  # LaunchAgent, because the unload would stop the very helper supervising
  # this tick (route_watcher_install preserves an installed agent for it).
  HOMEFIELD_SCALE_INSTALL=1 "${BASH:-bash}" "$HF_SELF" "$@" </dev/null
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
  local label repo host since
  [ -f "$(routing_file)" ] || return 0
  # One entry per routing record, not per label: two repositories can share
  # a label and host while their eligible runners differ (one served on
  # another Mac, one here), and merging them into the oldest run's
  # repository would let the unreachable one starve the reachable one. The
  # demand loop answers the first entry that actually adds capacity.
  while read -r label repo host _opts; do
    [ -n "$repo" ] || continue
    host="${host:-github.com}"
    since="$(queued_wait_since "$repo" "$label" "$host")" || return 1
    [ -n "$since" ] || continue
    SCALE_DEMAND_LABEL+=("$label")
    SCALE_DEMAND_HOST+=("$host")
    SCALE_DEMAND_REPO+=("$repo")
    SCALE_DEMAND_SINCE+=("$since")
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
    # An organization runner's group must admit the queued repository too:
    # two VMs can share a label in different selected-repository groups, and
    # a spare created in a group that excludes the repo cannot take the
    # queued jobs no matter what label it carries (route's own permission
    # check, runner_serves_repo). A group that cannot be asked is the same
    # fail-safe as a runner list that cannot. A repository-scoped runner
    # needs no check: in_scope already confined it to its registration
    # repository, whose jobs are the only ones it can take.
    if [[ "$(api_scope "$RS_URL" 2>/dev/null)" == orgs/* ]]; then
      local serves=0
      runner_serves_repo "$(scope_owner "$RS_URL")" "$RS_ID" "$repo" "$host" || serves=$?
      case "$serves" in
        0) ;;
        1) continue ;;
        *) return 2 ;;
      esac
    fi
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

# ── The scale-from-zero side (#305) ─────────────────────────────────────────
# scale_wake: a VM the scaler itself stopped is down, and demand wants it
# back. The dark record says which VMs those are; a VM the user stopped by
# hand has no line and stays down — the owner's explicit choice, and the
# fallback flip already moved its routed repositories to hosted. Demand
# comes from two sources: the queued jobs the demand lookup already finds
# (a label nothing serves — the stop's flip did not land, or a workflow
# that never went through the CI_RUNNER switch) and the runs an automatic
# flip moved to hosted, which are demand burning hosted minutes now and
# wake at once. The queued source waits out the same threshold the up-scale
# side uses — a queued job behind nothing still has to prove it is not a
# blip — while the hosted source does not: the money is being spent now.
# One VM per tick, the scaler's rule: a dark VM whose recorded label, host
# and registration scope match the demand starts first; an organization
# runner's group must admit the repository too (the same check the
# up-scale side makes through runner_serves_repo — two VMs can share a
# label in different selected-repository groups). A demand no dark line
# serves is left alone and logged — starting an unrelated VM would drop
# its dark line and strand the jobs anyway. The started VM's restore is
# the watcher's wake pattern (a bounded online wait, then the autoflipped
# repositories back to local). The wake runs for a partly-running fleet
# too: a VM another scope woke must not strand this one's dark line, so
# the tick calls it whenever the grow side added nothing this tick.
scale_wake() {
  local now label repo host since idle i j k m idx pname pidx wait_max rc=0
  local rurl rlabel rid served serves wi up_now wrc
  scale_dark_read
  if [ "${#DARK_NAME[@]}" -eq 0 ]; then
    log "fleet watch: no VM the scaler stopped is dark; nothing wakes on demand"
    return 0
  fi
  now="$(date +%s)"
  wait_max="${HOMEFIELD_SCALE_WAIT:-300}"
  case "$wait_max" in
    '' | *[!0-9]*) wait_max=300 ;;
  esac
  local -a WAKE_LABEL=() WAKE_REPO=() WAKE_HOST=() WAKE_SINCE=() WAKE_URGENT=()
  if scale_demand; then
    for ((i = 0; i < ${#SCALE_DEMAND_LABEL[@]}; i++)); do
      WAKE_LABEL+=("${SCALE_DEMAND_LABEL[i]}")
      WAKE_REPO+=("${SCALE_DEMAND_REPO[i]}")
      WAKE_HOST+=("${SCALE_DEMAND_HOST[i]}")
      WAKE_SINCE+=("${SCALE_DEMAND_SINCE[i]}")
      WAKE_URGENT+=(0)
    done
  else
    echo "homefield: fleet watch: could not read the queued runs from GitHub; not waking a dark fleet (fail safe)" >&2
    return 1
  fi
  if [ -f "$(autoflip_file)" ]; then
    while read -r label repo host events dependabot mode; do
      [ -n "$repo" ] || continue
      host="${host:-github.com}"
      # The entry's option fields (the routing record's at flip time) say
      # which runs may take the runner: the demand filter applies them
      # (#315). A legacy three-field entry reads as the guard's defaults.
      since="$(hosted_activity_since "$repo" "$host" \
        "${events:-pull_request}" "${dependabot:-hosted}" "${mode:-guards}")" || {
        echo "homefield: fleet watch: could not read the runs of ${repo}; not waking a dark fleet (fail safe)" >&2
        return 1
      }
      [ -n "$since" ] || continue
      WAKE_LABEL+=("$label")
      WAKE_REPO+=("$repo")
      WAKE_HOST+=("$host")
      WAKE_SINCE+=("$since")
      WAKE_URGENT+=(1)
    done <"$(autoflip_file)"
  fi
  if [ "${#WAKE_LABEL[@]}" -eq 0 ]; then
    log "fleet watch: a VM the scaler put dark is down; nothing waits"
    return 0
  fi
  for ((i = 0; i < ${#WAKE_LABEL[@]}; i++)); do
    idle=$((now - WAKE_SINCE[i]))
    [ "${WAKE_URGENT[i]}" = 1 ] || [ "$idle" -ge "$wait_max" ] || continue
    # A queued demand an idle Running VM already serves needs no new
    # capacity: the run is waiting on workflow dependencies no runner
    # can help, or on a runner the idle cooldown is about to retire,
    # and a dark VM started for the same scope would idle out behind
    # the same wait. The identities come from the records the tick
    # maintains while the VMs run — the primaries' for the fleet's own
    # VMs, the scale record for the secondaries — matched the way the
    # dark side matches below; only an idle VM counts, because a busy
    # one is the capacity gap this pass exists for. An org-scoped
    # registration needs its recorded runner id for the group check,
    # the same rule the dark side applies, so a secondary whose scale
    # record carries no id never counts as serving. The hosted source
    # keeps waking: its runs are on hosted now, and the restore that
    # brings the routing back rides on a start.
    if [ "${WAKE_URGENT[i]}" = 0 ]; then
      served=0
      for ((k = 0; k < ${#FLEET_NAME[@]}; k++)); do
        [ "${FLEET_STATUS[k]}" = Running ] || continue
        [ "${FLEET_JOB[k]}" = no ] || continue
        rurl=""; rlabel=""; rid=""
        for ((m = 0; m < ${#PRIM_NAME[@]}; m++)); do
          [ "${PRIM_NAME[m]}" = "${FLEET_NAME[k]}" ] || continue
          rurl="${PRIM_URL[m]}"
          rlabel="${PRIM_LABEL[m]}"
          rid="${PRIM_ID[m]}"
          break
        done
        if [ -z "$rurl" ]; then
          for ((m = 0; m < ${#SCALE_NAME[@]}; m++)); do
            [ "${SCALE_NAME[m]}" = "${FLEET_NAME[k]}" ] || continue
            rurl="${SCALE_URL[m]}"
            rlabel="${SCALE_LABEL[m]}"
            break
          done
        fi
        [ -n "$rurl" ] && [ -n "$rlabel" ] || continue
        [ "$(lower "$rlabel")" = "$(lower "${WAKE_LABEL[i]}")" ] || continue
        [ "$(github_host "$rurl")" = "${WAKE_HOST[i]}" ] || continue
        in_scope "${WAKE_REPO[i]}" "$(scope_owner "$rurl")" || continue
        if [[ "$rurl" =~ ^https://[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
          [ -n "$rid" ] || continue
          serves=0
          runner_serves_repo "$(scope_owner "$rurl")" "$rid" \
            "${WAKE_REPO[i]}" "${WAKE_HOST[i]}" || serves=$?
          [ "$serves" = 0 ] || continue
        fi
        served=1
        break
      done
      if [ "$served" = 1 ]; then
        log "fleet watch: an idle runner on this Mac already serves ${WAKE_REPO[i]} (${WAKE_LABEL[i]}); not waking a dark VM for it"
        continue
      fi
    fi
    pidx=-1
    for ((j = 0; j < ${#DARK_NAME[@]}; j++)); do
      [ "$(lower "${DARK_LABEL[j]}")" = "$(lower "${WAKE_LABEL[i]}")" ] || continue
      # The label is not enough: two VMs can share the default label, and
      # a runner that cannot take the demand's repository would start,
      # idle out, and leave the queued jobs stranded with its dark line
      # already dropped. The demand's host and registration scope must
      # match the recorded url — the same match the stop and restore
      # sides apply.
      [ -n "${DARK_URL[j]}" ] || continue
      [ "$(github_host "${DARK_URL[j]}")" = "${WAKE_HOST[i]}" ] || continue
      in_scope "${WAKE_REPO[i]}" "$(scope_owner "${DARK_URL[j]}")" || continue
      # An organization runner's group must admit the queued repository
      # too: two VMs can share a label in different selected-repository
      # groups, and a VM whose group excludes the repo cannot take the
      # queued jobs no matter what label it carries (route's own
      # permission check, runner_serves_repo). The runner id came from
      # GitHub's row while the VM ran; a registration that is not
      # org-scoped needs no check — in_scope already confined it to its
      # registration repository, whose jobs are the only ones it can take.
      if [[ "${DARK_URL[j]}" =~ ^https://[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        [ -n "${DARK_ID[j]}" ] || continue
        serves=0
        runner_serves_repo "$(scope_owner "${DARK_URL[j]}")" "${DARK_ID[j]}" \
          "${WAKE_REPO[i]}" "${WAKE_HOST[i]}" || serves=$?
        [ "$serves" = 0 ] || continue
      fi
      idx="$(fleet_index "${DARK_NAME[j]}")"
      [ "$idx" != -1 ] && [ "${FLEET_STATUS[idx]}" = Stopped ] || continue
      pidx=$j
      break
    done
    if [ "$pidx" = -1 ]; then
      # No dark VM on this Mac serves this demand. Starting an unrelated
      # VM would drop its dark line for a runner that cannot take the
      # jobs — the one outcome worse than staying dark. Say so and leave
      # it dark; the log is the signal, the way the up-scale side reports
      # a label it cannot serve.
      log "fleet watch: no dark VM here serves ${WAKE_REPO[i]} (${WAKE_LABEL[i]}); not waking"
      continue
    fi
    pname="${DARK_NAME[pidx]}"
    if [ "${WAKE_URGENT[i]}" = 1 ]; then
      log "fleet watch: ${WAKE_REPO[i]} is running on hosted runners; starting ${pname} (scaled to zero)"
    else
      log "fleet watch: jobs have waited ${idle}s for ${WAKE_LABEL[i]}; starting ${pname} (scaled to zero)"
    fi
    wrc=0
    scale_wake_start "$pname" || wrc=1
    # The VM is up: its dark line goes now, not on the next tick's
    # reconcile — the record is what the next demand reads. A recorded
    # secondary also gets a fresh idle clock: its stamp already
    # exceeded the cooldown when it was stopped, and without the reset
    # the next tick would stop it again before it can pick up a job —
    # the same reset the grow side's secondary start does. (A primary's
    # clock heals itself: its line's up flag is cleared while the VM is
    # down, and the next refresh starts a fresh cooldown from it.) The
    # start can also land without the wake proving out — the guest's
    # identity unreadable in time, the runner not online within the
    # wait — and a VM Lima says is Running is up all the same, so the
    # bookkeeping runs for it too; a stopped-again-on-sight cycle is
    # the one outcome worse than the wait.
    up_now=""
    if [ "$wrc" = 1 ]; then
      up_now="$(vm_status_of "$pname")" || up_now=""
    fi
    if [ "$wrc" = 0 ] || [ "$up_now" = Running ]; then
      scale_dark_drop "$pname" && scale_dark_write ||
        echo "homefield: fleet watch: started ${pname} but could not update $(scale_dark_file); the next tick's reconcile drops the stale line" >&2
      for ((wi = 0; wi < ${#SCALE_NAME[@]}; wi++)); do
        [ "${SCALE_NAME[wi]}" = "$pname" ] || continue
        SCALE_BUSY[wi]="$now"
        scale_record_write ||
          echo "homefield: fleet watch: started ${pname} but could not record it; it will be recorded again on the next demand ($(scale_file))" >&2
        break
      done
      if [ "$wrc" = 0 ]; then
        SCALE_ACTION="started ${pname} (from zero)"
        return 0
      fi
      # The start landed without the wake proving out: the VM is up and
      # eligible all the same, so the pass ends here — one VM per tick,
      # and a second start could not serve the demand any better than
      # the runner that is already online. The nonzero return keeps the
      # restore failure visible.
      return 1
    fi
    rc=1
  done
  return "$rc"
}

# scale_wake_start <name>: start one dark fleet's VM and bring its flipped
# repositories back. The start is the scaler subprocess; the restore is the
# watcher's wake pattern — wait for the runner to be listed online (a
# restore to an offline runner would point jobs at nothing), bounded by
# HOMEFIELD_WATCH_WAKE_WAIT — then route the autoflipped repositories back
# to local. A restore that does not land keeps its entries for the next
# start and fails the tick: the VM is up and taking jobs, and the run says
# so loudly.
scale_wake_start() {
  local name="$1" identity_ok=0 tries=0 waited=0 total online=0
  if ! scale_exec start --instance "$name"; then
    echo "homefield: fleet watch: could not start ${name} (log above); the fleet stays dark" >&2
    return 1
  fi
  INSTANCE="$name"
  # The guest answers only once it is up; a boot that is still settling
  # reads as "could not ask", so the identity read retries before it gives
  # up (30 s in total, on top of the start that already waited).
  while [ "$tries" -lt 6 ]; do
    load_runner_settings
    if [ -n "$RS_NAME" ] && [ -n "$RS_URL" ] && [ -n "$RS_ID" ]; then
      identity_ok=1
      break
    fi
    adopt_nap 5
    tries=$((tries + 1))
  done
  if [ "$identity_ok" != 1 ]; then
    echo "homefield: fleet watch: started ${name} but could not read its runner identity; its flipped repositories stay hosted until the next start" >&2
    return 1
  fi
  total="${HOMEFIELD_WATCH_WAKE_WAIT:-120}"
  case "$total" in
    '' | *[!0-9]*) total=120 ;;
  esac
  while [ "$waited" -lt "$total" ]; do
    if runner_on_github "$RS_URL" "$RS_ID" && [ "$RUNNER_GH_STATUS" = online ]; then
      online=1
      break
    fi
    adopt_nap 5
    waited=$((waited + 5))
  done
  if [ "$online" != 1 ]; then
    echo "homefield: fleet watch: ${name}'s runner is not online after ${total}s; its flipped repositories stay hosted until the next start" >&2
    return 1
  fi
  log "fleet watch: started ${name} from zero; routing its flipped repositories back to local"
  route_start_restore "$RS_URL" "$RS_NAME"
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

# scale_tick_lock: the tick's per-Mac lock. Two overlapping `fleet watch`
# runs — a hand-run one and the agent's loop, or two hand-runs — each read
# the scale record into their own arrays and write the file back whole, and
# each picks spare names from its own fleet snapshot: without mutual
# exclusion a slower tick can erase the other's newly created spare from
# idle-stop and reuse bookkeeping, and both can provision the same name.
# mkdir is the atomic test-and-set; a lock left behind by a killed tick
# (the watcher's sleep-side kill) is reclaimed from its dead pid, the way
# preflight's image cache lock works. A contender that cannot take the
# lock stands down: the demand is still queued, and the next interval's
# tick answers it.
scale_tick_lock_acquire() {
  local lock_dir pid attempts=0 dead=0
  lock_dir="$(route_watcher_dir)/scale.lock"
  mkdir -p "$(route_watcher_dir)" 2>/dev/null || return 1
  until mkdir "$lock_dir" 2>/dev/null; do
    pid=""
    if [ -r "$lock_dir/pid" ]; then
      IFS= read -r pid <"$lock_dir/pid" || pid=""
    fi
    if [ -n "$pid" ]; then
      if ! kill -0 "$pid" 2>/dev/null; then
        # The owner is gone: steal the lock with a rename, not a delete.
        # The rename is atomic, so a second contender that read the same
        # dead pid cannot delete the replacement lock the first one has
        # already taken — its rename fails and it re-tries the mkdir. A
        # rename that keeps failing is not a lock we can take: stand down.
        if mv "$lock_dir" "$lock_dir.stolen.$$" 2>/dev/null; then
          rm -rf "$lock_dir.stolen.$$" 2>/dev/null
        else
          dead=$((dead + 1))
          [ "$dead" -lt 50 ] || return 1
        fi
        continue
      fi
      # A live owner: stand down rather than wait out its tick — the
      # demand is still queued, and the next interval's tick answers it.
      return 1
    fi
    # No pid yet: the owner may be between mkdir and its pid write. A dir
    # that never grows one is a crashed take-over candidate.
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 50 ]; then
      if mv "$lock_dir" "$lock_dir.stolen.$$" 2>/dev/null; then
        rm -rf "$lock_dir.stolen.$$" 2>/dev/null
        attempts=0
      else
        return 1
      fi
      continue
    fi
    /bin/sleep 0.1 2>/dev/null || /bin/sleep 1
  done
  printf '%s\n' "$$" >"$lock_dir/pid" 2>/dev/null || true
  return 0
}

# scale_tick_lock_release: drop the lock, but only if it is still ours — a
# release after a reclaim must not remove another tick's lock.
scale_tick_lock_release() {
  local lock_dir pid
  lock_dir="$(route_watcher_dir)/scale.lock"
  [ -d "$lock_dir" ] || return 0
  pid=""
  if [ -r "$lock_dir/pid" ]; then
    IFS= read -r pid <"$lock_dir/pid" || pid=""
  fi
  [ "$pid" = "$$" ] || return 0
  rm -rf "$lock_dir"
}

# fleet_watch_tick: one evaluation. The order is the lifecycle: reconcile
# the scale record with the Mac (a secondary deleted by hand leaves it),
# then the stop side (the idle cooldown), then the demand side (the queued
# threshold). Every failure is fail-safe: nothing scales on an unprovable
# answer, and the tick says so.
fleet_watch_tick() {
  SCALE_ACTION="none"
  local rc=0 now list name st jrc saw_running=0 saw_unknown=0 all_busy=1 unaskable=0 i idx idle j recorded zero_on added write_ok
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
    # A fleet deleted by hand leaves the dark record behind: with no VMs
    # there is nothing to wake, and a stale line would arm the wake side
    # for a fleet that no longer exists.
    rm -f "$(scale_dark_file)"
    fleet_watch_record 0 || true
    return 0
  fi

  # The fleet's state, one pass: FLEET_NAME/STATUS/JOB (parallel arrays),
  # plus whether every Running VM is busy and whether any could not be
  # asked. A job probe that fails is not "idle": the demand side needs
  # "every VM busy" proven, and the stop side needs each secondary's own
  # answer, so an unaskable VM blocks both. A VM whose status itself could
  # not be read (saw_unknown) blocks the wake side the same way: starting
  # VMs while one may already be running is not the scaler's call.
  # The scale-to-zero opt-in (#305): off until the owner turns it on (the
  # plist bakes HOMEFIELD_SCALE_ZERO into the agent's environment, the way
  # the other HOMEFIELD_SCALE_* reach it). When on, the tick maintains the
  # primaries record below and may stop the fleet's own idle VMs after the
  # demand side.
  zero_on=0
  [ "${HOMEFIELD_SCALE_ZERO:-}" = 1 ] && zero_on=1
  # The records come up before the state pass: the pass refreshes the
  # primaries' lines for the VMs it finds Running, and a line for a VM the
  # scale record claims must not be written (secondaries are that record's
  # book). A recorded secondary that is gone from the Mac (deleted by hand)
  # leaves its record here; the stop side's pass below drops it.
  scale_record_read
  scale_primaries_read
  scale_dark_read
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
    if [ -n "$st" ]; then
      [ "$st" = Running ] || continue
    else
      saw_unknown=1
      continue
    fi
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
    # The primaries record (#305), only while the opt-in is on: this VM's
    # line, unless the scale record claims it (a secondary is that record's
    # book). The identity read and the GitHub row are the price of the map
    # the wake side reads once the VM is down and cannot be asked.
    if [ "$zero_on" = 1 ]; then
      recorded=0
      for ((j = 0; j < ${#SCALE_NAME[@]}; j++)); do
        [ "${SCALE_NAME[j]}" = "$name" ] && recorded=1 && break
      done
      if [ "$recorded" = 0 ]; then
        scale_primaries_refresh "$name" "${FLEET_JOB[idx]}"
      fi
    fi
  done <<<"$list"
  INSTANCE="$saved_instance"

  # A VM back up ends its own dark line: the wake side is for a VM the
  # scaler put dark, and a VM running again — by the wake, the user, or
  # anything else — is not dark, whatever put it there.
  if [ "${#DARK_NAME[@]}" -gt 0 ]; then
    for ((i = 0; i < ${#FLEET_NAME[@]}; i++)); do
      [ "${FLEET_STATUS[i]}" = Running ] && scale_dark_drop "${FLEET_NAME[i]}"
    done
  fi

  # The primaries record: drop lines for VMs gone from the Mac (the scale
  # record's own reconcile is the stop side's pass below) and clear the up
  # mark of any line whose VM is not Running, so its next start begins a
  # fresh idle cooldown instead of inheriting its pre-stop stamp.
  local -a pkeep_name=() pkeep_url=() pkeep_label=() pkeep_auto=() pkeep_busy=() pkeep_up=() pkeep_id=()
  for ((i = 0; i < ${#PRIM_NAME[@]}; i++)); do
    idx="$(fleet_index "${PRIM_NAME[i]}")"
    if [ "$idx" = -1 ]; then
      log "fleet watch: primary ${PRIM_NAME[i]} is gone from the Mac; dropping it from the primaries record"
      continue
    fi
    pkeep_name+=("${PRIM_NAME[i]}")
    pkeep_url+=("${PRIM_URL[i]}")
    pkeep_label+=("${PRIM_LABEL[i]}")
    pkeep_auto+=("${PRIM_AUTO[i]}")
    pkeep_busy+=("${PRIM_BUSY[i]}")
    pkeep_id+=("${PRIM_ID[i]}")
    if [ "${FLEET_STATUS[idx]}" = Running ]; then
      pkeep_up+=("${PRIM_UP[i]}")
    else
      pkeep_up+=("")
    fi
  done
  PRIM_NAME=("${pkeep_name[@]+"${pkeep_name[@]}"}")
  PRIM_URL=("${pkeep_url[@]+"${pkeep_url[@]}"}")
  PRIM_LABEL=("${pkeep_label[@]+"${pkeep_label[@]}"}")
  PRIM_AUTO=("${pkeep_auto[@]+"${pkeep_auto[@]}"}")
  PRIM_BUSY=("${pkeep_busy[@]+"${pkeep_busy[@]}"}")
  PRIM_UP=("${pkeep_up[@]+"${pkeep_up[@]}"}")
  PRIM_ID=("${pkeep_id[@]+"${pkeep_id[@]}"}")
  scale_primaries_write ||
    { echo "homefield: fleet watch: could not update $(scale_primaries_file)" >&2; rc=1; }

  # The dark record, reconciled in memory: lines for VMs gone from the Mac
  # go (nothing to wake), and lines for VMs seen Running went already (the
  # pass above). The stop passes below add this tick's lines after this,
  # so a VM this tick stops is not reconciled away by the state pass's
  # stale status; the write happens after them.
  if [ "${#DARK_NAME[@]}" -gt 0 ]; then
    local -a dkeep_name=() dkeep_url=() dkeep_label=() dkeep_id=()
    for ((i = 0; i < ${#DARK_NAME[@]}; i++)); do
      idx="$(fleet_index "${DARK_NAME[i]}")"
      if [ "$idx" = -1 ]; then
        log "fleet watch: dark VM ${DARK_NAME[i]} is gone from the Mac; dropping it from the dark record"
        continue
      fi
      dkeep_name+=("${DARK_NAME[i]}")
      dkeep_url+=("${DARK_URL[i]}")
      dkeep_label+=("${DARK_LABEL[i]}")
      dkeep_id+=("${DARK_ID[i]}")
    done
    DARK_NAME=("${dkeep_name[@]+"${dkeep_name[@]}"}")
    DARK_URL=("${dkeep_url[@]+"${dkeep_url[@]}"}")
    DARK_LABEL=("${dkeep_label[@]+"${dkeep_label[@]}"}")
    DARK_ID=("${dkeep_id[@]+"${dkeep_id[@]}"}")
  fi

  # The restore retry: a Running VM whose runner is online and whose
  # automatic flip has pending entries gets them restored, the way its
  # start would have — a wake or a start whose restore did not land does
  # not leave the repositories hosted until the next start. Only the
  # automatic flip's entries are touched (a manual `route hosted` writes
  # none), and a runner that is not online is left alone: restoring to it
  # would point jobs at nothing.
  if [ -f "$(autoflip_file)" ] && [ "$saw_running" -gt 0 ]; then
    for ((i = 0; i < ${#FLEET_NAME[@]}; i++)); do
      [ "${FLEET_STATUS[i]}" = Running ] || continue
      INSTANCE="${FLEET_NAME[i]}"
      [ "$(state_get auto_route)" = "1" ] || continue
      load_runner_settings
      if [ -n "$RS_NAME" ] && [ -n "$RS_URL" ]; then
        if runner_on_github "$RS_URL" "$RS_ID" && [ "$RUNNER_GH_STATUS" = online ]; then
          route_start_restore "$RS_URL" "$RS_NAME" || rc=1
        fi
      fi
    done
    INSTANCE="$saved_instance"
  fi

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
  local stopped_ok=0 st_now=""
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
            # With the scale-to-zero opt-in on, the identity is read
            # while the VM still runs: it comes from the guest's
            # .runner, which is gone once the VM is down — a read after
            # the stop returns nothing and the VM could never be matched
            # again. A read that fails (or a record without a label)
            # defers the stop to a later tick: a dark line that cannot
            # match demand is a stranded VM, not a wake-eligible one
            # (scale_dark_add_vm says why no line means no wake).
            local dark_url="" dark_id="" dark_ok=1
            if [ "$zero_on" = 1 ]; then
              if [ -z "${SCALE_LABEL[i]:-}" ]; then
                dark_ok=0
              else
                INSTANCE="${SCALE_NAME[i]}"
                load_runner_settings
                INSTANCE="$saved_instance"
                if [ -n "$RS_URL" ]; then
                  dark_url="$RS_URL"
                  dark_id="${RS_ID:-}"
                else
                  dark_ok=0
                fi
              fi
              if [ "$dark_ok" != 1 ]; then
                echo "homefield: fleet watch: could not read ${SCALE_NAME[i]}'s wake identity; not stopping it (fail safe)" >&2
                rc=1
              fi
            fi
            if [ "$dark_ok" = 1 ]; then
              # The dark line is durable before the stop — the same
              # reasoning as the zero pass's: a write that failed after
              # the stop would leave the VM down with no wake
              # eligibility, and the next tick would treat it as
              # hand-stopped.
              write_ok=1
              if [ "$zero_on" = 1 ]; then
                added=0
                scale_dark_add_vm "${SCALE_NAME[i]}" "$dark_url" \
                  "${SCALE_LABEL[i]}" "$dark_id" && added=1
                if ! scale_dark_write; then
                  write_ok=0
                  if [ "$added" = 1 ]; then
                    scale_dark_drop "${SCALE_NAME[i]}" || rc=1
                  fi
                  echo "homefield: fleet watch: could not write $(scale_dark_file); not stopping ${SCALE_NAME[i]} (fail safe)" >&2
                  rc=1
                fi
              fi
              if [ "$write_ok" = 1 ]; then
                stopped_ok=0
                if scale_exec stop --instance "${SCALE_NAME[i]}"; then
                  stopped_ok=1
                else
                  # The real stop can stop the VM and still exit nonzero (the
                  # automatic fallback's flip could not be proven): ask Lima
                  # before calling it a failure, the way the zero pass does.
                  st_now="$(vm_status_of "${SCALE_NAME[i]}")" || st_now=""
                  [ "$st_now" = Stopped ] && stopped_ok=1
                fi
                if [ "$stopped_ok" = 1 ]; then
                  log "fleet watch: stopped secondary ${SCALE_NAME[i]} (idle ${idle}s); it stays recorded as the spare"
                  SCALE_ACTION="stopped ${SCALE_NAME[i]}"
                else
                  echo "homefield: fleet watch: could not stop secondary ${SCALE_NAME[i]} (log above); it stays up" >&2
                  rc=1
                fi
              fi
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

  # ── the scale-to-zero side (#305, opt-in) ──
  # HOMEFIELD_SCALE_ZERO=1 lets the scaler stop the fleet's own VMs — the
  # ones it did not create — after the same idle cooldown the secondaries
  # use, through the real `stop`: it refuses under a live job, and with the
  # automatic fallback on it flips the VM's routed repositories to hosted
  # before it stops, so the dark Mac's jobs still run. Each VM it stops
  # gets a line in the dark record: the VM is dark by the scaler's hand,
  # and the wake side may bring it back on demand. A VM the user stopped
  # by hand never gets a line and never wakes; nor does one whose stop the
  # tick could not prove, nor one whose wake identity the record lacks —
  # a line the wake side cannot match is a stranded VM, not a wake.
  if [ "$zero_on" = 1 ]; then
    local pbusy="" st_now="" pidx=-1
    for ((i = 0; i < ${#FLEET_NAME[@]}; i++)); do
      [ "${FLEET_STATUS[i]}" = Running ] || continue
      recorded=0
      for ((j = 0; j < ${#SCALE_NAME[@]}; j++)); do
        [ "${SCALE_NAME[j]}" = "${FLEET_NAME[i]}" ] && recorded=1 && break
      done
      [ "$recorded" = 0 ] || continue
      case "${FLEET_JOB[i]}" in
        no) ;;
        yes) continue ;;
        *)
          echo "homefield: fleet watch: could not ask whether a job is running on ${FLEET_NAME[i]}; not stopping it (fail safe)" >&2
          rc=1
          continue
          ;;
      esac
      # The idle clock is the primaries record's: the last job this VM ran,
      # reset to now whenever it is seen back up after being down. No line,
      # no stop — the stamp is the proof the cooldown is real.
      pbusy=""
      pidx=-1
      for ((j = 0; j < ${#PRIM_NAME[@]}; j++)); do
        [ "${PRIM_NAME[j]}" = "${FLEET_NAME[i]}" ] && pidx=$j && break
      done
      if [ "$pidx" != -1 ]; then
        pbusy="${PRIM_BUSY[pidx]}"
      fi
      case "$pbusy" in
        '' | *[!0-9]*) pbusy="" ;;
      esac
      if [ -z "$pbusy" ]; then
        echo "homefield: fleet watch: no idle clock for ${FLEET_NAME[i]}; not stopping it (fail safe)" >&2
        rc=1
        continue
      fi
      idle=$((now - pbusy))
      [ "$idle" -ge "$idle_max" ] || continue
      # The wake identity must be in the record before the stop: the
      # identity cannot be read through a stopped guest, so a VM stopped
      # without it could never match demand again — and GitHub's listing
      # failing at refresh time is exactly when the record goes without
      # it. Defer the stop to a tick whose refresh captured the identity.
      if [ -z "${PRIM_URL[pidx]:-}" ] || [ -z "${PRIM_LABEL[pidx]:-}" ] ||
        [ -z "${PRIM_ID[pidx]:-}" ]; then
        echo "homefield: fleet watch: no wake identity recorded for ${FLEET_NAME[i]}; not stopping it (fail safe)" >&2
        rc=1
        continue
      fi
      # The dark line is durable before the stop: the record is the
      # only proof the VM is dark by the scaler's hand, and a write
      # that failed after the stop would leave it down with no wake
      # eligibility — the next tick reads the stale file and treats
      # the VM as hand-stopped, its queued jobs unanswered. A line
      # written for a stop that then fails is harmless: the reconcile
      # drops a line whose VM is seen Running.
      added=0
      scale_dark_add_prim "$pidx" && added=1
      if ! scale_dark_write; then
        if [ "$added" = 1 ]; then
          scale_dark_drop "${FLEET_NAME[i]}" || rc=1
        fi
        echo "homefield: fleet watch: could not write $(scale_dark_file); not stopping ${FLEET_NAME[i]} (fail safe)" >&2
        rc=1
        continue
      fi
      stopped_ok=0
      if scale_exec stop --instance "${FLEET_NAME[i]}"; then
        stopped_ok=1
      else
        # The real stop can stop the VM and still exit nonzero: the
        # automatic fallback's flip could not be proven (GitHub
        # unanswerable) and stop reports that after the stop. Ask Lima
        # before calling it a failure — a VM that is actually down must
        # not be left out of the dark fleet's wake eligibility, and the
        # repositories its unproven flip left routed local are exactly
        # the queued demand the wake side answers.
        st_now="$(vm_status_of "${FLEET_NAME[i]}")" || st_now=""
        [ "$st_now" = Stopped ] && stopped_ok=1
      fi
      if [ "$stopped_ok" = 1 ]; then
        log "fleet watch: stopped ${FLEET_NAME[i]} (idle ${idle}s) — scaled to zero"
        SCALE_ACTION="stopped ${FLEET_NAME[i]} (scaled to zero)"
      else
        echo "homefield: fleet watch: could not stop ${FLEET_NAME[i]} (log above); it stays up" >&2
        rc=1
      fi
    done
  fi

  # The dark record, written: the stop passes wrote their lines before
  # their stops (the record is the proof of scaler-owned shutdown, and a
  # write that failed there skipped the stop), so this write persists
  # what else changed — the reconcile's drops, a VM seen Running or gone
  # — and rewrites the same content when the passes already wrote. A
  # record the tick could not write here is the wake side's blindness
  # about drops only: a stale line for a Running VM cannot trigger a
  # start (the wake matches Stopped VMs), and the next tick's reconcile
  # drops it when the write lands.
  if [ "${#DARK_NAME[@]}" -gt 0 ] || [ -f "$(scale_dark_file)" ]; then
    scale_dark_write ||
      echo "homefield: fleet watch: could not update $(scale_dark_file); the wake side reads the stale record this tick" >&2
  fi

  # ── the demand side ──
  # Only when the queue is real: at least one VM running, every one of them
  # busy (an idle runner is taking jobs; nothing waits behind anything), and
  # every job probe answered. The lookup itself is the expensive part, so it
  # never runs for a fleet that is not fully busy.
  local grow_started=0
  if [ "$saw_running" = 0 ]; then
    # The fleet is dark. Only VMs the scaler's own scale-to-zero stops put
    # here wake on demand (#305): the dark record says which. A fleet the
    # user stopped by hand stays down — the owner's explicit choice — and
    # a VM whose status could not be read keeps the scaler from starting
    # anything, because one may already be running.
    if [ "$saw_unknown" = 1 ]; then
      echo "homefield: fleet watch: could not ask Lima about every VM; not waking a dark fleet (fail safe)" >&2
      rc=1
    else
      scale_wake || rc=1
    fi
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
            if [ "$SCALE_ACTION" != "$action_before" ]; then
              grow_started=1
              break
            fi
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
  # The wake side runs for a partly-running fleet too (#305): a VM another
  # scope's wake brought up must not strand this scope's dark line — the
  # grow side answers only demands a Running VM serves, and one it started
  # this tick already took the tick's one VM. Skipped when the tick could
  # not ask about every running VM's job: the demand may be answered
  # already, and the wake would start a second VM for it. Also skipped
  # when a VM's status itself could not be read: one may already be
  # running and serving the demand, the same guard the fully-dark branch
  # applies above. Nothing to wake (no dark line) is the common fleet:
  # the call, and its log, are for the scale-to-zero opt-in only.
  if [ "$saw_running" -gt 0 ] && [ "$unaskable" = 0 ] && [ "$grow_started" = 0 ] \
    && [ "${#DARK_NAME[@]}" -gt 0 ]; then
    if [ "$saw_unknown" = 1 ]; then
      echo "homefield: fleet watch: could not ask Lima about every VM; not waking a dark fleet (fail safe)" >&2
      rc=1
    else
      scale_wake || rc=1
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
    if scale_tick_lock_acquire; then
      fleet_watch_tick || rc=1
      scale_tick_lock_release
    else
      log "fleet watch: another tick holds the scaler lock on this Mac; standing down"
    fi
    ticks=$((ticks + 1))
    if [ "$max_ticks" -gt 0 ] && [ "$ticks" -ge "$max_ticks" ]; then
      break
    fi
    adopt_nap "$interval"
  done
  return "$rc"
}
