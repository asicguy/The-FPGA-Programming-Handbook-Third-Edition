// Self-contained testbench for the CH12 accelerator: it synthesises its own
// input, so csim and cosim need no external image files.
//
// The golden model here is a line-for-line transcription of
// sw/sobel_ref.py::filter_frame_naive. Two implementations of the same
// arithmetic in two languages is the point -- if they ever disagree, one of
// them is wrong and the notebook's bit-exact check on the board will say so.
//
// Keep TB_W/TB_H small: cosim is RTL-accurate and a full-HD frame would take
// hours.

#include "video_filter.hpp"
#include <cstdio>
#include <cstdlib>
#include <vector>

// TB_W / TB_H / COSIM_DEPTH come from video_filter.hpp, which is also where the
// m_axi depth pragmas read them from. If these ever disagree, cosim segfaults
// in ENTER_WRAPC rather than failing cleanly, so catch it at compile time.
static_assert(TB_W * TB_H == COSIM_DEPTH,
              "COSIM_DEPTH must equal TB_W*TB_H -- see video_filter.hpp");

// Pixels are B,G,R,A from the LSB up. See video_filter.hpp.
static inline unsigned char pix_b(unsigned int p) { return  p        & 0xFF; }
static inline unsigned char pix_g(unsigned int p) { return (p >>  8) & 0xFF; }
static inline unsigned char pix_r(unsigned int p) { return (p >> 16) & 0xFF; }

static inline unsigned int pack(unsigned char b, unsigned char g,
                                unsigned char r, unsigned char a)
{
    return ((unsigned int)a << 24) | ((unsigned int)r << 16)
         | ((unsigned int)g << 8)  | (unsigned int)b;
}

static unsigned char luma(unsigned int p)
{
    return (unsigned char)((LUMA_B * pix_b(p) + LUMA_G * pix_g(p)
                          + LUMA_R * pix_r(p)) >> 8);
}

// ---------------------------------------------------------------------------
// Golden model. Deliberately the obvious nested-loop version.
// ---------------------------------------------------------------------------
static void golden(const std::vector<unsigned int> &src,
                   std::vector<unsigned int>       &dst,
                   int W, int H, int mode)
{
    dst.assign((size_t)W * H, 0);

    if (mode == MODE_COLOR) {
        for (int i = 0; i < W * H; i++)
            dst[i] = src[i];
        return;
    }

    std::vector<unsigned char> g((size_t)W * H);
    for (int i = 0; i < W * H; i++)
        g[i] = luma(src[i]);

    for (int r = 0; r < H; r++) {
        for (int c = 0; c < W; c++) {
            unsigned char v;
            if (mode == MODE_GRAY) {
                v = g[r * W + c];
            } else if (mode == MODE_INVERT) {
                v = (unsigned char)(255 - g[r * W + c]);
            } else if (r == 0 || r == H - 1 || c == 0 || c == W - 1) {
                // A 3x3 window is undefined on the frame border, so it is
                // black there -- not extended, not replicated. Hardware and
                // software agree on that because neither invents a pixel.
                v = 0;
            } else {
                int p00 = g[(r-1)*W + c-1], p01 = g[(r-1)*W + c], p02 = g[(r-1)*W + c+1];
                int p10 = g[( r )*W + c-1],                       p12 = g[( r )*W + c+1];
                int p20 = g[(r+1)*W + c-1], p21 = g[(r+1)*W + c], p22 = g[(r+1)*W + c+1];
                int gx = (p02 + 2*p12 + p22) - (p00 + 2*p10 + p20);
                int gy = (p20 + 2*p21 + p22) - (p00 + 2*p01 + p02);
                int m  = abs(gx) + abs(gy);
                v = (unsigned char)(m > 255 ? 255 : m);
            }
            dst[r * W + c] = pack(v, v, v, 0xFF);
        }
    }
}

// ---------------------------------------------------------------------------
// Stimulus: a two-axis gradient with a hard-edged bright square in it, so
// Sobel has real edges to find rather than pure noise, and each channel
// carries something different so a swapped B and R does not go unnoticed.
// ---------------------------------------------------------------------------
static void make_scene(std::vector<unsigned int> &src, int W, int H)
{
    for (int r = 0; r < H; r++) {
        for (int c = 0; c < W; c++) {
            unsigned char B = (unsigned char)((c * 255) / (W > 1 ? W - 1 : 1));
            unsigned char G = (unsigned char)((r * 255) / (H > 1 ? H - 1 : 1));
            unsigned char R = 64;
            if (r > H / 4 && r < 3 * H / 4 && c > W / 4 && c < 3 * W / 4) {
                B = 240; G = 240; R = 240;
            }
            src[r * W + c] = pack(B, G, R, 0xFF);
        }
    }
}

static const char *mode_name(int mode)
{
    switch (mode) {
    case MODE_GRAY:   return "GRAY";
    case MODE_SOBEL:  return "SOBEL";
    case MODE_INVERT: return "INVERT";
    case MODE_COLOR:  return "COLOR";
    default:          return "?";
    }
}

static int run_case(int W, int H, int mode)
{
    // One allocation of exactly TB_W*TB_H, whatever the frame size under test.
    // The m_axi depth pragma promises cosim that these buffers are this big and
    // no bigger; allocating per-case would make that promise a lie in one
    // direction or the other.
    std::vector<unsigned int> src((size_t)TB_W * TB_H, 0);
    std::vector<unsigned int> got((size_t)TB_W * TB_H, 0);
    std::vector<unsigned int> ref;

    make_scene(src, W, H);
    golden(src, ref, W, H, mode);

    video_filter((const ap_uint<32> *)src.data(),
                 (ap_uint<32> *)got.data(),
                 W, H, mode);

    int errors = 0;
    for (int i = 0; i < W * H; i++) {
        if (ref[i] != got[i]) {
            if (errors < 8)
                printf("    MISMATCH @ (%d,%d): ref=0x%08X got=0x%08X\n",
                       i / W, i % W, ref[i], got[i]);
            errors++;
        }
    }
    printf("  [%-6s %4dx%-4d] %6d px  %s\n", mode_name(mode), W, H, W * H,
           errors ? "FAIL" : "PASS");
    return errors;
}

int main()
{
    // Every frame here fits in TB_W*TB_H words. The degenerate sizes are the
    // ones that matter: a filter whose iteration space is off by one still
    // produces a correct-looking picture at 64x48 and deadlocks at 1x1.
    static const int sizes[][2] = {
        {TB_W, TB_H},   // the full buffer
        {37, 23},       // both dimensions odd, neither a power of two
        {60, 50},       // 3000 words -- nearly the whole buffer
        {6, 5},         // small enough that a stale line buffer is visible
        {3, 3},         // exactly one interior pixel
        {2, 2},         // no interior at all
        {16, 1},        // single row
        {1, 16},        // single column
        {1, 1},         // single pixel
    };
    static const int modes[] = {MODE_GRAY, MODE_SOBEL, MODE_INVERT, MODE_COLOR};

    int errors = 0;
    int cases = 0;
    for (unsigned s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++) {
        for (unsigned m = 0; m < sizeof(modes) / sizeof(modes[0]); m++) {
            errors += run_case(sizes[s][0], sizes[s][1], modes[m]);
            cases++;
        }
    }

    printf("\n%d cases\n", cases);
    if (errors == 0) {
        printf("TEST PASSED\n");
        return 0;
    }
    printf("TEST FAILED (%d total mismatches)\n", errors);
    return 1;
}
