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

    0x00  CTRL        bit0 ap_start, bit1 ap_done, bit2 ap_idle, bit3 ap_ready
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

BYTES_PER_PIXEL = 4

# Generous by three orders of magnitude: a 1080p frame takes about 11 ms. This
# is here to turn a hung accelerator into an exception instead of a notebook
# that never returns.
DEFAULT_TIMEOUT = 5.0


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
            if self._ip.read(REG_CTRL) & CTRL_AP_DONE:
                return
            if self._clock() >= deadline:
                raise TimeoutError(
                    f"accelerator did not assert AP_DONE within {timeout}s -- "
                    "check the argument registers and that the frame buffers "
                    "are physically addressable")

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
