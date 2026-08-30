#!/usr/bin/env python3
"""Driving CH12's own pixel packer.

The camera hierarchy ends with a block that takes two 24-bit pixels per beat
and writes 32-bit pixels to the VDMA. Projects 0 and 1 use the one PYNQ ships
-- `xilinx.com:hls:pixel_pack_2:1.0`, prebuilt, no source in this repo -- and
PYNQ's own `PixelPacker` driver binds to it by VLNV.

Project 3 does not, and that is the point. A chapter whose argument is *here is
one design in HLS, in SystemVerilog and in VHDL* cannot ship a SystemVerilog
build with an HLS block still sitting in the datapath, so `-tclargs sv` and
`-tclargs vhdl` get `SystemVerilog/hdl/pixel_pack.sv` and
`VHDL/hdl/pixel_pack.vhd` instead. Those are packaged as `aup:rtl:pixel_pack`,
which PYNQ's driver does not bind to -- deliberately: packaging hand-written
RTL under `xilinx.com:hls:` to borrow a driver would be a lie about where the
logic came from. This wraps the IP the way `filter_driver.VideoFilter` wraps
the accelerator, and needs no binding at all.

**It does 32 bits per pixel and nothing else.** PYNQ's packer also does 8, 24
and two flavours of 16; CH12 is a 32bpp chapter end to end -- see the pixel
format note in `HLS/src/video_filter.hpp` -- so the RTL packs 32bpp
unconditionally and does not decode the mode register. That puts the whole
burden of refusing a width on this file. If it ever stops refusing, asking for
24bpp gets you 32bpp frames and a picture that is sheared rather than an
error, which is a bad afternoon.

The register map is PYNQ's, unchanged, so the hierarchy's address map and any
notebook written against either packer still work. Both registers come from
the HLS source (`AUP-ZU3/pynq/boards/ip/hls/pixel_pack_2/pixel_pack.cpp`, two
scalar arguments on an `ap_ctrl_none` interface), and the control aperture is
32 bytes -- five address bits -- in the RTL too, so the hierarchy's address
map does not move:

    0x10  mode     0 -> 24bpp, 1 -> 32bpp, 2 -> 8bpp, 3/4 -> 16bpp
    0x18  alpha    the fourth byte inserted after each 24-bit pixel
"""

REG_MODE = 0x10
REG_ALPHA = 0x18

# The only mode the RTL implements. It is also the RTL's reset value, so a
# packer that has never been written to is already in the right one.
MODE_32BPP = 1

SUPPORTED_BITS_PER_PIXEL = (32,)


class PixelPacker:
    """Thin wrapper over the packer's AXI4-Lite interface.

    Parameters
    ----------
    ip : object with read(offset) and write(offset, value)
        A PYNQ `DefaultIP` -- `camera.pixel_pack` -- or anything like one.
    """

    def __init__(self, ip):
        self._ip = ip

    @property
    def bits_per_pixel(self):
        """Read back the width the hardware is actually in.

        Raises rather than decoding an unexpected mode. This RTL can only ever
        report 32, so anything else means the driver is attached to a
        different packer -- most likely PYNQ's HLS one, whose constructor
        writes mode 0. Silently returning 24 there would hide a block design
        that was built with the wrong variant.
        """
        mode = self._ip.read(REG_MODE)
        if mode != MODE_32BPP:
            raise RuntimeError(
                f"pixel packer reports mode {mode}, expected {MODE_32BPP} "
                f"(32bpp). CH12's RTL packer implements 32bpp only and resets "
                f"into it, so this is probably PYNQ's HLS pixel_pack -- check "
                f"which variant the bitstream was built with.")
        return 32

    @bits_per_pixel.setter
    def bits_per_pixel(self, value):
        if value not in SUPPORTED_BITS_PER_PIXEL:
            raise ValueError(
                f"CH12's RTL pixel packer does 32 bits per pixel and nothing "
                f"else, so {value} cannot be honoured. PYNQ's HLS packer does "
                f"8, 16, 24 and 32 -- build project 3 with -tclargs hls to "
                f"use it.")
        self._ip.write(REG_MODE, MODE_32BPP)

    @property
    def alpha(self):
        """The byte written into the fourth channel of every pixel.

        PYNQ's driver never writes this, so on the HLS packer it stays at its
        reset value of zero and camera frames arrive with a transparent alpha.
        The RTL packer resets to zero for the same reason: matching what the
        camera has always produced matters more than a tidier default, because
        the filter's colour passthrough mode carries this byte to the screen.
        """
        return self._ip.read(REG_ALPHA) & 0xFF

    @alpha.setter
    def alpha(self, value):
        if not 0 <= value <= 0xFF:
            raise ValueError(f"alpha is one byte, so it must be 0..255, "
                             f"got {value}")
        self._ip.write(REG_ALPHA, value)


def attach(ip):
    """Return whichever driver is right for the packer in this bitstream.

    Project 3's `hls` build -- and projects 0 and 1, which are not variant
    aware at all -- instantiate PYNQ's HLS packer, and PYNQ binds its own
    `PixelPacker` to it by VLNV, so the IP arrives already knowing how to set
    its width. The `sv` and `vhdl` builds instantiate `aup:rtl:pixel_pack`,
    which PYNQ has no driver for and hands back as a bare `DefaultIP`.

    The test is for the behaviour rather than for the VLNV: a driver that
    already has `bits_per_pixel` is PYNQ's and is left alone, anything else is
    ours and gets wrapped. Reading the VLNV out of the IP dict would work too
    and would break the day PYNQ adds another packer to its bindto list.

    **The lookup is on the class, not the instance, and that is not a style
    choice.** `bits_per_pixel` is a property, so `hasattr(ip, ...)` calls its
    getter, and PYNQ's getter reads register 0x10. This function runs inside
    `Ov5647Camera.__init__` -- before `configure()` releases gpio_ip_reset --
    and `pixel_pack` is one of the IPs that reset holds. A read there does not
    raise: an IP in reset never completes an AXI4-Lite transaction, ZynqMP has
    no bus timeout on the PL ports, and the CPU wedges with no console and no
    panic, power cycle only. `hasattr(type(ip), ...)` finds the property object
    without ever calling it, and touches no hardware at all.
    """
    if hasattr(type(ip), "bits_per_pixel"):
        return ip
    return PixelPacker(ip)
