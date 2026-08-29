#ifndef VIDEO_FILTER_HPP
#define VIDEO_FILTER_HPP

#include <ap_int.h>

// Maximum supported image width. Sets the depth of the two BRAM line buffers.
#define MAX_WIDTH 1920

// ---------------------------------------------------------------------------
// Co-simulation geometry.
//
// The `depth` on an m_axi port is a *verification* hint, not a hardware one --
// it has no effect on the generated RTL. What it does control is how many
// elements the cosim wrapper copies out of each pointer argument in ENTER_WRAPC
// before the RTL ever runs. Set it larger than the testbench actually allocates
// and the wrapper reads off the end of that buffer:
//
//     ERROR: System received a signal named SIGSEGV ...
//     Current execution stopped during CodeState = ENTER_WRAPC.
//
// So depth must match the testbench frame exactly. TB_W/TB_H live here rather
// than in the testbench so the two cannot drift apart; tb_video_filter.cpp
// static_asserts that they still agree.
//
// Keep TB_W/TB_H small -- cosim is RTL-accurate and a full-HD frame would take
// hours.
#define TB_W 64
#define TB_H 48
#define COSIM_DEPTH 3072        // == TB_W * TB_H

// ---------------------------------------------------------------------------
// Filter modes (written to the s_axilite 'mode' register)
// ---------------------------------------------------------------------------
#define MODE_GRAY   0   // luma, replicated across all three colour channels
#define MODE_SOBEL  1   // luma -> Sobel magnitude, zero border
#define MODE_INVERT 2   // luma -> 255 - luma
#define MODE_COLOR  3   // colour passthrough: dst = src, pixel for pixel

// ---------------------------------------------------------------------------
// Pixel format: 32 bits per pixel, B,G,R,A from the LSB up.
//
//     bits  7..0   blue
//     bits 15..8   green
//     bits 23..16  red
//     bits 31..24  alpha / pad
//
// That byte order is not a preference, it is what both of this chapter's frame
// sources actually produce:
//
//   - The camera. AMD's MIPI pipeline ends in an axis_subset_converter named
//     `axis_channel_swap` whose TDATA_REMAP puts blue in the low byte, and
//     `pixel_pack` in 32bpp mode appends a pad byte on top. That is why the
//     AUP-ZU3 base overlay's notebook writes `frame[:,:,[2,1,0]]` to hand a
//     camera frame to PIL, which wants R first.
//   - OpenCV. `VideoCapture.read()` and `imread()` both return BGR.
//
// So a decoded video frame and a camera frame have the same layout, and the
// filter cannot tell them apart -- which is the whole point of project 3.
//
// Luma is ITU-R BT.601 in Q8: Y = (29*B + 150*G + 77*R) >> 8. Note the weights
// are ordered to match the byte order above; CH11's kernel used the same three
// constants against R,G,B because its input came from PIL, not from a camera.
// ---------------------------------------------------------------------------
#define LUMA_B 29
#define LUMA_G 150
#define LUMA_R 77

// ---------------------------------------------------------------------------
// Top-level HLS function.
//
// src / dst point to packed 32-bit pixels, laid out as above, contiguous, in
// raster order. There is no stride argument: a frame is exactly
// img_width * img_height words with nothing between the lines. Both PYNQ
// frame sources satisfy this at every resolution the chapter uses, but it is a
// constraint a caller can violate, so check it rather than assume it.
//
// img_width  : pixels per row, <= MAX_WIDTH
// img_height : rows
// mode       : one of MODE_* above
//
// NOTE ON THE ARGUMENT NAMES: these are deliberately not `width`/`height`.
// HLS turns each scalar argument into an s_axilite register whose single field
// carries the argument's name, and PYNQ builds `register_map` by creating a
// Python property per field on its own `Register` class. `Register.__init__`
// assigns `self.width`, so a field literally named `width` overwrites that
// attribute with a property -- and `Register.__setitem__` reads `self.width`,
// which re-enters the property, which recurses until the interpreter gives up:
//
//     RecursionError: maximum recursion depth exceeded
//         ... in Register.__getitem__ -> _calc_index(index, self.width)
//
// ...raised from `print(filt.register_map)`, long before you ever start the
// accelerator. The reserved names are `address`, `width`, `debug` and `access`
// (the four public attributes `Register.__init__` sets). Avoid all four for
// top-level argument names.
//
// The register map this produces is CH11's, unchanged -- see CH12/README.md.
// The two chapters' accelerators are drop-in compatible at the AXI4-Lite
// interface; they differ only in the pixel byte order they assume and in
// MODE_COLOR, which CH11 does not have.
// ---------------------------------------------------------------------------
void video_filter(const ap_uint<32> *src,
                  ap_uint<32>       *dst,
                  int                img_width,
                  int                img_height,
                  int                mode);

#endif // VIDEO_FILTER_HPP
