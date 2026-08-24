#!/usr/bin/env python3
"""Compare PS (Cortex-A53) implementations of the CH11 filters against the PL.

Every software variant computes exactly the algorithm the kernel implements:
BT.601 luma in Q8 (77/150/29 >> 8), Sobel |Gx|+|Gy| clamped with a zero border,
and 255-luma for invert. The NumPy version is checked bit-exact against the
same golden model used by csim, so the comparison is like for like.

OpenCV is the exception and is labelled as such: cvtColor and Sobel use
different coefficients, rounding and border handling, so it is doing
approximately -- not exactly -- the same work. It is included because it is the
fastest thing a competent engineer would reach for on the PS.
"""
import sys, time
import numpy as np
import cv2
from pynq import Overlay, allocate

BIT = "/home/xilinx/ch11_hil/hls/image_filter.bit"
REPS = 5
SIZES = [(640, 480), (1920, 1080)]


def make_img(W, H):
    rng = np.random.default_rng(7)
    img = rng.integers(0, 256, size=(H, W, 4), dtype=np.uint8)
    img[:, :, 3] = 255
    img[H // 4:3 * H // 4, W // 4:3 * W // 4, :3] = 240
    return img


# ---------------------------------------------------------------- golden/NumPy
def numpy_filter(rgba, mode):
    R = rgba[:, :, 0].astype(np.int32)
    G = rgba[:, :, 1].astype(np.int32)
    B = rgba[:, :, 2].astype(np.int32)
    gray = ((77 * R + 150 * G + 29 * B) >> 8).astype(np.int32)
    if mode == 0:
        o = gray
    elif mode == 2:
        o = 255 - gray
    else:
        o = np.zeros_like(gray)
        p = gray
        gx = (p[:-2, 2:] + 2 * p[1:-1, 2:] + p[2:, 2:]) - \
             (p[:-2, :-2] + 2 * p[1:-1, :-2] + p[2:, :-2])
        gy = (p[2:, :-2] + 2 * p[2:, 1:-1] + p[2:, 2:]) - \
             (p[:-2, :-2] + 2 * p[:-2, 1:-1] + p[:-2, 2:])
        o[1:-1, 1:-1] = np.clip(np.abs(gx) + np.abs(gy), 0, 255)
    o = o.astype(np.uint8)
    return np.dstack([o, o, o, np.full(o.shape, 255, np.uint8)])


# ------------------------------------------------------------- pure Python
def python_filter(rgba, mode):
    H, W = rgba.shape[0], rgba.shape[1]
    src = rgba.tolist()
    gray = [[0] * W for _ in range(H)]
    for r in range(H):
        row = src[r]
        g = gray[r]
        for c in range(W):
            px = row[c]
            g[c] = (77 * px[0] + 150 * px[1] + 29 * px[2]) >> 8
    out = [[0] * W for _ in range(H)]
    if mode == 0:
        out = gray
    elif mode == 2:
        for r in range(H):
            for c in range(W):
                out[r][c] = 255 - gray[r][c]
    else:
        for r in range(1, H - 1):
            for c in range(1, W - 1):
                gx = (gray[r-1][c+1] + 2*gray[r][c+1] + gray[r+1][c+1]) - \
                     (gray[r-1][c-1] + 2*gray[r][c-1] + gray[r+1][c-1])
                gy = (gray[r+1][c-1] + 2*gray[r+1][c] + gray[r+1][c+1]) - \
                     (gray[r-1][c-1] + 2*gray[r-1][c] + gray[r-1][c+1])
                m = abs(gx) + abs(gy)
                out[r][c] = 255 if m > 255 else m
    return out


# ------------------------------------------------------------------ OpenCV
def opencv_filter(bgr, mode):
    gray = cv2.cvtColor(bgr, cv2.COLOR_RGB2GRAY)
    if mode == 0:
        return gray
    if mode == 2:
        return cv2.bitwise_not(gray)
    gx = cv2.Sobel(gray, cv2.CV_16S, 1, 0, ksize=3)
    gy = cv2.Sobel(gray, cv2.CV_16S, 0, 1, ksize=3)
    return cv2.convertScaleAbs(cv2.add(cv2.convertScaleAbs(gx),
                                       cv2.convertScaleAbs(gy)))


def bench(fn, reps=REPS):
    ts = []
    fn()                                    # warm up
    for _ in range(reps):
        t0 = time.perf_counter()
        fn()
        ts.append(time.perf_counter() - t0)
    return min(ts), sorted(ts)[len(ts) // 2]


print("=" * 78)
print(f"PS: 4x Cortex-A53 @1.2GHz   |   OpenCV threads: {cv2.getNumThreads()}")
print("=" * 78)

ol = Overlay(BIT)
filt = ol.image_filter_0

for (W, H) in SIZES:
    img = make_img(W, H)
    rgb = np.ascontiguousarray(img[:, :, :3])

    src = allocate(shape=(H, W, 4), dtype=np.uint8)
    dst = allocate(shape=(H, W, 4), dtype=np.uint8)
    src[:] = img

    def pl_compute(mode):
        rm = filt.register_map
        sp, dp = src.physical_address, dst.physical_address
        rm.src_1 = sp & 0xFFFFFFFF; rm.src_2 = (sp >> 32) & 0xFFFFFFFF
        rm.dst_1 = dp & 0xFFFFFFFF; rm.dst_2 = (dp >> 32) & 0xFFFFFFFF
        rm.img_width = W; rm.img_height = H; rm.mode = mode
        rm.CTRL.AP_START = 1
        while rm.CTRL.AP_DONE == 0:
            pass

    def pl_full(mode):
        src.flush()
        pl_compute(mode)
        dst.invalidate()

    print()
    print(f"### {W}x{H}  ({W*H/1e6:.2f} Mpixel)")
    print(f"{'variant':<26}{'best ms':>10}{'median ms':>11}{'Mpix/s':>10}{'vs PL':>9}")
    print("-" * 78)

    # PL reference first
    pl_c = {}
    for mode, name in ((0, "GRAY"), (1, "SOBEL"), (2, "INVERT")):
        pl_c[mode] = bench(lambda m=mode: pl_compute(m))[0]
    pl_f = bench(lambda: pl_full(1))[0]
    ref = pl_c[1]

    rows = []
    rows.append(("PL  compute only (sobel)", pl_c[1]))
    rows.append(("PL  + cache flush/inval", pl_f))
    for mode, name in ((0, "GRAY"), (2, "INVERT")):
        rows.append((f"PL  compute only ({name.lower()})", pl_c[mode]))

    # verify NumPy is bit-exact against the PL before timing it
    src.flush(); pl_compute(1); dst.invalidate()
    ok = np.array_equal(np.array(dst), numpy_filter(img, 1))
    rows.append((f"NumPy sobel  [exact={ok}]", bench(lambda: numpy_filter(img, 1))[0]))
    rows.append(("NumPy gray", bench(lambda: numpy_filter(img, 0))[0]))
    rows.append(("OpenCV sobel  [approx]", bench(lambda: opencv_filter(rgb, 1))[0]))
    rows.append(("OpenCV gray   [approx]", bench(lambda: opencv_filter(rgb, 0))[0]))

    cv2.setNumThreads(1)
    rows.append(("OpenCV sobel 1-thread", bench(lambda: opencv_filter(rgb, 1))[0]))
    cv2.setNumThreads(0)

    for label, t in rows:
        print(f"{label:<26}{t*1e3:>10.2f}{'':>11}{W*H/t/1e6:>10.1f}"
              f"{t/ref:>8.1f}x")

    # pure Python only where it will not take all day
    if W * H <= 320 * 240:
        t = bench(lambda: python_filter(img, 1), reps=1)[0]
        print(f"{'pure Python sobel':<26}{t*1e3:>10.1f}{'':>11}{W*H/t/1e6:>10.3f}"
              f"{t/ref:>8.0f}x")
    else:
        print(f"{'pure Python sobel':<26}{'skipped (minutes)':>21}")

    src.freebuffer(); dst.freebuffer()

print()
print("=" * 78)
