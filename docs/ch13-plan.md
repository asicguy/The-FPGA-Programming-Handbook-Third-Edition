# CH13 — one socket, many accelerators, no reboot

**Status: proposed.** Not approved, not started. The feasibility spike behind it
is described in §3, including the parts that failed.

## 1. What the chapter is for

CH12 ships nine bitstreams across four projects, and moving between them
requires a **reboot of the board**. The reason is not the bitstream: it is that
removing a device-tree overlay leaks its `__symbols__` entries, so a later
overlay declaring the same `axi_iic` node is rejected with `EINVAL`. Every CH12
camera overlay declares that node.

Dynamic Function eXchange removes the cause rather than the symptom. One
overlay is applied at boot and never removed; only a *partial* bitstream
changes, and PYNQ's `pr_download(region, bitstream, dtbo=None)` applies no
device tree at all.

But swapping three implementations of the same filter would be a trick, not a
demonstration. What DFX is actually for is changing what the hardware *does*.
So CH13 builds **one accelerator socket and several interchangeable functions**,
swapped from a notebook while the camera keeps streaming.

## 2. Architecture

The pins decide the split. MIPI and IIC are physical, so the camera hierarchy,
VDMA, DisplayPort path and PS are all **static**. What varies is the
accelerator, which is exactly the thing worth varying.

```
static:  PS | camera hierarchy | VDMA | DisplayPort | interconnect
         | status GPIO | AXI decoupler | the socket's shell
   RP:   one accelerator, swapped at run time
   RMs:  empty | sobel | blur | threshold | (colour passthrough)
```

CH12's four "projects" collapse into run-time choices of one design.

### 2.1 The socket contract

Fixed before any RM exists, exactly as CH12 fixed its register map first.
CH12's `video_filter` already presents this, so it is RM #1 for free:

```
ap_clk, ap_rst_n
s_axi_control   AXI4-Lite, 6-bit     CTRL/GIER/IER/ISR, src, dst,
m_axi_gmem0     AXI4 read,  32-bit    img_width, img_height, mode
m_axi_gmem1     AXI4 write, 32-bit
interrupt
heartbeat       free-running counter bit -- see §2.2
```

Two additions to CH12's register map:

- **`kernel_id` (read-only).** With DFX you must be able to ask the hardware
  what is in the socket. Inferring it from what you *think* you loaded is how
  a swapped-but-not-really design goes unnoticed.
- **`heartbeat`**, not a register but a wire to the static region.

### 2.2 The status GPIO, and why it is not optional

An AXI GPIO **in the static region** reports the partition's reset state and
the socket's heartbeat. Static logic always answers; the partition may not.

This exists because of a specific failure. A read of a socket that is held in
reset never returns, ZynqMP has no bus timeout on the PL ports, and the CPU
then hangs with no panic and no console — power cycle only. Worse, "held in
reset" and "logic is broken" are indistinguishable from outside. During the
spike that ambiguity cost several power cycles and produced a diagnosis that
was wrong twice.

With the GPIO, software asks *"is the partition clocked and out of reset?"*
before it asks the partition anything, and **declines** instead of hanging.
Every access path in `sw/` must go through that check.

## 3. What the spike proved, and what it broke

A throwaway spike ran before this plan: a static design, two reconfigurable
modules with distinct identity registers, and a swap.

**Established:**

- DFX is available for `xczu3eg` on Vivado 2025.2 — `PR_FLOW`, `pr_verify`,
  `create_partition_def`, `dfx_decoupler`, and `dfx_axi_shutdown_manager`.
- Partial bitstreams build, and `pr_verify` reports the static regions of two
  configurations **compatible** — so the partials are interchangeable.
- A proper block design loads under PYNQ, the socket answers, and the status
  GPIO reports reset and heartbeat correctly (`identity = 0xA5A50001`,
  scratch write/read verified, board unharmed).
- A partial for a 1-clock-region partition is ~980 KB against a 5.5 MB full
  bitstream.

**Broke, and why it matters:**

- **Partial reconfiguration with no decoupler panicked the kernel:**
  `Kernel panic - not syncing: Asynchronous SError Interrupt`. The interconnect
  took a bus fault from a region being rewritten underneath it. A decoupler is
  therefore *mandatory* — this plan's §4 exists because of that panic.
- A hand-rolled static design with no `.hwh` wedged the CPU when PYNQ
  programmed it; the same design in a proper block design worked first time.
- An AXI4-Lite slave that required AW and W in the *same cycle* hung the PS
  forever. The PS routinely sends the address ahead of the data.
- Vivado's auto-created `<bd>_inst_0_impl_1` runs are **out-of-context** runs,
  not DFX children. A partial must be implemented in a run whose
  `-parent_run` is the static implementation, or the partition is a black box.
- `create_partition_def` does not apply to a BD cell created as a plain module
  reference. IPI's mechanism is the **Block Design Container**, and the
  partition definitions do not exist until `generate_target` has run — before
  that, `get_partition_defs` returns empty and it looks like a silent failure.

## 4. The swap procedure

Not a function call. A documented sequence, and the reason each step exists:

```
1. wait for ap_idle            the accelerator must not be mid-frame
2. engage the decoupler        isolate the partition from the interconnect
3. pr_download(region, bit)    no dtbo -- this is what avoids the reboot
4. release the partition reset RESET_AFTER_RECONFIG holds it until now
5. check the status GPIO       heartbeat toggling => the new RM is alive
6. disengage the decoupler     only now may traffic reach the socket
7. read kernel_id              confirm what is actually loaded
```

Steps 2 and 6 are what the spike's kernel panic bought. Step 5 is what the
board wedges bought. Skipping either is not a shortcut, it is the fault.

`dfx_axi_shutdown_manager` is preferred over a plain `dfx_decoupler` on the two
`m_axi_gmem` ports: it completes outstanding transactions and returns the
responses the interconnect is waiting for, rather than isolating and leaving
them stranded — and a stranded transaction on a PL port is the no-timeout hang.

## 5. Build flow

```
common/dfx_socket.tcl     the socket's child BD, one per RM
common/dfx_static.tcl     PS + camera + VDMA + DP + decoupler + GPIO + BDC
project/build_bd.tcl      -tclargs <rm>...   builds static + every partial
```

- Each RM is its own child block design; the container lists them in
  `CONFIG.LIST_SYNTH_BD`. Their external interfaces must match exactly; the
  module names must differ.
- `generate_target` before querying partition definitions.
- One child implementation run per RM, `-parent_run` the static impl.
- `pr_verify` every configuration against the static, as a build gate.
- The pblock is clock-region aligned (`RESET_AFTER_RECONFIG` requires it) and
  sized for the **largest** RM — HLS's `video_filter` is ~3000 LUT, 3602 FF,
  5.5 BRAM, 13 DSP out of context, so the partition must hold that with margin.

## 6. Verification, in order

Nothing reaches the board until the step before it passes.

1. **Socket testbench first, before any RM exists.** A deliberately hostile
   AXI4-Lite master: AW/W skew in both directions, delayed `bready`/`rready`,
   backpressure. With a negative control proving the testbench fails against a
   known-bad slave. Three of the spike's four board wedges were AXI slaves and
   drivers that had no testbench; every component that had one cost nothing.
2. **Each RM against the software golden model**, extending `sw/sobel_ref.py`,
   bit-exact.
3. **One RTL testbench, every RM**, as CH12 does for its three implementations.
4. **`pr_verify`** for every configuration.
5. **Staged bring-up.** Static design with a fixed RM as an ordinary overlay
   first; only when that answers, enable reconfiguration. The spike's Stage 1
   passed first time precisely because everything under it was already proven.
6. **On the board:** swap while the camera streams; confirm `kernel_id`,
   bit-exactness per RM, and the frame rate across a swap.

### 6.1 Reconfiguration time — a number, and what it costs the story

The spike measured one: a ~980 KB partial took **399 ms** through PYNQ's
`Bitstream(..., partial=True).download()`. That is 24 frames at 60 fps.

**A swap is therefore not invisible mid-stream**, and the chapter must not
imply it is. "Change the filter while the camera streams" is still true and
still worth demonstrating; "without the viewer noticing" is not. The honest
framing is that the pipeline stalls for about a quarter of a second and
resumes with different hardware in the socket — which is a great deal better
than a reboot, and should be presented as that rather than as seamlessness.

Treat the figure as provisional: it was taken through Python and PYNQ rather
than a tight loop, on a design with no decoupler, and the run panicked
immediately afterwards. Re-measure it properly, and measure the PCAP transfer
alone as well as the end-to-end call, before quoting it anywhere.

If the number holds, it is worth asking what the partial's size is buying: the
spike's partition was a whole clock region for a thirty-LUT module. A partition
sized to the accelerator rather than to convenience may reconfigure
proportionally faster, and that trade is itself a thing this chapter can show.

## 7. Board discipline

Learned expensively, and binding for this chapter:

- **Serial console capture running before any hardware step.** It is the only
  thing that produced a real diagnosis during the spike; ssh dies first.
- **Every board operation as a background task**, never a foreground command a
  timeout can kill mid-write.
- **Status before access**, per §2.2.
- **JTAG for first contact** with an untested address: a non-responding read
  costs the DAP, not the board. Note that programming the PL over JTAG under a
  running Linux takes the OS down — acceptable when deliberate, not as a
  default.

## 8. Risks

- **The camera cannot move into the RP** — its pins are physical. If a reader
  expects "swap the whole pipeline", the chapter must set that expectation
  early.
- **Timing under a pblock.** Project 3 currently closes at +0.386 ns; confining
  the accelerator to a region may cost more than that.
- **The AP_DONE fault rides along.** It is mitigated in software, not fixed;
  the mechanism is still unidentified after two refuted theories. The socket
  makes `video_filter_ctrl` permanent, so this should be closed with an ILA
  before it is baked in — see CH12's README.
- Partial reconfiguration is per-region; two accelerators would need two
  regions, and the spike proves one.

## 9. Out of scope

CH12 is not modified beyond what the socket requires. No PS-side dynamic
loading of anything but bitstreams. No multi-region DFX. No attempt to make
project 2's "no camera" case a hardware variant — with DFX it is a run-time
choice, which is the point.
