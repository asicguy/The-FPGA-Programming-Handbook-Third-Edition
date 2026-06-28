// ============================================================================
//  aic3104_dma.h
//
//  HLS implementation of the AIC3104 DMA engines (Chapter 9).
//
//  This is the high-level-synthesis counterpart of the hand-written RTL DMA
//  engines axi_dma_writer.sv (S2MM / capture) and axi_dma_reader.sv (MM2S /
//  playback).  Where the RTL versions had to spell out the AXI4 burst FSM, the
//  4 KB-boundary burst splitting and the read-ahead credit accounting by hand,
//  the HLS tool infers all of that from a simple copy loop over an m_axi
//  pointer.  Two functions are generated:
//
//    dma_s2mm  : AXI4-Stream slave  -> DDR        (audio CAPTURE)
//    dma_mm2s  : DDR -> AXI4-Stream master        (audio PLAYBACK)
//
//  Each becomes its own IP with:
//    * m_axi     master -> connect to a Zynq UltraScale+ HP/HPC slave port.
//                HLS auto-generates AW/W/B (s2mm) or AR/R (mm2s) bursts.
//    * axis      AXI4-Stream port -> connect to the RTL I2S front end
//                (clock-gen / serdes / async FIFOs from aic3104_dma.sv).
//    * s_axilite control bus -> driven by the PS.  The block-RAM register map
//                from the RTL (REG_*_ADDR/BYTES/START/STAT) is replaced by the
//                HLS-generated control registers: the buffer pointer (mem),
//                the length, the bytes-transferred status word, plus the
//                ap_ctrl_hs handshake (ap_start / ap_done / ap_idle) that
//                stands in for cfg_start / sts_busy / sts_done.
//
//  Sample packing (identical to the RTL):  one 32-bit AXI beat carries one
//  stereo frame, bits[31:16] = right channel, bits[15:0] = left channel,
//  each a 16-bit two's-complement sample.
// ============================================================================
#ifndef AIC3104_DMA_H
#define AIC3104_DMA_H

#include <ap_int.h>
#include <hls_stream.h>
#include <cstdint>

// One packed L/R audio frame == one AXI data beat (matches AXI_DATA_WIDTH=32).
typedef ap_uint<32> word_t;

// Largest buffer the engines size their m_axi window for, in beats.  Only used
// to bound the m_axi "depth" for C/RTL co-simulation; the runtime length is set
// by the PS through the length_bytes register.  16384 beats = 64 KB.
#define BUF_BEATS 16384

// ---- Audio CAPTURE: AXI4-Stream slave -> DDR (the HLS axi_dma_writer) -------
void dma_s2mm(word_t            *mem,           // m_axi master -> DDR buffer
              hls::stream<word_t>&s_axis,        // samples in from I2S front end
              uint32_t            length_bytes,  // buffer size in BYTES
              uint32_t           *bytes_written);// status: bytes captured

// ---- Audio PLAYBACK: DDR -> AXI4-Stream master (the HLS axi_dma_reader) -----
void dma_mm2s(word_t            *mem,           // m_axi master -> DDR buffer
              hls::stream<word_t>&m_axis,        // samples out to I2S front end
              uint32_t            length_bytes,  // buffer size in BYTES
              uint32_t           *bytes_read);   // status: bytes played

#endif // AIC3104_DMA_H
