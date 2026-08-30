# CH12 — a camera, a video, and the same filter in both

CH11 built a Sobel accelerator and proved it on a still image. CH12 asks the
question that actually decides whether it was worth building: **does it keep up
with video, and what does the alternative cost?**

Four projects, each one buildable and runnable on its own:

| | what it is | needs a camera? | needs a monitor? |
|---|---|---|---|
| `project0_camera_min/` | the smallest thing that gets a camera on a screen | yes | yes |
| `project1_mipi_dp/` | OV5647 camera → DisplayPort, driven from a notebook | yes | yes |
| `project2_video_sobel/` | a video clip through the filter, four ways | no | for the live cells |
| `project3_camera_sobel/` | project 1's camera into project 2's filter | yes | yes |

Project 0 was not in the original plan. It exists because the camera did not
work, and four projects' worth of moving parts is the wrong place to find out
why: one clock domain, one reset, one AXI aperture, no accelerator, and a plain
script instead of a notebook. It is the thing to run first on a new board, and
the thing to go back to when something stops working.

```
project 0   OV5647 ─CSI-2─▶ [ mipi ] ─▶ VDMA ─▶ DDR ─▶ DPDMA ─▶ DisplayPort
            (project 1 without the notebook, at 100 MHz, all on HPM0_LPD)

project 1   OV5647 ─CSI-2─▶ [ mipi ] ─▶ VDMA ─▶ DDR ─▶ DPDMA ─▶ DisplayPort

project 2   clip ─▶ A53 decode ─▶ DDR ─▶ [ video_filter ] ─▶ DDR ─▶ DisplayPort

project 3   OV5647 ─CSI-2─▶ [ mipi ] ─▶ VDMA ─▶ DDR
                                                  └─▶ [ video_filter ] ─▶ DDR ─▶ DisplayPort
```

The split is deliberate. Camera bring-up has many ways to fail that have nothing
to do with a filter — a renamed IP, a misrouted interrupt, an I2C controller at
the wrong address — and every one of them is easier to find in a design that
contains nothing else. Project 2, conversely, needs no camera at all, so the
filter can be proven bit-exact before a sensor is ever involved.

## Layout

```
CH12/
├── HLS/            Vitis HLS C++ kernel, shared by projects 2 and 3
├── SystemVerilog/  hand-written RTL + the testbench all three share
├── VHDL/           the same design in VHDL
├── sw/             the software reference, the driver, and their tests
├── common/         Tcl shared by the block designs
├── project0_camera_min/  build_bd.tcl, constraints, dts, run_camera.py
└── project{1,2,3}_*/     build_bd.tcl, constraints, dts, notebook
```

`project0_camera_min` also carries the debug build: `-tclargs ila` puts a System
ILA on all seven AXI4-Stream hops between the CSI-2 receiver and the VDMA. That
is what found the last of the camera bugs, and it is left in because the next
person to lose a day to a silent video pipeline will want it.

## The accelerator

Memory-mapped and `ap_ctrl_hs`, exactly like CH11's: write the argument
registers, set `ap_start`, poll `ap_done`. It is **not** in the video path —
it sits beside the pipeline and is called once per frame.

That is the design decision the chapter turns on. It costs a DDR round trip per
frame and it cannot filter anything that is not already in memory. In exchange
it does not care where the frame came from, which is why projects 2 and 3 share
an implementation, a driver, and most of a notebook: the code that filters a
decoded video frame is the code that filters a camera frame, with
`vc.test_pattern(...)` replaced by `mipi.readframe()`.

### Interfaces

| Port | Type |
|---|---|
| `s_axi_control` | AXI4-Lite, 6-bit address, 32-bit data |
| `m_axi_gmem0` | AXI4 read, 64-bit address, 32-bit data (one pixel per beat) |
| `m_axi_gmem1` | AXI4 write, same |
| `ap_clk` / `ap_rst_n` / `interrupt` | 187.5 MHz on the board, active-low reset |

| offset | register | |
|---|---|---|
| 0x00 | `CTRL` | bit0 ap_start, bit1 ap_done, bit2 ap_idle, bit3 ap_ready |
| 0x04 / 0x08 / 0x0C | `GIER` / `IP_IER` / `IP_ISR` | |
| 0x10, 0x14 | `src` | source frame, low and high halves |
| 0x1C, 0x20 | `dst` | destination frame |
| 0x28 | `img_width` | pixels per row, ≤ 1920 |
| 0x30 | `img_height` | rows |
| 0x38 | `mode` | 0 gray, 1 sobel, 2 invert, 3 colour passthrough |

This is CH11's register map, unchanged, and that is the point: `register_map`,
`sw/filter_driver.py`, the testbench and the notebooks all carry over. The two
chapters' accelerators are interchangeable at this interface.

The argument names are `img_width`/`img_height`, never `width`/`height` — see
the `RecursionError` note in `HLS/src/video_filter.hpp`. The RTL inherits the
constraint because it inherits the register map.

**Mode 3 is new relative to CH11.** Colour passthrough does no arithmetic at
all, which makes it the control in every measurement: it is what the DDR round
trip costs on its own, with the filtering subtracted out.

### Blue is in the low byte

CH11 treated a packed pixel as R,G,B,A because its input came from PIL. CH12
treats it as **B,G,R,A**, and that is not a preference — it is what both of this
chapter's frame sources actually produce:

- **The camera.** AMD's MIPI pipeline ends in an `axis_subset_converter` named
  `axis_channel_swap` whose `TDATA_REMAP` puts blue in the low byte. It is why
  the AUP-ZU3 base overlay's own notebook writes `frame[:,:,[2,1,0]]` to hand a
  camera frame to PIL.
- **OpenCV.** `VideoCapture.read()` and `imread()` both return BGR.

So a decoded video frame and a camera frame have identical layout, and nothing
in this chapter ever reorders a channel. Luma is BT.601 in Q8 with the weights
ordered to match: `Y = (29·B + 150·G + 77·R) >> 8`.

Project 1's notebook checks this empirically rather than asserting it — it
displays the frame both ways and asks which one looks right.

### 32 bits per pixel, end to end

`mipi.configure(VideoMode(1280, 720, 32))` puts `pixel_pack` in 32bpp mode, and
`DisplayPort.configure(..., PIXEL_RGBA)` matches. Four bytes per pixel all the
way through is what lets a 32-bit-per-beat accelerator read a camera frame and
write a display frame **in place**, with no repacking anywhere.

### Zero copies

CH11 filtered into a buffer of its own and then copied the result into the
display frame — a full 3.7 MB memcpy per frame at 720p. It did not have to.
Both `mipi.readframe()` and `dp.newframe()` return buffers with a physical
address, so the accelerator can be pointed straight at them:

```python
filt.run_frames(mipi.readframe(), dp.newframe(), MODE_SOBEL)
```

Neither the source nor the destination is ever touched by the CPU on that path,
which also means no cache maintenance: `flush()` and `invalidate()` are only
needed when software has written or wants to read the buffer, and
`sw/filter_driver.py` leaves that to the caller for exactly that reason.

`frame_address()` refuses a frame whose rows are padded rather than returning a
plausible-looking address. A DRM buffer whose stride has been aligned up is a
strided *view* of a larger allocation, and writing it by physical address would
shear the picture rather than fail.

### Geometry: why the loop runs one row and one column too far

Filtered pixel (r, c) needs input rows r−1, r, r+1 and columns c−1, c, c+1, so
the window centre at step (r, c) holds input pixel (r−1, c−1). The loop
therefore runs over (H+1) × (W+1) steps:

```
consume input pixel (r, c)        when  r < H and c < W
produce output pixel (r-1, c-1)   when  r ≥ 1 and c ≥ 1
```

Both totals come to exactly W×H, which is what keeps the two dataflow FIFOs
balanced. Getting it wrong does not produce a wrong picture; it produces an
accelerator that never asserts done.

Colour passthrough produces on the *consume* condition instead — it has no
window, so it owes no delay — and the totals still come to W×H either way.

## Simulate

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
cd SystemVerilog && ./sim.sh          # the hand-written SystemVerilog
                    ./sim.sh --hls    # the Verilog Vitis HLS generated
                    ./sim.sh --pack   # the pixel packer
cd ../VHDL        && ./sim.sh         # mixed-language: VHDL DUT, same testbench
                     ./sim.sh --pack  # the pixel packer, in VHDL
```

One testbench, three DUTs. The VHDL build does not copy it — `VHDL/sim.sh`
references `../SystemVerilog/tb/tb_video_filter.sv` directly, so the two
implementations cannot drift apart in what they are tested against.

The testbench binds to `video_filter_dut`, a per-implementation wrapper, rather
than to an implementation directly. That is not indirection for its own sake:
Vitis HLS spells its AXI ports in upper case (`s_axi_control_AWVALID`) and the
hand-written RTL in lower, and Verilog is case sensitive, so one port list
between them is the only way a single testbench can drive both.

All three pass all twenty cases:

```
  [        GRAY 64x48]   64 x 48       3072 px  PASS        1135 polls
  [       SOBEL 64x48]   64 x 48       3072 px  PASS        1136 polls
  [      INVERT 64x48]   64 x 48       3072 px  PASS        1139 polls
  [       COLOR 64x48]   64 x 48       3072 px  PASS        1118 polls
  [       SOBEL 37x23]   37 x 23        851 px  PASS        381 polls
  [         SOBEL 6x5]    6 x 5          30 px  PASS        27 polls
  [         SOBEL 3x3]    3 x 3           9 px  PASS        9 polls
  [         SOBEL 2x2]    2 x 2           4 px  PASS        6 polls
  [         SOBEL 1x1]    1 x 1           1 px  PASS        4 polls
  [        SOBEL 1x16]    1 x 16         16 px  PASS        15 polls
  [        SOBEL 16x1]   16 x 1          16 px  PASS        18 polls
  [         COLOR 6x5]    6 x 5          30 px  PASS        22 polls
  [         COLOR 1x1]    1 x 1           1 px  PASS        3 polls
  [     SOBEL 160x120]  160 x 120     19200 px  PASS        6597 polls
  [     COLOR 160x120]  160 x 120     19200 px  PASS        6515 polls
  [      MODE7->SOBEL]   32 x 24        768 px  PASS        354 polls
  [       SOBEL again]   32 x 24        768 px  PASS        357 polls
  [  GRAY after SOBEL]   32 x 24        768 px  PASS        356 polls
  [  COLOR after GRAY]   32 x 24        768 px  PASS        338 polls
  [         REGISTERS] argument registers read back correctly
```

**The SystemVerilog and the VHDL report identical poll counts on every case**,
which means they are cycle-identical rather than merely functionally equivalent.
The HLS DUT passes the same twenty with different counts, because its pipeline
is deeper.

The degenerate sizes are the ones that earn their place. A 1×1 or 2×2 frame has
no interior at all, and an iteration space that is off by one deadlocks there
while looking perfectly correct at 64×48. The testbench also checks the word
*after* the frame, because an accelerator that writes one pixel too many is as
fatal downstream as one that writes too few and would otherwise pass.

`./sim.sh --hls` stands in for C/RTL co-simulation. Cosim is worth running too
(`HLS/build_hls.sh --cosim`) but it proves a different thing: it checks HLS
against its own C testbench, whereas this checks the generated RTL against the
same stimulus and the same golden model the other two implementations face.

`./sim.sh --pack` runs the other design in this repo, the camera's pixel packer,
against `tb/tb_pixel_pack.sv`. Same arrangement — one testbench, two DUTs, the
VHDL one bound by name — and both come out identical:

```
  [        64x48 no stall] 64x48  alpha=00  bp=0%  1536 beats
  [         64x48 stalled] 64x48  alpha=ff  bp=30%  1536 beats
  [     64x48 heavy stall] 64x48  alpha=80  bp=60%  1536 beats
  [   2x8 one beat a line] 2x8  alpha=00  bp=30%  8 beats
  [     1280x720 no stall] 1280x720  alpha=00  bp=0%  460800 beats
  [      1280x720 stalled] 1280x720  alpha=00  bp=20%  460800 beats

PASS -- 926216 beat checks, 10 register checks, 0 errors
```

The packer is four lines of arithmetic, so what the testbench is really for is
everything around it. TUSER is start-of-frame and TLAST is end-of-line, and the
VDMA tears the picture if either lands on the wrong beat — so every beat is
checked for both, backpressure is randomised on *both* streams so a skid buffer
that drops or duplicates under stall is caught here rather than as a sheared
frame on a monitor, and the 2×8 case makes TLAST true on every beat, which is
where a packer that only marks the end of a burst gets it wrong.

The testbench was checked against a deliberately broken packer before it was
believed: moving the alpha byte one field along makes it fail on beat 1.

## Four implementations of one algorithm, checked against each other

| written in | checked how | result |
|---|---|---|
| Python, vectorised NumPy | against a nested-loop version, 36 unit tests | OK |
| C++ (the HLS kernel) | against a C golden model, 36 csim cases | TEST PASSED |
| Python ↔ C++ | the kernel's output vs `filter_frame`, 9 sizes × 4 modes | **identical, 0 differing samples** |
| SystemVerilog / VHDL / HLS-Verilog | one RTL testbench, 19 cases + register map | TEST PASSED, ×3 |

The third row is the one that matters most. The Python golden model and the C
kernel are independent implementations written from the same specification, and
they agree bit for bit on every size and mode tested. That is what makes
`sw/sobel_ref.py` usable as the reference the board is judged against.

### The packer, so that "SystemVerilog build" means something

There is a second block in project 3 that follows the variant, and the reason it
does is worth stating plainly.

The camera hierarchy ends with a pixel packer: two 24-bit pixels per beat in,
two 32-bit pixels out, which is what makes camera frames four bytes a pixel.
PYNQ ships one — `xilinx.com:hls:pixel_pack_2:1.0`, prebuilt, no source in this
repo — and projects 0 and 1 use it. So did every project 3 build, at first.

That made the SystemVerilog build of project 3 a design containing a
hand-written accelerator **and an HLS block in the same datapath**, which does
not demonstrate what this chapter claims to be demonstrating. So `-tclargs sv`
and `-tclargs vhdl` now build `SystemVerilog/hdl/pixel_pack.sv` and
`VHDL/hdl/pixel_pack.vhd` instead, and `-tclargs hls` keeps PYNQ's. Projects 0
and 1 are deliberately left alone: they exist to bring the camera up, and the
design the camera was debugged against should not move underneath them.

The behaviour is transcribed from the 32bpp branch of PYNQ's own HLS source
(`AUP-ZU3/pynq/boards/ip/hls/pixel_pack_2/pixel_pack.cpp`, `case V_32`), which
is four lines:

```c
data(23, 0)  = in.data(23, 0);     data(31, 24) = alpha;
data(55, 32) = in.data(47, 24);    data(63, 56) = alpha;
out.last = in.last;  out.user = in.user;
```

One beat in, one beat out. `alpha` is a real register, not a constant — PYNQ's
driver never writes it, so it sits at zero and camera frames arrive with a
transparent fourth byte, and the RTL resets it to zero for exactly that reason.
Matching what the camera has always produced matters more than a tidier default,
because the filter's colour passthrough mode carries that byte to the screen.

**It does 32 bits per pixel and nothing else.** PYNQ's packer also does 8, 24
and two flavours of 16; this chapter is 32bpp end to end, so the RTL packs 32bpp
unconditionally and never decodes the mode register. That puts the whole burden
of refusing a width on software, and `sw/pixel_packer.py` is where it lands —
ask it for 24bpp and it raises, because the alternative is 32bpp frames and a
sheared picture rather than an error.

Three things had to match the IP being replaced, and each of them is a way to
break the camera without breaking the build:

- **The interface names.** `common/mipi_hier.tcl` connects `pixel_pack/
  stream_in_48`, `/stream_out_64` and `/s_axi_control` by name, and `ipx` names
  an inferred interface after the common prefix of the ports it came from —
  which is why the RTL's ports are `stream_in_48_tdata` and not `s_axis_tdata`.
- **The register offsets**, `mode` at 0x10 and `alpha` at 0x18, and the 32-byte
  control aperture the HLS IP declared.
- **The address block range, 65536.** `assign_bd_address` packs apertures in
  order, so a different range here moves every address after it — including
  `axi_iic_0`, whose address the device-tree overlay hardcodes.
  `common/check_hwh.py` asserts that one, which is the check that would catch it.

PYNQ's `PixelPacker` binds by VLNV, so it does not bind to `aup:rtl:pixel_pack`.
Packaging hand-written RTL under `xilinx.com:hls:` to borrow the driver would be
a lie about where the logic came from, so `sw/pixel_packer.py` wraps the IP the
way `filter_driver.py` wraps the accelerator, and `pixel_packer.attach()` picks
whichever driver this bitstream needs.

## Build

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh

cd HLS && ./build_hls.sh                      # only needed for the hls variant
cd ../project0_camera_min   && vivado -mode batch -source build_bd.tcl
cd ../project1_mipi_dp      && vivado -mode batch -source build_bd.tcl
cd ../project2_video_sobel  && vivado -mode batch -source build_bd.tcl -tclargs sv
cd ../project3_camera_sobel && vivado -mode batch -source build_bd.tcl -tclargs sv
cd dts && make                                # -> *.dtbo, next to the .bit

# and the debug build, when the video stops and the registers all look right
cd ../project0_camera_min && vivado -mode batch -source build_bd.tcl -tclargs ila
```

`-tclargs` takes `sv`, `vhdl` or `hls` for projects 2 and 3, and `ila` for
project 0. Note that everything after `-tclargs` is passed to the script, so
Vivado's own flags must come before it.

Project 0's ILA build lands in `out_ila/` and `vivado_ila/` so it never
clobbers the working bitstream, and leaves `design_1_wrapper.ltx` in the
implementation run directory — that is the probes file the hardware manager
needs to name the signals.

Projects 2 and 3 build all three variants from one script. The block design is
identical apart from which IP is instantiated, and duplicating a few hundred
lines of IP Integrator Tcl to change one VLNV is a good way to let three designs
drift apart.

Three things about packaging RTL as IP are easy to get wrong.

**A module reference will not take a SystemVerilog top file.**
`create_bd_cell -type module` rejects it outright, hence the IP-XACT step.

**`ipx` infers the AXI interfaces but not the register definitions**, and it
auto-creates its own address block called `reg0`. Leave that alongside an
explicit one and PYNQ keys the IP as `video_filter_0/s_axi_control`, so
`ol.video_filter_0` has no register map at all.
`common/package_filter.tcl` removes every auto-created block and adds exactly
one. This one breaks PYNQ rather than the hardware.

**Say which direction each master goes.** The RTL brings out the full AXI4 port
set on both `m_axi_gmem0` and `m_axi_gmem1` — it has to, or
`ipx::infer_bus_interfaces` does not recognise them as AXI4 at all — and ties
off the half it does not use. Left at the IP-XACT default of `READ_WRITE`, the
SmartConnect on each port then builds the machinery for a direction wired to
constants. Declaring `READ_WRITE_MODE` as `READ_ONLY` and `WRITE_ONLY` took
**801 LUTs and 760 registers, 17.7%, out of project 2** — none of it in the
accelerator, all of it in the interconnect either side of it.

That one is worth dwelling on, because nothing points at it. The design works
either way, timing closes either way, and the accelerator's own resource numbers
are identical either way. It only shows up when the whole design is compared
against something built differently — which is how it was found here: Vitis HLS
declares these interfaces `READ_ONLY` and `WRITE_ONLY`, so its *whole design*
came out smaller than the RTL's despite its accelerator being 1.7× the size.

It needs two things from outside the repo, both at the top of
`common/config.tcl`: the AUP-ZU3 board files (for the DDR preset) and the
AUP-ZU3 checkout (for AMD's MIPI Tcl and PYNQ's prebuilt `pixel_pack_2`).

### Check the build before you carry it to the board

```bash
python3 common/check_hwh.py project*/out*/*.hwh
```

It checks the two things that break PYNQ without saying so. That the
accelerator's eleven registers are at the offsets `sw/filter_driver.py`
expects — if they are not, or if the map is missing entirely because `ipx` left
its auto-created address block in place, the accelerator never asserts done and
the notebook hangs. And that the camera's six required IP are present under
`mipi/` with the base addresses `dts/*.dtsi` declares — if the I2C controller
moves, the overlay describes hardware that is not there and the sensor never
enumerates.

Neither failure produces an error that points at the cause, which is the whole
reason the script exists. It exits non-zero, so it works as a build gate.

## Results

### Implementation — project 2 (PS + accelerator)

Post-route on `xczu3eg-sfvc784-2-e`, whole design, at the 5.333 ns the PS
actually delivers (see *The clock you asked for is not the clock you get*):

| | SystemVerilog | VHDL | HLS |
|---|---|---|---|
| WNS | +0.338 ns | +0.570 ns | **+1.544 ns** |
| Failing setup endpoints | **0** / 17943 | **0** / 17949 | **0** / 19819 |
| WHS | +0.012 ns | +0.015 ns | +0.012 ns |
| Failing hold endpoints | **0** | **0** | **0** |
| CLB LUTs | **3732** | 3748 | 4148 |
| CLB registers | **3545** | 3547 | 5442 |
| Block RAM tiles | **1** | **1** | 5.5 |
| DSPs | **3** | **3** | 13 |

Those totals are the whole design — PS interface logic and three SmartConnects
included — so the accelerator is a minority of them.

The two RTL versions land within 16 LUTs and 2 registers of each other. HLS
costs about 400 more LUTs and 1900 more registers, and buys a great deal of
timing margin with them — +1.544 ns against +0.338 — which is the same trade
CH11 measured and which is worth nothing here, because the accelerator is
DDR-bound long before it is Fmax-bound.

The BRAM and DSP columns are the interesting ones. HLS put its dataflow FIFOs in
block RAM (5.5 tiles against 1) where the RTL put its two 512×32 FIFOs in
distributed RAM, which is LUTs — the same storage billed to a different column,
and a choice the RTL could equally make. And HLS mapped the three constant luma
multiplies to DSP blocks where Vivado builds them from fabric for the RTL.
Multiplying by 29, 150 and 77 is cheap in LUTs, so those ten extra DSPs buy
nothing here — but they are free on this device, and on a design that needed
its LUTs elsewhere they would not be.

Two things about that table were not true of its first version, and both are
worth reading the rest of this section for: the RTL versions were 834 LUTs
apart rather than 16, and HLS's whole design was *smaller* than the RTL's
despite its accelerator being 1.7× the size. Neither turned out to be a fact
about HLS or about VHDL.

### Implementation — project 3 (camera + accelerator)

The biggest of the three, and the only one with three clock domains: 100 MHz
control, 300 MHz video, 187.5 MHz accelerator, plus the CSI-2 subsystem's own
200 MHz D-PHY clock. The AXI4-Lite control path crosses from 100 to 187.5 inside
the interconnect; the accelerator's two DDR ports do not cross at all, because
the HP slave ports they land on are clocked from the same PL clock.

| | SystemVerilog | VHDL | HLS |
|---|---|---|---|
| WNS | +0.466 ns | +0.414 ns | +0.477 ns |
| Failing setup endpoints | **0** / 74720 | **0** / 74726 | **0** / 76592 |
| WHS | +0.010 ns | +0.010 ns | +0.010 ns |
| Failing hold endpoints | **0** / 74586 | **0** / 74592 | **0** / 76460 |
| CLB LUTs | **19043** | **19043** | 19461 |
| CLB registers | **24866** | 24868 | 26761 |
| Block RAM tiles | **45** | **45** | 49.5 |
| DSPs | **43** | **43** | 53 |

WNS is not bolded in that table, and deliberately. These three builds differ by
60 ps across a 3.33 ns period, the critical path is in the camera datapath that
all three share, and on the previous build — same sources, different placement —
HLS had the *worst* WNS of the three rather than the best. That spread is
placement noise. The area columns are the ones that mean something, and they say
what the out-of-context numbers said: the two hand-written implementations are
indistinguishable from each other and about 400 LUTs and 1900 flip-flops smaller
than the HLS one.

Per-clock setup margin, SystemVerilog build:

| clock | achieved | WNS | failing endpoints |
|---|---|---|---|
| `clk_pl_0` control | 100.000 MHz | +5.827 ns | 0 / 7520 |
| `clk_pl_1` video | 300.030 MHz | **+0.558 ns** | 0 / 47995 |
| `clk_pl_2` accelerator | 187.512 MHz | +0.466 ns | 0 / 16632 |
| `clk_out1` D-PHY | 200.000 MHz | +1.999 ns | 0 / 747 |

On this build the worst path is in the 187.5 MHz accelerator domain, at
+0.466 ns, with the 300 MHz video datapath 92 ps behind it at +0.558. On the
previous build it was the other way round. Both domains are closing with about
half a nanosecond in hand and neither has a failing endpoint, so which one is
nominally "the critical path" is decided by placement rather than by the design
— the useful statement is that adding the filter did not make either of them
hard to close.

One number in the timing report is a free confirmation that the CSI-2 retune
actually took effect. The receiver's recovered byte clock,
`CAM_clk_p_FIFO_WRCLK_OUT`, is constrained at an 18.264 ns period. A D-PHY byte
clock is the line rate over eight, and 437.5 / 8 = 54.7 MHz is 18.29 ns. At the
old 672 Mbps it would have been 11.9 ns. The line rate did not merely get typed
into a config dictionary; it reached the generated constraints.

### Out-of-context synthesis — the accelerator alone

Reading resource numbers off the three full block designs is not a comparison of
the three accelerators: those totals include the PS interface logic, three
SmartConnects and, in project 3, an entire camera pipeline. This is the
accelerator on its own, same flow, same 5 ns constraint, all three:

```
impl       WNS (ns)   Fmax MHz     LUTs  LUT logic    LUT mem      FFs     BRAM     DSPs
sv            0.631      228.9     1799       1158        641      922        1        3
vhdl          0.597      227.1     1807       1166        641      924        1        3
hls           2.011      334.6     2997       2513        484     3602      5.5       13
```

Reproduce with `vivado -mode batch -source common/synth_ooc.tcl`. For HLS that
means synthesising the Verilog it generated, from
`HLS/video_filter/hls/syn/verilog/`, not reading its own estimate, which is
made before place and route and reports a different thing.

The two RTL versions land within 8 LUTs and 2 registers of each other, which is
the expected result when one design is written twice, and matches what CH11
found.

HLS is 1.7× the LUTs and 3.9× the registers, and buys about 100 MHz of Fmax with
them — the same trade CH11 measured. The extra registers are a deeper pipeline;
the extra DSPs are the three constant luma multiplies, which Vivado builds out
of fabric for the RTL versions. None of that headroom is worth anything here,
because the accelerator is DDR-bound long before it is Fmax-bound.

The one column where the RTL spends more is `LUT mem`: 641 against 484. Those
are the two 512×32 dataflow FIFOs in distributed RAM. HLS put most of its
equivalent storage in block RAM instead — 5.5 tiles against 1 — which is the
same storage billed to a different column, and a choice the RTL could equally
make.

### The bug the resource comparison found

The first version of that table had the VHDL at 2628 LUTs against the
SystemVerilog's 1799, with distributed RAM at exactly 1280 against 640. A
factor of two is not what synthesis variation looks like.

Synthesising `sync_fifo` on its own in both languages produced *identical*
netlists — 320 `RAMD64E` each — which ruled out the obvious explanation. The
cause was in the top level:

```
SystemVerilog:  parameter FIFO_DEPTH = 512
VHDL:           FIFO_DEPTH : integer := 1024
```

The VHDL FIFOs were twice as deep as intended. That cost 640 LUTs of
distributed RAM and about 190 more in wider pointer arithmetic, which is the
whole of the difference.

**No simulation could have caught it.** A too-large FIFO is functionally
identical — it simply never fills — which is exactly why the two implementations
passed all nineteen cases *and* reported identical poll counts on every one,
while differing by 830 LUTs in hardware. Cycle-identical behaviour is not the
same as identical hardware, and the only thing that showed the difference was
putting the resource numbers side by side.

### The clock you asked for is not the clock you get

The PL clocks are integer divisions of one of the PS PLLs, and which PLL the
configurator picks depends on what else you asked for. Requesting 200 MHz for
the accelerator gets **187.5 MHz** — 1500/8, because 1500/200 is 7.5 and the
divisors are integers. That is harmless: the accelerator is synthesised against
a 5 ns constraint and run at 5.333 ns, so it has more margin than it was
designed for, and 187.5 Mpixel/s is still three times what 720p60 needs.

The camera clock was not harmless, and it is the reason
`common/ps_config.tcl` pins a PLL source:

| requested | what the PS delivered |
|---|---|
| PL0 100, PL1 300 | PL1 = **262.5 MHz** (RPLL 1050 ÷ 4) |
| PL0 100, PL1 300, PL2 200 | PL1 = 300.0, PL2 = 187.5 (RPLL 1500 ÷ 5, ÷ 8) |
| PL0 100, PL1 300, PL1 pinned to IOPLL | PL1 = **300.0 MHz** (IOPLL 1500 ÷ 5) |

Project 1 asks for exactly the first of those. Left alone it would have clocked
AMD's camera datapath at 262.5 MHz — 12.5% below what the CSI-2 subsystem, the
demosaic and the colour-space converter are configured for. It would very likely
have worked; a 2-lane 437.5 Mbps link only needs about 44 MHz to keep up. But
*probably fine by accident* is not the same as *chosen*, and nothing downstream
would have complained.

So `ch12_add_ps` pins PL1's source to IOPLL when PL2 is not in use, and prints
and checks every achieved frequency, failing the build on a miss of more than
10%. Pinning is conditional because with PL2 in play it makes things worse:
IOPLL for PL1 drops PL2 to 175 MHz, whereas leaving both on RPLL gives 300 and
187.5, which is the better pair.

### Implementation — project 1 (camera to DisplayPort, no accelerator)

Post-route, with the video clock pinned to IOPLL so it is actually the 300 MHz
AMD's camera IP is configured for:

| | camera_dp |
|---|---|
| WNS | +0.436 ns |
| Failing setup endpoints | **0** / 57783 |
| WHS | +0.010 ns |
| Failing hold endpoints | **0** / 57733 |
| CLB LUTs | 15768 |
| CLB registers | 21718 |
| Block RAM tiles | 44 |
| DSPs | 40 |

(Retuning the CSI-2 receiver from 672 to 438 Mbps for the OV5647 moved this by
nine LUTs and 17 ps. The line rate is a D-PHY timing parameter, not a structural
one — nothing about the design changes shape when it moves.)

That is the price of the camera front end on its own — the CSI-2 receiver, the
demosaic, the gamma LUT, the colour-space converter, the VDMA and two
interconnects — and it is worth keeping in proportion. It is roughly three times
the whole of project 2, accelerator and PS interface included. Most of what a
video pipeline costs is getting pixels *to* the place where the interesting
arithmetic happens.

### PYNQ needs an interrupt controller even when nothing uses interrupts

Projects 1 and 3 carry an `axi_intc` that no software in this chapter ever
reads. It is not decoration, and its absence is not something simulation or a
timing report will tell you about.

Wiring the interrupt concat straight to `pl_ps_irq0` is electrically correct and
builds cleanly. It is also enough to stop `ol.mipi` from existing. PYNQ
attributes an interrupt to an IP by tracing the signal to an AXI Interrupt
Controller and reading which of its inputs it lands on; with a bare concat there
is nothing to trace to, so `axi_vdma` gets no `interrupts` entry — and
`AxiVDMA.__init__` does an unconditional `self.s2mm_introut` and dies with

```
AttributeError: 'AxiVDMA' object has no attribute 's2mm_introut'
```

The camera and the accelerator are both polled here, so the controller is pure
metadata. It is metadata the driver refuses to start without. AMD's base overlay
has one for the same reason, at the same address.

## The device-tree overlay

Projects 1 and 3 each build a `.dtbo` that has to sit next to their `.bit` —
PYNQ matches an overlay to a bitstream by basename. It declares exactly one
thing, the AXI IIC controller at 0x80140000, labelled `RPICAM`.

That label is not decorative. Nothing knows in advance which `/dev/i2c-N` the
AXI IIC controller will come up as — the number depends on how many I2C adapters
the PS registers first, and it moves — so the camera driver walks every one of
them reading its label until it sees `RPICAM`. The interrupt number is not
decorative either — `interrupts = <0 104 4>` is `pl_ps_irq1[0]`, which is
SPI 136, because the GIC binding counts SPIs from 32. Wire the I2C interrupt
anywhere else in the block design and Linux's `xiic` driver waits for one that
never arrives.

Every instance name inside the `mipi` hierarchy is spelled the way AMD spells
it, for the same class of reason: a hierarchy driver binds by looking for
`gpio_ip_reset`, `mipi_csi2_rx_subsyst`, `demosaic`, `gamma_lut`, `v_proc_sys`
and `pixel_pack` by name, and is then handed their base addresses. CH12's own
`Ov5647Camera` checks for exactly the same six as PYNQ's `Pcam5C` does, so a
board with either sensor fitted can bind to this hierarchy. Rename one and
`ol.mipi` simply does not exist.

## The camera that was actually fitted

This chapter was written for a **Pcam 5C**, whose sensor is an OV5640. The board
it was finished on has an **OV5647** — the sensor in a Raspberry Pi Camera
Module v1. They use the same 15-pin connector, and nothing about the mistake is
visible until you read a chip ID.

The interesting part is how little of the design that invalidated, and which
part it invalidated completely.

**The PL pipeline did not care.** Both sensors send RAW10 Bayer over two MIPI
lanes, so `mipi_csi2_rx_subsyst → axis_subset_converter → demosaic → gamma_lut →
v_proc_sys → axis_channel_swap → pixel_pack → VDMA` is unchanged, IP for IP and
name for name. (Project 3's `sv` and `vhdl` builds later swapped `pixel_pack`
for a hand-written one — see *The packer, so that "SystemVerilog build" means
something* — but that was a decision about what the chapter demonstrates, not
anything the sensor forced.) One parameter moved: the OV5647's PLL gives a 218.75 MHz link
frequency, so **437.5 Mbps a lane** against the Pcam 5C's 672.

That parameter is worth dwelling on, because it is a good example of a wrong
setting that works. `C_HS_SETTLE_NS` has to land inside the D-PHY spec's window
of 85 ns + 6 UI to 145 ns + 10 UI. At 437.5 Mbps one UI is 2.29 ns, so the legal
range is 98.7 ns to 167.8 ns — and the Pcam 5C's 149 ns is *inside* it. A
bitstream built for the wrong sensor will capture from this one. It is still
wrong, and `common/mipi_hier.tcl` now says 438 Mbps and 133 ns, but knowing the
old value also works is the difference between a five-minute bisect and a
five-hour one.

**The software had to be replaced entirely.** PYNQ drives the Pcam 5C through
`libpcam5c.so`, a shared library that does two jobs at once: the sensor over
I2C, *and* the demosaic, gamma-LUT and colour-space blocks in the PL, through
base addresses `Pcam5C.__init__` hands it. The sensor half speaks OV5640 to
address 0x3c. There is no way to keep the other half.

So `sw/ov5647.py` replaces all of it, in Python — and that is the one part of
this that is better than what it replaced. The pipeline stops being a blob that
either works or does not, and the notebook gets gamma, saturation, contrast,
brightness and exposure as live controls it could not previously have had. None
of the register values are guesses: the offsets come from the driver headers
shipped with Vivado (`xv_demosaic_hw.h`, `xv_gamma_lut_hw.h`, `xv_csc_hw.h`) and
the values — the identity colour matrix in Q12, the `0x81` that starts a block
in auto-restart, the LUT packed two 16-bit entries to a 32-bit word — are the
ones AMD's own reference design for this pipeline uses, in
`mipicsiss_*/examples/xmipi_ref_design/pipeline_program.c`.

The sensor register tables are transcribed from the Linux kernel's
`drivers/media/i2c/ov5647.c`, which is **GPL-2.0-only**. The rest of CH12 is
GPL-3.0 and GPL-2.0-only does not upgrade, so those tables live alone in
`sw/ov5647_regs.py` under their original licence and attribution, and every line
of logic that acts on them is in `sw/ov5647.py`. The split is at a file boundary
on purpose.

### There is no 1280x720 mode, so one is derived

The OV5647 reads out at 2592x1944, 1920x1080, 1296x972 or 640x480. CH12 is a
720p chapter — the DisplayPort mode, the accelerator's measurements and all of
project 2's comparison are at 720p — so moving the whole chapter to fit the
sensor would have been the wrong way round.

`MODE_720P` starts from the 2x2-binned readout, which averages the array down to
1296x972 at 87.5 Mpixel/s, and narrows the array window to rows 250..1705. That
is 1456 rows, 728 after binning, of which 720 are used; the full 2624 columns
give 1312 binned, of which 1280 are used. Both used areas are exactly twice the
output, so pixels stay square, and 2560x1440 array pixels is a true 16:9 slice
of a 4:3 sensor.

The frame rate then follows from the timing grid rather than being requested. A
line is HTS = 1896 pixel clocks at 87.5 MHz, or 21.67 µs; VTS = 769 lines is
16.66 ms. **60.0 fps** — the rate the Pcam 5C ran at, which is why nothing
downstream of the sensor had to be re-measured.

HTS and VTS are the two registers most easily missed in a port, because they are
in none of the kernel driver's mode tables: that driver writes them from its
`hblank`/`vblank` V4L2 controls instead. Copy only the tables and the sensor
runs at whatever rate it was last left at.

One loose end is worth stating rather than leaving to be discovered. The derived
mode keeps HTS at 1896, so the line time is unchanged and the anti-banding step
counts it inherits from the binned table (`0x3a08`/`0x3a09`, `0x3a0a`/`0x3a0b`)
are still right — those depend on line time, not on frame time. But the *band
count* limits (`0x3a0d`, `0x3a0e`) were computed against a 1435-line frame and
this one is 769, so in dim light the sensor's own auto-exposure loop may ask for
an exposure longer than the frame it has. Bright light will not show it. What it
would look like is the frame rate quietly dropping below 60, or flicker under
mains lighting — so if either of those appears, this is the first place to look
rather than the twentieth.

The second mode, `MODE_1920x1080`, is the sensor's own 1080p readout unmodified.
It runs at **32.8 fps**, which is what its HTS and VTS give — not the 30 that
PYNQ's `MIPIMode.r1920x1080_30` implied.

### Raw Bayer is green

A Bayer sensor has twice as many green photosites as red or blue, and its colour
filters are not matched to any illuminant. Nothing in the PL pipeline corrects
for that — the demosaic block interpolates, it does not balance — so a frame
straight out of `readframe()` is distinctly green. Whatever `libpcam5c.so` did
about this for the Pcam 5C, it did behind the door.

`auto_white_balance()` is one grey-world pass: assume the average of a natural
scene is neutral, scale each channel until the three means agree, and clamp the
result at 4x so that a lens cap does not turn read noise into confetti. Crude,
fooled by a scene that really is mostly one colour, and still far better than
leaving the gains at unity.

**It is applied in the CSC, not in the sensor, and that took a wrong turn to
find.** The obvious place is the OV5647's own AWB gain registers at
0x3400–0x3406, and that is where this code wrote them for a while. Those
registers live inside the sensor's ISP, and in raw Bayer mode the ISP is
bypassed — so they do nothing at all. Measured on hardware: a requested R gain
of 2.0 and B gain of 0.5 moved the channel means by less than 0.1 counts, with
the AWB enable bit both clear and set.

The colour-space converter is already in the pipeline performing an identity
multiply, so scaling its diagonal is white balance for free. Four unit tests
covered the sensor version and all four passed the whole time: they checked
that the right registers were written, never that anything changed. A test that
can only see the near side of a hardware boundary cannot tell you the far side
did nothing.

The one thing to be careful of is the channel order, which is crossed here and
easy to get wrong: the *frame* is B,G,R because `axis_channel_swap` put blue in
the low byte, while the *CSC* works in R,G,B because it sits before that swap.
Swapping them is invisible in a grey scene and wrong in every other one, so
`sw/test_ov5647.py` checks it with a deliberately red-starved frame — and with
the green-deficient means actually measured on this board.

### The Bayer phase is measured, not asserted

The demosaic block has to be told which of RGGB, GRBG, GBRG or BGGR the sensor's
top-left 2x2 tile is, and getting it wrong produces a sharp, well-exposed
photograph in the wrong colours rather than an error. The answer is not
lookup-able: it depends on the sensor's mirror bit (which the binned mode sets),
on the parity of the crop offsets (which the derived 720p mode chooses) and on
how the receiver packs two pixels per clock.

So the project 1 notebook determines it, by turning on the sensor's own
colour-bar generator and scoring all four phases against the expected bar
colours. Those bars are generated after the pixel array, so they need no lens,
no light and no correct exposure — which matters, because "the phase is wrong"
and "the room is dark" otherwise look identical. `sw/test_ov5647.py`
deliberately does not assert a phase, for the same reason.

Measured on this board, scored against those bars:

| phase | error |
|---|---|
| **RGGB** | **72** |
| BGGR | 2028 |
| GRBG | 2836 |
| GBRG | 3224 |

RGGB wins by a factor of 28. The default in `sw/ov5647.py` said **GBRG** for a
while — reasoned out from the kernel driver's `hflip`/mbus-code table, which
gives `SGBRG10` with the flip controls at their defaults. That reasoning was
sound and the answer was the *worst of the four*: the picture came out magenta
and green. The phase also depends on the parity of the crop offsets this
chapter's derived 720p mode chooses, and on how the receiver packs two pixels
per clock. Three contributions, one accounted for.

The rule this chapter keeps relearning: for anything decided by three
interacting hardware facts, measure it. The measurement is cheaper than the
reasoning and it is right.

## The four bugs that kept the camera dark

The camera did not work for a long time, and none of the four reasons was
visible from a register readback. Every one is a trap the next person will
walk into, so they are written down in the order they were found rather than
the order they mattered.

### 1. An IP held in reset does not answer, it hangs the board

`gpio_ip_reset` channel 1 powers up at **0**. The hierarchy sets
`C_DOUT_DEFAULT_2` for channel 2 — the camera module's own reset, which comes up
released — and sets nothing for channel 1. Channel 1 drives
`proc_sys_reset/aux_reset_in`, which is configured `C_AUX_RESET_HIGH {0}`,
active low. So from power-up it holds `ap_rst_n` on `demosaic`, `gamma_lut`,
`v_proc_sys`, `axis_channel_swap` and `pixel_pack`.

An IP held in reset does not complete an AXI4-Lite transaction, and **ZynqMP has
no bus timeout on the PL ports**. So reading one of their registers does not
return an error: it wedges the master that issued it, permanently. The CPU
stops with no panic and no console output, and the board is unrecoverable
without pulling the power. A JTAG probe of the same address wedges the debug
port in exactly the same way, which is a useful diagnostic in itself — the DAP
is expendable and the board is not.

This is why PYNQ's `Pcam5C` is handed `GPIO_IP_RESET_BaseAddress` alongside the
other three: releasing it is the first thing that has to happen.
`VideoPipeline.release_video_reset()` does it, `configure()` calls it before
anything else including `stop()`, and `sw/test_ov5647.py` checks the ordering.

Three plausible theories were chased and disproved before this one landed: the
FPD aperture at 0xA0000000, the `PSU__MAXIGP0__DATA_WIDTH` mismatch, and the PL
clocks. The port-width mismatch was **real and is fixed** — the PS boots at
128-bit and the design asked for 32 — but it was not what broke the camera. It
is kept, with a build-time check, because it would have broken something later.

### 2. The sensor's reset registers, applied in the wrong order

0x3000/0x3001/0x3002 are `SYSTEM_RESET00..02`: a set bit holds a block in
reset. The kernel calls this set `sensor_oe_enable_regs`, which reads like an
output enable and is not one. It writes them in `power_on`, and
`ov5647_common_regs` then clears all three back to **0x00** — so 0, 0, 0 is the
state the sensor streams in.

`configure()` applied them *after* the tables, leaving `0x3001 = 0xff`: most of
the chip, MIPI transmitter included, held in reset. The sensor then answers on
I2C, reports its chip ID, reports the correct geometry, and transmits nothing.

### 3. Frame geometry rewritten mid-stream

The mode tables end with `0x0100 = 1`. This chapter's derived 720p mode then
writes the window, output size, HTS and VTS on top of that — which is
reprogramming frame geometry while the sensor is running, and makes these parts
emit a partial frame and stop. The receiver reported a frozen count of 21 lines
for hours because of it.

Stop, configure, start. `configure()` now drops the sensor into software
standby before touching geometry and leaves `stream_on()` to start it.

### 4. The Bayer phase — see above

Magenta and green, and the default was the worst of the four options.

### A fifth, with a different symptom: the VDMA's latched SOF error

The four above kept the camera dark. This one let it work and then made the
first run after programming flaky, which is harder to catch and took an ILA
capture and a register-level hunt of its own.

The sensor free-runs at 60 fps. It cannot be synchronised to the instant the
VDMA arms, so the first Start-of-Frame after `stream_on()` lands mid-frame and
the VDMA latches `SOFEarlyErr` and `ErrIrq` in `S2MM_DMASR`:

```
after configure                  DMASR=0x00010001  Halted
after VDMA start (sensor parked) DMASR=0x00040000  clean
0.3 s after stream_on            SOFEarlyErr | FrmCntIrq | ErrIrq
1.5 s after stream_on            SOFEarlyErr | FrmCntIrq | ErrIrq
```

Those bits are **sticky, write-1-to-clear**, and PYNQ's `readframe()` never
touches them — it looks only at bit 0 (Halted) and bit 12 (FrmCntIrq):

```python
if not self.running:                       # bit 0
    raise RuntimeError("DMA channel not started")
while self._mmio.read(0x34) & 0x1000 == 0: # bit 12
    await self._interrupt.wait()           # blocks, unbounded
```

That is why it looked intermittent: frames keep flowing with the error latched,
right up until they do not. And it explains both observed failures as one cause
— `RuntimeError: DMA channel not started` is bit 0 setting, and the hang is the
frame-count interrupt never arriving.

It is a startup race and not a geometry fault, which matters because the fixes
are completely different. Cleared once the stream is steady, the bits **stayed
clear through 450 frames** with 20 of 20 frames delivered; a pipeline actually
producing the wrong number of lines would re-latch within a frame or two. So
the pipeline does deliver its 720 lines, and `start()` now clears the latched
error and re-arms the channel if the error halted it.

A second bug fell out of chasing this one: `probe_aperture` in
`run_camera.py` was reading offset `0x00` of the VDMA, which is `MM2S_DMACR`.
These designs set `c_include_mm2s 0`, so there is no MM2S channel and that
register is not implemented. It now probes `S2MM_DMACR` at `0x30`.

### What actually found them: an ILA

`project0_camera_min` builds with `-tclargs ila`, which puts a System ILA on all
seven AXI4-Stream hops from the CSI-2 receiver to the VDMA. One capture ended
the guessing:

```
hop                                    TVALID high   TREADY high
csirxss video_out  -> subset_conv      0             1024
subset_conv        -> demosaic         0             1024
demosaic           -> gamma_lut        0             1024
gamma_lut          -> v_proc_sys       0             1024
v_proc_sys         -> channel_swap     0             1024
channel_swap       -> pixel_pack       0             1024
pixel_pack         -> VDMA             0             1024
```

Every `TREADY` high: nothing downstream is back-pressuring, the whole pipeline
is idle and ready. Every `TVALID` zero **including hop 0**, the receiver's own
output. That single capture exonerated five video IPs and the VDMA at once and
moved the search to the sensor, where the answer was.

The lesson is about visibility, not about MIPI. Every register in that pipeline
read back correct the entire time, because AXI4-Stream handshakes are not
memory-mapped and no amount of `/dev/mem` will show you one. When the registers
all look right and the data is not moving, stop reading registers.

## The software reference

`sw/sobel_ref.py` is the same filter in Python, three ways:

- `filter_frame` — vectorised NumPy, the same integer Q8 arithmetic as the RTL,
  bit-exact against the PL. This is the golden model.
- `filter_frame_naive` — three nested loops. Obviously correct and unusably
  slow; it exists so the vectorised version has something independent to be
  tested against.
- `filter_frame_opencv` — approximate, and labelled so. `cvtColor` and `Sobel`
  use different coefficients, different rounding, and a replicated rather than
  zeroed border. It is what a sensible person would actually write on the A53s,
  which makes it the honest thing to measure the accelerator against.

`sw/video_clip.py` generates a deterministic test clip — a colour gradient, hard
edges for Sobel to find, a moving square, and the frame index packed into the
top-left pixel. It is generated rather than filmed for one reason: with real
video there is no way to say what *should* have come out, so a comparison
against the reference can only be approximate. With this, the expected answer is
exactly zero differing samples.

`sw/filter_driver.py` is the register map and the zero-copy rule in one place.

```bash
cd sw
python3 test_sobel_ref.py       # 36 tests, no board needed
python3 test_video_clip.py      # 28 more
python3 test_filter_driver.py   # 25 more
```

The driver's tests are worth a word. Most of what it does is hardware, but the
register offsets are not, and neither is the rule about padded strides. Getting
an offset wrong does not produce a wrong picture — it produces an accelerator
that never asserts done and a notebook that hangs, which is a slow thing to find
on a bench and a fast thing to check here.

## Run it from a notebook

Copy to the board, into one directory: the project's `.bit`, `.hwh` and
(projects 1 and 3) `.dtbo`, plus `sw/*.py` and the notebook.

- `project0_camera_min/run_camera.py` — not a notebook, deliberately. This is
  what you run when you do not yet know whether the camera works, and a
  notebook adds a browser, a kernel and a second copy of every failure mode to
  something that should be one process and one log. It announces every step
  before attempting it and fsyncs the log, so if the board dies the last line
  names what killed it — which is exactly how the reset bug was found.

    ```
    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 \
        run_camera.py --bitstream out/camera_min.bit
    ```

- `project1_mipi_dp/notebooks/ch12_p1_camera_dp.ipynb` — brings the camera up,
  determines the Bayer phase from the sensor's own colour bars, confirms the
  byte order empirically, drives the DisplayPort, and reports the frame rate
  with nothing in the way. It then exercises the gamma LUT, the colour-space
  converter and the sensor's exposure as live controls — which the previous
  draft of this notebook had a section explaining it could not do, because
  `libpcam5c.so` configured all four blocks once at construction and left them
  as raw register regions with no API in front of them.
- `project2_video_sobel/notebooks/ch12_p2_video_sobel.ipynb` — the bit-exact
  check, the per-frame cost of all four implementations, and a clip played
  through the filter to the screen.
- `project3_camera_sobel/notebooks/ch12_p3_camera_sobel.ipynb` — the camera
  through the filter at video rate, with the same comparison against a live
  source.

## On hardware

Measured on an AUP-ZU3 running PYNQ 3.1, 1280×720, medians over 40–60 samples.
Projects 0, 2 and 3 measured; project 1 built but not re-run — see below.

### Is it bit-exact? Yes.

```
    mode    PL ms  differing samples
    gray     5.05  0
   sobel     5.55  0
  invert     5.58  0
  colour     5.04  0
```

Zero differing samples against `sobel_ref.filter_frame`, every mode, on the
generated clip. The Python model, the C kernel, the RTL testbench and the board
all agree bit for bit.

### The accelerator

5.14 ms per 720p frame, and the distribution is 5.13–5.16 — it does not vary.
That is **183.0 Mpixel/s**, 97.6% of the 187.5 the clock allows, and it scales
linearly from 64×48 up. All four modes cost the same, which is the DDR-bound
behaviour the design predicts: the filter moves 8 bytes per pixel whatever it
does with them.

### Per-frame filter cost

Median (min–max) in ms. Opening the DisplayPort changes none of it, so DDR
contention from scanout is not a factor.

| mode | PL | OpenCV | NumPy | PL vs OpenCV |
|---|---|---|---|---|
| gray | 5.14 (5.13–5.16) | 3.78 (3.73–3.97) | 71.00 | **0.7× — slower** |
| sobel | 5.14 (5.13–5.16) | 39.33 (39.06–40.34) | 166.85 | **7.7× faster** |
| invert | 5.14 (5.13–5.16) | 4.43 (4.36–4.54) | 80.03 | 0.9× |
| colour | 5.13 (5.13–5.14) | 2.76 (2.71–3.02) | 2.75 | 0.5× |

This is CH11's result, reproduced and sharpened. **Offloading pays in
proportion to arithmetic per byte moved.** Sobel is worth 7.7×; grayscale is
*slower* in the PL than NEON out of cache; and colour passthrough — mode 3,
which exists to measure exactly this — shows the DDR round trip costs about
twice what a memcpy costs in software. The accelerator's floor is the round
trip, and three of the four modes do not do enough arithmetic to climb off it.

### End to end, onto the screen

| | per frame | fps |
|---|---|---|
| no filter at all | 17.37 ms | **57.6** |
| PL | 34.94 ms | **28.6** |
| OpenCV | 52.43 ms | 19.1 |
| NumPy (bit-exact) | 175.15 ms | 5.7 |

**The 7.7× becomes 1.50×.** Not because the accelerator disappoints — it still
costs 5.14 ms against OpenCV's 39.33 — but because a 18.76 ms pixel-format
conversion sits in *both* paths and dominates the budget:

```
copy the clip into the buffer + flush    2.10 ms
the accelerator                          5.14 ms
invalidate                               0.06 ms
32 -> 24 bpp for the DisplayPort        18.76 ms   <- the actual bottleneck
```

The rates are also vsync-locked: `writeframe` blocks on the page flip, so
17.37, 34.94 and 52.43 ms are one, two and three 16.67 ms periods plus loop
overhead. Amdahl, on a bench, in one table.

### Why there is a conversion at all

The plan was to filter straight into the DisplayPort's own frame — `newframe()`
returns a buffer with a physical address, so the accelerator could write it with
nothing copied. **This DisplayPort will not have it.** It offers only 24bpp
modes; `VideoMode(W, H, 32)` is refused outright. Of the formats its driver
accepts, `RG24` is 24bpp, and the one 32bpp format (`RA24`) has memory order
A,B,G,R, which is not what the filter writes. `AR24` and `XR24`, which would
match, are rejected by the driver.

So the input side is still zero-copy — a clip frame, or a camera frame, is read
by the accelerator in place — and the output side costs a conversion.
`frame_address()` is what draws that line: it refuses the display frame rather
than returning an address that would shear the picture.

**Write that conversion with NumPy and it costs 337.62 ms.** `frame[:] =
dst[:, :, :3]` is a 4→3 de-interleave that NumPy does element by element.
`cv2.cvtColor(..., COLOR_BGRA2BGR)` is the same work through NEON at 18.76 ms —
**18× faster**, and the difference between 28.6 fps and 2.5.

### Blue really is in the low byte

Verified by eye, not asserted. Three labelled bands on the screen, each lighting
one channel: channel 0 showed **blue**, channel 2 showed **red**. So
`DRM_FORMAT_RGB888` is B,G,R in memory, the camera and OpenCV agree with it, and
`LUMA_B = 29` on channel 0 is correct. Sobel and gray output would look almost
identical if this were backwards, which is why it needed an eye rather than an
assertion.

### Two things that will waste your afternoon

**Nothing appears on screen while an X server is running.** PYNQ must be DRM
master to page-flip, and `pynq-x11.service` holds `/dev/dri/card0`. Without
stopping it, `writeframe` returns promptly and displays nothing — which looks
exactly like a working frame rate, and produced a completely fictitious set of
numbers here before it was noticed. `sudo systemctl stop pynq-x11`, and kill any
surviving `Xorg`.

**Anything else that programs the PL will fight you.** CH11's `ch11-dp.service`
was still enabled on this board, reloading its own bitstream every three
seconds underneath the tests. The symptom was an accelerator that took 5 ms on
one run and 3431 ms on the next, then timed out. `systemctl stop ch11-dp`.

## Verification status

**All four projects are verified end to end on hardware.** The camera works:
live at 1280x720, ~57 fps to the DisplayPort, and through the accelerator at
183 Mpixel/s.

### Run, and passing

- `sw/` — 218 unit tests across five files (89 for the filter and the golden
  model, 86 for the camera driver, 22 for the packer, 21 for the accelerator
  driver's timeout diagnostics and retry).
- HLS C simulation — 36 cases, four modes over nine frame sizes.
- The Python golden model against the HLS kernel — **identical, zero differing
  samples** over the same 36 combinations.
- The RTL testbench against all three implementations — 19 cases plus a
  register-map check; SystemVerilog and VHDL cycle-identical.
- The packer testbench against both implementations — 926,216 beat checks and
  10 register checks, 0 errors, SystemVerilog and VHDL cycle-identical. Checked
  against a deliberately broken packer first, so a pass means something.
- Verilator `-Wall`: clean. `dtc` on the overlays: no warnings.
- All nine bitstreams: built, **zero failing setup and hold endpoints**, zero
  critical warnings, zero errors. Project 3's `sv` and `vhdl` were rebuilt when
  the packer changed: WNS +0.379 / +0.432 ns, WHS +0.010 ns both, still zero
  failing endpoints and zero critical warnings.
- `common/check_hwh.py` on every `.hwh`.

### On the board

- **Project 0** — camera live at 1280x720, RGGB, 57.0 fps to the DisplayPort.
  The colour bars, the phase sweep and the white balance all measured, not
  assumed.
- **Project 1** — `ch12_p1_camera_dp.ipynb` executes top to bottom under
  `nbconvert --execute`, zero errors, every cell. It independently reproduced
  the phase sweep (RGGB 72, GRBG 2836, GBRG 3224, BGGR 2028), and exercised
  three things nothing else had: the gamma LUT (mean level 17 → 72 → 101 for
  γ = 1.0, 2.2, 3.0), the exposure control (100/400/700 lines → mean 42.6,
  57.9, 70.4) and the **1080p mode at 32.81 fps**. DisplayPort loop 56.7 fps.
- **Project 2** — bit-exact in all four modes, the accelerator at
  183.0 Mpixel/s, and the full cost and frame-rate tables above.
  `ch12_p2_video_sobel.ipynb` executes top to bottom under `nbconvert`.
- **Project 3** — live camera through the accelerator, all four modes on the
  screen, built `sv` so that every block in the datapath is hand-written
  SystemVerilog, packer included:

  | mode | per frame | rate |
  |---|---|---|
  | gray | 5.04 ms | 182.9 Mpixel/s |
  | sobel | 5.35 ms | 172.3 Mpixel/s |
  | invert | 5.30 ms | 173.9 Mpixel/s |
  | colour | 5.24 ms | 175.9 Mpixel/s |

  Re-measured after the hand-written packer replaced PYNQ's HLS one, since the
  camera datapath changed. These are single measurements rather than the median
  of forty that project 2 reports, which is where the spread comes from — the
  timing table in project 2, taken the same day on the same accelerator, has all
  four modes within 0.01 ms of each other. Nothing here suggests the packer
  costs anything: it is not in the accelerator's path at all, it feeds the VDMA.

  All four are within 0.25 ms of the 5.15 ms project 2 measured on a stored
  clip. The accelerator does not care where the pixels came from, which is the
  entire argument for the memory-mapped interface — and the input is zero-copy,
  since `readframe()` returns a VDMA buffer whose physical address goes straight
  into the source register. Flat cost across all four modes confirms it is
  DDR-bound: the Sobel costs what a passthrough costs.

  Bit-exact against `sobel_ref` on a live camera frame: **0 differing samples,
  max difference 0**. The camera frame arrives 4 bytes per pixel with a stride
  of 5120 for 1280 pixels, which is the hand-written packer doing its job.

  The display loop runs at 28.1 fps (OpenCV 27.7, NumPy 5.7), and that ceiling
  is the 32→24 bpp conversion, not the filter — 5 ms of accelerator against
  ~22 ms of `cvtColor` and a 16.7 ms vsync.

### Still open, and not to be shipped as fine

**The AP_DONE timeout.** Intermittently the accelerator does not assert
`AP_DONE` within 5 s. It reproduces in projects 2 and 3, which share the
accelerator, and it is not fatal to a run: the calls around it are correct and
bit-exact.

`sw/filter_driver.py` now reports the hardware state when it fires, and two
captured occurrences say the same thing:

```
CTRL=0x00000004  ap_idle
src=0x7bb00000  dst=0x7c700000  1280x720  mode=1
ap_idle is set: the kernel is NOT running
```

**`ap_idle` set is the finding.** It rules out the obvious suspicion — this is
not the datapath deadlocking mid-frame, because the datapath is not running at
all. The argument registers read back exactly what was written, so the AXI4-Lite
path is working. What did not happen is the launch.

That points at one line, `video_filter_ctrl.sv`:

```systemverilog
ADDR_CTRL: if (wstrb_r[0]) begin
    if (wdata_r[0] && ap_idle) ap_start <= 1'b1;   // dropped when !ap_idle
end
```

A write of `ap_start` is discarded, silently, whenever `ap_idle` happens to be
low at that instant — and the completion logic in the same `always_ff` sets
`ap_idle` later in the block than this test reads it, so a CTRL write landing in
the same cycle as `ap_done` sees the *old* `ap_idle` and is lost. Vitis HLS's
generated control block has no such guard: it sets `ap_start` on any write of 1
and lets the datapath clear it.

That is a mechanism which fits every observation, **not a demonstrated cause**.
It has not been reproduced in simulation yet, and until it has it stays written
down as a lead. The testbench does drive 19 back-to-back cases without a reset,
so whatever the trigger is, it needs a timing relationship the testbench's
zero-latency AXI-Lite model does not produce.

One occurrence in project 2 also showed two frames taking **3.4 s each while
still coming out bit-exact**, which no version of "the start was dropped"
explains on its own.

**The stall is understood but not conclusively closed.** The SOF mechanism above
is real, root-caused and fixed, with tests built from the literal hardware
values. But the fault was always intermittent, and one fresh-download run of
`run_camera.py` failed *after* that fix was deployed, followed by two clean
runs. Two clean runs do not settle an intermittent fault. `run_camera.py` now
logs `S2MM_DMASR` with decoded error bits at each stage, so the next occurrence
names its own cause instead of requiring this hunt again.

**Overlays cannot be swapped without a reboot.** Removing a device-tree overlay
leaks its `__symbols__` entries — the kernel says so at apply time, `WARNING:
memory leak will occur if overlay removed` — so a later overlay declaring the
same `axi_iic` node is rejected with `EINVAL`, surfacing through PYNQ as
`Device tree <name> cannot be applied` or an `OSError` from the FPGA manager.
Every CH12 camera overlay declares that node, so going from project 0 to
project 3 needs a reboot. `run_camera.py` and project 3's notebook both catch
this and fall back to `Overlay(bitfile, download=False)`, which attaches to an
already-running design without reprogramming.

### No frame rate is quoted that was not measured

One set of display figures was measured, published here in an earlier draft, and
withdrawn: with an X server holding DRM master, `writeframe` displayed nothing
while still returning promptly, so the loop was timing an empty path. Every
number above the line was taken after that was fixed, with frames confirmed on
the screen.

## What CH11 and CH12 are each for

CH11's accelerator is a function call, proven on one still image. CH12 puts the
same kind of accelerator in front of a video source and asks whether the call is
fast enough to make sixty times a second — and gives it a colour-passthrough
mode so the DDR round trip can be measured with the arithmetic subtracted out.

The interface has not changed between them. What changed is that the input now
arrives on a schedule.
