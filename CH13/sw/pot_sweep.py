#!/usr/bin/env python3
"""Sweep test for the potentiometer on VP/VN.

Samples at 100 Hz while you turn the pot, mirrors the value onto the eight
white LEDs so there is immediate feedback at the board, and prints a bar once
a second so the sweep is visible in the transcript afterwards.

Reports the travel actually achieved, whether it clipped at either end, and
how much of the range was covered.
"""
import os, sys, time
sys.path.insert(0, "/home/xilinx/ch13_xadc/sw")

from pynq import Overlay, MMIO
import sysmon
from sysmon import Sysmon, PotBar

DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0

Overlay("/home/xilinx/ch13_xadc/out/xadc_sysmon.bit")
sm  = Sysmon(MMIO(sysmon.SYSMON_BASE,   sysmon.AXI_WINDOW_SIZE))
bar = PotBar(MMIO(sysmon.POT_GPIO_BASE, 0x1000))

if not sm.is_converting():
    sys.exit("the SYSMON is not converting -- wrong bitstream loaded?")

print("=" * 68)
print(" TURN THE POT FROM ONE END TO THE OTHER -- %.0f seconds" % DURATION)
print(" The eight white LEDs follow it. Take it to BOTH stops.")
print("=" * 68, flush=True)

lo, hi = 0xFFFF, 0
buckets = set()
samples = 0
start = time.time()
next_print = start + 1.0

while True:
    now = time.time()
    if now - start >= DURATION:
        break
    raw = sm.vp_vn_raw()
    bar.set_reading(raw)
    lo = min(lo, raw)
    hi = max(hi, raw)
    buckets.add(sysmon.normalize_pot(raw) >> 13)   # which of the 8 LED steps
    samples += 1
    if now >= next_print:
        frac = raw / 65536.0
        n = int(round(frac * 40))
        print("  %4.1fs  %.4f V  %5.1f%%  |%s%s|  min %.4f  max %.4f"
              % (now - start, sysmon.raw_to_external_volts(raw), 100.0 * frac,
                 "#" * n, "." * (40 - n),
                 sysmon.raw_to_external_volts(lo),
                 sysmon.raw_to_external_volts(hi)), flush=True)
        next_print += 1.0
    time.sleep(0.01)

v_lo = sysmon.raw_to_external_volts(lo)
v_hi = sysmon.raw_to_external_volts(hi)

print("\n" + "=" * 68)
print(" RESULT   %d samples in %.0f s" % (samples, DURATION))
print("=" * 68)
print("  minimum   raw 0x%04X  code %4d  %.4f V  (%5.1f%% of full scale)"
      % (lo, sysmon.adc_code(lo), v_lo, 100.0 * lo / 65536.0))
print("  maximum   raw 0x%04X  code %4d  %.4f V  (%5.1f%% of full scale)"
      % (hi, sysmon.adc_code(hi), v_hi, 100.0 * hi / 65536.0))
print("  travel    %.4f V  = %.1f%% of the channel's 1.0 V range"
      % (v_hi - v_lo, 100.0 * (v_hi - v_lo)))
print("  LED steps visited: %d of 8" % len(buckets))

print()
if hi >= 0xFFC0:
    print("  CLIPPING AT THE TOP: the pot reaches the ADC's 1.0 V ceiling, so")
    print("  readings near full scale are the ADC's limit, not the pin.")
elif hi < 0xF000:
    print("  Top of travel is %.4f V, comfortably inside the 1.0 V range." % v_hi)
if lo <= 0x003F:
    print("  Bottom of travel reaches 0 V.")
elif lo > 0x1000:
    print("  Bottom of travel only reaches %.4f V -- the pot does not swing to 0."
          % v_lo)

print("\n  temperature now %.2f C   vccint %.4f V"
      % (sm.temperature_celsius(), sm.supply_volts("vccint")))
