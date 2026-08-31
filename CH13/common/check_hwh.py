#!/usr/bin/env python3
"""Check a generated .hwh for the things PYNQ silently depends on.

    python3 common/check_hwh.py project1_mipi_dp/out/camera_dp.hwh
    python3 common/check_hwh.py project*/out*/*.hwh

Two classes of mistake are worth catching before a board is involved, because
neither produces an error message that points at the cause:

  - **A renamed or moved camera IP.** A hierarchy driver binds by looking for
    six IP by name, and is then handed their base addresses -- that is true of
    CH13's own `Ov5647Camera` (sw/ov5647.py) and of PYNQ's `Pcam5C` alike, and
    they check for the same six, so this list serves both. Get one wrong and
    `ol.mipi` simply does not exist, or the camera fails to initialise with no
    indication why. The I2C address additionally has to match what dts/*.dtsi
    declares.

  - **A register map that did not survive packaging.** `ipx` auto-creates an
    address block called "reg0"; leaving it alongside an explicitly added one
    gives the interface two blocks, and PYNQ then keys the IP one level deeper
    so `ol.video_filter_0.register_map` raises AttributeError. The offsets also
    have to match sw/filter_driver.py, or the accelerator never asserts done.

Exits non-zero if anything is wrong, so it can be used as a build gate.
"""
import re
import sys

# Must match sw/filter_driver.py and HLS/src/video_filter.hpp.
FILTER_REGS = {
    "CTRL": 0x00, "GIER": 0x04, "IP_IER": 0x08, "IP_ISR": 0x0C,
    "src_1": 0x10, "src_2": 0x14, "dst_1": 0x1C, "dst_2": 0x20,
    "img_width": 0x28, "img_height": 0x30, "mode": 0x38,
}

# The six names a camera hierarchy driver tests for, plus axi_vdma.
CAMERA_IP = ["gpio_ip_reset", "mipi_csi2_rx_subsyst", "demosaic",
             "gamma_lut", "v_proc_sys", "pixel_pack", "axi_vdma"]

# Only one camera address is load bearing across every project: the IIC, whose
# address dts/*.dtsi declares and which the camera driver finds by the label on
# that node. The rest are per-project -- project 0 deliberately places them
# somewhere different -- so they are reported, not enforced.
CAMERA_ADDRS = {"axi_iic_0": 0x80140000}

# The M_AXI_HPM0_FPD aperture, where AMD's base overlay and project 1 put the
# video IPs. This note used to say those addresses "did not respond on this
# board". They do -- once gpio_ip_reset channel 1 has been released. That GPIO
# powers up at 0 and drives an active-low reset holding demosaic, gamma_lut,
# v_proc_sys, axis_channel_swap and pixel_pack; in reset they do not complete
# an AXI4-Lite transaction, and ZynqMP has no bus timeout on the PL ports, so
# the access hangs the CPU permanently and looks precisely like a dead
# aperture.
#
# Kept as a note because it is still the first thing to check when a camera
# project loads cleanly and then hangs the board: not the aperture, the reset.
FPD_APERTURE = 0xA0000000


def parse(path):
    text = open(path).read()
    hier = set(re.findall(r'FULLNAME="/mipi/([A-Za-z_0-9]+)"', text))
    addrs = {}
    for tag in re.findall(r"<MEMRANGE[^>]*>", text):
        inst = re.search(r'INSTANCE="([^"]+)"', tag)
        base = re.search(r'BASEVALUE="([^"]+)"', tag)
        blk = re.search(r'ADDRESSBLOCK="([^"]+)"', tag)
        if inst and base and blk and blk.group(1) == "Reg":
            addrs.setdefault(inst.group(1), int(base.group(1), 16))
    # Registers scoped to the accelerator's own MODULE. Every IP in the design
    # contributes registers to the .hwh -- the VDMA alone has sixty -- so
    # collecting them globally would compare the filter's map against the whole
    # block design's.
    regs = {}
    # FULLNAME is not the first attribute on the tag, so do not anchor to it.
    mod = re.search(
        r'<MODULE [^>]*FULLNAME="/video_filter_0"[^>]*>.*?</MODULE>', text, re.S)
    if mod:
        for m in re.finditer(
                r'<REGISTER NAME="([^"]+)">.*?ADDRESS_OFFSET" VALUE="([^"]+)"',
                mod.group(0), re.S):
            regs[m.group(1)] = int(m.group(2), 0)
    return hier, addrs, regs, bool(mod)


def check(path):
    hier, addrs, regs, has_filter = parse(path)
    problems = []
    # Things worth saying that are not failures: properties of the board rather
    # than of the design. They print, they do not set the exit status.
    notes = []

    # Project 1 has no accelerator, and that is not a fault.
    if has_filter:
        if not regs:
            problems.append(
                "video_filter_0 has no register map -- ipx probably left its "
                "auto-created 'reg0' address block in place alongside ours")
        for name, off in FILTER_REGS.items():
            if name not in regs:
                problems.append(f"register {name} missing from the map")
            elif regs[name] != off:
                problems.append(
                    f"register {name} at {regs[name]:#x}, expected {off:#x}")
        extra = set(regs) - set(FILTER_REGS)
        if extra:
            problems.append(f"unexpected registers: {sorted(extra)}")

    if hier:
        for ip in CAMERA_IP:
            if ip not in hier:
                problems.append(f"mipi/{ip} missing -- no camera driver will bind")
        for ip, want in CAMERA_ADDRS.items():
            got = addrs.get(f"mipi_{ip}")
            if got is None:
                problems.append(f"mipi/{ip} has no address")
            elif got != want:
                problems.append(
                    f"mipi/{ip} at {got:#x}, expected {want:#x}"
                    + (" -- must match dts/*.dtsi" if ip == "axi_iic_0" else ""))
        in_fpd = sorted(name for name, base in addrs.items()
                        if name.startswith("mipi_") and base >= FPD_APERTURE)
        if in_fpd:
            notes.append(
                f"{len(in_fpd)} camera IP in the FPD aperture at "
                f"{FPD_APERTURE:#x}: {', '.join(n[5:] for n in in_fpd)}. "
                f"Fine, but release gpio_ip_reset before touching any of them "
                f"or the board hangs -- see FPD_APERTURE in this file.")

    kind = []
    if has_filter:
        kind.append("filter")
    if hier:
        kind.append("camera")
    if not kind:
        # Recognising nothing is a failure, not a pass: it means this script's
        # parsing has drifted from the .hwh format, and a silent "ok" here
        # would be worse than no check at all.
        problems.append("recognised neither a filter nor a camera in this .hwh "
                        "-- the parser is out of date, not the design")

    print(f"{path}  [{'+'.join(kind) or 'nothing recognised'}]")
    for p in problems:
        print(f"    {p}")
    for n in notes:
        print(f"    note: {n}")
    if not problems:
        print("    ok")
    return not problems


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    ok = all([check(p) for p in sys.argv[1:]])
    sys.exit(0 if ok else 1)
