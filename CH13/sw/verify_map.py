#!/usr/bin/env python3
"""Confirm the DRP window base and read every channel.

The registers are at 0x1400, not the 0x200 this driver first assumed -- that
was the 7-series XADC Wizard's map, and on the System Management Wizard's
13-bit window it pointed at nothing, which read back as zeros and looked
exactly like a dead SYSMON.

Cross-checks against the PS sensors, which have been reporting correctly all
along: VCCINT should be ~0.85 V, VCCAUX ~1.80 V, and the die temperature
within a few degrees of the PS's ~41 C.

    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 \
        verify_map.py [sweep_seconds]
"""
import os
import sys
import time

SW_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SW_DIR)

import sysmon

from pynq import Overlay, MMIO

BIT = os.path.join(SW_DIR, os.pardir, "out", "xadc_sysmon.bit")
Overlay(BIT)
m = MMIO(0x80000000, 0x2000)

DRP_BASE = 0x1400


def drp(n):
    return m.read(DRP_BASE + 4 * n) & 0xFFFF


print("DRP window base 0x%04X\n" % DRP_BASE)

print("config registers (zero everywhere at the old base):")
for name, a in (("config0", 0x40), ("config1", 0x41), ("config2", 0x42),
                ("seq_chan0", 0x48), ("seq_avg0", 0x4A)):
    print("  %-10s drp 0x%02X = 0x%04X" % (name, a, drp(a)))

print("\ntemperature:")
raw = drp(0x00)
print("  now      raw 0x%04X  %.2f C" % (raw, sysmon.raw_to_celsius(raw)))
print("  min/max  %.2f / %.2f C  (latched by the macro since power-up)"
      % (sysmon.raw_to_celsius(drp(0x24)), sysmon.raw_to_celsius(drp(0x20))))

print("\nsupply rails:")
for name, a in (("vccint", 0x01), ("vccaux", 0x02), ("vccbram", 0x06),
                ("vccpsintlp", 0x0D), ("vccpsintfp", 0x0E), ("vccpsaux", 0x0F)):
    r = drp(a)
    print("  %-11s raw 0x%04X  %.4f V" % (name, r, sysmon.raw_to_supply_volts(r)))

raw = drp(0x03)
print("\nthe potentiometer on VP/VN:")
print("  raw 0x%04X  code %d/1023  %.4f V  (%.1f%% of the 1.0 V full scale)"
      % (raw, sysmon.adc_code(raw), sysmon.raw_to_external_volts(raw),
         100.0 * raw / 65536.0))

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 0
if secs:
    print("\n>>> SWEEP THE POT END TO END NOW -- sampling %.0f s" % secs)
    lo, hi = 0xFFFF, 0
    n = 0
    end = time.time() + secs
    while time.time() < end:
        r = drp(0x03)
        lo = min(lo, r)
        hi = max(hi, r)
        n += 1
        time.sleep(0.01)
    print("  samples %d" % n)
    print("  min  raw 0x%04X  %.4f V" % (lo, sysmon.raw_to_external_volts(lo)))
    print("  max  raw 0x%04X  %.4f V" % (hi, sysmon.raw_to_external_volts(hi)))
    span = sysmon.raw_to_external_volts(hi) - sysmon.raw_to_external_volts(lo)
    print("  span %.4f V  (%.1f%% of full scale)" % (span, 100.0 * span))
    if hi >= 0xFFC0:
        print("  WARNING: pegged at full scale -- the pot exceeds 1.0 V and is")
        print("  clipping. The volts shown are the ADC ceiling, not the pin.")
