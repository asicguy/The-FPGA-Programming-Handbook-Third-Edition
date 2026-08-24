# HLS Image Filter — AUP-ZU3 (Zynq UltraScale+ ZU3EG) + PYNQ

A Vitis HLS accelerator in the programmable logic that reads a packed RGBA image
from DDR, converts it to luma, optionally applies a 3×3 Sobel, and writes the
result back. Driven from a Jupyter notebook via PYNQ.

```
CH11/HLS/
├── src/
│   ├── image_filter.hpp        interface + mode constants
│   ├── image_filter.cpp        the synthesizable kernel
│   └── tb_image_filter.cpp     self-checking testbench (no external files needed)
├── image_filter/               the Vitis HLS component
│   ├── hls_config.cfg          part, clock, source list, packaging options
│   └── vitis-comp.json         component descriptor, for the Vitis IDE
├── build_hls.sh                csim → csynth → cosim → IP package
├── build_bd.tcl                block design → bitstream → .bit/.hwh
├── hil_test.py                 on-board self-check vs the golden model
├── dp_display.py               output to a DisplayPort monitor (no GPU involved)
└── zu3_image_filter.ipynb      software → HLS → RTL, benchmarked side by side
```

Everything is driven from this directory — there are no `cd` steps between stages.

---

## First, about the Mali

Your request asked for HLS targeting the ARM Mali core. Those two things can't be
joined, and it's worth being clear about why before you spend build time on it.

**The ZU3EG really does have a Mali.** EG-series Zynq UltraScale+ parts include a
Mali-400 MP2 in the processing system (CG parts omit it; EV parts add a video
codec). So the hardware is there.

**But HLS cannot target it.** Vitis HLS compiles C/C++ into RTL, which gets placed
and routed into the FPGA fabric. The Mali is a hardened, fixed-function block
inside the PS. There is no compilation path from HLS to the Mali, and no way to
express Mali work in an HLS kernel.

**And the Mali-400 can't do image processing anyway.** It implements OpenGL ES
1.1/2.0 and OpenVG 1.1. It predates compute shaders and has no OpenCL support —
that arrived with the Mali-T (Midgard) series. It's a fixed-function-ish graphics
rasterizer for drawing triangles, not a GPGPU device. It also has no hardware JPEG
decoder.

**And Jupyter wouldn't show you GPU output regardless.** When a notebook displays
an image, the board encodes it as PNG and ships it over HTTP to your browser,
which draws it. The board's GPU and DisplayPort output are nowhere in that path.
Even a working Mali render would have to be read back into system memory and
re-encoded before Jupyter could show it.

**DisplayPort is not the Mali either.** This is the most common form of the
confusion, so it is worth separating carefully. The ZynqMP DisplayPort
controller — DPDMA plus the DP subsystem — is its own hardened block. It scans
out a framebuffer from DDR and drives the connector, and it does not care which
agent produced those pixels. The Mali is a *renderer*: one possible producer,
writing into DDR like anything else. Wanting output on a monitor therefore says
nothing about wanting the GPU. Here the producer is the PL accelerator:

```
JPEG → A53 decode → DDR → [PL: gray / sobel / invert] → DDR → DPDMA → DisplayPort
```

That path is implemented in `dp_display.py` and runs on a real monitor — see
**Displaying on a monitor** below. No GPU anywhere in it.

Four plausible things you might actually want:

| Goal | Path |
|---|---|
| Accelerate image processing in hardware, view in Jupyter | **This project.** HLS IP in the PL. |
| Accelerate in hardware, view on a physical monitor | **`dp_display.py`.** PL → DDR → PS DisplayPort via DRM/KMS. Works on a stock PYNQ image, no GPU. |
| Use the Mali for graphics | OpenGL ES 2.0 → DRM/KMS on the PS DisplayPort, physical monitor. Needs the Mali kernel driver plus ARM's proprietary userspace blobs enabled in PetaLinux (license acceptance required); stock PYNQ images ship without them. No Jupyter involved. |
| Just decode and show a JPEG | `PIL.Image.open()` in a notebook. Runs on the A53s. Three lines, no FPGA. |

If this is a course assignment whose brief mentions the Mali, it's worth checking
with your instructor — the brief may mean "the ARM processor" loosely, in which
case this project is the right shape.

---

## Kernel design

Three `#pragma HLS DATAFLOW` stages connected by FIFOs:

1. **`read_and_gray`** — bursts 32-bit RGBA words from DDR over `m_axi gmem0`,
   computes BT.601 luma in Q8 fixed point (`77R + 150G + 29B >> 8`), II=1.
2. **`window_filter`** — 3×3 sliding window over two `MAX_WIDTH`-deep BRAM line
   buffers, II=1. Iteration space is `(H+1) × (W+1)`: a pixel is consumed when
   `r < H && c < W`, produced when `r ≥ 1 && c ≥ 1`. Both counts come to exactly
   `W×H`, which is what keeps the dataflow FIFOs from deadlocking. Window centre
   `win[1][1]` at step `(r,c)` holds input pixel `(r-1, c-1)`.
3. **`write_rgba`** — replicates luma across R/G/B, opaque alpha, bursts out over
   `m_axi gmem1`, II=1.

Two separate `m_axi` bundles so reads and writes go to different HP ports and
don't contend. At II=1 and 200 MHz that's ~200 Mpixel/s in steady state, so a
1080p frame is roughly 10 ms plus DDR latency.

Modes: `0` grayscale, `1` Sobel magnitude (`|Gx| + |Gy|`, clamped, zero border),
`2` inverted grayscale.

The sliding-window logic was verified against a direct reference implementation
across several odd image sizes — exact match, and read/write counts balance.

---

## Build

Source the Vitis settings once, then run everything from `CH11/HLS`:

```bash
source /opt/Xilinx/2025.2/Vitis/settings64.sh
```

### 1. HLS

```bash
./build_hls.sh            # csim + synth + package
./build_hls.sh --cosim    # ...and RTL/C co-simulation (slow)
```

Runs csim against the golden model, synthesizes, and packages the IP into
`image_filter/hls/impl/ip`. Expect `TEST PASSED` from csim and an estimated Fmax
comfortably above 200 MHz.

**There is no `vitis_hls` executable.** From 2024.2 onward the standalone HLS
tool was folded into Vitis, and the old `open_project` / `open_solution` /
`set_part` Tcl script no longer has an interpreter to run in. The component is
described declaratively by `image_filter/hls_config.cfg` instead, and each
former Tcl command maps to one CLI invocation:

| `vitis_hls` Tcl | Unified Vitis |
|---|---|
| `csim_design` | `vitis-run --mode hls --csim --config image_filter/hls_config.cfg --work_dir image_filter` |
| `csynth_design` | `v++ -c --mode hls --config image_filter/hls_config.cfg --work_dir image_filter` |
| `cosim_design` | `vitis-run --mode hls --cosim --config image_filter/hls_config.cfg --work_dir image_filter` |
| `export_design` | `vitis-run --mode hls --package --config image_filter/hls_config.cfg --work_dir image_filter` |
| `set_part` / `create_clock` / `add_files` | keys in `hls_config.cfg` |

`build_hls.sh` is just those four commands in order. To work interactively
instead, open this directory as a Vitis workspace — `vitis -w .` — and the IDE
picks up `image_filter/` as an HLS component via `vitis-comp.json`.

**Check the part number first.** `hls_config.cfg` and `build_bd.tcl` both default
to `xczu3eg-sfvc784-2-e`, and they must agree. ZU3EG ships in several packages,
so confirm yours from the board documentation or the chip silkscreen.

### 2. Vivado

```bash
vivado -mode batch -source build_bd.tcl
```

`hls_ip_repo` and `board_repo` are both derived from the script's own location
and need no editing. The two you may need to touch:

- `board_part` — defaults to `realdigital.org:aup-zu3-8gb:part0:1.0`. **Change
  this to `aup-zu3-4gb` if yours is the 4GB board.** The preset configures the PS
  DDR controller; the wrong one produces an image that fails to boot or corrupts
  silently. Setting `board_part` to `{}` skips the preset entirely, which is worse
  — the PS is then left at defaults that match no real board.
- `part_name` — `xczu3eg-sfvc784-2-e`, and it must agree with `hls_config.cfg`.

The board files are not installed into Vivado; `build_bd.tcl` points
`board_part_repo_paths` at `../../../aup-zu3-board-files` (a sibling checkout of
this book's repo). If yours lives elsewhere, edit `board_repo`. Once the path is
set, `get_board_parts *zu3*` in the Vivado Tcl console lists what is visible.

The script builds: PS → SmartConnect → HLS IP, with `M_AXI_HPM0_LPD` driving the
AXI-Lite control port and the two masters landing on `S_AXI_HP0_FPD` and
`S_AXI_HP1_FPD` at 128 bits. PL clock 0 at 200 MHz to match the 5 ns HLS target.

With the 8GB preset applied, `assign_bd_address` maps both `DDR_LOW` (2 GB at 0)
and `DDR_HIGH` into the accelerator's two master address spaces, so buffers
anywhere in physical memory are reachable. Without a preset only `DDR_LOW` exists
and anything PYNQ allocates above 2 GB would be invisible to the PL.

Takes about five minutes on a 24-core machine. Outputs land in `out/`:
- `image_filter.bit`
- `image_filter.hwh`

Verified results on Vivado 2025.2 with the 8GB preset — timing closes with room
to spare and the part is barely touched, so there is plenty of headroom for the
extensions below:

| | |
|---|---|
| WNS / WHS | +1.611 ns / +0.003 ns — all constraints met at 200 MHz |
| Routing | fully routed, 0 nets with errors, 0 routed-DRC violations |
| CLB LUTs | 4020 (5.70%) |
| CLB registers | 5231 (3.71%) |
| Block RAM | 5.5 tiles (2.55%) |
| DSPs | 13 (3.61%) |

PYNQ requires both, **same basename, same directory** — it parses the `.hwh` to
discover the IP and its register map.

### 3. Board — hardware-in-the-loop check

`hil_test.py` is a self-checking run that needs no JPEG: it builds the same
synthetic image the C testbench uses and compares the accelerator's output
against the identical golden model, so a pass means the hardware agrees with
csim bit for bit.

```bash
scp out/image_filter.bit out/image_filter.hwh hil_test.py xilinx@<board>:~/ch11_hil/
ssh -t xilinx@<board> 'cd ~/ch11_hil && sudo env XILINX_XRT=/usr \
    /usr/local/share/pynq-venv/bin/python3 hil_test.py'
```

**Two things that bite when running headless rather than from Jupyter:**

- **`RuntimeError: No Devices Found`** (with a "is the XRT environment sourced?"
  warning). PYNQ reads `XILINX_XRT`, which `/etc/profile.d/xrt_setup.sh` sets to
  `/usr` — and profile scripts do not run for a non-interactive `ssh cmd`. Pass
  `env XILINX_XRT=/usr` explicitly, as above. Nothing is wrong with the overlay.
- **Root is required.** Loading a bitstream needs the PL device; as the `xilinx`
  user you get the same `No Devices Found`. Jupyter hides this because it already
  runs as root.

Measured on an AUP-ZU3 8GB (PynqLinux 22.04, kernel 6.6.10, PL at 200 MHz):

| Image | Time | Throughput |
|---|---|---|
| 640×480 | 1.71 ms | 179 Mpixel/s |
| 1920×1080 | 11.23 ms | 185 Mpixel/s |

That is ~90% of the theoretical 200 Mpixel/s for II=1 at 200 MHz, the shortfall
being DDR latency and the round trip through the PS. Sobel on 640×480 came out
**28.9× faster than the NumPy equivalent on the A53s** (49.5 ms).

All three modes are bit-exact against the golden model, verified at 1920×1080,
1920×1, 637×479, 64×48, 3×3 and 1×1 — the degenerate sizes matter because the
window stage's `(H+1)×(W+1)` iteration space is where a deadlock would show up.

### 4. Displaying on a monitor

`dp_display.py` puts the accelerator's output on a DisplayPort monitor, full
1920×1080, cycling the three modes with an on-screen label.

```bash
sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 dp_display.py 30
sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 dp_display.py --hold
```

It uses `pynq.lib.video.DisplayPort`, which drives the `zynqmp-display` DRM
device (`/dev/dri/card0`). Check the monitor is seen first:

```bash
cat /sys/class/drm/card0-DP-1/status      # -> connected
cat /sys/class/drm/card0-DP-1/modes       # -> 1920x1080, ...
```

Measured at 1920×1080 on a connected monitor:

| Stage | Time |
|---|---|
| PL filter (full frame) | 11.23 ms |
| RGBA→RGB copy + page flip | 8–17 ms |
| End to end | 36–52 fps |

The accelerator alone is good for ~89 fps; the rest is the CPU-side copy and
waiting for vsync, so the pipeline is display-limited rather than compute-limited.

Two details that shape the code:

- **The mode must come from `dp.modes`.** `configure()` rejects anything not in
  the driver-enumerated list, and those entries are all `bpp=24` — so the output
  is `PIXEL_RGB`, not `PIXEL_RGBA`, and the kernel's alpha byte gets dropped on
  the way to the framebuffer.
- **No zero-copy into the framebuffer.** The PL writes a CMA buffer from
  `allocate()`, and the A53s copy from there into the DRM frame. The reason is
  format, not addressing: the kernel emits packed 32-bit RGBA and the display
  mode is RGB24, so every pixel has to be narrowed on the way through. A copy is
  unavoidable while those two disagree.

  Do **not** read anything into the address `newframe()` reports. Both
  `physical_address` and `device_address` come back around `0x1_01B0_0000` —
  above 4 GiB, in neither of this board's two DDR windows (`0x0`–`0x7FEF_FFFF`
  and `0x8_0000_0000`–`0x9_7FFF_FFFF`, per `/proc/iomem`). That is a DRM fake
  mmap offset for the GEM object, not a bus address. The buffer itself is
  ordinary CMA and is perfectly reachable by the accelerator's masters; making
  the PL render straight into it would be a matter of matching the pixel format
  and getting the real physical address, not of the memory being out of range.

Nothing here involves the Mali; see the note at the top of this README.

### Letting the PL write the framebuffer directly

The CPU copy is the whole reason end-to-end sits at ~40 fps when the
accelerator alone manages ~89. It can be removed: the scanout buffer is
ordinary DDR that the accelerator's masters already map.

The framebuffer's true physical address is not exposed through DRM or sysfs,
but the DPDMA hardware knows it. Channel 3 is the graphics layer; its current
descriptor pointer lives at `0xFD4C_0000 + 0x50C`, and the descriptor decodes as:

| Field | Value | Meaning |
|---|---|---|
| `xfer_size` | 6220800 | 1920 × 1080 × 3 |
| `line_size` | 5760 | 1920 × 3 |
| `stride` | **5888** | 128 bytes of padding per row |
| `SRC_ADDR` | **0x7950_0000** | the framebuffer, in DDR_LOW |
| `next_desc` | itself | self-linked: one buffer, scanned continuously |

`CH11/HLS/dscr_probe.py` on the board prints all of this.

`0x7950_0000` sits in DDR_LOW, which `m_axi_gmem1` already maps, so the PL can
reach it today — no block-design change. What has to change is the kernel:

1. **Emit RG24, not RGBA.** Pack four pixels into three 32-bit words instead of
   writing one word per pixel.
2. **Honour the 5888-byte stride.** Skip 128 bytes at the end of each row; add a
   stride argument rather than assuming `width * 3`.
3. **Point `dst` at `0x7950_0000`** instead of a CMA buffer, and stop calling
   `writeframe()` — the descriptor is self-linked, so the display re-reads that
   buffer forever with no software involvement at all.

Two caveats. The descriptor is single-buffered, so the PL would be writing the
surface while DPDMA scans it — expect tearing. Double-buffering means allocating
a second frame, alternating `dst` between the two and page-flipping, which keeps
the flip ioctl but still copies zero bytes. And the address belongs to DRM: a
mode change or another client can move it, so re-read the descriptor rather than
hard-coding what you saw once.

Done properly this should take end-to-end from ~40 fps to roughly the
accelerator's own ~89 fps, with the CPU doing nothing per frame.

### 5. Notebook

`zu3_image_filter.ipynb` runs the same Sobel three times, in this order:

1. **Software on the PS** — a pure-Python transcription of the algorithm, then
   the vectorised NumPy version, then OpenCV for scale. The software comes
   first because it is the specification: both hardware versions are checked
   bit-for-bit against its output, and its runtime is the only honest
   denominator for a speed-up figure.
2. **HLS in the PL** — `image_filter.bit` from this directory.
3. **Hand-written RTL in the PL** — `../out_sv/image_filter.bit`. Set
   `HDL_IMPL = "vhdl"` in section 0 to run the VHDL build instead; the register
   map is identical, so the same driver class works unchanged.

Timings from every stage are accumulated in `RESULTS` and printed as a table
plus a log-scale bar chart in section 6.

Copy to the board (PYNQ image, or PetaLinux with the PYNQ packages installed).
`deploy.sh` already lays this out — the notebook searches the local build
directories first, then `/home/xilinx/ch11_hil/{hls,sv,vhdl}/`:

```
hls/image_filter.{bit,hwh}
sv/image_filter.{bit,hwh}          # or vhdl/
zu3_image_filter.ipynb
test.jpg          # any JPEG, width ≤ MAX_WIDTH
```

#### The DisplayPort service, and what to do if you don't have it

The notebook needs the PL to itself. `ch11-dp` — the optional DisplayPort demo
installed by `deploy/deploy.sh` — drives this same IP on a timer and reprograms
the fabric, so leaving it running corrupts the measurements *and* breaks its own
display. Measured with it running, individual reps stalled for ~3.4 s against a
true 16.5 ms.

Section 0 works out which of three situations you are in and prints it. Only one
needs action:

| What section 0 prints | What it means | What to do |
|---|---|---|
| `ch11-dp is not installed - the PL is yours` | You never deployed the demo. **This is the normal state for a new user.** | Nothing. Carry on. |
| `installed but inactive - that is the state you want` | You have it, and it is stopped. | Nothing. If it is also `enabled`, it returns after a reboot. |
| `*** WARNING: ch11-dp is RUNNING ***` | It is driving the PL right now. | Stop it, re-run from the top. |

```bash
sudo systemctl stop  ch11-dp       # before benchmarking
sudo systemctl start ch11-dp       # afterwards, to get the monitor back
```

**If you are a new user and have never run `deploy.sh`, none of this applies to
you** — there is no service to stop, section 0 will say so, and the notebook
runs exactly as documented. The demo is a separate thing that needs a monitor on
the DisplayPort connector; it is not a prerequisite for anything here.

One trap if you write your own check: `systemctl is-active ch11-dp` prints
`inactive` for a unit that was *never installed*, indistinguishable from one you
stopped yourself. The notebook tests `systemctl list-unit-files ch11-dp.service`
first for that reason.

Going the other way — you want the demo and it won't start — the usual cause is
no monitor attached. `dp_display.py` checks the connector up front and exits with
`no monitor: /sys/class/drm/card0-DP-1/status reads 'disconnected'`; confirm with
`cat /sys/class/drm/card0-DP-1/status`. See `deploy/README.md` for the rest.

Verified end to end on a 1500×2000 (3.0 Mpixel) JPEG, board otherwise idle.
Every hardware row is `0 of 3000000` pixels differing against the NumPy
reference, and the SV RTL is also bit-identical to the HLS build:

| where | stage | best | Mpixel/s | vs NumPy |
|---|---|---|---|---|
| PS, pure Python | sobel (extrapolated from a 256×192 crop) | 33.50 s | 0.09 | 65.7× slower |
| PS, NumPy | sobel | 510.08 ms | 5.88 | baseline |
| PS, OpenCV (4 threads, *approximate*) | sobel | 92.86 ms | 32.31 | 5.5× |
| PL, HLS | sobel, compute only | **16.38 ms** | 183.12 | **31.1×** |
| PL, HLS | sobel, + cache flush/invalidate | 16.52 ms | 181.59 | 30.9× |
| PL, HLS | sobel, + two 11 MiB memcpys | 110.34 ms | 27.19 | 4.6× |
| PL, SV RTL | sobel, compute only | 16.57 ms | 181.04 | 30.8× |
| PL, SV RTL | sobel, + cache flush/invalidate | 16.72 ms | 179.46 | 30.5× |

Best-of-5 after a warm-up; the median matched the best to within 0.1% on every
row, so these are stable numbers rather than lucky ones.

Three things worth taking from that table. HLS and hand-written RTL land within
1% of each other, which is inside the noise for a kernel this regular. Cache
maintenance costs ~0.9%, because the 11 MiB buffers barely fit the 1 MiB L2 and
the source is not re-dirtied between runs. And the two memcpys into and out of
CMA add 93.8 ms — **5.7× the filtering itself** — so the accelerator is not
remotely the bottleneck in a pipeline that hands it ordinary NumPy arrays.

To run it headlessly, note the `XILINX_XRT` and root caveats above:

```bash
sudo env XILINX_XRT=/usr MPLBACKEND=Agg /usr/local/share/pynq-venv/bin/python3 \
    -m jupyter nbconvert --to notebook --execute zu3_image_filter.ipynb
```

---

## Things that commonly go wrong

**`RecursionError` from `print(filt.register_map)`.** Not a corrupt `.hwh` — a
name collision, and the reason the kernel's arguments are `img_width`/`img_height`
rather than the obvious `width`/`height`.

HLS gives each scalar argument an `s_axilite` register whose one field carries the
argument's name. PYNQ builds `register_map` by generating a Python property per
field on its `Register` class. But `Register.__init__` does `self.width = width`,
so a field named `width` has already replaced that attribute with a property —
the assignment calls the setter, `__setitem__` reads `self.width` to size the
access, that re-enters the getter, and it recurses until the interpreter stops it:

```
RecursionError: maximum recursion depth exceeded
  ... in Register.__getitem__ -> _calc_index(index, self.width)
```

It fires the first time you touch `register_map`, long before the accelerator
runs, which makes it look like a bitstream problem. The reserved field names are
the four public attributes `Register.__init__` sets: **`address`, `width`,
`debug`, `access`.** Don't use any of them as a top-level argument name.

**Cosim dies with SIGSEGV in `ENTER_WRAPC`.** Not a bug in the kernel — the RTL
never even starts. The message names the cause in its own list, third item:

```
INFO: [COSIM 212-302] Starting C TB testing ...
ERROR: System received a signal named SIGSEGV and the program has to stop immediately!
  ...
  3) Excessive depth setting for array argument(s) ...
Current execution stopped during CodeState = ENTER_WRAPC.
```

`depth` on an `m_axi` port is a *verification* hint and has no effect on the
generated RTL — the hardware computes addresses at runtime from `img_width` and
`img_height`. What it does control is how many elements the cosim wrapper copies
out of each pointer argument before simulation begins. Set it to a full-HD frame
(`depth=2073600`) while the testbench allocates a 64×48 one (3072 elements), and
the wrapper reads 8.3 MB out of a 12 KB `std::vector` — a 675× overrun, straight
into a segfault.

So `depth` must match what the testbench actually allocates, not what the
hardware can process. `TB_W`, `TB_H` and `COSIM_DEPTH` therefore all live in
`image_filter.hpp`, where both the pragmas and the testbench can see them, and
`tb_image_filter.cpp` carries a `static_assert` so they cannot silently drift
apart again. Verified with Vitis 2025.2: `C/RTL co-simulation finished: PASS`,
`0/3072 pixels wrong` in all three modes.

This is also why csim passes while cosim fails — csim calls the function
directly and never builds a wrapc buffer, so nothing reads out of bounds.

**Register names don't match.** Cell 1 prints `filt.register_map` — that's the
ground truth. HLS names 64-bit pointer arguments as split 32-bit pairs, usually
`src_1`/`src_2`, but the suffix convention varies by tool version. Adjust
`run_filter()` to match what printed. Exact offsets are also in
`image_filter/hls/impl/ip/drivers/*/src/ximage_filter_hw.h`. As built by Vitis
2025.2: `src` 0x10/0x14, `dst` 0x1c/0x20, `img_width` 0x28, `img_height` 0x30,
`mode` 0x38 — which PYNQ surfaces as `src_1`/`src_2`, `dst_1`/`dst_2`,
`img_width`, `img_height`, `mode`, exactly what the notebook uses.

**Reading a register returns the string `'write-only'`.** Expected. PYNQ returns
the access mode instead of a value for write-only registers, and HLS marks scalar
inputs write-only. Write them and move on; don't read them back to verify.

**Output is garbage or stale.** Cache coherence. `src_buf.flush()` before starting
and `dst_buf.invalidate()` after finishing are both mandatory — the HP ports are
non-coherent, so the PL doesn't see dirty A53 cache lines and the A53s don't see
PL writes without an explicit invalidate. Both are already in the notebook; if you
restructure it, keep them.

**`AP_DONE` never asserts.** Usually a dataflow FIFO deadlock from mismatched
read/write counts, or `width` exceeding `MAX_WIDTH` so the line buffers overrun.
Check `img_width ≤ 1920` and that `img_width`/`img_height` were actually written
before `AP_START`.

**Wrong colours.** The kernel assumes byte order R,G,B,A from the LSB up, which is
what NumPy gives for a `uint8 (H,W,4)` array on little-endian ARM. If you feed it
BGRA, red and blue swap.

**Timing failure at 200 MHz.** Shouldn't happen as shipped — the design closes at
+1.611 ns WNS — but if you widen the datapath or add a heavier kernel you may
lose that margin. Drop PL0 to 150 MHz in `build_bd.tcl` and set `clock=6.67ns` in
`image_filter/hls_config.cfg` to match, then rebuild both. They must agree; HLS
constrains the IP and Vivado constrains the clock feeding it.

---

## Extending it

- **Wider datapath.** Change the pointer type to `ap_uint<128>` and process four
  pixels per beat — roughly 4× throughput, at the cost of handling widths that
  aren't a multiple of four.
- **Colour output.** Carry R/G/B through as three parallel streams instead of
  collapsing to luma early; costs 3× the line-buffer BRAM.
- **Other kernels.** The window stage is a drop-in point for Gaussian blur,
  median, sharpen, dilate/erode — anything expressible as a 3×3 stencil.
- **Free-running mode.** Swap `ap_ctrl_hs` for `ap_ctrl_chain` to pipeline
  successive frames without a round trip through the PS.
