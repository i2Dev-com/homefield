#!/usr/bin/env bash
# The guest's memory sampler (ci-runner-memwatch, embedded in provision.sh):
# lint it as extracted, then run it against a fake /proc for a few seconds and
# check the rows it writes.
#
# The sampler runs in the guest (Ubuntu, bash 5) and uses printf '%(...)T',
# which macOS's bash 3.2 lacks, so the run needs a newer bash; without one
# the lint still runs and the run is reported as skipped.
#
# Run:  bash tests/memwatch.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
script="$work/ci-runner-memwatch"

# Between the heredoc's opening line and its terminator.
sed -n "/^cat > \/usr\/local\/sbin\/ci-runner-memwatch <<'EOF'\$/,/^EOF\$/p" "$ROOT/vm/provision.sh" |
  sed '1d;$d' >"$script"
record "extracted the sampler" "yes" "$([ -s "$script" ] && echo yes || echo no)"

if command -v shellcheck >/dev/null; then
  record "shellcheck" "clean" "$(shellcheck "$script" >/dev/null 2>&1 && echo clean || echo findings)"
else
  echo "  skip shellcheck (not installed)"
fi

new_bash=""
for candidate in bash /opt/homebrew/bin/bash /usr/local/bin/bash; do
  # shellcheck disable=SC2016  # the candidate bash expands it, not this one
  if command -v "$candidate" >/dev/null &&
    [ "$("$candidate" -c 'echo $((BASH_VERSINFO[0] * 10 + BASH_VERSINFO[1]))')" -ge 42 ]; then
    new_bash="$candidate"
    break
  fi
done
if [ -z "$new_bash" ]; then
  echo "  skip run (needs bash >= 4.2)"
  summary
  exit
fi

fake_meminfo() { # <available kB>
  printf 'MemTotal:        8000000 kB\nMemFree:         1000000 kB\nMemAvailable:    %s kB\nBuffers: 1 kB\n' "$1" >"$work/meminfo.tmp"
  mv "$work/meminfo.tmp" "$work/meminfo"
}
fake_meminfo 7000000
printf 'nr_free_pages 1\noom_kill 3\npgfault 9\n' >"$work/vmstat"

# One row a second, a sample every 0.2 s. Halfway through, free memory drops
# by 1,000,000 kB, which must show up as the peak.
(
  sleep 1.7
  fake_meminfo 6000000
  touch "$work/job"
) &
MEMWATCH_DIR="$work/log" MEMWATCH_INTERVAL=0.2 MEMWATCH_PERIOD=1 \
  MEMWATCH_MEMINFO="$work/meminfo" MEMWATCH_VMSTAT="$work/vmstat" \
  MEMWATCH_JOB_FILE="$work/job" \
  timeout 5 "$new_bash" "$script" >/dev/null 2>&1
wait

csv="$(cat "$work"/log/memwatch-*.csv 2>/dev/null)"
header="ts,samples,total_mib,used_avg_mib,used_max_mib,avail_min_mib,oom_kills,job"
record "header" "$header" "$(echo "$csv" | head -1)"
rows="$(echo "$csv" | tail -n +2)"
record "wrote at least 3 rows" "yes" "$([ "$(echo "$rows" | grep -c .)" -ge 3 ] && echo yes || echo no)"
record "every row has 8 columns" "0" "$(echo "$rows" | awk -F, 'NF != 8' | grep -c .)"
# 8000000 kB total is 7812 MiB; 1,000,000 kB used is 976, 2,000,000 kB is 1953.
record "total_mib" "7812" "$(echo "$rows" | head -1 | cut -d, -f3)"
record "first row peak is the lower level" "976" "$(echo "$rows" | head -1 | cut -d, -f5)"
record "a later row peak is the raised level" "1953" "$(echo "$rows" | cut -d, -f5 | sort -n | tail -1)"
record "avail_min follows the same drop" "5859" "$(echo "$rows" | cut -d, -f6 | sort -n | head -1)"
record "oom_kills read from vmstat" "3" "$(echo "$rows" | head -1 | cut -d, -f7)"
# The job marker appears with the memory drop: the first row has none, the
# last row (which ends after it) has one. The machine running this test may
# be a runner itself, so the sampler's own process check is not used.
record "no job in the first row" "0" "$(echo "$rows" | head -1 | cut -d, -f8)"
record "a job seen in a later row" "1" "$(echo "$rows" | cut -d, -f8 | sort -n | tail -1)"

summary
