#!/usr/bin/env python3
"""The route watcher's power-event helper (#290).

macOS tells a process about sleep and wake only through IOKit's
IORegisterForSystemPower, which needs a run loop; there is no launchd key and
no shell command that delivers them (this is why the LaunchAgent runs this
helper instead of the shell command directly). The helper registers, waits in
the run loop, and translates the messages the automatic fallback cares about
into `bin/homefield route-watch` calls, acknowledging the sleep messages so
the Mac is not held up:

- kIOMessageSystemWillSleep: run `route-watch sleep` (the Part 1 flip: the
  routed repositories to hosted), bounded by HOMEFIELD_WATCH_SLEEP_BUDGET
  (default 20 s, of the ~30 s macOS grants before it forces the sleep), then
  acknowledge. A flip that does not finish in the budget is killed and
  logged loudly; the repositories it did not reach stay routed local, which
  is the status quo, and the wake side restores the ones it did reach. The
  clock is wall time, so a sleep that interrupts the wait still expires the
  budget right after the wake.
- kIOMessageCanSystemSleep: acknowledge (idle sleep is fine; the work
  happens on WillSleep).
- kIOMessageSystemHasPoweredOn: run `route-watch wake` (start the auto-route
  VMs, wait for the runners to be online, restore), bounded by
  HOMEFIELD_WATCH_WAKE_BUDGET (default 10 min; the wake path's own waits are
  bounded per VM, and a stuck one must not keep the agent from the next
  sleep). It runs in a thread of its own, because it can wait minutes and
  the run-loop thread must stay free to receive the next sleep notification;
  a WillSleep kills a running wake recovery before the sleep-side flip.

At load — login, or launchd restarting the agent — the wake path runs once:
the agent's RunAtLoad makes a login a wake for this purpose, and a crashed
and restarted agent re-checks what is pending.

The agent also runs the demand scaler (#291, part 3 of the #286 fallback):
a thread of its own wakes every HOMEFIELD_SCALE_INTERVAL seconds (default
60) and runs one `homefield fleet watch --max-ticks 1` tick, bounded by
HOMEFIELD_SCALE_TICK_BUDGET (default 30 min; creating a VM takes minutes,
and a hung tick must not stop the ones after it). A sleep notification
kills a running tick, the same way it kills a wake recovery.

Everything the helper itself does wrong goes to stderr, which launchd appends
to the watcher log (StandardErrorPath in the plist).
"""

import ctypes
import ctypes.util
import os
import signal
import subprocess
import sys
import threading
import time

# IOKit's power messages (IOPMLib.h): iokit_common_msg(0x270) etc., i.e.
# 0xe0000000 | the message id. Verified by compiling this Mac's own
# /usr/include/IOKit/IOMessage.h — the plain ids (14, 15, ...) are not what
# IORegisterForSystemPower delivers.
kIOMessageCanSystemSleep = 0xE0000270
kIOMessageSystemWillSleep = 0xE0000280
kIOMessageSystemWillPowerOn = 0xE0000320
kIOMessageSystemHasPoweredOn = 0xE0000300
kIOMessageSystemWillNotSleep = 0xE0000290


def _positive_float(name, default):
    try:
        value = float(os.environ.get(name, "") or default)
    except ValueError:
        return default
    return value if value > 0 else default


SLEEP_BUDGET = _positive_float("HOMEFIELD_WATCH_SLEEP_BUDGET", 20)
WAKE_BUDGET = _positive_float("HOMEFIELD_WATCH_WAKE_BUDGET", 600)
# The demand scaler's (#291) loop: one `fleet watch --max-ticks 1` tick every
# SCALE_INTERVAL seconds, each tick bounded by SCALE_TICK_BUDGET (creating a
# VM takes minutes; a tick that hangs must not stop the ones after it).
SCALE_INTERVAL = _positive_float("HOMEFIELD_SCALE_INTERVAL", 60)
SCALE_TICK_BUDGET = _positive_float("HOMEFIELD_SCALE_TICK_BUDGET", 1800)

# The helper lives next to homefield in the installed tree.
HOMEFIELD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "homefield")

IOKit = ctypes.cdll.LoadLibrary(ctypes.util.find_library("IOKit"))
CF = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))

# IOServiceInterestCallback: (void *refCon, io_service_t service,
# natural_t messageType, void *messageArgument); io_service_t and natural_t
# are 32-bit, so the callback reads them as 32-bit values.
IOServiceInterestCallback = ctypes.CFUNCTYPE(
    None, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p
)

IOKit.IORegisterForSystemPower.restype = ctypes.c_uint32
IOKit.IORegisterForSystemPower.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_void_p),
    IOServiceInterestCallback,
    ctypes.POINTER(ctypes.c_uint32),
]
IOKit.IOAllowPowerChange.restype = ctypes.c_int
IOKit.IOAllowPowerChange.argtypes = [ctypes.c_uint32, ctypes.c_long]
IOKit.IONotificationPortGetRunLoopSource.restype = ctypes.c_void_p
IOKit.IONotificationPortGetRunLoopSource.argtypes = [ctypes.c_void_p]
CF.CFRunLoopGetCurrent.restype = ctypes.c_void_p
CF.CFRunLoopAddSource.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
CF.CFRunLoopRun.restype = None
# The default run-loop mode is a CFStringRef constant: the pointer value
# stored at the symbol, read with in_dll.
kCFRunLoopDefaultMode = ctypes.c_void_p.in_dll(CF, "kCFRunLoopDefaultMode")

sleep_child = None


def log(message):
    print(message, file=sys.stderr, flush=True)


def kill_tree(proc):
    """Kill the run's whole process group and reap it.

    A multi-VM run's real work happens in per-VM grandchildren (vm_dispatch
    re-runs the command with --instance), so killing only the top `homefield`
    would leave them flipping repositories after the budget expired — the
    stale-flip protection must reach the whole tree. The command is started
    in a session of its own (start_new_session), so the group is exactly the
    run's tree; the parent may already be gone, and then the group id is
    what is still signalled.
    """
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def run_route_watch(mode, budget):
    """Run one route-watch mode synchronously, bounded by wall time.

    subprocess.run's timeout uses the monotonic clock, which does not advance
    while the Mac sleeps: a force-sleep in the middle of a flip would resume
    after the wake with its budget barely spent and keep flipping repositories
    to hosted after the Mac is back. Waiting in small slices on the wall clock
    expires the budget the moment the Mac is awake, the stale child is killed,
    and the run loop's next message (the wake) takes over.

    Only the sleep side runs here, on the run-loop thread and bounded to a
    fraction of the ~30 s macOS grants before it forces the sleep: the sleep
    notification must be answered after the flip, and the flip must finish
    before the Mac is gone. The wake side runs in a thread of its own (see
    start_wake), because it can wait minutes and must not keep this thread
    from the next sleep notification.
    """
    proc = subprocess.Popen([HOMEFIELD, "route-watch", mode], start_new_session=True)
    deadline = time.time() + budget
    while True:
        try:
            proc.wait(timeout=0.5)
            return True
        except subprocess.TimeoutExpired:
            pass
        if time.time() >= deadline:
            kill_tree(proc)
            log(
                "route-watch %s did not finish within %ds; killed. Repositories "
                "it did not reach keep their previous routing; the next wake or "
                "start sorts the rest out."
                % (mode, int(budget))
            )
            return False


# The wake recovery, in a thread of its own: it can wait minutes per VM
# (HOMEFIELD_WATCH_WAKE_WAIT) and must never keep the run-loop thread — the
# one that must receive and acknowledge the next sleep notification — busy.
# wake_proc is the run's process, guarded by state_lock; a sleep notification
# kills it (the Mac is going back to sleep, so a half-finished restore is
# exactly what the sleep-side flip then re-flips). wake_generation counts the
# starts: a run publishes its process only if its generation is still the
# newest, so a sleep notification arriving between a thread's start and its
# process creation invalidates the run instead of racing it — the thread sees
# the stale generation at publication, kills its own fresh process, and runs
# nothing (the sleep-side flip then re-flips whatever the half recovery did).
state_lock = threading.Lock()
wake_proc = None
wake_thread = None
wake_generation = 0


def _wake_run(gen):
    global wake_proc
    proc = subprocess.Popen([HOMEFIELD, "route-watch", "wake"], start_new_session=True)
    with state_lock:
        if gen != wake_generation:
            # Superseded between our start and this publication: a newer
            # start_wake took over, or a sleep notification cancelled the
            # recovery outright. The fresh process must not run.
            kill_tree(proc)
            return
        wake_proc = proc
    deadline = time.time() + WAKE_BUDGET
    while True:
        try:
            proc.wait(timeout=0.5)
            with state_lock:
                wake_proc = None
            return
        except subprocess.TimeoutExpired:
            pass
        if time.time() >= deadline:
            kill_tree(proc)
            with state_lock:
                wake_proc = None
            log(
                "route-watch wake did not finish within %ds; killed. Repositories "
                "it did not reach keep their previous routing; the next wake or "
                "start sorts the rest out." % int(WAKE_BUDGET)
            )
            return


def start_wake():
    """Start (or restart) the wake recovery in its own thread."""
    global wake_thread, wake_generation
    stop_wake()
    with state_lock:
        wake_generation += 1
        gen = wake_generation
    thread = threading.Thread(target=_wake_run, args=(gen,), daemon=True)
    with state_lock:
        wake_thread = thread
    thread.start()


def stop_wake():
    """Kill a running wake recovery and wait for its thread to end."""
    global wake_proc, wake_thread, wake_generation
    with state_lock:
        # The generation bump also invalidates a run whose thread has started
        # but not published its process yet: it kills the fresh process at
        # publication, so nothing of it races the sleep-side flip.
        wake_generation += 1
        proc = wake_proc
        wake_proc = None
    if proc is not None and proc.poll() is None:
        kill_tree(proc)
    with state_lock:
        thread = wake_thread
        wake_thread = None
    if thread is not None and thread is not threading.current_thread():
        # The thread notices the kill within its 0.5 s wait slice (or kills
        # its own fresh process at a stale-generation publication); the join
        # only bounds a thread stuck somewhere without the GIL released.
        thread.join(timeout=10)


# The demand scaler's tick (#291), guarded by the same lock as the wake
# recovery: a sleep notification kills a running tick (a half-created
# secondary is the same state a killed install leaves, and the next tick
# reconciles it), and the thread must never hold the run-loop thread.
scale_proc = None


def stop_scale():
    """Kill a running demand-scaler tick."""
    global scale_proc
    with state_lock:
        proc = scale_proc
        scale_proc = None
    if proc is not None and proc.poll() is None:
        kill_tree(proc)


def run_scale_tick():
    """Run one fleet-watch tick synchronously, bounded by wall time.

    The same wait-in-small-slices shape as run_route_watch: the budget is
    wall time, so a Mac that sleeps mid-tick expires it right after the wake
    instead of resuming a half-finished create into the awake world.
    """
    global scale_proc
    proc = subprocess.Popen(
        [HOMEFIELD, "fleet", "watch", "--max-ticks", "1"], start_new_session=True
    )
    with state_lock:
        scale_proc = proc
    deadline = time.time() + SCALE_TICK_BUDGET
    while True:
        try:
            proc.wait(timeout=0.5)
            with state_lock:
                scale_proc = None
            return
        except subprocess.TimeoutExpired:
            pass
        if time.time() >= deadline:
            kill_tree(proc)
            with state_lock:
                scale_proc = None
            log(
                "fleet watch tick did not finish within %ds; killed. A "
                "secondary it was half-creating stays behind; the next tick "
                "reconciles it, or `bin/homefield reset --instance <name>` "
                "removes it by hand." % int(SCALE_TICK_BUDGET)
            )
            return


def _scale_loop():
    """The scaler's thread: sleep, tick, repeat, surviving anything one tick
    does — the loop must outlive a tick's failure for the ones after it."""
    while True:
        time.sleep(SCALE_INTERVAL)
        try:
            run_scale_tick()
        except Exception as exc:  # noqa: BLE001 - the loop must survive
            log("fleet watch tick failed: %r" % (exc,))


def acknowledge(root_port, message_argument):
    # The notification id arrives as the pointer-sized value of
    # messageArgument, not as a pointer to it.
    token = message_argument if isinstance(message_argument, int) else 0
    IOKit.IOAllowPowerChange(root_port, token)


def on_power_event(_refcon, _service, message_type, message_argument):
    if message_type == kIOMessageCanSystemSleep:
        # Idle sleep is fine: the flip happens on WillSleep, which the system
        # announces separately. Not answering would delay every idle sleep.
        acknowledge(root_port, message_argument)
    elif message_type == kIOMessageSystemWillSleep:
        # A wake recovery still running from the previous wake is obsolete —
        # the Mac is going back to sleep — and this thread must stay free to
        # answer this notification: kill it before the flip. The demand
        # scaler's tick goes the same way: a create frozen mid-flight would
        # resume into the awake world, and the next tick starts over.
        stop_scale()
        stop_wake()
        run_route_watch("sleep", SLEEP_BUDGET)
        acknowledge(root_port, message_argument)
    elif message_type == kIOMessageSystemHasPoweredOn:
        start_wake()


# The callback must outlive the registration: a garbage-collected one would
# crash the process on the first power event.
_callback = IOServiceInterestCallback(on_power_event)
root_port = 0


def main():
    global root_port
    if not os.path.exists(HOMEFIELD):
        log(
            "route-watcher: %s is missing; the helper must live next to "
            "homefield. Reinstall the tool or rerun "
            "`bin/homefield upgrade --auto-route`." % HOMEFIELD
        )
        return 1
    port_ref = ctypes.c_void_p()
    notifier = ctypes.c_uint32()
    root_port = IOKit.IORegisterForSystemPower(
        None, ctypes.byref(port_ref), _callback, ctypes.byref(notifier)
    )
    if not root_port:
        log(
            "route-watcher: IORegisterForSystemPower failed; the watcher "
            "cannot tell when the Mac sleeps. Nothing was flipped."
        )
        return 1
    source = IOKit.IONotificationPortGetRunLoopSource(port_ref)
    if not source:
        log("route-watcher: could not get the power-event run-loop source.")
        return 1
    CF.CFRunLoopAddSource(CF.CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode)
    # Login or a restart counts as a wake (RunAtLoad): restore what is
    # pending, in its own thread so the run loop below stays free for the
    # sleep notification if the Mac goes back under immediately.
    start_wake()
    # The demand scaler's loop (#291): one tick per interval, in a thread of
    # its own (a tick can take minutes and must never keep the run loop from
    # the next power event).
    threading.Thread(target=_scale_loop, daemon=True).start()
    CF.CFRunLoopRun()
    return 0


if __name__ == "__main__":
    sys.exit(main())