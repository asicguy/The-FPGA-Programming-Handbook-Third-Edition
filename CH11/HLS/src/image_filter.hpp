#ifndef IMAGE_FILTER_HPP
#define IMAGE_FILTER_HPP

#include <ap_int.h>

// Maximum supported image width. Sets the depth of the two BRAM line buffers.
// 1920 * 2 bytes-per-row-buffer -> ~2 BRAM18 on ZU3EG. Raise only if you need it.
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
// than in the testbench so the two cannot drift apart; tb_image_filter.cpp
// static_asserts that they still agree.
//
// Keep TB_W/TB_H small -- cosim is RTL-accurate and a full-HD frame would take
// hours.
#define TB_W 64
#define TB_H 48
#define COSIM_DEPTH 3072        // == TB_W * TB_H

// Filter modes (written to the s_axilite 'mode' register)
#define MODE_GRAY   0   // RGB -> luma, passthrough
#define MODE_SOBEL  1   // RGB -> luma -> Sobel magnitude, zero border
#define MODE_INVERT 2   // RGB -> luma -> 255 - luma

// Top-level HLS function.
//
// src / dst point to packed 32-bit RGBA pixels (byte order R,G,B,A from the
// LSB up, which is exactly what NumPy gives you for a uint8 (H,W,4) array
// viewed as uint32 on a little-endian machine).
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
// top-level argument names. Only `width` actually collided here; `height` is
// renamed alongside it purely for symmetry.
void image_filter(const ap_uint<32> *src,
                  ap_uint<32>       *dst,
                  int                img_width,
                  int                img_height,
                  int                mode);

#endif // IMAGE_FILTER_HPP
