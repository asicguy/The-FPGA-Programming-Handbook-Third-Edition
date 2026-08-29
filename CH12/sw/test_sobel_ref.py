#!/usr/bin/env python3
"""Tests for the CH12 software reference.

Run with any interpreter that has NumPy:

    python3 test_sobel_ref.py

`filter_frame` is the golden model -- the thing the RTL, the HLS kernel and the
board are all checked against -- so it is tested against `filter_frame_naive`,
which is written to be obviously correct rather than fast. Testing the fast one
against itself would prove nothing.
"""
import unittest

import numpy as np

import sobel_ref as ref


def frame(bgr_rows, alpha=255):
    """Build an (H,W,4) uint8 BGRA frame from a nested list of (B,G,R)."""
    a = np.array(bgr_rows, dtype=np.uint8)
    h, w, _ = a.shape
    out = np.empty((h, w, 4), dtype=np.uint8)
    out[:, :, :3] = a
    out[:, :, 3] = alpha
    return out


def random_frame(w, h, seed=7):
    rng = np.random.default_rng(seed)
    f = rng.integers(0, 256, size=(h, w, 4), dtype=np.uint8)
    f[:, :, 3] = 255
    return f


def solid(w, h, bgr, alpha=255):
    f = np.empty((h, w, 4), dtype=np.uint8)
    f[:, :, 0], f[:, :, 1], f[:, :, 2] = bgr
    f[:, :, 3] = alpha
    return f


# --------------------------------------------------------------------- luma
class LumaTest(unittest.TestCase):
    def test_pure_blue_weighs_29(self):
        self.assertEqual(ref.luma(solid(1, 1, (255, 0, 0)))[0, 0], (29 * 255) >> 8)

    def test_pure_green_weighs_150(self):
        self.assertEqual(ref.luma(solid(1, 1, (0, 255, 0)))[0, 0], (150 * 255) >> 8)

    def test_pure_red_weighs_77(self):
        self.assertEqual(ref.luma(solid(1, 1, (0, 0, 255)))[0, 0], (77 * 255) >> 8)

    def test_white_saturates_to_255(self):
        self.assertEqual(ref.luma(solid(1, 1, (255, 255, 255)))[0, 0], 255)

    def test_black_is_zero(self):
        self.assertEqual(ref.luma(solid(1, 1, (0, 0, 0)))[0, 0], 0)

    def test_ignores_the_alpha_channel(self):
        opaque = ref.luma(solid(4, 4, (10, 20, 30), alpha=255))
        clear = ref.luma(solid(4, 4, (10, 20, 30), alpha=0))
        np.testing.assert_array_equal(opaque, clear)


# --------------------------------------------------------------------- gray
class GrayTest(unittest.TestCase):
    def test_replicates_luma_across_all_three_colour_channels(self):
        out = ref.filter_frame(random_frame(8, 6), ref.MODE_GRAY)
        np.testing.assert_array_equal(out[:, :, 0], out[:, :, 2])

    def test_writes_luma_into_the_colour_channels(self):
        f = random_frame(8, 6)
        out = ref.filter_frame(f, ref.MODE_GRAY)
        np.testing.assert_array_equal(out[:, :, 1], ref.luma(f).astype(np.uint8))

    def test_forces_alpha_opaque(self):
        out = ref.filter_frame(random_frame(8, 6), ref.MODE_GRAY)
        self.assertTrue(np.all(out[:, :, 3] == 255))

    def test_matches_the_naive_implementation(self):
        f = random_frame(23, 17, seed=1)
        np.testing.assert_array_equal(ref.filter_frame(f, ref.MODE_GRAY),
                                      ref.filter_frame_naive(f, ref.MODE_GRAY))


# ------------------------------------------------------------------- invert
class InvertTest(unittest.TestCase):
    def test_is_255_minus_the_gray_result(self):
        f = random_frame(8, 6)
        gray = ref.filter_frame(f, ref.MODE_GRAY)
        inv = ref.filter_frame(f, ref.MODE_INVERT)
        np.testing.assert_array_equal(inv[:, :, :3], 255 - gray[:, :, :3])

    def test_matches_the_naive_implementation(self):
        f = random_frame(23, 17, seed=2)
        np.testing.assert_array_equal(ref.filter_frame(f, ref.MODE_INVERT),
                                      ref.filter_frame_naive(f, ref.MODE_INVERT))


# -------------------------------------------------------------------- sobel
class SobelTest(unittest.TestCase):
    def test_zeroes_the_frame_border(self):
        out = ref.filter_frame(random_frame(9, 7), ref.MODE_SOBEL)[:, :, 1]
        border = np.concatenate([out[0, :], out[-1, :], out[:, 0], out[:, -1]])
        self.assertTrue(np.all(border == 0))

    def test_is_black_on_a_uniform_frame(self):
        out = ref.filter_frame(solid(9, 7, (40, 90, 200)), ref.MODE_SOBEL)
        self.assertTrue(np.all(out[:, :, :3] == 0))

    def test_clamps_a_hard_edge_to_255(self):
        f = np.zeros((5, 5, 4), dtype=np.uint8)
        f[:, 3:, :3] = 255
        f[:, :, 3] = 255
        self.assertEqual(ref.filter_frame(f, ref.MODE_SOBEL)[2, 2, 1], 255)

    def test_matches_the_naive_implementation(self):
        f = random_frame(23, 17, seed=3)
        np.testing.assert_array_equal(ref.filter_frame(f, ref.MODE_SOBEL),
                                      ref.filter_frame_naive(f, ref.MODE_SOBEL))

    def test_matches_the_naive_implementation_on_an_even_size(self):
        f = random_frame(16, 12, seed=4)
        np.testing.assert_array_equal(ref.filter_frame(f, ref.MODE_SOBEL),
                                      ref.filter_frame_naive(f, ref.MODE_SOBEL))

    def test_forces_alpha_opaque(self):
        out = ref.filter_frame(random_frame(9, 7), ref.MODE_SOBEL)
        self.assertTrue(np.all(out[:, :, 3] == 255))


# ---------------------------------------------------- degenerate geometries
# A 3x3 window has no interior on any of these, so Sobel owes an all-black
# frame -- not a crash and not a short frame. These are the sizes that catch
# an iteration space that is off by one.
class DegenerateSizeTest(unittest.TestCase):
    def test_single_pixel_frame_is_black(self):
        out = ref.filter_frame(random_frame(1, 1), ref.MODE_SOBEL)
        self.assertTrue(np.all(out[:, :, :3] == 0))

    def test_single_row_frame_is_black(self):
        out = ref.filter_frame(random_frame(16, 1), ref.MODE_SOBEL)
        self.assertTrue(np.all(out[:, :, :3] == 0))

    def test_single_column_frame_is_black(self):
        out = ref.filter_frame(random_frame(1, 16), ref.MODE_SOBEL)
        self.assertTrue(np.all(out[:, :, :3] == 0))

    def test_two_by_two_frame_is_black(self):
        out = ref.filter_frame(random_frame(2, 2), ref.MODE_SOBEL)
        self.assertTrue(np.all(out[:, :, :3] == 0))

    def test_three_by_three_frame_has_exactly_one_lit_pixel_position(self):
        f = np.zeros((3, 3, 4), dtype=np.uint8)
        f[:, 2, :3] = 255
        f[:, :, 3] = 255
        out = ref.filter_frame(f, ref.MODE_SOBEL)[:, :, 1]
        self.assertEqual(np.count_nonzero(out), 1)

    def test_preserves_frame_shape(self):
        out = ref.filter_frame(random_frame(16, 1), ref.MODE_SOBEL)
        self.assertEqual(out.shape, (1, 16, 4))


# -------------------------------------------------------------------- color
class ColorPassthroughTest(unittest.TestCase):
    def test_returns_the_input_unchanged(self):
        f = random_frame(8, 6, seed=5)
        np.testing.assert_array_equal(ref.filter_frame(f, ref.MODE_COLOR), f)

    def test_preserves_a_non_opaque_alpha_channel(self):
        f = solid(4, 4, (10, 20, 30), alpha=7)
        self.assertTrue(np.all(ref.filter_frame(f, ref.MODE_COLOR)[:, :, 3] == 7))

    def test_matches_the_naive_implementation(self):
        f = random_frame(9, 7, seed=6)
        np.testing.assert_array_equal(ref.filter_frame(f, ref.MODE_COLOR),
                                      ref.filter_frame_naive(f, ref.MODE_COLOR))


# ------------------------------------------------------------- input checks
class InputValidationTest(unittest.TestCase):
    def test_rejects_a_three_channel_frame(self):
        with self.assertRaises(ValueError):
            ref.filter_frame(np.zeros((4, 4, 3), dtype=np.uint8), ref.MODE_GRAY)

    def test_rejects_a_two_dimensional_frame(self):
        with self.assertRaises(ValueError):
            ref.filter_frame(np.zeros((4, 4), dtype=np.uint8), ref.MODE_GRAY)

    def test_rejects_a_non_uint8_frame(self):
        with self.assertRaises(ValueError):
            ref.filter_frame(np.zeros((4, 4, 4), dtype=np.float32), ref.MODE_GRAY)

    def test_rejects_an_unknown_mode(self):
        with self.assertRaises(ValueError):
            ref.filter_frame(random_frame(4, 4), 4)

    def test_rejects_a_frame_wider_than_the_line_buffers(self):
        with self.assertRaises(ValueError):
            ref.filter_frame(np.zeros((2, ref.MAX_WIDTH + 1, 4), dtype=np.uint8),
                             ref.MODE_SOBEL)

    def test_does_not_modify_its_input(self):
        f = random_frame(8, 6, seed=8)
        before = f.copy()
        ref.filter_frame(f, ref.MODE_SOBEL)
        np.testing.assert_array_equal(f, before)


# ------------------------------------------------------------------- opencv
# Labelled approximate on purpose: cvtColor and Sobel use different
# coefficients, different rounding and a replicated rather than zeroed border,
# so it does NOT match the golden model. It is here because it is the fastest
# thing a competent engineer would reach for on the PS, which makes it the
# honest thing to time the accelerator against.
class OpenCVReferenceTest(unittest.TestCase):
    def setUp(self):
        try:
            import cv2  # noqa: F401
        except ImportError:
            self.skipTest("OpenCV not installed")

    def test_gray_is_within_two_counts_of_the_golden_model(self):
        f = random_frame(32, 24, seed=9)
        a = ref.filter_frame(f, ref.MODE_GRAY)[:, :, 1].astype(np.int16)
        b = ref.filter_frame_opencv(f, ref.MODE_GRAY)[:, :, 1].astype(np.int16)
        self.assertLessEqual(int(np.abs(a - b).max()), 2)

    def test_sobel_agrees_on_a_hard_edge_away_from_the_border(self):
        f = np.zeros((16, 16, 4), dtype=np.uint8)
        f[:, 8:, :3] = 255
        f[:, :, 3] = 255
        self.assertEqual(ref.filter_frame_opencv(f, ref.MODE_SOBEL)[8, 8, 1], 255)

    def test_color_passthrough_is_exact(self):
        f = random_frame(8, 6, seed=10)
        np.testing.assert_array_equal(ref.filter_frame_opencv(f, ref.MODE_COLOR), f)


if __name__ == "__main__":
    unittest.main(verbosity=2)
