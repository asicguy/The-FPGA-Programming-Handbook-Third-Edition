// Self-contained testbench: synthesises its own input, so csim/cosim need no
// external image files. Keep TB_W/TB_H small -- cosim is RTL-accurate and a
// full-HD frame would take hours.

#include "image_filter.hpp"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>

// TB_W / TB_H / COSIM_DEPTH come from image_filter.hpp, which is also where the
// m_axi depth pragmas read them from. If these ever disagree, cosim segfaults
// in ENTER_WRAPC rather than failing cleanly, so catch it at compile time.
static_assert(TB_W * TB_H == COSIM_DEPTH,
              "COSIM_DEPTH must equal TB_W*TB_H -- see image_filter.hpp");

static unsigned char luma(unsigned char r, unsigned char g, unsigned char b)
{
    return (unsigned char)((77 * r + 150 * g + 29 * b) >> 8);
}

// Golden software model
static void golden(const std::vector<unsigned int> &src,
                   std::vector<unsigned int>       &dst,
                   int W, int H, int mode)
{
    std::vector<unsigned char> g(W * H);
    for (int i = 0; i < W * H; i++) {
        unsigned int p = src[i];
        g[i] = luma(p & 0xFF, (p >> 8) & 0xFF, (p >> 16) & 0xFF);
    }

    std::vector<unsigned char> o(W * H, 0);
    for (int r = 0; r < H; r++) {
        for (int c = 0; c < W; c++) {
            unsigned char v;
            if (mode == MODE_GRAY) {
                v = g[r * W + c];
            } else if (mode == MODE_INVERT) {
                v = (unsigned char)(255 - g[r * W + c]);
            } else {
                if (r == 0 || r == H - 1 || c == 0 || c == W - 1) {
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
            }
            o[r * W + c] = v;
        }
    }

    dst.assign(W * H, 0);
    for (int i = 0; i < W * H; i++)
        dst[i] = (0xFFu << 24) | (o[i] << 16) | (o[i] << 8) | o[i];
}

static int run_mode(int mode, const char *name)
{
    std::vector<unsigned int> src(TB_W * TB_H);
    std::vector<unsigned int> ref, got(TB_W * TB_H, 0);

    // Synthetic scene: gradient background with a hard-edged bright square,
    // so Sobel has real edges to find rather than pure noise.
    for (int r = 0; r < TB_H; r++) {
        for (int c = 0; c < TB_W; c++) {
            unsigned char R = (unsigned char)((c * 255) / (TB_W - 1));
            unsigned char G = (unsigned char)((r * 255) / (TB_H - 1));
            unsigned char B = (unsigned char)(((r + c) * 255) / (TB_W + TB_H - 2));
            if (r > TB_H / 4 && r < 3 * TB_H / 4 && c > TB_W / 4 && c < 3 * TB_W / 4) {
                R = 240; G = 240; B = 240;
            }
            src[r * TB_W + c] = (0xFFu << 24) | (B << 16) | (G << 8) | R;
        }
    }

    golden(src, ref, TB_W, TB_H, mode);

    image_filter((const ap_uint<32> *)src.data(),
                 (ap_uint<32> *)got.data(),
                 TB_W, TB_H, mode);

    int errors = 0;
    for (int i = 0; i < TB_W * TB_H; i++) {
        if (ref[i] != got[i]) {
            if (errors < 8)
                printf("  MISMATCH @ (%d,%d): ref=0x%08X got=0x%08X\n",
                       i / TB_W, i % TB_W, ref[i], got[i]);
            errors++;
        }
    }
    printf("[%-6s] %d/%d pixels wrong\n", name, errors, TB_W * TB_H);
    return errors;
}

int main()
{
    int errors = 0;
    errors += run_mode(MODE_GRAY,   "GRAY");
    errors += run_mode(MODE_SOBEL,  "SOBEL");
    errors += run_mode(MODE_INVERT, "INVERT");

    if (errors == 0) {
        printf("TEST PASSED\n");
        return 0;
    }
    printf("TEST FAILED (%d total mismatches)\n", errors);
    return 1;
}
