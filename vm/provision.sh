#!/usr/bin/env bash
# Provision the local GitHub Actions runner inside the Lima VM.
#
# Runs inside the guest as root. Copy it in and run it; see docs/runbook.md
# for the full sequence:
#
#   limactl copy vm/provision.sh homefield:/tmp/provision.sh
#   printf 'RUNNER_TOKEN=%s\n' "$TOKEN" |
#     limactl shell homefield sudo RUNNER_URL=https://github.com/<org> \
#       bash /tmp/provision.sh
#
# Settings, as environment variables (after `sudo`, as above):
#   RUNNER_URL    where to register: https://github.com/<org>, or a repository
#                 URL. Required to register or move; not needed to re-run on a
#                 runner that is already registered.
#   RUNNER_LABEL  the custom label workflows route on (default homefield-ci). Must
#                 match routing-guard's `label` input and the label in every
#                 inline expression.
#   RUNNER_NAME   default: the guest's hostname (lima-<instance>).
#   RUNNER_GROUP  org runner group to join (default homefield-ci).
#   RUNNER_EXTRA_PACKAGES
#                 apt packages to install on top of the base set, space-
#                 separated. Saved in the guest, so later runs keep them
#                 without passing it again; setting it replaces the saved
#                 list, and setting it empty clears it (nothing is removed).
# Tools apt does not have go in hooks: /etc/homefield/provision.d/*.sh, run
# as root in name order after the packages. See docs/runbook.md, "Adding
# tools".
# Name, label and group are read only at registration. To change the label
# later, edit the runner's labels on GitHub (runners page or REST API); to
# change the name or group, remove the runner and register it again
# (docs/runbook.md). Re-running with new values changes nothing.
#
# Tokens arrive on stdin, one KEY=VALUE per line (RUNNER_TOKEN, and
# RUNNER_REMOVE_TOKEN for a move), and nowhere else. A token on a command line
# is in /proc/<pid>/cmdline, which every user in the guest can read, including
# the `runner` user CI jobs run as, and an org registration token lets whoever
# holds it register a rogue runner for up to an hour. From stdin the token only
# lives in this root process and reaches config.sh through its environment
# (/proc/<pid>/environ is readable by the owner alone). No job runs while it
# does: a first registration has no service yet, and a move stops the service
# before anything else and refuses to start while a job is running. That last
# part is what actually holds, because the `docker` group makes jobs
# root-equivalent inside the guest.
#
# The registration token is a one-hour token, not a credential the runner
# keeps: config.sh exchanges it for the runner's own identity. Idempotent:
# re-running upgrades packages and skips registration if already registered.
#
# Scope: an organization URL lets one runner serve every repository its runner
# group allows (docs/runbook.md, "Runner group"). A repository URL gives a
# runner scoped to that one repository.
#
# Moving an existing runner (repo -> org, or to another org): run with
# RUNNER_REREGISTER=1 and both tokens on stdin, RUNNER_REMOVE_TOKEN for its
# current scope and RUNNER_TOKEN for the new one. The old registration is
# removed and the runner registered again under RUNNER_NAME and RUNNER_LABEL,
# so pass the current values to keep them.
set -euo pipefail

RUNNER_VERSION="2.337.0"
RUNNER_SHA256="9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393"
RUNNER_URL="${RUNNER_URL:-}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABEL="${RUNNER_LABEL:-homefield-ci}"
# Org registrations join the runner group that limits which repositories may
# use the runner (docs/runbook.md, "Runner group"). Without one the runner
# lands in Default, usable by every repository in the organization. Runner
# groups do not exist for a repository-scoped runner, so none is passed there.
if [[ "$RUNNER_URL" =~ ^https://github\.com/[^/]+/?$ ]]; then
  RUNNER_GROUP="${RUNNER_GROUP:-homefield-ci}"
else
  RUNNER_GROUP=""
fi
# RUNNER_LABEL is the label the workflows route on. The others are GitHub's
# defaults for this platform, repeated so the list is explicit. It must be a
# single custom label: a comma would smuggle in extra labels. It must not be a
# GitHub default label or a hosted image name either, because GitHub gives a
# job any runner whose labels are a superset of the request: a runner labelled
# `ubuntu-latest` would take every plain `runs-on: ubuntu-latest` job in the
# organization, with none of the expression's guards. routing_guard.py
# applies the same rule to its `label` input; keep the two in step.
if ! [[ "$RUNNER_LABEL" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "provision.sh: RUNNER_LABEL must be one label of letters, digits, '.', '_' or '-'" >&2
  exit 1
fi
label_lc="$(printf '%s' "$RUNNER_LABEL" | tr '[:upper:]' '[:lower:]')"
if [[ "$label_lc" =~ ^(self-hosted|linux|windows|macos|ubuntu|x64|x86|arm|arm64)$ ]] ||
  [[ "$label_lc" =~ ^(ubuntu|windows|macos)- ]]; then
  echo "provision.sh: RUNNER_LABEL must be a custom label, not a GitHub default label or hosted image name ($RUNNER_LABEL)" >&2
  exit 1
fi
RUNNER_LABELS="self-hosted,linux,arm64,${RUNNER_LABEL}"
if [ -n "$RUNNER_URL" ] && ! [[ "$RUNNER_URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?/?$ ]]; then
  echo "provision.sh: RUNNER_URL must be https://github.com/<org> or https://github.com/<owner>/<repo>, got: $RUNNER_URL" >&2
  exit 1
fi
# Debian package names, checked before anything runs; the names reach
# apt-get as arguments, so an option (`-o ...`) must not get through either.
# Space-separated on one line: `read` stops at a newline, so a multi-line
# value would silently lose everything after its first line.
if [[ "${RUNNER_EXTRA_PACKAGES:-}" == *$'\n'* ]]; then
  echo "provision.sh: RUNNER_EXTRA_PACKAGES: separate packages with spaces, on one line" >&2
  exit 1
fi
read -ra requested_packages <<<"${RUNNER_EXTRA_PACKAGES:-}"
for pkg in ${requested_packages[@]+"${requested_packages[@]}"}; do
  if ! [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]+$ ]]; then
    echo "provision.sh: RUNNER_EXTRA_PACKAGES: not a package name: $pkg" >&2
    exit 1
  fi
done
CONFIG_DIR="/etc/homefield"
RUNNER_USER="runner"
RUNNER_HOME="/opt/actions-runner"

# A guest that ci-runner v2 provisioned keeps its config in /etc/ci-runner and
# its units named ci-runner-*. v3 uses other paths and does not move these, so
# running here would leave two sets of timers and a half-configured runner:
# refuse, before anything changes (read-only checks, so ahead of the root
# check). PROVISION_SYSROOT prefixes the paths looked at; the tests point it at
# a fixture so they never read this machine's /etc.
v2_leftover=""
sysroot="${PROVISION_SYSROOT:-}"
if [ -e "$sysroot/etc/ci-runner" ] || [ -L "$sysroot/etc/ci-runner" ]; then
  v2_leftover="/etc/ci-runner"
fi
for unit in "$sysroot"/etc/systemd/system/ci-runner-*.timer "$sysroot"/etc/systemd/system/ci-runner-*.service; do
  if [ -e "$unit" ] || [ -L "$unit" ]; then
    v2_leftover="${v2_leftover:-${unit#"$sysroot"}}"
  fi
done
if [ -n "$v2_leftover" ]; then
  echo "provision.sh: this VM was provisioned by ci-runner v2 (found ${v2_leftover}). v3 does not upgrade it in place:" \
       "replace the VM by following docs/runbook.md, \"Migrating from ci-runner (v2)\"" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "provision.sh: run as root (sudo)" >&2
  exit 1
fi

# ── Tokens ──────────────────────────────────────────────────────────────────
if [ -n "${RUNNER_TOKEN:-}${RUNNER_REMOVE_TOKEN:-}" ]; then
  echo "provision.sh: pass tokens on stdin, not in the environment or on the" \
       "command line (see the header of this script)" >&2
  exit 1
fi
RUNNER_TOKEN=""
RUNNER_REMOVE_TOKEN=""
if [ ! -t 0 ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      RUNNER_TOKEN=*) RUNNER_TOKEN="${line#RUNNER_TOKEN=}" ;;
      RUNNER_REMOVE_TOKEN=*) RUNNER_REMOVE_TOKEN="${line#RUNNER_REMOVE_TOKEN=}" ;;
      "") ;;
      *) echo "provision.sh: ignoring an unrecognised line on stdin" >&2 ;;
    esac
  done
fi

# ── What this run has to do ─────────────────────────────────────────────────
# The scope the runner is registered at now, from its own config (a JSON file
# written with a BOM, hence utf-8-sig).
# Prints the named settings, one per line: a name may contain spaces.
runner_setting() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8-sig")); print(*(d[k] for k in sys.argv[2:]), sep="\n")' \
    "$RUNNER_HOME/.runner" "$@"
}
registered_url() { runner_setting gitHubUrl; }
job_running() { pgrep -f Runner.Worker >/dev/null; }
svc_unit=""
if [ -f "$RUNNER_HOME/.service" ]; then
  svc_unit="$(cat "$RUNNER_HOME/.service")"
fi

# A move is done once the runner is registered at RUNNER_URL. Re-running the
# same command after a later step failed (say, the service did not start) must
# not remove that new registration with a remove token for the *old* scope,
# which would fail and leave the runner offline. So it only moves what has not
# moved yet.
# RUNNER_URL has no default: a guess would register the runner, possibly at
# the wrong organization, and a move compares against it.
if [ -z "$RUNNER_URL" ] && { [ "${RUNNER_REREGISTER:-0}" = "1" ] || [ ! -f "$RUNNER_HOME/.runner" ]; }; then
  echo "provision.sh: set RUNNER_URL (https://github.com/<org> or a repository URL) to register" >&2
  exit 1
fi
move=0
if [ "${RUNNER_REREGISTER:-0}" = "1" ] && [ -f "$RUNNER_HOME/.runner" ]; then
  if [ "$(registered_url)" = "${RUNNER_URL%/}" ]; then
    echo "provision.sh: already registered at ${RUNNER_URL}; skipping re-registration (name and labels unchanged)"
  else
    move=1
  fi
fi
restart_old_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "provision.sh: move failed before the old registration was removed; restarting ${svc_unit}" >&2
    systemctl start "$svc_unit" || true
  fi
}
if [ "$move" = "1" ]; then
  if [ -z "$RUNNER_REMOVE_TOKEN" ] || [ -z "$RUNNER_TOKEN" ]; then
    echo "provision.sh: a move needs RUNNER_REMOVE_TOKEN and RUNNER_TOKEN on stdin" >&2
    exit 1
  fi
  if job_running; then
    echo "provision.sh: a job is running; move the runner while it is idle" >&2
    exit 1
  fi
  # Stopped before anything else, so no job can start while the tokens exist.
  # Until the old registration is removed below, the old runner is still
  # whole, so a failure on the way there (apt, a hook, the runner binary)
  # starts it again instead of leaving it offline.
  if [ -n "$svc_unit" ]; then
    systemctl stop "$svc_unit"
    trap restart_old_on_failure EXIT
  fi
elif [ ! -f "$RUNNER_HOME/.runner" ] && [ -z "$RUNNER_TOKEN" ]; then
  echo "provision.sh: first registration needs RUNNER_TOKEN on stdin" >&2
  exit 1
fi

# ── Packages ────────────────────────────────────────────────────────────────
# The base set: common tools that ubuntu-latest has and a minimal Ubuntu does
# not, kept small on purpose. Everything else a repository needs goes in
# RUNNER_EXTRA_PACKAGES or a hook, not here. Docker is for job `services:`.
# Compose v2 and buildx are not optional: Ubuntu's docker.io ships without
# either plugin, so `docker compose` and `docker buildx` (which `docker build
# --secret` needs) fail in a job without them. A job can still bring its own
# buildx, as docker/setup-buildx-action does, and that copy wins. dnsutils
# keeps `dig` as on a hosted runner. python3 is also what this script reads
# the runner's config with.
mkdir -p "$CONFIG_DIR/provision.d"
# This run's extras: RUNNER_EXTRA_PACKAGES when set (even empty), else the list
# saved by the last run that set it. Saved only once apt has installed it, so
# a misspelt name or a network failure leaves the saved list as it was.
extra_packages=()
if [ -n "${RUNNER_EXTRA_PACKAGES+set}" ]; then
  extra_packages=(${requested_packages[@]+"${requested_packages[@]}"})
elif [ -f "$CONFIG_DIR/extra-packages" ]; then
  mapfile -t extra_packages <"$CONFIG_DIR/extra-packages"
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q \
  ca-certificates curl git jq python3 tar zip unzip dnsutils build-essential \
  docker.io docker-compose-v2 docker-buildx \
  ${extra_packages[@]+"${extra_packages[@]}"}
if [ -n "${RUNNER_EXTRA_PACKAGES+set}" ]; then
  printf '%s\n' ${extra_packages[@]+"${extra_packages[@]}"} | sed '/^$/d' >"$CONFIG_DIR/extra-packages"
fi
systemctl enable --now docker

# ── Runner user ─────────────────────────────────────────────────────────────
# Not the Lima login user, which has passwordless sudo. Docker group membership
# is root-equivalent inside the guest; the VM, not this user, is the boundary.
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$RUNNER_USER"
fi
usermod -aG docker "$RUNNER_USER"

# ── Hooks ───────────────────────────────────────────────────────────────────
# For tools apt does not have. Each runs as root on every provisioning run, so
# it has to be idempotent, and a failing one stops provisioning here, before
# the runner is installed or upgraded. They run after the runner user exists,
# so a hook can install into its home.
for hook in "$CONFIG_DIR"/provision.d/*.sh; do
  [ -e "$hook" ] || continue
  echo "provision.sh: running hook $hook"
  if ! bash "$hook"; then
    echo "provision.sh: hook $hook failed; stopping before the runner is installed or upgraded" >&2
    exit 1
  fi
done

# ── Runner binary ───────────────────────────────────────────────────────────
# Download and verify *before* touching the running service, so a bad pin or a
# network failure leaves the old runner up. Only then stop it: extracting over
# a running Runner.Listener fails with ETXTBSY, and a running service keeps
# executing the old binary anyway. Stopping cancels any job in progress, so
# upgrade while idle (runbook). If the replacement itself fails, the old
# service is started again rather than left down.
mkdir -p "$RUNNER_HOME"
if [ ! -x "$RUNNER_HOME/config.sh" ] || ! grep -qx "$RUNNER_VERSION" "$RUNNER_HOME/.provisioned-version" 2>/dev/null; then
  tarball="$(mktemp /tmp/actions-runner.XXXXXX.tar.gz)"
  curl -fsSL -o "$tarball" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz"
  echo "${RUNNER_SHA256}  ${tarball}" | sha256sum -c -
  restart_old=0
  if [ -n "$svc_unit" ] && systemctl is-active --quiet "$svc_unit"; then
    echo "provision.sh: stopping ${svc_unit} to replace the runner binary"
    systemctl stop "$svc_unit"
    restart_old=1
  fi
  if [ "$restart_old" = "1" ]; then
    trap 'echo "provision.sh: replacing the runner failed; restarting the old service" >&2; systemctl start "$svc_unit" || true' ERR
  fi
  tar -xzf "$tarball" -C "$RUNNER_HOME"
  rm -f "$tarball"
  "$RUNNER_HOME/bin/installdependencies.sh"
  echo "$RUNNER_VERSION" > "$RUNNER_HOME/.provisioned-version"
  trap - ERR
fi
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"

# ── Registration + service ──────────────────────────────────────────────────
# config.sh reads `--token` from ACTIONS_RUNNER_INPUT_TOKEN when the flag is
# absent, which keeps the token off its command line. --preserve-env passes
# just that one variable through sudo.
runner_config() {
  local token="$1"
  shift
  ACTIONS_RUNNER_INPUT_TOKEN="$token" \
    sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u "$RUNNER_USER" \
    "$RUNNER_HOME/config.sh" "$@"
}
if [ "$move" = "1" ]; then
  # From here on the old registration is being dismantled; there is nothing
  # left to restart. A failure now needs the same command re-run (runbook).
  trap - EXIT
  if [ -f "$RUNNER_HOME/.service" ]; then
    (cd "$RUNNER_HOME" && ./svc.sh uninstall)
  fi
  runner_config "$RUNNER_REMOVE_TOKEN" remove
fi
if [ ! -f "$RUNNER_HOME/.runner" ]; then
  # A ${RUNNER_GROUP:+--runnergroup "$RUNNER_GROUP"} expansion would split a
  # group name containing a space into two words; build the argument instead,
  # so the name reaches config.sh as one.
  group_args=()
  if [ -n "$RUNNER_GROUP" ]; then
    group_args+=(--runnergroup "$RUNNER_GROUP")
  fi
  runner_config "$RUNNER_TOKEN" \
    --unattended \
    --url "$RUNNER_URL" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    "${group_args[@]}" \
    --work _work \
    --replace
fi
RUNNER_TOKEN=""
RUNNER_REMOVE_TOKEN=""
if [ ! -f "$RUNNER_HOME/.service" ]; then
  (cd "$RUNNER_HOME" && ./svc.sh install "$RUNNER_USER")
fi
svc_unit="$(cat "$RUNNER_HOME/.service")"

# A runner that fails to come up must fail provisioning: otherwise every CI
# job queues for 24 h behind a script that reported success. "active" only
# means the process started, so a (re)started runner must also log
# "Listening for Jobs", which it does once it has authenticated with GitHub.
# A runner that was already running and untouched is left alone.
if systemctl is-active --quiet "$svc_unit"; then
  echo "provision.sh: ${svc_unit} already running"
else
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  systemctl start "$svc_unit"
  ready=0
  for _ in $(seq 1 60); do
    if journalctl -u "$svc_unit" --since "$since" --no-pager 2>/dev/null | grep -q "Listening for Jobs"; then
      ready=1
      break
    fi
    systemctl is-active --quiet "$svc_unit" || break
    sleep 1
  done
  if [ "$ready" != "1" ] || ! systemctl is-active --quiet "$svc_unit"; then
    journalctl -u "$svc_unit" --since "$since" --no-pager | tail -20 || true
    echo "provision.sh: ${svc_unit} did not reach \"Listening for Jobs\"" >&2
    exit 1
  fi
  echo "provision.sh: ${svc_unit} is listening for jobs"
fi

# ── Cleanup timer ───────────────────────────────────────────────────────────
# Service containers are removed by the runner after each job, but dangling
# layers, build cache and abandoned _work checkouts accumulate. Daily.
#
# The idle check is not a lock: the runner can pick up a job the moment after
# it. So the prune itself must be safe under a starting job:
#   - No `--all`. Tagged images (postgres:16-alpine, redis:7-alpine) are never
#     removed, so a job that just pulled them keeps them. `until` could not
#     protect them: for images it compares the *build* date, which for an
#     upstream image is long past.
#   - `until=24h` still guards what a job creates. For containers and
#     networks it compares creation time, so anything made by a job that is
#     starting now is too new to prune.
# Tagged images left behind by version bumps are few and small; clear them by
# hand (runbook) rather than racing a job for them.
#
# A workspace is removed only if nothing *inside* it changed for 7 days. The
# top-level directory's own mtime moves only when direct entries change, so
# the checkout reused by every job would look stale after a week of daily use.
cat > /usr/local/sbin/homefield-cleanup <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# An empty _work (before the first job) must not iterate the literal glob.
shopt -s nullglob
job_running() { pgrep -f Runner.Worker >/dev/null; }
if job_running; then
  echo "homefield-cleanup: job in progress, skipping"
  exit 0
fi
docker system prune --force --filter "until=24h"
for dir in /opt/actions-runner/_work/*/; do
  case "$(basename "$dir")" in _*) continue ;; esac
  if [ -z "$(find "$dir" -newermt '-7 days' -print -quit)" ]; then
    # Checked again right before deleting: a job may have started since the
    # top of the script, and an idle-for-a-week workspace is exactly the one
    # the first job after a long absence would be using.
    if job_running; then
      echo "homefield-cleanup: job started, leaving $dir"
      exit 0
    fi
    echo "homefield-cleanup: removing idle workspace $dir"
    rm -rf "$dir"
  fi
done
EOF
chmod 755 /usr/local/sbin/homefield-cleanup

cat > /etc/systemd/system/homefield-cleanup.service <<'EOF'
[Unit]
Description=Prune Docker and stale runner workspaces

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homefield-cleanup
EOF

cat > /etc/systemd/system/homefield-cleanup.timer <<'EOF'
[Unit]
Description=Daily CI runner cleanup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ── OS updates ──────────────────────────────────────────────────────────────
# Ubuntu's unattended-upgrades runs at a random time between 06:00 and 07:00
# and restarts whatever it upgrades, plus everything needrestart finds, with
# no regard for the runner. On 2026-09-30 that stopped the runner, containerd
# and Docker in the middle of a job and failed an unrelated snap PR
# (homefield#8). So automatic upgrades are off, and homefield-maintenance
# installs updates instead. It runs only while the runner is idle, and stops
# the runner first, so no job can be caught by a restart during the upgrade.
#
# The idle check and the stop are two steps, so a job the runner picks up in
# the moment between them is cancelled. That window is a fraction of a second.
# The window it replaces was the whole upgrade, roughly three minutes of
# service restarts. The package lists are still refreshed daily, and
# "unattended-upgrades" stays installed but inert, so `apt-config` shows the
# override in effect.
cat > /etc/apt/apt.conf.d/52homefield-no-unattended-upgrade <<'EOF'
// homefield#8: upgrades run from homefield-maintenance.timer, only while idle.
APT::Periodic::Unattended-Upgrade "0";
EOF

cat > /usr/local/sbin/homefield-maintenance <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
unit="$(cat /opt/actions-runner/.service)"
if pgrep -f Runner.Worker >/dev/null; then
  echo "homefield-maintenance: job in progress, skipping until tomorrow"
  exit 0
fi
systemctl stop "$unit"
# Whatever happens below, the runner comes back up.
trap 'systemctl start "$unit"' EXIT
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -q
apt-get upgrade -y -q --with-new-pkgs \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
apt-get autoremove -y -q --purge
# A kernel or libc update asks for a reboot. The runner is still stopped, so
# reboot now rather than start it and give it a job to lose. Its service is
# enabled, so it comes back on boot. A guest reboot keeps the VM running
# under Lima's vz backend (verified with Lima 2.2.0).
if [ -f /var/run/reboot-required ]; then
  echo "homefield-maintenance: rebooting to finish the upgrade"
  trap - EXIT
  systemctl reboot || systemctl start "$unit"
fi
EOF
chmod 755 /usr/local/sbin/homefield-maintenance

cat > /etc/systemd/system/homefield-maintenance.service <<'EOF'
[Unit]
Description=Install OS updates while the CI runner is idle
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homefield-maintenance
EOF

# 07:00 guest time (Lima copies the Mac's time zone): in the deployment this
# came from, none of ~800 PR runs started between 07:00 and 08:00. Change it
# with a drop-in (`systemctl edit homefield-maintenance.timer`: an empty
# `OnCalendar=` first, or the new time adds to this one), which
# re-provisioning leaves alone. The timer is not Persistent: a missed run would
# fire at boot, just as the runner comes online and may pick up a queued job.
cat > /etc/systemd/system/homefield-maintenance.timer <<'EOF'
[Unit]
Description=Daily idle-time OS updates for the CI runner

[Timer]
OnCalendar=*-*-* 07:00

[Install]
WantedBy=timers.target
EOF

# ── Memory sampler ──────────────────────────────────────────────────────────
# One line per minute in /var/log/homefield/memwatch-<date>.csv, taken from
# samples every 2 seconds. sysstat's 10-minute samples miss the short spikes
# (a build, a test run) that decide how small the VM's memory can be set, so
# this keeps the per-minute *peak*. "Used" is MemTotal - MemAvailable: what
# cannot be reclaimed, and so what an out-of-memory kill is about. `job` is 1
# if a job ran at any time in the minute; `oom_kills` is the kernel's
# cumulative counter (it restarts at 0 after a reboot). Files older than 90
# days are deleted. Read it with `bin/homefield memory`.
cat > /usr/local/sbin/homefield-memwatch <<'EOF'
#!/usr/bin/env bash
# The MEMWATCH_* variables exist for tests/memwatch.sh; the service sets none.
set -u
dir="${MEMWATCH_DIR:-/var/log/homefield}"
interval="${MEMWATCH_INTERVAL:-2}"
period="${MEMWATCH_PERIOD:-60}"
meminfo="${MEMWATCH_MEMINFO:-/proc/meminfo}"
vmstat="${MEMWATCH_VMSTAT:-/proc/vmstat}"
job_file="${MEMWATCH_JOB_FILE:-}"
mkdir -p "$dir"
chmod 755 "$dir"

# A job is running if the runner has a worker process. A test points
# MEMWATCH_JOB_FILE at a file instead, because the machine it runs on may
# itself be a runner.
job_running() {
  if [ -n "$job_file" ]; then
    [ -e "$job_file" ]
  else
    pgrep -f Runner.Worker >/dev/null
  fi
}

oom_kills() {
  local key value
  while read -r key value; do
    if [ "$key" = oom_kill ]; then
      echo "$value"
      return
    fi
  done <"$vmstat"
  echo 0
}

now=0
printf -v now '%(%s)T' -1
slot=$((now / period))
n=0 sum=0 max=0 min_avail=-1 job=0 total=0

emit() {
  local file day stamp
  printf -v day '%(%F)T' $((slot * period))
  printf -v stamp '%(%Y-%m-%dT%H:%M:%S%z)T' $((slot * period))
  file="$dir/memwatch-${day}.csv"
  if [ ! -e "$file" ]; then
    echo "ts,samples,total_mib,used_avg_mib,used_max_mib,avail_min_mib,oom_kills,job" >"$file"
    chmod 644 "$file"
    find "$dir" -name 'memwatch-*.csv' -mtime +90 -delete
  fi
  echo "${stamp},${n},$((total / 1024)),$((sum / n / 1024)),$((max / 1024)),$((min_avail / 1024)),$(oom_kills),${job}" >>"$file"
}

while :; do
  {
    read -r _ total _
    read -r _ _ _
    read -r _ avail _
  } <"$meminfo"
  used=$((total - avail))
  n=$((n + 1))
  sum=$((sum + used))
  [ "$used" -gt "$max" ] && max=$used
  if [ "$min_avail" -lt 0 ] || [ "$avail" -lt "$min_avail" ]; then min_avail=$avail; fi
  if job_running; then job=1; fi
  sleep "$interval"
  printf -v now '%(%s)T' -1
  if [ $((now / period)) -ne "$slot" ]; then
    emit
    slot=$((now / period))
    n=0 sum=0 max=0 min_avail=-1 job=0
  fi
done
EOF
chmod 755 /usr/local/sbin/homefield-memwatch

cat > /etc/systemd/system/homefield-memwatch.service <<'EOF'
[Unit]
Description=Per-minute peak memory log for the CI runner

[Service]
ExecStart=/usr/local/sbin/homefield-memwatch
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now homefield-cleanup.timer homefield-maintenance.timer
# restart, not just enable: a re-run may have changed the script, and the
# running copy would keep the old one. Nothing depends on it, so it never
# blocks a job; the minute in progress is lost.
systemctl enable homefield-memwatch.service
systemctl restart homefield-memwatch.service

# Reports the registration as it is, which differs from the settings when an
# existing registration was kept. Labels are not in the runner's config; the
# runners page shows them.
{ read -r reg_name; read -r reg_url; } < <(runner_setting agentName gitHubUrl)
echo "provision.sh: runner ${reg_name} (${RUNNER_VERSION}) registered at ${reg_url}"
