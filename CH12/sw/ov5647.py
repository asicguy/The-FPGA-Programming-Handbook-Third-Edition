#!/usr/bin/env python3
"""The OV5647 camera, and the PL video pipeline behind it.

CH12 was written for the Pcam 5C, whose sensor is an OV5640, and PYNQ drives
that one through `pynq.lib.video.Pcam5C` -- a thin wrapper around a shared
library, `libpcam5c.so`, that does two jobs at once:

  - it initialises the sensor over I2C, and
  - it configures the demosaic, gamma-LUT and colour-space-converter blocks in
    the PL through the base addresses the wrapper hands it.

The board this chapter was finished on has an **OV5647** instead -- the sensor
in a Raspberry Pi Camera Module v1. It answers at I2C address 0x36 rather than
0x3c, and its register map is not the OV5640's, so `libpcam5c.so` fails at the
first read and takes the PL half of the setup down with it. There is no way to
keep half a binary.

So this module replaces all of it, in Python. That is a better deal than it
sounds: the pipeline stops being a blob that either works or does not, and
becomes six pages you can read, instrument and change. The notebook gets live
gamma, saturation and exposure controls it could not have had before, and the
one thing the blob really did buy -- known-good register values -- is recovered
from AMD's own reference design for the same IP (see VideoPipeline below).

What did NOT have to change is the hardware. Both sensors send RAW10 Bayer over
two MIPI lanes, so `common/mipi_hier.tcl` keeps its shape:

    OV5647 --RAW10, 2 lanes, 437.5 Mbps--> mipi_csi2_rx_subsyst
      -> axis_subset_converter (RAW10 -> RAW8)
      -> demosaic -> gamma_lut -> v_proc_sys (CSC)
      -> axis_channel_swap -> pixel_pack -> axi_vdma S2MM -> DDR

Only the line rate moved, from the OV5640's 672 Mbps to 437.5.

Three things are worth knowing before you change anything here:

**There is no 1280x720 mode on this sensor.** Its readout modes are 2592x1944,
1920x1080, 1296x972 and 640x480. CH12 is a 720p chapter -- the DisplayPort mode,
the accelerator measurements and project 2's whole comparison are at 720p -- so
MODE_720P derives one, by taking the 2x2-binned readout and cropping its window
to a 16:9 slice. See Ov5647Mode for the arithmetic. It lands on 60.0 fps, which
is the rate the Pcam 5C ran at, so nothing downstream had to be re-measured.

**The Bayer phase is established by experiment, not by assertion.** Which of the
four phases is correct depends on the sensor's mirror bit, on the parity of the
crop offsets and on how the receiver packs two pixels per clock. Guessing wrong
gives a picture that is recognisable but magenta-and-green, which is exactly the
kind of bug that survives a code review. `BAYER_PHASE_DEFAULT` records what was
measured on hardware with the sensor's own colour-bar pattern; the project 1
notebook re-runs that measurement in front of you.

**Auto exposure is on, and that is a deviation from the kernel driver.** The
register tables end by putting AEC/AGC in manual mode, because in Linux
libcamera runs the exposure loop in userspace. There is no libcamera here, so
`configure()` hands the loop back to the sensor. Without that the picture is
correctly demosaiced and almost black.
"""
import ctypes
import fcntl
import glob
import os
import time

import ov5647_regs as regs
import pixel_packer

# ---------------------------------------------------------------------------
# Sensor
# ---------------------------------------------------------------------------
CHIP_ID = 0x5647
DEFAULT_I2C_ADDR = 0x36

# Registers this module's *logic* touches. The bulk-configuration tables live
# in ov5647_regs.py, under their own licence.
REG_SW_STANDBY = 0x0100
REG_SW_RESET = 0x0103
REG_CHIP_ID = 0x300A        # and 0x300B
REG_PAD_OUT = 0x300D
REG_AWB_R_GAIN = 0x3400     # 0x3400/0x3401, Q10
REG_AWB_G_GAIN = 0x3402
REG_AWB_B_GAIN = 0x3404
REG_AWB_MANUAL = 0x3406
REG_EXPOSURE = 0x3500       # 0x3500..0x3502, 20-bit, value << 4
REG_AEC_AGC = 0x3503
REG_GAIN = 0x350A           # 0x350A/0x350B, Q4
REG_X_START = 0x3800        # every 0x38xx pair below is big-endian 16-bit
REG_Y_START = 0x3802
REG_X_END = 0x3804
REG_Y_END = 0x3806
REG_X_OUTPUT = 0x3808
REG_Y_OUTPUT = 0x380A
REG_HTS = 0x380C
REG_VTS = 0x380E
REG_X_OFFSET = 0x3811       # 8-bit
REG_Y_OFFSET = 0x3813       # 8-bit
REG_FRAME_OFF_NUMBER = 0x4202
REG_MIPI_CTRL00 = 0x4800
REG_MIPI_CTRL14 = 0x4814
REG_TEST_PATTERN = 0x503D

MIPI_CTRL00_CLOCK_LANE_GATE = 1 << 5
MIPI_CTRL00_LINE_SYNC_ENABLE = 1 << 4
MIPI_CTRL00_BUS_IDLE = 1 << 2
MIPI_CTRL00_CLOCK_LANE_DISABLE = 1 << 0

# What the PLL in ov5647_regs.COMMON_REGS produces from the module's own 25 MHz
# oscillator. The link frequency is the number that has to agree with
# CONFIG.C_HS_LINE_RATE on the CSI-2 receiver: 218.75 MHz DDR is 437.5 Mbps a
# lane. PIXEL_RATE is what HTS and VTS are counted in.
PIXEL_RATE = 87_500_000
LINK_FREQ = 218_750_000
LANE_RATE_MBPS = 2 * LINK_FREQ / 1e6
MIPI_LANES = 2

# Sensor array geometry, from the OV5647 datasheet.
NATIVE_WIDTH = 2624
NATIVE_HEIGHT = 1956
MIN_VBLANK = 24

# The accelerator's line buffers are sized for this -- HLS/src/video_filter.hpp.
MAX_FILTER_WIDTH = 1920

# Ceiling on a white-balance gain. A channel that is almost dark -- lens cap on,
# or the exposure loop not yet settled -- would otherwise ask for a gain of
# several hundred, which amplifies read noise into confetti rather than
# correcting anything. 4x is about as far as this sensor's digital gain is
# worth pushing.
MAX_WB_GAIN = 4.0

TEST_PATTERNS = {
    None: regs.TEST_PATTERN_OFF,
    "off": regs.TEST_PATTERN_OFF,
    "color_bars": regs.TEST_PATTERN_COLOR_BARS,
    "color_squares": regs.TEST_PATTERN_COLOR_SQUARES,
    "random": regs.TEST_PATTERN_RANDOM,
}


# ---------------------------------------------------------------------------
# The guard that turns an unrecoverable board hang into an exception
# ---------------------------------------------------------------------------
# FPD_SLCR.AFI_FS holds the PS-PL master port widths for the two FPD masters.
# psu_init writes it ONCE, at boot, from whatever design the board booted with
# -- on a PYNQ image, the base overlay. Loading a bitstream reprograms the
# fabric and the PL clocks and does not revisit it.
#
# So an overlay built with a different width than the booting image drives one
# width into a port configured for another, and every access to that port's
# aperture never completes. ZynqMP has no bus timeout on the PL ports, so the
# master that issued the access wedges permanently: the CPU stops with no
# panic, no console output and no way back short of pulling the power. A JTAG
# probe of the same address wedges the debug port in exactly the same way.
#
# Reading this register is a PS access and is always safe. Doing it before the
# first write into the PL aperture costs one memory read and converts the worst
# failure mode in the chapter into a sentence.
FPD_SLCR_AFI_FS = 0xFD615000
AFI_FS_HPM0_SHIFT = 8           # psu_init writes this field under mask 0xF00
AFI_FS_WIDTHS = {0: 32, 1: 64, 2: 128}


def axi_port_width(afi_fs):
    """Decode M_AXI_HPM0_FPD's configured width from FPD_SLCR.AFI_FS."""
    return AFI_FS_WIDTHS.get((afi_fs >> AFI_FS_HPM0_SHIFT) & 0x3, 0)


def check_axi_port_width(afi_fs, expected_bits):
    """Raise if the PS port width disagrees with what the bitstream expects."""
    actual = axi_port_width(afi_fs)
    if actual != expected_bits:
        raise RuntimeError(
            f"M_AXI_HPM0_FPD is configured for {actual}-bit in the PS, but "
            f"this bitstream drives it as {expected_bits}-bit "
            f"(FPD_SLCR.AFI_FS = {afi_fs:#010x}).\n"
            f"psu_init sets that width once at boot, from the design the "
            f"board booted with, and loading a bitstream does not change it. "
            f"Touching the 0xA0000000 aperture now would hang this board hard "
            f"-- no panic, no console, power cycle only.\n"
            f"Rebuild the overlay with PSU__MAXIGP0__DATA_WIDTH set to "
            f"{actual}, or boot an image whose base overlay uses "
            f"{expected_bits}.")
    return actual


def to_signed(value, bits):
    """Interpret an unsigned register field as two's complement."""
    if value >= 1 << (bits - 1):
        value -= 1 << bits
    return value


def _to_field(value, bits):
    """Saturate a signed value into a `bits`-wide two's-complement field.

    Saturating rather than wrapping is the whole point: a 12-bit offset handed
    4000 would wrap to -96 and turn a request for a bright picture into a dark
    one, silently.
    """
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    value = max(lo, min(hi, int(round(value))))
    return value & ((1 << bits) - 1)


class Ov5647Mode:
    """One sensor readout mode.

    `regs` is a base table from ov5647_regs; `window`, `offset`, `hts` and
    `vts` are applied over the top of it. That layering is what lets MODE_720P
    exist at all -- it is the stock 2x2-binned table with a different slice of
    the array selected.

    Coordinates in `window` are in *array* pixels, before binning. `binning` is
    how many array pixels go into one output pixel per axis, so the output size
    the sensor can deliver from a window is window/binning.
    """

    def __init__(self, name, width, height, hts, vts, regs, binning,
                 window=None, offset=None):
        self.name = name
        self.width = width
        self.height = height
        self.hts = hts
        self.vts = vts
        self.regs = regs
        self.binning = binning
        self.window = window
        self.offset = offset or (0, 0)

        if width % 2 or height % 2:
            raise ValueError(
                f"{name}: {width}x{height} -- the CSI-2 receiver is configured "
                f"for two pixels per clock, so both axes must be even")
        if width > MAX_FILTER_WIDTH:
            raise ValueError(
                f"{name}: {width} exceeds the accelerator's MAX_WIDTH of "
                f"{MAX_FILTER_WIDTH}")
        if window is not None:
            if self.window_width < width * binning:
                raise ValueError(
                    f"{name}: window is {self.window_width} array columns, "
                    f"which cannot produce {width} output pixels at "
                    f"{binning}x binning")
            if self.window_height < height * binning:
                raise ValueError(
                    f"{name}: window is {self.window_height} array rows, "
                    f"which cannot produce {height} output pixels at "
                    f"{binning}x binning")
        # Two separate rules, and they are not the same number. The sensor's
        # minimum vertical blanking is measured against the *output* height --
        # its own 1080p mode reads 1088 lines with a VTS of 1104, which is 16
        # against the readout and 24 against the output.
        if vts - height < MIN_VBLANK:
            raise ValueError(
                f"{name}: VTS of {vts} leaves {vts - height} lines of vertical "
                f"blanking, below the sensor's minimum of {MIN_VBLANK}")
        # And the frame has to be long enough to contain what is being read.
        if vts <= self.readout_lines:
            raise ValueError(
                f"{name}: VTS of {vts} is shorter than the {self.readout_lines} "
                f"lines the window reads out; the frame would be truncated")

    @property
    def window_width(self):
        if self.window is None:
            return self.width * self.binning
        return self.window[2] - self.window[0] + 1

    @property
    def window_height(self):
        if self.window is None:
            return self.height * self.binning
        return self.window[3] - self.window[1] + 1

    @property
    def readout_lines(self):
        """Lines the sensor actually reads out, which is what VTS must cover.

        Not the same as `height`: the ISP crops `offset` lines off a window
        that the analogue front end has already read.
        """
        return self.window_height // self.binning

    @property
    def fps(self):
        return PIXEL_RATE / (self.hts * self.vts)

    @property
    def parity_critical(self):
        """Fields whose parity decides the Bayer phase.

        An odd value in any of them shifts the colour filter pattern by one
        pixel, which is not recoverable downstream -- the demosaic block would
        need a phase that then no longer matches the sensor's own description
        of itself. Kept as a dict so the test can name the offender.
        """
        fields = {"x_offset": self.offset[0], "y_offset": self.offset[1]}
        if self.window is not None:
            fields["x_start"] = self.window[0]
            fields["y_start"] = self.window[1]
        return fields

    def __repr__(self):
        return (f"<Ov5647Mode {self.name} {self.width}x{self.height} "
                f"@ {self.fps:.1f} fps>")


# --- the two modes CH12 offers ---------------------------------------------
#
# MODE_720P is the derived one. The 2x2-binned readout covers the whole array,
# 2624x1956 down to 1312x978. Cropping the *array* window to rows 250..1705
# leaves 1456 rows -- 728 binned -- of which 720 are used, and the full 2624
# columns give 1312 binned of which 1280 are used. Both used areas are exactly
# twice the output, so pixels stay square, and 2560x1440 array pixels is a true
# 16:9 slice.
#
# The frame rate then follows from the timing grid. A line is HTS = 1896 pixel
# clocks at 87.5 MHz, or 21.67 us; VTS = 769 lines is 16.66 ms, or 60.0 fps.
# Nothing about that is a coincidence -- 769 was chosen to land on 60.
#
# Keeping HTS at the binned table's value is deliberate and not just laziness:
# the anti-banding step counts the table carries (0x3a08/0x3a09 for 50 Hz,
# 0x3a0a/0x3a0b for 60 Hz) are derived from the *line* time, so leaving HTS
# alone leaves them correct.
#
# What is NOT correct, and is a known loose end: the band-count limits at
# 0x3a0d and 0x3a0e were computed against a 1435-line frame, and this one is
# 769. In dim light the sensor's own AEC loop can therefore ask for an exposure
# longer than the frame it has. Bright light will not show it; a frame rate
# quietly below 60, or flicker under mains lighting, is what it looks like.
MODE_720P = Ov5647Mode(
    name="1280x720",
    width=1280, height=720,
    hts=1896, vts=769,
    regs=regs.BINNED_2X2_REGS,
    binning=2,
    window=(0, 250, 2623, 1705),
    offset=(16, 4),
)

# MODE_1080P is the sensor's own 1080p readout, unmodified: a 1:1 window out of
# the middle of the array, so a narrower field of view but no binning. Its
# timing grid gives 32.8 fps, and this driver reports that rather than calling
# it "1080p30" the way PYNQ's MIPIMode did.
MODE_1080P = Ov5647Mode(
    name="1920x1080",
    width=1920, height=1080,
    hts=2416, vts=1104,
    regs=regs.FULL_1080P_REGS,
    binning=1,
    window=None,
    offset=(4, 2),
)

MODES = {m.name: m for m in (MODE_720P, MODE_1080P)}


class I2CDevice:
    """16-bit register, 8-bit data transfers on one /dev/i2c-N.

    Uses I2C_RDWR rather than plain read()/write() because an SCCB register
    read is a combined transaction -- write the address, repeated START, read
    the data -- and a pair of unrelated transfers can be interleaved by another
    master between the two halves.
    """

    I2C_RDWR = 0x0707

    class _Msg(ctypes.Structure):
        _fields_ = [("addr", ctypes.c_uint16),
                    ("flags", ctypes.c_uint16),
                    ("len", ctypes.c_uint16),
                    ("buf", ctypes.POINTER(ctypes.c_char))]

    class _IoctlData(ctypes.Structure):
        _fields_ = [("msgs", ctypes.c_void_p), ("nmsgs", ctypes.c_uint32)]

    M_RD = 0x0001

    def __init__(self, bus, addr=DEFAULT_I2C_ADDR):
        self.addr = addr
        self.path = f"/dev/i2c-{bus}" if isinstance(bus, int) else bus
        self._fd = os.open(self.path, os.O_RDWR)

    def close(self):
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _transfer(self, msgs):
        arr = (self._Msg * len(msgs))(*msgs)
        data = self._IoctlData(msgs=ctypes.cast(arr, ctypes.c_void_p),
                               nmsgs=len(msgs))
        fcntl.ioctl(self._fd, self.I2C_RDWR, data)

    def write_reg(self, reg, val):
        buf = ctypes.create_string_buffer(
            bytes([(reg >> 8) & 0xFF, reg & 0xFF, val & 0xFF]), 3)
        self._transfer([self._Msg(self.addr, 0, 3,
                                  ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))])

    def read_reg(self, reg):
        out = ctypes.create_string_buffer(
            bytes([(reg >> 8) & 0xFF, reg & 0xFF]), 2)
        inp = ctypes.create_string_buffer(1)
        self._transfer([
            self._Msg(self.addr, 0, 2,
                      ctypes.cast(out, ctypes.POINTER(ctypes.c_char))),
            self._Msg(self.addr, self.M_RD, 1,
                      ctypes.cast(inp, ctypes.POINTER(ctypes.c_char))),
        ])
        return inp.raw[0]


def find_camera_i2c_bus(default=None):
    """The bus the AXI IIC controller in the `mipi` hierarchy shows up as.

    Found by label, not by number: the number depends on how many I2C adapters
    the PS happens to register first, and it moves. The `RPICAM` label comes
    from the device-tree overlay in project1_mipi_dp/dts/, and the same walk is
    what PYNQ's own Pcam5C driver does.
    """
    for dev in sorted(glob.glob("/dev/i2c-*")):
        n = os.path.basename(dev).split("-")[-1]
        try:
            with open(f"/sys/bus/i2c/devices/i2c-{n}/of_node/label") as fh:
                if "RPICAM" in fh.read().strip("\x00 \n"):
                    return int(n)
        except (OSError, ValueError):
            continue
    if default is not None:
        return default
    raise RuntimeError(
        "no I2C bus labelled RPICAM. The overlay's .dtbo has to be loaded "
        "alongside the .bit -- PYNQ matches them by basename -- or the AXI IIC "
        "controller never appears in /dev/i2c-*.")


class Ov5647Sensor:
    """The sensor itself: everything that happens over I2C.

    Deliberately knows nothing about PYNQ, the PL or the overlay, so it can be
    tested against a fake I2C device and used from a plain script.
    """

    def __init__(self, i2c):
        self.i2c = i2c
        self.mode = None

    # -- primitives ---------------------------------------------------------
    def write_reg(self, reg, val):
        self.i2c.write_reg(reg, val)

    def read_reg(self, reg):
        return self.i2c.read_reg(reg)

    def write_word(self, reg, val):
        """Big-endian 16-bit, which is how every 0x38xx pair is laid out."""
        self.i2c.write_reg(reg, (val >> 8) & 0xFF)
        self.i2c.write_reg(reg + 1, val & 0xFF)

    def read_word(self, reg):
        return (self.i2c.read_reg(reg) << 8) | self.i2c.read_reg(reg + 1)

    def apply(self, table):
        for reg, val in table:
            self.i2c.write_reg(reg, val)

    # -- identity -----------------------------------------------------------
    def chip_id(self):
        return self.read_word(REG_CHIP_ID)

    def check_id(self):
        found = self.chip_id()
        if found != CHIP_ID:
            raise RuntimeError(
                f"expected an OV5647 (chip id {CHIP_ID:#06x}) at I2C address "
                f"{getattr(self.i2c, 'addr', DEFAULT_I2C_ADDR):#04x}, but the "
                f"device there reports {found:#06x}. "
                f"{'That is an OV5640 -- a Pcam 5C. Use PYNQ pynq.lib.video.Pcam5C for it. ' if found == 0x5640 else ''}"
                f"Check that the ribbon cable is the right way round.")
        return found

    # -- configuration ------------------------------------------------------
    def configure(self, mode, auto_exposure=True):
        """Load a mode. The sensor is left configured but NOT streaming.

        The mode tables end with 0x0100 = 1, but MIPI_CTRL00 keeps the link
        parked, so nothing reaches the receiver until `stream_on()`. That is
        deliberate: everything downstream is a back-pressured AXI4-Stream, and
        a sensor streaming into a pipeline that is not draining overflows the
        receiver's line buffer.

        Order matters here too, and is not arbitrary: the common table
        software-resets
        the part and leaves the output pads disabled, the mode table sets the
        readout, and only then do the pads come back on. Turning the pads on
        first puts an unconfigured sensor's idea of a MIPI stream onto the
        lanes, and the receiver has to be reset to recover.
        """
        if isinstance(mode, str):
            mode = MODES[mode]

        # OE first, then the tables. This order is the whole ballgame.
        #
        # 0x3000/0x3001/0x3002 are SYSTEM_RESET00..02, and a set bit holds a
        # block in reset -- despite the kernel calling this set "oe_enable".
        # It writes them in power_on, and COMMON_REGS then clears all three to
        # zero, so the state the sensor actually streams in is 0, 0, 0.
        #
        # Applying them the other way round leaves 0x3001 = 0xff, which holds
        # most of the chip -- the MIPI transmitter included -- in reset. The
        # sensor then answers on I2C, reports the correct geometry, and never
        # transmits a packet, which is an extraordinarily quiet way to fail.
        self.apply(regs.OE_ENABLE_REGS)
        self.apply(regs.COMMON_REGS)
        self.apply(mode.regs)

        # The mode tables end with 0x0100 = 1. Changing the window, output
        # size, HTS or VTS while the sensor is running makes it emit a partial
        # frame and stop, so stop first and let stream_on() start it.
        self.write_reg(REG_SW_STANDBY, 0x00)

        # Overrides on top of the base table -- see Ov5647Mode.
        if mode.window is not None:
            x0, y0, x1, y1 = mode.window
            self.write_word(REG_X_START, x0)
            self.write_word(REG_Y_START, y0)
            self.write_word(REG_X_END, x1)
            self.write_word(REG_Y_END, y1)
        self.write_word(REG_X_OUTPUT, mode.width)
        self.write_word(REG_Y_OUTPUT, mode.height)
        self.write_reg(REG_X_OFFSET, mode.offset[0])
        self.write_reg(REG_Y_OFFSET, mode.offset[1])

        # HTS and VTS are not in any of the tables. The kernel driver writes
        # them from its hblank/vblank controls, so a table-only port of that
        # driver runs at whatever rate the sensor was last left at.
        self.write_word(REG_HTS, mode.hts)
        self.write_word(REG_VTS, mode.vts)

        # Virtual channel 0. The CSI-2 receiver filters on it, so a stream on
        # any other channel is discarded without an error anywhere.
        ctrl14 = self.read_reg(REG_MIPI_CTRL14) & ~0xC0
        self.write_reg(REG_MIPI_CTRL14, ctrl14)

        # Hand the exposure loop back to the sensor -- see the module docstring.
        self.write_reg(REG_AEC_AGC, 0x00 if auto_exposure else 0x03)

        self.mode = mode
        return mode

    # -- controls -----------------------------------------------------------
    def set_exposure(self, lines):
        """Exposure time in lines. One line is HTS/PIXEL_RATE seconds."""
        if self.mode is not None:
            lines = min(lines, self.mode.vts - 4)
        lines = max(4, int(lines))
        raw = lines << 4
        self.write_reg(REG_EXPOSURE, (raw >> 16) & 0x0F)
        self.write_reg(REG_EXPOSURE + 1, (raw >> 8) & 0xFF)
        self.write_reg(REG_EXPOSURE + 2, raw & 0xFF)
        return lines

    def set_gain(self, gain):
        """Analogue gain as a multiplier. 1.0 is unity; the register is Q4."""
        if gain < 1.0:
            raise ValueError(f"gain {gain} is below unity; the OV5647 cannot "
                             f"attenuate, only amplify")
        self.write_word(REG_GAIN, min(0x3FF, int(round(gain * 16))))
        return gain

    def set_white_balance(self, r=1.0, g=1.0, b=1.0):
        """Manual digital white balance, as per-channel multipliers (Q10).

        Raw Bayer straight off the sensor is strongly green -- there are twice
        as many green photosites, and the colour filters are not matched to any
        particular illuminant. Something has to correct it, and doing it here
        costs nothing: it is a multiply the sensor was going to do anyway.
        """
        for reg, gain in ((REG_AWB_R_GAIN, r), (REG_AWB_G_GAIN, g),
                          (REG_AWB_B_GAIN, b)):
            if gain <= 0:
                raise ValueError(f"white-balance gain {gain} must be positive")
            self.write_word(reg, min(0xFFF, int(round(gain * 1024))))
        self.write_reg(REG_AWB_MANUAL, 0x01)

    def set_white_balance_from_means(self, b_mean, g_mean, r_mean):
        """Grey-world white balance from one frame's per-channel means.

        Raw Bayer is strongly green before correction: there are twice as many
        green photosites as red or blue, and the colour filters are not matched
        to any particular illuminant. Grey-world assumes the average of a
        natural scene is neutral and scales each channel until the three means
        agree -- crude, but it needs no calibration and no magic constants, and
        it is a great deal better than leaving the gains at unity.

        Note the argument order. The frame is **B, G, R** -- `axis_channel_swap`
        put blue in the low byte -- while the sensor's gain registers are R, G,
        B. Those two get crossed over easily, and a swap is invisible in a grey
        scene and wrong in every other one.

        Takes means rather than a frame so that this module needs no NumPy and
        can be tested without one.
        """
        means = (b_mean, g_mean, r_mean)
        target = sum(means) / 3.0
        if target <= 0 or min(means) <= 0:
            # A black frame carries no information about colour. Unity, and let
            # the caller try again once there is light.
            self.set_white_balance(1.0, 1.0, 1.0)
            return (1.0, 1.0, 1.0)
        b_gain, g_gain, r_gain = (min(MAX_WB_GAIN, target / m) for m in means)
        self.set_white_balance(r=r_gain, g=g_gain, b=b_gain)
        return (r_gain, g_gain, b_gain)

    def set_test_pattern(self, pattern="color_bars"):
        """The sensor's built-in patterns, generated after the pixel array.

        `color_bars` is how the project 1 notebook pins down the Bayer phase:
        it is a known image that needs no lens, no light and no correct
        exposure to be recognisable, so it separates "the phase is wrong" from
        "the room is dark" -- two failures that otherwise look alike.
        """
        if pattern not in TEST_PATTERNS:
            raise ValueError(f"unknown test pattern {pattern!r}; "
                             f"expected one of {sorted(k for k in TEST_PATTERNS if k)}")
        self.write_reg(REG_TEST_PATTERN, TEST_PATTERNS[pattern])

    # -- streaming ----------------------------------------------------------
    def stream_on(self):
        """Start the MIPI output, with a continuous clock lane.

        MIPI_CTRL00 = 0 is the continuous-clock setting, and it has to be: the
        Xilinx D-PHY in `mipi_csi2_rx_subsyst` is configured for a continuous
        clock, and against a gated one it never completes HS settle. The
        symptom is a receiver that reports no errors and delivers no frames.
        """
        self.write_reg(REG_MIPI_CTRL00, 0x00)
        self.write_reg(REG_FRAME_OFF_NUMBER, 0x00)
        self.write_reg(REG_PAD_OUT, 0x00)
        self.write_reg(REG_SW_STANDBY, 0x01)

    def stream_off(self):
        """Stop, and park the lanes in LP-11 so the receiver resynchronises."""
        self.write_reg(REG_MIPI_CTRL00,
                       MIPI_CTRL00_CLOCK_LANE_GATE | MIPI_CTRL00_BUS_IDLE
                       | MIPI_CTRL00_CLOCK_LANE_DISABLE)
        self.write_reg(REG_FRAME_OFF_NUMBER, 0x0F)
        self.write_reg(REG_PAD_OUT, 0x01)
        self.write_reg(REG_SW_STANDBY, 0x00)


# ---------------------------------------------------------------------------
# The PL video pipeline -- demosaic, gamma LUT, colour-space converter
# ---------------------------------------------------------------------------
# Every offset below is from the driver headers shipped with Vivado, not from
# guesswork:
#
#   v_demosaic_v1_4/src/xv_demosaic_hw.h
#   v_gamma_lut_v1_4/src/xv_gamma_lut_hw.h
#   v_csc_v2_6/src/xv_csc_hw.h
#
# and the values that are not simply width and height -- the identity CSC, the
# 0x81 start, the LUT packing -- are the ones AMD's own reference design for
# this exact pipeline uses, in
#
#   mipicsiss_v1_11/examples/xmipi_ref_design/pipeline_program.c
#
# That file is worth reading if you change anything here; it is the closest
# thing to documentation for how these three blocks are meant to be driven.

AP_CTRL = 0x00
AP_START = 1 << 0
AP_AUTO_RESTART = 1 << 7
# 0x81. The blocks are ap_ctrl_hs like the accelerator, but a video block that
# needed restarting per frame would need an interrupt per frame; auto-restart
# is what makes them free-running.
AP_START_AUTO_RESTART = AP_START | AP_AUTO_RESTART

DEMOSAIC_WIDTH = 0x10
DEMOSAIC_HEIGHT = 0x18
DEMOSAIC_RESERVED = 0x20
DEMOSAIC_BAYER_PHASE = 0x28

GAMMA_WIDTH = 0x10
GAMMA_HEIGHT = 0x18
GAMMA_VIDEO_FORMAT = 0x20
GAMMA_LUT0 = 0x800
GAMMA_LUT1 = 0x1000
GAMMA_LUT2 = 0x1800
GAMMA_ENTRIES = 256         # the IP is built for 8-bit data

CSC_IN_FORMAT = 0x10
CSC_OUT_FORMAT = 0x18
CSC_WIDTH = 0x20
CSC_HEIGHT = 0x28
CSC_COLSTART = 0x30
CSC_COLEND = 0x38
CSC_ROWSTART = 0x40
CSC_ROWEND = 0x48
CSC_K11, CSC_K12, CSC_K13 = 0x50, 0x58, 0x60
CSC_K21, CSC_K22, CSC_K23 = 0x68, 0x70, 0x78
CSC_K31, CSC_K32, CSC_K33 = 0x80, 0x88, 0x90
CSC_R_OFFSET, CSC_G_OFFSET, CSC_B_OFFSET = 0x98, 0xA0, 0xA8
CSC_CLAMPMIN = 0xB0
CSC_CLIPMAX = 0xB8

CSC_FRACTIONAL_BITS = 12
CSC_ONE = 1 << CSC_FRACTIONAL_BITS      # 4096: the coefficients are Q12
CSC_COEFF_BITS = 16
CSC_OFFSET_BITS = 12

CSF_RGB = 0                             # XVIDC_CSF_RGB

# --- the reset that has to come off first -----------------------------------
# gpio_ip_reset is an AXI GPIO with two channels. Channel 2 is the camera
# module's own reset line and the hierarchy gives it C_DOUT_DEFAULT_2 = 1, so
# it comes up released. Channel 1 has no default, so it comes up at 0 -- and it
# drives proc_sys_reset/aux_reset_in, which is configured active-low. Zero
# means reset asserted.
#
# What that reset holds is every HLS video IP in the pipeline: demosaic,
# gamma_lut, v_proc_sys, axis_channel_swap and pixel_pack. An IP held in reset
# does not complete an AXI4-Lite transaction, and ZynqMP has no bus timeout on
# the PL ports -- so reading one of their registers does not return an error,
# it wedges the CPU permanently. No panic, no console output, power cycle only.
#
# This is why PYNQ's Pcam5C hands libpcam5c.so the GPIO base address alongside
# the other three: releasing this is the first thing that has to happen.
GPIO_CH1_DATA = 0x00        # video IP reset, active low, defaults to 0
GPIO_CH1_TRI = 0x04
GPIO_CH2_DATA = 0x08        # the camera module's reset -- do not touch
GPIO_CH2_TRI = 0x0C

# --- the VDMA's latched Start-of-Frame error --------------------------------
# The sensor free-runs and cannot be synchronised to the instant the VDMA arms,
# so the first SOF after stream_on() lands mid-frame and the VDMA latches
# SOFEarlyErr and ErrIrq in S2MM_DMASR. Measured on hardware, cleared once the
# stream is steady they stay clear through 450 frames, so this is a startup
# race and not a geometry fault -- the pipeline does deliver 720 lines.
#
# It matters because PYNQ's readframe() looks only at bit 0 (Halted) and bit 12
# (FrmCntIrq) and never clears an error. Left latched it produces exactly two
# failures, both seen: `RuntimeError: DMA channel not started` when bit 0 sets,
# and an unbounded block when the frame-count interrupt does not arrive. One
# cause, two faces, and it is why the fault looked intermittent -- frames keep
# flowing with the error latched right up until they do not.
VDMA_S2MM_DMASR = 0x34
VDMA_DMASR_HALTED = 1 << 0
VDMA_DMASR_ERRORS = {
    4: "DMAIntErr", 5: "DMASlvErr", 6: "DMADecErr", 8: "SOFEarlyErr",
    9: "EOLEarlyErr", 11: "SOFLateErr", 14: "ErrIrq", 15: "EOLLateErr",
}
# Write-1-to-clear. Deliberately excludes bit 0 (Halted, which is status) and
# bit 12 (FrmCntIrq, which is what readframe waits on).
VDMA_ERROR_MASK = sum(1 << b for b in VDMA_DMASR_ERRORS)


def vdma_errors(dmasr):
    """Error bits set in an S2MM_DMASR value, in bit order."""
    return [name for bit, name in sorted(VDMA_DMASR_ERRORS.items())
            if dmasr >> bit & 1]


def vdma_halted(dmasr):
    """True if the channel has halted. Error bits alone do not halt it."""
    return bool(dmasr & VDMA_DMASR_HALTED)


BAYER_RGGB, BAYER_GRBG, BAYER_GBRG, BAYER_BGGR = 0, 1, 2, 3
BAYER_NAMES = {BAYER_RGGB: "RGGB", BAYER_GRBG: "GRBG",
               BAYER_GBRG: "GBRG", BAYER_BGGR: "BGGR"}

# Measured on hardware with the sensor's own colour-bar generator, scored
# against the expected bar colours. RGGB wins by a factor of 28:
#
#     RGGB    72        <- this one
#     BGGR  2028
#     GRBG  2836
#     GBRG  3224
#
# This constant previously said GBRG, reasoned out from the kernel driver's
# hflip/mbus-code table, and that was not merely wrong but the worst of the
# four -- the picture came out magenta and green. The lesson is the one the
# test file already states: the phase depends on the sensor's mirror bit, the
# parity of the crop offsets and how the receiver packs two pixels per clock,
# and the only reliable way to know it is to look. Change it only with a
# picture to show for it.
BAYER_PHASE_DEFAULT = BAYER_RGGB

# BT.601 luma weights. Note the order: the CSC sits *before* axis_channel_swap
# in the hierarchy, so at this point in the pipeline the channels are still
# R, G, B. It is the swap after it that puts blue in the low byte, which is why
# sobel_ref.py weights channel 0 at 29/256.
LUMA_R, LUMA_G, LUMA_B = 0.299, 0.587, 0.114

MID_GREY = 128.0


def read_lut(mmio, base, entries=GAMMA_ENTRIES):
    """Unpack a gamma LUT back out of a fake or real MMIO, for checking."""
    out = []
    for word in range(entries // 2):
        value = mmio.read(base + word * 4)
        out.append(value & 0xFFFF)
        out.append((value >> 16) & 0xFFFF)
    return out


class VideoPipeline:
    """The three configurable blocks between the CSI-2 receiver and the VDMA.

    Takes three objects that each have `read(offset)` and `write(offset,
    value)` -- PYNQ's `DefaultIP`, and the hardware boundary. Nothing here
    imports PYNQ, so it is testable without a board.
    """

    def __init__(self, demosaic, gamma_lut, csc, gpio_ip_reset):
        self.demosaic = demosaic
        self.gamma_lut = gamma_lut
        self.csc = csc
        self.gpio = gpio_ip_reset
        self.width = None
        self.height = None
        self.bayer_phase = BAYER_PHASE_DEFAULT
        self.gamma = 1.0
        self.brightness = 0.0
        self.contrast = 1.0
        self.saturation = 1.0
        # White balance lives here rather than in the sensor -- see
        # set_white_balance. R, G, B, matching the CSC's own channel order.
        self.wb = (1.0, 1.0, 1.0)

    # -- the whole pipeline -------------------------------------------------
    def configure(self, width, height, bayer_phase=None, gamma=None):
        if bayer_phase is None:
            bayer_phase = self.bayer_phase
        if bayer_phase not in BAYER_NAMES:
            raise ValueError(
                f"bayer phase {bayer_phase} is not one of "
                f"{sorted(BAYER_NAMES)} ({', '.join(BAYER_NAMES.values())})")
        self.width, self.height = width, height
        self.bayer_phase = bayer_phase
        if gamma is not None:
            self.gamma = gamma

        # Before anything else, and it is not optional: these three are held
        # in reset from power-up and reading them in that state hangs the
        # board. See GPIO_CH1_DATA.
        self.release_video_reset()

        self._configure_demosaic()
        self._configure_gamma()
        self._configure_csc()

    def release_video_reset(self):
        """Take the video IPs out of reset, and pulse it on the way.

        Writing 0 then 1 rather than just 1: if a previous run left an IP
        mid-transaction, a clean pulse starts it from a known state instead of
        from wherever it stopped. Channel 2 is deliberately not touched -- that
        is the camera module's own reset and it is already released.
        """
        self.gpio.write(GPIO_CH1_DATA, 0)
        self.gpio.write(GPIO_CH1_DATA, 1)

    def stop(self):
        """Clear every start bit. Do this before reprogramming the geometry.

        Only safe once the video IPs are out of reset -- see configure().
        """
        for mmio in (self.demosaic, self.gamma_lut, self.csc):
            mmio.write(AP_CTRL, 0)

    # -- demosaic -----------------------------------------------------------
    def _configure_demosaic(self):
        d = self.demosaic
        d.write(DEMOSAIC_WIDTH, self.width)
        d.write(DEMOSAIC_HEIGHT, self.height)
        d.write(DEMOSAIC_RESERVED, 0)
        d.write(DEMOSAIC_BAYER_PHASE, self.bayer_phase)
        d.write(AP_CTRL, AP_START_AUTO_RESTART)     # start last, always

    def set_bayer_phase(self, phase):
        """Retune the phase without disturbing anything else.

        Exists so the notebook can sweep all four and let you pick by eye,
        which is the only reliable way to settle it.
        """
        if phase not in BAYER_NAMES:
            raise ValueError(f"bayer phase {phase} is not one of "
                             f"{sorted(BAYER_NAMES)}")
        self.bayer_phase = phase
        self.demosaic.write(DEMOSAIC_BAYER_PHASE, phase)

    # -- gamma --------------------------------------------------------------
    def _configure_gamma(self):
        g = self.gamma_lut
        g.write(GAMMA_WIDTH, self.width)
        g.write(GAMMA_HEIGHT, self.height)
        g.write(GAMMA_VIDEO_FORMAT, CSF_RGB)
        self._write_lut()
        g.write(AP_CTRL, AP_START_AUTO_RESTART)

    def set_gamma(self, gamma):
        """Load a gamma curve. 1.0 is the identity ramp AMD's example uses.

        The sensor delivers something close to linear light. A display expects
        roughly 2.2, so a value near there is what makes shadows look like
        shadows rather than like black.
        """
        if gamma <= 0:
            raise ValueError(f"gamma must be positive, got {gamma}")
        self.gamma = gamma
        self._write_lut()

    def _write_lut(self):
        table = [
            int(round(((i / 255.0) ** (1.0 / self.gamma)) * 255.0))
            for i in range(GAMMA_ENTRIES)
        ]
        # 16-bit entries, two to a 32-bit word. AMD's reference writes them
        # with Xil_Out16 at base + i*2; from Python, where MMIO writes are
        # 32 bits wide, that is the same bytes packed little-endian in pairs.
        for base in (GAMMA_LUT0, GAMMA_LUT1, GAMMA_LUT2):
            for word in range(GAMMA_ENTRIES // 2):
                lo, hi = table[word * 2], table[word * 2 + 1]
                self.gamma_lut.write(base + word * 4, (hi << 16) | lo)

    # -- colour -------------------------------------------------------------
    def _colour_matrix(self):
        """A 3x3 matrix and a 3-vector for brightness/contrast/saturation.

        Saturation interpolates each row towards the luma weights, so that a
        fully desaturated picture is the luminance the eye expects rather than
        a channel average. Each row still sums to one, which is what keeps
        turning the colour down from also turning the brightness down.

        Contrast then scales about mid-grey, and brightness is a pure offset.
        Composing them in that order is why the offset carries the
        128*(1 - contrast) term.
        """
        s = self.saturation
        luma = (LUMA_R, LUMA_G, LUMA_B)
        matrix = [
            [luma[col] * (1.0 - s) + (s if col == row else 0.0)
             for col in range(3)]
            for row in range(3)
        ]
        c = self.contrast
        matrix = [[v * c for v in row] for row in matrix]
        # White balance scales each OUTPUT channel, so it multiplies a whole
        # row. Doing it here rather than as a separate write is what lets it
        # compose with saturation and contrast instead of overwriting them.
        matrix = [[v * self.wb[row] for v in matrix[row]] for row in range(3)]
        offset = MID_GREY * (1.0 - c) + self.brightness
        return matrix, [offset] * 3

    def _configure_csc(self):
        c = self.csc
        c.write(CSC_IN_FORMAT, CSF_RGB)
        c.write(CSC_OUT_FORMAT, CSF_RGB)
        self._write_colour()
        c.write(CSC_CLAMPMIN, 0)
        c.write(CSC_CLIPMAX, 255)
        c.write(CSC_WIDTH, self.width)
        c.write(CSC_HEIGHT, self.height)
        c.write(CSC_COLSTART, 0)
        c.write(CSC_COLEND, self.width - 1)
        c.write(CSC_ROWSTART, 0)
        c.write(CSC_ROWEND, self.height - 1)
        c.write(AP_CTRL, AP_START_AUTO_RESTART)

    def set_white_balance(self, r=1.0, g=1.0, b=1.0):
        """Per-channel gain, applied in the CSC.

        NOT in the sensor. The OV5647's AWB gain registers (0x3400-0x3406) are
        inside its ISP, and in raw Bayer mode that ISP is bypassed -- measured
        on hardware, a requested R gain of 2.0 and B gain of 0.5 moved the
        channel means by less than 0.1 counts. The CSC is already in the
        pipeline doing an identity multiply, so scaling its diagonal costs
        nothing and actually works.
        """
        for name, gain in (("r", r), ("g", g), ("b", b)):
            if gain <= 0:
                raise ValueError(f"{name} gain {gain} must be positive")
        self.wb = tuple(min(MAX_WB_GAIN, v) for v in (r, g, b))
        self._write_colour()

    def white_balance_from_means(self, b_mean, g_mean, r_mean):
        """Grey-world from one frame's per-channel means.

        Takes them in **B, G, R** -- the order the frame comes out in, after
        axis_channel_swap -- and applies them as **R, G, B**, which is the
        order the CSC works in because it sits before that swap. Crossing those
        two over is invisible in a grey scene and wrong in every other one.
        """
        means = (b_mean, g_mean, r_mean)
        target = sum(means) / 3.0
        if target <= 0 or min(means) <= 0:
            self.set_white_balance(1.0, 1.0, 1.0)
            return (1.0, 1.0, 1.0)
        b_gain, g_gain, r_gain = (min(MAX_WB_GAIN, target / m) for m in means)
        self.set_white_balance(r=r_gain, g=g_gain, b=b_gain)
        return (r_gain, g_gain, b_gain)

    def set_color(self, brightness=None, contrast=None, saturation=None):
        """Retune colour alone. Safe to call on every slider drag."""
        if brightness is not None:
            self.brightness = brightness
        if contrast is not None:
            self.contrast = contrast
        if saturation is not None:
            self.saturation = saturation
        self._write_colour()

    def _write_colour(self):
        matrix, offsets = self._colour_matrix()
        coeffs = ((CSC_K11, CSC_K12, CSC_K13),
                  (CSC_K21, CSC_K22, CSC_K23),
                  (CSC_K31, CSC_K32, CSC_K33))
        for row, addrs in enumerate(coeffs):
            for col, addr in enumerate(addrs):
                self.csc.write(
                    addr, _to_field(matrix[row][col] * CSC_ONE, CSC_COEFF_BITS))
        for addr, value in zip((CSC_R_OFFSET, CSC_G_OFFSET, CSC_B_OFFSET),
                               offsets):
            self.csc.write(addr, _to_field(value, CSC_OFFSET_BITS))


# ---------------------------------------------------------------------------
# The PYNQ hierarchy driver
# ---------------------------------------------------------------------------
# Importing PYNQ is optional so that everything above can be unit-tested on a
# workstation. On the board, importing this module registers Ov5647Camera as a
# driver for the `mipi` hierarchy.
try:
    from pynq import DefaultHierarchy
    from pynq.lib.video import VideoMode
    _HAVE_PYNQ = True
except ImportError:                                  # pragma: no cover
    DefaultHierarchy = object
    VideoMode = None
    _HAVE_PYNQ = False


if _HAVE_PYNQ:

    class Ov5647Camera(DefaultHierarchy):
        """Drop-in replacement for `pynq.lib.video.Pcam5C`, for the OV5647.

        Matches the same hierarchy, and PYNQ resolves hierarchy drivers newest
        first (`_hierarchy_drivers.appendleft`), so importing this module after
        pynq.lib.video is what makes `ol.mipi` an Ov5647Camera rather than a
        Pcam5C. Import it *before* constructing the Overlay.

        The public surface Pcam5C had is kept -- configure/start/stop/
        readframe/mode/tie/close -- so project 3's notebook does not care which
        camera is fitted. What is added is everything the blob made impossible:
        set_bayer_phase, set_gamma, set_color, exposure, white balance and the
        test pattern.
        """

        @staticmethod
        def checkhierarchy(description):
            return ("gpio_ip_reset" in description["ip"]
                    and "mipi_csi2_rx_subsyst" in description["ip"]
                    and "demosaic" in description["ip"]
                    and "gamma_lut" in description["ip"]
                    and "v_proc_sys" in description["ip"]
                    and "pixel_pack" in description["ip"])

        def __init__(self, description):
            super().__init__(description)
            self._vdma = self.axi_vdma
            self._i2c = I2CDevice(find_camera_i2c_bus())
            self.sensor = Ov5647Sensor(self._i2c)
            self.pipeline = VideoPipeline(self.demosaic, self.gamma_lut,
                                          self.v_proc_sys, self.gpio_ip_reset)
            # NOT resolved here, and nothing in this constructor may touch
            # `self.pixel_pack`. PYNQ builds an IP's driver on first attribute
            # access, and PYNQ's own PixelPacker writes register 0x10 in its
            # __init__ -- so the attribute access alone is a write. At this
            # point gpio_ip_reset is still asserted and pixel_pack is one of
            # the IPs it holds; a transaction to an IP in reset never
            # completes, ZynqMP has no bus timeout on the PL ports, and the
            # CPU wedges with no console and no panic. See `packer` below.
            self._packer = None
            self._mode = None

            # Before the first write into the 0xA0000000 aperture, and before
            # anything else that could go wrong: confirm the PS agrees with
            # this bitstream about how wide that port is. See
            # check_axi_port_width -- getting this wrong does not raise, it
            # hangs the board.
            self.check_port_width()

            self.sensor.check_id()

        def check_port_width(self, expected_bits=128):
            """Verify the PS-PL master port width before touching the PL."""
            from pynq import MMIO
            afi = MMIO(FPD_SLCR_AFI_FS & ~0xFFF, 0x1000)
            value = afi.read(FPD_SLCR_AFI_FS & 0xFFF)
            return check_axi_port_width(value, expected_bits)

        # -- the Pcam5C surface ---------------------------------------------
        def configure(self, videomode=None, mode=None, bayer_phase=None,
                      gamma=2.2):
            """Set up sensor, PL pipeline and VDMA for one video mode.

            `mode` selects the sensor readout ("1280x720" or "1920x1080").
            Unlike Pcam5C -- which hardcoded 720p60 inside the shared library
            and gave you no way to ask for anything else -- changing resolution
            here is just an argument.
            """
            if self._vdma.readchannel.running:
                self._vdma.readchannel.stop()

            if mode is None and videomode is not None:
                mode = f"{videomode.width}x{videomode.height}"
            sensor_mode = MODES[mode] if mode is not None else MODE_720P
            if videomode is None:
                videomode = VideoMode(sensor_mode.width, sensor_mode.height, 32)
            if (videomode.width, videomode.height) != (sensor_mode.width,
                                                       sensor_mode.height):
                raise ValueError(
                    f"VideoMode is {videomode.width}x{videomode.height} but "
                    f"the sensor mode is {sensor_mode.name}. The VDMA would "
                    f"tear every frame. Pass one or the other, not both.")

            # Order matters, downstream first. Everything from the CSI-2
            # receiver to the VDMA is a back-pressured AXI4-Stream, so a sensor
            # streaming into a pipeline that is not draining fills the
            # receiver's line buffer and overflows it -- and the receiver
            # reports that as a status bit nobody is reading, then delivers a
            # torn first frame. So configure leaves the sensor parked, and
            # nothing streams until start() has the VDMA running.
            # Release before stop(): stop() writes AP_CTRL on all three, and
            # in reset those writes never complete.
            self.pipeline.release_video_reset()
            self.pipeline.stop()
            self.sensor.configure(sensor_mode)          # leaves MIPI idle
            self.pipeline.configure(sensor_mode.width, sensor_mode.height,
                                    bayer_phase=bayer_phase, gamma=gamma)

            # First touch of pixel_pack in the whole class, and it happens
            # here on purpose: release_video_reset() above has already run.
            self.packer.bits_per_pixel = videomode.bits_per_pixel
            self._vdma.readchannel.mode = videomode
            self._mode = videomode
            return sensor_mode

        @property
        def packer(self):
            """The pixel packer's driver, resolved on first use.

            Deliberately lazy. Project 3's sv and vhdl builds carry a
            hand-written packer that PYNQ has no driver for; every other build
            carries PYNQ's HLS one, which arrives already driven, and whose
            constructor writes register 0x10. Resolving either of them costs a
            bus transaction, so it must not happen until the video reset is
            off -- which is why this is a property and not a line in __init__.
            See sw/pixel_packer.py for which driver gets picked and why the
            test is made against the class rather than the instance.
            """
            if self._packer is None:
                self._packer = pixel_packer.attach(self.pixel_pack)
            return self._packer

        def start(self):
            """VDMA first, then let the sensor onto the link, then tidy up."""
            self._vdma.readchannel.start()
            self.sensor.stream_on()
            # The sensor needs a frame or two to settle after the lanes come up,
            # and the VDMA hands back whatever was in the buffer before that.
            time.sleep(0.2)
            self.clear_vdma_errors()

        def clear_vdma_errors(self):
            """Clear the SOF error the free-running sensor latches at startup.

            Returns the error names that were set, so a caller can log them
            rather than have them disappear silently. Re-arms the channel if
            the error halted it.
            """
            dmasr = self.axi_vdma.read(VDMA_S2MM_DMASR)
            errors = vdma_errors(dmasr)
            if errors:
                self.axi_vdma.write(VDMA_S2MM_DMASR, VDMA_ERROR_MASK)
            if vdma_halted(self.axi_vdma.read(VDMA_S2MM_DMASR)):
                self._vdma.readchannel.start()
            return errors

        def stop(self):
            """And the reverse: take the sensor off the link before the VDMA."""
            self.sensor.stream_off()
            if self._vdma.readchannel.running:
                self._vdma.readchannel.stop()

        def close(self):
            self.stop()
            self.pipeline.stop()
            self._i2c.close()

        def readframe(self):
            return self._vdma.readchannel.readframe()

        async def readframe_async(self):
            return await self._vdma.readchannel.readframe_async()

        def tie(self, output):
            self._vdma.readchannel.tie(output._vdma.writechannel)

        @property
        def mode(self):
            return self._vdma.readchannel.mode

        @property
        def cacheable_frames(self):
            return self._vdma.readchannel.cacheable_frames

        @cacheable_frames.setter
        def cacheable_frames(self, value):
            self._vdma.readchannel.cacheable_frames = value

        # -- what the blob made impossible -----------------------------------
        def set_bayer_phase(self, phase):
            self.pipeline.set_bayer_phase(phase)

        def set_gamma(self, gamma):
            self.pipeline.set_gamma(gamma)

        def set_color(self, **kwargs):
            self.pipeline.set_color(**kwargs)

        def set_exposure(self, lines):
            return self.sensor.set_exposure(lines)

        def set_gain(self, gain):
            return self.sensor.set_gain(gain)

        def set_white_balance(self, r=1.0, g=1.0, b=1.0):
            """In the CSC -- the sensor's own gains are inert in raw mode."""
            self.pipeline.set_white_balance(r, g, b)

        def auto_white_balance(self, frame=None):
            """One grey-world pass over a captured frame.

            Not a loop and not continuous -- call it once when the light
            changes. Returns the (r, g, b) gains it applied, so the notebook
            can show them.
            """
            if frame is None:
                frame = self.readframe()
            b, g, r = (float(frame[:, :, c].mean()) for c in range(3))
            return self.pipeline.white_balance_from_means(b, g, r)

        def set_test_pattern(self, pattern="color_bars"):
            self.sensor.set_test_pattern(pattern)
