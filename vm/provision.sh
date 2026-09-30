#!/usr/bin/env bash
# Provision the local GitHub Actions runner inside the Lima VM
# (i2Dev-com/i2dev#879).
#
# Runs inside the guest as root. Copy it in and run it; see docs/runbook.md
# for the full sequence:
#
#   limactl copy vm/provision.sh i2dev-ci-runner:/tmp/provision.sh
#   printf 'RUNNER_TOKEN=%s\n' "$TOKEN" |
#     limactl shell i2dev-ci-runner sudo bash /tmp/provision.sh
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
# Scope: registers at the organization by default, so one runner can serve
# every repository its runner group allows (docs/runbook.md, "Runner group").
# Set RUNNER_URL to a repository URL for a runner scoped to one repo.
#
# Moving an existing runner (repo -> org, or to another org): run with
# RUNNER_REREGISTER=1 and both tokens on stdin, RUNNER_REMOVE_TOKEN for its
# current scope and RUNNER_TOKEN for the new one. The old registration is
# removed and the runner registered again under the same name and labels.
set -euo pipefail

RUNNER_VERSION="2.337.0"
RUNNER_SHA256="9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393"
RUNNER_URL="${RUNNER_URL:-https://github.com/i2Dev-com}"
RUNNER_NAME="${RUNNER_NAME:-i2dev-ci-lima}"
# Org registrations join the runner group that limits which repositories may
# use the runner (docs/runbook.md, "Runner group"). Without one the runner
# lands in Default, usable by every repository in the organization. Runner
# groups do not exist for a repository-scoped runner, so none is passed there.
if [[ "$RUNNER_URL" =~ ^https://github\.com/[^/]+/?$ ]]; then
  RUNNER_GROUP="${RUNNER_GROUP:-local-ci}"
else
  RUNNER_GROUP=""
fi
# `i2dev-ci` is the label the workflows route on. The others are GitHub's
# defaults for this platform, repeated so the list is explicit.
RUNNER_LABELS="self-hosted,linux,arm64,i2dev-ci"
RUNNER_USER="runner"
RUNNER_HOME="/opt/actions-runner"

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
registered_url() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8-sig"))["gitHubUrl"])' \
    "$RUNNER_HOME/.runner"
}
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
move=0
if [ "${RUNNER_REREGISTER:-0}" = "1" ] && [ -f "$RUNNER_HOME/.runner" ]; then
  if [ "$(registered_url)" = "${RUNNER_URL%/}" ]; then
    echo "provision.sh: already registered at ${RUNNER_URL}; skipping re-registration"
  else
    move=1
  fi
fi
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
  if [ -n "$svc_unit" ]; then
    systemctl stop "$svc_unit"
  fi
elif [ ! -f "$RUNNER_HOME/.runner" ] && [ -z "$RUNNER_TOKEN" ]; then
  echo "provision.sh: first registration needs RUNNER_TOKEN on stdin" >&2
  exit 1
fi

# ── Packages ────────────────────────────────────────────────────────────────
# What the CI checks job calls that ubuntu-latest has and a minimal Ubuntu does
# not (i2dev#886 inventory). The tests stub aws and dig on PATH, so the AWS CLI
# is deliberately absent. Docker is for job `services:`, and Compose v2 is not
# optional: i2dev's production-log-rotation.test.sh runs a real `docker compose
# config` (Ubuntu's docker.io ships without the plugin, and the first local run
# failed on exactly that). dnsutils is cheap and keeps `dig` as on a hosted
# runner.
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q \
  ca-certificates curl git jq python3 tar zip unzip dnsutils build-essential \
  docker.io docker-compose-v2
systemctl enable --now docker

# ── Runner user ─────────────────────────────────────────────────────────────
# Not the Lima login user, which has passwordless sudo. Docker group membership
# is root-equivalent inside the guest; the VM, not this user, is the boundary.
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$RUNNER_USER"
fi
usermod -aG docker "$RUNNER_USER"

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
  if [ -f "$RUNNER_HOME/.service" ]; then
    (cd "$RUNNER_HOME" && ./svc.sh uninstall)
  fi
  runner_config "$RUNNER_REMOVE_TOKEN" remove
fi
if [ ! -f "$RUNNER_HOME/.runner" ]; then
  runner_config "$RUNNER_TOKEN" \
    --unattended \
    --url "$RUNNER_URL" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    ${RUNNER_GROUP:+--runnergroup "$RUNNER_GROUP"} \
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
cat > /usr/local/sbin/ci-runner-cleanup <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# An empty _work (before the first job) must not iterate the literal glob.
shopt -s nullglob
job_running() { pgrep -f Runner.Worker >/dev/null; }
if job_running; then
  echo "ci-runner-cleanup: job in progress, skipping"
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
      echo "ci-runner-cleanup: job started, leaving $dir"
      exit 0
    fi
    echo "ci-runner-cleanup: removing idle workspace $dir"
    rm -rf "$dir"
  fi
done
EOF
chmod 755 /usr/local/sbin/ci-runner-cleanup

cat > /etc/systemd/system/ci-runner-cleanup.service <<'EOF'
[Unit]
Description=Prune Docker and stale runner workspaces

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ci-runner-cleanup
EOF

cat > /etc/systemd/system/ci-runner-cleanup.timer <<'EOF'
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
# (ci-runner#8). So automatic upgrades are off, and ci-runner-maintenance
# installs updates instead. It runs only while the runner is idle, and stops
# the runner first, so no job can be caught by a restart during the upgrade.
#
# The idle check and the stop are two steps, so a job the runner picks up in
# the moment between them is cancelled. That window is a fraction of a second.
# The window it replaces was the whole upgrade, roughly three minutes of
# service restarts. The package lists are still refreshed daily, and
# "unattended-upgrades" stays installed but inert, so `apt-config` shows the
# override in effect.
cat > /etc/apt/apt.conf.d/52ci-runner-no-unattended-upgrade <<'EOF'
// ci-runner#8: upgrades run from ci-runner-maintenance.timer, only while idle.
APT::Periodic::Unattended-Upgrade "0";
EOF

cat > /usr/local/sbin/ci-runner-maintenance <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
unit="$(cat /opt/actions-runner/.service)"
if pgrep -f Runner.Worker >/dev/null; then
  echo "ci-runner-maintenance: job in progress, skipping until tomorrow"
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
  echo "ci-runner-maintenance: rebooting to finish the upgrade"
  trap - EXIT
  systemctl reboot || systemctl start "$unit"
fi
EOF
chmod 755 /usr/local/sbin/ci-runner-maintenance

cat > /etc/systemd/system/ci-runner-maintenance.service <<'EOF'
[Unit]
Description=Install OS updates while the CI runner is idle
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ci-runner-maintenance
EOF

# 07:00 guest time (Lima copies the Mac's time zone): of the ~800 i2dev and
# snap PR runs up to 2026-09-30, none started between 07:00 and 08:00, and
# 05:00-09:00 held five in all. The timer is not Persistent: a missed run would fire at
# boot, just as the runner comes online and may pick up a queued job.
cat > /etc/systemd/system/ci-runner-maintenance.timer <<'EOF'
[Unit]
Description=Daily idle-time OS updates for the CI runner

[Timer]
OnCalendar=*-*-* 07:00

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ci-runner-cleanup.timer ci-runner-maintenance.timer

# Reports where the runner is actually registered, which differs from
# RUNNER_URL when an existing registration was kept.
echo "provision.sh: runner ${RUNNER_NAME} (${RUNNER_VERSION}) registered at $(registered_url), labels ${RUNNER_LABELS}"
