"""Tests for the software reference filter.

These run on a laptop -- no board, no camera, no PYNQ. What they establish is
that sobel_ref.py implements the same filter the hardware does, which is what
makes it usable as the golden model the notebooks check the PL against.

    pytest -q test_sobel_ref.py
    python3 test_sobel_ref.py       # same tests, without pytest installed

The vectorised NumPy implementation is checked against a naive triple-loop one
written from the same specification but sharing none of its code. That is the
point of keeping both: the loops are obviously correct and unusably slow, the
array version is fast and easy to get subtly wrong.
"""
import numpy as np

import sobel_ref as ref


def _frame(h, w, seed=1):
    """A deterministic BGR frame with structure and noise.

    Structure so Sobel has real edges; noise so that neighbouring pixels always
    differ, because a filter that is one column out on a smooth gradient still
    looks almost right.
    """
    rng = np.random.default_rng(seed)
    f = rng.integers(0, 40, size=(h, w, 3), dtype=np.uint8)
    f[h//4:3*h//4, w//4:3*w//4] = 240
    return f


# --------------------------------------------------------------------------
# luma
# --------------------------------------------------------------------------

def test_luma_uses_hardware_q8_coefficients():
    # 77*R + 150*G + 29*B >> 8, on B,G,R -- the same integer arithmetic the RTL
    # does, not a float conversion rounded afterwards.
    frame = np.array([[[10, 20, 30]]], dtype=np.uint8)          # B, G, R
    expected = (77 * 30 + 150 * 20 + 29 * 10) >> 8
    assert ref.luma(frame)[0, 0] == expected


def test_luma_saturates_at_white_without_overflowing():
    frame = np.full((1, 1, 3), 255, dtype=np.uint8)
    assert ref.luma(frame)[0, 0] == 255


# --------------------------------------------------------------------------
# the pointwise modes
# --------------------------------------------------------------------------

def test_gray_replicates_luma_across_all_three_channels():
    frame = _frame(8, 8)
    out = ref.filter_frame(frame, ref.MODE_GRAY)
    y = ref.luma(frame)
    assert np.array_equal(out[:, :, 0], y)
    assert np.array_equal(out[:, :, 1], y)
    assert np.array_equal(out[:, :, 2], y)


def test_invert_is_255_minus_luma():
    frame = _frame(8, 8)
    out = ref.filter_frame(frame, ref.MODE_INVERT)
    assert np.array_equal(out[:, :, 0], 255 - ref.luma(frame))


def test_colour_mode_passes_the_frame_through_untouched():
    frame = _frame(8, 8)
    out = ref.filter_frame(frame, ref.MODE_COLOR)
    assert np.array_equal(out, frame)


def test_an_undefined_mode_falls_through_to_sobel():
    # The C tests == GRAY, == INVERT, == COLOR and treats everything else as
    # Sobel; the hardware compares the whole 32-bit word to match. The software
    # reference has to agree or it stops being a golden model.
    frame = _frame(8, 8)
    assert np.array_equal(ref.filter_frame(frame, 7),
                          ref.filter_frame(frame, ref.MODE_SOBEL))


# --------------------------------------------------------------------------
# sobel
# --------------------------------------------------------------------------

def test_sobel_leaves_a_black_one_pixel_border():
    out = ref.filter_frame(_frame(10, 12), ref.MODE_SOBEL)
    assert not out[0].any()
    assert not out[-1].any()
    assert not out[:, 0].any()
    assert not out[:, -1].any()


def test_sobel_finds_a_vertical_step_edge():
    # A step from 0 to 255 across a column: gx is 4*255 = 1020 at the edge,
    # gy is 0, and the sum saturates to 255.
    frame = np.zeros((5, 6, 3), dtype=np.uint8)
    frame[:, 3:] = 255
    out = ref.filter_frame(frame, ref.MODE_SOBEL)
    assert out[2, 2, 0] == 255
    assert out[2, 3, 0] == 255


def test_sobel_is_flat_on_a_flat_field():
    frame = np.full((6, 6, 3), 128, dtype=np.uint8)
    assert not ref.filter_frame(frame, ref.MODE_SOBEL).any()


def test_sobel_saturates_rather_than_wrapping():
    # Wrapping would turn the brightest edges black, which is the classic
    # 8-bit Sobel bug and looks like an outline drawn in the wrong colour.
    frame = np.zeros((5, 6, 3), dtype=np.uint8)
    frame[:, 3:] = 255
    out = ref.filter_frame(frame, ref.MODE_SOBEL)
    assert out.max() == 255


# --------------------------------------------------------------------------
# the two implementations must agree
# --------------------------------------------------------------------------

def test_vectorised_matches_naive_on_every_mode():
    frame = _frame(9, 10, seed=7)
    for mode in (ref.MODE_GRAY, ref.MODE_SOBEL, ref.MODE_INVERT, ref.MODE_COLOR):
        assert np.array_equal(ref.filter_frame(frame, mode),
                              ref.filter_frame_naive(frame, mode)), f"mode {mode}"


def test_vectorised_matches_naive_on_awkward_shapes():
    # Degenerate geometries break a window filter long before a real frame
    # does: one line means every output row is a border row.
    for h, w in ((1, 8), (2, 2), (3, 16), (5, 6), (16, 2)):
        frame = _frame(h, w, seed=h * 100 + w)
        assert np.array_equal(ref.filter_frame(frame, ref.MODE_SOBEL),
                              ref.filter_frame_naive(frame, ref.MODE_SOBEL)), f"{w}x{h}"


# --------------------------------------------------------------------------
# the hardware contract
# --------------------------------------------------------------------------

def test_odd_width_is_rejected():
    # Two pixels per beat: an odd width has no representation on the bus, and
    # the hardware drains such a frame rather than filtering it. The reference
    # says so out loud rather than quietly producing a picture the PL will
    # never match.
    try:
        ref.filter_frame(_frame(4, 5), ref.MODE_SOBEL)
    except ValueError:
        return
    raise AssertionError("an odd width should raise ValueError")


def test_output_is_uint8_and_the_same_shape():
    frame = _frame(6, 8)
    out = ref.filter_frame(frame, ref.MODE_SOBEL)
    assert out.dtype == np.uint8
    assert out.shape == frame.shape


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  PASS  {name}")
            except Exception as exc:                       # noqa: BLE001
                failures += 1
                print(f"  FAIL  {name}: {exc}")
    print("TEST PASSED" if failures == 0 else f"TEST FAILED -- {failures} failures")
    raise SystemExit(1 if failures else 0)
