#!/usr/bin/env python3
"""Tests for the CH12 frame sources.

    python3 test_video_clip.py

Nothing here needs a board or a camera. The tests that need a video file make
one first; the tests that need OpenCV skip cleanly without it.
"""
import os
import tempfile
import unittest

import numpy as np

import sobel_ref as ref
import video_clip as vc


def has_cv2():
    try:
        import cv2  # noqa: F401
        return True
    except ImportError:
        return False


# ------------------------------------------------------------- test pattern
class TestPatternTest(unittest.TestCase):
    def test_has_the_requested_shape(self):
        self.assertEqual(vc.test_pattern(64, 48, 0).shape, (48, 64, 4))

    def test_is_uint8(self):
        self.assertEqual(vc.test_pattern(64, 48, 0).dtype, np.uint8)

    def test_is_opaque(self):
        self.assertTrue(np.all(vc.test_pattern(64, 48, 0)[:, :, 3] == 255))

    def test_is_deterministic_for_a_given_index(self):
        np.testing.assert_array_equal(vc.test_pattern(64, 48, 3),
                                      vc.test_pattern(64, 48, 3))

    def test_moves_between_consecutive_indices(self):
        a = vc.test_pattern(64, 48, 3)
        b = vc.test_pattern(64, 48, 4)
        self.assertTrue(np.any(a != b))

    def test_contains_edges_for_sobel_to_find(self):
        out = ref.filter_frame(vc.test_pattern(64, 48, 0), ref.MODE_SOBEL)
        self.assertGreater(np.count_nonzero(out[:, :, 1]), 0)

    def test_uses_all_three_colour_channels(self):
        f = vc.test_pattern(64, 48, 0)
        for ch in range(3):
            self.assertGreater(int(f[:, :, ch].max()), 0, f"channel {ch} is dark")

    def test_encodes_the_frame_index_in_the_top_left_pixel(self):
        self.assertEqual(vc.frame_index_of(vc.test_pattern(64, 48, 37)), 37)

    def test_rejects_a_width_below_the_minimum(self):
        with self.assertRaises(ValueError):
            vc.test_pattern(0, 48, 0)

    def test_rejects_a_height_below_the_minimum(self):
        with self.assertRaises(ValueError):
            vc.test_pattern(64, 0, 0)

    def test_rejects_a_negative_index(self):
        with self.assertRaises(ValueError):
            vc.test_pattern(64, 48, -1)


class MakeTestClipTest(unittest.TestCase):
    def test_yields_the_requested_number_of_frames(self):
        self.assertEqual(len(list(vc.make_test_clip(32, 24, 5))), 5)

    def test_frames_are_in_index_order(self):
        got = [vc.frame_index_of(f) for f in vc.make_test_clip(32, 24, 5)]
        self.assertEqual(got, [0, 1, 2, 3, 4])

    def test_rejects_a_zero_length_clip(self):
        with self.assertRaises(ValueError):
            list(vc.make_test_clip(32, 24, 0))


# ------------------------------------------------------------------- to_bgra
class ToBgraTest(unittest.TestCase):
    def test_preserves_the_three_colour_channels(self):
        bgr = np.arange(2 * 3 * 3, dtype=np.uint8).reshape(2, 3, 3)
        np.testing.assert_array_equal(vc.to_bgra(bgr)[:, :, :3], bgr)

    def test_sets_alpha_opaque(self):
        bgr = np.zeros((2, 3, 3), dtype=np.uint8)
        self.assertTrue(np.all(vc.to_bgra(bgr)[:, :, 3] == 255))

    def test_passes_a_bgra_frame_through_unchanged(self):
        bgra = np.zeros((2, 3, 4), dtype=np.uint8)
        bgra[:, :, 3] = 9
        np.testing.assert_array_equal(vc.to_bgra(bgra), bgra)

    def test_rejects_a_single_channel_frame(self):
        with self.assertRaises(ValueError):
            vc.to_bgra(np.zeros((2, 3), dtype=np.uint8))


# ----------------------------------------------------------------- letterbox
class LetterboxTest(unittest.TestCase):
    def setUp(self):
        if not has_cv2():
            self.skipTest("OpenCV not installed")

    def test_produces_the_requested_shape(self):
        src = np.full((10, 40, 3), 200, dtype=np.uint8)
        self.assertEqual(vc.letterbox(src, 64, 64).shape, (64, 64, 3))

    def test_pads_a_wide_source_with_black_bars_top_and_bottom(self):
        src = np.full((10, 40, 3), 200, dtype=np.uint8)
        out = vc.letterbox(src, 64, 64)
        self.assertEqual(int(out[0, :, :].max()), 0)

    def test_preserves_aspect_ratio_by_not_padding_a_matching_source(self):
        src = np.full((32, 64, 3), 200, dtype=np.uint8)
        out = vc.letterbox(src, 64, 32)
        self.assertGreater(int(out[0, :, :].max()), 0)

    def test_rejects_a_zero_width_target(self):
        with self.assertRaises(ValueError):
            vc.letterbox(np.zeros((4, 4, 3), dtype=np.uint8), 0, 4)


# ------------------------------------------------------------ file round trip
class ClipFileTest(unittest.TestCase):
    def setUp(self):
        if not has_cv2():
            self.skipTest("OpenCV not installed")
        self.dir = tempfile.mkdtemp(prefix="ch12clip")
        self.path = os.path.join(self.dir, "clip.avi")

    def tearDown(self):
        for name in os.listdir(self.dir):
            os.unlink(os.path.join(self.dir, name))
        os.rmdir(self.dir)

    def test_write_then_read_returns_the_same_number_of_frames(self):
        vc.write_clip(self.path, vc.make_test_clip(64, 48, 6), fps=10)
        self.assertEqual(len(list(vc.read_clip(self.path, 64, 48))), 6)

    def test_read_returns_bgra_frames_of_the_requested_size(self):
        vc.write_clip(self.path, vc.make_test_clip(64, 48, 3), fps=10)
        first = next(iter(vc.read_clip(self.path, 32, 24)))
        self.assertEqual(first.shape, (24, 32, 4))

    def test_read_frames_are_opaque(self):
        vc.write_clip(self.path, vc.make_test_clip(64, 48, 3), fps=10)
        first = next(iter(vc.read_clip(self.path, 64, 48)))
        self.assertTrue(np.all(first[:, :, 3] == 255))

    def test_read_stops_at_max_frames(self):
        vc.write_clip(self.path, vc.make_test_clip(64, 48, 6), fps=10)
        self.assertEqual(len(list(vc.read_clip(self.path, 64, 48, max_frames=2))), 2)

    def test_read_raises_on_a_missing_file(self):
        with self.assertRaises(FileNotFoundError):
            list(vc.read_clip(os.path.join(self.dir, "nope.avi"), 64, 48))

    def test_write_raises_on_an_empty_frame_sequence(self):
        with self.assertRaises(ValueError):
            vc.write_clip(self.path, iter([]), fps=10)


if __name__ == "__main__":
    unittest.main(verbosity=2)
