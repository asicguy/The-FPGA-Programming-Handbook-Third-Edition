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
