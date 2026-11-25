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
if [ -n "${CALLS_SLEEP_FLAG:-}" ] && [ -f "$CALLS_SLEEP_FLAG" ]; then
  sleep "$(cat "$CALLS_SLEEP_FLAG")"
fi
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
    case "$*" in
      # the overwrite retry always succeeds: it is the operator's explicit
      # --overwrite-dns, and the plain route's conflict is what fails
      *--overwrite-dns*) echo "route replaced" ;;
      *)
        if [ "${CF_ROUTE_FAIL:-}" = 1 ]; then
          printf '%s\n' "${CF_ROUTE_ERR:-cloudflared: boom}" >&2
          exit 1
        fi
        echo "route added" ;;
    esac ;;
  "tunnel cleanup"*) : ;;
  "tunnel delete"*)
    [ "${CF_DELETE_FAIL:-}" = 1 ] && exit 1
    : ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/cloudflared"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
# The tick budget is 5 s — comfortably longer than a stub spawn takes even
# under the pool's load (a shorter budget has the receiver kill healthy
# ticks before they record their call) — and the hung-tick stub below sleeps
# far past it, so the budget is what ends it. The read deadline and the
# connection cap are small so the slowloris tests below run in seconds.
HOMEFIELD_STATE_DIR="$TMP/state" HOMEFIELD_WEBHOOK_PORT="$PORT" HOMEFIELD_SCALE_TICK_BUDGET=5 \
  HOMEFIELD_WEBHOOK_DEBOUNCE=10 HOMEFIELD_WEBHOOK_READ_TIMEOUT=2 HOMEFIELD_WEBHOOK_MAX_CONNECTIONS=4 \
  CALLS_SLEEP_FLAG="$TMP/stub-sleep" \
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

# post_raw <body> [event]: one signed delivery with an arbitrary body;
# prints the status. The payload-shape tests below use it: GitHub's
# payloads are objects, but the endpoint is reachable from the internet.
post_raw() {
  python3 - "$PORT" "$SECRET_FILE" "$1" "${2:-workflow_job}" <<'PY'
import hashlib, hmac, http.client, sys
port, secret_file, body, event = sys.argv[1:5]
secret = open(secret_file, "rb").read().strip()
sig = "sha256=" + hmac.new(secret, body.encode(), hashlib.sha256).hexdigest()
c = http.client.HTTPConnection("127.0.0.1", int(port))
c.request("POST", "/webhook", body=body.encode(),
          headers={"Content-Type": "application/json", "X-GitHub-Event": event,
                   "X-Hub-Signature-256": sig})
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
# forked, while the stub's append lands a moment later — wait for it. The
# budget is generous because the suite also runs under the pool's load.
await_ticks() {
  local want="$1" got=0
  for _ in $(seq 1 400); do
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

# an exited tick child is reaped, not left a zombie that kill -0 still
# sees as alive: after the debounce, a fresh delivery spawns again
sleep 10.1
out="$(post workflow_job queued)"
record "exited tick reaped: a later delivery spawns again" "204" "$out"
record "exited tick reaped: third tick" "3" "$(await_ticks 3)"

# a hung tick is killed at the same wall-time budget the route watcher
# applies to its own ticks — it must not hold the scaler's lock forever.
# The sleep flag is a file because the stub runs as the receiver's child:
# only what the receiver's environment carried at startup reaches it.
printf '60\n' >"$TMP/stub-sleep"
rm -f "$RECEIVER_DIR/tick.pid"
out="$(post workflow_job queued)"
record "hung tick: delivery accepted" "204" "$out"
tick_pid="$(cat "$RECEIVER_DIR/tick.pid")"
kill -0 "$tick_pid" 2>/dev/null && r=yes || r=no
record "hung tick: running right after the spawn" "yes" "$r"
alive=yes
for _ in $(seq 1 200); do
  if ! kill -0 "$tick_pid" 2>/dev/null; then
    alive=no
    break
  fi
  sleep 0.1
done
record "hung tick: killed at the 5s budget" "no" "$alive"
rm -f "$TMP/stub-sleep"
# the hung tick's call is logged forever, so the remaining spawn counts are
# relative to it
ticks_base="$(ticks)"

# a tick recorded as already running suppresses a spawn: the recorded pid
# is a real `homefield fleet watch` run (the identity the pid-file fallback
# validates), held by the sleep flag
printf '60\n' >"$TMP/stub-sleep"
fake_tick_pid="$(CALLS_SLEEP_FLAG="$TMP/stub-sleep" python3 - "$TMP/app/bin/homefield" <<'PY'
import subprocess, sys
print(subprocess.Popen([sys.argv[1], "fleet", "watch", "--max-ticks", "1"],
                       start_new_session=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid)
PY
)"
printf '%s\n' "$fake_tick_pid" >"$RECEIVER_DIR/tick.pid"
out="$(post workflow_job queued)"
record "tick already running: 202, no new spawn" "202/1" "$out/$(($(ticks) - ticks_base))"
kill "$fake_tick_pid" 2>/dev/null || true
wait "$fake_tick_pid" 2>/dev/null
rm -f "$TMP/stub-sleep"

# a pid file naming an unrelated live process (a restart or a reboot left
# it behind and the pid was recycled) is not a running tick: the delivery
# spawns instead of 202ing forever
python3 -c 'import time; time.sleep(300)' 2>/dev/null &
stale_pid=$!
printf '%s\n' "$stale_pid" >"$RECEIVER_DIR/tick.pid"
out="$(post workflow_job queued)"
record "stale pid: an unrelated live process is not a tick" "204/2" \
  "$out/$(($(ticks) - ticks_base))"
kill "$stale_pid" 2>/dev/null || true
wait "$stale_pid" 2>/dev/null
# the stale-pid delivery spawned a tick whose call is logged forever, so
# the remaining spawn counts are relative to it again
ticks_base="$(ticks)"

# a payload that is not a JSON object must be rejected with a generic 400,
# not crash the handler into a dropped connection
out="$(post_raw '[]')"
record "a JSON array payload is rejected, not dropped" "400" "$out"
out="$(post_raw 'null')"
record "a JSON null payload is rejected, not dropped" "400" "$out"
out="$(post_raw '{"action": ["queued"]}')"
record "an unhashable action is ignored, not crashed" "204" "$out"
out="$(post_raw '{"repository": "o/r"}')"
record "a missing action rings nothing" "204" "$out"

# a non-dict repository must not raise AttributeError on the way to the
# doorbell (the receiver logs no payload field, so there is nothing to trip)
rm -f "$RECEIVER_DIR/tick.pid"
out="$(post_raw '{"action": "queued", "repository": "o/r"}')"
record "a non-dict repository still rings the doorbell" "204" "$out"
want=$((ticks_base + 1))
record "a non-dict repository: one tick" "$want" "$(await_ticks "$want")"
ticks_base="$(ticks)"

out="$(raw $PORT $'POST /webhook HTTP/1.1\r\nHost: x\r\nContent-Length: 1048577\r\n\r\n')" # 1 MiB + 1 of a
record "oversized Content-Length: 413 before anything else" "413" "$out"

mv "$SECRET_FILE" "$TMP/secret.away"
out="$(post workflow_job queued missing)"
record "no secret on disk: 503, no tick" "503/0" "$out/$(($(ticks) - ticks_base))"
mv "$TMP/secret.away" "$SECRET_FILE"

out="$(raw $PORT $'POST /webhook HTTP/1.1\r\nHost: x\r\n\r\n')"
record "missing Content-Length: 411" "411" "$out"

# keep-alive desync: a response sent before the body is read (404, 411,
# 413) must close the connection, or the unread body bytes sit in the
# stream and are parsed as the next request on it
python3 - "$PORT" >"$TMP/desync404.txt" 2>&1 <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(b"POST /nope HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
          b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
print(s.recv(4096).decode(errors="replace").split()[1])
s.settimeout(3)
try:
    more = s.recv(4096)
    print("closed" if more == b"" else "kept-alive")
except socket.timeout:
    print("kept-alive")
except OSError:
    # the server tore the connection down with our pipelined request
    # unread: a reset is the close, same as a clean one
    print("closed")
PY
record "framing: a 404 POST with an unread body is refused" "404" "$(head -1 "$TMP/desync404.txt")"
record "framing: the unread body is not parsed as the next request" "closed" "$(sed -n 2p "$TMP/desync404.txt")"

python3 - "$PORT" >"$TMP/desync413.txt" 2>&1 <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(b"POST /webhook HTTP/1.1\r\nHost: x\r\nContent-Length: 1048577\r\n\r\n"
          b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
print(s.recv(4096).decode(errors="replace").split()[1])
s.settimeout(3)
try:
    more = s.recv(4096)
    print("closed" if more == b"" else "kept-alive")
except socket.timeout:
    print("kept-alive")
except OSError:
    print("closed")
PY
record "framing: a 413 POST with an unread body is refused" "413" "$(head -1 "$TMP/desync413.txt")"
record "framing: the oversized body is not parsed as the next request" "closed" "$(sed -n 2p "$TMP/desync413.txt")"

# a truncated body (the peer hangs up mid-body) is a 400, not a signature
# failure over whatever arrived: the read must reject short reads
python3 - "$PORT" >"$TMP/trunc.txt" 2>&1 <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(b"POST /webhook HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nshort")
s.shutdown(socket.SHUT_WR)
data = s.recv(4096)
print(data.decode(errors="replace").split()[1] if data else "none")
PY
record "a truncated body is rejected, not signature-checked" "400" "$(cat "$TMP/trunc.txt")"

# an env count that is not above zero must not crash the helper at import
# (a negative BoundedSemaphore raises ValueError; a zero one would refuse
# every connection) and the reaped-pid record must stay bounded over a
# daemon's lifetime
out="$(HOMEFIELD_WEBHOOK_MAX_CONNECTIONS=0 python3 - "$ROOT/bin/webhook-receiver.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wr", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
assert m.MAX_CONNECTIONS == 32, m.MAX_CONNECTIONS
for i in range(300):
    m.reaped_pids.append(i)
assert len(m.reaped_pids) == 256, len(m.reaped_pids)
print("ok")
PY
)"
record "a max-connections of 0 starts with the default, reaped pids bounded" "ok" "$out"

# an unauthenticated peer can declare a Content-Length and never send the
# body: the read deadline closes the connection instead of holding a thread
# forever, and the receiver stays healthy afterwards
python3 - "$PORT" >"$TMP/slowloris.txt" 2>&1 <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(b"POST /webhook HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n")
s.settimeout(6)
try:
    data = s.recv(1024)
    print("closed" if data == b"" else "responded")
except socket.timeout:
    print("held")
PY
case "$(cat "$TMP/slowloris.txt")" in
  closed) r=yes ;; *) r=no ;;
esac
record "slowloris: an incomplete body is closed at the read deadline" "yes" "$r"
record "slowloris: the receiver stays healthy" "200" "$(get /healthz)"

# the connection cap bounds what a peer that only opens connections can
# make the server hold: excess connections are closed before a thread is
# spent on them, and the receiver recovers once they go away
python3 - "$PORT" >"$TMP/cap.txt" 2>&1 <<'PY'
import socket, sys
port = int(sys.argv[1])
holders = []
for _ in range(4):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.sendall(b"POST /webhook HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n")
    holders.append(s)
extra = socket.create_connection(("127.0.0.1", port), timeout=5)
extra.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
extra.settimeout(3)
try:
    data = extra.recv(1024)
    print("closed" if data == b"" else "served")
except socket.timeout:
    print("held")
except OSError:
    # the server tore the connection down with our request unread: a reset
    # is the cap refusing the connection, same as a clean close
    print("closed")
for s in holders:
    s.close()
extra.close()
PY
case "$(cat "$TMP/cap.txt")" in
  closed) r=yes ;; *) r=no ;;
esac
record "slowloris: a connection past the cap is closed, not threaded" "yes" "$r"
record "slowloris: the receiver recovers after the holders go away" "200" "$(get /healthz)"

# shutdown: a running tick does not outlive the receiver — it was started
# in a session of its own and its budget supervisor is a daemon thread, so
# a hung tick would hold the scaler's lock forever after a restart
printf '60\n' >"$TMP/stub-sleep"
rm -f "$RECEIVER_DIR/tick.pid"
out="$(post workflow_job queued)"
record "shutdown: a delivery with a hung tick is accepted" "204" "$out"
tick_pid="$(cat "$RECEIVER_DIR/tick.pid")"
kill -0 "$tick_pid" 2>/dev/null && r=yes || r=no
record "shutdown: the tick is running" "yes" "$r"
kill -TERM "$RECEIVER_PID" 2>/dev/null || true
tick_gone=no
for _ in $(seq 1 100); do
  kill -0 "$tick_pid" 2>/dev/null || tick_gone=yes
  [ "$tick_gone" = yes ] && break
  sleep 0.1
done
record "shutdown: the hung tick is killed with the receiver" "yes" "$tick_gone"
# the receiver exits after reaping the tick (its kill_tree waits up to 5 s
# per tick); a watchdog bounds the wait so a hung exit fails the record
# instead of hanging the suite
( sleep 15; kill -9 "$RECEIVER_PID" 2>/dev/null ) & watchdog_pid=$!
wait "$RECEIVER_PID"; rc=$?
kill "$watchdog_pid" 2>/dev/null
record "shutdown: the receiver exits cleanly" "0" "$rc"
rm -f "$TMP/stub-sleep"

# the tunnel supervisor must not spawn a cloudflared after SIGTERM: the
# backoff sleeps are interruptible by the shutdown event, and a spawn
# that raced the shutdown is killed instead of orphaned. A stub
# cloudflared that exits after 0.3 s puts the supervisor into its 5 s
# backoff before the SIGTERM lands.
ORPHAN_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
mkdir -p "$TMP/cfbin"
cat > "$TMP/cfbin/cloudflared" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "${CF_ORPHAN_PIDS:?}"
sleep 0.3
EOF
chmod +x "$TMP/cfbin/cloudflared"
CF_ORPHAN_PIDS="$TMP/cf-orphan-pids"
: > "$CF_ORPHAN_PIDS"
HOMEFIELD_STATE_DIR="$TMP/orphan-state" HOMEFIELD_WEBHOOK_PORT="$ORPHAN_PORT" \
  PATH="$TMP/cfbin:$PATH" CF_ORPHAN_PIDS="$CF_ORPHAN_PIDS" \
  python3 "$ROOT/bin/webhook-receiver.py" 2>"$TMP/orphan.err" &
ORPHAN_PID=$!
orphan_started=no
for _ in $(seq 1 50); do
  [ -s "$CF_ORPHAN_PIDS" ] && { orphan_started=yes; break; }
  sleep 0.1
done
record "shutdown: the tunnel child is spawned" "yes" "$orphan_started"
sleep 0.5  # the child (0.3 s) has exited; the supervisor is in its backoff
kill -TERM "$ORPHAN_PID" 2>/dev/null || true
( sleep 15; kill -9 "$ORPHAN_PID" 2>/dev/null ) & watchdog_pid=$!
wait "$ORPHAN_PID"; rc=$?
kill "$watchdog_pid" 2>/dev/null
record "shutdown: the receiver exits cleanly with the tunnel dead" "0" "$rc"
spawns_before="$(wc -l < "$CF_ORPHAN_PIDS" | tr -d ' ')"
sleep 1
record "shutdown: no cloudflared is spawned after SIGTERM" "$spawns_before" \
  "$(wc -l < "$CF_ORPHAN_PIDS" | tr -d ' ')"

# the sleep side kills a webhook tick the same way it kills its own scale
# tick: the tick lock serializes ticks with each other, but it does not
# protect the sleep-side routing flip from a tick that survives the sleep
# notification. route-watcher.py is macOS-only (IOKit at import); elsewhere
# the suite skips this part.
if HOMEFIELD_STATE_DIR="$TMP/state" python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('rw', '$ROOT/bin/route-watcher.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
" 2>/dev/null; then
  printf '60\n' >"$TMP/stub-sleep"
  tick_pid="$(CALLS_SLEEP_FLAG="$TMP/stub-sleep" python3 - "$TMP/app/bin/homefield" <<'PY'
import subprocess, sys
print(subprocess.Popen([sys.argv[1], "fleet", "watch", "--max-ticks", "1"],
                       start_new_session=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid)
PY
)"
  printf '%s\n' "$tick_pid" >"$TMP/state/route-watcher/webhook/tick.pid"
  kill -0 "$tick_pid" 2>/dev/null && r=yes || r=no
  record "sleep side: the webhook tick is running" "yes" "$r"
  HOMEFIELD_STATE_DIR="$TMP/state" python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('rw', '$ROOT/bin/route-watcher.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.stop_webhook_tick()
"
  r=no
  for _ in $(seq 1 50); do
    kill -0 "$tick_pid" 2>/dev/null || { r=yes; break; }
    sleep 0.1
  done
  record "sleep side: the tick is killed before the flip" "yes" "$r"

  # the pid file can be stale and a stale pid recycled: the kill only lands
  # on a process whose command line is the tick's
  python3 -c 'import time; time.sleep(300)' 2>/dev/null &
  innocent_pid=$!
  printf '%s\n' "$innocent_pid" >"$TMP/state/route-watcher/webhook/tick.pid"
  HOMEFIELD_STATE_DIR="$TMP/state" python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('rw', '$ROOT/bin/route-watcher.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.stop_webhook_tick()
"
  kill -0 "$innocent_pid" 2>/dev/null && r=yes || r=no
  record "sleep side: a pid that is not a tick is left alone" "yes" "$r"
  kill "$innocent_pid" 2>/dev/null || true
  wait "$innocent_pid" 2>/dev/null
  rm -f "$TMP/stub-sleep"
else
  echo "  skip sleep-side tick kill (route-watcher.py needs macOS IOKit)"
fi

# ---------------------------------------------------------------------------
# Part 2 — the commands, against stubbed cloudflared/gh/launchctl.

# The port probes are overridden for the command tests: the setup tests must
# not probe the host's real listeners (this Mac is a runner host, and the
# root AGENTS.md forbids observing ambient host state), so each phase picks
# a stub and the probes themselves are unit-tested below against
# test-owned, dynamically allocated ports.
cat > "$TMP/stubs-port-free" <<'EOF'
webhook_port_free() { return 0; }
webhook_receiver_answers() { return 1; }
EOF
cat > "$TMP/stubs-port-ours" <<'EOF'
webhook_port_free() { return 1; }
webhook_receiver_answers() { return 0; }
EOF
cat > "$TMP/stubs-port-held" <<'EOF'
webhook_port_free() { return 1; }
webhook_receiver_answers() { return 1; }
EOF
HOOK_STUBS="$TMP/stubs-port-free"

# probe <fn> <args...>: one port-probe function in a child that sourced
# bin/homefield; prints the function's exit status (set -e is armed by the
# source, so the status is captured, not propagated).
probe() {
  local fn="$1"
  shift
  env -i HOME="$HOME" PATH="$PATH" HOMEFIELD_SOURCE_ONLY=1 HOMEFIELD_STATE_DIR="$TMP/state2" \
    "$BASH" -c '. "$1"; shift; status=0; "$@" || status=$?; printf "%s" "$status"' \
    _ "$ROOT/bin/homefield" "$fn" "$@"
}

PROBE_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
record "probe: a port with no listener is free" "0" "$(probe webhook_port_free "$PROBE_PORT")"

python3 - "$PROBE_PORT" <<'PY' &
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(16)
s.settimeout(60)
# accept and close: a listener that never accepts fills its backlog with
# the readiness probe's connection and the port-free probe's connect is
# then refused, which reads as "free"
while True:
    try:
        c, _ = s.accept()
        c.close()
    except socket.timeout:
        break
PY
plain_listener=$!
for _ in $(seq 1 50); do
  python3 -c "import socket; s=socket.socket(); s.connect(('127.0.0.1',$PROBE_PORT)); s.close()" 2>/dev/null && break
  sleep 0.1
done
record "probe: a port with a plain listener is not free" "1" "$(probe webhook_port_free "$PROBE_PORT")"
record "probe: a plain listener is not the receiver" "1" "$(probe webhook_receiver_answers "$PROBE_PORT")"
kill "$plain_listener" 2>/dev/null || true
wait "$plain_listener" 2>/dev/null

# a fresh port for the healthz listener: on Linux, the plain listener's
# accepted connections sit in TIME_WAIT after it closes them, and without
# SO_REUSEADDR its port is not immediately reusable
HEALTHZ_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 - "$HEALTHZ_PORT" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
healthz_listener=$!
for _ in $(seq 1 50); do
  python3 -c "import socket; s=socket.socket(); s.connect(('127.0.0.1',$PROBE_PORT)); s.close()" 2>/dev/null && break
  sleep 0.1
done
record "probe: a healthz listener is the receiver" "0" "$(probe webhook_receiver_answers "$HEALTHZ_PORT")"
kill "$healthz_listener" 2>/dev/null || true
wait "$healthz_listener" 2>/dev/null

cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALLS_LAUNCHCTL:?}"
case "${1-}" in
  list)
    # grep -q exits as soon as it matches, and any line the producer writes
    # after that is a SIGPIPE — which set -o pipefail turns into a false
    # "not loaded" (the capture-first fix exists for this; launchctl list is
    # slow enough over IPC that it always writes past the match). The
    # webhook line therefore sits in the middle, with padding after it.
    printf -- '-\t0\tcom.apple.Placeholder\n%.0s' $(seq 1 50)
    printf -- '-\t0\tcom.homefield.route-watcher\n-\t0\tcom.homefield.webhook\n'
    printf -- '-\t0\tcom.apple.Placeholder\n%.0s' $(seq 1 400000) ;;
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
        # GitHub's create-repository-webhook API rejects a payload whose
        # name is not "web" (422, Hook.name invalid) — pin the contract the
        # live connect exposed.
        if [ -n "$body" ] && [ "$(jq -r .name "$body" 2>/dev/null)" != "web" ]; then
          printf 'gh: Validation Failed (Hook.name invalid)\n' >&2
          exit 1
        fi
        [ -n "$body" ] && cp "$body" "${GH_BODY_OUT:?}"
        # a PATCH of an existing hook carries the hook id in its path
        hook="$(printf '%s' "$*" | sed -n 's|.*repos/.*/hooks/\([0-9]*\).*|\1|p')"
        if [ -n "$hook" ] && [ "${GH_PATCH_FAIL:-}" = 1 ]; then
          printf 'gh: boom\n' >&2
          exit 1
        fi
        [ -n "$hook" ] && printf '%s' "$hook" || printf '%s' "4242" ;;
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
    GH_PATCH_FAIL="${GH_PATCH_FAIL:-}" \
    HOMEFIELD_SCALE_INTERVAL="${HOMEFIELD_SCALE_INTERVAL:-}" HOMEFIELD_SCALE_WAIT="${HOMEFIELD_SCALE_WAIT:-}" \
    HOMEFIELD_SCALE_IDLE="${HOMEFIELD_SCALE_IDLE:-}" HOMEFIELD_SCALE_MAX="${HOMEFIELD_SCALE_MAX:-}" \
    HOMEFIELD_SCALE_ZERO="${HOMEFIELD_SCALE_ZERO:-}" HOMEFIELD_SCALE_TICK_BUDGET="${HOMEFIELD_SCALE_TICK_BUDGET:-}" \
    HOMEFIELD_WEBHOOK_TUNNEL="${HOMEFIELD_WEBHOOK_TUNNEL:-}" \
    HOMEFIELD_WEBHOOK_READ_TIMEOUT="${HOMEFIELD_WEBHOOK_READ_TIMEOUT:-}" HOMEFIELD_WEBHOOK_MAX_CONNECTIONS="${HOMEFIELD_WEBHOOK_MAX_CONNECTIONS:-}" \
    HOOK_STUBS="${HOOK_STUBS:-}" \
    "$BASH" -c '. "$1"; shift; if [ -n "${HOOK_STUBS:-}" ]; then . "$HOOK_STUBS"; fi; "$@"' \
    _ "$ROOT/bin/homefield" cmd_webhook "$@" 2>&1 </dev/null
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
out="$(run "$STATE2" setup --hostname webhook.example.com --port 0)"
record "setup: --port 0 is refused" "nonzero" "$(nonzero $?)"
out="$(run "$STATE2" setup --hostname webhook.example.com --port 99999)"
rc=$?
record "setup: --port 99999 is refused" "nonzero" "$(nonzero $rc)"
case "$out" in *"between 1 and 65535"*) r=yes ;; *) r=no ;; esac
record "setup: the port refusal names the valid range" "yes" "$r"

# no cloudflared login yet (the fresh HOME has none)
out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787)"
rc=$?
record "setup: no cloudflared login is refused" "nonzero" "$(nonzero $rc)"
case "$out" in *"tunnel login"*) r=yes ;; *) r=no ;; esac
record "setup: the refusal names the login" "yes" "$r"
: > "$HOME/.cloudflared/cert.pem"
: > "$HOME/.cloudflared/tunnel-uuid.json"

# a port that is already in use, against a test-owned listener: the real
# probes run here (no stub), and the port is one this suite allocated
unset HOOK_STUBS
BUSY_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 -c "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',$BUSY_PORT)); s.listen(1); time.sleep(60)" 2>/dev/null &
busy_pid=$!
out="$(run "$STATE2" setup --hostname webhook.example.com --port "$BUSY_PORT")"
record "setup: an occupied port is refused" "nonzero" "$(nonzero $?)"
kill "$busy_pid" 2>/dev/null || true
wait "$busy_pid" 2>/dev/null
HOOK_STUBS="$TMP/stubs-port-free"

HOMEFIELD_SCALE_ZERO=1 HOMEFIELD_SCALE_MAX=2
out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787)"
rc=$?
record "setup: happy path exits 0" "0" "$rc"
plist="$HOME/Library/LaunchAgents/com.homefield.webhook.plist"
record "setup: the plist is written" "yes" "$(has "$(cat "$plist" 2>/dev/null)" 'com.homefield.webhook')"
record "setup: the port is baked into the plist" "yes" "$(has "$(cat "$plist" 2>/dev/null)" '18787')"
record "setup: the shell's scaler policy is baked into the plist" "yes/yes" \
  "$(has "$(cat "$plist" 2>/dev/null)" 'HOMEFIELD_SCALE_ZERO')/$(has "$(cat "$plist" 2>/dev/null)" '<string>2</string>')"
record "setup: launchctl load recorded" "1" "$(grep -c -e '^load -w' "$calls_launchctl" || true)"
record "setup: the tunnel was already listed, so no create" "0" "$(grep -c -e 'tunnel create' "$calls_cloudflared" || true)"
record "setup: the DNS route is added" "1" "$(grep -c -e 'tunnel route dns' "$calls_cloudflared" || true)"
record "setup: the secret is 0600" "600" "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$STATE2/route-watcher/webhook/secret")"
record "setup: the config records hostname, port, tunnel" "webhook.example.com/18787/homefield-webhook" \
  "$(grep -h '^hostname=' "$STATE2/route-watcher/webhook/config" | cut -d= -f2)/$(grep -h '^port=' "$STATE2/route-watcher/webhook/config" | cut -d= -f2)/$(grep -h '^tunnel=' "$STATE2/route-watcher/webhook/config" | cut -d= -f2)"
record "setup: prints the public URL" "yes" "$(has "$out" 'https://webhook.example.com/webhook')"
HOMEFIELD_WEBHOOK_READ_TIMEOUT=5 HOMEFIELD_WEBHOOK_MAX_CONNECTIONS=8
out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787)"
record "setup: the receiver's read deadline and cap are baked into the plist" "yes/yes" \
  "$(has "$(cat "$plist" 2>/dev/null)" '<key>HOMEFIELD_WEBHOOK_READ_TIMEOUT</key>')/$(has "$(cat "$plist" 2>/dev/null)" '<key>HOMEFIELD_WEBHOOK_MAX_CONNECTIONS</key>')"
unset HOMEFIELD_WEBHOOK_READ_TIMEOUT HOMEFIELD_WEBHOOK_MAX_CONNECTIONS
unset HOMEFIELD_SCALE_ZERO HOMEFIELD_SCALE_MAX

# re-run: the route step's "already exists" conflict is refused, because
# the error says nothing about the existing record's target - it may point
# at this tunnel or at another tunnel or service, and the record is a
# proxied CNAME whose target resolution cannot reveal
# shellcheck disable=SC2034  # read by the cloudflared stub in the subshell
CF_ROUTE_FAIL=1 CF_ROUTE_ERR="An A, AAAA or CNAME record already exists with that host"
out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787)"
rc=$?
record "setup: an existing DNS record is refused" "nonzero" "$(nonzero $rc)"
case "$out" in *"--overwrite-dns"*) r=yes ;; *) r=no ;; esac
record "setup: the conflict names the fix" "yes" "$r"
# the operator's explicit --overwrite-dns replaces the record
out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787 --overwrite-dns)"
rc=$?
record "setup: --overwrite-dns replaces the record" "0" "$rc"
case "$out" in *"replaced the existing DNS record"*) r=yes ;; *) r=no ;; esac
record "setup: the replacement is reported" "yes" "$r"
record "setup: the overwrite hit cloudflared" "1" \
  "$(grep -c -e 'route dns --overwrite-dns' "$calls_cloudflared" || true)"
# shellcheck disable=SC2034  # read by the cloudflared stub in the subshell
CF_ROUTE_ERR="cloudflared: zone not found"
out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787)"
rc=$?
record "setup: a real route failure is fatal" "nonzero" "$(nonzero $rc)"
case "$out" in *"zone not found"*) r=yes ;; *) r=no ;; esac
record "setup: the route failure is shown" "yes" "$r"
unset CF_ROUTE_FAIL CF_ROUTE_ERR

# a tunnel that does not exist yet is created (the marker records that the
# tunnel exists, so it must be absent for the create path to run); with no
# scaler settings in the shell, the policy is read back from the installed
# route watcher's plist
rm -rf "$STATE2"
rm -f "$CF_MARKER"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.homefield.route-watcher.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOMEFIELD_SCALE_IDLE</key>
    <string>1200</string>
  </dict>
</dict>
</plist>
EOF
# shellcheck disable=SC2034  # read by the cloudflared stub in the subshell
CF_CREATE_THEN_LIST=1
out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787)"
rc=$?
record "setup: a missing tunnel is created" "1" "$(grep -c -e 'tunnel create' "$calls_cloudflared" || true)"
record "setup: created tunnel still exits 0" "0" "$rc"
record "setup: the route watcher's scaler policy is inherited" "yes" \
  "$(has "$(cat "$plist" 2>/dev/null)" '<key>HOMEFIELD_SCALE_IDLE</key>')"
unset CF_CREATE_THEN_LIST

# the documented HOMEFIELD_WEBHOOK_TUNNEL override must reach the tunnel
# setup discovers, creates and routes: the plist bakes it and the receiver
# runs it, so a name the shell did not resolve the same way would route the
# hostname to one tunnel while the agent starts another (own state dir:
# the purge below must not touch STATE2's config and secret)
STATE4="$TMP/state4"
# shellcheck disable=SC2034  # read by the cloudflared stub in the subshell
CF_LIST_JSON='[{"id": "custom-uuid", "name": "custom-tunnel"}]'
touch "$HOME/.cloudflared/custom-uuid.json"
HOMEFIELD_WEBHOOK_TUNNEL=custom-tunnel
out="$(run "$STATE4" setup --hostname webhook.example.com --port 18787)"
rc=$?
record "setup: a tunnel-name override exits 0" "0" "$rc"
record "setup: the override is routed, not the default name" "1" \
  "$(grep -c -e 'tunnel route dns custom-tunnel webhook.example.com' "$calls_cloudflared" || true)"
record "setup: the override is recorded in the config" "custom-tunnel" \
  "$(grep -h '^tunnel=' "$STATE4/route-watcher/webhook/config" | cut -d= -f2)"
record "setup: the override is baked into the plist" "yes" \
  "$(has "$(cat "$plist" 2>/dev/null)" '<string>custom-tunnel</string>')"
# a later agent refresh from a shell without the override (upgrade
# --auto-route re-runs webhook_agent_install the same way) must preserve
# the installed tunnel: the DNS route points at the saved name, and a
# receiver started on the default tunnel would never see a delivery
env -i HOME="$HOME" PATH="$PATH" HOMEFIELD_SOURCE_ONLY=1 \
  HOMEFIELD_STATE_DIR="$STATE4" \
  "$BASH" -c '. "$1"; shift; status=0; "$@" || status=$?; printf "%s" "$status"' \
  _ "$ROOT/bin/homefield" webhook_agent_install 18787 >/dev/null 2>&1
refresh_rc=$?
record "setup: an agent refresh without the override exits 0" "0" "$(nonzero $refresh_rc)"
record "setup: the refresh keeps the installed tunnel baked" "yes" \
  "$(has "$(cat "$plist" 2>/dev/null)" '<string>custom-tunnel</string>')"
# removal and status run without the override: the name setup saved in the
# config is what they act on, not the default
unset HOMEFIELD_WEBHOOK_TUNNEL
out="$(run "$STATE4" status)"
record "setup: status reports the installed tunnel without the env" "yes" \
  "$(has "$out" 'custom-uuid')"
out="$(run "$STATE4" remove --purge)"
record "setup: remove --purge deletes the overridden tunnel from the saved config" "1" \
  "$(grep -c -e 'tunnel delete custom-tunnel' "$calls_cloudflared" || true)"
unset CF_LIST_JSON
rm -f "$HOME/.cloudflared/custom-uuid.json"

# connect. The request body is a 0600 mktemp (a fresh name per run) with
# an EXIT/INT/TERM cleanup trap: a test-owned TMPDIR makes the leftovers
# observable, and the old fixed connect-body.json path in the state dir is
# gone with it.
CONNECT_TMPDIR="$TMP/connect-tmp"
mkdir -p "$CONNECT_TMPDIR"
TMPDIR_OLD="${TMPDIR:-}"
TMPDIR="$CONNECT_TMPDIR"
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
record "connect: no request body file is left behind" "0" "$(ls -A "$CONNECT_TMPDIR" 2>/dev/null | wc -l | tr -d ' ')"

# shellcheck disable=SC2034  # read by the gh stub in the subshell
GH_HOOKS_JSON='[{"id": 7, "config": {"url": "https://webhook.example.com/webhook"}}]'
out="$(run "$STATE2" connect o/r)"
rc=$?
record "connect: an existing hook exits 0" "0" "$rc"
case "$out" in *"refreshed with the current secret"*) r=yes ;; *) r=no ;; esac
record "connect: an existing hook is refreshed, not skipped" "yes" "$r"
record "connect: the refresh PATCHes the hook" "1" "$(grep -c -e 'hooks/7' "$calls_gh" || true)"
record "connect: the refresh carries the current secret" "yes" \
  "$(has "$(cat "$TMP/body.json" 2>/dev/null)" "$(cat "$STATE2/route-watcher/webhook/secret")")"
record "connect: the refresh does not create a second hook" "4" "$(grep -c -e 'repos/o/r/hooks' "$calls_gh" || true)"

# a gh failure must not leave the secret-bearing body on disk either:
# the EXIT/INT/TERM cleanup trap is what removes it
# shellcheck disable=SC2034  # read by the gh stub in the subshell
GH_PATCH_FAIL=1
out="$(run "$STATE2" connect o/r)"
rc=$?
record "connect: a failed refresh exits nonzero" "nonzero" "$(nonzero $rc)"
record "connect: a failed refresh leaves no body file behind" "0" \
  "$(ls -A "$CONNECT_TMPDIR" 2>/dev/null | wc -l | tr -d ' ')"
unset GH_PATCH_FAIL

# a remove + re-setup rotates the secret; the next connect must push the
# new one to the hook GitHub still has
old_secret="$(cat "$STATE2/route-watcher/webhook/secret")"
run "$STATE2" remove >/dev/null
run "$STATE2" setup --hostname webhook.example.com --port 18787 >/dev/null
out="$(run "$STATE2" connect o/r)"
rc=$?
record "connect: after a secret rotation, exits 0" "0" "$rc"
case "$out" in *"refreshed"*) r=yes ;; *) r=no ;; esac
record "connect: after a secret rotation, the hook is refreshed" "yes" "$r"
record "connect: the rotation push carries the new secret, not the old" "yes/no" \
  "$(has "$(cat "$TMP/body.json" 2>/dev/null)" "$(cat "$STATE2/route-watcher/webhook/secret")")/$(has "$(cat "$TMP/body.json" 2>/dev/null)" "$old_secret")"

out="$(run "$TMP/state3" connect o/r)"
record "connect: without setup is refused" "nonzero" "$(nonzero $?)"
unset GH_HOOKS_JSON GH_BODY_OUT
TMPDIR="$TMPDIR_OLD"

# status: the agent is loaded (the stub lists it), the receiver is not up
out="$(run "$STATE2" status)"
rc=$?
record "status: reports the loaded agent" "yes" "$(has "$out" 'agent: loaded')"
record "status: reports the URL" "yes" "$(has "$out" 'https://webhook.example.com/webhook')"
record "status: the secret is present" "yes" "$(has "$out" 'secret: present')"
record "status: the tunnel is listed" "yes" "$(has "$out" 'tunnel-uuid')"
record "status: the quiet receiver is reported" "yes" "$(has "$out" 'receiver: not answering')"
record "status: the quiet receiver fails the status" "nonzero" "$(nonzero $rc)"

out="$(run "$STATE2" status junk)"
record "status: an unknown argument is refused" "nonzero" "$(nonzero $?)"

# a listener that holds the port but is not the receiver must not be
# reported as ours (the old check read the port being busy as "listening")
HOOK_STUBS="$TMP/stubs-port-held"
out="$(run "$STATE2" status)"
rc=$?
record "status: a foreign listener on the port is reported" "yes/nonzero" \
  "$(has "$out" 'another process')/$(nonzero $rc)"

# a listening receiver, through the stub (a real listener on a fixed port
# would observe the host's ambient state)
HOOK_STUBS="$TMP/stubs-port-ours"
out="$(run "$STATE2" status)"
rc=$?
record "status: a listening receiver passes" "yes/0" \
  "$(has "$out" 'receiver: listening on 127.0.0.1:18787')/$(nonzero $rc)"

# re-running setup on the installed receiver's own port is
# reconfiguration, not a conflict: the listener answers the receiver's
# healthz (the probes are stubbed; their real logic is unit-tested above
# and the occupied-port refusal runs against a test-owned listener)
out="$(run "$STATE2" setup --hostname webhook.example.com --port 18787)"
rc=$?
record "setup: the receiver's own port is reconfiguration" "0" "$rc"
record "setup: the reinstalled agent carries the port" "yes" "$(has "$(cat "$plist" 2>/dev/null)" '18787')"
HOOK_STUBS="$TMP/stubs-port-free"

# remove
unloads_before="$(grep -c -e '^unload -w' "$calls_launchctl" || true)"
deletes_before="$(grep -c -e 'tunnel delete' "$calls_cloudflared" || true)"
printf 'stale\n' >"$STATE2/route-watcher/webhook/connect-body.json"
out="$(run "$STATE2" remove)"
rc=$?
record "remove: exits 0" "0" "$rc"
record "remove: launchctl unload recorded" "1" \
  "$(( $(grep -c -e '^unload -w' "$calls_launchctl" || true) - unloads_before ))"
record "remove: the plist is gone" "0" "$(ls "$plist" 2>/dev/null | wc -l | tr -d ' ')"
record "remove: the secret is gone" "0" "$(ls "$STATE2/route-watcher/webhook/secret" 2>/dev/null | wc -l | tr -d ' ')"
record "remove: a stale connect-body.json is cleaned up" "0" \
  "$(ls "$STATE2/route-watcher/webhook/connect-body.json" 2>/dev/null | wc -l | tr -d ' ')"
record "remove: the tunnel is kept without --purge" "0" \
  "$(( $(grep -c -e 'tunnel delete' "$calls_cloudflared" || true) - deletes_before ))"

# rebuild the state, then purge
deletes_before="$(grep -c -e 'tunnel delete' "$calls_cloudflared" || true)"
cleanups_before="$(grep -c -e 'tunnel cleanup' "$calls_cloudflared" || true)"
run "$STATE2" setup --hostname webhook.example.com --port 18787 >/dev/null
out="$(run "$STATE2" remove --purge)"
rc=$?
record "remove --purge: exits 0" "0" "$rc"
record "remove --purge: the tunnel is deleted" "1" \
  "$(( $(grep -c -e 'tunnel delete' "$calls_cloudflared" || true) - deletes_before ))"
record "remove --purge: the tunnel is cleaned up first" "1" \
  "$(( $(grep -c -e 'tunnel cleanup' "$calls_cloudflared" || true) - cleanups_before ))"

summary