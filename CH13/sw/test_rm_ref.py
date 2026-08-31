"""Tests for the CH13 reconfigurable modules' golden model.

Every RM in the socket must be bit-exact against rm_ref.filter_frame for its
kernel id. That is the contract the RTL testbenches check and the notebook
checks again on hardware, so this file is where the definition of "correct"
actually lives.
"""
import numpy as np
import pytest

import rm_ref as ref


def _frame(h, w, fill=0):
    f = np.full((h, w, 4), fill, dtype=np.uint8)
    f[:, :, 3] = 255
    return f


def _random_frame(h, w, seed=0):
    rng = np.random.default_rng(seed)
    f = rng.integers(0, 256, size=(h, w, 4), dtype=np.uint8)
    f[:, :, 3] = 255
    return f


# ------------------------------------------------------------------ luma

def test_luma_of_white_is_255():
    f = _frame(4, 4, 255)
    assert ref.luma(f).max() == 255


def test_luma_of_black_is_0():
    f = _frame(4, 4, 0)
    assert ref.luma(f).max() == 0


def test_luma_weights_sum_to_256():
    assert ref.LUMA_B + ref.LUMA_G + ref.LUMA_R == 256


def test_luma_ignores_alpha():
    a = _frame(4, 4, 10)
    b = _frame(4, 4, 10)
    b[:, :, 3] = 7
    assert np.array_equal(ref.luma(a), ref.luma(b))


# ----------------------------------------------------------- passthrough

def test_passthrough_returns_the_input_unchanged():
    f = _random_frame(8, 8)
    out = ref.filter_frame(f, ref.KERNEL_PASSTHROUGH, 0)
    assert np.array_equal(out, f)


def test_passthrough_does_not_alias_the_input():
    f = _random_frame(4, 4)
    out = ref.filter_frame(f, ref.KERNEL_PASSTHROUGH, 0)
    out[0, 0, 0] ^= 0xFF
    assert not np.array_equal(out, f)


# ------------------------------------------------------------------ blur

def test_blur_of_a_uniform_image_is_that_value():
    f = _frame(8, 8, 200)
    out = ref.filter_frame(f, ref.KERNEL_BLUR, 0)
    assert np.all(out[1:-1, 1:-1, 0] == 200)


def test_blur_zeroes_the_border():
    f = _frame(8, 8, 200)
    out = ref.filter_frame(f, ref.KERNEL_BLUR, 0)
    assert out[0, :, :3].max() == 0 and out[-1, :, :3].max() == 0
    assert out[:, 0, :3].max() == 0 and out[:, -1, :3].max() == 0


def test_blur_of_an_impulse_is_the_kernel_over_16():
    f = _frame(5, 5, 0)
    f[2, 2, 0] = 160                 # 160/16 = 10, so the kernel reads directly
    out = ref.filter_frame(f, ref.KERNEL_BLUR, 0)
    assert np.array_equal(out[1:4, 1:4, 0],
                          np.array([[10, 20, 10],
                                    [20, 40, 20],
                                    [10, 20, 10]], dtype=np.uint8))


def test_blur_treats_the_three_colour_channels_independently():
    f = _frame(5, 5, 0)
    f[2, 2, 0] = 160
    f[2, 2, 1] = 80
    out = ref.filter_frame(f, ref.KERNEL_BLUR, 0)
    assert out[2, 2, 0] == 40 and out[2, 2, 1] == 20


def test_blur_border_is_opaque_black_like_the_sobel_kernel():
    f = _random_frame(8, 8)
    out = ref.filter_frame(f, ref.KERNEL_BLUR, 0)
    assert out[0, :, 3].min() == 255 and out[:, 0, 3].min() == 255


def test_blur_leaves_the_interior_opaque():
    f = _random_frame(8, 8)
    out = ref.filter_frame(f, ref.KERNEL_BLUR, 0)
    assert np.all(out[1:-1, 1:-1, 3] == 255)


def test_blur_truncates_rather_than_rounds():
    # 15 of 16 weights' worth of 1 plus a zero centre gives 15/16 -> 0, not 1.
    f = _frame(3, 3, 1)
    f[1, 1, 0] = 0
    out = ref.filter_frame(f, ref.KERNEL_BLUR, 0)
    assert out[1, 1, 0] == 0


# ------------------------------------------------------------- threshold

def test_threshold_below_the_level_is_black():
    f = _frame(4, 4, 100)            # luma 100
    out = ref.filter_frame(f, ref.KERNEL_THRESHOLD, 200)
    assert out[:, :, :3].max() == 0


def test_threshold_at_the_level_is_white():
    f = _frame(4, 4, 100)
    out = ref.filter_frame(f, ref.KERNEL_THRESHOLD, 100)
    assert out[:, :, :3].min() == 255


def test_threshold_above_the_level_is_white():
    f = _frame(4, 4, 100)
    out = ref.filter_frame(f, ref.KERNEL_THRESHOLD, 99)
    assert out[:, :, :3].min() == 255


def test_threshold_has_no_border_because_it_needs_no_window():
    f = _frame(4, 4, 255)
    out = ref.filter_frame(f, ref.KERNEL_THRESHOLD, 0)
    assert out[0, 0, 0] == 255


def test_threshold_output_is_gray():
    f = _random_frame(8, 8)
    out = ref.filter_frame(f, ref.KERNEL_THRESHOLD, 128)
    assert np.array_equal(out[:, :, 0], out[:, :, 1])
    assert np.array_equal(out[:, :, 1], out[:, :, 2])


# ----------------------------------------------------------------- sobel

def test_sobel_zeroes_the_border():
    f = _random_frame(8, 8)
    out = ref.filter_frame(f, ref.KERNEL_SOBEL, ref.MODE_SOBEL)
    assert out[0, :, :3].max() == 0 and out[:, 0, :3].max() == 0


def test_sobel_of_a_uniform_image_is_black():
    f = _frame(8, 8, 120)
    out = ref.filter_frame(f, ref.KERNEL_SOBEL, ref.MODE_SOBEL)
    assert out[:, :, :3].max() == 0


def test_sobel_kernel_gray_mode_is_luma():
    f = _random_frame(8, 8)
    out = ref.filter_frame(f, ref.KERNEL_SOBEL, ref.MODE_GRAY)
    assert np.array_equal(out[:, :, 0], ref.luma(f).astype(np.uint8))


def test_sobel_kernel_colour_mode_is_passthrough():
    f = _random_frame(8, 8)
    out = ref.filter_frame(f, ref.KERNEL_SOBEL, ref.MODE_COLOR)
    assert np.array_equal(out, f)


# ---------------------------------------------- vectorised vs. independent

@pytest.mark.parametrize("kernel", [ref.KERNEL_BLUR, ref.KERNEL_THRESHOLD])
def test_vectorised_matches_the_naive_implementation(kernel):
    f = _random_frame(17, 23, seed=kernel)
    mode = 128
    assert np.array_equal(ref.filter_frame(f, kernel, mode),
                          ref.filter_frame_naive(f, kernel, mode))


# ------------------------------------------------------------ validation

def test_rejects_a_float_frame():
    with pytest.raises(ValueError):
        ref.filter_frame(np.zeros((4, 4, 4), dtype=np.float32), ref.KERNEL_BLUR, 0)


def test_rejects_a_three_channel_frame():
    with pytest.raises(ValueError):
        ref.filter_frame(np.zeros((4, 4, 3), dtype=np.uint8), ref.KERNEL_BLUR, 0)


def test_rejects_a_frame_wider_than_the_line_buffers():
    with pytest.raises(ValueError):
        ref.filter_frame(_frame(4, ref.MAX_WIDTH + 1), ref.KERNEL_BLUR, 0)


def test_rejects_an_unknown_kernel_id():
    with pytest.raises(ValueError):
        ref.filter_frame(_frame(4, 4), 0xDEADBEEF, 0)


def test_rejects_a_threshold_level_outside_a_byte():
    with pytest.raises(ValueError):
        ref.filter_frame(_frame(4, 4), ref.KERNEL_THRESHOLD, 256)


# ---------------------------------------------------------------- registry

def test_every_kernel_id_has_a_name():
    for k in ref.KERNELS:
        assert k in ref.KERNEL_NAMES


def test_kernel_ids_are_distinct():
    assert len(set(ref.KERNELS)) == len(ref.KERNELS)
