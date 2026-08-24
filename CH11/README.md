# CH11 — RGBA gray / Sobel / invert filter, three ways

The same accelerator implemented three times, with the same interfaces, the same
register map and bit-identical output. Any of them drops into the same block
design and is driven by the same PYNQ notebook.

```
CH11/
├── HLS/            Vitis HLS C++ kernel (see HLS/README.md)
├── deploy/         copy to the board + install the DisplayPort service
├── SystemVerilog/  hand-written RTL
│   ├── hdl/        sync_fifo, ctrl, rd, wr, core, top
│   ├── tb/         self-checking testbench
│   └── sim.sh      xsim: compile + run
└── VHDL/           the same design in VHDL
    ├── hdl/
    ├── tb/         (the SystemVerilog testbench, reused verbatim)
    └── sim.sh      mixed-language xsim
```

## Why the RTL exists

The HLS version is the one you would ship. These two are here to show what HLS
actually generated for you — the AXI burst logic, the credit-based flow control,
the line buffers and the `ap_ctrl_hs` handshake are all things HLS wrote from
five `#pragma` lines, and writing them by hand is the fastest way to understand
what those pragmas cost.

## Interfaces

Taken from the HLS-generated RTL so the three are interchangeable:

| Port | Type |
|---|---|
| `s_axi_control` | AXI4-Lite, 6-bit address, 32-bit data |
| `m_axi_gmem0` | AXI4 read, 64-bit address, 32-bit data (one pixel per beat) |
| `m_axi_gmem1` | AXI4 write, same |
| `ap_clk` / `ap_rst_n` / `interrupt` | active-low reset |

Register map is identical to HLS: `CTRL` 0x00, `GIER` 0x04, `IP_IER` 0x08,
`IP_ISR` 0x0C, `src` 0x10/0x14, `dst` 0x1C/0x20, `img_width` 0x28,
`img_height` 0x30, `mode` 0x38.

The arguments are `img_width`/`img_height`, never `width`/`height` — see the
`RecursionError` note in `HLS/README.md`. The RTL inherits that constraint
because it inherits the register map.

## Structure

```
gmem0 → read master → BT.601 luma → FIFO → core → FIFO → write master → gmem1
```

mirroring the three `#pragma HLS DATAFLOW` stages. The core is a four-stage
pipeline over two `MAX_WIDTH`-deep line buffers:

| Stage | Work |
|---|---|
| S0 | counters; present the column address; pop input |
| S1 | line-buffer data arrives; shift the window; write the buffers back |
| S2 | Sobel partial sums `gx` / `gy` |
| S3 | absolute value, clamp, mode select, push output |

All four share one enable, so they advance together or stall together.

The iteration space is `(height+1) × (width+1)`, exactly as in the HLS kernel: a
pixel is consumed when `r < height && c < width` and produced when `r ≥ 1 &&
c ≥ 1`. Both counts come to exactly `width × height`, which is what keeps the
two FIFOs balanced. Getting this wrong shows up as a deadlock rather than as
wrong pixels, which is why the testbench leans on degenerate sizes.

## Simulate

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
cd SystemVerilog && ./sim.sh
cd ../VHDL      && ./sim.sh
```

The VHDL build is mixed-language: it compiles the VHDL DUT with `xvhdl` and
reuses the **same** SystemVerilog testbench. That is deliberate — identical
stimulus and identical golden model, so a pass means both implementations agree
with the HLS C simulation and with each other.

The golden model in the testbench is a transcription of
`HLS/src/tb_image_filter.cpp`. The testbench drives the DUT the way PYNQ does:
write the argument registers over AXI4-Lite, set `ap_start`, poll `ap_done`. All
AXI channels apply randomised backpressure.

Both implementations pass all ten cases, with **identical poll counts** on every
one — they are cycle-identical, not merely functionally equivalent:

```
  [        GRAY 64x48]   64 x 48       3072 px  PASS        1135 polls
  [       SOBEL 64x48]   64 x 48       3072 px  PASS        1136 polls
  [      INVERT 64x48]   64 x 48       3072 px  PASS        1139 polls
  [       SOBEL 37x23]   37 x 23        851 px  PASS        383 polls
  [         SOBEL 3x3]    3 x 3           9 px  PASS        11 polls
  [         SOBEL 1x1]    1 x 1           1 px  PASS        4 polls
  [        SOBEL 1x16]    1 x 16         16 px  PASS        16 polls
  [        SOBEL 16x1]   16 x 1          16 px  PASS        16 polls
  [     SOBEL 160x120]  160 x 120     19200 px  PASS        6600 polls
  [      MODE4->SOBEL]   32 x 24        768 px  PASS        354 polls
```

`MODE4` is not a defined mode; the C tests `== MODE_GRAY` then `== MODE_INVERT`
and falls through to Sobel for everything else, so the RTL compares the whole
32-bit word rather than the low bits.

## Synthesis

Out-of-context on `xczu3eg-sfvc784-2-e` at 5 ns (200 MHz) — all three run
through the same flow, accelerator alone, so the columns are comparable. For
HLS that means synthesising its generated Verilog from
`HLS/image_filter/hls/impl/ip/hdl/verilog/`, not reading numbers off the full
block design (those include the PS interface logic and three SmartConnects and
are roughly 40% larger):

| | SystemVerilog | VHDL | HLS |
|---|---|---|---|
| WNS @ 5 ns | +0.631 ns | +0.586 ns | **+1.977 ns** |
| implied Fmax | 229 MHz | 227 MHz | **331 MHz** |
| CLB LUTs | **1385** | **1384** | 2841 |
| CLB registers | **817** | **817** | 3391 |
| Block RAM | **1** | **1** | 5.5 |
| DSPs | **3** | **3** | 13 |

The RTL is about half the LUTs and a quarter of the registers, because it does
exactly one thing. HLS spends the difference on dataflow channel bookkeeping,
deadlock-detection logic and a deeper, more aggressively pipelined datapath —
and that pipelining is what buys it 100 MHz of extra headroom. Neither trade is
wrong; they are different points on the same curve.

The two RTL versions land within one LUT of each other, which is the expected
result when the same design is written twice in two languages.

## Build a bitstream

```bash
vivado -mode batch -source build_bd_rtl.tcl -tclargs sv     # -> out_sv/
vivado -mode batch -source build_bd_rtl.tcl -tclargs vhdl   # -> out_vhdl/
```

Same block design as `HLS/build_bd.tcl` — PS, two SmartConnects, filter on
HP0/HP1 and HPM0_LPD, PL0 at 200 MHz — but the script first packages the RTL as
IP (`aup:rtl:image_filter:1.0`) and then instantiates that.

Two things about packaging that are easy to get wrong, both of which break PYNQ
rather than the hardware:

- **A module reference will not take a SystemVerilog top file.** `create_bd_cell
  -type module` rejects it outright, hence the IP-XACT packaging step.
- **`ipx` infers the AXI interfaces but not the register definitions**, and it
  auto-creates its own address block called `reg0`. Leaving that alongside an
  explicitly added one gives the interface *two* address blocks, and PYNQ then
  keys the IP as `image_filter_0/s_axi_control` — so `ol.image_filter_0` has no
  register map and `filt.register_map` raises `AttributeError`. The script
  removes every auto-created block, adds exactly one named `Reg`, and declares
  the registers and the `CTRL` fields explicitly so the map matches HLS.

Post-route on `xczu3eg-sfvc784-2-e` at 200 MHz, in the full block design:

| | SystemVerilog | VHDL | HLS |
|---|---|---|---|
| WNS | +0.337 ns | +0.344 ns | +1.583 ns |
| Routing | clean, 0 errors | clean, 0 errors | clean, 0 errors |

## Verified on hardware

All three bitstreams run on the AUP-ZU3 over the same input and compared byte
for byte. Random image plus a hard-edged block, every mode, two sizes:

```
Golden-model check          all 18 combinations   wrong = 0
Cross-check against HLS     all 12 combinations   IDENTICAL

  640x480:   HLS= 1.73 ms   SV= 1.75 ms   VHDL= 1.76 ms
  1920x1080: HLS=11.24 ms   SV=11.37 ms   VHDL=11.35 ms

RESULT: ALL MATCH
```

Not "close" — the output buffers are bit-for-bit equal to the HLS accelerator's
at 640×480 and 1920×1080 in grayscale, Sobel and invert.

`HLS/hil_test.py` also runs **unmodified** against both RTL bitstreams, which is
the practical statement of drop-in compatibility: same register names, same
offsets, same `ap_ctrl_hs` handshake.

| | SV | VHDL |
|---|---|---|
| `hil_test.py` | ALL MODES PASS | ALL MODES PASS |
| Sobel 640×480 | 1.78 ms | 1.76 ms |
| vs NumPy on A53 | 28.7× | 28.6× |

The RTL is ~1% slower than HLS on the same frame (182.4 vs 184.5 Mpixel/s at
1080p). All three sit at ~92% of the theoretical 200 Mpixel/s for II=1 at
200 MHz, so they are DDR-bound, not compute-bound — which is why HLS's 100 MHz
of extra Fmax headroom buys nothing here. It would start to matter only if the
datapath widened enough to stop being the bottleneck.

Treat the 1% as indicative rather than settled: it is consistent in direction
across every run, but the run-to-run spread on a single configuration is of the
same order.

## PS versus PL

`HLS/ps_vs_pl.py` runs the same three algorithms on the A53s and on the
accelerator over identical data. The NumPy version is checked bit-exact against
the PL before it is timed, so that row is a like-for-like comparison; OpenCV is
labelled approximate because `cvtColor` and `Sobel` use different coefficients,
rounding and border handling.

**Sobel, 1920×1080**, on 4× Cortex-A53 @ 1.2 GHz:

| Implementation | Time | Throughput | vs PL |
|---|---|---|---|
| PL (HLS, SV, VHDL alike) | **11.39 ms** | 182 Mpixel/s | 1.0× |
| OpenCV, NEON, 4 threads | 72.18 ms | 28.7 Mpixel/s | 6.3× slower |
| NumPy (bit-exact) | 363.37 ms | 5.7 Mpixel/s | 31.9× slower |
| Pure Python | ~29.6 s (extrapolated) | 0.07 Mpixel/s | ~2600× slower |

Cache maintenance costs almost nothing: 11.39 ms compute-only becomes 11.53 ms
including `flush()` and `invalidate()`, about 1%.

### The result that complicates the story

Grayscale is a different picture entirely:

| Grayscale | 640×480 | 1920×1080 |
|---|---|---|
| PL | 1.90 ms | 11.40 ms |
| OpenCV | **0.79 ms** | 12.39 ms |

**At 640×480 the A53s beat the accelerator by 2.4×**, and at 1080p it is a tie.
Grayscale is three multiplies and a shift per pixel — almost no arithmetic per
byte moved — so it is purely memory-bound, and NEON working out of cache beats a
PL accelerator that must round-trip every pixel through DDR over the HP ports.
At 640×480 the working set is cache-friendly; by 1080p it spills and the
advantage disappears.

The PL's margin therefore tracks arithmetic intensity, not image size:

| Kernel | Work per pixel | PL advantage over best PS code |
|---|---|---|
| grayscale | ~4 ops | none (0.4–1.1×) |
| Sobel | ~20 ops | 6.3× |

A corroborating detail: OpenCV Sobel takes 72.14 ms on one thread and 72.18 ms
on four. Extra cores buy nothing because it is bandwidth-bound — the same reason
the accelerator sits at ~92% of its theoretical II=1 rate rather than 100%.

The honest summary is that offloading this filter is worth it for Sobel and not
worth it for grayscale, and that the ~2600× figure against pure Python, while
true, compares against something nobody should ship. The fair comparison is
against OpenCV, and there the answer is 6.3×.

## Run it on the board

```bash
cd deploy
./deploy.sh --impl hls --start --enable    # or --impl sv / --impl vhdl
```

Copies the chosen build to the board and installs the DisplayPort demo as a
systemd service. All three implementations can live on the board at once;
switching between them is an edit to `/etc/default/ch11-dp` plus a restart. See
`deploy/README.md` — including why `XILINX_XRT` and SIGTERM handling matter, and
why the board's clock makes timestamps useless.

## Two bugs worth keeping

Both were found by the testbench and are the kind of thing that separates RTL
that simulates from RTL that works.

**Held output valid duplicated pixels.** The core's `m_valid` was asserted
whenever S3 held an output. But the pipeline can stall for a reason that has
nothing to do with the consumer — S0 waiting on an input pixel — and during that
stall the downstream FIFO happily latched the same pixel again on every cycle.
The symptom was a duplicated pixel followed by a one-pixel shift for the rest of
the frame. Both `s_ready` and `m_valid` are now single-cycle strobes qualified
by the pipeline enable.

**`ap_done` lost to a simultaneous clear-on-read.** `ap_done` is set by the
write engine and cleared when the master reads `CTRL`. A polling driver reads
`CTRL` continuously, so eventually a read handshake lands in the same cycle as
the done pulse — and with the clear taking priority the completion vanished and
the driver polled forever. The set now wins; that read returns 0 and the next
one returns 1. This only appeared once the testbench polled over AXI4-Lite the
way PYNQ does, rather than waiting on the internal signal.

## Testbench notes (xsim)

Several constructs took the xsim kernel down rather than erroring cleanly, all
of them in the testbench rather than the design. Worth knowing if you extend it:

- `$sformatf` nested in a ternary inside a `$display` argument list
- an `output` argument on an automatic task, called in a tight loop
- variable declarations inside a `forever` block
- hierarchical references into the DUT with `-debug off -O2`

The testbench avoids all four, and `sim.sh` elaborates with `-debug typical`.
