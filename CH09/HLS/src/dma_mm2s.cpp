// ============================================================================
//  dma_mm2s.cpp
//
//  HLS audio-playback DMA engine -- the high-level-synthesis equivalent of
//  axi_dma_reader.sv.  It reads a DDR buffer over an AXI4 master and emits it
//  as an AXI4-Stream into the I2S serializer's TX FIFO.
//
//  Compare with the RTL: axi_dma_reader.sv carried a credit-based read-ahead
//  scheme (an AR-issue sub-FSM, an inflight-beat counter, a prime threshold,
//  and underflow detection) purely to keep the output FIFO from going empty
//  while many bursts were in flight.  In HLS the same effect comes for free:
//  num_read_outstanding + the inferred read burst let the tool launch several
//  AR requests ahead of the stream, and the loop below simply blocks on the
//  stream when the consumer (I2S TX FIFO) is full.
//
//  Control mapping (RTL register  ->  HLS s_axilite):
//    cfg_buf_addr   -> mem            (pointer, offset=slave)
//    cfg_buf_len    -> length_bytes
//    cfg_start      -> ap_start       (auto handshake)
//    sts_busy/done  -> ap_idle/ap_done
//    sts_bytes_read -> bytes_read
// ============================================================================
#include "aic3104_dma.h"

void dma_mm2s(word_t            *mem,
              hls::stream<word_t>&m_axis,
              uint32_t            length_bytes,
              uint32_t           *bytes_read) {
    // DDR master.  num_read_outstanding lets HLS keep several read bursts in
    // flight -- the read-ahead that the RTL had to manage with its credit
    // counter -- so the stream stays fed and never underflows.
#pragma HLS INTERFACE m_axi port=mem offset=slave bundle=gmem depth=BUF_BEATS \
    max_read_burst_length=16 num_read_outstanding=8

    // Audio samples out.  Bare AXI4-Stream -> RTL front end's
    // tx_din / tx_stream_valid / tx_stream_ready.
#pragma HLS INTERFACE axis port=m_axis

    // Control / status bus driven by the PS.
#pragma HLS INTERFACE s_axilite port=mem          bundle=ctrl
#pragma HLS INTERFACE s_axilite port=length_bytes bundle=ctrl
#pragma HLS INTERFACE s_axilite port=bytes_read   bundle=ctrl
#pragma HLS INTERFACE s_axilite port=return       bundle=ctrl

    const uint32_t beats = length_bytes >> 2;

playback:
    for (uint32_t i = 0; i < beats; i++) {
#pragma HLS PIPELINE II=1
        // Blocking write stalls when the I2S TX FIFO is full, so playback
        // paces itself to the audio sample rate without overrunning.
        m_axis.write(mem[i]);
    }

    *bytes_read = beats << 2;
}
