#!/usr/bin/env python3
"""Tests for the CH12 pixel packer driver.

    python3 test_pixel_packer.py

No board and no PYNQ. The packer is one register, so this file is mostly about
the one thing that can go wrong quietly: asking for a width the hand-written
RTL does not implement and getting 32bpp frames anyway.
"""
import unittest

import pixel_packer as pp


class FakeIP:
    """Stands in for a PYNQ DefaultIP: the read/write pair, and nothing else."""

    def __init__(self, mode=pp.MODE_32BPP, alpha=0):
        self.regs = {pp.REG_MODE: mode, pp.REG_ALPHA: alpha}

    def write(self, offset, value):
        self.regs[offset] = value

    def read(self, offset):
        return self.regs.get(offset, 0)


def packer(mode=pp.MODE_32BPP, alpha=0):
    ip = FakeIP(mode, alpha)
    return pp.PixelPacker(ip), ip


class RegisterMapTest(unittest.TestCase):
    def test_writes_the_mode_to_the_offset_pynq_uses(self):
        # 0x10 is where PYNQ's PixelPacker writes, and the hierarchy's address
        # map is unchanged, so a notebook written against either one works.
        d, ip = packer()
        d.bits_per_pixel = 32
        self.assertIn(pp.REG_MODE, ip.regs)

    def test_thirty_two_bits_per_pixel_is_mode_one(self):
        d, ip = packer()
        d.bits_per_pixel = 32
        self.assertEqual(ip.regs[pp.REG_MODE], 1)


class ReadbackTest(unittest.TestCase):
    def test_reports_thirty_two_bits_per_pixel(self):
        d, _ = packer(mode=pp.MODE_32BPP)
        self.assertEqual(d.bits_per_pixel, 32)

    def test_an_unexpected_mode_is_an_error_not_a_guess(self):
        # The RTL resets to 1 and implements nothing else, so any other value
        # means this driver is not talking to the IP it thinks it is -- most
        # likely PYNQ's HLS packer, whose constructor writes 0.
        d, _ = packer(mode=0)
        with self.assertRaises(RuntimeError):
            d.bits_per_pixel

    def test_the_error_names_the_mode_it_actually_read(self):
        d, _ = packer(mode=3)
        with self.assertRaises(RuntimeError) as ctx:
            d.bits_per_pixel
        self.assertIn("3", str(ctx.exception))


class UnsupportedWidthTest(unittest.TestCase):
    """The whole point of the driver. The RTL packs 32bpp unconditionally, so
    a width it cannot do has to fail here or it fails silently on a screen."""

    def test_rejects_twenty_four_bits_per_pixel(self):
        d, _ = packer()
        with self.assertRaises(ValueError):
            d.bits_per_pixel = 24

    def test_rejects_eight_bits_per_pixel(self):
        d, _ = packer()
        with self.assertRaises(ValueError):
            d.bits_per_pixel = 8

    def test_rejects_sixteen_bits_per_pixel(self):
        d, _ = packer()
        with self.assertRaises(ValueError):
            d.bits_per_pixel = 16

    def test_rejects_a_width_that_is_not_a_pixel_format_at_all(self):
        d, _ = packer()
        with self.assertRaises(ValueError):
            d.bits_per_pixel = 12

    def test_the_error_says_which_widths_exist(self):
        d, _ = packer()
        with self.assertRaises(ValueError) as ctx:
            d.bits_per_pixel = 24
        self.assertIn("32", str(ctx.exception))

    def test_a_rejected_width_does_not_reach_the_hardware(self):
        d, ip = packer()
        with self.assertRaises(ValueError):
            d.bits_per_pixel = 24
        self.assertEqual(ip.regs[pp.REG_MODE], pp.MODE_32BPP)


class AlphaTest(unittest.TestCase):
    """The fourth byte the packer inserts.

    PYNQ's driver never writes it, so on the HLS packer it is whatever reset
    left there -- zero. It is a real register all the same, and the filter's
    colour passthrough mode carries it all the way to the screen, so a
    replacement that dropped it would change what project 3 displays.
    """

    def test_reads_back_the_byte_the_hardware_holds(self):
        d, _ = packer(alpha=0xFF)
        self.assertEqual(d.alpha, 0xFF)

    def test_defaults_to_zero_like_the_hls_packer(self):
        d, _ = packer()
        self.assertEqual(d.alpha, 0)

    def test_is_written_to_its_own_offset(self):
        d, ip = packer()
        d.alpha = 0xFF
        self.assertEqual(ip.regs[pp.REG_ALPHA], 0xFF)

    def test_does_not_disturb_the_mode_register(self):
        d, ip = packer()
        d.alpha = 0x80
        self.assertEqual(ip.regs[pp.REG_MODE], pp.MODE_32BPP)

    def test_rejects_a_value_that_does_not_fit_in_a_byte(self):
        d, _ = packer()
        with self.assertRaises(ValueError):
            d.alpha = 256

    def test_rejects_a_negative_value(self):
        d, _ = packer()
        with self.assertRaises(ValueError):
            d.alpha = -1


class PynqDriverStub:
    """PYNQ's own PixelPacker, modelled faithfully.

    `bits_per_pixel` is a **property on the class**, and its getter reads
    register 0x10 -- see pynq/lib/video/pipeline.py. An earlier version of this
    stub set it as an instance attribute instead, which is why the tests below
    passed while `attach()` was reading hardware: `hasattr(instance, name)`
    invokes a property getter, `hasattr(type(instance), name)` does not.

    That difference wedged the board twice. `pixel_pack` is one of the IPs held
    in reset by gpio_ip_reset at power-up, an IP in reset never completes an
    AXI4-Lite transaction, and ZynqMP has no bus timeout on the PL ports -- so
    the read does not raise, it takes the CPU down with no console and no
    panic. Hence the getter here raises: a test that hung the way the board
    hangs would be no use to anyone.
    """

    @property
    def bits_per_pixel(self):
        raise AssertionError(
            "attach() invoked PYNQ's property getter, which reads register "
            "0x10 -- on hardware that hangs the board when the IP is in reset")

    @bits_per_pixel.setter
    def bits_per_pixel(self, value):
        raise AssertionError("attach() wrote through the property")

    def read(self, offset):
        raise AssertionError("attach() read a register")

    def write(self, offset, value):
        raise AssertionError("attach() wrote a register")


class ReadTrap:
    """A bare DefaultIP whose registers must not be touched either.

    Same reason: when the RTL packer is the one fitted, it is still behind
    gpio_ip_reset at the moment the hierarchy driver is constructed.
    """

    def read(self, offset):
        raise AssertionError("attach() read a register")

    def write(self, offset, value):
        raise AssertionError("attach() wrote a register")


class AttachTest(unittest.TestCase):
    """Which driver the camera hierarchy ends up with.

    Project 3's `hls` build and both camera-only projects instantiate PYNQ's
    HLS packer, and PYNQ binds its own driver to it. The `sv` and `vhdl` builds
    instantiate aup:rtl:pixel_pack, which PYNQ has no driver for and hands back
    as a bare DefaultIP. One line in ov5647.py has to work either way.
    """

    def test_wraps_an_ip_that_pynq_did_not_bind_a_driver_to(self):
        ip = FakeIP()
        self.assertIsInstance(pp.attach(ip), pp.PixelPacker)

    def test_leaves_pynqs_own_driver_alone(self):
        pynq_driver = PynqDriverStub()
        self.assertIs(pp.attach(pynq_driver), pynq_driver)

    def test_decides_without_reading_the_hardware(self):
        # The whole point. attach() runs inside Ov5647Camera.__init__, which is
        # before configure() releases the video reset.
        self.assertIsInstance(pp.attach(ReadTrap()), pp.PixelPacker)

    def test_decides_without_invoking_pynqs_property_getter(self):
        stub = PynqDriverStub()
        self.assertIs(pp.attach(stub), stub)

    def test_the_wrapper_it_returns_drives_the_ip(self):
        ip = FakeIP(mode=0)
        pp.attach(ip).bits_per_pixel = 32
        self.assertEqual(ip.regs[pp.REG_MODE], pp.MODE_32BPP)


if __name__ == "__main__":
    unittest.main(verbosity=2)
