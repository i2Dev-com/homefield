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
  sleep).

At load — login, or launchd restarting the agent — the wake path runs once:
the agent's RunAtLoad makes a login a wake for this purpose, and a crashed
and restarted agent re-checks what is pending.

Everything the helper itself does wrong goes to stderr, which launchd appends
to the watcher log (StandardErrorPath in the plist).
"""

import ctypes
import ctypes.util
import os
import subprocess
import sys
import time

# IOKit's power messages (IOPMLib.h).
kIOMessageCanSystemSleep = 14
kIOMessageSystemWillSleep = 15
kIOMessageSystemWillPowerOn = 16
kIOMessageSystemHasPoweredOn = 17
kIOMessageSystemWillNotSleep = 18


def _positive_float(name, default):
    try:
        value = float(os.environ.get(name, "") or default)
    except ValueError:
        return default
    return value if value > 0 else default


SLEEP_BUDGET = _positive_float("HOMEFIELD_WATCH_SLEEP_BUDGET", 20)
WAKE_BUDGET = _positive_float("HOMEFIELD_WATCH_WAKE_BUDGET", 600)

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


def run_route_watch(mode, budget):
    """Run one route-watch mode, bounded by wall time.

    subprocess.run's timeout uses the monotonic clock, which does not advance
    while the Mac sleeps: a force-sleep in the middle of a flip would resume
    after the wake with its budget barely spent and keep flipping repositories
    to hosted after the Mac is back. Waiting in small slices on the wall clock
    expires the budget the moment the Mac is awake, the stale child is killed,
    and the run loop's next message (the wake) takes over.
    """
    global sleep_child
    proc = subprocess.Popen([HOMEFIELD, "route-watch", mode])
    sleep_child = proc
    deadline = time.time() + budget
    while True:
        try:
            proc.wait(timeout=0.5)
            sleep_child = None
            return True
        except subprocess.TimeoutExpired:
            pass
        if time.time() >= deadline:
            proc.kill()
            proc.wait()
            sleep_child = None
            log(
                "route-watch %s did not finish within %ds; killed. Repositories "
                "it did not reach keep their previous routing; the next wake or "
                "start sorts the rest out."
                % (mode, int(budget))
            )
            return False


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
        run_route_watch("sleep", SLEEP_BUDGET)
        acknowledge(root_port, message_argument)
    elif message_type == kIOMessageSystemHasPoweredOn:
        if sleep_child is not None and sleep_child.poll() is None:
            # Unreachable while the run loop is single-threaded (the wake
            # cannot be delivered inside the sleep callback), but a stale
            # flip must never outlive the sleep it served.
            sleep_child.kill()
            sleep_child.wait()
        run_route_watch("wake", WAKE_BUDGET)


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
    # pending before settling into the event loop.
    run_route_watch("wake", WAKE_BUDGET)
    CF.CFRunLoopRun()
    return 0


if __name__ == "__main__":
    sys.exit(main())