#!/usr/bin/env python3
"""Driving the CH12 accelerator: the register map, and the zero-copy rule.

The accelerator is `ap_ctrl_hs` -- write the arguments, set AP_START, poll
AP_DONE -- which is exactly how CH11's was driven and exactly what PYNQ's
`register_map` does for you. This module exists for two reasons that a bare
`register_map` does not cover:

  - **It works in physical addresses, not buffers.** At video rate the
    interesting thing is to point the accelerator straight at a frame the
    hardware already owns: the camera's VDMA buffer as the source, the
    DisplayPort's own frame as the destination. Nothing is copied and nothing
    is allocated per frame. CH11 could not do this -- it read a JPEG into a
    buffer it allocated itself and copied the result out again -- and the copy
    it paid is most of the difference between the two chapters at 60 fps.

  - **It refuses a frame the accelerator cannot write.** The kernel has no
    stride register: a frame is width*height contiguous words. A DRM frame
    whose stride has been aligned up is a strided *view* of a larger buffer,
    and handing its device address to the accelerator would scribble over the
    padding and shear the picture. `frame_address` checks rather than assumes.

Register map, unchanged from CH11 -- see CH12/README.md:

    0x00  CTRL        bit0 ap_start, bit1 ap_done, bit2 ap_idle, bit3 ap_ready,
                    bit7 auto_restart
    0x04  GIER
    0x08  IP_IER
    0x0C  IP_ISR
    0x10  src   low 32 bits      0x14  src  high 32 bits
    0x1C  dst   low 32 bits      0x20  dst  high 32 bits
    0x28  img_width
    0x30  img_height
    0x38  mode
"""
import time

import sobel_ref as ref

REG_CTRL = 0x00
REG_GIER = 0x04
REG_IER = 0x08
REG_ISR = 0x0C
REG_SRC_LO = 0x10
REG_SRC_HI = 0x14
REG_DST_LO = 0x1C
REG_DST_HI = 0x20
REG_WIDTH = 0x28
REG_HEIGHT = 0x30
REG_MODE = 0x38

CTRL_AP_START = 1 << 0
CTRL_AP_DONE = 1 << 1
CTRL_AP_IDLE = 1 << 2
CTRL_AP_READY = 1 << 3
CTRL_AUTO_RESTART = 1 << 7

# Ordered low bit first, so a decoded string reads the way the register does.
CTRL_FLAGS = (
    (CTRL_AP_START, "ap_start"),
    (CTRL_AP_DONE, "ap_done"),
    (CTRL_AP_IDLE, "ap_idle"),
    (CTRL_AP_READY, "ap_ready"),
    (CTRL_AUTO_RESTART, "auto_restart"),
)

BYTES_PER_PIXEL = 4

# Generous by three orders of magnitude: a 1080p frame takes about 11 ms. This
# is here to turn a hung accelerator into an exception instead of a notebook
# that never returns.
DEFAULT_TIMEOUT = 5.0


def decode_ctrl(ctrl):
    """CTRL as names rather than as a number.

    Same spelling as project 0's `run_camera.py` uses on the video IPs, so a
    handshake state means the same thing wherever it is printed.
    """
    names = [name for bit, name in CTRL_FLAGS if ctrl & bit]
    return " | ".join(names) if names else "nothing set"


def frame_address(frame, width, height):
    """Physical address of a frame the accelerator can read or write in place.

    Raises ValueError rather than returning a plausible-looking address for a
    buffer whose rows are not contiguous -- see the module docstring.
    """
    if frame.shape != (height, width, 4):
        raise ValueError(f"frame is {frame.shape}, expected {(height, width, 4)}")
    if frame.dtype.itemsize != 1:
        raise ValueError(f"frame must be 8-bit, got {frame.dtype}")
    if not frame.flags["C_CONTIGUOUS"]:
        raise ValueError(
            "frame rows are not contiguous -- its stride is padded, so the "
            "accelerator cannot write it in place. Filter into a buffer of "
            "your own and copy, or pick a width whose row is already aligned.")
    if frame.strides[0] != width * BYTES_PER_PIXEL:
        raise ValueError(f"row stride is {frame.strides[0]}, expected "
                         f"{width * BYTES_PER_PIXEL}")
    addr = getattr(frame, "device_address", None)
    if addr is None:
        addr = getattr(frame, "physical_address", None)
    if not addr:
        raise ValueError("frame has no physical address -- it is ordinary "
                         "memory, not a buffer the PL can reach. Use "
                         "pynq.allocate, a VDMA frame or a DisplayPort frame.")
    return int(addr)


def _timeout_message(timeout, state):
    """The exception text. Long on purpose -- this failure is intermittent and
    expensive to reproduce, so the one that happens has to name its own cause
    instead of asking for another afternoon on the board."""
    if state["ctrl"] & CTRL_AP_IDLE:
        verdict = ("ap_idle is set: the kernel is NOT running, so the AP_START "
                   "write was dropped rather than a frame hanging")
    else:
        verdict = ("ap_idle is clear: the kernel started and did not finish, so "
                   "it is hung part-way through the frame above -- check that "
                   "both buffers are physically addressable and contiguous")
    latch = ""
    if state.get("isr", 0) & 1:
        latch = ("\n  IP_ISR=0x%08x -- ap_done DID fire and was latched, so the "
                 "completion\n  was lost between the hardware and the poll, not "
                 "never generated" % state["isr"])
    elif "isr" in state:
        latch = (f"\n  IP_ISR={state['isr']:#010x}  IP_IER={state['ier']:#010x}"
                 f"  (IER bit 0 must be set for ISR to latch anything)")
    probe = ""
    sc = state.get("start_ctrl")
    if sc is not None:
        if sc & CTRL_AP_IDLE:
            reading = ("AP_START never took -- still idle one transaction "
                       "after arming, so the write was dropped")
        else:
            reading = ("the kernel DID launch -- ap_idle was already clear, so "
                       "the completion was lost, not the start")
        probe = (f"\n  at start: CTRL={sc:#010x}  {decode_ctrl(sc)}"
                 f"\n  {reading}")
    fresh = ""
    if "ctrl_fresh" in state:
        cf = state["ctrl_fresh"]
        fresh = (f"\n  fresh CTRL read at the deadline: {cf:#010x}  "
                 f"{decode_ctrl(cf)}   after {state.get('polls', 0)} polls")
        if cf & CTRL_AP_DONE:
            fresh += ("\n  AP_DONE IS SET on a fresh read -- the poll was not "
                      "seeing the hardware")
    return (
        f"accelerator did not assert AP_DONE within {timeout}s\n"
        f"  CTRL={state['ctrl']:#010x}  {state['flags']}\n"
        f"  src={state['src']:#010x}  dst={state['dst']:#010x}  "
        f"{state['img_width']}x{state['img_height']}  mode={state['mode']}\n"
        f"  {verdict}{probe}{latch}{fresh}")


class VideoFilter:
    """Thin wrapper over the accelerator's AXI4-Lite interface.

    Parameters
    ----------
    ip : object with read(offset) and write(offset, value)
        A PYNQ `DefaultIP` -- `overlay.video_filter_0` -- or anything that
        looks like one.
    clock : callable
        Injected so the timing path is testable without a board. Defaults to
        `time.perf_counter`.
    """

    def __init__(self, ip, clock=None):
        self._ip = ip
        self._clock = clock or time.perf_counter
        # One record per AP_DONE timeout observed, in the order they happened.
        # The fault is intermittent, so a run that retried past one still has
        # to be able to say that it did -- see `wait`.
        self.timeouts = []
        # Opt-in: read CTRL once immediately after AP_START. See `run`.
        self.probe_start = False
        self.last_start_ctrl = None
        # Set by enable_done_latch(). Counts completions that CTRL lost and
        # IP_ISR saved -- a recovery is not a non-event, it is the race
        # happening, and the number belongs in the chapter.
        # On by default. CTRL's AP_DONE is clear-on-read and about one frame in
        # a thousand goes missing between being set and being polled; IP_ISR
        # latches the same event and cannot be lost that way. Nothing else uses
        # IP_ISR, and IP_IER bit 0 on its own raises no interrupt because GIER
        # is zero, so there is nothing to trade away. Set `done_latch = False`
        # to see the raw behaviour.
        self.done_latch = True
        self._latch_armed = False
        self.recovered_completions = 0

    # ------------------------------------------------------------- arguments
    def configure(self, src_addr, dst_addr, width, height, mode):
        """Write every argument register. Does not start the accelerator."""
        if not 0 < width <= ref.MAX_WIDTH:
            raise ValueError(f"width must be 1..{ref.MAX_WIDTH}, got {width}")
        if height < 1:
            raise ValueError(f"height must be >= 1, got {height}")
        if mode not in ref.MODES:
            raise ValueError(f"mode must be one of {ref.MODES}, got {mode!r}")
        for name, addr in (("src", src_addr), ("dst", dst_addr)):
            if not 0 <= addr < (1 << 64):
                raise ValueError(f"{name} address {addr:#x} does not fit in 64 bits")

        self._ip.write(REG_SRC_LO, src_addr & 0xFFFFFFFF)
        self._ip.write(REG_SRC_HI, (src_addr >> 32) & 0xFFFFFFFF)
        self._ip.write(REG_DST_LO, dst_addr & 0xFFFFFFFF)
        self._ip.write(REG_DST_HI, (dst_addr >> 32) & 0xFFFFFFFF)
        self._ip.write(REG_WIDTH, width)
        self._ip.write(REG_HEIGHT, height)
        self._ip.write(REG_MODE, mode)

    # ----------------------------------------------------------- handshake
    def start(self):
        """Pulse AP_START. The kernel is `ap_ctrl_hs`, so this runs one frame."""
        if self.done_latch:
            # Deferred to here rather than done in __init__: a constructor that
            # touches registers can hit an IP still held in reset, and on
            # ZynqMP that does not raise, it wedges the CPU.
            if not self._latch_armed:
                self.enable_done_latch()
            # IP_ISR is toggle-on-write and therefore sticky. A bit left over
            # from the previous frame would satisfy this frame's first poll,
            # returning before any work had been done -- so clear it here,
            # while the accelerator is definitely idle, rather than trusting
            # every completion path to have consumed it.
            stale = self._ip.read(REG_ISR) & 0x3
            if stale:
                self._ip.write(REG_ISR, stale)
        self._ip.write(REG_CTRL, CTRL_AP_START)

    def enable_done_latch(self):
        """Make IP_ISR bit 0 latch every ap_done.

        Called automatically by the first `start()` when `done_latch` is set,
        which it is by default. It exists separately so a script can arm the
        latch without running a frame.

        CTRL's AP_DONE is clear-on-read: a poll that races the completion can
        take the bit away without reporting it, and then nothing remembers the
        frame finished. ISR is toggle-on-write, so once latched it stays until
        it is explicitly cleared -- which makes it the one place a lost
        completion leaves a trace. It only latches when IP_IER bit 0 is on.

        On this board the reads were lost in an AXI4-Lite clock crossing rather
        than to a race inside the accelerator, and project 3 fixes that by
        giving the accelerator its own PS master at its own clock -- see
        CH12/README.md. The latch stays on by default because it costs nothing
        and it covers a crossing that cannot be avoided.
        """
        self._ip.write(REG_IER, 1)
        self._latch_armed = True

    def wait(self, timeout=DEFAULT_TIMEOUT):
        """Poll CTRL until AP_DONE. Raises TimeoutError rather than spinning.

        Polling rather than waiting on the interrupt: the accelerator has an
        interrupt line and it is connected, but a frame takes single-digit
        milliseconds and an interrupt round trip through the kernel costs more
        than it saves. CH11 polled for the same reason.
        """
        deadline = self._clock() + timeout
        polls = 0
        while True:
            ctrl = self._ip.read(REG_CTRL)
            polls += 1
            if ctrl & CTRL_AP_DONE:
                return
            if self.done_latch and (self._ip.read(REG_ISR) & 1):
                # ISR says the frame finished. That alone does not mean CTRL
                # lost anything: the completion may simply have landed in the
                # microseconds between this iteration's CTRL read and its ISR
                # read, in which case the next CTRL read would have seen it.
                # Re-read CTRL to tell the two apart, or the loss rate comes
                # out two orders of magnitude too high.
                lost = not (self._ip.read(REG_CTRL) & CTRL_AP_DONE)
                self._ip.write(REG_ISR, 1)          # toggle-on-write, consume
                if lost:
                    self.recovered_completions += 1
                return
            if self._clock() >= deadline:
                # Report the word the last poll returned rather than reading
                # CTRL again. AP_DONE is clear-on-read: a diagnostic read here
                # would consume a completion that arrived a moment late and
                # turn a slow frame into a lost one.
                state = self._diagnose(ctrl, polls)
                self.timeouts.append(state)
                raise TimeoutError(_timeout_message(timeout, state))

    def run(self, src_addr, dst_addr, width, height, mode,
            timeout=DEFAULT_TIMEOUT, retries=0):
        """Filter one frame in place. Returns the accelerator's elapsed seconds.

        `retries` re-arms the accelerator after a timeout: the arguments are
        written again and AP_START pulsed again. It is off by default and has
        to be asked for, because a retry that happens quietly hides the very
        fault it is working around -- every attempt that timed out is appended
        to `self.timeouts` whether the retry rescued the frame or not.

        The returned time is the successful attempt alone. A lost attempt is
        not part of what a frame costs, and folding it in would poison a
        timing table with an event that is being counted separately.
        """
        for attempt in range(retries + 1):
            # Written again on every attempt. If the accelerator was left in a
            # state where the first AP_START was dropped, its argument
            # registers are not to be trusted either.
            self.configure(src_addr, dst_addr, width, height, mode)
            t0 = self._clock()
            self.start()
            if self.probe_start:
                # The one measurement that separates the two things an
                # ap_idle timeout can mean. After the deadline they are
                # indistinguishable -- ap_idle set, nothing running -- because
                # a kernel that launched and finished also ends up idle. One
                # transaction after arming they are still distinct: a launched
                # kernel has already cleared ap_idle, a dropped write has not.
                #
                # Off by default because it costs an AXI4-Lite read on every
                # frame, and because reading CTRL clears AP_DONE -- harmless
                # here only because a frame takes milliseconds and cannot have
                # completed yet.
                self.last_start_ctrl = self._ip.read(REG_CTRL)
            try:
                self.wait(timeout=timeout)
            except TimeoutError:
                if attempt == retries:
                    raise
                continue
            return self._clock() - t0

    def run_frames(self, src_frame, dst_frame, mode, timeout=DEFAULT_TIMEOUT,
                   retries=0):
        """Filter one frame buffer into another, with no copies at all.

        Both arguments must be buffers the PL can reach -- a `pynq.allocate`
        buffer, a VDMA frame from the camera, or a DisplayPort frame from
        `newframe()`. Cache maintenance is the caller's, because at video rate
        it is usually already known to be unnecessary (VDMA and DPDMA buffers
        are non-cached) and a `flush()` per frame is not free.
        """
        height, width = dst_frame.shape[:2]
        return self.run(frame_address(src_frame, width, height),
                        frame_address(dst_frame, width, height),
                        width, height, mode, timeout=timeout, retries=retries)

    # ---------------------------------------------------------- diagnostics
    def _diagnose(self, ctrl, polls=0):
        """Everything the hardware can be asked at the moment it timed out.

        CTRL alone separates the two things this failure can be, which is why
        it is worth the words: ap_idle set means the kernel is not running, so
        the AP_START write never took; ap_idle clear means it started and has
        not finished, so it is hung part-way through the geometry reported
        alongside.
        """
        # IP_ISR and IP_IER are ordinary reads with no side effects -- unlike
        # CTRL, reading them cannot consume anything.
        # A FRESH read of CTRL, now that the frame is already lost. If this
        # disagrees with the polled word, the poll was not seeing the hardware
        # -- which is a different fault entirely from a completion that was
        # generated and consumed.
        state = {"ctrl": ctrl, "flags": decode_ctrl(ctrl),
                 "start_ctrl": self.last_start_ctrl, "polls": polls,
                 "isr": self._ip.read(REG_ISR), "ier": self._ip.read(REG_IER),
                 "ctrl_fresh": self._ip.read(REG_CTRL)}
        state.update(self.register_map)
        return state

    # ------------------------------------------------------------- readback
    @property
    def register_map(self):
        """The argument registers as written, read back off the hardware."""
        return {
            "src": (self._ip.read(REG_SRC_HI) << 32) | self._ip.read(REG_SRC_LO),
            "dst": (self._ip.read(REG_DST_HI) << 32) | self._ip.read(REG_DST_LO),
            "img_width": self._ip.read(REG_WIDTH),
            "img_height": self._ip.read(REG_HEIGHT),
            "mode": self._ip.read(REG_MODE),
        }
