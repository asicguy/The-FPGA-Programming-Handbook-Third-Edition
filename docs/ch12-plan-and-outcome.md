# CH12 — plan and outcome

Durable in-repo record of what happened to the CH12 plan. The plan was approved
on 2026-08-25 and existed only in a session transcript until these two files
were written; it is reproduced verbatim, and separately, in
[`ch12-plan.md`](ch12-plan.md).

| | |
|---|---|
| Chapter | `CH12/` — a camera, a video, and the same filter in both |
| Plan approved | 2026-08-25 13:57 UTC |
| Work completed | 2026-08-28 |
| Commits | `132f264` (first attempt, superseded), `cb7254e` (the chapter as it stands) |
| The plan itself | [`ch12-plan.md`](ch12-plan.md) — verbatim, unedited |
| Results and measurements | `CH12/README.md` — this file does not duplicate its tables |

---

## 1. Two attempts

**Attempt 1 — `132f264` "CH12 initial commit"** (6,432 lines added).

One monolithic project built around a **streaming** AXI4-Stream Sobel block
spliced directly into the camera video path: `sobel_stream.sv/.vhd`,
`sobel_stream_core`, `sobel_stream_ctrl`, `axis_skid`, a 673-line testbench, a
single 720-line `build_bd.tcl`, and two notebooks. Built entirely without the
board, which was unavailable at the time.

It did not come up on hardware, and the streaming interface was the wrong
contract for the chapter's argument in any case — CH11's accelerator is a
memory-mapped function call, and the question CH12 asks is whether *that* keeps
up with video. Attempt 1 was abandoned rather than debugged.

**Attempt 2 — `cb7254e` "Claude commit of CH12"** (+12,626 / −6,124).

Planned from an empty `CH12/`, explicitly not restoring attempt 1. This is the
chapter as it stands.

## 2. What the chapter is

Four projects, each buildable and runnable on its own:

| | what it is | camera? | monitor? |
|---|---|---|---|
| `project0_camera_min/` | the smallest thing that gets a camera on a screen | yes | yes |
| `project1_mipi_dp/` | OV5647 → DisplayPort, notebook-driven | yes | yes |
| `project2_video_sobel/` | a clip through the filter, four ways | no | for the live cells |
| `project3_camera_sobel/` | project 1's camera into project 2's filter | yes | yes |

One accelerator (`video_filter`), four implementations — PS reference, HLS,
SystemVerilog, VHDL — bound by one contract and checked against each other.

## 3. The approved plan

The plan is reproduced verbatim, and unedited, in **[`ch12-plan.md`](ch12-plan.md)**
— extracted from the session in which it was approved, which was until now its
only copy. Its load-bearing decisions, for reading this file without opening it:

- **The accelerator keeps CH11's exact contract.** Same ports (`s_axi_control`,
  `m_axi_gmem0` read, `m_axi_gmem1` write, 32-bit, one pixel per beat,
  `ap_ctrl_hs` + interrupt) and the same register map (`CTRL` 0x00 … `img_width`
  0x28, `img_height` 0x30, `mode` 0x38). Arguments are `img_width`/`img_height`,
  never `width`/`height`. Named `video_filter` so CH11's and CH12's IP coexist in
  one catalog. Memory-mapped, **not** streaming — the deliberate reversal of the
  first attempt.
- **Mode 3, colour passthrough, is new relative to CH11** and earns its place by
  measuring the DDR round trip alone, which is the baseline every fps number in
  the chapter is quoted against.
- **32 bits per pixel end to end** — `pixel_pack` in 32bpp mode, DisplayPort at
  `PIXEL_RGBA` — so camera frames, filter frames and display frames share one
  RGBA layout and nothing repacks in software.
- **Shared, not duplicated:** `HLS/`, `SystemVerilog/`, `VHDL/`, `sw/`,
  `common/`. One testbench binds to all three DUTs, and VHDL's `sim.sh`
  references the SystemVerilog testbench rather than copying it, so the two
  cannot drift.
- **Contract first, then the filter, then the projects.** The port list and
  register map are settled before any of the four implementations start; then PS
  reference (TDD, no board) → HLS → SystemVerilog → VHDL → project 2 → project 1
  → project 3.
- **Nothing is written down that was not run.** "No fps figure, resource number
  or timing number goes in any README until the run that produced it has
  happened. Anything not executed gets a 'verification status' section saying so
  plainly."
- **Out of scope:** CH11 is not modified, no streaming variant is built, no video
  encode or file writeback — display only.

The plan's stated risks are worth reading against section 4: it named the board's
availability and "a name or address mismatch that only shows up as `Pcam5C`
refusing to bind" as the two things most likely to go wrong. Both did, in a form
the plan did not anticipate — the camera was not the one the plan assumed.

## 4. Deviations from the plan

Three, all forced by what was found on the board. Everything else was built as
planned, in the planned order.

### 4.1 The sensor is an OV5647, not a Pcam 5C

The Pcam 5C did not arrive. The plan's entire project-1 strategy — reproduce
AMD's hierarchy name-for-name so PYNQ's `Pcam5C` class binds to it — went with
it, because there is no equivalent library for the OV5647.

What replaced it: `sw/ov5647.py` (1,237 lines) and `sw/ov5647_regs.py`, a
sensor driver written from scratch, with 86 unit tests in `sw/test_ov5647.py`.
The sensor has no 1280×720 mode, so one is derived — see *"There is no 1280x720
mode, so one is derived"* in `CH12/README.md`.

### 4.2 `project0_camera_min` was added — a fourth project

Not in the plan. It exists because the camera did not work and four projects'
worth of moving parts is the wrong place to find out why: one clock domain, one
reset, one AXI aperture, no accelerator, and a plain `run_camera.py` instead of
a notebook.

It also carries the debug build — `-tclargs ila` puts a System ILA on all seven
AXI4-Stream hops between the CSI-2 receiver and the VDMA. That is what found
the last of the camera bugs, and it is kept in the tree deliberately.

It is the thing to run first on a new board, and the thing to go back to when
something stops working.

### 4.3 `build_bd.tcl` was decomposed into `common/`

The plan called for three shared Tcl files. Four projects needing the same
hierarchy produced six: `mipi_hier.tcl`, `ps_config.tcl`, `package_filter.tcl`,
`synth_ooc.tcl`, `config.tcl`, and `check_hwh.py` (a post-build check that every
generated `.hwh` carries the expected register map).

## 5. The bug hunt

Five bugs kept the camera dark. All five were ordering or assumption; none was
arithmetic. They are written up at length in `CH12/README.md` under *"The four
bugs that kept the camera dark"* and the section following it.

1. **`gpio_ip_reset` never released.** Channel 1 powers up at 0 — the hierarchy
   sets `C_DOUT_DEFAULT_2` for channel 2 and nothing for channel 1 — and drives
   `proc_sys_reset/aux_reset_in`, which is `C_AUX_RESET_HIGH {0}`, active low.
   That holds `ap_rst_n` on demosaic, gamma_lut, v_proc_sys, axis_channel_swap
   and pixel_pack. An IP in reset does not complete an AXI4-Lite transaction,
   and **ZynqMP has no bus timeout on the PL ports**, so reading one wedges the
   CPU permanently: no panic, no console, power cycle only. Release it before
   *any* video-IP access.
2. **`SYSTEM_RESET` registers applied after the mode tables.** 0x3000/01/02 are
   `SYSTEM_RESET00..02` — a set bit holds a block in reset — despite the kernel
   calling the set `sensor_oe_enable_regs`. Applying them last left
   0x3001 = 0xff: the MIPI transmitter stayed in reset, so the sensor answered
   I2C and transmitted nothing.
3. **Frame geometry rewritten mid-stream.** Mode tables end with `0x0100 = 1`;
   writing window / output-size / HTS / VTS after that makes the sensor emit a
   partial frame and stop. Stop, configure, start.
4. **Bayer phase was RGGB, not GBRG.** Scored against the sensor's own colour
   bars: RGGB 72, BGGR 2028, GRBG 2836, GBRG 3224 — the default was the worst of
   the four. Reasoning from the kernel's flip table accounts for only one of
   three contributions (mirror bit, crop-offset parity, receiver pixel packing),
   so the phase is measured, not asserted.
5. **VDMA latched `SOFEarlyErr`.** A free-running sensor cannot be synchronised
   to the instant the VDMA arms, so the first SOF lands mid-frame and latches
   `SOFEarlyErr` + `ErrIrq` in `S2MM_DMASR` (0x34). Sticky, write-1-to-clear,
   and PYNQ's `readframe()` never clears them — it checks only bit 0 (Halted)
   and bit 12 (FrmCntIrq). One latched event produces both
   `RuntimeError: DMA channel not started` and an unbounded block. `start()` now
   clears it.

**What found them was the ILA**, not reasoning. Every TREADY high and every
TVALID zero — including the receiver's own `video_out` — proved the PL idle and
moved the search to the sensor.

**One further measured result, worth keeping:** white balance belongs in the
CSC, never in the sensor. Registers 0x3400–0x3406 are inside the OV5647's ISP,
which is bypassed in raw Bayer mode; a 2.0/0.5 gain request moved the channel
means by less than 0.1 counts. Scale the CSC diagonal instead — noting that the
CSC is R,G,B (it sits before `axis_channel_swap`) while the frame is B,G,R.

## 6. Outcome against the plan's acceptance criteria

Every acceptance item in section 3 was met. Full tables and every measurement
are in `CH12/README.md` under *"Verification status"*; the headline:

- `sw/` — **175 unit tests** across four files (89 for the filter and golden
  model, 86 for the camera driver), all passing.
- HLS C simulation — 36 cases, four modes over nine frame sizes.
- Python golden model vs. the HLS kernel — **identical, zero differing samples**
  over the same 36 combinations.
- RTL testbench against all three DUTs — 19 cases plus a register-map check;
  SystemVerilog and VHDL cycle-identical.
- Verilator `-Wall` clean; `dtc` on the overlays, no warnings.
- All **nine** bitstreams built (the plan estimated five, before project 0 and
  the extra variants): zero failing setup and hold endpoints, zero critical
  warnings, zero errors. `common/check_hwh.py` run on every `.hwh`.
- **All four projects verified end to end on hardware.** OV5647 live at
  1280×720 RGGB, 57.0 fps to the DisplayPort; 1080p at 32.81 fps; through the
  accelerator at **183 Mpixel/s**.

The chapter's actual finding, which the plan predicted would be the measurement
worth making: per-frame cost is **identical across all four modes** (5.03–5.04 ms),
so the pipeline is DDR-bound and the Sobel costs exactly what a passthrough
costs. The 28.4 fps display ceiling in project 3 is the 32→24 bpp conversion
(~19 ms of `cvtColor` plus a 16.7 ms vsync), not the filter.

The plan's rule held: one set of display figures was measured, published in an
earlier draft, and **withdrawn** — with an X server holding DRM master,
`writeframe` displayed nothing while still returning promptly, so the loop was
timing an empty path. Every number now in the README was taken after that was
fixed, with frames confirmed on the screen.

Deployed to `~/jupyter_notebooks/handbook/CH12/` on the board (not `~/handbook`,
which is now a symlink there).

## 7. Still open

Carried forward, and stated as open in `CH12/README.md` rather than shipped as
fine:

- **The AP_DONE timeout.** Twice, on the first calls after a fresh PL download,
  the accelerator did not assert `AP_DONE` within 5 s. Against an
  already-running design it took 20+ consecutive calls without a miss.
  `p3_live.py` re-arms and retries, logging every occurrence. Suspected to be
  the same startup race as the SOF error; not demonstrated, so recorded as a
  suspicion.
- **The SOF stall is root-caused and fixed but not conclusively closed.** The
  fault was always intermittent, and one fresh-download run failed *after* the
  fix, followed by two clean runs. Two clean runs do not settle an intermittent
  fault. `run_camera.py` now logs decoded `S2MM_DMASR` at each stage so the next
  occurrence names its own cause.
- **Overlays cannot be swapped without a reboot.** Removing a device-tree
  overlay leaks its `__symbols__` entries, so a later overlay declaring the same
  `axi_iic` node is rejected with `EINVAL`. Every CH12 camera overlay declares
  that node. `run_camera.py` and project 3's notebook fall back to
  `Overlay(bitfile, download=False)`.
- **No colour correction matrix.** Raw primaries are not sRGB, so saturated reds
  read strong.

## 8. Provenance

This record was reconstructed on 2026-08-29 from:

- the `ExitPlanMode` payload in session `35f5773f` (2026-08-25T13:57:29Z), which
  was the only copy of the plan — `ch12-plan.md` is that payload verbatim;
- the user turns of sessions `91cec6b6` (attempt 1) and `35f5773f` (attempt 2),
  for the order in which decisions were forced;
- `git log --stat 132f264 cb7254e`;
- `CH12/README.md` and the project memory note `ch12-camera-pipeline-stall`.

Session transcripts live under
`~/.claude-personal/projects/-home-fbruno-git-books-The-FPGA-Programming-Handbook-Third-Edition-CH12/`
and are not part of the repository.
