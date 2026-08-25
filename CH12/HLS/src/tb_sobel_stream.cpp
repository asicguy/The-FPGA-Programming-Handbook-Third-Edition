// Self-contained testbench for the streaming Sobel filter: it synthesises its
// own frames, so csim and cosim need no external image files.
//
// What it checks, per case:
//   * every output pixel against a software golden model
//   * the beat count -- a streaming filter that emits the wrong number of beats
//     wedges the VDMA rather than producing wrong pixels, so this matters more
//     than it does for a memory-mapped accelerator
//   * TUSER on exactly the first beat of the frame, and TLAST on exactly the
//     last beat of every line
//
// Keep the frames small. cosim is RTL-accurate and a 1080p frame would take
// hours; the geometry is what is being tested, not the resolution.

#include "sobel_stream.hpp"
#include <cstdio>
#include <cstdlib>
#include <vector>

// ---------------------------------------------------------------------------
// BT.601 luma, Q8 fixed point: 0.299/0.587/0.114 -> 77/150/29. Identical to
// CH11's, so the two chapters' outputs can be compared pixel for pixel.
// ---------------------------------------------------------------------------
static unsigned char luma(unsigned char b, unsigned char g, unsigned char r)
{
    return (unsigned char)((77 * r + 150 * g + 29 * b) >> 8);
}

// A frame in software: W*H pixels, each a 24-bit BGR value with B in the low
// byte, matching one half of a 48-bit beat.
typedef std::vector<unsigned int> frame_t;

// ---------------------------------------------------------------------------
// Golden software model. A transcription of CH11's, with two differences that
// both come from being a video filter rather than a DDR one: the input is BGR
// rather than RGBA, and MODE_COLOR passes the pixel through untouched.
// ---------------------------------------------------------------------------
static void golden(const frame_t &src, frame_t &dst, int W, int H, int mode)
{
    if (mode == MODE_COLOR) {
        dst = src;
        return;
    }

    std::vector<unsigned char> g(W * H);
    for (int i = 0; i < W * H; i++) {
        unsigned int p = src[i];
        g[i] = luma(p & 0xFF, (p >> 8) & 0xFF, (p >> 16) & 0xFF);
    }

    dst.assign(W * H, 0);
    for (int r = 0; r < H; r++) {
        for (int c = 0; c < W; c++) {
            unsigned char v;
            if (mode == MODE_GRAY) {
                v = g[r * W + c];
            } else if (mode == MODE_INVERT) {
                v = (unsigned char)(255 - g[r * W + c]);
            } else {
                // Sobel is undefined on the one-pixel frame; emit black there.
                if (r == 0 || r == H - 1 || c == 0 || c == W - 1) {
                    v = 0;
                } else {
                    int p00 = g[(r-1)*W + c-1], p01 = g[(r-1)*W + c], p02 = g[(r-1)*W + c+1];
                    int p10 = g[( r )*W + c-1],                       p12 = g[( r )*W + c+1];
                    int p20 = g[(r+1)*W + c-1], p21 = g[(r+1)*W + c], p22 = g[(r+1)*W + c+1];
                    int gx  = (p02 + 2*p12 + p22) - (p00 + 2*p10 + p20);
                    int gy  = (p20 + 2*p21 + p22) - (p00 + 2*p01 + p02);
                    int m   = abs(gx) + abs(gy);
                    v = (unsigned char)(m > 255 ? 255 : m);
                }
            }
            // luma replicated across B, G and R
            dst[r * W + c] = (v << 16) | (v << 8) | v;
        }
    }
}

// ---------------------------------------------------------------------------
// Synthetic scene: a gradient with a hard-edged bright square in the middle, so
// Sobel has real edges to find rather than pure noise, plus a deterministic
// pseudo-random speckle so that neighbouring pixels differ everywhere.
// ---------------------------------------------------------------------------
static void make_frame(frame_t &f, int W, int H, unsigned seed)
{
    f.assign(W * H, 0);
    unsigned lfsr = seed | 1u;
    for (int r = 0; r < H; r++) {
        for (int c = 0; c < W; c++) {
            lfsr = lfsr * 1103515245u + 12345u;
            unsigned char noise = (unsigned char)((lfsr >> 16) & 0x1F);
            int B = (W > 1) ? (c * 200) / (W - 1) : 0;
            int G = (H > 1) ? (r * 200) / (H - 1) : 0;
            int R = ((r + c) * 200) / (W + H > 2 ? W + H - 2 : 1);
            if (r > H / 4 && r < 3 * H / 4 && c > W / 4 && c < 3 * W / 4) {
                B = 240; G = 240; R = 240;
            }
            B = (B + noise) & 0xFF;
            G = (G + noise) & 0xFF;
            R = (R + noise) & 0xFF;
            f[r * W + c] = (R << 16) | (G << 8) | B;
        }
    }
}

// ---------------------------------------------------------------------------
// One case: push a frame in, pull a frame out, compare everything.
// ---------------------------------------------------------------------------
static int run_case(int W, int H, int mode, const char *name)
{
    const int beats = (W / 2) * H;

    frame_t src, ref;
    make_frame(src, W, H, (unsigned)(W * 7919 + H * 104729 + mode));
    golden(src, ref, W, H, mode);

    video_stream sin("sin"), sout("sout");

    for (int r = 0; r < H; r++) {
        for (int b = 0; b < W / 2; b++) {
            video_pixel p;
            p.data = ((ap_uint<48>)src[r * W + 2 * b + 1] << 24) |
                      (ap_uint<48>)src[r * W + 2 * b];
            p.keep = -1;
            p.strb = -1;
            p.user = (r == 0 && b == 0) ? 1 : 0;
            p.last = (b == W / 2 - 1) ? 1 : 0;
            sin.write(p);
        }
    }

    sobel_stream(sin, sout, W, H, mode);

    int errors = 0;

    if ((int)sout.size() != beats) {
        printf("  [%s] BEAT COUNT: expected %d, got %d\n",
               name, beats, (int)sout.size());
        errors++;
    }
    if (!sin.empty()) {
        printf("  [%s] %d input beats left unread\n", name, (int)sin.size());
        errors++;
    }

    for (int r = 0; r < H && !sout.empty(); r++) {
        for (int b = 0; b < W / 2 && !sout.empty(); b++) {
            video_pixel p = sout.read();

            unsigned int got0 = (unsigned int)p.data(23, 0);
            unsigned int got1 = (unsigned int)p.data(47, 24);
            unsigned int exp0 = ref[r * W + 2 * b];
            unsigned int exp1 = ref[r * W + 2 * b + 1];

            if (got0 != exp0 || got1 != exp1) {
                if (errors < 8)
                    printf("  [%s] MISMATCH @ (%d,%d): exp %06X %06X got %06X %06X\n",
                           name, r, 2 * b, exp0, exp1, got0, got1);
                errors++;
            }

            int want_user = (r == 0 && b == 0) ? 1 : 0;
            int want_last = (b == W / 2 - 1) ? 1 : 0;
            if ((int)p.user != want_user) {
                if (errors < 8)
                    printf("  [%s] TUSER @ (%d,%d): expected %d, got %d\n",
                           name, r, 2 * b, want_user, (int)p.user);
                errors++;
            }
            if ((int)p.last != want_last) {
                if (errors < 8)
                    printf("  [%s] TLAST @ (%d,%d): expected %d, got %d\n",
                           name, r, 2 * b, want_last, (int)p.last);
                errors++;
            }
        }
    }

    printf("  [%-18s] %4d x %-4d  %6d beats  %s\n",
           name, W, H, beats, errors ? "FAIL" : "PASS");
    return errors;
}

int main()
{
    int errors = 0;

    errors += run_case(64, 48, MODE_GRAY,   "GRAY 64x48");
    errors += run_case(64, 48, MODE_SOBEL,  "SOBEL 64x48");
    errors += run_case(64, 48, MODE_INVERT, "INVERT 64x48");
    errors += run_case(64, 48, MODE_COLOR,  "COLOR 64x48");

    // Degenerate geometries. A streaming window filter fails on these long
    // before it fails on a real frame: one line means every output row is a
    // border row, and one beat per line means the two Sobel windows in a beat
    // are both against an edge.
    errors += run_case(2,  2,  MODE_SOBEL,  "SOBEL 2x2");
    errors += run_case(2,  16, MODE_SOBEL,  "SOBEL 2x16");
    errors += run_case(16, 1,  MODE_SOBEL,  "SOBEL 16x1");
    errors += run_case(16, 3,  MODE_SOBEL,  "SOBEL 16x3");
    errors += run_case(6,  5,  MODE_GRAY,   "GRAY 6x5");

    // Mode 7 is not a defined mode. The C tests == MODE_GRAY, == MODE_INVERT
    // and == MODE_COLOR, and everything else falls through to Sobel; the RTL
    // has to compare the whole 32-bit word to match, not just the low bits.
    errors += run_case(32, 24, 7,           "MODE7->SOBEL");

    // A wide-ish frame, to exercise the line buffers at a realistic depth.
    errors += run_case(320, 8, MODE_SOBEL,  "SOBEL 320x8");

    if (errors == 0) {
        printf("TEST PASSED\n");
        return 0;
    }
    printf("TEST FAILED (%d total errors)\n", errors);
    return 1;
}
