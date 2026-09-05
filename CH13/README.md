# CH13 — one socket, many accelerators, no reboot

CH12 ships nine bitstreams across four projects, and moving between them
requires a **reboot of the board**. The reason is not the bitstream. Removing a
device-tree overlay leaks its `__symbols__` entries, so a later overlay
declaring the same `axi_iic` node is rejected with `EINVAL`, and every CH12
camera overlay declares that node.

Dynamic Function eXchange removes the cause rather than the symptom. One
overlay is applied at boot and never removed; only a **partial** bitstream
changes, and partial reconfiguration applies no device tree at all.

But swapping three implementations of the same filter would be a trick rather
than a demonstration. What DFX is for is changing what the hardware *does*, so
this chapter builds **one accelerator socket and four interchangeable
functions**, chosen at run time.

```
static:  PS | camera hierarchy | VDMA | interconnect | status GPIO
         | AXI shutdown managers | the socket's shell
   RP:   one accelerator, swapped at run time
   RMs:  passthrough | sobel | blur | threshold
```

The camera stays static because its MIPI lanes and I²C are physical pins. That
is a constraint worth stating early: DFX swaps *logic*, and anything bonded to a
pin cannot move.

> **This chapter contains two independent projects.** Everything from here
> through *Still open* is the DFX socket. The second — **The SYSMON**, at the
> end of this file — reads the board's potentiometer and on-chip temperature and
> supply sensors, and shares nothing with the socket but the directory.

## What it does

| | |
|---|---|
| Swap time | **~101 ms**, of which ~88 ms is the PCAP transfer |
| Full bitstream | 5438 KB |
| Partial, each RM | 960 KB |
| Timing | WNS **+0.146 ns** worst of four configurations, 0 failing endpoints |
| `pr_verify` | passes for every configuration against the static |
| Bit-exactness | every mode of every kernel, 0 differing samples, on live 720p camera frames |
| On the panel | camera → socket → 1920×1080, 43–44 frames per 4 s window through each kernel |

## The socket contract

Fixed before any RM existed, exactly as CH12 fixed its register map first.

```
ap_clk, ap_rst_n
s_axi_control   AXI4-Lite, 6-bit    CTRL/GIER/IER/ISR, src, dst,
m_axi_gmem0     AXI4 read,  32-bit   img_width, img_height, mode, kernel_id
m_axi_gmem1     AXI4 write, 32-bit
interrupt
heartbeat       a free-running toggle to the static region
```

The first eleven registers are byte-for-byte what Vitis HLS generates for an
`ap_ctrl_hs` kernel, so CH11's and CH12's drivers drive this socket unchanged.
Two additions carry the chapter:

**`kernel_id` at 0x3C, read-only.** With DFX you must be able to ask the
hardware what is in the socket. Inferring it from what you *think* you loaded is
how a swap that silently did not happen goes unnoticed for an afternoon.

**`heartbeat`**, which is not a register at all — see below.

### What `mode` means depends on the kernel

This is the chapter's argument in one register. The map does not change across a
swap, but the meaning does:

| kernel | `mode` |
|---|---|
| sobel | a menu: 0 gray, 1 sobel, 2 invert, 3 colour |
| threshold | the **level**, 0–255 |
| blur, passthrough | unused |

You cannot read `mode` correctly without knowing which kernel is loaded, and the
only trustworthy way to know is to ask the hardware. That is what `kernel_id` is
for, and it is why a constant that lives in four places gets a build-time check
(`common/check_ids.py`) rather than a comment asking people to be careful.

## Why the status GPIO is in the static region

**On ZynqMP there is no bus timeout on the PL ports.** A read of a partition
that is held in reset, mid-reconfiguration, or empty does not return an error —
it does not return at all. The CPU stops, with no panic and no console output,
and only a power cycle recovers it. Worse, "held in reset", "being
reconfigured" and "the logic is broken" are indistinguishable from outside.

So software must be able to ask *"is the partition alive?"* without touching the
partition. Static logic always answers; the partition may not. Every access path
in `sw/dfx_socket.py` goes through that check, and the driver **declines**
rather than risking the read.

Liveness is decided by watching the heartbeat **change**, not by reading a
level. A dead partition holds a perfectly stable 0 or 1, and a level test calls
that alive.

The mechanism proved itself on the first hardware run: at boot the partition
came up held in reset with no heartbeat — the safe default falls out of the
GPIO's zero-initialised output register — and the driver refused to read it
until an explicit release made the heartbeat toggle.

## The swap, and why each step exists

```
1. wait for ap_idle              the accelerator must not be mid-frame
2. engage the shutdown managers  and WAIT until all three acknowledge
3. hold the partition in reset
4. download the partial          no dtbo -- this is what avoids the reboot
5. release the partition reset
6. check the heartbeat           is the new RM actually alive?
7. release the managers          only now may traffic reach the socket
8. read kernel_id                and confirm what is really in there
```

Steps 2 and 7 are what the feasibility spike's kernel panic bought.
Reconfiguring underneath live AXI traffic gave

```
Kernel panic - not syncing: Asynchronous SError Interrupt
```

Step 6 is what several wedged boards bought. Any failure after step 2 leaves the
partition **isolated and in reset** — deliberately not releasing the managers,
because letting traffic reach a partition that is not answering is the exact
hang the mechanism exists to prevent.

`dfx_axi_shutdown_manager` is used rather than a plain `dfx_decoupler` on all
three interfaces: it completes outstanding transactions and returns the
responses the interconnect is waiting for, where a decoupler isolates and leaves
them stranded — and a stranded transaction on a PL port is the no-timeout hang.

## Things that cost time to learn

**A Block Design Container is a hierarchy, not an IP.** PYNQ exposes it as a
`DefaultHierarchy`: `ol.socket` has no `read()`/`write()`. The `.hwh` carries no
register definitions for it either — a container does not propagate its inner
IP's register map however carefully the packaging described one. So the socket
is addressed with `MMIO` at the address the build assigned, and the driver works
in raw offsets throughout. That turned out to be necessary rather than tidy.

**`LIST_SYNTH_BD` holds file names.** Given design names it reports that it
cannot remove the container's active source, which reads like a tool bug.

**A DFX container needs its aperture declared.** The static region's address
decode is routed once, so every RM must decode the same range, and Vivado will
not infer that from the RMs. 0xB0000000 is the first valid aperture through
`HPM1_FPD`.

**The socket's address segment is `SEG_rm_inst_Reg`** — named after the instance
*inside* the child design, not after the container. That is the concrete reason
every RM's instance is named `rm_inst`: if the name varied per RM, the address
map would change under a swap.

**`validate_bd_design -assign_dfx_addressing` excludes the socket's DDR
masters**, after they have been explicitly assigned, proposing a misaligned
`0x44A0_0000 [950M]`. They are therefore assigned both before and after it — and
then checked by reading the segment's `OFFSET`. An excluded segment is still
*listed* against the address space; it simply has no address. A check that tests
for presence passes on a design whose accelerator cannot reach memory at all,
which builds cleanly, programs cleanly, and reads zeroes.

**Vivado's auto-created `<bd>_inst_0_impl_1` runs are out-of-context runs, not
DFX children.** A partial implemented in one of those leaves the partition a
black box. Each partial needs a run whose `-parent_run` is the static
implementation.

## The two timing failures, both self-inflicted

The first full implementation met no timing at all: WNS −1.324 ns, 1433 failing
setup endpoints.

**An unsynchronised clock crossing — 1369 of 1369 endpoints.** The status GPIO
sits on the 100 MHz interconnect, and the first version wired `rm_resetn`
straight into the partition, onto a net that fans out to every flip-flop in the
socket. The requirement was **0.336 ns**.

That number is the lesson. The two clocks are *not* asynchronous: they are
integer divisions of the same 1500 MHz PLL, so Vivado times them
**synchronously**, and the logic gets whatever the tightest edge relationship
between a 10 ns clock and a 5.333 ns clock happens to be. No placement effort
closes that. It is the same PLL relationship that made CH12's AP_DONE crossing
so confusing — it looked asynchronous and was constrained as if it were.

The partition now has its own `proc_sys_reset`: software's bit goes to
`aux_reset_in` and comes out synchronous to the partition's clock, asserted
asynchronously and released synchronously. That also fixed a second bug in the
same lines — ANDing with `rst_accel` meant holding the partition in reset could
reset the shutdown managers isolating it, which are the only thing keeping the
rest of the system safe while the partition is gone.

**A fifteen-level path inside the socket, −0.375 ns.** `total_words` was a
combinational product of the argument registers, and the chain ran `img_height`
→ DSP multiply → the read engine's burst arithmetic → the input FIFO's empty
flag → the core's pipeline enable → its counters. Registering the product breaks
it at the source for one cycle of latency nothing can observe.

## What a swap costs, honestly

A swap is **not invisible**. At ~101 ms it is roughly six frames at 60 fps: the
pipeline stalls and resumes with different hardware in the socket. That is a
great deal better than a reboot and should be presented as that, not as
seamlessness.

Two things about that number are worth separating.

**The partial's size is set by the partition, not by its contents.** All four
partials are exactly 960 KB, because a partial covers the whole reconfigurable
region. The region is a whole clock region — `RESET_AFTER_RECONFIG` requires
clock-region alignment — and holds about 9600 LUTs against the largest RM's
1831. A partition fitted to the accelerator would swap proportionally faster.

**A third of the first measurement was the driver's own liveness check.**
Detecting a heartbeat *change* cannot be faster than half its period, and
`HB_BITS` at 24 makes that 44.7 ms. The divider had been chosen for "slow enough
that software can poll it" without costing what it would do to the thing the
socket exists to do. A status signal's rate is not a free parameter: it sets the
floor on how fast anything waiting for it can be, and that floor is invisible
until something is measured against it.

Measured, that is exactly what it was. At `HB_BITS` 24 the liveness check took
**45.5 ms on every one of five swaps** -- not approximately, identically, which
is the signature of a wait on a fixed divider rather than of work. At 20 it is
3.3 ms, and the swap went from 138 ms to 101 ms.

The fix took two attempts, and the first one is the more useful lesson.
`socket_ctrl` carried the intended default, `rm_shell` declared its own
`HB_BITS = 24` and passed it down, and no RM top overrode either. Changing the
leaf changed nothing: the build kept the shell's value, the design still
compiled, simulation still passed, and the hardware still spent 45.5 ms a swap.
Two defaults for one constant is the defect; the second one is only where it
surfaced. `rm_shell` no longer declares or forwards `HB_BITS` at all, so
`socket_ctrl` is the single definition, and `tb_rm.sv`'s `check_heartbeat_rate`
asserts the value that *arrives* -- the previous check only asked whether the
heartbeat was driven at all, which is why a 24-against-20 mismatch passed
simulation four times over.

## Resource cost of each RM

Out of context at 5.000 ns, which is what sized the partition:

| RM | WNS | LUTs | FFs | BRAM | DSP |
|---|---|---|---|---|---|
| passthrough | +0.321 | 1542 | 749 | 0 | 3 |
| sobel | +0.300 | 1831 | 947 | 1 | 3 |
| blur | +0.315 | 1548 | 940 | 3 | 3 |
| threshold | +0.310 | 1240 | 709 | 0 | 3 |

The blur's 3 BRAM against the sobel's 1 is the whole architectural difference
between them: a blur needs a neighbour's **colour** where a Sobel needs only its
brightness, so its line buffers carry three bytes a pixel instead of one.

## Verification

`SystemVerilog/sim.sh --all` is the gate before anything reaches a build:

```
######## kernel ids     4 ids agree across 4 sources
######## RM passthrough TEST PASSED   7 cases
######## RM sobel       TEST PASSED  14 cases
######## RM blur        TEST PASSED  11 cases
######## RM threshold   TEST PASSED  10 cases
######## socket         PASS         338 checks
######## socket, negative control (must fail)   correctly failed
```

That last line is the one to keep honest. Three of the spike's four board wedges
were AXI slaves or drivers with no testbench behind them, and one of them — a
slave that completed a write only when AW and W arrived in the same cycle — hung
the PS forever, because the PS routinely sends the address ahead of the data.
`tb/socket_ctrl_broken.sv` is that bug, kept deliberately, so the testbench can
be *shown* to catch it. A gate whose negative control has quietly started
passing proves nothing and will not announce itself.

Odd and degenerate frame sizes (1x1, 2x2, 3x3, 1x16, 16x1) are in the RM test
list because the windowed kernels produce on a different condition from the one
they consume on. An off-by-one there does not make a wrong picture — it
unbalances the shell's two FIFOs and deadlocks.

## Building it

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
cd SystemVerilog && ./sim.sh --all          # the gate
cd ..
vivado -mode batch -source common/synth_ooc.tcl              # size the partition
vivado -mode batch -source project_dfx_socket/build_bd.tcl   # static + container
vivado -mode batch -source project_dfx_socket/build_impl.tcl # impl + partials
```

`build_impl.tcl` is resumable: every launch is guarded on `PROGRESS`, so
re-running it continues rather than discarding finished work.

`build_bd.tcl stage1` builds the static design with one fixed RM and no
partition — an ordinary overlay. That is the staged bring-up: prove the socket
answers before enabling reconfiguration.

## Getting it onto the board

The overlay is not built by Vivado and is gitignored, so it is the one step
that is easy to forget:

```bash
make -C project_dfx_socket/dts          # dfx_socket.dtbo
deploy/deploy.sh                        # copy to the board and verify
```

`deploy.sh` takes `--board`, `--user` and `--dest`; it copies files and nothing
else -- it starts no service and does not reprogram the PL. The layout it
writes is not a matter of taste, because the notebook reaches for `../out` and
`../sw` and must run without editing a path:

```
/home/xilinx/ch13_dfx/            11 MB
├── out/         dfx_socket.{bit,hwh,dtbo} + 4 x socket_*_partial.bit
├── sw/          dfx_socket.py rm_ref.py test_*.py
│                + ov5647.py ov5647_regs.py pixel_packer.py from CH12
└── notebooks/   ch13_dfx_socket.ipynb
```

The `.dtbo` sits in `out/` beside the bitstream because PYNQ pairs an overlay
to a bitstream by filename, and the partials sit there because `swap_to()`
globs `*partial*.bit` out of the same directory. CH12's camera driver travels
along because the camera is in the static region -- that is the whole reason it
survives a swap.

Every file is checksummed after the copy. The board has no RTC, so timestamps
prove nothing; md5 is the only honest check.

The script finishes by naming the two things that ruin a run *silently* rather
than loudly -- `ch11-dp` running, and anything holding DRM master on
`/dev/dri/card0`. It only reports them. Stopping a service or killing an X
session is the operator's call.

The software tests run on the board, not the host:

```bash
ssh xilinx@192.168.3.1 'cd /home/xilinx/ch13_dfx/sw && python3 -m pytest -q'
53 passed
```

`deploy/test_deploy.sh` covers `deploy.sh` itself, with `ssh` and `scp` stubbed
and a directory standing in for the board, so it needs no hardware.

## Still open

**One board hang is unexplained.** During an earlier attempt at the heartbeat
re-measurement the board went down before any swap completed, and there was no
serial console running, so there is no diagnosis. It has not recurred: the
`HB_BITS=24` design was later run again to completion with the console captured,
and the `HB_BITS=20` design after it, both clean and both silent on the console.
An unreproduced hang with no evidence is recorded as exactly that, not explained
away.

**`alive()`'s default sampling window is coupled to `HB_BITS` and does not say
so.** It samples 32 times at 1 ms; against the 24-bit divider's 44.7 ms half
period a standalone call was a coin flip, and returned `True` then `False` on
consecutive calls. It is fail-safe -- a false negative refuses to read, and a
false positive cannot happen, because a change is a change -- and `swap()` wraps
it in a 1 s retry, which is why every swap succeeded regardless. At 20 bits it is
correct as documented. Making it wait on a *timeout* rather than a sample count
would remove the coupling.

**Where the last few milliseconds of a swap go is not fully accounted for.** In
the `HB_BITS=24` runs the final step was erratic -- 6.7, 9.7, 11.1, 183 and
344 ms for what is a single register read. Instrumenting every MMIO access in
the 20-bit run showed no read over 0.05 ms, and a steady-state loop measures
9 us median over 2000 samples, so the register path is exonerated; the residual
8-10 ms is measurement tail. The two large outliers did not recur and remain
unexplained.

**Anything holding DRM master makes the DisplayPort output silently do
nothing.** `writeframe()` returns promptly and displays nothing, which is
indistinguishable from working unless someone is watching the panel. Stopping
`pynq-x11.service` is *not* sufficient: an X session also comes up from
`/root/.xinitrc` in a root login that the unit does not own, and it keeps DRM
master. `fuser -v /dev/dri/card0` is the check that catches it. `ch11-dp.service`
is a separate hazard — it drives CH11's own bitstream, so reprogramming the PL
under it points its register reads at hardware that no longer exists.

---

# The SYSMON — a potentiometer, a die temperature, and six supply rails

The second project in this chapter, and independent of the first: it shares the
directory and nothing else.

The AUP-ZU3 wires a 10K potentiometer to **VP (R13)** and **VN (T12)**, the
dedicated analog input pins of the UltraScale+ SYSMON. This reads it, shows it
as a moving bar in a notebook and as an eight-LED thermometer on the board, and
reads the on-chip temperature and supply sensors alongside it.

**On UltraScale+ there is no XADC.** The block is **SYSMONE4** and the IP is the
**System Management Wizard**, not the XADC Wizard. The name matters more than it
sounds like it should, because the two have different register maps — which is
what this project mostly turned out to be about.

## What it does

| | |
|---|---|
| Die temperature | **40.8 °C**, with min/max since power-up latched by the macro |
| Supply rails | six: `vccint` 0.851, `vccaux` 1.803, `vccbram` 0.852, `vccpsintlp` 0.849, `vccpsintfp` 0.849, `vccpsaux` 1.803 V |
| Potentiometer | full travel **0 → 0.8545 V**, 85.4% of the channel's range, no clipping; bar normalised so a full turn fills all 8 LEDs |
| Conversion rate | **5345/s**, 668 complete sequences/s, measured on the macro's own `eoc` pin |
| Timing | WNS **+0.005 ns**, one SYSMONE4 placed |
| Tests | 33 Python, 2 SystemVerilog testbenches, Verilator `-Wall` clean |

Every rail cross-checks independently against the PS sensors that Linux's
`xilinx-ams` driver exposes, which is the only reason to believe the numbers.

## VP and VN take no constraint

They are **dedicated** pins: `PIN_FUNC` `VP`/`VN`, `IS_GENERAL_PURPOSE 0`.
Vivado places them on the only sites they can occupy, and `constraints/pins.xdc`
deliberately says nothing about them. The board's own `base.xdc` constrains
nothing for them either, which is the confirmation that this is intended rather
than an omission. A `PACKAGE_PIN` line for them is not redundant, it is wrong.

**The external channel's range is fixed and not adjustable.** Unipolar VP/VN is
0 to 1.0 V. Whatever divider the board puts on the wiper has to land inside
that; one that exceeded it would clip rather than scale. This board's does not
— measured, the wiper sits at 64% of full scale.

## The register window is at 0x1400, and that cost a day

This is the part worth reading.

Every SYSMON register read `0x0000`. Temperature included — and temperature is
never legitimately zero, because the conversion's own offset puts raw 0 at
−280 °C. Writes to the config registers did not stick: `0x2000`, `0x3000` and
`0xFFFF` all read back as zero. Linux's `xilinx-ams` driver agreed, reporting
`in_temp20_raw = 0` for the PL while the PS sensors read ~43 °C correctly. The
board vendor's own PYNQ base overlay fails in exactly the same way, and its
implemented design really does place the macro (`SYSMONE4 Used=1, Fixed=1`).

It looked conclusively like a SYSMON that was present, placed and dead. It was
diagnosed as exactly that, and the diagnosis was wrong.

**`0x200` is the 7-series XADC Wizard's DRP base.** The System Management
Wizard's AXI window is **13 bits wide — 8 KB, twice the size — and puts the DRP
at `0x1400`** (aliased at `0x1C00`; address bit 11 is ignored). Reads at `0x200`
landed on nothing and came back as zeros, which is indistinguishable from dead
silicon. Map 8 KB too: `MMIO(base, 0x1000)` leaves the registers outside the
mapping entirely.

```
0x1400  temp    0xA14D  40.68 C      0x140C  VP/VN  0xA40B  0.6408 V   <- the pot
0x1404  vccint  0x48AA  0.8515 V     0x1418  vccbram        0.8518 V
0x1408  vccaux  0x9A0F  1.8054 V     0x1500  config0/1/2  0x1000/0x2190/0x1400
```

### What broke the deadlock: count the macro's own pins

The wizard brings `eoc_out`, `eos_out`, `busy_out` and `channel_out` out to the
fabric. Those come off the SYSMONE4 itself and pass through **neither the DRP
register path nor the PS AMS block** — the two paths that were reporting
nothing. So they can answer a question neither of those can: *is the converter
running at all?*

`hdl/sysmon_activity.sv` counts them. It showed **~5400 conversions a second
while every register still read zero**, which made "wrong address" the only
remaining explanation and turned a day of hardware forensics into a one-line
fix.

It **counts** rather than samples, and that is not a detail: `eoc_out` is a
single-cycle pulse at 100 MHz, so software polling a GPIO at a few kHz would
miss essentially every one and report a dead converter whether or not one was
running. Its testbench also pins down that a signal held *high* counts once, not
once per cycle — a stuck-high input reading as a healthy converter is the other
way this diagnostic could lie.

The counter stays in the design rather than being deleted along with the bug it
found. It is the only thing that distinguishes "the SYSMON is dead" from "you
are reading the wrong address", and `sw/scan_window.py` — which sweeps the whole
window for non-zero words and flags anything in a plausible temperature band —
found the real base in seconds once someone thought to look.

**The lesson: when an entire register window reads zero, question the address
before concluding the hardware is dead.** Verify a suspected map against values
known independently. Here `vccint` had to be 0.85 V and `vccaux` 1.80 V, and the
PS sensors had been reporting exactly that the whole time.

### A real finding that explained the wrong symptom

`AMS_PL_CSTS` genuinely does read zero:

```
AMS + 0x040  AMS_PS_CSTS = 0x08010000    PS sysmon accessible
AMS + 0x044  AMS_PL_CSTS = 0x00000000    PL sysmon ACCESS bit clear
```

and the whole PL aperture at `AMS + 0x400` faults uniformly — 0 of 20 offsets
respond, against 20 of 20 for the PS. That is why `xilinx-ams` silently skips
the PL channels: it gates on that very bit. All true, all reproducible, and it
explains **only the AMS route**. It never explained the wizard's own DRP.
Letting one real finding account for a second, unrelated symptom is precisely
how the diagnosis went wrong. Read the PL SYSMON through the wizard's AXI
window; ignore the AMS PL route.

Proving that aperture was gated rather than sparsely decoded needed a
**fork-per-read probe** — a `SIGBUS` kills the process, so a straight sweep
stops at the first bad offset and tells you nothing about the rest. Worth
knowing: `AMS_CTRL` itself faults on undefined offsets too (31 of 64 respond),
so a single `SIGBUS` proves nothing. Only the uniformity across the whole PL
aperture does.

## The pot's actual travel

Swept end to end over 30 s, 2965 samples:

```
minimum   raw 0x0001  code   0  0.0000 V  (  0.0% of full scale)
maximum   raw 0xDAC1  code 875  0.8545 V  ( 85.5% of full scale)
travel    0.8545 V = 85.4% of the channel's 1.0 V range
```

**It reaches 0 V at one stop and 0.8545 V at the other, so it never clips.**
That is the thing worth knowing, because the unipolar range is fixed at 1.0 V
and a divider that overshot it would peg the reading at the ceiling and look
like a pot with a dead zone at the top.

It does not reach full scale, though — the top of travel is 85.4%. Scaled to
the ADC's range the bar would top out at **seven of its eight LEDs**, so
`normalize_pot()` rescales the *display* to the pot's real travel and a full
turn now fills it. Re-swept afterwards: **8 of 8 bar steps reachable**. The
volts reported stay the true measurement; only the bar is rescaled.

`POT_FULL_SCALE_RAW = 0xDAC1` is a **measured, board-specific constant**, not a
datasheet value. Two independent sweeps put the top at `0xDAC1` and `0xDAB9`,
eight counts apart, so it is stable — but on different hardware, re-measure with
`sw/pot_sweep.py` and change it. The rescale is **clamped**: without that, a
reading above the measured maximum scales past 16 bits and wraps, sending the
bar to the *bottom* exactly at the top of the pot's travel.

Parked at one position the reading sat between 0.4665 and 0.4673 V across ten
seconds — about 0.8 mV peak to peak, roughly one LSB at 10 bits. That is the
16-sample hardware averaging doing its job.

## The LED bar, and why software is in the path

`hdl/pot_bar.sv` decodes a 16-bit level into an eight-LED thermometer, 8192
counts per LED, rounded **up** so that one count above zero lights the first LED
and full scale lights all eight. Truncating instead would leave the bar dark
until the pot was well off its stop and never reach eight at the top — both of
which look like a broken pot rather than a rounding choice.

`PotBar.set_reading()` normalises to the pot's measured travel before writing;
`set_level()` writes straight through, for driving exact LED steps.

The value reaches it from **software**, through an output GPIO, and that is
forced rather than chosen. `INTERFACE_SELECTION Enable_AXI` gives the wizard's
bridge ownership of the SYSMONE4's **single** DRP port. There is only one, so
fabric logic cannot also read conversions out of the macro. The alternatives
were to write a DRP master in RTL and give up the AXI register interface, or to
let software read VP/VN and hand the value back. This takes the second: the
decode stays in hardware, only the transport goes through the PS.

## Address map

| | |
|---|---|
| `0x80000000` | System Management Wizard, AXI4-Lite (8 KB window; DRP at `+0x1400`) |
| `0x80010000` | activity counter GPIO — ch1 `eoc_count`, ch2 packed status |
| `0x80020000` | pot level out to the LED bar decoder |

The activity counter is deliberately at a **separate** aperture from the
sysmon's: it has to stay readable when the sysmon is not, because "the sysmon
tells us nothing" is the exact case it exists to report on.

## Verification

```
33 passed                                   sw/test_sysmon.py
[PASS] tb_pot_bar: all checks passed        xsim
[PASS] tb_sysmon_activity: all checks       xsim
verilator -Wall                             clean, 4 files, no suppressions
SYSMONE4 primitives in the implemented design: 1
WNS: 0.005 ns
```

The Python tests run against a fake register file and need no board; the MMIO
object is the only thing mocked. Both testbenches and the driver assert the
*same* `status_word` packing from opposite sides, so the RTL and the software
cannot drift apart silently.

The driver **refuses to read a SYSMON that is not converting**, rather than
reporting a comfortable `0.000 V` and `−280 °C`. Raw temperature of zero is the
probe, because it is physically impossible. That rule is why the original fault
was visible at all instead of being quietly plotted.

## Building it

```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
vivado -mode batch -source project_xadc_sysmon/build.tcl

# check the wizard's configuration in seconds rather than twenty minutes:
vivado -mode batch -source project_xadc_sysmon/build.tcl -tclargs bd_only
```

The build asserts what it produced — the top module, and that exactly one
SYSMONE4 is in the implemented design. Both have already caught a silent
failure: `add_files` brought the Verilog wrapper in before the block design
existed, so `update_compile_order` elected *it* as top and `make_wrapper -top`
did not displace it, and a whole run implemented the bare counter with no PS and
no sysmon.

Note also that IP Integrator rejects a `.sv` file as the top of a module
reference (`filemgmt 56-195`), which is why each module has a thin Verilog
wrapper, the same pattern CH08 and CH09 use.

## Getting it onto the board

```bash
./deploy/deploy_xadc.sh
```

Copies the bitstream, `.hwh`, drivers and notebook, and verifies every file by
md5 — the board has no RTC, so timestamps are meaningless and checksums are the
only honest check. Then open `notebooks/ch13_xadc_sysmon.ipynb`.

## Still open

**Nothing outstanding on the measurement side.** The pot's travel was in
question and has since been swept; see *The pot's actual travel* above.

**A physical button on the board powers it off, and it looks nothing like a
button.** The device tree maps `ps_sw0` on **PS MIO6** to `KEY_POWER` with
`autorepeat`, and systemd's default `HandlePowerKey=poweroff` applies. One press
produces a run of `systemd-logind: Power key pressed.` lines and a clean
shutdown ending in `reboot: Power down` — no panic, no mmc timeouts, none of the
signatures of a real crash. It happened here seconds after a bitstream load and
was initially suspected to be a thermal trip or a PL fault. MIO is PS-side and
untouched by PL reconfiguration, so the PL can never be the cause.
`journalctl -b -1 | grep -i "power key"` names it immediately.
