# AIC3104 DMA — HLS implementation

This is the High-Level-Synthesis version of the Chapter 9 DMA audio path. It
replaces the two hand-written RTL DMA engines with HLS C++:

| RTL (SystemVerilog)   | HLS (this folder)        | Direction                  |
|-----------------------|--------------------------|----------------------------|
| `axi_dma_writer.sv`   | `dma_s2mm` (`dma_s2mm.cpp`) | AXI4-Stream → DDR (capture) |
| `axi_dma_reader.sv`   | `dma_mm2s` (`dma_mm2s.cpp`) | DDR → AXI4-Stream (playback) |

## Why only the DMA engines?

The full RTL design (`aic3104_dma.sv`) has three parts:

1. **I2S front end** — MCLK clock divider, the bit-serial transmit/receive
   shift logic, and the two `xpm_fifo_async` clock-domain-crossing FIFOs.
2. **AXI-Lite register block** — the `REG_TX_*` / `REG_RX_*` map.
3. **Two DMA engines** — `axi_dma_writer` / `axi_dma_reader`.

Part 1 is sub-clock-cycle bit timing plus a true asynchronous clock crossing
(audio MCLK ↔ AXI clock). That is exactly what RTL is for and is *not* a good
fit for HLS, so it stays in SystemVerilog. HLS replaces parts **2 and 3**:
the AXI burst master and its control registers.

## What HLS does for you

The RTL engines spell out, by hand, an AW/W/B (or AR/R) state machine, the
arithmetic that clamps every burst to `MAX_BURST_LEN` **and** to the next 4 KB
boundary (an AXI4 rule), an internal sample FIFO, and — in the reader — a
credit-based read-ahead scheme with underflow detection. In HLS all of that
collapses to one pipelined copy loop over an `m_axi` pointer:

```cpp
for (uint32_t i = 0; i < beats; i++) {
#pragma HLS PIPELINE II=1
    mem[i] = s_axis.read();        // capture  (dma_s2mm)
    // m_axis.write(mem[i]);       // playback (dma_mm2s)
}
```

Vitis HLS infers the AXI4 burst master, splits bursts at 4 KB boundaries, and
(via `num_read_outstanding` / `num_write_outstanding`) keeps several bursts in
flight so the stream never stalls — the read-ahead the RTL had to build by hand.

## Control-register mapping

The custom RTL register map becomes the HLS-generated `s_axilite` control bus
plus the standard `ap_ctrl_hs` block-level handshake:

| RTL register / signal | HLS equivalent              |
|-----------------------|-----------------------------|
| `cfg_buf_addr`        | `mem` pointer (`offset=slave`) |
| `cfg_buf_len`         | `length_bytes`              |
| `cfg_start`           | `ap_start`                  |
| `sts_busy`            | `ap_idle` (inverted)        |
| `sts_done`            | `ap_done`                   |
| `sts_bytes_written` / `sts_bytes_read` | `bytes_written` / `bytes_read` |

Sample packing is unchanged: one 32-bit beat = one stereo frame,
`bits[31:16]` = right, `bits[15:0]` = left, 16-bit two's-complement each.

## Building

Easiest — the wrapper script sources the Vitis environment and builds both
components (C sim → C synthesis → IP packaging):

```sh
./build.sh                # csim + synth + package both components
./build.sh --cosim        # also run C/RTL co-simulation
./build.sh --no-csim      # synth + package only
./build.sh s2mm           # build just one component (or: mm2s)
./build.sh --clean        # remove generated component directories
```

It auto-detects the newest `/opt/Xilinx/<ver>/Vitis`; override with
`VITIS_VERSION=2025.2 ./build.sh` or `VITIS_SETTINGS=/path/settings64.sh ./build.sh`.

Under the hood it runs the unified-flow Tcl script directly:

```sh
cd src && vitis-run --mode hls --tcl run_hls.tcl
```

`run_hls.tcl` honors the same `RUN_CSIM` / `RUN_COSIM` / `COMPONENTS` env vars.
Each component targets `xczu3eg-sfvc784-2-e` at 100 MHz (both synthesize at
II = 1) and produces an IP-catalog archive at:

```
src/<component>/hls/impl/ip/xilinx_com_hls_<component>_1_0.zip
```

The `hls_config_*.cfg` files are provided for opening the components directly in
the Vitis IDE / unified `--config` flow.

## Quick C-simulation (no Vitis project needed)

```sh
g++ -std=c++14 -I$XILINX_VITIS/include \
    test_bench.cpp dma_s2mm.cpp dma_mm2s.cpp -o dma_csim && ./dma_csim
```

The bench mirrors the loopback check in `tb_aic3104.sv`: it captures a known
`right = ~i, left = i` pattern into a DDR model and plays it back, including a
1536-beat (6 KB) pass that crosses several 4 KB burst boundaries.

## Integrating in the block design

1. Add both packaged IPs to the IP catalog and drop them into the Chapter 9
   block design.
2. Connect each IP's **`m_axi`** master to a Zynq UltraScale+ **HP/HPC** slave
   port (capture and playback can share one port through an AXI interconnect,
   as the RTL did, or use two ports).
3. Connect each IP's **`s_axilite`** control bus to the PS **M_AXI_GP**.
4. Wire the **AXI4-Stream** ports to the retained RTL I2S front end:
   - `dma_s2mm.s_axis`  ← RX stream (the codec-capture FIFO output).
   - `dma_mm2s.m_axis`  → TX stream (the playback FIFO input).
5. From the PS: set the buffer pointer and `length_bytes`, write `ap_start`,
   then poll `ap_done` (or use the `interrupt` if `ap_ctrl` interrupts are
   enabled) — the software flow that replaces poking `REG_*_START` / `REG_*_STAT`.
