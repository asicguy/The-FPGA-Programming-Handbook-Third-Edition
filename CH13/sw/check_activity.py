#!/usr/bin/env python3
"""Is the SYSMONE4 converting? Asked from fabric, not from the DRP.

The DRP register path and the PS AMS block both report nothing on this board.
This reads the macro's own eoc/eos/busy/channel pins, counted in fabric by
hdl/sysmon_activity.sv and presented on an AXI GPIO, which is a third path
that shares nothing with the other two.

    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 \
        check_activity.py [settle_seconds]

The verdict is one of:
  counters advance  -> the ADC IS running; only the register path is broken,
                       which is a different and probably fixable problem
  counters static   -> the macro is genuinely not converting, confirmed
                       independently of DRP and AMS
"""
import os
import sys
import time

SW_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SW_DIR)

import sysmon
from sysmon import Activity, Sysmon

BIT = os.path.join(SW_DIR, os.pardir, "out", "xadc_sysmon.bit")
SYSMON_BASE = 0x80000000
ACTIVITY_BASE = 0x80010000
CRUMB = os.path.join(SW_DIR, os.pardir, "activity.crumbs")


def crumb(msg):
    with open(CRUMB, "a") as f:
        f.write("%.3f %s\n" % (time.time(), msg))
        f.flush()
        os.fsync(f.fileno())
    print(msg, flush=True)


settle = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0

crumb("=== check_activity start ===")
from pynq import Overlay, MMIO

Overlay(BIT)
crumb("overlay downloaded")

act = Activity(MMIO(ACTIVITY_BASE, 0x1000))
sm = Sysmon(MMIO(SYSMON_BASE, 0x1000))

crumb("")
crumb("--- the DRP path, for comparison (known bad) ---")
crumb("  SR              0x%08X" % sm.status_register())
crumb("  temperature raw %d" % sm.drp_read(sysmon.DRP_TEMPERATURE))
crumb("  config1         0x%04X" % sm.drp_read(sysmon.DRP_CONFIG1))

crumb("")
crumb("--- the fabric path (the new evidence) ---")
before = act.snapshot()
crumb("  t=0      eoc=%-12d eos=%-6d chan_changes=%-4d busy=%d channel=%d"
      % (before["eoc_count"], before["eos_count"], before["chan_changes"],
         before["busy"], before["channel"]))

time.sleep(settle)
after = act.snapshot()
crumb("  t=%.2fs  eoc=%-12d eos=%-6d chan_changes=%-4d busy=%d channel=%d"
      % (settle, after["eoc_count"], after["eos_count"],
         after["chan_changes"], after["busy"], after["channel"]))

moved = sysmon.advanced(before, after)
crumb("")
if moved:
    d_eoc = (after["eoc_count"] - before["eoc_count"]) & 0xFFFFFFFF
    crumb("VERDICT: THE ADC IS RUNNING.")
    crumb("  %d conversions in %.2f s = %.0f/s" % (d_eoc, settle, d_eoc / settle))
    crumb("  The macro converts; only the register path is broken. That is a")
    crumb("  different problem from a dead SYSMON, and a more tractable one.")
else:
    crumb("VERDICT: THE MACRO IS NOT CONVERTING.")
    crumb("  Every counter is static. eoc_out and eos_out never pulsed and")
    crumb("  channel_out never changed, measured in fabric on the macro's own")
    crumb("  pins. This is independent of the DRP and of the PS AMS block, so")
    crumb("  it confirms the SYSMONE4 is genuinely stopped rather than merely")
    crumb("  unreadable.")

crumb("=== check_activity done ===")
