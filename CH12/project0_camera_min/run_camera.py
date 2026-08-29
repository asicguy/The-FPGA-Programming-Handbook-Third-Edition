#!/usr/bin/env python3
"""CH12 project 0 -- camera to DisplayPort, and nothing else.

    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 run_camera.py

A plain script rather than a notebook, because this is the thing you run when
you do not yet know whether the camera works, and a notebook adds a browser, a
kernel and a second copy of every failure mode to something that should be one
process and one log.

It brings the sensor up, puts the picture on the DisplayPort, and reports the
rate it sustained. Every step is announced before it is attempted, and the log
is flushed and fsync'd, so if the board dies the last line names what killed it.

THE ORDER THIS RUNS IN, AND WHY
-------------------------------
gpio_ip_reset channel 1 powers up at 0, and it drives an active-low reset that
holds demosaic, gamma_lut, v_proc_sys, axis_channel_swap and pixel_pack. An IP
in reset does not complete an AXI4-Lite transaction, and ZynqMP has no bus
timeout on the PL ports -- so reading one of their registers first does not
fail, it wedges the CPU permanently: no panic, no console, power cycle only.

So the reset comes off before anything reads a video IP register. That one
write is the difference between this script working and this script hanging the
board, which is why it gets its own step and its own line in the log.

Everything is announced before it is attempted and the log is fsync'd, so if
the board does die the last line names exactly what was being touched. That is
how this reset was found: the log's last line was `read mipi/demosaic
0x80200000 ...` and there was no line after it.
"""
import argparse
import mmap
import os
import signal
import struct
import sys
import time


class Timeout(Exception):
    pass


signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(Timeout()))


# MIPI CSI-2 RX Subsystem register map, PG232. When no frame arrives these are
# the registers that say why, and they distinguish the three cases that
# otherwise look identical from Python: the sensor is not transmitting, the
# D-PHY is not locking, or the packets are arriving and being dropped.
CSI_CCR = 0x00          # [0] core enable
CSI_PCR = 0x04
CSI_CSR = 0x10          # core status
CSI_ISR = 0x20          # interrupt status -- error bits live here
CSI_CLK_INFO = 0x3C     # [0] clock lane in stop state, [1] clock lane in HS
CSI_L0_INFO = 0x40
CSI_L1_INFO = 0x44
CSI_IMG_INFO1 = 0x60    # [15:0] byte count of the last VC0 packet
CSI_IMG_INFO2 = 0x64    # [5:0] data type; 0x2B is RAW10


def csi_report(say, csi):
    """Dump the receiver's view of the link."""
    ccr = csi.read(CSI_CCR)
    csr = csi.read(CSI_CSR)
    isr = csi.read(CSI_ISR)
    clk = csi.read(CSI_CLK_INFO)
    l0 = csi.read(CSI_L0_INFO)
    l1 = csi.read(CSI_L1_INFO)
    info1 = csi.read(CSI_IMG_INFO1)
    info2 = csi.read(CSI_IMG_INFO2)
    say("    CSI-2 receiver:")
    say(f"      CCR       = {ccr:#010x}  core {'enabled' if ccr & 1 else 'DISABLED'}")
    say(f"      CSR       = {csr:#010x}")
    say(f"      ISR       = {isr:#010x}"
        + ("  <- errors latched" if isr else "  (no errors latched)"))
    say(f"      CLK_INFO  = {clk:#010x}  "
        f"{'HS active' if clk & 0x2 else 'clock lane NOT in high speed'}")
    say(f"      LANE0/1   = {l0:#010x} / {l1:#010x}")
    say(f"      IMG_INFO  = {info1:#010x} / {info2:#010x}  "
        f"byte count {info1 & 0xFFFF}, data type {info2 & 0x3F:#04x}"
        f"{' (RAW10)' if (info2 & 0x3F) == 0x2B else ''}")
    if not (clk & 0x2) and (info1 & 0xFFFF) == 0:
        say("      => nothing is arriving on the link at all. Either the sensor")
        say("         is not transmitting, or the ribbon cable is the wrong way")
        say("         round. Check the sensor's own registers next.")

HERE = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(HERE, "run_camera.log")
_log = open(LOG_PATH, "w", buffering=1)


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    _log.write(line + "\n")
    _log.flush()
    os.fsync(_log.fileno())


def peek(addr):
    """One 32-bit read through /dev/mem. PS or PL, physical address."""
    page = 0x1000
    base = addr & ~(page - 1)
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    try:
        m = mmap.mmap(fd, page, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
        try:
            return struct.unpack("<I", m[addr - base:addr - base + 4])[0]
        finally:
            m.close()
    finally:
        os.close(fd)


def probe_aperture(ip_dict):
    """Read one register from every PL slave, announcing each before trying it.

    Only valid AFTER the video IP reset has been released -- see the module
    docstring. Run before that, it hangs on the first HLS IP it reaches, which
    is exactly how that reset was found.
    """
    say("\n--- probing every PL slave, one register each ---")
    say("    (if the log stops inside this section, the address on the last")
    say("     line is a slave that is not responding, and the CPU is wedged)")
    # Offset 0 is the right probe for almost everything, but not for the VDMA:
    # this design sets c_include_mm2s 0, so there is no MM2S channel and
    # offset 0x00 is MM2S_DMACR, a register that does not exist here. Probe
    # S2MM_DMACR at 0x30 instead -- the channel that is actually built.
    probe_offset = {"mipi/axi_vdma": 0x30}
    addressable = [(n, e) for n, e in ip_dict.items() if "phys_addr" in e]
    for name, entry in sorted(addressable, key=lambda kv: kv[1]["phys_addr"]):
        addr = entry["phys_addr"] + probe_offset.get(name, 0x00)
        say(f"    read  {name:<34} {addr:#010x} ...")
        value = peek(addr)
        say(f"      ok  {name:<34} {addr:#010x} = {value:#010x}")
    say("    all PL slaves answered")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bitstream", default=os.path.join(HERE, "out", "camera_min.bit"))
    ap.add_argument("--mode", default="1280x720")
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--no-display", action="store_true",
                    help="capture only; skip the DisplayPort")
    args = ap.parse_args()

    say("=" * 72)
    say("CH12 project 0 -- camera to DisplayPort")
    say("log:", LOG_PATH)

    for path in ("../../sw", "../sw", "sw", HERE):
        candidate = os.path.join(HERE, path) if not os.path.isabs(path) else path
        if os.path.exists(os.path.join(candidate, "ov5647.py")):
            sys.path.insert(0, candidate)
            say("driver from:", candidate)
            break
    else:
        say("!! ov5647.py not found"); return 1

    import numpy as np
    import ov5647 as cam                       # binds ahead of Pcam5C
    from pynq import Overlay
    from pynq.lib.video import VideoMode, DisplayPort, PIXEL_RGB

    say("\n--- loading", args.bitstream, "---")
    say("    Overlay() also applies the .dtbo and constructs hierarchy drivers")
    try:
        overlay = Overlay(args.bitstream)
        say("    loaded (programmed the PL and applied the overlay)")
    except (OSError, RuntimeError) as e:
        # Removing a device-tree overlay leaks its __symbols__ entries, so a
        # later overlay declaring the same axi_iic node is rejected with
        # EINVAL. PYNQ surfaces that either as RuntimeError("Device tree ...
        # cannot be applied") or as an OSError from the FPGA manager. Every
        # CH12 camera overlay declares that node, so re-running this script,
        # or moving between camera projects, hits it until the board reboots.
        #
        # If the PL is already running this design, attach instead of
        # insisting on reprogramming.
        say(f"    reload refused ({type(e).__name__}: {e})")
        say("    attaching to the running design instead")
        overlay = Overlay(args.bitstream, download=False)
        say("    attached")

    say("\n--- camera ---")
    mipi = overlay.mipi
    say("    driver     :", type(mipi).__name__)

    # BEFORE any video IP register is read, by this script or anything else.
    # gpio_ip_reset channel 1 comes up at 0 and holds demosaic, gamma_lut,
    # v_proc_sys, axis_channel_swap and pixel_pack in reset; reading one of
    # them in that state hangs the CPU with no way back.
    say("    releasing video IP reset (gpio_ip_reset ch1) ...")
    mipi.pipeline.release_video_reset()
    say("      released")

    probe_aperture(overlay.ip_dict)

    say("    i2c        :", mipi.sensor.i2c.path, hex(mipi.sensor.i2c.addr))
    say("    chip id    : %#06x" % mipi.sensor.chip_id())

    sensor_mode = mipi.configure(mode=args.mode)
    say(f"    mode       : {sensor_mode.name} at {sensor_mode.fps:.2f} fps")
    mipi.start()

    def dmasr(tag):
        r = mipi.axi_vdma.read(cam.VDMA_S2MM_DMASR)
        say("    DMASR %-26s %#010x halted=%s errors=%s"
            % (tag, r, cam.vdma_halted(r), cam.vdma_errors(r) or "none"))

    dmasr("after start()")
    say("    waiting for the first frame (10 s watchdog) ...")
    signal.alarm(10)
    try:
        frame = mipi.readframe()
    except Timeout:
        signal.alarm(0)
        say("    !! no frame arrived in 10 s -- the VDMA never completed one")
        csi_report(say, mipi.mipi_csi2_rx_subsyst)
        say("    sensor: 0x0100 standby = %#04x, 0x4800 mipi_ctrl = %#04x"
            % (mipi.sensor.read_reg(0x0100), mipi.sensor.read_reg(0x4800)))
        say("    sensor: 0x300a/b id = %#06x" % mipi.sensor.chip_id())

        # The link is fine if we got here with a byte count. So the question is
        # which block downstream is not running. An HLS block reads 0x04 when
        # it is idle and un-started, and bit 7 (auto-restart) plus bit 0
        # (ap_start) when it is free-running.
        say("    video IP AP_CTRL after configure:")
        for name in ("demosaic", "gamma_lut", "v_proc_sys", "pixel_pack"):
            ctrl = getattr(mipi, name).read(0x00)
            state = []
            if ctrl & 0x01: state.append("ap_start")
            if ctrl & 0x02: state.append("ap_done")
            if ctrl & 0x04: state.append("ap_idle")
            if ctrl & 0x08: state.append("ap_ready")
            if ctrl & 0x80: state.append("auto_restart")
            say(f"      {name:<14} = {ctrl:#010x}  "
                f"{' | '.join(state) or 'nothing set'}"
                + ("" if ctrl & 0x81 else "   <- NOT RUNNING"))
        say("    geometry actually programmed:")
        say(f"      demosaic   {mipi.demosaic.read(0x10)} x {mipi.demosaic.read(0x18)}"
            f"  bayer_phase={mipi.demosaic.read(0x28)}")
        say(f"      gamma_lut  {mipi.gamma_lut.read(0x10)} x {mipi.gamma_lut.read(0x18)}"
            f"  fmt={mipi.gamma_lut.read(0x20)}")
        say(f"      csc        {mipi.v_proc_sys.read(0x20)} x {mipi.v_proc_sys.read(0x28)}"
            f"  in={mipi.v_proc_sys.read(0x10)} out={mipi.v_proc_sys.read(0x18)}"
            f"  K11={mipi.v_proc_sys.read(0x50)}")
        say(f"      pixel_pack mode reg 0x10 = {mipi.pixel_pack.read(0x10)}"
            f"  (1 = 32bpp)")

        # pixel_pack read 0 at AP_CTRL. Either it is ap_ctrl_none and free
        # running -- in which case this write is inert -- or it is ap_ctrl_hs
        # and nobody ever started it, because PYNQ's PixelPacker only sets the
        # mode register and no other driver in the video library writes 0x00.
        say("    starting pixel_pack explicitly and retrying ...")
        mipi.pixel_pack.write(0x00, 0x81)
        say(f"      pixel_pack AP_CTRL now = {mipi.pixel_pack.read(0x00):#010x}")
        signal.alarm(10)
        try:
            f2 = mipi.readframe()
            signal.alarm(0)
            say(f"      A FRAME ARRIVED: {f2.shape} min {f2.min()} max {f2.max()} "
                f"mean {f2.mean():.1f}")
            say("      => pixel_pack was the missing start")
        except Timeout:
            signal.alarm(0)
            say("      still no frame -- pixel_pack was not the only thing")

        # VDMA S2MM: is it running, does it think it has the right geometry?
        v = mipi.axi_vdma
        dmacr, dmasr = v.read(0x30), v.read(0x34)
        say("    VDMA S2MM:")
        say(f"      DMACR = {dmacr:#010x}  {'running' if dmacr & 1 else 'HALTED'}")
        say(f"      DMASR = {dmasr:#010x}  "
            f"{'halted' if dmasr & 1 else 'not halted'}"
            f"{', idle' if dmasr & 2 else ''}"
            + ("   <- ERROR BITS SET" if dmasr & 0xFF0 else ""))
        say(f"      VSIZE = {v.read(0xA0)}  HSIZE = {v.read(0xA4)}  "
            f"STRIDE = {v.read(0xA8)}")
        mipi.close()
        return 2
    signal.alarm(0)
    say("    frame      :", frame.shape, frame.dtype)
    say("    levels     : min %d max %d mean %.1f"
        % (frame.min(), frame.max(), frame.mean()))
    if frame.max() == frame.min():
        say("    !! frame is a constant -- no pixels are reaching DDR")

    r, g, b = mipi.auto_white_balance(frame)
    say("    wb gains   : R %.2f G %.2f B %.2f" % (r, g, b))

    if args.no_display:
        say("\n--- capture-rate only (--no-display) ---")
        n = 120
        t0 = time.perf_counter()
        for _ in range(n):
            mipi.readframe()
        dt = time.perf_counter() - t0
        say("    %.1f fps over %d frames (sensor sends %.1f)"
            % (n / dt, n, sensor_mode.fps))
        mipi.close()
        return 0

    say("\n--- displayport ---")
    width, height = sensor_mode.width, sensor_mode.height
    dp = DisplayPort()
    wanted = [m for m in dp.modes if m.width == width and m.height == height]
    if not wanted:
        dp.close(); mipi.close()
        say("    !! monitor does not offer %dx%d; it offers %s"
            % (width, height, sorted({(m.width, m.height) for m in dp.modes})))
        return 1
    dp_mode = max(wanted, key=lambda m: m.fps)
    dp.configure(dp_mode, PIXEL_RGB)
    say(f"    {dp_mode.width}x{dp_mode.height} @ {dp_mode.fps} Hz, "
        f"{dp_mode.bits_per_pixel} bpp")

    # 24bpp out, 32bpp in. cv2 does the repack in ~19 ms where the equivalent
    # NumPy slice costs about 350 -- a strided 3-of-every-4-byte copy is the
    # worst case for the memory system.
    import cv2

    # `start()` clears the SOF error the free-running sensor latches when the
    # VDMA arms mid-frame, so this should never fire now. Kept as a check
    # rather than an assumption, and loud if it does.
    if not mipi._vdma.readchannel.running:
        say("    !! VDMA halted between setup and the loop -- DMASR=%#010x %s"
            % (mipi.axi_vdma.read(cam.VDMA_S2MM_DMASR),
               cam.vdma_errors(mipi.axi_vdma.read(cam.VDMA_S2MM_DMASR))))
        mipi.clear_vdma_errors()
        say("    recovered, running =", mipi._vdma.readchannel.running)

    dmasr("after DisplayPort setup")
    say(f"\n--- running for {args.seconds:.0f} s ---")
    out = dp.newframe()
    frames = 0
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < args.seconds:
        cv2.cvtColor(mipi.readframe(), cv2.COLOR_BGRA2BGR, dst=out)
        dp.writeframe(out)
        out = dp.newframe()
        frames += 1
    elapsed = time.perf_counter() - t0
    say("    %d frames in %.2f s = %.1f fps (sensor sends %.1f)"
        % (frames, elapsed, frames / elapsed, sensor_mode.fps))

    dp.close()
    mipi.close()
    say("\ndone -- released")
    return 0


if __name__ == "__main__":
    sys.exit(main())
