#include "sobel_stream.hpp"

// ---------------------------------------------------------------------------
// BT.601 luma in Q8 fixed point: 0.299/0.587/0.114 -> 77/150/29. The same
// coefficients CH11 used, so the two chapters' outputs are comparable pixel for
// pixel. The byte order is the difference: this stream is BGR, CH11's was RGBA.
// ---------------------------------------------------------------------------
static inline ap_uint<8> luma_of(ap_uint<24> px)
{
#pragma HLS INLINE
    ap_uint<8> b = px.range(7, 0);
    ap_uint<8> g = px.range(15, 8);
    ap_uint<8> r = px.range(23, 16);
    return (ap_uint<8>)(((ap_uint<18>)(77 * r + 150 * g + 29 * b)) >> 8);
}

// Luma replicated back across B, G and R.
static inline ap_uint<24> grey_of(ap_uint<8> v)
{
#pragma HLS INLINE
    ap_uint<24> p;
    p.range(7, 0)   = v;
    p.range(15, 8)  = v;
    p.range(23, 16) = v;
    return p;
}

// |g|, saturating the 3x3 Sobel magnitude to 8 bits.
static inline ap_uint<8> mag_of(int gx, int gy)
{
#pragma HLS INLINE
    int a = (gx < 0) ? -gx : gx;
    int b = (gy < 0) ? -gy : gy;
    int m = a + b;
    return (ap_uint<8>)((m > 255) ? 255 : m);
}

// ---------------------------------------------------------------------------
// The filter.
//
// Geometry, and why it is what it is
// ----------------------------------
// Two pixels arrive per beat, so a line is B = img_width/2 beats. Filtered
// pixel (r, c) needs input rows r-1, r, r+1 and columns c-1, c, c+1, which
// means output beat b of row r cannot be computed until input beat b+1 of row
// r+1 has arrived. The loop therefore runs over (H+1) x (B+1) steps:
//
//     consume input beat b of row r   when  r < H && b < B
//     produce output beat b-1 of row r-1   when  r >= 1 && b >= 1
//
// Both totals come to exactly B*H, which is what makes the block transparent to
// the rest of the pipeline: one beat out for every beat in, no frame ever short
// or long. This is the same iteration space as CH11's (height+1) x (width+1),
// and for the same reason -- there it kept two dataflow FIFOs balanced, here it
// keeps the AXI4-Stream frame intact.
//
// The extra row (r == H) is the important one for a *streaming* filter. It
// consumes nothing: the input frame is already over and the camera is in
// vertical blanking. It runs purely to flush the last output line out of the
// line buffers, so the frame that leaves this block is complete before the next
// start-of-frame arrives. Without it the last line of every frame would be owed
// into the next one, and the picture would crawl up the screen by a line per
// frame.
//
// The window
// ----------
// Per row the filter keeps the last three columns it has seen -- q0, q1, q2 --
// and combines them with the left-hand pixel of the beat currently arriving:
//
//     step b:  q0 = col 2b-3   q1 = col 2b-2   q2 = col 2b-1   new = col 2b
//              output pixels are cols 2b-2 (centre q1) and 2b-1 (centre q2)
//
// so the two Sobel windows in a beat overlap in two of their three columns and
// four columns of context are enough for both. Three rows of that gives the
// 3x4 window this loop actually maintains; a one-pixel-per-clock filter would
// need 3x3.
//
// Rows come from two line buffers holding whole beats: lb0 is row r-2 and lb1
// is row r-1, each rotated forward one row per step exactly as in CH11.
// ---------------------------------------------------------------------------
void sobel_stream(video_stream &stream_in,
                  video_stream &stream_out,
                  int           img_width,
                  int           img_height,
                  int           mode)
{
#pragma HLS INTERFACE axis port=stream_in  register
#pragma HLS INTERFACE axis port=stream_out register
#pragma HLS INTERFACE s_axilite port=img_width  register
#pragma HLS INTERFACE s_axilite port=img_height register
#pragma HLS INTERFACE s_axilite port=mode       register
#pragma HLS INTERFACE ap_ctrl_none port=return

    // Two luma values per word, so MAX_BEATS words covers MAX_WIDTH pixels.
    static ap_uint<16> lb0[MAX_BEATS];   // row r-2
    static ap_uint<16> lb1[MAX_BEATS];   // row r-1
#pragma HLS BIND_STORAGE variable=lb0 type=ram_s2p impl=bram
#pragma HLS BIND_STORAGE variable=lb1 type=ram_s2p impl=bram

    // There is deliberately no
    //
    //     #pragma HLS DEPENDENCE variable=lb1 type=inter dependent=false
    //
    // here, tempting as it looks. It flattens the two loops into a single II=1
    // pipeline and buys a few cycles per line -- and it is a lie. Successive
    // steps do address successive beats, but step (r, b) writes lb1[b] and step
    // (r+1, b) reads it back, and those are B+1 steps apart. `inter false`
    // claims independence at *every* distance, so with the loops flattened the
    // read of a narrow frame is issued before the write of the row above has
    // landed, and the filter emits a frame that is one line stale.
    //
    // The pipeline is about nine stages deep, so the lie is invisible for any
    // width above about twenty pixels, and the C simulation cannot see it at
    // all -- there is no pipeline in C. It took
    // the RTL testbench, on a 6x5 frame, to catch it -- and only on that frame,
    // because the other narrow cases are all border pixels, which are black
    // whatever the line buffer says.
    //
    // Without the pragma the column loop still pipelines at II=1; only the row
    // loop stops flattening, so the pipeline drains and refills once per line.
    // At 1080p that is about 8600 cycles a frame: 29 us at 300 MHz, against a
    // 33 ms frame, and it happens during horizontal blanking anyway.

    const int B = img_width >> 1;
    const int H = img_height;

    // Nothing sensible to do: the registers have not been written yet, the
    // geometry is wider than the line buffers, or the width is odd and so has
    // no representation on a two-pixel bus. Drain one beat rather than
    // returning empty-handed -- a block that stops reading backs the CSI-2
    // subsystem up until it overflows, and recovering from that needs a reset
    // of the whole video chain, whereas dropping pixels until a notebook sets
    // the registers costs nothing.
    //
    // Rejecting an odd width rather than truncating it is what keeps this and
    // the two RTL implementations interchangeable: truncating would leave each
    // of them to invent its own answer for a case none of them supports.
    if ((img_width & 1) || B <= 0 || B > MAX_BEATS || H <= 0) {
        stream_in.read();
        return;
    }

    // Find the start of a frame. Only the first invocation after a reset (or
    // after a mid-frame glitch) discards anything here: a frame is exactly B*H
    // beats long, so afterwards the loop always ends on an end-of-line and the
    // next beat read is the next frame's start-of-frame.
    video_pixel in_px = stream_in.read();
sync_loop:
    while (!in_px.user) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=1036800
#pragma HLS PIPELINE II=1
        in_px = stream_in.read();
    }

    // Latched here, once per frame, so that writing the register from a
    // notebook mid-frame switches modes cleanly at the next frame boundary
    // instead of tearing the frame in half.
    const int m = mode;

    // Colour passthrough needs no window and no line buffers, so it forwards
    // the beat untouched, TUSER and TLAST included. It is the only mode with
    // no line of latency.
    if (m == MODE_COLOR) {
color_row_loop:
        for (int r = 0; r < H; r++) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=1080
color_col_loop:
            for (int b = 0; b < B; b++) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=960
#pragma HLS PIPELINE II=1
                if (r || b) in_px = stream_in.read();   // (0,0) is already in hand
                stream_out.write(in_px);
            }
        }
        return;
    }

    // Window registers: q<row><n>, row 0 = r-2, row 1 = r-1, row 2 = r.
    ap_uint<8> q00 = 0, q01 = 0, q02 = 0;
    ap_uint<8> q10 = 0, q11 = 0, q12 = 0;
    ap_uint<8> q20 = 0, q21 = 0, q22 = 0;

row_loop:
    for (int r = 0; r <= H; r++) {
#pragma HLS LOOP_TRIPCOUNT min=2 max=1081
col_loop:
        for (int b = 0; b <= B; b++) {
#pragma HLS LOOP_TRIPCOUNT min=2 max=961
#pragma HLS PIPELINE II=1

            // --- consume -------------------------------------------------
            // New column pair for row r. Zero on the flush row and past the
            // right-hand edge; neither ever reaches an output pixel, because
            // every pixel they would contribute to is a frame border, and the
            // border is black in Sobel and centre-only in the pointwise modes.
            ap_uint<8> new2l = 0, new2r = 0;
            if (r < H && b < B) {
                if (r || b) in_px = stream_in.read();   // (0,0) is already in hand
                new2l = luma_of(in_px.data.range(23, 0));
                new2r = luma_of(in_px.data.range(47, 24));
            }

            // --- line buffers --------------------------------------------
            ap_uint<8> new0l = 0, new0r = 0;   // row r-2
            ap_uint<8> new1l = 0, new1r = 0;   // row r-1
            if (b < B) {
                ap_uint<16> w0 = lb0[b];
                ap_uint<16> w1 = lb1[b];
                new0l = w0.range(7, 0);   new0r = w0.range(15, 8);
                new1l = w1.range(7, 0);   new1r = w1.range(15, 8);

                lb0[b] = w1;                                   // r-1 becomes r-2
                lb1[b] = (ap_uint<16>)(((ap_uint<16>)new2r << 8) | new2l);
            }

            // --- produce -------------------------------------------------
            if (r >= 1 && b >= 1) {
                const int out_r  = r - 1;
                const int out_c0 = 2 * (b - 1);
                const int out_c1 = out_c0 + 1;
                const bool edge_row = (out_r == 0) || (out_r == H - 1);

                ap_uint<8> v0, v1;

                if (m == MODE_GRAY) {
                    v0 = q11;
                    v1 = q12;
                } else if (m == MODE_INVERT) {
                    v0 = (ap_uint<8>)(255 - q11);
                    v1 = (ap_uint<8>)(255 - q12);
                } else {
                    // Left pixel: columns q0, q1, q2 centred on q1.
                    int gx0 = (q02 + 2 * q12 + q22) - (q00 + 2 * q10 + q20);
                    int gy0 = (q20 + 2 * q21 + q22) - (q00 + 2 * q01 + q02);
                    // Right pixel: columns q1, q2, new centred on q2.
                    int gx1 = (new0l + 2 * new1l + new2l) - (q01 + 2 * q11 + q21);
                    int gy1 = (q21 + 2 * q22 + new2l) - (q01 + 2 * q02 + new0l);

                    bool b0 = edge_row || (out_c0 == 0) || (out_c0 == img_width - 1);
                    bool b1 = edge_row || (out_c1 == img_width - 1);

                    v0 = b0 ? (ap_uint<8>)0 : mag_of(gx0, gy0);
                    v1 = b1 ? (ap_uint<8>)0 : mag_of(gx1, gy1);
                }

                video_pixel out_px;
                out_px.data = ((ap_uint<48>)grey_of(v1) << 24) | grey_of(v0);
                out_px.keep = -1;
                out_px.strb = -1;
                out_px.user = (r == 1 && b == 1) ? 1 : 0;   // start of frame
                out_px.last = (b == B) ? 1 : 0;             // end of line
                stream_out.write(out_px);
            }

            // --- slide the window two columns to the left ----------------
            q00 = q02;  q01 = new0l;  q02 = new0r;
            q10 = q12;  q11 = new1l;  q12 = new1r;
            q20 = q22;  q21 = new2l;  q22 = new2r;
        }
    }
}
