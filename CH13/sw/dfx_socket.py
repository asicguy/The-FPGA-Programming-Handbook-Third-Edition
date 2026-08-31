#!/usr/bin/env python3
"""Driving the CH13 reconfigurable socket: the swap, and the refusals.

This driver is mostly about DECLINING to do things, and that needs explaining,
because it looks defensive out of proportion to a filter swap.

On ZynqMP there is no bus timeout on the PL ports. A read of a partition that
is held in reset, or mid-reconfiguration, or simply empty, does not return an
error -- it does not return at all. The CPU that issued it stops, with no panic
and no console output, and the only way out is a power cycle. Worse, "held in
reset", "being reconfigured" and "the logic is broken" are indistinguishable
from outside, so there is no way to tell afterwards which one happened.

The answer is the status GPIO, and it is in the STATIC region on purpose:
static logic always answers, the partition may not. So every path to the socket
in this file goes through a liveness check first, and every failure leaves the
partition ISOLATED and IN RESET rather than half-connected. A swap that goes
wrong should cost an exception, not a power cycle.

The swap sequence is not a function call, it is a documented order, and each
step is here because something went wrong without it. See docs/ch13-plan.md 4.
"""
import time

# --- the socket's registers, at ch13_socket_base --------------------------
REG_CTRL      = 0x00
REG_GIER      = 0x04
REG_IP_IER    = 0x08
REG_IP_ISR    = 0x0C
REG_MODE      = 0x38
REG_KERNEL_ID = 0x3C

AP_START = 1 << 0
AP_DONE  = 1 << 1
AP_IDLE  = 1 << 2

# --- the static status/control GPIO, at ch13_dfx_ctrl_base ----------------
# Standard AXI GPIO map. Channel 1 is all outputs, channel 2 all inputs, so the
# TRI registers are fixed by the hardware configuration and never written.
GPIO_DATA  = 0x00
GPIO_TRI   = 0x04
GPIO2_DATA = 0x08
GPIO2_TRI  = 0x0C

# channel 1, outputs
CTL_SHUTDOWN  = 0   # request_shutdown to all three AXI shutdown managers
CTL_RM_RESETN = 1   # the partition's reset, active low

# channel 2, inputs
ST_HEARTBEAT  = 0   # a free-running toggle from inside the partition
ST_SDM_CTRL   = 1   # in_shutdown from the control-path manager
ST_SDM_GMEM0  = 2
ST_SDM_GMEM1  = 3
ST_SDM_ALL    = (1 << ST_SDM_CTRL) | (1 << ST_SDM_GMEM0) | (1 << ST_SDM_GMEM1)

# --- the RMs --------------------------------------------------------------
# These must agree with rm_ref.py and with the KERNEL_ID localparam in each
# hdl/rm_<name>.sv. test_dfx_socket.py asserts the first of those.
KERNEL_PASSTHROUGH = 0xA5A50000
KERNEL_SOBEL       = 0xA5A50001
KERNEL_BLUR        = 0xA5A50002
KERNEL_THRESHOLD   = 0xA5A50003

KERNEL_NAMES = {
    KERNEL_PASSTHROUGH: "passthrough",
    KERNEL_SOBEL:       "sobel",
    KERNEL_BLUR:        "blur",
    KERNEL_THRESHOLD:   "threshold",
}


class SocketError(Exception):
    """Base for everything this driver refuses to do."""


class SocketNotReady(SocketError):
    """The partition is not clocked, not out of reset, or not answering.

    Raised INSTEAD of touching the socket. On this board touching it anyway is
    not a worse error message, it is a hung CPU.
    """


class ShutdownTimeout(SocketError):
    """A shutdown manager never reported in_shutdown.

    Reconfiguring anyway would rewrite fabric underneath live AXI traffic. The
    spike did exactly that and the kernel died with
    'Asynchronous SError Interrupt'.
    """


class NotIdle(SocketError):
    """The accelerator is still running a frame."""


class WrongKernel(SocketError):
    """The socket reports an identity other than the one that was loaded."""


class DfxSocket:
    """The reconfigurable socket, and the static logic that guards it.

    `ip` is the socket's AXI4-Lite control port -- a PYNQ IP object, or
    anything with read(offset) and write(offset, value).
    `gpio` is the STATIC region's status GPIO, same interface.
    """

    def __init__(self, ip, gpio):
        self.ip = ip
        self.gpio = gpio
        # Every step of the last swap, in order, for the notebook to print and
        # for the tests to assert on. A swap that went wrong should say where.
        self.trace = []

    # ---------------------------------------------------------- static side
    def _ctl(self):
        return self.gpio.read(GPIO_DATA)

    def _set_ctl(self, bit, value):
        v = self._ctl()
        v = (v | (1 << bit)) if value else (v & ~(1 << bit))
        self.gpio.write(GPIO_DATA, v)

    def status(self):
        """Channel 2. Reads static logic only -- always safe, always answers."""
        return self.gpio.read(GPIO2_DATA)

    def alive(self, samples=8, interval=0.01):
        """Is the partition clocked and out of reset?

        Answered by watching the heartbeat CHANGE, not by reading a level: a
        level tells you what the wire is doing, a change tells you the
        partition's clock is running. A dead partition holds whatever the
        decoupled value is, which is a perfectly stable 0 or 1.

        Touches only the static GPIO, so it is safe to call at any time,
        including while the partition is being reconfigured.
        """
        first = (self.status() >> ST_HEARTBEAT) & 1
        for _ in range(samples):
            time.sleep(interval)
            if ((self.status() >> ST_HEARTBEAT) & 1) != first:
                return True
        return False

    def in_reset(self):
        return not (self._ctl() >> CTL_RM_RESETN) & 1

    def shutdown_engaged(self):
        """All three managers have actually completed their shutdown."""
        return (self.status() & ST_SDM_ALL) == ST_SDM_ALL

    # ------------------------------------------------------------- the gate
    def check_ready(self):
        """Raise unless the socket can be safely addressed.

        Called before every access to the partition. It is the whole reason the
        status GPIO exists, and skipping it once is enough to hang the board.
        """
        if self.in_reset():
            raise SocketNotReady("the partition is held in reset")
        if not self.alive():
            raise SocketNotReady(
                "the partition's heartbeat is not toggling -- it is not "
                "clocked, not out of reset, or empty")

    # ------------------------------------------------------ partition side
    def kernel_id(self):
        """What is ACTUALLY in the socket, asked of the hardware."""
        self.check_ready()
        return self.ip.read(REG_KERNEL_ID)

    def kernel_name(self):
        k = self.kernel_id()
        return KERNEL_NAMES.get(k, f"unknown ({k:#010x})")

    def is_idle(self):
        self.check_ready()
        return bool(self.ip.read(REG_CTRL) & AP_IDLE)

    # --------------------------------------------------------- the sequence
    def engage_shutdown(self, timeout=1.0):
        """Step 2. Ask the managers to shut down, and WAIT until they have.

        Asserting request_shutdown is a request. The managers take as long as
        their outstanding transactions take, and reconfiguring before all three
        report in_shutdown is reconfiguring underneath live traffic.
        """
        self._set_ctl(CTL_SHUTDOWN, 1)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.shutdown_engaged():
                return
            time.sleep(0.001)
        raise ShutdownTimeout(
            f"managers did not report in_shutdown within {timeout}s "
            f"(status={self.status():#06x})")

    def release_shutdown(self):
        self._set_ctl(CTL_SHUTDOWN, 0)

    def hold_reset(self):
        self._set_ctl(CTL_RM_RESETN, 0)

    def release_reset(self):
        self._set_ctl(CTL_RM_RESETN, 1)

    def wait_idle(self, timeout=1.0):
        """Step 1. The accelerator must not be mid-frame when it vanishes."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.ip.read(REG_CTRL) & AP_IDLE:
                return
            time.sleep(0.001)
        raise NotIdle(f"still running after {timeout}s")

    def swap(self, download, expect_kernel,
             idle_timeout=1.0, shutdown_timeout=1.0, alive_timeout=1.0):
        """The whole sequence, in the order docs/ch13-plan.md 4 specifies.

        `download` is a zero-argument callable that programs the partial -- in
        PYNQ, `lambda: overlay.pr_download(region, bitfile)`. It is injected
        rather than done here so this sequence can be tested without a board,
        which matters because the failure mode being tested for is a hang.

        On ANY failure after the shutdown is engaged, the partition is left
        isolated and in reset. That is the safe state: a partition nobody can
        reach cannot hang anybody.
        """
        self.trace = []

        def step(name, fn):
            self.trace.append((name, time.time()))
            return fn()

        # 1. not mid-frame. Before anything is disturbed, so a busy accelerator
        #    costs an exception rather than a half-finished swap.
        step("wait_idle", lambda: self.wait_idle(idle_timeout))

        # 2. isolate. Everything from here is inside the guarded region.
        step("engage_shutdown", lambda: self.engage_shutdown(shutdown_timeout))
        try:
            # 3. hold the partition down across the rewrite.
            step("hold_reset", self.hold_reset)

            # 4. the only step that touches the fabric.
            step("download", download)

            # 5. let it start.
            step("release_reset", self.release_reset)

            # 6. is the new RM alive? Static logic answers; the partition may
            #    not, and this is the last moment it is safe to ask.
            def check_alive():
                deadline = time.time() + alive_timeout
                while time.time() < deadline:
                    if self.alive(samples=4):
                        return
                raise SocketNotReady(
                    "the new RM never toggled its heartbeat -- the partial did "
                    "not take, or it is not the design this socket was routed for")
            step("check_alive", check_alive)
        except Exception:
            # Isolated and in reset. Deliberately NOT releasing the managers:
            # letting traffic reach a partition that is not answering is the
            # hang this entire mechanism exists to prevent.
            self.hold_reset()
            raise

        # 7. only now may traffic reach the socket.
        step("release_shutdown", self.release_shutdown)

        # 8. and only now is it meaningful to ask what is in there.
        def check_id():
            got = self.ip.read(REG_KERNEL_ID)
            if got != expect_kernel:
                raise WrongKernel(
                    f"socket reports {got:#010x} "
                    f"({KERNEL_NAMES.get(got, 'unknown')}), expected "
                    f"{expect_kernel:#010x} "
                    f"({KERNEL_NAMES.get(expect_kernel, 'unknown')})")
            return got
        return step("check_kernel_id", check_id)
