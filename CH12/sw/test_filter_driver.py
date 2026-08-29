#!/usr/bin/env python3
"""Tests for the CH12 accelerator driver.

    python3 test_filter_driver.py

No board and no PYNQ needed. The driver talks to the accelerator through
`read(offset)` / `write(offset, value)` -- PYNQ's `DefaultIP` interface, and the
hardware boundary -- so that is what gets mocked, and nothing else. The clock is
injected for the same reason.

Most of this file is about the register map. Getting an offset wrong does not
produce a wrong picture, it produces an accelerator that never asserts done and
a notebook that hangs, which is a slow thing to debug on a board and a fast
thing to check here.
"""
import unittest

import numpy as np

import filter_driver as fd
import sobel_ref as ref


class FakeIP:
    """Stands in for a PYNQ DefaultIP. Records writes, scripts CTRL reads."""

    def __init__(self, done_after=1, clock=None):
        self.writes = []
        self.reads = 0
        self._done_after = done_after
        self._clock = clock
        self.regs = {}

    def write(self, offset, value):
        self.writes.append((offset, value))
        self.regs[offset] = value

    def read(self, offset):
        if offset == fd.REG_CTRL:
            self.reads += 1
            if self._clock is not None:
                self._clock.advance()
            return fd.CTRL_AP_DONE if self.reads >= self._done_after else 0
        return self.regs.get(offset, 0)

    def written(self, offset):
        for off, val in reversed(self.writes):
            if off == offset:
                return val
        raise AssertionError(f"nothing was written to offset {offset:#x}")


class FakeClock:
    """A clock that moves when the hardware is polled, not when it is read.

    Reading a clock must not make time pass -- computing a timeout deadline
    would otherwise show up in the measurement. What makes time pass here is
    the accelerator being busy, so FakeIP advances this on every CTRL poll.
    """

    def __init__(self, step=0.001):
        self.now = 0.0
        self.step = step

    def advance(self):
        self.now += self.step

    def __call__(self):
        return self.now


def driver(done_after=1, clock=None):
    clock = clock or FakeClock()
    ip = FakeIP(done_after=done_after, clock=clock)
    return fd.VideoFilter(ip, clock=clock), ip


# ------------------------------------------------------------- register map
class ConfigureTest(unittest.TestCase):
    def test_writes_the_low_half_of_the_source_address(self):
        d, ip = driver()
        d.configure(0x1_2345_6789, 0, 64, 48, ref.MODE_SOBEL)
        self.assertEqual(ip.written(fd.REG_SRC_LO), 0x2345_6789)

    def test_writes_the_high_half_of_the_source_address(self):
        d, ip = driver()
        d.configure(0x1_2345_6789, 0, 64, 48, ref.MODE_SOBEL)
        self.assertEqual(ip.written(fd.REG_SRC_HI), 0x1)

    def test_writes_the_low_half_of_the_destination_address(self):
        d, ip = driver()
        d.configure(0, 0x7_ABCD_EF01, 64, 48, ref.MODE_SOBEL)
        self.assertEqual(ip.written(fd.REG_DST_LO), 0xABCD_EF01)

    def test_writes_the_high_half_of_the_destination_address(self):
        d, ip = driver()
        d.configure(0, 0x7_ABCD_EF01, 64, 48, ref.MODE_SOBEL)
        self.assertEqual(ip.written(fd.REG_DST_HI), 0x7)

    def test_writes_the_width(self):
        d, ip = driver()
        d.configure(0, 0, 640, 48, ref.MODE_SOBEL)
        self.assertEqual(ip.written(fd.REG_WIDTH), 640)

    def test_writes_the_height(self):
        d, ip = driver()
        d.configure(0, 0, 64, 480, ref.MODE_SOBEL)
        self.assertEqual(ip.written(fd.REG_HEIGHT), 480)

    def test_writes_the_mode(self):
        d, ip = driver()
        d.configure(0, 0, 64, 48, ref.MODE_INVERT)
        self.assertEqual(ip.written(fd.REG_MODE), ref.MODE_INVERT)

    def test_does_not_touch_the_control_register(self):
        d, ip = driver()
        d.configure(0, 0, 64, 48, ref.MODE_SOBEL)
        self.assertNotIn(fd.REG_CTRL, [off for off, _ in ip.writes])


class StartTest(unittest.TestCase):
    def test_sets_ap_start(self):
        d, ip = driver()
        d.start()
        self.assertEqual(ip.written(fd.REG_CTRL), fd.CTRL_AP_START)

    def test_run_starts_only_after_every_argument_is_written(self):
        d, ip = driver()
        d.run(0, 0, 64, 48, ref.MODE_SOBEL)
        self.assertEqual(ip.writes[-1][0], fd.REG_CTRL)


# --------------------------------------------------------------- completion
class WaitTest(unittest.TestCase):
    def test_polls_the_control_register_until_done(self):
        d, ip = driver(done_after=5)
        d.wait()
        self.assertEqual(ip.reads, 5)

    def test_returns_immediately_when_done_is_already_set(self):
        d, ip = driver(done_after=1)
        d.wait()
        self.assertEqual(ip.reads, 1)

    def test_raises_when_done_never_arrives(self):
        d, _ = driver(done_after=10**9)
        with self.assertRaises(TimeoutError):
            d.wait(timeout=0.01)

    def test_run_reports_the_elapsed_time(self):
        clock = FakeClock(step=0.25)
        d, _ = driver(clock=clock)
        self.assertAlmostEqual(d.run(0, 0, 64, 48, ref.MODE_SOBEL), 0.25, places=6)


# ------------------------------------------------------------ argument checks
class ArgumentValidationTest(unittest.TestCase):
    def test_rejects_a_width_above_the_line_buffer_depth(self):
        d, _ = driver()
        with self.assertRaises(ValueError):
            d.configure(0, 0, ref.MAX_WIDTH + 1, 48, ref.MODE_SOBEL)

    def test_rejects_a_zero_width(self):
        d, _ = driver()
        with self.assertRaises(ValueError):
            d.configure(0, 0, 0, 48, ref.MODE_SOBEL)

    def test_rejects_a_zero_height(self):
        d, _ = driver()
        with self.assertRaises(ValueError):
            d.configure(0, 0, 64, 0, ref.MODE_SOBEL)

    def test_rejects_an_unknown_mode(self):
        d, _ = driver()
        with self.assertRaises(ValueError):
            d.configure(0, 0, 64, 48, 4)

    def test_rejects_an_address_wider_than_the_pointer_registers(self):
        d, _ = driver()
        with self.assertRaises(ValueError):
            d.configure(1 << 64, 0, 64, 48, ref.MODE_SOBEL)


# ------------------------------------------------------------- frame layout
class FakeFrame(np.ndarray):
    """A NumPy array carrying a device address, like a PynqBuffer."""

    def __new__(cls, shape, device_address=0x7000_0000):
        obj = np.zeros(shape, dtype=np.uint8).view(cls)
        obj.device_address = device_address
        return obj

    def __array_finalize__(self, obj):
        if obj is not None:
            self.device_address = getattr(obj, "device_address", 0)


class FrameLayoutTest(unittest.TestCase):
    def test_accepts_a_contiguous_frame(self):
        f = FakeFrame((48, 64, 4))
        self.assertEqual(fd.frame_address(f, 64, 48), 0x7000_0000)

    def test_rejects_a_frame_whose_rows_are_padded(self):
        # What a DRM dumb buffer looks like when its stride is aligned up: the
        # visible pixels are a strided view, so consecutive rows are not
        # consecutive in memory and the accelerator would write into the pad.
        padded = FakeFrame((48, 64 * 4 + 16))[:, :64 * 4].reshape(48, 64, 4)
        with self.assertRaises(ValueError):
            fd.frame_address(padded, 64, 48)

    def test_rejects_a_frame_of_the_wrong_shape(self):
        with self.assertRaises(ValueError):
            fd.frame_address(FakeFrame((48, 32, 4)), 64, 48)

    def test_rejects_a_frame_with_three_channels(self):
        with self.assertRaises(ValueError):
            fd.frame_address(FakeFrame((48, 64, 3)), 64, 48)

    def test_rejects_a_frame_with_no_device_address(self):
        with self.assertRaises(ValueError):
            fd.frame_address(np.zeros((48, 64, 4), dtype=np.uint8), 64, 48)

    def test_rejects_a_frame_whose_device_address_is_zero(self):
        with self.assertRaises(ValueError):
            fd.frame_address(FakeFrame((48, 64, 4), device_address=0), 64, 48)


if __name__ == "__main__":
    unittest.main(verbosity=2)
