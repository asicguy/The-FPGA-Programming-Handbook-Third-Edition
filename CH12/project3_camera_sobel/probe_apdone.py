#!/usr/bin/env python3
"""Hunt the AP_DONE completion race, and measure how often it fires.

    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 \
        probe_apdone.py [frames] [--no-latch] [--download]

  --no-latch   turn off the IP_ISR completion latch, so what is measured is
               the hardware alone rather than the software working around it.
               Use this to decide whether an RTL change actually fixed
               something; with the latch on, a fault is recovered and counted
               rather than seen.
  --download   program the PL first, instead of attaching to what is loaded.

This is the tool that placed the fault described under "The AP_DONE timeout,
and what it actually is" in CH12/README.md, and it is kept because the fault is
mitigated rather than fixed: the RTL still loses the bit, so the next person to
touch video_filter_ctrl.sv needs a way to measure whether they made it better
or worse.

It attaches to the design already running -- `download=False` -- so it does not
reprogram the PL. That matters twice over: it can be run against a board that
is mid-session, and it cannot trip the overlay-swap problem. It does mean the
project 3 bitstream has to be loaded already, by the notebook or by a previous
run.

What it prints, and how to read it:

  timeouts    frames where neither CTRL nor IP_ISR ever reported completion.
              Should be zero. Anything else is a fault the latch did not cover.

  recovered   frames where CTRL lost AP_DONE and the sticky IP_ISR copy saved
              them. This is the race, counted. About 1 in 1000 on this board.

  slow        frames over 20 ms, against a nominal 5. Kept because project 2
              once showed two frames taking 3.4 s while still coming out
              bit-exact, which no account of this fault yet explains.

The wall time is the check that matters: N frames at ~5.2 ms each is the only
thing that proves the recoveries are real completions and not early returns.
An earlier version of the driver returned on a stale IP_ISR and finished 4000
frames in 13.6 s instead of 20.7 -- the clock caught that, the tests did not.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "sw"))

import numpy as np                                          # noqa: E402
from pynq import Overlay, allocate                          # noqa: E402

import sobel_ref as ref                                     # noqa: E402
from filter_driver import VideoFilter, decode_ctrl          # noqa: E402

BIT = os.path.join(HERE, "out_sv", "camera_sobel.bit")
W, H = 1280, 720
SLOW_MS = 20.0          # a frame is nominally ~5 ms
# A frame cannot physically finish much under 5 ms: 921600 pixels at one per
# beat at 187.5 MHz is 4.9 ms. Anything materially faster did not run -- it
# returned on a completion belonging to some other frame, which is the
# signature of ap_done firing more than once per start.
FAST_MS = 3.0


def main():
    args = sys.argv[1:]
    no_latch = "--no-latch" in args
    download = "--download" in args
    nums = [a for a in args if not a.startswith("--")]
    frames = int(nums[0]) if nums else 4000
    if not os.path.exists(BIT):
        raise SystemExit(f"{BIT} not found -- build project 3 first")

    ol = Overlay(BIT, download=download)
    filt = VideoFilter(ol.video_filter_0)
    filt.probe_start = True                 # place the fault, not just report it
    if no_latch:
        filt.done_latch = False

    src = allocate(shape=(H, W, 4), dtype=np.uint8)
    dst = allocate(shape=(H, W, 4), dtype=np.uint8)
    src[:] = 0x40
    src.flush()

    # Poison the two ends of the destination before every frame. The
    # accelerator writes it in address order, so the LAST word tells us whether
    # the frame ran to completion -- which is the difference between "the
    # completion was signalled and lost" and "the frame never finished". Only
    # 16 words are touched, so this does not perturb the timing.
    POISON = 0xEE
    def poison():
        dst[0, 0, :] = POISON
        dst[H - 1, W - 1, :] = POISON
        dst.flush()

    def poison_state():
        dst.invalidate()
        first = int(dst[0, 0, 0])
        last = int(dst[H - 1, W - 1, 0])
        return first, last

    print(f"probing {frames} frames  (probe_start={filt.probe_start}, "
          f"done_latch={filt.done_latch})", flush=True)
    slow = fails = fast = 0
    times = []
    t_start = time.perf_counter()
    for i in range(frames):
        poison()
        t0 = time.perf_counter()
        try:
            filt.run_frames(src, dst, ref.MODE_SOBEL)
        except TimeoutError as exc:
            fails += 1
            first, last = poison_state()
            wrote_start = first != POISON
            wrote_end = last != POISON
            print(f"\n#### frame {i}: TIMEOUT\n{exc}", flush=True)
            print(f"  destination: first word written={wrote_start}  "
                  f"last word written={wrote_end}", flush=True)
            print("  -> the frame RAN TO COMPLETION; only the completion was lost"
                  if wrote_end else
                  "  -> the frame did NOT finish writing; it never completed",
                  flush=True)
            continue
        dt = (time.perf_counter() - t0) * 1e3
        times.append(dt)
        if dt < FAST_MS:
            fast += 1
            print(f"  frame {i}: FAST {dt:.3f} ms -- too quick to have run. "
                  f"probe CTRL={filt.last_start_ctrl:#010x}", flush=True)
        if dt > SLOW_MS:
            slow += 1
            print(f"  frame {i}: SLOW {dt:.1f} ms   probe "
                  f"CTRL={filt.last_start_ctrl:#010x} "
                  f"{decode_ctrl(filt.last_start_ctrl)}", flush=True)
        if i and i % 500 == 0:
            print(f"  {i} frames, {fails} timeouts, {slow} slow", flush=True)

    elapsed = time.perf_counter() - t_start
    print(f"\n{frames} frames in {elapsed:.1f}s "
          f"({elapsed / frames * 1e3:.2f} ms a frame)")
    print(f"  timeouts  : {fails}")
    print(f"  recovered : {filt.recovered_completions}"
          "   <- CTRL lost these, IP_ISR saved them")
    print(f"  slow      : {slow}")
    print(f"  fast      : {fast}   <- returned without running a frame")
    if times:
        ts = sorted(times)
        print(f"  frame time: min {ts[0]:.3f}  p50 {ts[len(ts)//2]:.3f}  "
              f"max {ts[-1]:.3f} ms")


if __name__ == "__main__":
    main()
