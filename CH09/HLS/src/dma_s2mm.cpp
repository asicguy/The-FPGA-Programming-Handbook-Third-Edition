// ============================================================================
//  dma_s2mm.cpp
//
//  HLS audio-capture DMA engine -- the high-level-synthesis equivalent of
//  axi_dma_writer.sv.  It drains the AXI4-Stream coming from the I2S
//  deserializer and bursts it into a DDR buffer over an AXI4 master.
//
//  Compare with the RTL: axi_dma_writer.sv needed an explicit S_IDLE/S_DECIDE/
//  S_ADDR/S_DATA/S_RESP FSM, a combinational block to clamp each burst to
//  MAX_BURST_LEN and to the next 4 KB boundary, and a sample FIFO so the W
//  channel never stalled mid-burst.  Here the loop below is all the designer
//  writes; Vitis HLS infers the AW/W/B channels, splits bursts at 4 KB
//  boundaries automatically, and builds the elastic buffering needed to keep
//  the bursts full.
//
//  Control mapping (RTL register  ->  HLS s_axilite):
//    cfg_buf_addr     -> mem            (pointer, offset=slave)
//    cfg_buf_len      -> length_bytes
//    cfg_start        -> ap_start       (auto handshake)
//    sts_busy/done    -> ap_idle/ap_done
//    sts_bytes_written-> bytes_written
// ============================================================================
#include "aic3104_dma.h"

void dma_s2mm(word_t            *mem,
              hls::stream<word_t>&s_axis,
              uint32_t            length_bytes,
              uint32_t           *bytes_written) {
    // DDR master.  offset=slave puts the buffer base address in a control
    // register, so the PS sets it exactly like cfg_buf_addr.  The burst/
    // outstanding settings give the same "keep the bus busy" behaviour the RTL
    // got from its internal FIFO.
#pragma HLS INTERFACE m_axi port=mem offset=slave bundle=gmem depth=BUF_BEATS \
    max_write_burst_length=16 num_write_outstanding=4

    // Audio samples in.  A bare AXI4-Stream (TDATA/TVALID/TREADY only) so it
    // drops straight onto the RTL I2S front end's rx_data / ~rx_empty / tready.
#pragma HLS INTERFACE axis port=s_axis

    // Control / status bus driven by the PS.
#pragma HLS INTERFACE s_axilite port=mem           bundle=ctrl
#pragma HLS INTERFACE s_axilite port=length_bytes  bundle=ctrl
#pragma HLS INTERFACE s_axilite port=bytes_written bundle=ctrl
#pragma HLS INTERFACE s_axilite port=return        bundle=ctrl

    // 4 bytes per packed L/R frame -> number of AXI beats to capture.
    const uint32_t beats = length_bytes >> 2;

capture:
    for (uint32_t i = 0; i < beats; i++) {
#pragma HLS PIPELINE II=1
        // Blocking read stalls the loop (and back-pressures TVALID) whenever
        // the codec has no sample ready, so no frames are dropped.
        mem[i] = s_axis.read();
    }

    *bytes_written = beats << 2;
}
