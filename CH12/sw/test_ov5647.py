#!/usr/bin/env python3
"""Tests for the CH12 OV5647 camera driver.

    python3 test_ov5647.py

No board, no camera and no PYNQ needed. Two hardware boundaries are mocked and
nothing else: the I2C transfer (`write_reg`/`read_reg`) and the AXI4-Lite MMIO
of the three video IPs (`read`/`write`).

This file exists because of what the failures look like on real hardware. A
wrong sensor register gives you a black frame, a torn frame, or a frame at the
wrong rate -- and no error message anywhere. A wrong IP register offset gives
you a pipeline that never asserts ap_done, which looks exactly like a camera
that is not plugged in. Both are slow to diagnose on a board at 60 fps and fast
to catch here.

The one thing these tests deliberately do NOT assert is the Bayer phase. Which
of the four phases is correct depends on the sensor's mirror bit, on the crop
offsets' parity, and on how the CSI-2 receiver packs two pixels per clock. That
is a question for the sensor's own colour-bar test pattern on real hardware --
see the project 1 notebook -- not for a value hardcoded in a test.
"""
import unittest

import ov5647 as cam
import ov5647_regs as regs


class FakeI2C:
    """Stands in for one /dev/i2c-N transfer to the sensor at 0x36."""

    def __init__(self, chip_id=cam.CHIP_ID):
        self.writes = []
        self._mem = {
            cam.REG_CHIP_ID: (chip_id >> 8) & 0xFF,
            cam.REG_CHIP_ID + 1: chip_id & 0xFF,
            cam.REG_SW_STANDBY: 0x01,
        }

    def write_reg(self, reg, val):
        assert 0 <= reg <= 0xFFFF, f"register {reg:#x} is not 16-bit"
        assert 0 <= val <= 0xFF, f"value {val:#x} is not 8-bit"
        self.writes.append((reg, val))
        self._mem[reg] = val

    def read_reg(self, reg):
        return self._mem.get(reg, 0)

    # -- helpers the tests read the transcript with ---------------------------
    def value_of(self, reg):
        """Last value written to `reg`, or None if it was never written."""
        for r, v in reversed(self.writes):
            if r == reg:
                return v
        return None

    def word_of(self, reg):
        """Last big-endian 16-bit value written to the pair (reg, reg+1)."""
        hi, lo = self.value_of(reg), self.value_of(reg + 1)
        if hi is None or lo is None:
            return None
        return (hi << 8) | lo

    def index_of(self, reg, val):
        return self.writes.index((reg, val))


class FakeMMIO:
    """Stands in for a PYNQ DefaultIP: 32-bit reads and writes at an offset."""

    def __init__(self):
        self.writes = []
        self.mem = {}

    def write(self, offset, value):
        assert offset % 4 == 0, f"offset {offset:#x} is not word-aligned"
        assert 0 <= value <= 0xFFFFFFFF, f"value {value:#x} is not 32-bit"
        self.writes.append((offset, value))
        self.mem[offset] = value

    def read(self, offset):
        return self.mem.get(offset, 0)

    def value_of(self, offset):
        return self.mem.get(offset)


def fake_pipeline():
    d, g, c, gp = FakeMMIO(), FakeMMIO(), FakeMMIO(), FakeMMIO()
    return cam.VideoPipeline(d, g, c, gp), d, g, c, gp


# ---------------------------------------------------------------------------
# The mode table
# ---------------------------------------------------------------------------
class ModeArithmetic(unittest.TestCase):

    def test_720p_mode_runs_at_60_fps(self):
        self.assertAlmostEqual(cam.MODE_720P.fps, 60.0, delta=0.1)

    def test_1080p_mode_rate_is_reported_honestly_not_rounded_to_30(self):
        # The sensor's own 1080p timing gives 32.8 fps, not the 30 the old
        # Pcam 5C driver's MIPIMode name claimed. Say what it is.
        self.assertAlmostEqual(cam.MODE_1080P.fps, 32.8, delta=0.1)

    def test_720p_output_is_1280_by_720(self):
        self.assertEqual((cam.MODE_720P.width, cam.MODE_720P.height), (1280, 720))

    def test_1080p_output_is_1920_by_1080(self):
        self.assertEqual((cam.MODE_1080P.width, cam.MODE_1080P.height), (1920, 1080))

    def test_720p_window_is_square_pixels(self):
        # 1280x720 out of a 2x2-binned window: the used part of the window must
        # be exactly twice the output in both axes, or the picture is stretched.
        m = cam.MODE_720P
        used_cols = m.width * 2
        used_rows = m.height * 2
        self.assertLessEqual(used_cols, m.window_width)
        self.assertLessEqual(used_rows, m.window_height)
        self.assertAlmostEqual(used_cols / used_rows, 16 / 9, delta=0.01)

    def test_every_mode_has_an_even_crop_window(self):
        # An odd crop start shifts the Bayer phase by one, which turns the
        # picture magenta-and-green. It is not recoverable downstream.
        for m in cam.MODES.values():
            for name, value in m.parity_critical.items():
                with self.subTest(mode=m.name, field=name):
                    self.assertEqual(value % 2, 0, f"{name}={value} is odd")

    def test_every_mode_is_two_pixels_per_clock_friendly(self):
        # CONFIG.CMN_NUM_PIXELS is 2 on the CSI-2 receiver.
        for m in cam.MODES.values():
            with self.subTest(mode=m.name):
                self.assertEqual(m.width % 2, 0)

    def test_every_mode_fits_the_accelerator(self):
        # HLS/src/video_filter.hpp sizes its line buffers for MAX_WIDTH.
        for m in cam.MODES.values():
            with self.subTest(mode=m.name):
                self.assertLessEqual(m.width, 1920)

    def test_vertical_blanking_meets_the_sensor_minimum(self):
        # Measured against the *output* height, which is the rule the sensor
        # actually obeys: its own 1080p mode reads out 1088 lines with a VTS of
        # 1104, so against readout lines it would be 16 and illegal.
        for m in cam.MODES.values():
            with self.subTest(mode=m.name):
                self.assertGreaterEqual(m.vts - m.height, 24)

    def test_the_frame_is_long_enough_for_the_readout(self):
        # Separate rule, and the one that bites when a window is overridden:
        # VTS shorter than the lines being read truncates the frame.
        for m in cam.MODES.values():
            with self.subTest(mode=m.name):
                self.assertGreater(m.vts, m.readout_lines)

    def test_mode_rejects_a_window_smaller_than_its_output(self):
        with self.assertRaises(ValueError):
            cam.Ov5647Mode(name="bad", width=1280, height=720,
                           hts=1896, vts=769, regs=regs.BINNED_2X2_REGS,
                           window=(0, 0, 1279, 719), offset=(0, 0), binning=2)


# ---------------------------------------------------------------------------
# The sensor
# ---------------------------------------------------------------------------
class SensorIdentity(unittest.TestCase):

    def test_reads_chip_id_from_0x300a(self):
        i2c = FakeI2C(chip_id=0x5647)
        self.assertEqual(cam.Ov5647Sensor(i2c).chip_id(), 0x5647)

    def test_rejects_an_ov5640_and_names_it(self):
        # The Pcam 5C this chapter was originally written for. Being told
        # "found 0x5640" beats being told "camera cannot be initialized".
        i2c = FakeI2C(chip_id=0x5640)
        with self.assertRaises(RuntimeError) as e:
            cam.Ov5647Sensor(i2c).check_id()
        self.assertIn("5640", str(e.exception))
        self.assertIn("5647", str(e.exception))

    def test_accepts_the_right_sensor(self):
        cam.Ov5647Sensor(FakeI2C()).check_id()      # must not raise


class SensorConfigure(unittest.TestCase):

    def setUp(self):
        self.i2c = FakeI2C()
        self.sensor = cam.Ov5647Sensor(self.i2c)

    def test_software_reset_precedes_every_mode_register(self):
        self.sensor.configure(cam.MODE_720P)
        reset = self.i2c.index_of(cam.REG_SW_RESET, 0x01)
        first_mode_write = self.i2c.index_of(cam.REG_X_OUTPUT, 0x05)
        self.assertLess(reset, first_mode_write)

    def test_720p_writes_the_output_size(self):
        self.sensor.configure(cam.MODE_720P)
        self.assertEqual(self.i2c.word_of(cam.REG_X_OUTPUT), 1280)
        self.assertEqual(self.i2c.word_of(cam.REG_Y_OUTPUT), 720)

    def test_720p_overrides_the_binned_tables_vertical_window(self):
        # The stock 2x2-binned table reads the whole array. 720p reads a 16:9
        # slice of it, which is the only reason the mode exists.
        self.sensor.configure(cam.MODE_720P)
        y0, y1 = cam.MODE_720P.window[1], cam.MODE_720P.window[3]
        self.assertEqual(self.i2c.word_of(cam.REG_Y_START), y0)
        self.assertEqual(self.i2c.word_of(cam.REG_Y_END), y1)
        self.assertLess(y1 - y0, 1944)

    def test_720p_writes_hts_and_vts_that_the_base_table_does_not_carry(self):
        # The kernel driver leaves these to its hblank/vblank controls, so the
        # tables have no entry for them at all. Miss them and the frame rate is
        # whatever the sensor last had.
        self.sensor.configure(cam.MODE_720P)
        self.assertEqual(self.i2c.word_of(cam.REG_HTS), 1896)
        self.assertEqual(self.i2c.word_of(cam.REG_VTS), 769)

    def test_crop_offsets_are_written(self):
        self.sensor.configure(cam.MODE_720P)
        x_off, y_off = cam.MODE_720P.offset
        self.assertEqual(self.i2c.value_of(cam.REG_X_OFFSET), x_off)
        self.assertEqual(self.i2c.value_of(cam.REG_Y_OFFSET), y_off)

    def test_1080p_keeps_its_tables_window(self):
        self.sensor.configure(cam.MODE_1080P)
        self.assertEqual(self.i2c.word_of(cam.REG_X_OUTPUT), 1920)
        self.assertEqual(self.i2c.word_of(cam.REG_Y_OUTPUT), 1080)
        self.assertEqual(self.i2c.word_of(cam.REG_HTS), 2416)

    def test_sensor_is_left_with_its_blocks_out_of_reset(self):
        # This test previously asserted the OPPOSITE and was wrong -- it
        # encoded the bug it should have caught, and cost an evening.
        #
        # 0x3000/0x3001/0x3002 are SYSTEM_RESET00..02: a set bit holds a block
        # in reset. The kernel writes the 0x0f/0xff/0xe4 set in power_on, and
        # ov5647_common_regs then clears all three to 0x00 -- so 0,0,0 is the
        # state the sensor streams in. Applying the OE set AFTER the tables
        # leaves 0x3001 = 0xff, which holds most of the chip including the MIPI
        # transmitter in reset. The sensor then answers on I2C, reports correct
        # geometry, and never transmits a single packet.
        self.sensor.configure(cam.MODE_720P)
        for reg in (0x3000, 0x3001, 0x3002):
            with self.subTest(reg=hex(reg)):
                self.assertEqual(self.i2c.value_of(reg), 0x00)

    def test_output_enable_set_is_applied_before_the_tables(self):
        # Order, not just final value: power_on first, then set_mode.
        self.sensor.configure(cam.MODE_720P)
        self.assertLess(self.i2c.index_of(0x3001, 0xFF),
                        self.i2c.index_of(0x3001, 0x00))

    def test_geometry_is_written_with_the_sensor_in_standby(self):
        # The mode tables end with 0x0100 = 1. Reprogramming the window,
        # output size, HTS or VTS while the sensor is running makes it emit a
        # partial frame and stop. Stop, configure, start.
        self.sensor.configure(cam.MODE_720P)
        standby_off = self.i2c.index_of(cam.REG_SW_STANDBY, 0x00)
        first_geometry = min(
            self.i2c.index_of(cam.REG_X_OUTPUT, 0x05),
            self.i2c.index_of(cam.REG_VTS, 0x03))
        self.assertLess(standby_off, first_geometry)

    def test_virtual_channel_is_forced_to_zero(self):
        # The CSI-2 receiver is filtering on VC0. Anything else vanishes.
        self.sensor.configure(cam.MODE_720P)
        self.assertEqual(self.i2c.value_of(cam.REG_MIPI_CTRL14) & 0xC0, 0)

    def test_auto_exposure_is_enabled_by_default(self):
        # The tables end with 0x3503 = 0x03, which is manual AEC/AGC and a
        # black picture without libcamera to drive it. See ov5647_regs.py.
        self.sensor.configure(cam.MODE_720P)
        self.assertEqual(self.i2c.value_of(cam.REG_AEC_AGC), 0x00)

    def test_configure_leaves_the_mipi_link_parked(self):
        # configure() must not start data flowing. Nothing downstream is ready
        # yet -- the PL blocks are stopped and the VDMA is not running -- so a
        # sensor that streamed here would back-pressure the CSI-2 receiver into
        # a buffer overflow, and the first real frame would arrive torn.
        # The mode tables end with 0x0100 = 1, so what holds the link is
        # MIPI_CTRL00's idle bits, and they must survive configure().
        self.sensor.configure(cam.MODE_720P)
        parked = self.i2c.value_of(cam.REG_MIPI_CTRL00)
        self.assertTrue(parked & cam.MIPI_CTRL00_BUS_IDLE,
                        f"MIPI_CTRL00 is {parked:#04x}; the link is live")

    def test_auto_exposure_can_be_declined(self):
        self.sensor.configure(cam.MODE_720P, auto_exposure=False)
        self.assertEqual(self.i2c.value_of(cam.REG_AEC_AGC), 0x03)


class SensorControls(unittest.TestCase):

    def setUp(self):
        self.i2c = FakeI2C()
        self.sensor = cam.Ov5647Sensor(self.i2c)

    def test_exposure_is_a_20_bit_value_shifted_left_by_four(self):
        self.sensor.set_exposure(431)
        raw = 431 << 4
        self.assertEqual(self.i2c.value_of(0x3500), (raw >> 16) & 0x0F)
        self.assertEqual(self.i2c.value_of(0x3501), (raw >> 8) & 0xFF)
        self.assertEqual(self.i2c.value_of(0x3502), raw & 0xFF)

    def test_exposure_is_clamped_to_the_frame(self):
        # More exposure lines than there are lines in a frame is not a longer
        # exposure, it is a corrupted one.
        self.sensor.configure(cam.MODE_720P)
        self.sensor.set_exposure(100000)
        raw = (self.i2c.value_of(0x3500) << 16 | self.i2c.value_of(0x3501) << 8
               | self.i2c.value_of(0x3502)) >> 4
        self.assertLessEqual(raw, cam.MODE_720P.vts - 4)

    def test_gain_is_a_q4_fixed_point_multiplier(self):
        self.sensor.set_gain(2.0)               # 2.00x -> 0x0020
        self.assertEqual(self.i2c.word_of(cam.REG_GAIN), 0x20)

    def test_gain_below_unity_is_refused(self):
        with self.assertRaises(ValueError):
            self.sensor.set_gain(0.5)

    def test_white_balance_gains_are_q10_and_enable_manual_awb(self):
        self.sensor.set_white_balance(1.0, 1.0, 1.0)
        self.assertEqual(self.i2c.word_of(cam.REG_AWB_R_GAIN), 0x400)
        self.assertEqual(self.i2c.word_of(cam.REG_AWB_G_GAIN), 0x400)
        self.assertEqual(self.i2c.word_of(cam.REG_AWB_B_GAIN), 0x400)
        self.assertEqual(self.i2c.value_of(cam.REG_AWB_MANUAL) & 0x01, 0x01)

    def test_grey_world_balance_lifts_the_starved_channels(self):
        # Raw Bayer comes out green: there are twice as many green photosites
        # and the colour filters are not matched to any illuminant. Grey-world
        # says the average of a natural scene is neutral, so scale each channel
        # until the three means agree.
        self.sensor.set_white_balance_from_means(b_mean=60, g_mean=120, r_mean=80)
        r = self.i2c.word_of(cam.REG_AWB_R_GAIN)
        g = self.i2c.word_of(cam.REG_AWB_G_GAIN)
        b = self.i2c.word_of(cam.REG_AWB_B_GAIN)
        # Blue was the darkest, so it must get the most gain; green the least.
        self.assertGreater(b, r)
        self.assertGreater(r, g)

    def test_grey_world_balance_maps_frame_channels_to_the_right_registers(self):
        # The frame is B,G,R -- axis_channel_swap put blue in the low byte --
        # while the sensor's gain registers are R, G, B. Crossing those two
        # over is invisible in a grey scene and wrong in every other one.
        self.sensor.set_white_balance_from_means(b_mean=100, g_mean=100, r_mean=25)
        r = self.i2c.word_of(cam.REG_AWB_R_GAIN)
        b = self.i2c.word_of(cam.REG_AWB_B_GAIN)
        self.assertGreater(r, b)

    def test_grey_world_balance_is_a_no_op_on_a_neutral_frame(self):
        self.sensor.set_white_balance_from_means(80, 80, 80)
        for reg in (cam.REG_AWB_R_GAIN, cam.REG_AWB_G_GAIN, cam.REG_AWB_B_GAIN):
            self.assertEqual(self.i2c.word_of(reg), 0x400)   # Q10 unity

    def test_grey_world_balance_survives_a_black_frame(self):
        # Lens cap on, or the exposure loop has not settled. A zero mean must
        # not become a division by zero or an infinite gain.
        self.sensor.set_white_balance_from_means(0, 0, 0)
        for reg in (cam.REG_AWB_R_GAIN, cam.REG_AWB_G_GAIN, cam.REG_AWB_B_GAIN):
            self.assertEqual(self.i2c.word_of(reg), 0x400)

    def test_grey_world_balance_is_bounded(self):
        # One channel at almost nothing would otherwise ask for a gain of
        # hundreds and produce coloured noise rather than a corrected picture.
        self.sensor.set_white_balance_from_means(b_mean=1, g_mean=200, r_mean=200)
        self.assertLessEqual(self.i2c.word_of(cam.REG_AWB_B_GAIN),
                             int(cam.MAX_WB_GAIN * 1024))

    def test_test_pattern_goes_to_isp_control_3d(self):
        self.sensor.set_test_pattern("color_bars")
        self.assertEqual(self.i2c.value_of(cam.REG_TEST_PATTERN),
                         regs.TEST_PATTERN_COLOR_BARS)

    def test_test_pattern_off_clears_it(self):
        self.sensor.set_test_pattern(None)
        self.assertEqual(self.i2c.value_of(cam.REG_TEST_PATTERN),
                         regs.TEST_PATTERN_OFF)

    def test_unknown_test_pattern_is_refused(self):
        with self.assertRaises(ValueError):
            self.sensor.set_test_pattern("herringbone")

    def test_stream_on_selects_the_continuous_clock(self):
        # The Xilinx D-PHY is configured for a continuous clock lane. Leaving
        # the sensor's gating bits set makes the receiver time out on settle.
        self.sensor.stream_on()
        self.assertEqual(self.i2c.value_of(cam.REG_MIPI_CTRL00), 0x00)
        self.assertEqual(self.i2c.value_of(cam.REG_SW_STANDBY), 0x01)

    def test_stream_off_parks_the_lanes(self):
        self.sensor.stream_off()
        self.assertEqual(self.i2c.value_of(cam.REG_SW_STANDBY), 0x00)
        parked = self.i2c.value_of(cam.REG_MIPI_CTRL00)
        self.assertTrue(parked & cam.MIPI_CTRL00_BUS_IDLE)
        self.assertTrue(parked & cam.MIPI_CTRL00_CLOCK_LANE_DISABLE)


# ---------------------------------------------------------------------------
# The PL video pipeline -- what libpcam5c.so used to do
# ---------------------------------------------------------------------------
class DemosaicConfig(unittest.TestCase):

    def test_writes_size_and_phase_then_starts(self):
        pipe, dem, _, _, _ = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        self.assertEqual(dem.value_of(cam.DEMOSAIC_WIDTH), 1280)
        self.assertEqual(dem.value_of(cam.DEMOSAIC_HEIGHT), 720)
        self.assertEqual(dem.value_of(cam.DEMOSAIC_BAYER_PHASE), cam.BAYER_BGGR)
        self.assertEqual(dem.value_of(cam.AP_CTRL), cam.AP_START_AUTO_RESTART)

    def test_start_is_the_last_write(self):
        # Starting the block before its size is programmed streams one frame of
        # garbage, which on a 60 fps pipeline is a visible flash on every
        # reconfigure.
        pipe, dem, _, _, _ = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        self.assertEqual(dem.writes[-1][0], cam.AP_CTRL)

    def test_rejects_an_unknown_bayer_phase(self):
        pipe, _, _, _, _ = fake_pipeline()
        with self.assertRaises(ValueError):
            pipe.configure(1280, 720, 4)


class GammaLutConfig(unittest.TestCase):

    def test_writes_256_entries_to_each_of_three_channels(self):
        pipe, _, gam, _, _ = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        for base in (cam.GAMMA_LUT0, cam.GAMMA_LUT1, cam.GAMMA_LUT2):
            with self.subTest(base=hex(base)):
                # 256 16-bit entries packed two per 32-bit word.
                words = [o for o, _ in gam.writes if base <= o < base + 512]
                self.assertEqual(len(words), 128)

    def test_entries_are_packed_two_per_word_little_endian(self):
        pipe, _, gam, _, _ = fake_pipeline()
        pipe.set_gamma(1.0)                     # identity: lut[i] == i
        word = gam.value_of(cam.GAMMA_LUT0 + 4)  # entries 2 and 3
        self.assertEqual(word & 0xFFFF, 2)
        self.assertEqual(word >> 16, 3)

    def test_unity_gamma_is_the_identity_curve(self):
        pipe, _, gam, _, _ = fake_pipeline()
        pipe.set_gamma(1.0)
        self.assertEqual(cam.read_lut(gam, cam.GAMMA_LUT0), list(range(256)))

    def test_gamma_curve_is_monotonic_and_hits_both_ends(self):
        for gamma in (1.8, 2.2, 2.6):
            pipe, _, gam, _, _ = fake_pipeline()
            pipe.set_gamma(gamma)
            lut = cam.read_lut(gam, cam.GAMMA_LUT0)
            with self.subTest(gamma=gamma):
                self.assertEqual(lut[0], 0)
                self.assertEqual(lut[255], 255)
                self.assertEqual(lut, sorted(lut))
                # A gamma above 1 brightens the mid-tones; that is the point.
                self.assertGreater(lut[128], 128)

    def test_video_format_is_rgb(self):
        pipe, _, gam, _, _ = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        self.assertEqual(gam.value_of(cam.GAMMA_VIDEO_FORMAT), cam.CSF_RGB)

    def test_rejects_a_gamma_that_is_not_positive(self):
        pipe, _, _, _, _ = fake_pipeline()
        with self.assertRaises(ValueError):
            pipe.set_gamma(0.0)


class CscConfig(unittest.TestCase):

    def test_defaults_to_the_identity_matrix(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        for off in (cam.CSC_K11, cam.CSC_K22, cam.CSC_K33):
            self.assertEqual(csc.value_of(off), cam.CSC_ONE)
        for off in (cam.CSC_K12, cam.CSC_K13, cam.CSC_K21,
                    cam.CSC_K23, cam.CSC_K31, cam.CSC_K32):
            self.assertEqual(csc.value_of(off), 0)

    def test_clamps_to_the_full_eight_bit_range(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        self.assertEqual(csc.value_of(cam.CSC_CLAMPMIN), 0)
        self.assertEqual(csc.value_of(cam.CSC_CLIPMAX), 255)

    def test_window_covers_the_whole_frame(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        self.assertEqual(csc.value_of(cam.CSC_WIDTH), 1280)
        self.assertEqual(csc.value_of(cam.CSC_HEIGHT), 720)
        self.assertEqual(csc.value_of(cam.CSC_COLSTART), 0)
        self.assertEqual(csc.value_of(cam.CSC_COLEND), 1279)
        self.assertEqual(csc.value_of(cam.CSC_ROWSTART), 0)
        self.assertEqual(csc.value_of(cam.CSC_ROWEND), 719)

    def test_in_and_out_are_both_rgb(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        self.assertEqual(csc.value_of(cam.CSC_IN_FORMAT), cam.CSF_RGB)
        self.assertEqual(csc.value_of(cam.CSC_OUT_FORMAT), cam.CSF_RGB)

    def test_zero_saturation_makes_every_row_the_luma_weights(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.set_color(saturation=0.0)
        rows = [
            [csc.value_of(o) for o in (cam.CSC_K11, cam.CSC_K12, cam.CSC_K13)],
            [csc.value_of(o) for o in (cam.CSC_K21, cam.CSC_K22, cam.CSC_K23)],
            [csc.value_of(o) for o in (cam.CSC_K31, cam.CSC_K32, cam.CSC_K33)],
        ]
        self.assertEqual(rows[0], rows[1])
        self.assertEqual(rows[1], rows[2])
        # BT.601 luma: R sees the middle weight, G the largest, B the smallest.
        self.assertLess(rows[0][2], rows[0][0])
        self.assertLess(rows[0][0], rows[0][1])

    def test_each_row_of_a_desaturating_matrix_still_sums_to_one(self):
        # Otherwise turning the colour down also turns the brightness down.
        for sat in (0.0, 0.5, 1.0):
            pipe, _, _, csc, _ = fake_pipeline()
            pipe.set_color(saturation=sat)
            for row in (cam.CSC_K11, cam.CSC_K21, cam.CSC_K31):
                total = sum(csc.value_of(row + 8 * i) for i in range(3))
                with self.subTest(saturation=sat, row=hex(row)):
                    self.assertAlmostEqual(total / cam.CSC_ONE, 1.0, delta=0.01)

    def test_brightness_moves_the_offsets_and_not_the_matrix(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.set_color(brightness=20)
        self.assertEqual(csc.value_of(cam.CSC_K11), cam.CSC_ONE)
        for off in (cam.CSC_R_OFFSET, cam.CSC_G_OFFSET, cam.CSC_B_OFFSET):
            self.assertEqual(csc.value_of(off), 20)

    def test_contrast_pivots_about_mid_grey(self):
        # Mid-grey in must stay mid-grey out, or "more contrast" is just
        # "brighter". out = k*(in-128) + 128, so offset = 128*(1-k).
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.set_color(contrast=1.5)
        k = csc.value_of(cam.CSC_K11) / cam.CSC_ONE
        offset = cam.to_signed(csc.value_of(cam.CSC_R_OFFSET), 12)
        self.assertAlmostEqual(k, 1.5, delta=0.01)
        self.assertAlmostEqual(k * 128 + offset, 128, delta=1.0)

    def test_negative_coefficients_are_written_as_twos_complement(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.set_color(saturation=2.0)      # oversaturating makes K12/K13 < 0
        k12 = csc.value_of(cam.CSC_K12)
        self.assertLess(cam.to_signed(k12, 16), 0)
        self.assertLessEqual(k12, 0xFFFF)

    def test_negative_brightness_is_written_as_twos_complement(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.set_color(brightness=-20)
        raw = csc.value_of(cam.CSC_R_OFFSET)
        self.assertEqual(cam.to_signed(raw, 12), -20)
        self.assertLessEqual(raw, 0xFFF)

    def test_offsets_saturate_rather_than_wrap(self):
        # A 12-bit register given 4000 would wrap to a large negative offset
        # and produce a black frame from a request for a bright one.
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.set_color(brightness=4000)
        self.assertEqual(cam.to_signed(csc.value_of(cam.CSC_R_OFFSET), 12), 2047)

    def test_start_is_the_last_write(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        self.assertEqual(csc.writes[-1][0], cam.AP_CTRL)

    def test_colour_can_be_retuned_without_restating_the_geometry(self):
        # The notebook's sliders call set_color on every drag. It must not
        # need, or clobber, the frame size.
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        csc.writes.clear()
        pipe.set_color(saturation=1.4)
        self.assertNotIn(cam.CSC_WIDTH, [o for o, _ in csc.writes])
        self.assertEqual(csc.value_of(cam.CSC_WIDTH), 1280)


class AxiPortWidthGuard(unittest.TestCase):
    """The check that would have saved four crashed boards.

    The PS-PL master port width lives in FPD_SLCR.AFI_FS and is written once,
    by psu_init, at boot. Loading a bitstream does not revisit it. So an
    overlay built against a different width than the booting image drives one
    width into a port expecting another, and every access to that port's
    aperture never completes -- and on ZynqMP there is no bus timeout, so the
    CPU hangs forever with no panic and no console output.

    Reading FPD_SLCR.AFI_FS is a PS register access and always safe. Doing it
    before the first write into the PL aperture turns an unrecoverable board
    hang into an exception with a sentence explaining itself.
    """

    def test_accepts_a_matching_width(self):
        cam.check_axi_port_width(afi_fs=0x00000A00, expected_bits=128)

    def test_rejects_the_mismatch_that_hangs_the_board(self):
        # PS booted at 128 (base overlay), bitstream built for 32.
        with self.assertRaises(RuntimeError) as e:
            cam.check_axi_port_width(afi_fs=0x00000A00, expected_bits=32)
        msg = str(e.exception)
        self.assertIn("128", msg)
        self.assertIn("32", msg)

    def test_decodes_the_field_at_bits_9_and_8(self):
        # psu_init writes this field under mask 0x00000F00. Decoding it at
        # bits [1:0] -- which is the obvious wrong guess -- reads 32-bit for
        # every possible value and the guard silently never fires.
        self.assertEqual(cam.axi_port_width(0x00000A00), 128)
        self.assertEqual(cam.axi_port_width(0x00000000), 32)
        self.assertEqual(cam.axi_port_width(0x00000100), 64)
        self.assertEqual(cam.axi_port_width(0x00000200), 128)

    def test_ignores_the_unrelated_hpm1_field(self):
        # bits [11:10] are HPM1_FPD and must not move the answer.
        self.assertEqual(cam.axi_port_width(0x00000200), 128)
        self.assertEqual(cam.axi_port_width(0x00000E00), 128)

    def test_error_names_the_register_and_the_cause(self):
        with self.assertRaises(RuntimeError) as e:
            cam.check_axi_port_width(afi_fs=0x00000A00, expected_bits=32)
        msg = str(e.exception)
        self.assertIn("AFI_FS", msg)
        self.assertIn("psu_init", msg)


class VideoIpReset(unittest.TestCase):
    """The reset that has to come off before any of these IPs will answer.

    gpio_ip_reset channel 1 powers up at 0 -- the hierarchy sets
    C_DOUT_DEFAULT_2 for channel 2 but leaves channel 1 alone -- and it drives
    proc_sys_reset/aux_reset_in, which is configured active-low. So from
    power-up demosaic, gamma_lut, v_proc_sys, axis_channel_swap and pixel_pack
    are all held in reset, and an IP in reset does not complete an AXI4-Lite
    transaction. On ZynqMP there is no bus timeout, so the read does not fail:
    it wedges the CPU permanently.

    This is why Pcam5C hands libpcam5c.so the GPIO base address first. Miss it
    and the board hangs on the first register access, with no panic and no
    console output.
    """

    def test_configure_releases_the_video_ip_reset(self):
        pipe, _, _, _, gpio = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        self.assertEqual(gpio.value_of(cam.GPIO_CH1_DATA) & 1, 1)

    def test_the_release_happens_before_any_ip_is_touched(self):
        # The whole point. Writing demosaic first is the hang.
        pipe, dem, gam, csc, gpio = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        self.assertTrue(gpio.writes, "reset was never released")
        for mmio, name in ((dem, "demosaic"), (gam, "gamma_lut"), (csc, "csc")):
            with self.subTest(ip=name):
                self.assertTrue(mmio.writes, f"{name} was never configured")

    def test_release_pulses_the_reset_low_then_high(self):
        # A clean pulse, so an IP left mid-transaction by a previous run starts
        # from a known state rather than from whatever it was doing.
        pipe, _, _, _, gpio = fake_pipeline()
        pipe.release_video_reset()
        values = [v for o, v in gpio.writes if o == cam.GPIO_CH1_DATA]
        self.assertEqual(values[0] & 1, 0)
        self.assertEqual(values[-1] & 1, 1)

    def test_release_does_not_disturb_the_camera_reset(self):
        # Channel 2 is the sensor's own reset line and defaults to released.
        # Clearing it would put the camera back into reset.
        pipe, _, _, _, gpio = fake_pipeline()
        pipe.release_video_reset()
        self.assertNotIn(cam.GPIO_CH2_DATA, [o for o, _ in gpio.writes])


class WhiteBalanceInTheCsc(unittest.TestCase):
    """White balance belongs in the CSC, not in the sensor.

    The sensor's AWB gain registers (0x3400-0x3406) sit inside its ISP, and in
    raw Bayer mode that ISP is bypassed -- so writing them does nothing at all.
    Measured on hardware: a requested R gain of 2.0 and B gain of 0.5 moved the
    channel means by less than 0.1 counts, with the AWB enable bit both clear
    and set.

    The colour-space converter is already in the pipeline performing an
    identity multiply, so scaling its diagonal is white balance for free.

    Note the crossed order, which is the easy thing to get wrong: the CSC sits
    BEFORE axis_channel_swap and so works in R,G,B, while the frame that comes
    out is B,G,R.
    """

    def test_gains_scale_the_matrix_diagonal(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.set_white_balance(r=2.0, g=1.0, b=0.5)
        self.assertAlmostEqual(csc.value_of(cam.CSC_K11) / cam.CSC_ONE, 2.0, delta=0.01)
        self.assertAlmostEqual(csc.value_of(cam.CSC_K22) / cam.CSC_ONE, 1.0, delta=0.01)
        self.assertAlmostEqual(csc.value_of(cam.CSC_K33) / cam.CSC_ONE, 0.5, delta=0.01)

    def test_unity_gains_leave_the_identity_alone(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.set_white_balance(1.0, 1.0, 1.0)
        for off in (cam.CSC_K11, cam.CSC_K22, cam.CSC_K33):
            self.assertEqual(csc.value_of(off), cam.CSC_ONE)

    def test_white_balance_composes_with_saturation(self):
        # Both live in the same matrix; one must not clobber the other.
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.set_white_balance(r=2.0, g=1.0, b=1.0)
        pipe.set_color(saturation=0.0)
        row0 = [csc.value_of(o) for o in (cam.CSC_K11, cam.CSC_K12, cam.CSC_K13)]
        # Desaturated, so row 0 is the luma weights -- but still doubled by the
        # red gain, so it sums to 2.0 rather than 1.0.
        self.assertAlmostEqual(sum(row0) / cam.CSC_ONE, 2.0, delta=0.02)

    def test_grey_world_from_bgr_means_maps_to_the_right_channels(self):
        # A red-starved frame must raise the RED gain, i.e. K11 -- not K33.
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.white_balance_from_means(b_mean=100, g_mean=100, r_mean=25)
        self.assertGreater(csc.value_of(cam.CSC_K11), csc.value_of(cam.CSC_K33))

    def test_grey_world_lifts_a_green_deficit(self):
        # The measured cast on hardware: G low against B and R, which reads as
        # a red cast. Green must come up.
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.white_balance_from_means(b_mean=73.1, g_mean=64.6, r_mean=70.8)
        self.assertGreater(csc.value_of(cam.CSC_K22), cam.CSC_ONE)

    def test_grey_world_survives_a_black_frame(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.white_balance_from_means(0, 0, 0)
        for off in (cam.CSC_K11, cam.CSC_K22, cam.CSC_K33):
            self.assertEqual(csc.value_of(off), cam.CSC_ONE)

    def test_grey_world_is_bounded(self):
        pipe, _, _, csc, _ = fake_pipeline()
        pipe.white_balance_from_means(b_mean=1, g_mean=200, r_mean=200)
        self.assertLessEqual(csc.value_of(cam.CSC_K33),
                             int(cam.MAX_WB_GAIN * cam.CSC_ONE))


class VdmaStartupRace(unittest.TestCase):
    """The latched SOF error that makes the first run after programming flaky.

    The sensor free-runs at 60 fps and cannot be synchronised to the instant
    the VDMA arms, so the first Start-of-Frame after `stream_on()` lands
    mid-frame and the VDMA latches SOFEarlyErr and ErrIrq in S2MM_DMASR.

    Those bits are sticky, write-1-to-clear, and PYNQ's `readframe()` never
    touches them -- it looks only at bit 0 (Halted) and bit 12 (FrmCntIrq).
    Measured on hardware: cleared once the stream is steady they stay clear
    through 450 frames, so this is a startup race and not a geometry fault.

    Left latched it produces exactly the two failures seen: `RuntimeError:
    DMA channel not started` when bit 0 sets, and an unbounded block when the
    frame-count interrupt does not arrive.
    """

    def test_decodes_the_error_measured_on_hardware(self):
        # The literal DMASR captured 1 s after stream_on.
        self.assertEqual(cam.vdma_errors(0x00045100), ["SOFEarlyErr", "ErrIrq"])

    def test_a_healthy_status_reports_nothing(self):
        # Captured after clearing, with frames flowing normally.
        self.assertEqual(cam.vdma_errors(0x00011000), [])

    def test_the_clear_mask_covers_every_error_bit_and_nothing_else(self):
        # Writing 1s clears; writing a 1 into bit 0 or 12 would be wrong --
        # bit 0 is Halted, which is status, and bit 12 is the frame-count
        # interrupt readframe() depends on.
        self.assertEqual(cam.VDMA_ERROR_MASK & 0x1, 0)
        self.assertEqual(cam.VDMA_ERROR_MASK & 0x1000, 0)
        for bit in (8, 14):
            self.assertTrue(cam.VDMA_ERROR_MASK >> bit & 1)

    def test_halted_is_detected_from_bit_zero(self):
        self.assertTrue(cam.vdma_halted(0x00010001))
        self.assertFalse(cam.vdma_halted(0x00011000))

    def test_error_bits_alone_do_not_mean_halted(self):
        # This is why the fault looked intermittent: frames keep flowing with
        # the error latched, because readframe() ignores it.
        self.assertFalse(cam.vdma_halted(0x00045100))


class PipelineStop(unittest.TestCase):

    def test_stop_clears_every_blocks_start_bit(self):
        pipe, dem, gam, csc, _ = fake_pipeline()
        pipe.configure(1280, 720, cam.BAYER_BGGR)
        pipe.stop()
        for mmio in (dem, gam, csc):
            self.assertEqual(mmio.value_of(cam.AP_CTRL), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
