<!--
The approved implementation plan for CH12, reproduced verbatim from the session
in which it was approved (2026-08-25T13:57:29Z). Nothing below this comment has
been edited: it is the plan as agreed, not as it turned out.

What actually happened against it — three forced deviations, five hardware bugs,
and the measured results — is in ch12-plan-and-outcome.md.
-->

# CH12 — MIPI camera, video, and a Sobel filter in three projects

## Context

`CH12/` is empty. A previous attempt (commit `132f264`) built a single monolithic
project around a *streaming* AXI4-Stream Sobel block spliced into the camera
pipeline; those files are deleted in the working tree and, per your direction,
**we start fresh and do not restore them**.

The chapter is instead three separate, self-contained projects that build on each
other:

1. **project1_mipi_dp** — Pcam 5C MIPI camera to DisplayPort, driven from a
   notebook. No accelerator; this establishes the camera and the display path.
2. **project2_video_sobel** — a notebook that plays a video clip through a Sobel
   filter, with the filter available four ways: PS (NumPy/OpenCV), HLS,
   SystemVerilog and VHDL. The accelerator is **CH11-style: memory-mapped,
   DDR→DDR, `ap_ctrl_hs`, one call per frame**.
3. **project3_camera_sobel** — project 1's camera feeding project 2's filter.
   Camera → DDR → filter → DDR → DisplayPort.

All three show results both inline in the notebook and on the DisplayPort output,
whichever is appropriate to the cell.

The point of the chapter is the *pipeline*, not new filter arithmetic: CH11 proved
the accelerator on a still image, CH12 asks whether it keeps up with live video
and what the PS costs by comparison.

## Key decisions

**The accelerator keeps CH11's exact contract.** Same ports (`s_axi_control`,
`m_axi_gmem0` read, `m_axi_gmem1` write, 32-bit data, one pixel per beat,
`ap_ctrl_hs` + interrupt) and the same register map (`CTRL` 0x00, `GIER` 0x04,
`IP_IER` 0x08, `IP_ISR` 0x0C, `src` 0x10/0x14, `dst` 0x1C/0x20, `img_width` 0x28,
`img_height` 0x30, `mode` 0x38). Arguments are `img_width`/`img_height`, never
`width`/`height` — see the `RecursionError` note in `CH11/HLS/README.md`. Named
`video_filter` in CH12 so the two chapters' IP can coexist in one catalog.

Modes: `0` gray, `1` sobel, `2` invert, `3` colour passthrough. Passthrough is new
relative to CH11 and earns its place here — it measures the cost of the DDR round
trip alone, which is the baseline every fps number in the chapter is against.

**32 bits per pixel end to end.** `mipi.configure(VideoMode(1280, 720, 32))` puts
`pixel_pack` in 32bpp mode (`pynq/lib/video/pipeline.py`, mode 1) and
`DisplayPort.configure(..., PIXEL_RGBA)` matches. That makes camera frames, filter
frames and DisplayPort frames the same RGBA layout CH11's filter already works in,
with no repacking anywhere in software.

**Throughput sanity, so the chapter's claims are checkable:** 720p60 RGBA is
3.69 MB/frame; the filter at one pixel/beat at 200 MHz takes 4.6 ms/frame (~217 fps
ceiling), and the DDR traffic across camera VDMA + filter + DPDMA is ~0.9 GB/s.
Both have comfortable margin, so if 60 fps is missed it will be software overhead,
not the accelerator — which is the measurement worth making.

## Layout

```
CH12/
├── README.md                    chapter overview, the three projects, results
├── HLS/                         shared: Vitis HLS kernel (projects 2 and 3)
│   ├── src/{video_filter.cpp,video_filter.hpp,tb_video_filter.cpp}
│   ├── hls_config.cfg
│   └── build_hls.sh
├── SystemVerilog/               shared: hand-written RTL
│   ├── hdl/  sync_fifo, video_filter_ctrl, _rd, _wr, _core, video_filter
│   ├── tb/   tb_video_filter.sv  (self-checking; VHDL reuses it verbatim)
│   └── sim.sh
├── VHDL/                        shared: the same design in VHDL
│   ├── hdl/
│   └── sim.sh                   mixed-language, references ../SystemVerilog/tb
├── sw/                          shared: PS reference + tests
│   ├── sobel_ref.py             NumPy golden, naive loops, OpenCV (approximate)
│   ├── video_clip.py            deterministic test-clip generator + clip reader
│   ├── filter_driver.py         thin PYNQ wrapper over the register map
│   ├── test_sobel_ref.py
│   ├── test_video_clip.py
│   └── test_filter_driver.py
├── common/                      shared Tcl, sourced by the project builds
│   ├── mipi_hier.tcl            AMD's camera hierarchy as a proc (P1, P3)
│   ├── package_filter.tcl       package SV/VHDL as aup:rtl:video_filter:1.0
│   └── ps_config.tcl            Zynq MP preset, clocks, resets
├── project1_mipi_dp/
│   ├── build_bd.tcl             → out/camera_dp.{bit,hwh}
│   ├── constraints/pins.xdc
│   ├── dts/{Makefile,camera_dp.dtsi}
│   └── notebooks/ch12_p1_camera_dp.ipynb
├── project2_video_sobel/
│   ├── build_bd.tcl             -tclargs hls|sv|vhdl → out_<v>/video_sobel.{bit,hwh}
│   └── notebooks/ch12_p2_video_sobel.ipynb
└── project3_camera_sobel/
    ├── build_bd.tcl             -tclargs hls|sv|vhdl → out_<v>/camera_sobel.{bit,hwh}
    ├── constraints/pins.xdc
    ├── dts/{Makefile,camera_sobel.dtsi}
    └── notebooks/ch12_p3_camera_sobel.ipynb
```

Nothing is duplicated between projects except the two lines of MIPI/IIC pin
constraints and the device-tree overlay, which must be named after their own
bitstream (PYNQ matches `.dtbo` to `.bit` by basename) and so cannot be shared.

## What each project contains

### project1_mipi_dp

Block design: AMD's `mipi` hierarchy reproduced from
`/home/fbruno/git/books/AUP-ZU3/base/run_create_mipi.tcl` (BSD-3-Clause) —
`mipi_csi2_rx_subsyst` → `axis_subset_converter` → `demosaic` → `gamma_lut` →
`v_proc_sys` (CSC) → `axis_channel_swap` → `pixel_pack` → `axi_vdma` (S2MM) → DDR,
plus `gpio_ip_reset`, `axi_iic_0`, a 300 MHz `clk_wiz` and the interconnects.
Everything else in the base overlay (audio, PMOD, Grove, MicroBlaze, LEDs) is left
out. **Every IP name inside the hierarchy is spelled exactly as AMD spells it** —
`Pcam5C.checkhierarchy` (`pynq/lib/video/pcam5c.py:38`) looks for `gpio_ip_reset`,
`mipi_csi2_rx_subsyst`, `demosaic`, `gamma_lut`, `v_proc_sys` and `pixel_pack` by
name, and `libpcam5c.so` configures four of them through their base addresses.

Device tree: one AXI IIC node at 0x80140000 labelled `RPICAM` with
`interrupts = <0 104 4>`, copied from `AUP-ZU3/base/dts/base.dtsi`. The label is how
the camera library finds the right `/dev/i2c-N`; the interrupt number is
`pl_ps_irq1[0]` and the `xiic` driver hangs if it is wired anywhere else.

Constraints: `IIC_0_0_sda_io` L14 / `IIC_0_0_scl_io` K14, LVCMOS18 with pullups
(from `AUP-ZU3/base/constraints/base.xdc`); MIPI lane positions are set inside the
CSI-2 subsystem's configuration, not in the XDC.

Notebook: bring the camera up, grab a frame and show it inline, open the
DisplayPort at `PIXEL_RGBA`, run a timed frame loop and report fps, and expose the
gamma LUT and CSC (brightness/contrast/saturation) as live controls. It also
documents the 1080p30 workaround: `Pcam5C.__init__` hardcodes
`MIPIMode.r1280x720_60`, so switching resolution means calling the same library
entry point again — a workaround for a hardcoded constant, not an API.

### project2_video_sobel

Block design: PS + `video_filter` on HP0 (read) / HP1 (write) and HPM0_LPD for
control, at 200 MHz. This is CH11's block design; `CH11/build_bd_rtl.tcl` is the
model, including the explicit `reg0` address-block fix it documents — leaving the
auto-created block alongside an explicit one makes PYNQ key the IP as
`filter/s_axi_control` and the register map disappears. No camera, so this project
builds and runs without one.

Notebook: generate (or load) a clip, then for each frame — copy into a `pynq`
buffer, run the filter, display. Three things get measured side by side over the
same clip: OpenCV on the A53s, NumPy on the A53s, and the PL. Output goes inline as
a live-updating image and, in a separate cell, full-rate to the DisplayPort. A
bit-exactness cell checks PL output against `sobel_ref.filter_frame` and expects
**zero** differing samples; mode 3 gives the DDR-round-trip-only baseline.

The default clip is generated by `sw/video_clip.py` — deterministic, so the
bit-exact check has a fixed answer and no media file is committed to the repo. A
`VIDEO` variable points the notebook at a real file instead.

### project3_camera_sobel

Block design: project 1's `mipi` hierarchy plus project 2's `video_filter`, both
sourced from `common/`. The filter is **not** in the video path — the camera VDMA
writes frames to DDR and software calls the filter on each one, which is the whole
point of the CH11-style interface and is what makes the source interchangeable
between a clip and a sensor.

Notebook: camera → filter → DisplayPort at video rate, with a mode selector, an
inline preview, and the fps comparison from project 2 repeated against a live
source. The honest result the chapter is after: the PL sustains the camera's frame
rate and the PS does not.

## Implementation order

Contracts first, then the shared filter, then the projects. The filter's port list
and register map are fixed before any of the four implementations start, so the
same testbench and the same notebook bind to all of them.

1. **Contract** — write `HLS/src/video_filter.hpp` and the register-map table in
   `CH12/README.md`. Nothing else starts until these are settled.
2. **PS reference** (`sw/`) — TDD, no board needed. Tests for `sobel_ref` first
   (vectorised NumPy against naive nested loops, borders, 1×1 and 1×N degenerate
   sizes, each mode), then `video_clip`, then `filter_driver` (register offsets and
   the `ap_ctrl_hs` start/poll sequence, mocked at the MMIO boundary).
3. **HLS kernel** — C testbench against the same golden model, `csim` then `cosim`.
4. **SystemVerilog** — testbench first (`tb/tb_video_filter.sv`), driving the DUT
   the way PYNQ does: write arguments over AXI4-Lite, set `ap_start`, poll
   `ap_done`, randomised backpressure on every AXI channel. Degenerate sizes are
   what catch iteration-space bugs, which show up as deadlock rather than as wrong
   pixels. Then the RTL.
5. **VHDL** — same design, `VHDL/sim.sh` compiles it with `xvhdl` and reuses the
   SystemVerilog testbench directly rather than copying it, so the two cannot drift.
6. **project2** — build all three bitstreams, then the notebook.
7. **project1** — independent of 2–6; camera bring-up, dts, notebook.
8. **project3** — merge the two block designs, then the notebook.

## Verification

Per-step, all of it runnable without the board except where marked:

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh

# software reference (no board)
cd CH12/sw && python3 -m pytest -p no:cacheprovider -q

# lint
verilator --lint-only -Wall -sv CH12/SystemVerilog/hdl/*.sv
ghdl -a --std=08 CH12/VHDL/hdl/*.vhd

# HLS: csim + cosim
cd CH12/HLS && ./build_hls.sh

# RTL: one testbench, three DUTs
cd CH12/SystemVerilog && ./sim.sh          # hand-written SystemVerilog
                         ./sim.sh --hls    # the Verilog Vitis HLS generated
cd ../VHDL             && ./sim.sh         # mixed-language

# bitstreams
cd CH12/project1_mipi_dp      && vivado -mode batch -source build_bd.tcl
cd CH12/project2_video_sobel  && vivado -mode batch -source build_bd.tcl -tclargs sv
                                 vivado -mode batch -source build_bd.tcl -tclargs vhdl
                                 vivado -mode batch -source build_bd.tcl -tclargs hls
cd CH12/project3_camera_sobel && vivado -mode batch -source build_bd.tcl -tclargs sv
cd */dts && make                            # .dtbo next to the .bit
```

Acceptance, in order of what each thing actually proves:

- Every `sw/` test passes and `filter_frame` matches `filter_frame_naive`
  bit-exactly on every mode and every size tested.
- The RTL testbench passes on all three DUTs with identical results, and reports
  the exact pixel count out for every case.
- Out-of-context synthesis at 200 MHz closes with zero failing endpoints for all
  three, and the LUT/FF/BRAM/DSP comparison table goes in the README (HLS numbers
  from its generated Verilog, not from the block design — see CH11's README on why).
- All five bitstreams route with zero failing endpoints and **zero new warnings**.
- The generated `.hwh` files show the same register map for all three variants, so
  one notebook drives any of them.

**On hardware** (board required, and these steps will be reported as run or not
run, never assumed):

- P1: camera comes up, a frame appears inline, the DisplayPort loop reports its fps.
- P2: PL output is bit-identical to `sobel_ref.filter_frame` on the generated clip
  — zero differing samples, every mode — and the OpenCV / NumPy / PL fps table is
  measured, not estimated.
- P3: filtered camera frames reach the DisplayPort; the measured fps for PL and PS
  are recorded against the camera's 60 fps.

No fps figure, resource number or timing number goes in any README until the run
that produced it has happened. Anything not executed gets a "verification status"
section saying so plainly.

## Assumptions and risks

- **The board.** The plan assumes an AUP-ZU3 with a Pcam 5C is available for the
  hardware steps. If it is not, everything through the bitstream builds still
  completes and the notebooks ship marked as unverified — say which is the case.
- External dependencies, both already present and configurable at the top of each
  build script: `/home/fbruno/git/books/aup-zu3-board-files` (DDR preset) and
  `/home/fbruno/git/books/AUP-ZU3` (AMD's MIPI Tcl and PYNQ's prebuilt
  `pixel_pack_2` HLS IP).
- Frames must be contiguous in DDR — the accelerator has no stride register, same
  as CH11. `pynq.allocate` and PYNQ's video frames are contiguous, so this holds,
  but it is a constraint the notebook should not quietly violate.
- Reproducing AMD's hierarchy carries a real risk of a name or address mismatch
  that only shows up as `Pcam5C` refusing to bind. Project 1 exists partly to
  isolate that failure away from the filter.

## Out of scope

CH11 is not modified. No streaming/AXI4-Stream variant of the filter is built. No
video encode or file writeback — display only.

