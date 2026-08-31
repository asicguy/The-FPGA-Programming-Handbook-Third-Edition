#!/usr/bin/env python3
"""The CH13 reconfigurable modules in software: the golden model.

CH12 had one accelerator with four modes. CH13 has one *socket* with several
accelerators, and the difference matters: a mode is a branch inside fixed
hardware, while a kernel is different hardware entirely, loaded into the same
partition at run time. This file is the definition of what each one computes,
and every RTL testbench and every on-board check measures against it.

Four kernels, each with an identity the hardware reports at register 0x3C:

    KERNEL_PASSTHROUGH  copies its input. The "empty" RM -- it does nothing,
                        but it answers the bus, which is exactly what an empty
                        partition must do and a blanked one cannot.
    KERNEL_SOBEL        CH12's filter, unchanged: gray / Sobel / invert /
                        colour by mode. RM #1 for free, and the reason the
                        socket contract is CH12's register map.
    KERNEL_BLUR         3x3 Gaussian, [1 2 1; 2 4 2; 1 2 1] / 16, per colour
                        channel.
    KERNEL_THRESHOLD    binary threshold on luma, the level taken from `mode`.

That last one is the point of the chapter in one line: the register map does
not change, but what `mode` MEANS does, and the only honest way to know which
reading applies is to ask the hardware its kernel_id rather than to remember
what you loaded.

Frames are (H, W, 4) uint8 in B,G,R,A order -- what the MIPI camera and OpenCV
both hand you, so nothing here ever reorders a channel.

Border convention, for the windowed kernels: the border is ZEROED, not
extended. A 3x3 window is not defined at the edge, and inventing pixels there
would make hardware and software disagree about something neither of them
knows. Point kernels (passthrough, threshold) have no border at all, because
they need no window.
"""
import numpy as np

# Identities, reported at register 0x3C. These are the values the RTL
# parameters carry and the values sw asserts after a swap; if they drift apart
# the swap check silently stops meaning anything.
KERNEL_PASSTHROUGH = 0xA5A50000
KERNEL_SOBEL       = 0xA5A50001
KERNEL_BLUR        = 0xA5A50002
KERNEL_THRESHOLD   = 0xA5A50003

KERNELS = (KERNEL_PASSTHROUGH, KERNEL_SOBEL, KERNEL_BLUR, KERNEL_THRESHOLD)
KERNEL_NAMES = {
    KERNEL_PASSTHROUGH: "passthrough",
    KERNEL_SOBEL:       "sobel",
    KERNEL_BLUR:        "blur",
    KERNEL_THRESHOLD:   "threshold",
}

# The sobel kernel's modes, unchanged from CH12 so its notebook still applies.
MODE_GRAY = 0
MODE_SOBEL = 1
MODE_INVERT = 2
MODE_COLOR = 3
SOBEL_MODES = (MODE_GRAY, MODE_SOBEL, MODE_INVERT, MODE_COLOR)

# ITU-R BT.601 luma in Q8, ordered B,G,R to match the pixel layout.
LUMA_B = 29
LUMA_G = 150
LUMA_R = 77

# The Gaussian, and the shift that divides by its weight sum. A power of two
# on purpose: dividing by 9 for a box blur costs a divider or a multiply-and-
# shift approximation in the PL, and neither is worth it when a kernel that
# sums to 16 is a right-shift and looks better.
BLUR_K = np.array([[1, 2, 1],
                   [2, 4, 2],
                   [1, 2, 1]], dtype=np.int32)
BLUR_SHIFT = 4

# The line buffers in the PL are this deep. Software has no such limit, but it
# refuses anything the hardware could not do so the two stay comparable.
MAX_WIDTH = 1920


def _check(frame, kernel, mode):
    if not isinstance(frame, np.ndarray):
        raise ValueError("frame must be a NumPy array")
    if frame.dtype != np.uint8:
        raise ValueError(f"frame must be uint8, got {frame.dtype}")
    if frame.ndim != 3 or frame.shape[2] != 4:
        raise ValueError(f"frame must be (H, W, 4) BGRA, got {frame.shape}")
    if frame.shape[1] > MAX_WIDTH:
        raise ValueError(f"width {frame.shape[1]} exceeds MAX_WIDTH {MAX_WIDTH}")
    if kernel not in KERNELS:
        raise ValueError(f"kernel must be one of {[hex(k) for k in KERNELS]}, "
                         f"got {kernel:#x}")
    if kernel == KERNEL_SOBEL and mode not in SOBEL_MODES:
        raise ValueError(f"the sobel kernel's mode must be one of {SOBEL_MODES}, "
                         f"got {mode!r}")
    if kernel == KERNEL_THRESHOLD and not (0 <= mode <= 255):
        raise ValueError(f"the threshold level must fit in a byte, got {mode!r}")


def luma(frame):
    """BT.601 luma of a BGRA frame, as (H, W) int32. Alpha is ignored.

    Integer and truncating, because that is what the hardware does bit for bit.
    The weights sum to 256, so white comes out at exactly 255 and no clamp is
    needed.
    """
    b = frame[:, :, 0].astype(np.int32)
    g = frame[:, :, 1].astype(np.int32)
    r = frame[:, :, 2].astype(np.int32)
    return (LUMA_B * b + LUMA_G * g + LUMA_R * r) >> 8


def _as_bgra(plane):
    """Replicate an (H, W) intensity plane into an opaque BGRA frame."""
    v = plane.astype(np.uint8)
    out = np.empty(plane.shape + (4,), dtype=np.uint8)
    out[:, :, 0] = v
    out[:, :, 1] = v
    out[:, :, 2] = v
    out[:, :, 3] = 255
    return out


def _window_sum(plane, k):
    """Sum of a 3x3 weighted window over an (H, W) int32 plane, interior only.

    Returns an array the same shape with a zeroed border, so every windowed
    kernel here shares one border convention rather than each inventing its own.
    """
    out = np.zeros(plane.shape, dtype=np.int32)
    h, w = plane.shape
    if h < 3 or w < 3:
        return out
    acc = np.zeros((h - 2, w - 2), dtype=np.int32)
    for dr in range(3):
        for dc in range(3):
            acc += k[dr, dc] * plane[dr:dr + h - 2, dc:dc + w - 2]
    out[1:-1, 1:-1] = acc
    return out


def _sobel(y):
    """|Gx| + |Gy| of an (H, W) int32 luma plane, clamped, with a zero border."""
    out = np.zeros(y.shape, dtype=np.int32)
    h, w = y.shape
    if h < 3 or w < 3:
        return out
    gx = ((y[:-2, 2:] + 2 * y[1:-1, 2:] + y[2:, 2:])
          - (y[:-2, :-2] + 2 * y[1:-1, :-2] + y[2:, :-2]))
    gy = ((y[2:, :-2] + 2 * y[2:, 1:-1] + y[2:, 2:])
          - (y[:-2, :-2] + 2 * y[:-2, 1:-1] + y[:-2, 2:]))
    out[1:-1, 1:-1] = np.minimum(np.abs(gx) + np.abs(gy), 255)
    return out


def _blur(frame):
    """3x3 Gaussian per colour channel, zero border, opaque alpha.

    Per CHANNEL, not on luma. A blur that collapsed colour to grey would be two
    changes at once, and the point of this RM is to show the socket running a
    genuinely different function rather than another way to make things grey.
    It costs the line buffers three bytes a pixel instead of one -- see
    hdl/rm_blur_core.sv, where that is the whole difference from the sobel core.
    """
    out = np.zeros(frame.shape, dtype=np.uint8)
    for c in range(3):
        acc = _window_sum(frame[:, :, c].astype(np.int32), BLUR_K)
        out[:, :, c] = (acc >> BLUR_SHIFT).astype(np.uint8)
    # Opaque everywhere, border included: a border pixel is opaque BLACK, the
    # same convention the sobel kernel has had since CH11. Leaving the border
    # transparent instead would be a second, silent difference between the two
    # kernels, and the first place it would surface is a bit-exactness failure
    # on hardware with no obvious cause.
    out[:, :, 3] = 255
    return out


def filter_frame(frame, kernel, mode):
    """The golden model. Bit-exact against the RM loaded in the socket."""
    _check(frame, kernel, mode)

    if kernel == KERNEL_PASSTHROUGH:
        return frame.copy()

    if kernel == KERNEL_BLUR:
        return _blur(frame)

    if kernel == KERNEL_THRESHOLD:
        y = luma(frame)
        return _as_bgra(np.where(y >= mode, 255, 0))

    # KERNEL_SOBEL -- CH12's filter, unchanged.
    if mode == MODE_COLOR:
        return frame.copy()
    y = luma(frame)
    if mode == MODE_GRAY:
        return _as_bgra(y)
    if mode == MODE_INVERT:
        return _as_bgra(255 - y)
    return _as_bgra(_sobel(y))


def filter_frame_naive(frame, kernel, mode):
    """The same thing written the obvious way, to check the fast one against.

    Unusably slow and obviously correct, which is the trade it exists to make.
    Only the kernels new to CH13 need it; the sobel kernel already has CH12's
    naive implementation behind it.
    """
    _check(frame, kernel, mode)
    h, w = frame.shape[:2]
    out = np.zeros((h, w, 4), dtype=np.uint8)

    if kernel == KERNEL_PASSTHROUGH:
        for r in range(h):
            for c in range(w):
                out[r, c] = frame[r, c]
        return out

    if kernel == KERNEL_THRESHOLD:
        for r in range(h):
            for c in range(w):
                b, g, rr = int(frame[r, c, 0]), int(frame[r, c, 1]), int(frame[r, c, 2])
                y = (LUMA_B * b + LUMA_G * g + LUMA_R * rr) >> 8
                v = 255 if y >= mode else 0
                out[r, c] = (v, v, v, 255)
        return out

    if kernel == KERNEL_BLUR:
        out[:, :, 3] = 255                      # opaque border, as above
        for r in range(1, h - 1):
            for c in range(1, w - 1):
                for ch in range(3):
                    acc = 0
                    for dr in range(-1, 2):
                        for dc in range(-1, 2):
                            acc += int(BLUR_K[dr + 1, dc + 1]) * int(frame[r + dr, c + dc, ch])
                    out[r, c, ch] = (acc >> BLUR_SHIFT) & 0xFF
                out[r, c, 3] = 255
        return out

    raise ValueError("filter_frame_naive does not implement the sobel kernel -- "
                     "CH12/sw/sobel_ref.py already has it")
