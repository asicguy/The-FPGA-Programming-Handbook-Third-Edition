#!/usr/bin/env python3
"""Tests for the SYSMON driver.

Everything here runs against a fake register file, so it needs no board. The
hardware boundary is the MMIO object and that is the only thing mocked -- the
conversions, the register map and the liveness rule are the real code.

Run on the board, where pytest and numpy live:
    ssh xilinx@192.168.3.1 'cd ~/ch13_xadc/sw && \
        /usr/local/share/pynq-venv/bin/python3 -m pytest . -q -p no:cacheprovider'
"""
import pytest

import sysmon
from sysmon import Sysmon


class FakeMMIO:
    """The AXI4-Lite window, as a dict. Records writes so order can be checked."""

    def __init__(self, initial=None):
        self.words = dict(initial or {})
        self.writes = []

    def read(self, offset):
        return self.words.get(offset, 0)

    def write(self, offset, value):
        self.words[offset] = value
        self.writes.append((offset, value))


def a_live_sysmon(**channels):
    """A fake whose temperature is non-zero, so it passes the liveness rule."""
    words = {sysmon.drp_offset(sysmon.DRP_TEMPERATURE): 41602}
    for name, raw in channels.items():
        words[sysmon.drp_offset(getattr(sysmon, "DRP_" + name.upper()))] = raw
    return FakeMMIO(words)


# --- the DRP window ------------------------------------------------------

def test_maps_drp_address_zero_to_the_start_of_the_status_window():
    assert sysmon.drp_offset(0x00) == 0x1400


def test_maps_drp_address_to_a_word_per_register():
    # VP/VN is DRP 0x03, so four bytes per DRP address puts it at 0x140C.
    # Measured there on hardware: 0xA3DD, 0.640 V, the pot's wiper.
    assert sysmon.drp_offset(0x03) == 0x140C


def test_maps_the_first_control_register_above_the_status_window():
    # DRP 0x40 is Configuration Register 0, the first register past the
    # 64-entry status block.
    assert sysmon.drp_offset(0x40) == 0x1500


# --- conversions ---------------------------------------------------------

def test_converts_raw_to_celsius_using_the_ultrascale_formula():
    # 41602 is a real reading taken from this board's PS sensor, which the
    # running xilinx-ams driver reports as 43.08 C.
    assert sysmon.raw_to_celsius(41602) == pytest.approx(43.08, abs=0.01)


def test_temperature_of_raw_zero_is_far_below_any_real_temperature():
    # The offset in the formula. Nothing is at -280 C, which is exactly why a
    # zero reading is used as the not-converting signal.
    assert sysmon.raw_to_celsius(0) == pytest.approx(-280.23, abs=0.01)


def test_converts_supply_raw_over_a_three_volt_range():
    # Supply sensors are fixed at a 3.0 V full scale.
    assert sysmon.raw_to_supply_volts(18569) == pytest.approx(0.850, abs=0.001)


def test_supply_full_scale_is_three_volts():
    assert sysmon.raw_to_supply_volts(0xFFFF) == pytest.approx(3.0, abs=0.001)


def test_converts_external_channel_over_a_one_volt_range():
    # VP/VN in unipolar mode is 0 to 1.0 V, not 3.0 V. Using the supply
    # formula here would over-report the pot by exactly 3x.
    assert sysmon.raw_to_external_volts(0x8000) == pytest.approx(0.5, abs=0.001)


def test_external_channel_reads_zero_volts_at_raw_zero():
    assert sysmon.raw_to_external_volts(0) == 0.0


def test_extracts_the_ten_bit_code_from_the_left_justified_register():
    # SYSMONE4 is a 10-bit ADC and the result sits in bits [15:6].
    assert sysmon.adc_code(0xFFC0) == 1023


def test_ignores_the_unused_low_bits_when_extracting_the_code():
    assert sysmon.adc_code(0x803F) == sysmon.adc_code(0x8000)


# --- reading channels ----------------------------------------------------

def test_reads_the_pot_from_the_vp_vn_register():
    mmio = a_live_sysmon(vp_vn=0x8000)
    assert Sysmon(mmio).vp_vn_volts() == pytest.approx(0.5, abs=0.001)


def test_reads_temperature_as_celsius():
    assert Sysmon(a_live_sysmon()).temperature_celsius() == pytest.approx(43.08, abs=0.01)


def test_reads_vccint_as_a_supply_voltage():
    mmio = a_live_sysmon(vccint=18569)
    assert Sysmon(mmio).supply_volts("vccint") == pytest.approx(0.850, abs=0.001)


def test_rejects_a_channel_that_is_not_in_the_map():
    with pytest.raises(KeyError):
        Sysmon(a_live_sysmon()).supply_volts("vccnonsense")


def test_reads_every_supply_channel_it_advertises():
    mmio = a_live_sysmon()
    s = Sysmon(mmio)
    assert set(s.read_all()["supplies"]) == set(sysmon.SUPPLY_CHANNELS)


# --- the liveness rule ---------------------------------------------------
# The board's vendor overlay ships a SYSMON that is placed but answers zero on
# every register. Reporting that as "0.00 V, -280 C" would be worse than
# failing, so the driver refuses to read a sysmon that is not converting.

def test_refuses_to_read_a_sysmon_whose_registers_are_all_zero():
    with pytest.raises(sysmon.SysmonNotConverting):
        Sysmon(FakeMMIO()).temperature_celsius()


def test_names_the_symptom_when_the_sysmon_is_not_converting():
    with pytest.raises(sysmon.SysmonNotConverting, match="temperature"):
        Sysmon(FakeMMIO()).vp_vn_volts()


def test_accepts_a_sysmon_that_is_converting():
    assert Sysmon(a_live_sysmon()).is_converting() is True


def test_reports_a_dead_sysmon_without_raising_when_asked_directly():
    # is_converting() is the question; the exception is for the readers.
    assert Sysmon(FakeMMIO()).is_converting() is False


# --- the fabric activity counter -----------------------------------------
# hdl/sysmon_activity.sv counts the SYSMONE4's eoc/eos pulses in fabric,
# because they are single-cycle at 100 MHz and software sampling would miss
# them. These tests pin down the packing so the RTL and the driver cannot
# drift apart -- tb_sysmon_activity.sv asserts the same layout from the other
# side.

def a_status_word(eos_count=0, chan_changes=0, busy=0, channel=0):
    return ((eos_count & 0xFFFF) << 16 | (chan_changes & 0xFF) << 8
            | (busy & 1) << 7 | (channel & 0x3F))


def test_decodes_eos_count_from_the_high_half():
    assert sysmon.decode_status(a_status_word(eos_count=1234))["eos_count"] == 1234


def test_decodes_channel_from_the_low_six_bits():
    assert sysmon.decode_status(a_status_word(channel=0x2A))["channel"] == 0x2A


def test_decodes_channel_changes():
    assert sysmon.decode_status(a_status_word(chan_changes=77))["chan_changes"] == 77


def test_decodes_busy():
    assert sysmon.decode_status(a_status_word(busy=1))["busy"] is True


def test_ignores_the_reserved_bit():
    assert sysmon.decode_status(1 << 6)["channel"] == 0


def test_reads_the_eoc_count_from_gpio_channel_one():
    mmio = FakeMMIO({sysmon.GPIO_DATA: 4242})
    assert sysmon.Activity(mmio).snapshot()["eoc_count"] == 4242


def test_reads_the_status_word_from_gpio_channel_two():
    mmio = FakeMMIO({sysmon.GPIO2_DATA: a_status_word(channel=9)})
    assert sysmon.Activity(mmio).snapshot()["channel"] == 9


# The question the whole diagnostic exists to answer, reduced to a pure
# comparison of two snapshots so it can be tested without a board or a sleep.

def test_reports_converting_when_the_eoc_count_advances():
    a = {"eoc_count": 10, "eos_count": 0, "chan_changes": 0}
    b = {"eoc_count": 11, "eos_count": 0, "chan_changes": 0}
    assert sysmon.advanced(a, b) is True


def test_reports_converting_when_only_the_sequence_counter_advances():
    a = {"eoc_count": 5, "eos_count": 1, "chan_changes": 0}
    b = {"eoc_count": 5, "eos_count": 2, "chan_changes": 0}
    assert sysmon.advanced(a, b) is True


def test_reports_not_converting_when_nothing_advances():
    a = {"eoc_count": 7, "eos_count": 3, "chan_changes": 2}
    assert sysmon.advanced(a, dict(a)) is False


def test_treats_a_wrapped_counter_as_advancing():
    # eos_count is 16 bits and chan_changes 8, so both wrap. A wrap is still
    # movement, and reading it as "went backwards, therefore dead" would be
    # exactly the wrong conclusion.
    a = {"eoc_count": 0, "eos_count": 65535, "chan_changes": 0}
    b = {"eoc_count": 0, "eos_count": 0, "chan_changes": 0}
    assert sysmon.advanced(a, b) is True


# --- the LED bar's output GPIO -------------------------------------------

def test_writes_the_level_to_the_output_gpio():
    mmio = FakeMMIO()
    sysmon.PotBar(mmio).set_level(0xA3DD)
    assert mmio.writes == [(sysmon.GPIO_DATA, 0xA3DD)]


def test_truncates_a_level_wider_than_the_gpio():
    # The GPIO is 16 bits. Letting a wider value through would wrap silently
    # and send the bar back to the bottom at the top of the pot's travel.
    mmio = FakeMMIO()
    sysmon.PotBar(mmio).set_level(0x1FFFF)
    assert mmio.writes == [(sysmon.GPIO_DATA, 0xFFFF)]


# --- normalising the bar to the pot's real travel ------------------------
# Measured on this board: the wiper spans 0x0000 to 0xDAC1, 85.5% of the
# channel's full scale, so a bar scaled to the ADC's range can only ever reach
# seven of its eight LEDs. These tests cover the rescale.

def test_normalises_the_bottom_of_travel_to_zero():
    assert sysmon.normalize_pot(0) == 0


def test_normalises_the_top_of_travel_to_full_scale():
    assert sysmon.normalize_pot(sysmon.POT_FULL_SCALE_RAW) == 0xFFFF


def test_normalises_mid_travel_to_about_half():
    half = sysmon.normalize_pot(sysmon.POT_FULL_SCALE_RAW // 2)
    assert abs(half - 0x8000) < 4


def test_clamps_a_reading_above_the_measured_maximum():
    # Noise, a warmer day, or a different board can push the reading past the
    # value measured here. Without the clamp the scaled result exceeds 16 bits
    # and wraps, sending the bar to the BOTTOM at the top of the pot's travel.
    assert sysmon.normalize_pot(0xFFFF) == 0xFFFF


def test_normalisation_is_monotonic():
    seen = [sysmon.normalize_pot(r) for r in range(0, 0x10000, 0x400)]
    assert seen == sorted(seen)


def test_set_reading_writes_the_normalised_value():
    mmio = FakeMMIO()
    sysmon.PotBar(mmio).set_reading(sysmon.POT_FULL_SCALE_RAW)
    assert mmio.writes == [(sysmon.GPIO_DATA, 0xFFFF)]


def test_set_level_still_writes_the_raw_value_unchanged():
    # The walk-the-bar demo drives exact LED steps and must not be rescaled.
    mmio = FakeMMIO()
    sysmon.PotBar(mmio).set_level(0x8000)
    assert mmio.writes == [(sysmon.GPIO_DATA, 0x8000)]
