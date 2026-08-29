#include "video_filter.hpp"
#include <hls_stream.h>

// ---------------------------------------------------------------------------
// Stage 1: burst-read packed BGRA from DDR into a stream.
//
// Unlike CH11's kernel this passes the whole pixel along rather than reducing
// it to luma here. MODE_COLOR needs the colour to survive, and a 32-bit
// dataflow FIFO costs a handful of LUTs -- whereas keeping the colour in a
// second line buffer, so it could be recovered after the window delay, would
// cost another BRAM.
// ---------------------------------------------------------------------------
static void read_pixels(const ap_uint<32>        *src,
                        hls::stream<ap_uint<32> > &pix_s,
                        int                        width,
                        int                        height)
{
    const int n = width * height;
read_loop:
    for (int i = 0; i < n; i++) {
#pragma HLS LOOP_TRIPCOUNT min=1024 max=2073600
#pragma HLS PIPELINE II=1
        pix_s.write(src[i]);
    }
}

// ---------------------------------------------------------------------------
// Stage 2: 3x3 sliding window over a two-row line buffer.
//
// The iteration space is (height+1) x (width+1). A pixel is consumed whenever
// (r < height && c < width); in the three filtered modes one is produced
// whenever (r >= 1 && c >= 1), because the window centre at step (r, c) holds
// input pixel (r-1, c-1) and cannot be filtered until its row below has
// arrived. Both counts come to exactly width*height, which is what keeps the
// two dataflow FIFOs from deadlocking.
//
// MODE_COLOR produces on the *consume* condition instead. It has no window and
// therefore owes no delay, so making it wait a line would only add latency --
// and, more to the point, the totals still come to width*height either way, so
// the FIFOs stay balanced whichever branch is taken.
// ---------------------------------------------------------------------------
static void window_filter(hls::stream<ap_uint<32> > &pix_s,
                          hls::stream<ap_uint<32> > &out_s,
                          int                        width,
                          int                        height,
                          int                        mode)
{
    static ap_uint<8> lb[2][MAX_WIDTH];
#pragma HLS ARRAY_PARTITION variable=lb complete dim=1
#pragma HLS BIND_STORAGE variable=lb type=ram_s2p impl=bram

    ap_uint<8> win[3][3];
#pragma HLS ARRAY_PARTITION variable=win complete dim=0

    // NOTE: there is deliberately no
    //     #pragma HLS DEPENDENCE variable=lb inter false
    // here. It is the obvious thing to write -- successive steps do address
    // successive columns, and it flattens the two loops into one II=1 pipeline
    // -- but it is not true. Step (r, c) writes lb[1][c] and step (r+1, c)
    // reads it back, and those are width+1 steps apart, while `inter false`
    // claims independence at *every* distance. With the loops flattened and the
    // pipeline several stages deep, any frame narrower than about twenty pixels
    // reads the line above before the write has landed and comes out one line
    // stale. C simulation cannot see it -- there is no pipeline in C.
    //
    // Without the pragma the column loop still pipelines at II=1; only the row
    // loop stops flattening, so the pipeline drains and refills once per line.
    // At 1080p that is a few thousand cycles a frame against a budget of two
    // million, and it happens where a video pipeline has slack anyway.

row_loop:
    for (int r = 0; r < height + 1; r++) {
#pragma HLS LOOP_TRIPCOUNT min=32 max=1081
    col_loop:
        for (int c = 0; c < width + 1; c++) {
#pragma HLS LOOP_TRIPCOUNT min=32 max=1921
#pragma HLS PIPELINE II=1

            const bool consume = (r < height && c < width);

            ap_uint<32> newpix = 0;
            if (consume)
                newpix = pix_s.read();

            // ITU-R BT.601 luma in Q8. The weights sum to 256, so white lands
            // on exactly 255 and no clamp is needed.
            ap_uint<8>  b = newpix.range(7, 0);
            ap_uint<8>  g = newpix.range(15, 8);
            ap_uint<8>  rr = newpix.range(23, 16);
            ap_uint<18> y = (ap_uint<18>)(LUMA_B * b + LUMA_G * g + LUMA_R * rr) >> 8;
            ap_uint<8>  newy = (ap_uint<8>)y;

            // shift the window one column to the left
            win[0][0] = win[0][1]; win[0][1] = win[0][2];
            win[1][0] = win[1][1]; win[1][1] = win[1][2];
            win[2][0] = win[2][1]; win[2][1] = win[2][2];

            if (c < width) {
                ap_uint<8> above2 = lb[0][c];   // row r-2
                ap_uint<8> above1 = lb[1][c];   // row r-1
                win[0][2] = above2;
                win[1][2] = above1;
                win[2][2] = newy;               // row r
                lb[0][c]  = above1;
                lb[1][c]  = newy;
            } else {
                // past the right edge: replicate so the window stays defined
                win[0][2] = win[0][1];
                win[1][2] = win[1][1];
                win[2][2] = win[2][1];
            }

            if (mode == MODE_COLOR) {
                if (consume)
                    out_s.write(newpix);
            } else if (r >= 1 && c >= 1) {
                const int out_r = r - 1;
                const int out_c = c - 1;
                ap_uint<8> v;

                if (mode == MODE_GRAY) {
                    v = win[1][1];
                } else if (mode == MODE_INVERT) {
                    v = (ap_uint<8>)(255 - win[1][1]);
                } else {
                    // Sobel is undefined on the one-pixel frame border, so it
                    // is black there rather than extended or replicated.
                    if (out_r == 0 || out_r == height - 1 ||
                        out_c == 0 || out_c == width - 1) {
                        v = 0;
                    } else {
                        int gx = (win[0][2] + 2 * win[1][2] + win[2][2])
                               - (win[0][0] + 2 * win[1][0] + win[2][0]);
                        int gy = (win[2][0] + 2 * win[2][1] + win[2][2])
                               - (win[0][0] + 2 * win[0][1] + win[0][2]);
                        int gxa = (gx < 0) ? -gx : gx;
                        int gya = (gy < 0) ? -gy : gy;
                        int mag = gxa + gya;
                        v = (ap_uint<8>)((mag > 255) ? 255 : mag);
                    }
                }

                ap_uint<32> px;
                px.range(7, 0)   = v;
                px.range(15, 8)  = v;
                px.range(23, 16) = v;
                px.range(31, 24) = 0xFF;
                out_s.write(px);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Stage 3: burst-write back to DDR.
// ---------------------------------------------------------------------------
static void write_pixels(hls::stream<ap_uint<32> > &out_s,
                         ap_uint<32>               *dst,
                         int                        width,
                         int                        height)
{
    const int n = width * height;
write_loop:
    for (int i = 0; i < n; i++) {
#pragma HLS LOOP_TRIPCOUNT min=1024 max=2073600
#pragma HLS PIPELINE II=1
        dst[i] = out_s.read();
    }
}

// ---------------------------------------------------------------------------
// Top level
// ---------------------------------------------------------------------------
// The argument names img_width / img_height matter -- a scalar argument named
// `width` collides with PYNQ's Register.width and makes register_map recurse
// to death. See the note in video_filter.hpp.
void video_filter(const ap_uint<32> *src,
                  ap_uint<32>       *dst,
                  int                img_width,
                  int                img_height,
                  int                mode)
{
#pragma HLS INTERFACE m_axi port=src offset=slave bundle=gmem0 \
    max_read_burst_length=256 num_read_outstanding=16 depth=COSIM_DEPTH
#pragma HLS INTERFACE m_axi port=dst offset=slave bundle=gmem1 \
    max_write_burst_length=256 num_write_outstanding=16 depth=COSIM_DEPTH

#pragma HLS INTERFACE s_axilite port=src        bundle=control
#pragma HLS INTERFACE s_axilite port=dst        bundle=control
#pragma HLS INTERFACE s_axilite port=img_width  bundle=control
#pragma HLS INTERFACE s_axilite port=img_height bundle=control
#pragma HLS INTERFACE s_axilite port=mode       bundle=control
#pragma HLS INTERFACE s_axilite port=return     bundle=control

#pragma HLS DATAFLOW

    hls::stream<ap_uint<32> > pix_s("pix_s");
#pragma HLS STREAM variable=pix_s depth=64
    hls::stream<ap_uint<32> > out_s("out_s");
#pragma HLS STREAM variable=out_s depth=64

    read_pixels(src, pix_s, img_width, img_height);
    window_filter(pix_s, out_s, img_width, img_height, mode);
    write_pixels(out_s, dst, img_width, img_height);
}
