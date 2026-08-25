"""The software reference for the CH12 video filter.

This is the same filter as the hardware, written three ways, and the point of
each is different:

  filter_frame        vectorised NumPy. Bit-exact against the PL, and fast
                      enough to check a real frame with. This is what the
                      notebooks compare the accelerator's output against.
  filter_frame_naive  the same thing as three nested loops. Obviously correct
                      and unusably slow -- it exists so the vectorised version
                      has something independent to be tested against, and so
                      the algorithm is readable somewhere.
  filter_frame_opencv approximate. OpenCV's cvtColor and Sobel do not use the
                      same coefficients, rounding or border handling, so this
                      does NOT match the hardware pixel for pixel. It is here
                      because it is what a sensible person would actually write
                      in software, which makes it the honest thing to measure
                      the accelerator against.

Frames are (H, W, 3) uint8 in B,G,R channel order -- exactly what
mipi.readframe() hands back from PYNQ, and exactly what the 48-bit video stream
carries inside the PL.

Everything here is integer arithmetic in the same Q8 fixed point the RTL uses.
Converting to float and rounding at the end gives a picture that looks the same
and is off by one in a few thousand pixels, which is enough to make a bit-exact
comparison against the PL useless.
"""
import numpy as np

MODE_GRAY   = 0   # BGR -> luma, replicated back across all three channels
MODE_SOBEL  = 1   # BGR -> luma -> Sobel magnitude, black one-pixel border
MODE_INVERT = 2   # BGR -> luma -> 255 - luma
MODE_COLOR  = 3   # raw camera, untouched

MODE_NAMES = {
    MODE_GRAY:   "grayscale",
    MODE_SOBEL:  "sobel",
    MODE_INVERT: "inverted",
    MODE_COLOR:  "colour",
}


def _check(frame):
    if frame.ndim != 3 or frame.shape[2] != 3:
        raise ValueError(f"expected an (H, W, 3) BGR frame, got {frame.shape}")
    if frame.dtype != np.uint8:
        raise ValueError(f"expected uint8, got {frame.dtype}")
    # Two pixels per beat on the video bus, so the hardware cannot express an
    # odd width and drains such a frame instead of filtering it. Refusing here
    # keeps the reference honest about what the PL will actually do.
    if frame.shape[1] % 2:
        raise ValueError(f"width must be even, got {frame.shape[1]}")


def luma(frame):
    """BT.601 luma, Q8: (77*R + 150*G + 29*B) >> 8."""
    b = frame[:, :, 0].astype(np.uint32)
    g = frame[:, :, 1].astype(np.uint32)
    r = frame[:, :, 2].astype(np.uint32)
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)


def _grey_to_bgr(y):
    return np.repeat(y[:, :, np.newaxis], 3, axis=2)


def sobel_magnitude(y):
    """|gx| + |gy| over a 3x3 window, saturated to 8 bits, black border.

    Interior pixels only: the one-pixel frame around the edge has no window and
    the hardware emits black there, so this does too.
    """
    h, w = y.shape
    out = np.zeros((h, w), dtype=np.uint8)
    if h < 3 or w < 3:
        return out

    p = y.astype(np.int32)
    p00, p01, p02 = p[0:h-2, 0:w-2], p[0:h-2, 1:w-1], p[0:h-2, 2:w]
    p10,      p12 = p[1:h-1, 0:w-2],                  p[1:h-1, 2:w]
    p20, p21, p22 = p[2:h,   0:w-2], p[2:h,   1:w-1], p[2:h,   2:w]

    gx = (p02 + 2 * p12 + p22) - (p00 + 2 * p10 + p20)
    gy = (p20 + 2 * p21 + p22) - (p00 + 2 * p01 + p02)
    mag = np.abs(gx) + np.abs(gy)

    out[1:h-1, 1:w-1] = np.minimum(mag, 255).astype(np.uint8)
    return out


def filter_frame(frame, mode):
    """Apply the filter the way the PL does. Returns a new (H, W, 3) frame."""
    _check(frame)
    if mode == MODE_COLOR:
        return frame.copy()
    y = luma(frame)
    if mode == MODE_GRAY:
        return _grey_to_bgr(y)
    if mode == MODE_INVERT:
        return _grey_to_bgr((255 - y).astype(np.uint8))
    # Sobel, and anything that is not one of the three above -- the C tests the
    # three by equality and falls through, so mode 7 is Sobel.
    return _grey_to_bgr(sobel_magnitude(y))


def filter_frame_naive(frame, mode):
    """The same filter as three nested loops, for testing filter_frame."""
    _check(frame)
    h, w, _ = frame.shape
    if mode == MODE_COLOR:
        return frame.copy()

    y = [[0] * w for _ in range(h)]
    for r in range(h):
        for c in range(w):
            b, g, rr = (int(v) for v in frame[r, c])
            y[r][c] = (77 * rr + 150 * g + 29 * b) >> 8

    out = np.zeros((h, w, 3), dtype=np.uint8)
    for r in range(h):
        for c in range(w):
            if mode == MODE_GRAY:
                v = y[r][c]
            elif mode == MODE_INVERT:
                v = 255 - y[r][c]
            elif r == 0 or r == h - 1 or c == 0 or c == w - 1:
                v = 0
            else:
                gx = ((y[r-1][c+1] + 2*y[r][c+1] + y[r+1][c+1]) -
                      (y[r-1][c-1] + 2*y[r][c-1] + y[r+1][c-1]))
                gy = ((y[r+1][c-1] + 2*y[r+1][c] + y[r+1][c+1]) -
                      (y[r-1][c-1] + 2*y[r-1][c] + y[r-1][c+1]))
                v = min(abs(gx) + abs(gy), 255)
            out[r, c] = (v, v, v)
    return out


def filter_frame_opencv(frame, mode):
    """What you would write if you were not trying to match the hardware.

    APPROXIMATE. cv2.cvtColor's BGR2GRAY uses different coefficients and
    rounding, and cv2.Sobel extends the border rather than blacking it out, so
    this differs from the PL in the last bit of most pixels and in the whole
    frame edge. Use it for timing, not for checking.
    """
    import cv2                                     # only needed for this path

    _check(frame)
    if mode == MODE_COLOR:
        return frame.copy()
    y = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    if mode == MODE_GRAY:
        out = y
    elif mode == MODE_INVERT:
        out = 255 - y
    else:
        gx = cv2.Sobel(y, cv2.CV_16S, 1, 0, ksize=3)
        gy = cv2.Sobel(y, cv2.CV_16S, 0, 1, ksize=3)
        out = cv2.add(cv2.convertScaleAbs(gx), cv2.convertScaleAbs(gy))
    return cv2.cvtColor(out, cv2.COLOR_GRAY2BGR)


def compare(a, b):
    """How many pixels differ, and by how much. For notebook output."""
    if a.shape != b.shape:
        raise ValueError(f"shape mismatch: {a.shape} vs {b.shape}")
    diff = np.abs(a.astype(np.int16) - b.astype(np.int16))
    return int((diff != 0).sum()), int(diff.max())
