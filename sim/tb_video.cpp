// Driver of the frozen-state video bench (tb_video.sv): runs to the second vertical blank and compares the picture scanned out between the
// first and the second with MAME's (+MAMERGB=<fNNNNN.rgb>), writing it as +OUT=<file.ppm>.  Exit code 0 if the pictures are identical.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "Vtb_video.h"
#include "verilated.h"

static const char* plus(int argc, char** argv, const char* key) {
    size_t n = strlen(key);
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], key, n)) return argv[i] + n;
    return nullptr;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* mame = plus(argc, argv, "+MAMERGB=");
    const char* outp = plus(argc, argv, "+OUT=");
    std::vector<uint8_t> pic(320 * 240 * 3, 0);
    Vtb_video* t = new Vtb_video;
    t->reset = 1; t->clk = 0;
    for (int i = 0; i < 16; i++) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
    t->reset = 0;
    int vbl = 0;
    long long cyc = 0;
    int late = 0;
    while (vbl < 2 && cyc < 20000000) {
        t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++;
        if (t->ev_vbl) vbl++;
        if (t->late) late = 1;
        if (vbl == 1 && t->o_ce && !t->o_hb && !t->o_vb && t->o_x < 320 && t->o_y < 240) {
            size_t p = ((size_t)t->o_y * 320 + t->o_x) * 3;
            pic[p] = t->o_r; pic[p + 1] = t->o_g; pic[p + 2] = t->o_b;
        }
    }
    t->final();
    if (outp) { FILE* f = fopen(outp, "wb"); if (f) { fprintf(f, "P6\n320 240\n255\n"); fwrite(pic.data(), 1, pic.size(), f); fclose(f); } }
    int diff = -1;
    if (mame) {
        std::vector<uint8_t> m(320 * 240 * 3);
        FILE* f = fopen(mame, "rb");
        if (f && fread(m.data(), 1, m.size(), f) == m.size()) {
            diff = 0;
            int first = -1;
            for (int i = 0; i < 320 * 240; i++)
                if (memcmp(&m[i * 3], &pic[i * 3], 3)) { if (first < 0) first = i; diff++; }
            if (first >= 0) printf("first difference at (%d, %d): MAME %02x%02x%02x RTL %02x%02x%02x\n", first % 320, first / 320,
                                   m[first * 3], m[first * 3 + 1], m[first * 3 + 2], pic[first * 3], pic[first * 3 + 1], pic[first * 3 + 2]);
        }
        if (f) fclose(f);
    }
    printf("RESULT %d pixels differ%s\n", diff, late ? " (a line was late)" : "");
    delete t;
    return diff == 0 ? 0 : 1;
}
