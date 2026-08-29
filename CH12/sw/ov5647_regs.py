# SPDX-License-Identifier: GPL-2.0
#
# OV5647 sensor register tables.
#
# ---------------------------------------------------------------------------
# PROVENANCE, AND WHY THIS ONE FILE IS GPL-2.0
# ---------------------------------------------------------------------------
# The tables below are transcribed from the Linux kernel's V4L2 driver for the
# OmniVision OV5647, `drivers/media/i2c/ov5647.c`, which carries:
#
#     SPDX-License-Identifier: GPL-2.0
#     Based on Samsung S5K6AAFX SXGA 1/6" 1.3M CMOS Image Sensor driver
#     Copyright (C) 2011 Sylwester Nawrocki <s.nawrocki@samsung.com>
#     Based on Omnivision OV7670 Camera Driver
#     Copyright (C) 2006-7 Jonathan Corbet <corbet@lwn.net>
#     Copyright (C) 2016, Synopsys, Inc.
#
# The rest of CH12 is GPL-3.0, and GPL-2.0-only does not upgrade to GPL-3.0.
# So this file stays under its original licence rather than being absorbed into
# the surrounding tree, and it is kept to *only* the material that came from
# there -- register/value tables and nothing else. Every line of logic that
# acts on these tables lives in `ov5647.py`, which is the chapter's own code.
#
# Keeping the split at a file boundary is the point. If you reuse CH12, this
# file travels under GPL-2.0 and the others under GPL-3.0.
#
# ---------------------------------------------------------------------------
# WHAT THE SENSOR NEEDS, IN THE ORDER IT NEEDS IT
# ---------------------------------------------------------------------------
# The OV5647 is a raw Bayer sensor: it has no ISP worth the name, and what
# comes out of the MIPI link is RAW10 Bayer that the PL has to demosaic. That
# is why the camera hierarchy in `common/mipi_hier.tcl` has a demosaic block
# and a gamma LUT in it at all.
#
# Bring-up is three writes deep:
#
#   1. COMMON_REGS   -- PLL, analog bias, MIPI lane setup. Mode-independent.
#   2. a mode table  -- windowing, binning, output size. See MODES in ov5647.py.
#   3. stream on     -- ov5647.py does this, because it is logic, not a table.
#
# COMMON_REGS ends with {0x3503, 0x03}, which turns *off* the on-chip auto
# exposure and auto gain: the kernel driver expects libcamera to run the AE
# loop in userspace. CH12 does not have libcamera, so `Ov5647.configure()`
# clears 0x3503 back to 0x00 and lets the sensor do it -- see AEC_AGC_AUTO in
# ov5647.py. Without that you get a correctly-demosaiced photograph of the
# inside of the lens cap.

# --- COMMON_REGS -----------------------------------------------------------
# 0x3034/0x3035/0x3036/0x3106 are the PLL. As programmed here with the module's
# own 25 MHz oscillator they give a 218.75 MHz link frequency, so 437.5 Mbps on
# each of the two MIPI lanes. That number is the one that has to agree with
# CONFIG.C_HS_LINE_RATE on the CSI-2 receiver in common/mipi_hier.tcl.
#
# 0x3630..0x3f06 are analog bias and timing trim. They have no derivation --
# they are OmniVision's characterisation values, and they are copied here as
# they are copied in every other driver for this part.
COMMON_REGS = (
    (0x0100, 0x00),   # SW_STANDBY: stop streaming before touching anything
    (0x0103, 0x01),   # SW_RESET
    (0x3034, 0x1A),   # PLL: 10-bit mode
    (0x3035, 0x21),   # PLL: system divider
    (0x303C, 0x11),   # PLL: PLLS control
    (0x3106, 0xF5),   # PLL: clock divider / SRB control
    (0x3827, 0xEC),
    (0x370C, 0x03),
    (0x5000, 0x06),   # ISP control: BPC/WPC on, most of the ISP off (raw out)
    (0x5003, 0x08),
    (0x5A00, 0x08),
    (0x3000, 0x00),   # pad output enable: all off until the mode is loaded
    (0x3001, 0x00),
    (0x3002, 0x00),
    (0x3016, 0x08),
    (0x3017, 0xE0),
    (0x3018, 0x44),   # MIPI: 2 data lanes
    (0x301C, 0xF8),
    (0x301D, 0xF0),
    (0x3A18, 0x00),   # AEC gain ceiling
    (0x3A19, 0xF8),
    (0x3C01, 0x80),
    (0x3B07, 0x0C),
    (0x3630, 0x2E),   # -- analog trim, no derivation, from OmniVision --
    (0x3632, 0xE2),
    (0x3633, 0x23),
    (0x3634, 0x44),
    (0x3636, 0x06),
    (0x3620, 0x64),
    (0x3621, 0xE0),
    (0x3600, 0x37),
    (0x3704, 0xA0),
    (0x3703, 0x5A),
    (0x3715, 0x78),
    (0x3717, 0x01),
    (0x3731, 0x02),
    (0x370B, 0x60),
    (0x3705, 0x1A),
    (0x3F05, 0x02),
    (0x3F06, 0x10),
    (0x3F01, 0x0A),
    (0x3A08, 0x01),   # -- AEC/AGC banding filter and limits --
    (0x3A0F, 0x58),
    (0x3A10, 0x50),
    (0x3A1B, 0x58),
    (0x3A1E, 0x50),
    (0x3A11, 0x60),
    (0x3A1F, 0x28),
    (0x4001, 0x02),   # BLC start line
    (0x4000, 0x09),   # BLC enable
    (0x3503, 0x03),   # AEC/AGC -> manual. ov5647.py overrides this; see above.
)

# --- BINNED_2X2_REGS -------------------------------------------------------
# The 2x2-binned readout: the whole 2592x1944 array averaged down to 1296x972
# at 87.5 Mpixel/s. CH12's 720p mode is this table with the vertical window and
# the output size overridden -- see MODES in ov5647.py -- because the OV5647
# has no native 1280x720 and 720p is what the rest of the chapter is built for.
#
# 0x3821 = 0x03 is horizontal binning *plus* the mirror bit, and 0x3820 = 0x41
# is vertical binning. The mirror bit is not cosmetic: it moves the Bayer phase
# by one column, which is why the demosaic block's phase is established by
# experiment in the project 1 notebook rather than asserted here.
BINNED_2X2_REGS = (
    (0x3036, 0x69),   # PLL multiplier -> 218.75 MHz link
    (0x3821, 0x03),   # horizontal binning + mirror
    (0x3820, 0x41),   # vertical binning
    (0x3612, 0x59),
    (0x3618, 0x00),
    (0x5002, 0x41),
    (0x3800, 0x00),   # X_ADDR_START = 0
    (0x3801, 0x00),
    (0x3802, 0x00),   # Y_ADDR_START = 0
    (0x3803, 0x00),
    (0x3804, 0x0A),   # X_ADDR_END = 2623
    (0x3805, 0x3F),
    (0x3806, 0x07),   # Y_ADDR_END = 1955
    (0x3807, 0xA3),
    (0x3808, 0x05),   # X_OUTPUT_SIZE = 1296
    (0x3809, 0x10),
    (0x380A, 0x03),   # Y_OUTPUT_SIZE = 972
    (0x380B, 0xCC),
    (0x3811, 0x0C),   # ISP X offset = 12
    (0x3813, 0x06),   # ISP Y offset = 6
    (0x3814, 0x31),   # X_INC: odd 3 / even 1  -> 2x subsample
    (0x3815, 0x31),   # Y_INC: odd 3 / even 1  -> 2x subsample
    (0x3A09, 0x28),
    (0x3A0A, 0x00),
    (0x3A0B, 0xF6),
    (0x3A0D, 0x08),
    (0x3A0E, 0x06),
    (0x4004, 0x04),
    (0x4837, 0x16),   # MIPI PCLK period
    (0x4800, 0x24),
    (0x350A, 0x00),   # gain = 0x0010 = 1.00x
    (0x350B, 0x10),
    (0x3500, 0x00),   # exposure = 0x1AF0 >> 4 = 431 lines
    (0x3501, 0x1A),
    (0x3502, 0xF0),
    (0x3212, 0xA0),   # group latch
    (0x0100, 0x01),   # SW_STANDBY off -> streaming
)

# --- FULL_1080P_REGS -------------------------------------------------------
# 1:1 readout of a 1928x1080 window out of the middle of the array -- no
# binning, so a narrower field of view than the binned mode but full detail.
FULL_1080P_REGS = (
    (0x3036, 0x69),   # same PLL -> same 218.75 MHz link
    (0x3821, 0x02),   # mirror, no horizontal binning
    (0x3820, 0x00),   # no vertical binning
    (0x3612, 0x5B),
    (0x3618, 0x04),
    (0x5002, 0x41),
    (0x3814, 0x11),   # X_INC 1:1
    (0x3815, 0x11),   # Y_INC 1:1
    (0x3708, 0x64),
    (0x3709, 0x12),
    (0x3800, 0x01),   # X_ADDR_START = 348
    (0x3801, 0x5C),
    (0x3802, 0x01),   # Y_ADDR_START = 434
    (0x3803, 0xB2),
    (0x3804, 0x08),   # X_ADDR_END = 2275
    (0x3805, 0xE3),
    (0x3806, 0x05),   # Y_ADDR_END = 1521
    (0x3807, 0xF1),
    (0x3808, 0x07),   # X_OUTPUT_SIZE = 1920
    (0x3809, 0x80),
    (0x380A, 0x04),   # Y_OUTPUT_SIZE = 1080
    (0x380B, 0x38),
    (0x3811, 0x04),   # ISP X offset = 4
    (0x3813, 0x02),   # ISP Y offset = 2
    (0x3A09, 0x4B),
    (0x3A0A, 0x01),
    (0x3A0B, 0x13),
    (0x3A0D, 0x04),
    (0x3A0E, 0x03),
    (0x4004, 0x04),
    (0x4837, 0x19),   # MIPI PCLK period
    (0x4800, 0x34),
    (0x0100, 0x01),   # SW_STANDBY off -> streaming
)

# Pad output enable. COMMON_REGS leaves the pads disabled; these turn the MIPI
# and clock outputs back on once a mode is loaded.
OE_ENABLE_REGS = (
    (0x3000, 0x0F),
    (0x3001, 0xFF),
    (0x3002, 0xE4),
)

OE_DISABLE_REGS = (
    (0x3000, 0x00),
    (0x3001, 0x00),
    (0x3002, 0x00),
)

# ISP test pattern, register 0x503D. The colour bars are how the project 1
# notebook establishes the Bayer phase: they are a known image that needs no
# lens, no light and no correct exposure to be recognisable.
TEST_PATTERN_OFF = 0x00
TEST_PATTERN_COLOR_BARS = 0x80
TEST_PATTERN_COLOR_SQUARES = 0x82
TEST_PATTERN_RANDOM = 0x81
