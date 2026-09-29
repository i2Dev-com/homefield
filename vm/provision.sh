#!/usr/bin/env bash
# Provision the local GitHub Actions runner inside the Lima VM
# (i2Dev-com/i2dev#879).
#
# Runs inside the guest as root. Copy it in and run it; see docs/runbook.md
# for the full sequence:
#
#   limactl copy vm/provision.sh i2dev-ci-runner:/tmp/provision.sh
#   limactl shell i2dev-ci-runner sudo RUNNER_TOKEN=<token> bash /tmp/provision.sh
#
# RUNNER_TOKEN is a one-hour registration token, not a credential the runner
# keeps: config.sh exchanges it for the runner's own identity. Idempotent —
# re-running upgrades packages and skips registration if already registered.
#
# Scope: registers at the organization by default, so one runner can serve
# every repository its runner group allows (docs/runbook.md, "Runner group").
# Set RUNNER_URL to a repository URL for a runner scoped to one repo.
#
# Moving an existing runner (repo -> org, or to another org): run with
# RUNNER_REREGISTER=1 RUNNER_REMOVE_TOKEN=<remove-token for its current scope>
# RUNNER_TOKEN=<registration token for the new scope>. The service is stopped,
# the old registration removed, and the runner registered again under the
# same name and labels.
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

# ── Packages ────────────────────────────────────────────────────────────────
# What the CI checks job calls that ubuntu-latest has and a minimal Ubuntu does
# not (#886 inventory). The tests stub aws and dig on PATH, so the AWS CLI is
# deliberately absent. Docker is for job `services:`, and Compose v2 is not
# optional: production-log-rotation.test.sh runs a real `docker compose config`
# (Ubuntu's docker.io ships without the plugin, and the first local run failed
# on exactly that). dnsutils is cheap and keeps `dig` as on a hosted runner.
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
# An upgrade (RUNNER_VERSION bumped) must stop the service first: extracting
# over a running Runner.Listener fails with ETXTBSY, and even when it doesn't,
# a running service keeps executing the old binary. Stopping it cancels any
# job in progress, so upgrade while idle (runbook).
mkdir -p "$RUNNER_HOME"
svc_unit=""
if [ -f "$RUNNER_HOME/.service" ]; then
  svc_unit="$(cat "$RUNNER_HOME/.service")"
fi
if [ ! -x "$RUNNER_HOME/config.sh" ] || ! grep -qx "$RUNNER_VERSION" "$RUNNER_HOME/.provisioned-version" 2>/dev/null; then
  if [ -n "$svc_unit" ] && systemctl is-active --quiet "$svc_unit"; then
    echo "provision.sh: stopping ${svc_unit} to replace the runner binary"
    systemctl stop "$svc_unit"
  fi
  tarball="/tmp/actions-runner-${RUNNER_VERSION}.tar.gz"
  curl -fsSL -o "$tarball" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz"
  echo "${RUNNER_SHA256}  ${tarball}" | sha256sum -c -
  tar -xzf "$tarball" -C "$RUNNER_HOME"
  rm -f "$tarball"
  "$RUNNER_HOME/bin/installdependencies.sh"
  echo "$RUNNER_VERSION" > "$RUNNER_HOME/.provisioned-version"
fi
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"

# ── Registration + service ──────────────────────────────────────────────────
if [ "${RUNNER_REREGISTER:-0}" = "1" ] && [ -f "$RUNNER_HOME/.runner" ]; then
  : "${RUNNER_REMOVE_TOKEN:?RUNNER_REMOVE_TOKEN is required to re-register}"
  : "${RUNNER_TOKEN:?RUNNER_TOKEN is required to re-register}"
  if [ -f "$RUNNER_HOME/.service" ]; then
    (cd "$RUNNER_HOME" && ./svc.sh stop && ./svc.sh uninstall)
  fi
  sudo -u "$RUNNER_USER" "$RUNNER_HOME/config.sh" remove --token "$RUNNER_REMOVE_TOKEN"
fi
if [ ! -f "$RUNNER_HOME/.runner" ]; then
  : "${RUNNER_TOKEN:?RUNNER_TOKEN is required for first registration}"
  sudo -u "$RUNNER_USER" "$RUNNER_HOME/config.sh" \
    --unattended \
    --url "$RUNNER_URL" \
    --token "$RUNNER_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    ${RUNNER_GROUP:+--runnergroup "$RUNNER_GROUP"} \
    --work _work \
    --replace
fi
if [ ! -f "$RUNNER_HOME/.service" ]; then
  (cd "$RUNNER_HOME" && ./svc.sh install "$RUNNER_USER")
fi
svc_unit="$(cat "$RUNNER_HOME/.service")"
# `systemctl start` is a no-op on an active unit, so this is safe on re-runs.
# A runner that fails to come up must fail provisioning: otherwise every CI
# job queues for 24 h behind a script that reported success.
systemctl start "$svc_unit"
sleep 3
if ! systemctl is-active --quiet "$svc_unit"; then
  systemctl status "$svc_unit" --no-pager || true
  echo "provision.sh: ${svc_unit} is not running" >&2
  exit 1
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

systemctl daemon-reload
systemctl enable --now ci-runner-cleanup.timer

echo "provision.sh: runner ${RUNNER_NAME} (${RUNNER_VERSION}) provisioned with labels ${RUNNER_LABELS} at ${RUNNER_URL}${RUNNER_GROUP:+ in group ${RUNNER_GROUP}}"
