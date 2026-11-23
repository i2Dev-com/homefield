#!/usr/bin/env python3
"""The webhook receiver's helper (#309).

GitHub delivers `workflow_job` webhooks to a cloudflared named tunnel that
forwards to this helper's loopback HTTP server. Each verified delivery rings
the demand scaler's doorbell: the helper spawns one
`homefield fleet watch --max-ticks 1` tick, so a dark VM's wake no longer
waits up to the route-watcher's 60 s tick interval. The tick stays the only
decision point — the receiver is a doorbell, and a delivery for a job the
routing would never send here costs one harmless evaluation (the tick answers
"nothing waits" for it), nothing more.

Security posture (the endpoint is reachable from the internet through the
tunnel):

- Every POST's body is authenticated with GitHub's `X-Hub-Signature-256`
  HMAC-SHA256 signature over the raw body, compared in constant time against
  the shared secret in `<state>/webhook/secret` (mode 0600, written by
  `homefield webhook setup`). Anything else gets a generic 403 before the
  body is parsed. A replayed delivery only re-rings the doorbell, and one
  tick evaluates the whole demand — there is nothing to replay into.
- The request body is capped (BODY_LIMIT) and rejected before parsing; the
  action comes from an allowlist; no payload field reaches a command line,
  a path, or a log line. The spawned tick command is fixed.
- The server binds to 127.0.0.1 only: the tunnel is the only path in, and
  the Mac's own users already own the secret file.

The helper also supervises the tunnel's cloudflared child: it spawns
`cloudflared tunnel run --url http://127.0.0.1:<port> homefield-webhook`
and retries with a capped backoff if the child dies (a brew upgrade moves
the binary; the retry re-resolves it from PATH). The HTTP server dies with a
SIGTERM after killing the tunnel child, so launchd's KeepAlive restarts both
cleanly.

Environment (all optional; `homefield webhook setup` bakes the plist's):

- HOMEFIELD_WEBHOOK_PORT       listen port (default 8787)
- HOMEFIELD_WEBHOOK_ACTIONS    workflow_job actions that ring the doorbell,
                               comma-separated (default queued,completed)
- HOMEFIELD_WEBHOOK_DEBOUNCE   minimum seconds between spawned ticks
                               (default 1; a tick child already running
                               always suppresses a spawn instead)
- HOMEFIELD_STATE_DIR          state root (default ~/.local/state/homefield)
- HOMEFIELD_WEBHOOK_TUNNEL     tunnel name (default homefield-webhook)

State lives in `<state>/route-watcher/webhook/`: `secret`, `tick.pid`, and
the tunnel child's output interleaves with this helper's log (launchd
redirects both to `<state>/route-watcher/webhook/log`).
"""

import hashlib
import hmac
import http.server
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time

# GitHub's webhook payloads are a few KB; 1 MiB is generous and bounds what
# a hostile delivery can make the helper read and hash.
BODY_LIMIT = 1024 * 1024
WEBHOOK_PATH = "/webhook"
TUNNEL_NAME = os.environ.get("HOMEFIELD_WEBHOOK_TUNNEL") or "homefield-webhook"

# The helper lives next to homefield in the installed tree, like
# route-watcher.py.
HOMEFIELD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "homefield")
STATE_DIR = os.environ.get("HOMEFIELD_STATE_DIR") or os.path.join(
    os.path.expanduser("~"), ".local", "state", "homefield"
)
WEBHOOK_DIR = os.path.join(STATE_DIR, "route-watcher", "webhook")
SECRET_FILE = os.path.join(WEBHOOK_DIR, "secret")
TICK_PID_FILE = os.path.join(WEBHOOK_DIR, "tick.pid")


def _positive_float(name, default):
    try:
        value = float(os.environ.get(name, "") or default)
    except ValueError:
        return default
    return value if value > 0 else default


def _int_env(name, default):
    try:
        return int(os.environ.get(name, "") or default)
    except ValueError:
        return default


PORT = _int_env("HOMEFIELD_WEBHOOK_PORT", 8787)
DEBOUNCE = _positive_float("HOMEFIELD_WEBHOOK_DEBOUNCE", 1.0)
ACTIONS = {
    a.strip()
    for a in (os.environ.get("HOMEFIELD_WEBHOOK_ACTIONS") or "queued,completed").split(",")
    if a.strip()
}


def log(message):
    print(time.strftime("%Y-%m-%dT%H:%M:%S%z") + " webhook: " + message, file=sys.stderr, flush=True)


def read_secret():
    try:
        with open(SECRET_FILE, "rb") as f:
            secret = f.read().strip()
    except OSError:
        return None
    return secret or None


def tick_child_alive():
    """True when the recorded tick child is still running.

    A tick evaluates the whole demand, so a delivery that arrives while one
    runs is satisfied by the running tick; the recorded pid only suppresses
    a duplicate spawn, it never gates one (a dead or recycled pid just lets
    the next delivery spawn a fresh tick).
    """
    try:
        with open(TICK_PID_FILE) as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


# One delivery at a time reaches the spawn decision: concurrent request
# threads would otherwise both pass the alive check and both spawn.
spawn_lock = threading.Lock()


def spawn_tick():
    """Spawn one scaler tick detached; the tick lock serializes it with the
    route-watcher's own ticks, and its output lands in this helper's log."""
    log_fd = os.open(
        os.path.join(WEBHOOK_DIR, "tick.log"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600
    )
    try:
        proc = subprocess.Popen(
            [HOMEFIELD, "fleet", "watch", "--max-ticks", "1"],
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=log_fd,
            stderr=subprocess.STDOUT,
        )
    finally:
        os.close(log_fd)
    tmp = TICK_PID_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(proc.pid))
    os.replace(tmp, TICK_PID_FILE)
    log("spawned tick pid=%d" % proc.pid)


class Receiver(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # Generic responses only: an error body that explains which check failed
    # is reconnaissance for an attacker probing the endpoint.
    def _respond(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path == "/healthz":
            self._respond(200)
        else:
            self._respond(404)

    def do_POST(self):
        if self.path != WEBHOOK_PATH:
            self._respond(404)
            return
        length = self.headers.get("Content-Length")
        try:
            length = int(length)
        except (TypeError, ValueError):
            self._respond(411)
            return
        if length < 0 or length > BODY_LIMIT:
            self._respond(413)
            return
        body = self.rfile.read(length) if length else b""

        secret = read_secret()
        if secret is None:
            log("rejected: no secret on disk (run homefield webhook setup)")
            self._respond(503)
            return
        given = self.headers.get("X-Hub-Signature-256") or ""
        expected = "sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(given, expected):
            log("rejected: bad or missing signature")
            self._respond(403)
            return

        event = self.headers.get("X-GitHub-Event") or ""
        if event != "workflow_job":
            # Authenticated delivery for an event we did not ask for (or a
            # ping): accepted, nothing to ring.
            self._respond(204)
            return
        try:
            payload = json.loads(body or b"{}")
            action = payload.get("action")
        except ValueError:
            self._respond(400)
            return
        repo = (payload.get("repository") or {}).get("full_name") or "?"
        if action not in ACTIONS:
            log("ignored: workflow_job action=%r not in %s (repo=%s)" % (action, ",".join(sorted(ACTIONS)), repo))
            self._respond(204)
            return

        if not spawn_lock.acquire(blocking=False):
            log("doorbell: another delivery is spawning a tick (action=%s repo=%s)" % (action, repo))
            self._respond(202)
            return
        try:
            if tick_child_alive():
                log("doorbell: tick already running (action=%s repo=%s)" % (action, repo))
                self._respond(202)
                return
            # A tick recorded as just spawned may not have its pid on disk yet
            # (the child is spawned between our alive check and our own spawn);
            # the debounce covers that window, and a skipped ring costs nothing
            # because the just-spawned tick evaluates the same demand.
            try:
                age = time.time() - os.stat(TICK_PID_FILE).st_mtime
            except OSError:
                age = None
            if age is not None and age < DEBOUNCE:
                log("doorbell: debounced (action=%s repo=%s)" % (action, repo))
                self._respond(202)
                return
            spawn_tick()
        finally:
            spawn_lock.release()
        self._respond(204)

    def log_message(self, format, *args):
        pass  # the handler's own lines say everything worth logging


def tunnel_command():
    """The cloudflared child's command line, re-resolved on every (re)start
    so a brew upgrade that moves the binary is picked up on the next retry."""
    cloudflared = shutil.which("cloudflared")
    if cloudflared is None:
        return None
    return [
        cloudflared,
        "tunnel",
        "run",
        "--url",
        "http://127.0.0.1:%d" % PORT,
        TUNNEL_NAME,
    ]


tunnel_proc = None


def supervise_tunnel():
    """Keep one cloudflared child running, retrying with a capped backoff.

    The receiver itself stays up (launchd's KeepAlive only restarts it if
    this helper exits), so a crash-looping tunnel degrades to retries every
    60 s with the reason in the log, not to a restart loop of the whole
    agent.
    """
    global tunnel_proc
    backoff = 5.0
    while True:
        cmd = tunnel_command()
        if cmd is None:
            log("cloudflared not found on PATH; retrying in 60s (reinstall the agent if it moved)")
            time.sleep(60.0)
            continue
        tunnel_proc = subprocess.Popen(cmd)
        log("tunnel child pid=%d (%s)" % (tunnel_proc.pid, " ".join(cmd)))
        started = time.time()
        tunnel_proc.wait()
        code = tunnel_proc.returncode
        if time.time() - started > 300.0:
            backoff = 5.0  # a healthy stretch resets the backoff
        log("tunnel child exited rc=%s; retrying in %.0fs" % (code, backoff))
        time.sleep(backoff)
        backoff = min(backoff + 5.0, 60.0)


def terminate(signum, frame):
    if tunnel_proc is not None:
        try:
            tunnel_proc.terminate()
        except OSError:
            pass
    sys.exit(0)


def main():
    os.makedirs(WEBHOOK_DIR, exist_ok=True)
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    threading.Thread(target=supervise_tunnel, daemon=True).start()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Receiver)
    log(
        "listening on 127.0.0.1:%d%s (actions=%s)"
        % (PORT, WEBHOOK_PATH, ",".join(sorted(ACTIONS)))
    )
    server.serve_forever()


if __name__ == "__main__":
    main()