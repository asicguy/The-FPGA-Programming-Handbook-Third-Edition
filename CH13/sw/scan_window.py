#!/usr/bin/env python3
"""Find where the SYSMON's registers actually live in the AXI window.

The macro is converting -- hdl/sysmon_activity.sv counts ~5400 conversions a
second on its eoc pin -- so the zeros were never a dead SYSMON. They were
almost certainly the wrong address: this IP's s_axi_awaddr is 13 bits, an 8 KB
window, while the DRP base of 0x200 assumed here came from the 7-series XADC
Wizard's much smaller map.

So stop assuming and look. Scan the whole window and report anything non-zero,
flagging values in the range a real temperature would occupy: about 42 C is
raw (42 + 280.23) * 65536 / 509.314 = 41463 = 0xA1F7, so 0x9800-0xB000 is the
plausible band.
"""
import os
import sys

SW_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SW_DIR)

from pynq import Overlay, MMIO

BIT = os.path.join(SW_DIR, os.pardir, "out", "xadc_sysmon.bit")
Overlay(BIT)

WINDOW = 0x2000
m = MMIO(0x80000000, WINDOW)

TEMP_LO, TEMP_HI = 0x9800, 0xB000

print("scanning 0x0000-0x%04X of the sysmon AXI window\n" % (WINDOW - 4))
nonzero = []
for off in range(0, WINDOW, 4):
    v = m.read(off)
    if v:
        nonzero.append((off, v))

for off, v in nonzero:
    low = v & 0xFFFF
    tag = ""
    if TEMP_LO <= low <= TEMP_HI:
        celsius = low * 509.3140064 / 65536.0 - 280.23087870
        tag = "   <-- plausible temperature: %.2f C" % celsius
    print("  +0x%04X = 0x%08X%s" % (off, v, tag))

print("\n%d non-zero words of %d" % (len(nonzero), WINDOW // 4))

# Read one candidate twice: a live measurement changes, a constant does not.
if nonzero:
    print("\nre-reading to see which ones move:")
    import time
    first = {off: m.read(off) for off, _ in nonzero}
    time.sleep(0.5)
    for off, _ in nonzero:
        a, b = first[off], m.read(off)
        if a != b:
            print("  +0x%04X  0x%08X -> 0x%08X   MOVES" % (off, a, b))
