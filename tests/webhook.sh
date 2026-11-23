#!/usr/bin/env bash
# tests/webhook.sh — the webhook receiver (#309): the receiver's signature
# verification, event/action filtering and doorbell into the scaler (a stub
# homefield records the ticks it spawns), and the setup/connect/status/
# remove commands against stubbed cloudflared, gh and launchctl.
#
# Run:  bash tests/webhook.sh
# Exit: 0 when every case passes, 1 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$TMP/bin" "$TMP/app/bin" "$HOME/.cloudflared"
export PATH="$TMP/bin:$PATH"

calls_homefield="$TMP/calls-homefield"
calls_launchctl="$TMP/calls-launchctl"
calls_cloudflared="$TMP/calls-cloudflared"
calls_gh="$TMP/calls-gh"
: > "$calls_homefield"
: > "$calls_launchctl"
: > "$calls_cloudflared"
: > "$calls_gh"
export CALLS_HOMEFIELD="$calls_homefield"
export CALLS_LAUNCHCTL="$calls_launchctl"
export CALLS_CLOUDFLARED="$calls_cloudflared"
export CALLS_GH="$calls_gh"

# ---------------------------------------------------------------------------
# Part 1 — the receiver: signed deliveries against a live receiver on a
# loopback port, with a stub homefield recording the ticks it spawns.

RECEIVER_DIR="$TMP/state/route-watcher/webhook"
mkdir -p "$RECEIVER_DIR"
SECRET_FILE="$RECEIVER_DIR/secret"
python3 -c 'import secrets; print(secrets.token_hex(32))' >"$SECRET_FILE"
chmod 600 "$SECRET_FILE"

cp "$ROOT/bin/webhook-receiver.py" "$TMP/app/bin/"
cat > "$TMP/app/bin/homefield" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALLS_HOMEFIELD:?}"
exit 0
EOF
chmod +x "$TMP/app/bin/homefield"

cat > "$TMP/bin/cloudflared" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALLS_CLOUDFLARED:?}"
case "$*" in
  "tunnel list --output json")
    if [ "${CF_CREATE_THEN_LIST:-}" = 1 ] && [ ! -f "${CF_MARKER:?}" ]; then
      printf '%s' "[]"
    else
      json="${CF_LIST_JSON:-}"
      [ -n "$json" ] || json='[{"id": "tunnel-uuid", "name": "homefield-webhook"}]'
      printf '%s' "$json"
    fi ;;
  "tunnel create"*)
    [ "${CF_CREATE_FAIL:-}" = 1 ] && exit 1
    : > "${CF_MARKER:?}"
    echo "created tunnel homefield-webhook" ;;
  "tunnel route dns"*)
    if [ "${CF_ROUTE_FAIL:-}" = 1 ]; then
      printf '%s\n' "${CF_ROUTE_ERR:-cloudflared: boom}" >&2
      exit 1
    fi
    echo "route added" ;;
  "tunnel cleanup"*) : ;;
  "tunnel delete"*)
    [ "${CF_DELETE_FAIL:-}" = 1 ] && exit 1
    : ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/cloudflared"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
HOMEFIELD_STATE_DIR="$TMP/state" HOMEFIELD_WEBHOOK_PORT="$PORT" \
  python3 "$TMP/app/bin/webhook-receiver.py" 2>"$TMP/receiver.err" &
RECEIVER_PID=$!

ready=no
for _ in $(seq 1 50); do
  if python3 -c "import socket; s=socket.socket(); s.connect(('127.0.0.1',$PORT)); s.close()" 2>/dev/null; then
    ready=yes
    break
  fi
  sleep 0.1
done
record "receiver: started and answers on the loopback port" "yes" "$ready"

# post <event> <action> [sigmode]: one signed delivery; prints the status.
post() {
  python3 - "$PORT" "$SECRET_FILE" "$1" "$2" "${3:-good}" <<'PY'
import hashlib, hmac, http.client, json, sys
port, secret_file, event, action, mode = sys.argv[1:6]
try:
    secret = open(secret_file, "rb").read().strip()
except OSError:
    secret = b"unsigned"
body = json.dumps({"action": action, "workflow_job": {"id": 1},
                   "repository": {"full_name": "o/r"}}).encode()
sig = "sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest()
if mode == "bad":
    sig = "sha256=0000"
elif mode == "missing":
    sig = None
c = http.client.HTTPConnection("127.0.0.1", int(port))
h = {"Content-Type": "application/json", "X-GitHub-Event": event}
if sig:
    h["X-Hub-Signature-256"] = sig
c.request("POST", "/webhook", body=body, headers=h)
r = c.getresponse()
r.read()
print(r.status)
PY
}

# get <path>: a plain GET; prints the status.
get() {
  python3 - "$PORT" "$1" <<'PY'
import http.client, sys
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
c.request("GET", sys.argv[2])
r = c.getresponse()
r.read()
print(r.status)
PY
}

# raw <request>: one hand-rolled request; prints the status line's code.
raw() {
  python3 - "$PORT" "$2" <<'PY'
import socket, sys
s = socket.socket()
s.connect(("127.0.0.1", int(sys.argv[1])))
s.sendall(sys.argv[2].encode())
print(s.recv(4096).decode(errors="replace").split()[1])
PY
}

ticks() { grep -c -e 'fleet watch --max-ticks 1' "$calls_homefield" || true; }

# await_ticks <n>: the receiver's 204 returns as soon as the tick child is
# forked, while the stub's append lands a moment later — wait for it.
await_ticks() {
  local want="$1" got=0
  for _ in $(seq 1 100); do
    got="$(ticks)"
    [ "$got" -ge "$want" ] && break
    sleep 0.05
  done
  printf '%s' "$got"
}

record "healthz: answers 200" "200" "$(get /healthz)"
record "healthz: other paths are 404" "404" "$(get /nope)"

out="$(post workflow_job queued)"
record "queued delivery: accepted" "204" "$out"
record "queued delivery: spawned exactly one tick" "1" "$(await_ticks 1)"

out="$(post workflow_job queued)"
record "burst: the second delivery is debounced" "202" "$out"
record "burst: still one tick" "1" "$(ticks)"

out="$(post workflow_job queued bad)"
record "bad signature: 403" "403" "$out"
record "bad signature: no tick" "1" "$(ticks)"

out="$(post workflow_job queued missing)"
record "missing signature: 403" "403" "$out"
record "missing signature: no tick" "1" "$(ticks)"

out="$(post ping ignored)"
record "ping event: accepted, ignored" "204" "$out"
record "ping event: no tick" "1" "$(ticks)"

out="$(post workflow_job created)"
record "workflow_job action outside the set: ignored" "204" "$out"
record "workflow_job action outside the set: no tick" "1" "$(ticks)"

rm -f "$RECEIVER_DIR/tick.pid"
out="$(post workflow_job completed)"
record "completed action: rings the doorbell" "204" "$out"
record "completed action: second tick" "2" "$(await_ticks 2)"

python3 -c 'import time; time.sleep(300)' 2>/dev/null &
sleep_pid=$!
printf '%s\n' "$sleep_pid" >"$RECEIVER_DIR/tick.pid"
out="$(post workflow_job queued)"
record "tick already running: 202, no new spawn" "202/2" "$out/$(ticks)"
kill "$sleep_pid" 2>/dev/null || true

out="$(raw $PORT $'POST /webhook HTTP/1.1\r\nHost: x\r\nContent-Length: 1048577\r\n\r\n')" # 1 MiB + 1 of a
record "oversized Content-Length: 413 before anything else" "413" "$out"

mv "$SECRET_FILE" "$TMP/secret.away"
out="$(post workflow_job queued missing)"
record "no secret on disk: 503, no tick" "503/2" "$out/$(ticks)"
mv "$TMP/secret.away" "$SECRET_FILE"

out="$(raw $PORT $'POST /webhook HTTP/1.1\r\nHost: x\r\n\r\n')"
record "missing Content-Length: 411" "411" "$out"

kill "$RECEIVER_PID" 2>/dev/null || true
wait "$RECEIVER_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Part 2 — the commands, against stubbed cloudflared/gh/launchctl.

cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALLS_LAUNCHCTL:?}"
case "${1-}" in
  list) printf -- '-\t0\tcom.homefield.route-watcher\n-\t0\tcom.homefield.webhook\n' ;;
esac
exit 0
EOF

# gh: hooks list from GH_HOOKS_JSON (the --jq is applied with the real jq,
# the way gh does); a --input create is recorded with its body file copied
# to GH_BODY_OUT, printing the new hook id.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALLS_GH:?}"
expr=""
prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && expr="$a"
  prev="$a"
done
case "$*" in
  *"repos/"*"/hooks"*)
    case "$*" in
      *--input*)
        body=""
        prev=""
        for a in "$@"; do
          [ "$prev" = "--input" ] && body="$a"
          prev="$a"
        done
        [ -n "$body" ] && cp "$body" "${GH_BODY_OUT:?}"
        printf '%s' "4242" ;;
      *) printf '%s' "${GH_HOOKS_JSON:-[]}" | jq -r "${expr:-.}" 2>/dev/null ;;
    esac ;;
esac
exit 0
EOF

chmod +x "$TMP/bin/launchctl" "$TMP/bin/cloudflared" "$TMP/bin/gh"

STATE2="$TMP/state2"
export CF_MARKER="$TMP/marker"

# run <state> <args...>: the command under test in a child bash. The test
# shell never sources bin/homefield (it arms errexit when sourced, which
# would end the suite on the first die under test); the child sources it
# fresh, and a die ends only the child.
run() {
  local state="$1"
  shift
  env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" HOMEFIELD_SOURCE_ONLY=1 \
    HOMEFIELD_STATE_DIR="$state" CF_MARKER="$CF_MARKER" \
    CALLS_HOMEFIELD="$calls_homefield" CALLS_LAUNCHCTL="$calls_launchctl" \
    CALLS_CLOUDFLARED="$calls_cloudflared" CALLS_GH="$calls_gh" \
    CF_LIST_JSON="${CF_LIST_JSON:-}" CF_CREATE_THEN_LIST="${CF_CREATE_THEN_LIST:-}" \
    CF_CREATE_FAIL="${CF_CREATE_FAIL:-}" CF_ROUTE_FAIL="${CF_ROUTE_FAIL:-}" \
    CF_ROUTE_ERR="${CF_ROUTE_ERR:-}" CF_DELETE_FAIL="${CF_DELETE_FAIL:-}" \
    GH_HOOKS_JSON="${GH_HOOKS_JSON:-}" GH_BODY_OUT="${GH_BODY_OUT:-}" \
    "$BASH" -c '. "$1"; shift; "$@"' _ "$ROOT/bin/homefield" cmd_webhook "$@" 2>&1 </dev/null
}

out="$(run "$STATE2" setup)"
rc=$?
record "setup: without --hostname is refused" "nonzero" "$(nonzero $rc)"
case "$out" in *"--hostname"*) r=yes ;; *) r=no ;; esac
record "setup: the refusal names --hostname" "yes" "$r"

out="$(run "$STATE2" setup --hostname 'bad hostname' --port 18787)"
record "setup: a hostname with spaces is refused" "nonzero" "$(nonzero $?)"
out="$(run "$STATE2" setup --hostname 'localhost' --port 18787)"
record "setup: a dotless hostname is refused" "nonzero" "$(nonzero $?)"

# no cloudflared login yet (the fresh HOME has none)
out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787)"
rc=$?
record "setup: no cloudflared login is refused" "nonzero" "$(nonzero $rc)"
case "$out" in *"tunnel login"*) r=yes ;; *) r=no ;; esac
record "setup: the refusal names the login" "yes" "$r"
: > "$HOME/.cloudflared/cert.pem"
: > "$HOME/.cloudflared/tunnel-uuid.json"

# a port that is already in use
BUSY_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 -c "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',$BUSY_PORT)); s.listen(1); time.sleep(60)" 2>/dev/null &
busy_pid=$!
out="$(run "$STATE2" setup --hostname webhook.example.com --port "$BUSY_PORT")"
record "setup: an occupied port is refused" "nonzero" "$(nonzero $?)"
kill "$busy_pid" 2>/dev/null || true

out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787)"
rc=$?
record "setup: happy path exits 0" "0" "$rc"
plist="$HOME/Library/LaunchAgents/com.homefield.webhook.plist"
record "setup: the plist is written" "yes" "$(has "$(cat "$plist" 2>/dev/null)" 'com.homefield.webhook')"
record "setup: the port is baked into the plist" "yes" "$(has "$(cat "$plist" 2>/dev/null)" '18787')"
record "setup: launchctl load recorded" "1" "$(grep -c -e '^load -w' "$calls_launchctl" || true)"
record "setup: the tunnel was already listed, so no create" "0" "$(grep -c -e 'tunnel create' "$calls_cloudflared" || true)"
record "setup: the DNS route is added" "1" "$(grep -c -e 'tunnel route dns' "$calls_cloudflared" || true)"
record "setup: the secret is 0600" "600" "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$STATE2/route-watcher/webhook/secret")"
record "setup: the config records hostname, port, tunnel" "webhook.example.com/18787/homefield-webhook" \
  "$(grep -h '^hostname=' "$STATE2/route-watcher/webhook/config" | cut -d= -f2)/$(grep -h '^port=' "$STATE2/route-watcher/webhook/config" | cut -d= -f2)/$(grep -h '^tunnel=' "$STATE2/route-watcher/webhook/config" | cut -d= -f2)"
record "setup: prints the public URL" "yes" "$(has "$out" 'https://webhook.example.com/webhook')"

# re-run: the route step's "already exists" failure is not an error
# shellcheck disable=SC2034  # read by the cloudflared stub in the subshell
CF_ROUTE_FAIL=1 CF_ROUTE_ERR="record already exists"
out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787)"
record "setup: an existing DNS record is not an error" "0" "$?"
# shellcheck disable=SC2034  # read by the cloudflared stub in the subshell
CF_ROUTE_ERR="cloudflared: zone not found"
out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787)"
rc=$?
record "setup: a real route failure is fatal" "nonzero" "$(nonzero $rc)"
case "$out" in *"zone not found"*) r=yes ;; *) r=no ;; esac
record "setup: the route failure is shown" "yes" "$r"
unset CF_ROUTE_FAIL CF_ROUTE_ERR

# a tunnel that does not exist yet is created (the marker records that the
# tunnel exists, so it must be absent for the create path to run)
rm -rf "$STATE2"
rm -f "$CF_MARKER"
# shellcheck disable=SC2034  # read by the cloudflared stub in the subshell
CF_CREATE_THEN_LIST=1
out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787)"
rc=$?
record "setup: a missing tunnel is created" "1" "$(grep -c -e 'tunnel create' "$calls_cloudflared" || true)"
record "setup: created tunnel still exits 0" "0" "$rc"
unset CF_CREATE_THEN_LIST

# connect
# shellcheck disable=SC2034  # read by the gh stub in the subshell
GH_BODY_OUT="$TMP/body.json"
# shellcheck disable=SC2034  # read by the gh stub in the subshell
GH_HOOKS_JSON="[]"
out="$(run "$STATE2" connect o/r)"
rc=$?
record "connect: exits 0" "0" "$rc"
record "connect: the list and the create both hit the repo" "2" "$(grep -c -e 'repos/o/r/hooks' "$calls_gh" || true)"
record "connect: the body carries the secret" "yes" "$(has "$(cat "$TMP/body.json" 2>/dev/null)" "$(cat "$STATE2/route-watcher/webhook/secret")")"
record "connect: the body subscribes workflow_job" "yes" "$(has "$(cat "$TMP/body.json" 2>/dev/null)" '"workflow_job"')"
record "connect: the body carries the public URL" "yes" "$(has "$(cat "$TMP/body.json" 2>/dev/null)" 'https://webhook.example.com/webhook')"
record "connect: the secret never appears on a command line" "0" "$(grep -c -e "$(cat "$STATE2/route-watcher/webhook/secret")" "$calls_gh" || true)"
record "connect: prints the hook id" "yes" "$(has "$out" '4242')"
record "connect: the body file is removed" "0" "$(ls "$STATE2/route-watcher/webhook/connect-body.json" 2>/dev/null | wc -l | tr -d ' ')"

# shellcheck disable=SC2034  # read by the gh stub in the subshell
GH_HOOKS_JSON='[{"id": 7, "config": {"url": "https://webhook.example.com/webhook"}}]'
out="$(run "$STATE2" connect o/r)"
rc=$?
record "connect: already connected exits 0" "0" "$rc"
case "$out" in *"already connected"*) r=yes ;; *) r=no ;; esac
record "connect: already connected is reported" "yes" "$r"
record "connect: already connected does not create" "3" "$(grep -c -e 'repos/o/r/hooks' "$calls_gh" || true)"

out="$(run "$TMP/state3" connect o/r)"
record "connect: without setup is refused" "nonzero" "$(nonzero $?)"
unset GH_HOOKS_JSON GH_BODY_OUT

# status: the agent is loaded (the stub lists it), the receiver is not up
out="$(run "$STATE2" status)"
rc=$?
record "status: reports the loaded agent" "yes" "$(has "$out" 'agent: loaded')"
record "status: reports the URL" "yes" "$(has "$out" 'https://webhook.example.com/webhook')"
record "status: the secret is present" "yes" "$(has "$out" 'secret: present')"
record "status: the tunnel is listed" "yes" "$(has "$out" 'tunnel-uuid')"
record "status: the quiet receiver is reported" "yes" "$(has "$out" 'receiver: not answering')"
record "status: the quiet receiver fails the status" "nonzero" "$(nonzero $rc)"

python3 -c "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',18787)); s.listen(1); time.sleep(60)" 2>/dev/null &
listen_pid=$!
out="$(run "$STATE2" status)"
rc=$?
record "status: a listening receiver passes" "yes/0" "$(has "$out" 'receiver: listening on 127.0.0.1:18787')/$(nonzero $rc)"
kill "$listen_pid" 2>/dev/null || true

# remove
unloads_before="$(grep -c -e '^unload -w' "$calls_launchctl" || true)"
out="$(run "$STATE2" remove)"
rc=$?
record "remove: exits 0" "0" "$rc"
record "remove: launchctl unload recorded" "1" \
  "$(( $(grep -c -e '^unload -w' "$calls_launchctl" || true) - unloads_before ))"
record "remove: the plist is gone" "0" "$(ls "$plist" 2>/dev/null | wc -l | tr -d ' ')"
record "remove: the secret is gone" "0" "$(ls "$STATE2/route-watcher/webhook/secret" 2>/dev/null | wc -l | tr -d ' ')"
record "remove: the tunnel is kept without --purge" "0" "$(grep -c -e 'tunnel delete' "$calls_cloudflared" || true)"

# rebuild the state, then purge
run "$STATE2" setup --hostname webhook.example.com --port 18787 >/dev/null
out="$(run "$STATE2" remove --purge)"
rc=$?
record "remove --purge: exits 0" "0" "$rc"
record "remove --purge: the tunnel is deleted" "1" "$(grep -c -e 'tunnel delete' "$calls_cloudflared" || true)"
record "remove --purge: the tunnel is cleaned up first" "1" "$(grep -c -e 'tunnel cleanup' "$calls_cloudflared" || true)"

summary