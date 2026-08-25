# CH12 — the Sobel filter, moved into the video path

CH11 built a filter that read a frame out of DDR and wrote it back. This chapter
puts the same arithmetic inside a live video pipeline, where it never touches
DDR at all: pixels arrive two at a time, get filtered on the way past, and land
in memory already done. They can come from the MIPI camera or from a video file
played back out of DDR — the filter cannot tell the difference, which is what
makes it possible to check the hardware against the software reference exactly.

```
CH12/
├── HLS/            Vitis HLS C++ kernel (src/, hls_config.cfg, build_hls.sh)
├── SystemVerilog/  hand-written RTL + the testbench all three share
├── VHDL/           the same design in VHDL
├── sw/             the software reference, source selection, and their tests
├── notebooks/      what drives the whole thing on the board
│                   (camera or video file, filter in the PL or in software)
├── constraints/    camera pins
├── dts/            device-tree overlay for the camera's I2C bus
└── build_bd.tcl    block design and bitstream, for any of the three
```

## The pipeline

The camera front end is AMD's, taken from the AUP-ZU3 PYNQ base overlay
(`AUP-ZU3/base/run_create_mipi.tcl`, BSD-3-Clause) and reproduced in
`build_bd.tcl` with one block spliced in:

```
Pcam 5C ─MIPI CSI-2, 2 lanes, RAW10─▶ csi2_rx ─▶ subset ─▶ demosaic ─▶ gamma_lut
   ─▶ v_proc_ss (CSC) ─▶ channel_swap ──┐
                                        ├─▶ axis_switch ─▶ [ sobel_stream ]
DDR ─▶ VDMA MM2S ─▶ pixel_unpack ───────┘                         │
                                                                  ▼
                            DisplayPort ◀─ DPDMA ◀─ DDR ◀─ VDMA S2MM ◀─ pixel_pack
```

Everything on the camera side is AMD's, and every IP name inside the `mipi`
hierarchy is spelled exactly as AMD spells it. That is not tidiness: PYNQ's
`Pcam5C` driver identifies the hierarchy by looking for `mipi_csi2_rx_subsyst`,
`demosaic`, `gamma_lut`, `v_proc_sys`, `pixel_pack`, `gpio_ip_reset` and
`axi_vdma` by name, and `libpcam5c.so` on the board configures four of them
through their base addresses. Rename one and the camera stops coming up.

The insertion point sets the interface. At that point in the pipeline the stream
is `ap_axiu<48,1,0,0>`: 48 bits carrying two pixels, `TUSER` bit 0 as
start-of-frame, `TLAST` as end-of-line. The switch in front of the filter is
transparent to all of that — both sources present the same stream, which is why
the filter has no idea which one it is looking at. Two pixels per beat is
where most of the difficulty in this chapter lives.

## Interfaces

Taken from the HLS-generated RTL so the three implementations are
interchangeable — the same testbench binds against all three, and the same
notebook drives any of them:

| Port | Type |
|---|---|
| `stream_in` / `stream_out` | AXI4-Stream, 48-bit TDATA, 1-bit TUSER, TLAST |
| `s_axi_control` | AXI4-Lite, 6-bit address, 32-bit data |
| `ap_clk` / `ap_rst_n` | 300 MHz, active-low reset |

| offset | register | |
|---|---|---|
| 0x10 | `img_width` | pixels per line, even, ≤ 1920 |
| 0x18 | `img_height` | lines per frame |
| 0x20 | `mode` | 0 gray, 1 sobel, 2 invert, 3 colour passthrough |

There is no `CTRL` register, no `GIER`, no `IP_ISR` and no interrupt. CH11's
kernel was `ap_ctrl_hs` and PYNQ started it per frame; this one is
`ap_ctrl_none` and free-runs off the stream, like every other IP in the
pipeline. `mode` is latched at start-of-frame, so writing it from a notebook
cannot tear a frame in half.

The argument names are `img_width`/`img_height`, never `width`/`height` — see
the `RecursionError` note in CH11's `HLS/image_filter.hpp`. The RTL inherits the
constraint because it inherits the register map.

## Geometry: why the loop runs one row and one beat too far

Filtered pixel (r, c) needs input rows r-1, r, r+1 and columns c-1, c, c+1, so
output beat b of row r cannot be computed until input beat b+1 of row r+1 has
arrived. The loop therefore runs over (H+1) × (B+1) steps, where B = width/2:

```
consume input beat b of row r        when  r < H and b < B
produce output beat b-1 of row r-1   when  r ≥ 1 and b ≥ 1
```

Both totals come to exactly B×H, which is what makes the block transparent to
the rest of the pipeline: one beat out for every beat in, no frame ever short or
long. This is CH11's (height+1) × (width+1) iteration space, and it is here for
the same reason — there it kept two dataflow FIFOs balanced, here it keeps the
AXI4-Stream frame intact. Getting it wrong does not produce a wrong picture; it
produces a VDMA that never completes a frame.

**The extra row is what makes a streaming filter possible at all.** It consumes
nothing: the input frame is over and the camera is in vertical blanking. It runs
purely to flush the last output line out of the line buffers, so the frame that
leaves the block is complete before the next start-of-frame arrives. Without it
the last line of every frame would be owed into the next one and the picture
would crawl up the screen by a line per frame.

## Two pixels per clock

The MIPI front end runs at two pixels per clock, so the filter has to produce
two Sobel results per beat. The two windows overlap in two of their three
columns, so four columns of context cover both:

```
step b:  q0 = col 2b-3   q1 = col 2b-2   q2 = col 2b-1   new = col 2b
         output pixels are cols 2b-2 (centred on q1) and 2b-1 (centred on q2)
```

Three rows of that is a 3×4 window. A one-pixel-per-clock filter would need
3×3, and that difference — plus the line buffers holding pairs rather than
single pixels — is most of what two pixels per clock costs to write.

It buys margin nobody needs here. Two pixels at 300 MHz is 600 Mpixel/s. The
2-lane RAW10 link runs at 672 Mbps a lane, so it can carry 134 Mpixel/s, and
the camera sends 55 Mpixel/s at 720p60. The filter runs at about a tenth of
its capacity, and what would stop it going faster is the line buffers, which
are sized for 1920 pixels — not the arithmetic.

## Two sources: the camera, or a file

The filter is a streaming block with no memory port, so *"run this video file
through it"* is not something software can arrange on its own — there has to be
a path in the PL that plays frames from DDR into the video stream. CH12 adds
one, which is the only part of the `mipi` hierarchy that is not AMD's:

| block | what it does |
|---|---|
| VDMA MM2S | reads frames back out of DDR. `c_mm2s_sof_enable` is on, so the stream carries TUSER at start-of-frame and TLAST at end-of-line — without it the filter would never find a frame boundary and would sit in its synchronisation state draining every beat |
| `pixel_unpack_2` | the mirror of the packer already there: 64-bit words back into 48-bit two-pixel beats |
| `axis_switch` | two inputs, one output: camera on S00, DDR on S01 |
| `source_select` | an AXI GPIO driving the switch's `s_req_suppress` |

Both sources hand the filter the identical 48-bit stream, so the hardware cannot
tell them apart. A frame played from a file is filtered by the same logic at the
same rate as a frame from the sensor.

**Why a GPIO and not the switch's own registers.** A two-into-one AXI4-Stream
switch has no AXI4-Lite interface — the register map only appears when there is
more than one master to route to. What it has instead is `s_req_suppress`, one
bit per input, which stops the arbiter ever granting that input. Suppressing one
leaves exactly one source connected, which is the behaviour wanted anyway: the
unselected source stalls rather than interleaving its lines into the selected
one. The GPIO's reset default is 0b10 — file player suppressed, camera flowing —
so an overlay that is loaded and never told anything behaves exactly as it did
before this path existed.

**The unselected source is backpressured, not switched off.** With the camera
deselected its pixels have nowhere to go, the CSI-2 receiver's line buffer fills
and it begins flagging overflow. It resynchronises at the next start-of-frame,
so nothing breaks, but `video_source.camera_enabled(mipi, False)` turns the
receiver off for a long stretch of playback and saves the noise.

**Width must be a multiple of 8** on the file path. `pixel_unpack_2` turns three
64-bit words into four 48-bit beats, so a line has to be a whole number of those
groups. Both camera resolutions are.

### What this buys beyond convenience

A known input makes the hardware checkable. With the camera there is no way to
know what went into the filter — the sensor is still exposing and the frame
before the one you filtered is not the frame you filtered — so a comparison
against the software reference can only ever be approximate. Play a deterministic
test pattern in and the comparison has an exact answer: **zero** differing
samples, in every mode. `notebooks/ch12_video_sobel.ipynb` does exactly that,
and it is the same check the RTL testbench makes in simulation, made again on
the real hardware.

## 720p60 and 1080p30

The filter handles both — the line buffers are sized for 1920 pixels, which is
960 beats — but PYNQ's `Pcam5C` driver does not offer the choice. It calls
`libpcam5c.so` once, when the hierarchy is constructed, with the mode hardcoded
to `MIPIMode.r1280x720_60`. `mipi.configure(VideoMode(1920, 1080, 24))` changes
what the VDMA expects and not what the sensor sends.

`notebooks/ch12_video_sobel.ipynb` has a `set_camera_mode()` cell that calls the
same library entry point again with the other mode. It reaches around the driver
into the library it wraps, so treat it as a workaround for a hardcoded constant
rather than an API.

## Simulate

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
cd SystemVerilog && ./sim.sh          # the hand-written SystemVerilog
                    ./sim.sh --hls    # the Verilog Vitis HLS generated
cd ../VHDL        && ./sim.sh         # mixed-language: VHDL DUT, same testbench
```

One testbench, three DUTs. The VHDL build does not copy it — `VHDL/sim.sh`
references `../SystemVerilog/tb/tb_sobel_stream.sv` directly, so the two
implementations cannot drift apart in what they are tested against.

`./sim.sh --hls` is standing in for C/RTL co-simulation, which Vitis will not
run on this design: cosim supports `ap_ctrl_none` only when the whole top level
is a single II=1 pipeline, and this one has a synchronisation phase, a mode
branch and a nested loop. Driving the generated RTL from the same testbench
checks the same thing against the same stimulus.

All three pass all twenty checks:

```
  [        GRAY 64x48]   64 x 48      1536 beats x2  gap  0%  bp  0%  PASS
  [       SOBEL 64x48]   64 x 48      1536 beats x2  gap  0%  bp  0%  PASS
  [      INVERT 64x48]   64 x 48      1536 beats x2  gap  0%  bp  0%  PASS
  [       COLOR 64x48]   64 x 48      1536 beats x2  gap  0%  bp  0%  PASS
  [     SOBEL stalled]   64 x 48      1536 beats x2  gap 30%  bp 30%  PASS
  [     COLOR stalled]   64 x 48      1536 beats x2  gap 30%  bp 30%  PASS
  [         SOBEL 2x2]    2 x 2          2 beats x2  gap  0%  bp  0%  PASS
  [        SOBEL 2x16]    2 x 16        16 beats x2  gap  0%  bp  0%  PASS
  [        SOBEL 16x1]   16 x 1          8 beats x2  gap  0%  bp  0%  PASS
  [        SOBEL 16x3]   16 x 3         24 beats x2  gap  0%  bp  0%  PASS
  [          GRAY 6x5]    6 x 5         15 beats x2  gap  0%  bp 20%  PASS
  [      MODE7->SOBEL]   32 x 24       384 beats x2  gap  0%  bp  0%  PASS
  [       SOBEL 320x8]  320 x 8       1280 beats x2  gap  0%  bp 15%  PASS
  [         SOBEL 6x5]    6 x 5         15 beats x2  gap  0%  bp  0%  PASS
  [         GRAY 12x6]   12 x 6         36 beats x2  gap  0%  bp  0%  PASS
  [            RESYNC]   32 x 12    unsynced frame discarded  PASS
  [         ODD WIDTH] width 15 drained, nothing emitted  PASS
  [SWITCH sobel->gray]   32 x 12    mode 1 then 0  PASS
  [SWITCH gray->color]   32 x 12    mode 0 then 3  PASS
  [         REGISTERS] readback ok (mode = 3)
```

Each case drives two frames back to back. The second is the one that matters:
if the flush row were missing, or the line buffers left in the wrong state at
the end of a frame, frame two is where it shows. The testbench also checks the
beat count exactly — an extra beat is as fatal downstream as a missing one — and
that TUSER lands on exactly the first beat of a frame and TLAST on the last beat
of every line.

## The bug the testbench found

The HLS kernel had this in it, and it looks entirely reasonable:

```c
#pragma HLS DEPENDENCE variable=lb1 type=inter dependent=false
```

Successive steps do address successive beats, so telling HLS the line buffers
carry no inter-iteration dependence flattens the two loops into one II=1
pipeline and saves a few cycles per line. It is also a lie. Step (r, b) writes
`lb1[b]` and step (r+1, b) reads it back, and those are B+1 steps apart;
`inter false` claims independence at *every* distance. With the loops flattened
and the pipeline about nine stages deep, any frame narrower than about twenty
pixels reads the line above before the write has landed, and the filter emits a
frame that is one line stale.

C simulation cannot see it — there is no pipeline in C. It took the RTL
testbench, and only on the 6×5 case: the other narrow cases are all border
pixels, which are black whatever the line buffer says. Without the pragma the
column loop still pipelines at II=1; only the row loop stops flattening, so the
pipeline drains and refills once per line. At 1080p that is about 8600 cycles a
frame — 29 µs at 300 MHz against a 33 ms frame — and it happens during
horizontal blanking.

The hand-written RTL never had the problem — its write-back is one stage behind
its read, so the distance it needs is two steps, not B+1.

## Out-of-context synthesis

`xczu3eg-sfvc784-2-e` at 3.3 ns (300 MHz), accelerator alone, so the columns are
comparable. For HLS that means synthesising the generated Verilog from
`HLS/sobel_stream/hls/syn/verilog/`, not reading numbers off the full block
design:

| | SystemVerilog | VHDL | HLS |
|---|---|---|---|
| WNS @ 3.3 ns | +0.773 ns | +0.551 ns | **+0.920 ns** |
| implied Fmax | 396 MHz | 364 MHz | **420 MHz** |
| Total LUTs | **685** | 708 | 1209 |
| Registers | **452** | 552 | 1645 |
| BRAM18 | 2 | 2 | 2 |
| DSPs | **0** | **0** | 10 |

The two BRAM18s are the line buffers and are the same in all three, because the
algorithm decides them: two rows of 960 sixteen-bit words. Everything else is
the usual trade. HLS spends registers on a deeper pipeline and buys 25 MHz of
headroom with them; it also puts the luma multiplies in DSPs, while Vivado
synthesises the same three constant multiplies out of LUTs for the RTL versions.
Constant multiplication by 29, 150 and 77 is cheap in fabric, so those ten DSPs
are not buying anything here — but they are free on this device, and on a design
that needed them elsewhere they would not be.

The two RTL versions land within 23 LUTs of each other, which is the expected
result when the same design is written twice in two languages.

## Build a bitstream

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
cd HLS && ./build_hls.sh          # only needed for the HLS variant
cd ..
vivado -mode batch -source build_bd.tcl -tclargs hls    # -> out_hls/
vivado -mode batch -source build_bd.tcl -tclargs sv     # -> out_sv/
vivado -mode batch -source build_bd.tcl -tclargs vhdl   # -> out_vhdl/
cd dts && make                                          # -> sobel_stream.dtbo
```

One script for all three: the block design is identical apart from which
`sobel_stream` IP is instantiated, and duplicating four hundred lines of IP
Integrator Tcl to change one VLNV is a good way to let three designs drift
apart. For `sv` and `vhdl` it packages the RTL as `aup:rtl:sobel_stream:1.0`
first, including the `reg0` address-block fix CH11 documents — leave the
auto-created address block alongside an explicit one and PYNQ keys the IP as
`sobel/s_axi_control`, so `ol.mipi.sobel` has no register map at all.

It needs two things from outside the repo, both configurable at the top of the
script: the AUP-ZU3 board files (for the DDR preset) and PYNQ's prebuilt
`pixel_pack_2` IP from the AUP-ZU3 checkout.

Post-route on `xczu3eg-sfvc784-2-e`, whole design, 300 MHz video clock and
100 MHz control clock:

| | SystemVerilog | VHDL | HLS |
|---|---|---|---|
| WNS on the 300 MHz clock | **+0.534 ns** | +0.445 ns | +0.375 ns |
| WNS on the 100 MHz clock | +4.993 ns | +5.790 ns | +6.554 ns |
| Failing endpoints | 0 | 0 | 0 |
| CLB LUTs | **18000** | 18026 | 18464 |
| CLB registers | **24038** | 24133 | 25106 |
| Block RAM tiles | 62 | 62 | 62 |

Those totals are the whole pipeline — the CSI-2 receiver, the demosaic, the
gamma LUT, the colour-space converter, both VDMA channels, the unpacker, the
switch and two interconnects. The filter is 4–7% of it depending on which one
you build, which is worth keeping in proportion: the whole difference between
the three implementations is about 460 LUTs, in a design that spends 18000 of
them getting pixels between a camera, DDR and a screen.

The DDR playback path costs about 2100 LUTs, 2800 registers and 15 BRAM tiles —
more than the filter it feeds. Most of that is the VDMA's second channel and its
line buffer. Note also that the 300 MHz margin drops from around +0.63 ns to
+0.53 ns when it is added: there is more logic contending for the same clock,
and the interconnect grew a slave port.

The worst path in every build is a hold path inside the CSI-2 subsystem that the
router closes to about 10 ps. That is normal for a routed design and not a sign
of anything marginal; setup is what the table above reports.

The two overlays also present the same register map to PYNQ. Reading the
generated `.hwh` files back:

```
hls   img_width    offset=    16  size=32      sv    img_width    offset=  0x10  size=32
hls   img_height   offset=    24  size=32      sv    img_height   offset=  0x18  size=32
hls   mode         offset=    32  size=32      sv    mode         offset=  0x20  size=32
```

Same three registers at the same three offsets, so `ol.mipi.sobel.register_map`
behaves identically whichever bitstream is loaded.

## The device-tree overlay

`dts/` builds `sobel_stream.dtbo`, which has to sit next to `sobel_stream.bit`
on the board — PYNQ loads a device-tree overlay by matching its basename against
the bitstream's. It declares exactly one thing: the AXI IIC controller at
0x80140000, labelled `RPICAM`.

That label is not decorative. The camera is brought up by `libpcam5c.so` through
`/dev/i2c-N`, and the driver finds the right adapter by walking `/dev/i2c-*` and
reading each one's label until it sees `RPICAM`. The interrupt number is not
decorative either: `interrupts = <0 104 4>` is `pl_ps_irq1[0]`, which is SPI 136,
and the GIC binding counts SPIs from 32. Wire the I2C interrupt anywhere else in
the block design and Linux's `xiic` driver waits for one that never arrives.

## The software reference

`sw/sobel_ref.py` is the same filter in Python, three ways:

- `filter_frame` — vectorised NumPy, the same integer Q8 arithmetic as the RTL,
  bit-exact against the PL. This is the golden model.
- `filter_frame_naive` — three nested loops. Obviously correct and unusably
  slow; it exists so the vectorised version has something independent to be
  tested against.
- `filter_frame_opencv` — approximate, and labelled so. `cvtColor` uses
  different luma coefficients and rounding and `Sobel` extends the border rather
  than blacking it out, so it does not match. It is what a sensible person would
  actually write in software, which makes it the honest thing to measure the
  accelerator against.

`sw/video_source.py` is the other half: selecting between the camera and the
frame player, driving the VDMA's MM2S channel, and generating the test pattern
the bit-exact check is built on.

```bash
cd sw
python3 test_sobel_ref.py       # 14 tests, no board needed
python3 test_video_source.py    # 10 more, likewise
```

The second file's tests are worth a word. Most of `video_source.py` is hardware,
but the suppress bits are not: `s_req_suppress` names the input to *stop*, so
the mapping is inverted from how anyone says it out loud, and getting it
backwards produces a design that hangs rather than one that shows the wrong
picture. That is an hour on the bench to find and a second to check here.

`sw/video_sobel.py` is the software reference *design*: the same camera, the
same screen, the filter done by the A53s with the PL block in colour
passthrough.

```bash
sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 \
    video_sobel.py --impl numpy      # or --impl opencv, or --impl pl

# either source, either filter -- the four combinations are the experiment
video_sobel.py --source file --video clip.mp4 --impl pl
video_sobel.py --source file --video clip.mp4 --impl numpy
```

Note what stays in hardware even there. The MIPI receiver, the demosaic, the
gamma LUT and the CSC are in the PL in every version of this design — there is
no way to get RAW10 off a D-PHY into a Python process otherwise. What moves
between "software" and "hardware" is the filter, which is the part the chapter
is about.

## Run it from a notebook

Copy to the board, into one directory: `out_<impl>/sobel_stream.bit`,
`out_<impl>/sobel_stream.hwh`, `dts/sobel_stream.dtbo`, `sw/sobel_ref.py`,
`sw/video_source.py` and the two notebooks. Add a video file or a still if you
want to play one; the test pattern needs neither.

- `notebooks/ch12_video_sobel.ipynb` — brings the camera up, shows the four
  modes, puts the result on the DisplayPort, switches the filter's input between
  the camera and frames from DDR (a video file, a still, or the test pattern),
  and checks the hardware against the software reference: exactly, on the test
  pattern, and approximately on the camera.
- `notebooks/ch12_ps_vs_pl.ipynb` — the same filter in the PL and on the A53s,
  timed.

## What CH11 and CH12 are each for

CH11's accelerator is a function call: hand it a frame in DDR, wait, get one
back. Its cost scales with how often you call it, and the CH11 numbers say that
call is worth making for Sobel (6.3× faster than OpenCV on four A53s) and not
worth making for grayscale (no faster at all, because grayscale is memory-bound
and NEON out of cache beats a round trip through DDR).

CH12's filter is not a function call. It costs one line of latency and no frames
per second, because it is upstream of memory entirely — the frame arrives
already filtered and turning the filter on does not make the next frame arrive
any later. What it cannot do is filter something already sitting in DDR; there
is no port to feed it from.

Neither is the better accelerator. They are the same arithmetic wearing
different interfaces, and the interface is the whole design decision.

## Verification status

Everything here is verified in simulation and built to a bitstream. **None of it
has been run on hardware** — the board was not available while it was written.
Specifically:

- HLS C simulation, the RTL testbench against all three implementations, the
  software reference's unit tests, out-of-context synthesis and the full block
  design build all pass, and the numbers quoted above come from those runs.
- The notebooks, `sw/video_sobel.py`, `sw/video_source.py`, the device-tree
  overlay and camera bring-up have never been executed. They follow AMD's
  base-overlay design closely, but nothing in this section has been proven
  against real hardware.
- The DDR playback path is verified as far as a bitstream: the block design
  builds, the widths and addresses are right in the generated `.hwh`, and
  timing closes. Whether the VDMA's MM2S channel and `pixel_unpack_2` hand the
  filter a frame it recognises has not been observed — that is what the test
  pattern cell in the first notebook exists to answer, and it will answer it
  bluntly, because the expected result is zero differing samples.
- No frame-rate figure appears anywhere in this README, because none has been
  measured. The notebooks print theirs.
