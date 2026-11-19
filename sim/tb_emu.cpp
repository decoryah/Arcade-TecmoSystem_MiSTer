// Driver of the MiSTer-top bench (tb_emu_top.sv): plays the stream, verifies the SDRAM when the core is released, runs +FRAMES= more frames
// and writes +SNAPS= pictures (<SNAPPFX>.pNNNNN.ppm, counted from the release).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>
#include "Vtb_emu_top.h"
#include "verilated.h"

static const char* plus(int argc, char** argv, const char* key) {
    size_t n = strlen(key);
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], key, n)) return argv[i] + n;
    return nullptr;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* p;
    long frames = (p = plus(argc, argv, "+FRAMES=")) ? atol(p) : 2;
    std::string pfx = (p = plus(argc, argv, "+SNAPPFX=")) ? p : "emu";
    std::set<long> snaps;
    if ((p = plus(argc, argv, "+SNAPS="))) { std::string x = p; size_t a = 0; while (a < x.size()) { size_t b = x.find(',', a); if (b == std::string::npos) b = x.size(); snaps.insert(atol(x.substr(a, b - a).c_str())); a = b + 1; } }
    Vtb_emu_top* t = new Vtb_emu_top;
    t->joy_en = 0; t->joy0 = 0; t->joy1 = 0;
    t->reset = 1; t->clk = 0;
    for (int i = 0; i < 64; i++) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
    t->reset = 0;
    std::vector<uint8_t> pic(320 * 240 * 3);
    long long cyc = 0;
    long frame = -1, pk = 0;
    bool released = false;
    while (frame < frames) {
        t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++;
        if (!released && t->verified) { released = true; frame = 0; printf("core released at clock %lld\n", cyc); fflush(stdout); }
        if (released && t->ev_vbl) frame++;
        if (released && t->o_ce && !t->o_hb && !t->o_vb && t->o_x < 320 && t->o_y < 240) {
            size_t q = ((size_t)t->o_y * 320 + t->o_x) * 3;
            pic[q] = t->o_r; pic[q + 1] = t->o_g; pic[q + 2] = t->o_b;
            if (t->o_x == 319 && t->o_y == 239) {
                if (snaps.count(pk)) {
                    char name[512]; snprintf(name, sizeof name, "%s.p%05ld.ppm", pfx.c_str(), pk);
                    FILE* f = fopen(name, "wb"); if (f) { fprintf(f, "P6\n320 240\n255\n"); fwrite(pic.data(), 1, pic.size(), f); fclose(f); }
                }
                pk++;
            }
        }
        if (cyc % 50000000 == 0) { printf("clock %lld, frame %ld\n", cyc, frame); fflush(stdout); }
    }
    printf("done: %lld clocks, %ld frames after the release, %ld pictures\n", cyc, frame, pk);
    t->final();
    delete t;
    return 0;
}
