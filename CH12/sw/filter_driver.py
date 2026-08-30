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
    return (
        f"accelerator did not assert AP_DONE within {timeout}s\n"
        f"  CTRL={state['ctrl']:#010x}  {state['flags']}\n"
        f"  src={state['src']:#010x}  dst={state['dst']:#010x}  "
        f"{state['img_width']}x{state['img_height']}  mode={state['mode']}\n"
        f"  {verdict}")


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
        self._ip.write(REG_CTRL, CTRL_AP_START)

    def wait(self, timeout=DEFAULT_TIMEOUT):
        """Poll CTRL until AP_DONE. Raises TimeoutError rather than spinning.

        Polling rather than waiting on the interrupt: the accelerator has an
        interrupt line and it is connected, but a frame takes single-digit
        milliseconds and an interrupt round trip through the kernel costs more
        than it saves. CH11 polled for the same reason.
        """
        deadline = self._clock() + timeout
        while True:
            ctrl = self._ip.read(REG_CTRL)
            if ctrl & CTRL_AP_DONE:
                return
            if self._clock() >= deadline:
                # Report the word the last poll returned rather than reading
                # CTRL again. AP_DONE is clear-on-read: a diagnostic read here
                # would consume a completion that arrived a moment late and
                # turn a slow frame into a lost one.
                state = self._diagnose(ctrl)
                self.timeouts.append(state)
                raise TimeoutError(_timeout_message(timeout, state))

    def run(self, src_addr, dst_addr, width, height, mode,
            timeout=DEFAULT_TIMEOUT):
        """Filter one frame in place. Returns the accelerator's elapsed seconds."""
        self.configure(src_addr, dst_addr, width, height, mode)
        t0 = self._clock()
        self.start()
        self.wait(timeout=timeout)
        return self._clock() - t0

    def run_frames(self, src_frame, dst_frame, mode, timeout=DEFAULT_TIMEOUT):
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
                        width, height, mode, timeout=timeout)

    # ---------------------------------------------------------- diagnostics
    def _diagnose(self, ctrl):
        """Everything the hardware can be asked at the moment it timed out.

        CTRL alone separates the two things this failure can be, which is why
        it is worth the words: ap_idle set means the kernel is not running, so
        the AP_START write never took; ap_idle clear means it started and has
        not finished, so it is hung part-way through the geometry reported
        alongside.
        """
        state = {"ctrl": ctrl, "flags": decode_ctrl(ctrl)}
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
