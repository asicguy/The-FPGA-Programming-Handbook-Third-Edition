#!/usr/bin/env python3
"""The UltraScale+ SYSMON: on-chip temperature, supply rails, and VP/VN.

On 7-series parts this block is called XADC and it is a 12-bit converter. On
UltraScale+ it is SYSMONE4, reached through the System Management Wizard
rather than the XADC Wizard, and the ADC is 10 bits. Both store results
left-justified in a 16-bit register, so code written against the full 16-bit
value is correct on either -- which is why every conversion here divides by
65536 rather than by 4096 or 1024.

THE DRIVER REFUSES TO READ A SYSMON THAT IS NOT CONVERTING

The AUP-ZU3's own PYNQ base overlay instantiates one of these, places it
(utilization reports SYSMONE4 Used=1), and it answers zero on every register:
temperature included, config writes not sticking, and Linux's xilinx-ams
driver reporting in_temp20_raw = 0 for the PL while the PS sensors read
correctly. A driver that trusted those registers would report a comfortable
0.000 V and a temperature of -280 C rather than admitting it had learned
nothing. So `temperature_celsius()` and friends raise rather than return, and
`is_converting()` exists for callers that want to ask instead of catch.

Zero temperature is the signal because the conversion's own offset puts raw 0
at -280 C. No silicon is at -280 C, and no working sysmon reports raw 0 for
temperature even at power-up.
"""

# --- the AXI4-Lite wrapper's own registers --------------------------------
# These belong to the wizard, not to the SYSMONE4 macro, and they answer even
# when the macro does not -- which is exactly how the vendor overlay's fault
# stayed invisible.
REG_SRR = 0x00      # software reset for the IP: write 0x0A
REG_SR = 0x04       # status: BUSY, EOC, EOS, current CHANNEL
REG_AOSR = 0x08
REG_CONVSTR = 0x0C
REG_SYSMONRR = 0x10  # reset for the SYSMONE4 hard macro: write 0x0A

# --- the DRP window -------------------------------------------------------
# The macro's DRP address space is mapped one 32-bit word per DRP address.
# DRP 0x00-0x3F are the status registers and 0x40-0x7F the control registers,
# so the control block starts 0x100 further on, at 0x1500.
#
# 0x1400 IS NOT 0x200, AND THE DIFFERENCE COST A DAY.
#
# 0x200 is the 7-SERIES XADC Wizard's DRP base. The System Management Wizard's
# AXI window is 13 bits wide -- 8 KB, twice the size -- and puts the DRP at
# 0x1400. Reads at 0x200 land on nothing and come back as zeros, which is
# indistinguishable from a SYSMON that is present, placed and not converting.
# It was diagnosed as exactly that, wrongly, until the macro's own eoc pin was
# counted in fabric (hdl/sysmon_activity.sv) and showed ~5400 conversions a
# second while every register still read zero.
#
# The lesson, and it is why scan_window.py is kept: when a whole register
# window reads zero, question the ADDRESS before concluding the hardware is
# dead. Verify the map against something whose value is known independently --
# here VCCINT had to be 0.85 V and VCCAUX 1.80 V, which the PS sensors were
# reporting correctly the entire time.
#
# The window aliases: bit 11 of the address is ignored, so 0x1C00 mirrors
# 0x1400. Use 0x1400.
DRP_WINDOW_BASE = 0x1400

# The AXI window is 8 KB. Mapping only 4 KB puts the DRP registers outside the
# mapping entirely.
AXI_WINDOW_SIZE = 0x2000

DRP_TEMPERATURE = 0x00
DRP_VCCINT = 0x01
DRP_VCCAUX = 0x02
DRP_VP_VN = 0x03
DRP_VREFP = 0x04
DRP_VREFN = 0x05
DRP_VCCBRAM = 0x06
DRP_VCCPSINTLP = 0x0D
DRP_VCCPSINTFP = 0x0E
DRP_VCCPSAUX = 0x0F

# Max/min holding registers. The macro latches the extremes since power-up on
# its own -- software does not have to poll to catch a transient.
DRP_MAX_TEMPERATURE = 0x20
DRP_MIN_TEMPERATURE = 0x24

DRP_CONFIG0 = 0x40
DRP_CONFIG1 = 0x41
DRP_CONFIG2 = 0x42

# The supply rails this design's wizard enables, in the order a display should
# show them: PL rails first, then the PS rails the PL sysmon can also see.
SUPPLY_CHANNELS = {
    "vccint": DRP_VCCINT,
    "vccaux": DRP_VCCAUX,
    "vccbram": DRP_VCCBRAM,
    "vccpsintlp": DRP_VCCPSINTLP,
    "vccpsintfp": DRP_VCCPSINTFP,
    "vccpsaux": DRP_VCCPSAUX,
}

# --- conversion constants -------------------------------------------------
# UG580's UltraScale formula. The running xilinx-ams driver on this board
# agrees independently: it reports scale 7.771514892 millidegrees per LSB
# (= 509.3140064 / 65536 degrees) and offset -36058 LSB (= -280.2 C).
TEMP_SCALE = 509.3140064
TEMP_OFFSET = 280.23087870

# Supply sensors have a fixed 3.0 V full scale; the external VP/VN channel in
# unipolar mode has a fixed 1.0 V full scale. Neither is adjustable, so a pot
# whose divider exceeds 1.0 V clips rather than scaling.
SUPPLY_FULL_SCALE = 3.0
EXTERNAL_FULL_SCALE = 1.0

ADC_BITS = 10


class SysmonNotConverting(RuntimeError):
    """The SYSMONE4 is present on the bus but producing no measurements."""


def drp_offset(drp_address):
    """Byte offset in the AXI window of a given DRP register address."""
    return DRP_WINDOW_BASE + 4 * drp_address


def raw_to_celsius(raw16):
    """Left-justified 16-bit temperature reading to degrees Celsius."""
    return raw16 * TEMP_SCALE / 65536.0 - TEMP_OFFSET


def raw_to_supply_volts(raw16):
    """Left-justified 16-bit supply reading to volts, over the 3.0 V range."""
    return raw16 * SUPPLY_FULL_SCALE / 65536.0


def raw_to_external_volts(raw16):
    """Left-justified 16-bit VP/VN reading to volts, over the 1.0 V range."""
    return raw16 * EXTERNAL_FULL_SCALE / 65536.0


def adc_code(raw16):
    """The ADC's own code, with the unused low bits of the register dropped."""
    return raw16 >> (16 - ADC_BITS)


class Sysmon:
    """Reads the System Management Wizard's AXI4-Lite window.

    Takes anything with read(offset) and write(offset, value), which is PYNQ's
    MMIO and also the fake the tests use.
    """

    def __init__(self, mmio):
        self.mmio = mmio

    # --- raw access ------------------------------------------------------

    def drp_read(self, drp_address):
        return self.mmio.read(drp_offset(drp_address)) & 0xFFFF

    def status_register(self):
        return self.mmio.read(REG_SR)

    # --- liveness --------------------------------------------------------

    def is_converting(self):
        """True if the macro is producing measurements at all.

        Temperature is the probe because it is the one channel that is always
        converted whatever the sequencer is configured for, and because its
        conversion offset makes raw 0 physically impossible.
        """
        return self.drp_read(DRP_TEMPERATURE) != 0

    def _require_converting(self):
        if not self.is_converting():
            raise SysmonNotConverting(
                "the SYSMON reads 0 for temperature, which is -280 C and "
                "therefore not a measurement -- the SYSMONE4 macro is not "
                "converting. The AXI wrapper answering is not evidence that "
                "it is: the board's own base overlay fails exactly this way. "
                "Check that the loaded bitstream is this project's."
            )

    # --- measurements ----------------------------------------------------

    def temperature_celsius(self):
        self._require_converting()
        return raw_to_celsius(self.drp_read(DRP_TEMPERATURE))

    def temperature_extremes_celsius(self):
        """(min, max) since power-up, latched by the macro itself."""
        self._require_converting()
        return (raw_to_celsius(self.drp_read(DRP_MIN_TEMPERATURE)),
                raw_to_celsius(self.drp_read(DRP_MAX_TEMPERATURE)))

    def supply_volts(self, name):
        self._require_converting()
        return raw_to_supply_volts(self.drp_read(SUPPLY_CHANNELS[name]))

    def vp_vn_raw(self):
        self._require_converting()
        return self.drp_read(DRP_VP_VN)

    def vp_vn_volts(self):
        return raw_to_external_volts(self.vp_vn_raw())

    def vp_vn_fraction(self):
        """The pot's position as 0.0 to 1.0 of the channel's full scale."""
        return self.vp_vn_raw() / 65536.0

    def read_all(self):
        """Everything at once, for a display that refreshes as a unit."""
        self._require_converting()
        raw = self.drp_read(DRP_VP_VN)
        return {
            "temperature": self.temperature_celsius(),
            "supplies": {n: raw_to_supply_volts(self.drp_read(a))
                         for n, a in SUPPLY_CHANNELS.items()},
            "external": {
                "raw": raw,
                "code": adc_code(raw),
                "volts": raw_to_external_volts(raw),
                "fraction": raw / 65536.0,
            },
        }


# ---------------------------------------------------------------------------
# The fabric activity counter
# ---------------------------------------------------------------------------
# hdl/sysmon_activity.sv watches the SYSMONE4's eoc_out, eos_out, busy_out and
# channel_out pins directly. Those come off the macro itself and pass through
# NEITHER the DRP register path NOR the PS AMS block -- the two paths that
# report nothing on this board -- so they can establish whether the converter
# is running when nothing else can.
#
# The counting happens in fabric because eoc_out and eos_out are single-cycle
# pulses at 100 MHz. Software polling a GPIO manages a few thousand reads a
# second, would miss essentially every pulse, and would report a dead
# converter whether or not one was running.

# Standard AXI GPIO map. Both channels are inputs, so the TRI registers are
# fixed by the hardware configuration and are never written.
GPIO_DATA = 0x00    # channel 1: eoc_count, full 32 bits
GPIO2_DATA = 0x08   # channel 2: the packed status word

# status_word packing, matching hdl/sysmon_activity.sv exactly. Both sides are
# asserted against this layout -- tb_sysmon_activity.sv from the RTL side and
# test_sysmon.py from here -- so they cannot drift apart silently.
STATUS_EOS_SHIFT = 16
STATUS_EOS_MASK = 0xFFFF
STATUS_CHAN_CHANGES_SHIFT = 8
STATUS_CHAN_CHANGES_MASK = 0xFF
STATUS_BUSY_BIT = 7
STATUS_CHANNEL_MASK = 0x3F


def decode_status(word):
    """Unpack the activity counter's status word."""
    return {
        "eos_count": (word >> STATUS_EOS_SHIFT) & STATUS_EOS_MASK,
        "chan_changes": ((word >> STATUS_CHAN_CHANGES_SHIFT)
                         & STATUS_CHAN_CHANGES_MASK),
        "busy": bool((word >> STATUS_BUSY_BIT) & 1),
        "channel": word & STATUS_CHANNEL_MASK,
    }


def advanced(before, after):
    """Did anything move between two snapshots?

    Inequality rather than a greater-than, because eos_count is 16 bits and
    chan_changes only 8, so both wrap. A wrap is still movement; reading it as
    "the counter went backwards, therefore dead" would draw exactly the wrong
    conclusion from exactly the evidence that proves the macro is alive.
    """
    return any(before[k] != after[k]
               for k in ("eoc_count", "eos_count", "chan_changes"))


class Activity:
    """Reads the activity counter's AXI GPIO."""

    def __init__(self, mmio):
        self.mmio = mmio

    def snapshot(self):
        snap = {"eoc_count": self.mmio.read(GPIO_DATA)}
        snap.update(decode_status(self.mmio.read(GPIO2_DATA)))
        return snap

    def is_converting(self, settle=0.25):
        """Sample twice and report whether the converter moved."""
        import time
        before = self.snapshot()
        time.sleep(settle)
        after = self.snapshot()
        return advanced(before, after), before, after


# --- addresses in project_xadc_sysmon's block design ----------------------
# Kept here so the notebook and the scripts cannot disagree about them; they
# must match the corresponding `set` lines in project_xadc_sysmon/build.tcl.
SYSMON_BASE = 0x80000000
ACTIVITY_BASE = 0x80010000
POT_GPIO_BASE = 0x80020000


# The top of the potentiometer's travel, MEASURED on this board: swept end to
# end over 30 s and 2965 samples, the wiper spans 0x0000 to 0xDAC1 -- 0 V to
# 0.8545 V, 85.5% of the channel's fixed 1.0 V full scale. It never clips,
# which is the important part, but it never reaches full scale either.
#
# A bar scaled to the ADC's range therefore tops out at seven of its eight
# LEDs. normalize_pot() rescales the DISPLAY to the pot's real travel so a full
# turn fills the bar; the reported volts stay the true measurement.
#
# This is a board-specific constant obtained by measurement, not a datasheet
# value. On different hardware, re-measure with sw/pot_sweep.py and change it
# here.
POT_FULL_SCALE_RAW = 0xDAC1


def normalize_pot(raw16, full_scale=POT_FULL_SCALE_RAW):
    """Rescale a VP/VN reading so the pot's real travel spans 0..0xFFFF.

    Clamped at the top. Without the clamp a reading above the measured maximum
    -- noise, a warmer die, another board -- scales past 16 bits and wraps,
    which sends the bar to the BOTTOM exactly at the top of the pot's travel.
    """
    return min(raw16 * 0xFFFF // full_scale, 0xFFFF)


class PotBar:
    """The output GPIO feeding hdl/pot_bar.sv's thermometer decoder.

    Software is in this path because the wizard owns the SYSMONE4's only DRP
    port -- see the note at the top of hdl/pot_bar.sv. The decode itself is
    still hardware; only the value's journey goes through the PS.
    """

    GPIO_WIDTH_MASK = 0xFFFF

    def __init__(self, mmio):
        self.mmio = mmio

    def set_level(self, raw16):
        """Write a level straight through, with no rescaling.

        For driving exact LED steps. Use set_reading() for a live measurement.
        """
        self.mmio.write(GPIO_DATA, raw16 & self.GPIO_WIDTH_MASK)

    def set_reading(self, raw16):
        """Show a VP/VN reading, rescaled to the pot's measured travel."""
        self.set_level(normalize_pot(raw16))
