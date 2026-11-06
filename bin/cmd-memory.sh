#!/usr/bin/env bash
# The memory and report commands.

# memory_cutoff_epoch <cutoff-day> <rows>: the cutoff day's midnight as an
# epoch, in the timezone the rows themselves carry. The summary selects
# rows by each row's own (guest) calendar day, so the epoch that decides a
# first row or a reboot must use the same day boundary — the host's
# midnight is a different instant when the zones differ (#91 review). The
# offset comes from the first row at/after the cutoff (an earlier row's day
# is outside the window). Empty when nothing is at/after the cutoff or the
# date cannot be parsed, which the summary then treats as "cannot decide".
memory_cutoff_epoch() {
  local cutoff="$1" rows="$2" offset
  offset="$(printf '%s\n' "$rows" | awk -F, -v cutoff="$cutoff" '
    $1 != "ts" && substr($1, 1, 10) >= cutoff { print substr($1, 20, 5); exit }')"
  [ -n "$offset" ] || return 0
  # ts is always YYYY-MM-DDTHH:MM:SS+HHMM (samplers %z), so the offset sits
  # at characters 20-24. BSD date first, GNU fallback: the tool runs only on
  # macOS, but the suites run here and on Linux CI.
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "${cutoff}T00:00:00${offset}" +%s 2>/dev/null ||
    date -d "${cutoff}T00:00:00${offset}" +%s 2>/dev/null || true
}

# Per-day summary of the guest's memwatch rows (vm/provision.sh,
# homefield-memwatch): ts,samples,total_mib,used_avg_mib,used_max_mib,
# avail_min_mib,oom_kills,job[,boot]. Files sort by date, so rows arrive in
# time order and the cumulative oom counter can be diffed row to row. The
# counter restarts at a reboot, so: a boot change between two rows (column 9,
# added for #91) means the whole value is kills since that boot; same boot,
# take the difference. Both whole-counter cases count only when that boot is
# known (a 0 from an unreadable btime is unknown, not a boot at the epoch)
# and began inside the window (cutoff_epoch, compared as epochs) — kills
# under a boot older than the window span its start and cannot be split, and
# guessing would overcount, the #91 review's point against prev = 0. Rows
# from before column 9 (8 fields) fall back to the counter rule: a smaller
# value than before means a reboot; nothing can be decided for their first
# row, which stays uncounted.
# shellcheck disable=SC2016  # awk, not shell, expands the $n fields
MEMORY_AWK='
BEGIN { FS = ","; prev = -1; prev_boot = -1 }
$1 == "ts" || (NF != 8 && NF != 9) { next }
{
  day = substr($1, 1, 10)
  boot = (NF >= 9 && $9 + 0 > 0 ? $9 + 0 : -1)
  if (day < cutoff) { prev = $7; prev_boot = boot; next }
  if (!(day in n)) { order[++days] = day; mn[day] = -1 }
  n[day]++
  sum[day] += $4
  if ($5 > peak[day]) { peak[day] = $5; at[day] = substr($1, 12, 5) }
  if (mn[day] < 0 || $6 < mn[day]) mn[day] = $6
  if ($8 == 1) { busy[day]++; if ($5 > bpeak[day]) bpeak[day] = $5 }
  if (prev < 0) {
    if (boot >= 0 && cutoff_epoch != "" && boot >= cutoff_epoch + 0) oom[day] += $7
  } else if (boot >= 0 && prev_boot >= 0 && boot != prev_boot) {
    # Rebooted between rows: the counter is all kills since the NEW boot.
    # It counts only when that boot is inside the window — the previous row
    # can precede the window and the reboot can too, and then the counter
    # reaches across the boundary (#91 review).
    if (cutoff_epoch != "" && boot >= cutoff_epoch + 0) oom[day] += $7
  } else {
    oom[day] += ($7 >= prev ? $7 - prev : $7)
  }
  prev = $7
  prev_boot = boot
  total = $3
  tn++
  tsum += $4
  if ($5 > tpeak) { tpeak = $5; tday = day; tat = substr($1, 12, 5) }
}
END {
  if (days == 0) exit 3
  printf "%-10s %8s %9s %9s %10s %9s %5s\n", "day", "minutes", "avg MiB", "peak MiB", "job peak", "min avail", "OOM"
  for (i = 1; i <= days; i++) {
    d = order[i]
    printf "%-10s %8d %9d %9d %10s %9d %5d\n", d, n[d], sum[d] / n[d], peak[d], (busy[d] ? bpeak[d] : "-"), mn[d], oom[d]
    allOom += oom[d]
  }
  printf "\nVM memory %d MiB. Over %d minutes: average %d MiB, highest minute %d MiB (%d%%) on %s at %s, %d out-of-memory kills.\n", total, tn, tsum / tn, tpeak, tpeak * 100 / total, tday, tat, allOom
}'

# memory_single: one VM's table; vm_dispatch runs it for every VM by default.
memory_single() {
  local days=7 cutoff rows rc cutoff_epoch
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="${2:?--days needs a value}"; shift 2 ;;
      *) die "memory: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -lt 1 ]; then
    die "memory: --days must be a positive number"
  fi
  check_host
  vm_lookup
  [ "$VM_STATUS" = "Running" ] || die "memory: VM ${INSTANCE} is not running"
  # The table has no instance in it, so a run over several VMs heads its block.
  [ "${HOMEFIELD_ONE_OF_MANY:-}" != 1 ] || echo "VM ${INSTANCE}: Running"
  # BSD date, as on macOS: today minus (days - 1), so --days 1 is today.
  cutoff="$(date -v-"$((days - 1))"d +%F)"
  rows="$(guest sh -c 'cat /var/log/homefield/memwatch-*.csv 2>/dev/null; true')" ||
    die "memory: could not read the memory log from VM ${INSTANCE}"
  [ -n "$rows" ] || die "memory: no samples in ${INSTANCE} yet; the sampler is installed by bin/homefield upgrade"
  # The same instant as an epoch, for comparing the CSV's boot column
  # (#91): midnight at the start of the cutoff day, measured in the guests
  # timezone from the rows themselves, never the hosts.
  cutoff_epoch="$(memory_cutoff_epoch "$cutoff" "$rows")"
  rc=0
  printf '%s\n' "$rows" | awk -v cutoff="$cutoff" -v cutoff_epoch="$cutoff_epoch" "$MEMORY_AWK" || rc=$?
  [ "$rc" -ne 3 ] || die "memory: no samples since ${cutoff}"
  [ "$rc" -eq 0 ] || exit "$rc"
}

cmd_memory() {
  # The options are validated once here, so a bad one fails before any VM is
  # asked and does not repeat for each of them (#182).
  local days=7 opts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --days)
        days="${2:?--days needs a value}"
        opts+=("--days" "${2}")
        shift 2
        ;;
      *) die "memory: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -lt 1 ]; then
    die "memory: --days must be a positive number"
  fi
  vm_dispatch memory memory_single "${opts[@]+"${opts[@]}"}"
}

cmd_report() {
  command -v python3 >/dev/null || die "report needs python3"
  command -v gh >/dev/null || die "report needs gh (https://cli.github.com)"
  exec python3 "$ROOT/tools/report.py" "$@"
}
