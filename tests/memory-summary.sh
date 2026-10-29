#!/usr/bin/env bash
# The awk behind `bin/homefield memory`: per-day average and peak, the peak
# during jobs, and out-of-memory kills counted across a guest reboot, which
# restarts the kernel's counter — with the boot column deciding the cases the
# counter alone cannot (first retained row, reboot without a lower value,
# #91).
#
# Run:  bash tests/memory-summary.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The program text, between MEMORY_AWK=' and the closing quote.
prog="$(sed -n "/^MEMORY_AWK='\$/,/^}'\$/p" "$ROOT/bin/homefield" | sed '1d;$d')"
prog="${prog}
}"
record "extracted the awk program" "yes" "$([ -n "$prog" ] && echo yes || echo no)"

# ts,samples,total_mib,used_avg_mib,used_max_mib,avail_min_mib,oom_kills,job
rows='ts,samples,total_mib,used_avg_mib,used_max_mib,avail_min_mib,oom_kills,job
2026-10-01T10:00:00-0400,30,8000,300,500,7000,0,0
2026-10-01T10:01:00-0400,30,8000,400,900,6500,0,1
ts,samples,total_mib,used_avg_mib,used_max_mib,avail_min_mib,oom_kills,job
2026-10-02T11:20:00-0400,30,8000,500,1300,6000,2,1
2026-10-02T11:21:00-0400,30,8000,200,300,7500,2,0
2026-10-03T00:00:00-0400,30,8000,100,200,7700,1,0
2026-10-03T00:01:00-0400,30,8000,300,400,7600,1,0'

out="$(printf '%s\n' "$rows" | awk -v cutoff=2026-10-02 "$prog")"
echo "$out"
echo

row() { echo "$out" | awk -v d="$1" '$1 == d { $1 = ""; print }' | tr -s ' ' | sed 's/^ //'; }
# minutes, avg, peak, job peak, min avail, OOM
record "10-01 is before the cutoff" "" "$(row 2026-10-01)"
record "10-02: peak, job peak and OOM kills" "2 350 1300 1300 6000 2" "$(row 2026-10-02)"
record "10-03: a reboot restarts the counter at 1: that kill counts; no job, so no job peak" "2 200 400 - 7600 1" "$(row 2026-10-03)"
record "summary line" \
  "VM memory 8000 MiB. Over 4 minutes: average 275 MiB, highest minute 1300 MiB (16%) on 2026-10-02 at 11:20, 3 out-of-memory kills." \
  "$(echo "$out" | tail -1)"

# Nothing after the cutoff is reported as such (exit 3), not as a zero table.
printf '%s\n' "$rows" | awk -v cutoff=2026-12-01 "$prog" >/dev/null
record "no rows since the cutoff exits 3" "3" "$?"

# The boot column (#91): the 9th field is the epoch of the boot the row's
# oom counter started at. cutoff_epoch is midnight of the cutoff day.
echo "the boot column (#91):"
cutoff_epoch="$(date -j -f %F -v0H -v0M -v0S 2026-10-02 +%s)"   # what cmd_memory passes
H9='ts,samples,total_mib,used_avg_mib,used_max_mib,avail_min_mib,oom_kills,job,boot'
# run9 <boot-or-empty args> <rows...>: awk with the cutoff pair, fresh $out.
run9() {
  local ce="$1"; shift
  out="$(printf '%s\n' "$@" | awk -v cutoff=2026-10-02 -v cutoff_epoch="$ce" "$prog")"
}
# The first retained row, holding kills its counter took since boot:
run9 "$cutoff_epoch" "$H9" "2026-10-02T11:20:00-0400,30,8000,500,1300,6000,3,1,$((cutoff_epoch + 3600))"
record "boot inside the window: the first row's kills count (was: 0)" "1 500 1300 1300 6000 3" "$(row 2026-10-02)"
run9 "$cutoff_epoch" "$H9" "2026-10-02T11:20:00-0400,30,8000,500,1300,6000,3,1,$((cutoff_epoch - 86400))"
record "boot before the window: they may predate it and stay uncounted" "1 500 1300 1300 6000 0" "$(row 2026-10-02)"
run9 "$cutoff_epoch" "${H9/,boot/}" "2026-10-02T11:20:00-0400,30,8000,500,1300,6000,3,1"
record "an old 8-column log cannot decide: still uncounted, as documented" "1 500 1300 1300 6000 0" "$(row 2026-10-02)"
# A reboot between rows, decided by the boot column rather than the counter:
# the counter did NOT fall (previous boot had only 2), so the old rule
# subtracted 2 kills that belonged to the previous boot.
run9 "$cutoff_epoch" "$H9" \
  "2026-10-01T23:00:00-0400,30,8000,300,500,7000,2,0,$((cutoff_epoch - 100))" \
  "2026-10-02T11:20:00-0400,30,8000,500,1300,6000,4,1,$((cutoff_epoch + 200))"
record "boot changed between rows: the whole new counter counts (was: 2)" "1 500 1300 1300 6000 4" "$(row 2026-10-02)"
# Same boot on both sides: the difference, as before.
run9 "$cutoff_epoch" "$H9" \
  "2026-10-01T23:00:00-0400,30,8000,300,500,7000,5,0,$((cutoff_epoch - 100))" \
  "2026-10-02T11:20:00-0400,30,8000,500,1300,6000,9,1,$((cutoff_epoch - 100))"
record "same boot: the difference, with the column present" "1 500 1300 1300 6000 4" "$(row 2026-10-02)"

summary
