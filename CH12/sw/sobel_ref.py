#!/usr/bin/env python3
"""The CH12 filter in software: the golden model, and two things to time it against.

Three implementations, for three different jobs:

    filter_frame        vectorised NumPy. Bit-exact against the PL -- the same
                        Q8 integer arithmetic, the same zeroed border, the same
                        clamp. This is the golden model.
    filter_frame_naive  three nested loops. Obviously correct and unusably slow;
                        it exists so the vectorised version has something
                        independent to be tested against.
    filter_frame_opencv approximate, and labelled so. cvtColor and Sobel use
                        different coefficients, different rounding and a
                        replicated rather than zeroed border. It is what a
                        sensible person would actually write on the PS, which
                        makes it the honest thing to measure the accelerator
                        against.

Frames are (H, W, 4) uint8 in B,G,R,A order -- see HLS/src/video_filter.hpp for
why that byte order and not another. It is what both the MIPI camera and
OpenCV hand you, so nothing in this chapter ever has to reorder a channel.
"""
import numpy as np

# Must match HLS/src/video_filter.hpp.
MODE_GRAY = 0
MODE_SOBEL = 1
MODE_INVERT = 2
MODE_COLOR = 3

MODES = (MODE_GRAY, MODE_SOBEL, MODE_INVERT, MODE_COLOR)
MODE_NAMES = {MODE_GRAY: "gray", MODE_SOBEL: "sobel",
              MODE_INVERT: "invert", MODE_COLOR: "colour"}

# ITU-R BT.601 luma in Q8, ordered B,G,R to match the pixel layout.
LUMA_B = 29
LUMA_G = 150
LUMA_R = 77

# The line buffers in the PL are this deep. Software has no such limit, but it
# refuses anything the hardware could not do so the two stay comparable.
MAX_WIDTH = 1920


def _check(frame, mode):
    if not isinstance(frame, np.ndarray):
        raise ValueError("frame must be a NumPy array")
    if frame.dtype != np.uint8:
        raise ValueError(f"frame must be uint8, got {frame.dtype}")
    if frame.ndim != 3 or frame.shape[2] != 4:
        raise ValueError(f"frame must be (H, W, 4) BGRA, got {frame.shape}")
    if frame.shape[1] > MAX_WIDTH:
        raise ValueError(f"width {frame.shape[1]} exceeds MAX_WIDTH {MAX_WIDTH}")
    if mode not in MODES:
        raise ValueError(f"mode must be one of {MODES}, got {mode!r}")


def luma(frame):
    """BT.601 luma of a BGRA frame, as (H, W) int32. Alpha is ignored.

    The arithmetic is deliberately integer and deliberately truncating: this is
    what the hardware does, bit for bit. The weights sum to 256, so a white
    pixel comes out at exactly 255 and no clamp is needed.
    """
    b = frame[:, :, 0].astype(np.int32)
    g = frame[:, :, 1].astype(np.int32)
    r = frame[:, :, 2].astype(np.int32)
    return (LUMA_B * b + LUMA_G * g + LUMA_R * r) >> 8


def _sobel(y):
    """|Gx| + |Gy| of an (H, W) int32 luma plane, clamped, with a zero border.

    The border is zeroed rather than extended because a 3x3 window is simply
    not defined there, and inventing pixels to fill it would make the hardware
    and the software disagree about something neither of them knows.
    """
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


def _as_bgra(plane):
    """Replicate an (H, W) intensity plane into an opaque BGRA frame."""
    v = plane.astype(np.uint8)
    out = np.empty(plane.shape + (4,), dtype=np.uint8)
    out[:, :, 0] = v
    out[:, :, 1] = v
    out[:, :, 2] = v
    out[:, :, 3] = 255
    return out


def filter_frame(frame, mode):
    """The golden model. Bit-exact against all three PL implementations."""
    _check(frame, mode)
    if mode == MODE_COLOR:
        return frame.copy()
    y = luma(frame)
    if mode == MODE_GRAY:
        return _as_bgra(y)
    if mode == MODE_INVERT:
        return _as_bgra(255 - y)
    return _as_bgra(_sobel(y))


def filter_frame_naive(frame, mode):
    """The same thing written the obvious way, to check the fast one against."""
    _check(frame, mode)
    h, w = frame.shape[0], frame.shape[1]
    if mode == MODE_COLOR:
        return frame.copy()

    y = [[0] * w for _ in range(h)]
    for r in range(h):
        for c in range(w):
            b, g, rr = int(frame[r, c, 0]), int(frame[r, c, 1]), int(frame[r, c, 2])
            y[r][c] = (LUMA_B * b + LUMA_G * g + LUMA_R * rr) >> 8

    out = np.empty((h, w, 4), dtype=np.uint8)
    for r in range(h):
        for c in range(w):
            if mode == MODE_GRAY:
                v = y[r][c]
            elif mode == MODE_INVERT:
                v = 255 - y[r][c]
            elif r == 0 or r == h - 1 or c == 0 or c == w - 1:
                v = 0
            else:
                gx = ((y[r - 1][c + 1] + 2 * y[r][c + 1] + y[r + 1][c + 1])
                      - (y[r - 1][c - 1] + 2 * y[r][c - 1] + y[r + 1][c - 1]))
                gy = ((y[r + 1][c - 1] + 2 * y[r + 1][c] + y[r + 1][c + 1])
                      - (y[r - 1][c - 1] + 2 * y[r - 1][c] + y[r - 1][c + 1]))
                v = min(abs(gx) + abs(gy), 255)
            out[r, c, 0] = out[r, c, 1] = out[r, c, 2] = v
            out[r, c, 3] = 255
    return out


def filter_frame_opencv(frame, mode):
    """Approximate. Different coefficients, different rounding, different border.

    Included because it is the fastest filter available on the A53s, so it is
    what the accelerator has to beat to be worth building. It is not, and is not
    meant to be, bit-identical to `filter_frame`.
    """
    import cv2

    _check(frame, mode)
    if mode == MODE_COLOR:
        return frame.copy()

    gray = cv2.cvtColor(frame, cv2.COLOR_BGRA2GRAY)
    if mode == MODE_GRAY:
        plane = gray
    elif mode == MODE_INVERT:
        plane = cv2.bitwise_not(gray)
    else:
        gx = cv2.Sobel(gray, cv2.CV_16S, 1, 0, ksize=3)
        gy = cv2.Sobel(gray, cv2.CV_16S, 0, 1, ksize=3)
        plane = cv2.add(cv2.convertScaleAbs(gx), cv2.convertScaleAbs(gy))
    return cv2.cvtColor(plane, cv2.COLOR_GRAY2BGRA)
