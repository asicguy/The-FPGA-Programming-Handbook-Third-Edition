#!/usr/bin/env python3
"""Frames to feed the filter: a synthetic one, and one out of a video file.

Two sources, deliberately interchangeable with the camera:

    test_pattern / make_test_clip   deterministic frames, computed from the
                                    frame index alone. Nothing random, nothing
                                    read from disk -- so a hardware-against-
                                    software comparison over this clip has an
                                    exact expected answer, and that answer is
                                    zero differing samples.
    read_clip                       frames out of any file OpenCV can open,
                                    letterboxed to the size you ask for.

Both hand back (H, W, 4) uint8 BGRA -- the same layout `pixel_pack` produces on
the camera path, so the filter cannot tell which source it is looking at.

Why a generated clip at all: with a real video (or a camera) there is no way to
say what *should* have come out, so a comparison against the software reference
can only ever be approximate. A deterministic pattern turns that into a pass or
a fail.
"""
import os

import numpy as np

MIN_SIZE = 8
MAX_WIDTH = 1920


def _check_size(width, height):
    if width < MIN_SIZE or height < MIN_SIZE:
        raise ValueError(f"clip must be at least {MIN_SIZE}x{MIN_SIZE}, "
                         f"got {width}x{height}")
    if width > MAX_WIDTH:
        raise ValueError(f"width {width} exceeds MAX_WIDTH {MAX_WIDTH}")


def test_pattern(width, height, index):
    """One frame of the deterministic clip, a pure function of the index.

    The frame carries four things on purpose:

      - a two-axis colour gradient, so every channel is exercised and a swapped
        R and B is visible at a glance;
      - three hard-edged vertical bars, so Sobel has something to find and a
        line buffer that is one row stale shows up as a smeared edge;
      - a square that moves with the index, so a repeated or dropped frame is
        visible in motion rather than only in a checksum;
      - the frame index packed into the top-left pixel, so it is visible in a
        checksum too. That pixel is on the frame border, where Sobel is zero by
        definition, so it never perturbs the bit-exact comparison.
    """
    _check_size(width, height)
    if index < 0:
        raise ValueError(f"frame index must be >= 0, got {index}")

    frame = np.empty((height, width, 4), dtype=np.uint8)
    xs = (np.arange(width) * 255 // max(width - 1, 1)).astype(np.uint8)
    ys = (np.arange(height) * 255 // max(height - 1, 1)).astype(np.uint8)
    frame[:, :, 0] = xs[None, :]          # blue  ramps left to right
    frame[:, :, 1] = ys[:, None]          # green ramps top to bottom
    frame[:, :, 2] = 64                   # red   flat, so a B/R swap is obvious
    frame[:, :, 3] = 255

    bar = max(width // 16, 1)
    for n, channel in enumerate((0, 1, 2)):
        x0 = (width * (n + 1)) // 4
        frame[:, x0:x0 + bar, :3] = 0
        frame[:, x0:x0 + bar, channel] = 255

    side = max(width // 8, 2)
    span = max(width - side, 1)
    x0 = (index * max(side // 2, 1)) % span
    y0 = (height - side) // 2
    frame[y0:y0 + side, x0:x0 + side, :3] = 255

    frame[0, 0, 0] = index & 0xFF
    frame[0, 0, 1] = (index >> 8) & 0xFF
    frame[0, 0, 2] = (index >> 16) & 0xFF
    return frame


def frame_index_of(frame):
    """Recover the index `test_pattern` packed into the top-left pixel."""
    return (int(frame[0, 0, 0])
            | (int(frame[0, 0, 1]) << 8)
            | (int(frame[0, 0, 2]) << 16))


def make_test_clip(width, height, frames):
    """Yield `frames` consecutive test-pattern frames."""
    if frames < 1:
        raise ValueError(f"clip must have at least one frame, got {frames}")
    for i in range(frames):
        yield test_pattern(width, height, i)


def to_bgra(frame):
    """Add an opaque alpha channel to a BGR frame; pass BGRA through."""
    if frame.ndim != 3 or frame.shape[2] not in (3, 4):
        raise ValueError(f"frame must be (H, W, 3) or (H, W, 4), got {frame.shape}")
    if frame.shape[2] == 4:
        return frame
    out = np.empty(frame.shape[:2] + (4,), dtype=np.uint8)
    out[:, :, :3] = frame
    out[:, :, 3] = 255
    return out


def letterbox(frame, width, height):
    """Scale a BGR frame into width x height, preserving aspect, padding black.

    Cropping would be the other option. Padding is the right one here because
    the filter's border handling is part of what is under test, and cropping
    would quietly change which pixels land on the frame edge.
    """
    import cv2

    if width < 1 or height < 1:
        raise ValueError(f"target must be at least 1x1, got {width}x{height}")
    sh, sw = frame.shape[:2]
    scale = min(width / sw, height / sh)
    nw, nh = max(int(round(sw * scale)), 1), max(int(round(sh * scale)), 1)
    resized = cv2.resize(frame, (nw, nh), interpolation=cv2.INTER_AREA)
    out = np.zeros((height, width, frame.shape[2]), dtype=np.uint8)
    x0, y0 = (width - nw) // 2, (height - nh) // 2
    out[y0:y0 + nh, x0:x0 + nw] = resized
    return out


def _fourcc_for(path):
    import cv2

    ext = os.path.splitext(path)[1].lower()
    # MJPG in an AVI container is the one combination that is present in every
    # OpenCV build we care about, including the one on the PYNQ image.
    return cv2.VideoWriter_fourcc(*("mp4v" if ext == ".mp4" else "MJPG"))


def write_clip(path, frames, fps=30):
    """Write BGRA frames to a video file, so a notebook can embed the result."""
    import cv2

    frames = iter(frames)
    try:
        first = next(frames)
    except StopIteration:
        raise ValueError("nothing to write: the frame sequence is empty") from None

    h, w = first.shape[:2]
    writer = cv2.VideoWriter(path, _fourcc_for(path), fps, (w, h))
    if not writer.isOpened():
        raise RuntimeError(f"OpenCV could not open {path} for writing")
    try:
        writer.write(np.ascontiguousarray(first[:, :, :3]))
        for frame in frames:
            writer.write(np.ascontiguousarray(frame[:, :, :3]))
    finally:
        writer.release()
    return path


def read_clip(path, width, height, max_frames=None, loop=False):
    """Yield BGRA frames from a video file, letterboxed to width x height."""
    import cv2

    if not os.path.exists(path):
        raise FileNotFoundError(path)

    emitted = 0
    while True:
        cap = cv2.VideoCapture(path)
        if not cap.isOpened():
            raise RuntimeError(f"OpenCV could not open {path}")
        got_any = False
        try:
            while max_frames is None or emitted < max_frames:
                ok, frame = cap.read()
                if not ok:
                    break
                got_any = True
                emitted += 1
                yield to_bgra(letterbox(frame, width, height))
        finally:
            cap.release()
        if not loop or not got_any:
            return
        if max_frames is not None and emitted >= max_frames:
            return
