// ============================================================================
//  test_bench.cpp
//
//  C / co-simulation test bench for the HLS AIC3104 DMA engines.  It mirrors
//  the loopback check in tb_aic3104.sv:
//
//    1. Push a known stereo pattern into dma_s2mm so it is captured to a DDR
//       model (the mem[] array), then read it back with dma_mm2s and confirm
//       every beat survives the round trip -- exactly the wr_q vs rd_q check
//       the SystemVerilog bench performs.
//    2. Repeat with 1536 beats (6 KB), which crosses several 4 KB AXI burst
//       boundaries, to exercise the burst splitting HLS inferred for us.
//
//  The packed pattern matches the RTL bench: right = ~i, left = i.
// ============================================================================
#include "aic3104_dma.h"
#include <cstdio>

static word_t pattern(uint32_t i) {
    uint32_t left  = i & 0xFFFF;
    uint32_t right = (~i) & 0xFFFF;
    return (word_t)((right << 16) | left);
}

static int run_loopback(const char *name, uint32_t beats) {
    static word_t mem[BUF_BEATS];          // DDR model shared by both engines
    hls::stream<word_t> rx("rx");          // I2S deserializer -> dma_s2mm
    hls::stream<word_t> tx("tx");          // dma_mm2s -> I2S serializer
    const uint32_t bytes = beats * 4;

    // ---- Capture: feed the stream, then run the S2MM engine ----------------
    for (uint32_t i = 0; i < beats; i++)
        rx.write(pattern(i));

    uint32_t bytes_written = 0;
    dma_s2mm(mem, rx, bytes, &bytes_written);

    if (bytes_written != bytes) {
        printf("[%s] FAIL: bytes_written %u != %u\n", name, bytes_written, bytes);
        return 1;
    }

    // ---- Playback: run the MM2S engine, then drain and check the stream ----
    uint32_t bytes_read = 0;
    dma_mm2s(mem, tx, bytes, &bytes_read);

    if (bytes_read != bytes) {
        printf("[%s] FAIL: bytes_read %u != %u\n", name, bytes_read, bytes);
        return 1;
    }
    if (tx.size() != beats) {
        printf("[%s] FAIL: beat-count mismatch  exp=%u got=%u\n",
               name, beats, (uint32_t)tx.size());
        return 1;
    }

    for (uint32_t i = 0; i < beats; i++) {
        word_t got = tx.read();
        word_t exp = pattern(i);
        if (got != exp) {
            printf("[%s] FAIL: beat %u  exp=%08x got=%08x\n",
                   name, i, (uint32_t)exp, (uint32_t)got);
            return 1;
        }
    }

    printf("[%s] PASS: %u beats looped back through DDR\n", name, beats);
    return 0;
}

int main() {
    int err = 0;
    err |= run_loopback("small",        16);     // single short burst
    err |= run_loopback("backpressure", 1536);   // crosses 4 KB boundaries

    if (err) {
        printf("TEST FAILED\n");
        return 1;
    }
    printf("ALL TESTS PASSED\n");
    return 0;
}
