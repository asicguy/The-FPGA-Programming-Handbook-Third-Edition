#include "image_filter.hpp"
#include <hls_stream.h>

// ---------------------------------------------------------------------------
// Stage 1: burst-read packed RGBA from DDR, convert to 8-bit luma, push to FIFO
// ---------------------------------------------------------------------------
static void read_and_gray(const ap_uint<32>      *src,
                          hls::stream<ap_uint<8> > &gray_s,
                          int                     width,
                          int                     height)
{
    const int n = width * height;
read_loop:
    for (int i = 0; i < n; i++) {
#pragma HLS LOOP_TRIPCOUNT min=1024 max=2073600
#pragma HLS PIPELINE II=1
        ap_uint<32> px = src[i];
        ap_uint<8>  r  = px.range(7, 0);
        ap_uint<8>  g  = px.range(15, 8);
        ap_uint<8>  b  = px.range(23, 16);
        // ITU-R BT.601 luma in Q8 fixed point: 0.299/0.587/0.114 -> 77/150/29
        ap_uint<18> y = (ap_uint<18>)(77 * r + 150 * g + 29 * b) >> 8;
        gray_s.write((ap_uint<8>)y);
    }
}

// ---------------------------------------------------------------------------
// Stage 2: 3x3 sliding window over a 2-row line buffer.
//
// The iteration space is (height+1) x (width+1). A pixel is consumed whenever
// (r < height && c < width) and a pixel is produced whenever (r >= 1 && c >= 1),
// so reads and writes both total exactly width*height -- which is what keeps
// the dataflow FIFOs from deadlocking. The window centre win[1][1] at step
// (r, c) holds input pixel (r-1, c-1).
// ---------------------------------------------------------------------------
static void window_filter(hls::stream<ap_uint<8> > &gray_s,
                          hls::stream<ap_uint<8> > &out_s,
                          int                     width,
                          int                     height,
                          int                     mode)
{
    static ap_uint<8> lb[2][MAX_WIDTH];
#pragma HLS ARRAY_PARTITION variable=lb complete dim=1
#pragma HLS BIND_STORAGE variable=lb type=ram_s2p impl=bram

    ap_uint<8> win[3][3];
#pragma HLS ARRAY_PARTITION variable=win complete dim=0

row_loop:
    for (int r = 0; r < height + 1; r++) {
#pragma HLS LOOP_TRIPCOUNT min=32 max=1081
    col_loop:
        for (int c = 0; c < width + 1; c++) {
#pragma HLS LOOP_TRIPCOUNT min=32 max=1921
#pragma HLS PIPELINE II=1
#pragma HLS DEPENDENCE variable=lb inter false

            ap_uint<8> newpx = 0;
            if (r < height && c < width)
                newpx = gray_s.read();

            // shift the window one column to the left
            win[0][0] = win[0][1]; win[0][1] = win[0][2];
            win[1][0] = win[1][1]; win[1][1] = win[1][2];
            win[2][0] = win[2][1]; win[2][1] = win[2][2];

            if (c < width) {
                ap_uint<8> above2 = lb[0][c];   // row r-2
                ap_uint<8> above1 = lb[1][c];   // row r-1
                win[0][2] = above2;
                win[1][2] = above1;
                win[2][2] = newpx;              // row r
                lb[0][c]  = above1;
                lb[1][c]  = newpx;
            } else {
                // past the right edge: replicate so the window stays defined
                win[0][2] = win[0][1];
                win[1][2] = win[1][1];
                win[2][2] = win[2][1];
            }

            if (r >= 1 && c >= 1) {
                const int out_r = r - 1;
                const int out_c = c - 1;
                ap_uint<8> v;

                if (mode == MODE_GRAY) {
                    v = win[1][1];
                } else if (mode == MODE_INVERT) {
                    v = (ap_uint<8>)(255 - win[1][1]);
                } else {
                    // Sobel: undefined on the 1px frame, emit black there
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
                out_s.write(v);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Stage 3: replicate luma across R,G,B, force alpha opaque, burst-write to DDR
// ---------------------------------------------------------------------------
static void write_rgba(hls::stream<ap_uint<8> > &out_s,
                       ap_uint<32>             *dst,
                       int                      width,
                       int                      height)
{
    const int n = width * height;
write_loop:
    for (int i = 0; i < n; i++) {
#pragma HLS LOOP_TRIPCOUNT min=1024 max=2073600
#pragma HLS PIPELINE II=1
        ap_uint<8>  v = out_s.read();
        ap_uint<32> px;
        px.range(7, 0)   = v;
        px.range(15, 8)  = v;
        px.range(23, 16) = v;
        px.range(31, 24) = 0xFF;
        dst[i] = px;
    }
}

// ---------------------------------------------------------------------------
// Top level
// ---------------------------------------------------------------------------
// The argument names img_width / img_height matter -- a scalar argument named
// `width` collides with PYNQ's Register.width and makes register_map recurse
// to death. See the note in image_filter.hpp.
void image_filter(const ap_uint<32> *src,
                  ap_uint<32>       *dst,
                  int                img_width,
                  int                img_height,
                  int                mode)
{
#pragma HLS INTERFACE m_axi port=src offset=slave bundle=gmem0 \
    max_read_burst_length=256 num_read_outstanding=16 depth=COSIM_DEPTH
#pragma HLS INTERFACE m_axi port=dst offset=slave bundle=gmem1 \
    max_write_burst_length=256 num_write_outstanding=16 depth=COSIM_DEPTH

#pragma HLS INTERFACE s_axilite port=src    bundle=control
#pragma HLS INTERFACE s_axilite port=dst    bundle=control
#pragma HLS INTERFACE s_axilite port=img_width  bundle=control
#pragma HLS INTERFACE s_axilite port=img_height bundle=control
#pragma HLS INTERFACE s_axilite port=mode       bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control

#pragma HLS DATAFLOW

    hls::stream<ap_uint<8> > gray_s("gray_s");
#pragma HLS STREAM variable=gray_s depth=64
    hls::stream<ap_uint<8> > out_s("out_s");
#pragma HLS STREAM variable=out_s depth=64

    read_and_gray(src, gray_s, img_width, img_height);
    window_filter(gray_s, out_s, img_width, img_height, mode);
    write_rgba(out_s, dst, img_width, img_height);
}
