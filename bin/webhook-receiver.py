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
# The same wall-time budget the route watcher gives its ticks: a
# webhook-spawned tick that hangs must not hold the scaler's tick lock
# forever, which would stand down every later delivery and periodic tick
# alike — scaling for the whole fleet would stop.
TICK_BUDGET = _positive_float("HOMEFIELD_SCALE_TICK_BUDGET", 1800)
# Seconds a connection may take between reads before the server closes it:
# an unauthenticated peer can declare a Content-Length and never send the
# body, and without a deadline each such request holds a thread and a
# socket indefinitely. GitHub's deliveries are a few KB on a live
# connection; 10 s is generous for them and fatal for a slowloris.
READ_TIMEOUT = _positive_float("HOMEFIELD_WEBHOOK_READ_TIMEOUT", 10.0)
# Concurrent connections the server serves at all: each is a thread plus a
# socket, and the cap bounds what a peer that only opens connections can
# make the server hold. Excess connections are closed before a thread is
# spent on them — GitHub retries a rejected delivery; a thread pile-up
# does not recover.
MAX_CONNECTIONS = _int_env("HOMEFIELD_WEBHOOK_MAX_CONNECTIONS", 32)
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


# One delivery at a time reaches the spawn decision: concurrent request
# threads would otherwise both pass the alive check and both spawn.
spawn_lock = threading.Lock()

# The ticks this receiver instance spawned. A exited child stays a zombie
# until reaped, and a zombie still answers kill -0 — without reaping, the
# first exited tick would read as "already running" forever and every
# later delivery would 202 instead of spawning.
tick_children = []
# Pids of our own children that have been reaped: the pid file may still
# name them, and the pid-file fallback below must not read them as alive.
reaped_pids = set()


def tick_child_alive():
    """True when a spawned tick is still running.

    Our own children are tracked as Popen objects and polled here, which
    reaps them; the pid file is only a fallback for a tick this receiver
    instance did not spawn (one started before a restart, or by hand) —
    for those, kill -0 is a plain live check, because the process is not
    our child and something else reaps it.
    """
    still = []
    for proc in tick_children:
        if proc.poll() is None:
            still.append(proc)
        else:
            reaped_pids.add(proc.pid)
    tick_children[:] = still
    if tick_children:
        return True
    try:
        with open(TICK_PID_FILE) as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        return False
    if pid in reaped_pids:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        # A pid the file names that no longer runs: the file is stale (a
        # tick this receiver instance did not spawn exits without anything
        # reaping it), and a stale pid can later be recycled — drop the
        # file so neither we nor the sleep side mistake a recycled pid for
        # a live tick.
        try:
            os.remove(TICK_PID_FILE)
        except OSError:
            pass
        return False
    return True


def kill_tree(proc):
    """Kill the tick's whole process group and reap it.

    The tick is started in a session of its own (start_new_session), so
    the group is exactly the run's tree: a multi-VM tick's real work
    happens in per-VM grandchildren, and killing only the top `homefield`
    would leave them working after the budget expired.
    """
    if proc.poll() is not None:
        # Already exited and reaped: its pid is recyclable, and killpg on
        # a recycled pid would signal whoever the pid now names.
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def supervise_tick(proc):
    """Reap the tick child, killing its tree when it exceeds the budget.

    This is also what reaps the child: without a wait, an exited tick
    stays a zombie, and a zombie still answers kill -0. A reaped tick is
    untracked here, so the shutdown path never killpg's a pid the OS may
    have recycled.
    """
    try:
        proc.wait(timeout=TICK_BUDGET)
    except subprocess.TimeoutExpired:
        log("tick pid=%d exceeded the %gs budget; killing its process tree" % (proc.pid, TICK_BUDGET))
        kill_tree(proc)
    reaped_pids.add(proc.pid)
    try:
        tick_children.remove(proc)
    except ValueError:
        pass


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
    tick_children.append(proc)
    threading.Thread(target=supervise_tick, args=(proc,), daemon=True).start()
    log("spawned tick pid=%d (budget %gs)" % (proc.pid, TICK_BUDGET))


class Receiver(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # Closes a connection that stops reading mid-request (see READ_TIMEOUT);
    # handle_one_request turns the socket timeout into a clean close.
    timeout = READ_TIMEOUT

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


handler_slots = threading.BoundedSemaphore(MAX_CONNECTIONS)


class ReceiverServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    # Bound the connections the server serves (see MAX_CONNECTIONS): a peer
    # that only opens connections and never speaks is closed here, before
    # a thread is spent on it.
    def process_request(self, request, client_address):
        if not handler_slots.acquire(blocking=False):
            try:
                request.close()
            except OSError:
                pass
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            handler_slots.release()

    def handle_error(self, request, client_address):
        # A connection the cap closed (or a peer that hung up mid-request)
        # surfaces here as a reset; a traceback per refused connection is
        # noise, not signal. One line, then move on.
        log("dropped a connection from %s: %s" % (client_address[0], sys.exc_info()[1]))


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
    # A running tick would otherwise outlive this process: it was started in
    # a session of its own, and its budget supervisor is a daemon thread
    # that dies with us — a restarted receiver merely reads the saved pid
    # and never reinstates the deadline, so a hung tick could hold the
    # scaler's lock forever, suppressing webhook and periodic scaling alike.
    # Kill and reap the ticks this instance spawned before exiting; launchd
    # restarts the receiver, and the next delivery re-rings the doorbell.
    for proc in list(tick_children):
        kill_tree(proc)
    sys.exit(0)


def main():
    os.makedirs(WEBHOOK_DIR, exist_ok=True)
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    threading.Thread(target=supervise_tunnel, daemon=True).start()
    server = ReceiverServer(("127.0.0.1", PORT), Receiver)
    log(
        "listening on 127.0.0.1:%d%s (actions=%s)"
        % (PORT, WEBHOOK_PATH, ",".join(sorted(ACTIONS)))
    )
    server.serve_forever()


if __name__ == "__main__":
    main()