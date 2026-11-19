// Whole-machine Verilator driver for tb_top: the 68000 and the Z80 run the real ROMs from reset through the SDRAM controller and model.
//
//   Vtb_top +IMAGE=<set.sdram> +HDR=<set.hdr> +FRAMES=<n> [+SNAPS=a,b,c|all] [+SNAPPFX=<prefix>] [+PROGRESS=n] [+WAV=<file>]
//           [+INPUTS=<file>: lines "frame p1hex p2hex", the values from that frame on]
//   +FRAMES   stop after n vertical blanks.  +SNAPS  write picture k (k counts the complete 320 x 240 pictures from reset) as <prefix>.pNNNNN.ppm.
//   +WAV      the 48 kHz stereo output as a 16-bit WAV.
//   +CHIPS    (tb_top.sv) the three sound chips' outputs at each 48 kHz sample, as text: "ymz_l ymz_r opl_l opl_r oki".
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>
#include "Vtb_top.h"
#include "verilated.h"

static Vtb_top* t;
static long long cycles;
static int opl_div;

static std::vector<uint8_t> cap(320 * 240 * 3);
static long pic_k = 0;
static std::set<long> snaps;
static bool snap_all;
static std::string snappfx;
static int snap_written;
static FILE* wav;
static long wav_n;
static long ee_n;

static void wav_header(FILE* f, long n) {
    uint32_t data = (uint32_t)(n * 4), riff = 36 + data, rate = 48000, br = 48000 * 4, fmt = 16;
    uint16_t pcm = 1, ch = 2, ba = 4, bits = 16;
    fseek(f, 0, SEEK_SET);
    fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f); fwrite(&fmt, 4, 1, f);
    fwrite(&pcm, 2, 1, f); fwrite(&ch, 2, 1, f); fwrite(&rate, 4, 1, f); fwrite(&br, 4, 1, f); fwrite(&ba, 2, 1, f); fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f);
}

static void tick() {
    t->clk = 1; t->eval();
    t->clk = 0; t->eval();
    cycles++;
    if (t->ee_written) ee_n++;
    if (++opl_div == 2) { opl_div = 0; t->clk_opl = !t->clk_opl; }     // 24 MHz = 96 / 4
    if (wav && t->audio_valid) {
        int16_t s[2] = { (int16_t)t->audio_l, (int16_t)t->audio_r };
        fwrite(s, 2, 2, wav); wav_n++;
    }
    if (t->o_ce && !t->o_hb && !t->o_vb && t->o_x < 320 && t->o_y < 240) {
        size_t p = (size_t)t->o_y * 320 + t->o_x;
        cap[p * 3 + 0] = t->o_r; cap[p * 3 + 1] = t->o_g; cap[p * 3 + 2] = t->o_b;
        if (t->o_x == 319 && t->o_y == 239) {
            if (snap_all || snaps.count(pic_k)) {
                char name[512];
                snprintf(name, sizeof name, "%s.p%05ld.ppm", snappfx.c_str(), pic_k);
                FILE* f = fopen(name, "wb");
                if (f) { fprintf(f, "P6\n320 240\n255\n"); fwrite(cap.data(), 1, cap.size(), f); fclose(f); snap_written++; }
            }
            pic_k++;
        }
    }
}

static const char* plus(int argc, char** argv, const char* key) {
    size_t n = strlen(key);
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], key, n)) return argv[i] + n;
    return nullptr;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* p;
    long last = (p = plus(argc, argv, "+FRAMES=")) ? atol(p) : 10;
    if ((p = plus(argc, argv, "+SNAPS="))) {
        if (!strcmp(p, "all")) snap_all = true;
        else { std::string x = p; size_t a = 0; while (a < x.size()) { size_t b = x.find(',', a); if (b == std::string::npos) b = x.size(); snaps.insert(atol(x.substr(a, b - a).c_str())); a = b + 1; } }
    }
    snappfx = (p = plus(argc, argv, "+SNAPPFX=")) ? p : "snap";
    long progress = (p = plus(argc, argv, "+PROGRESS=")) ? atol(p) : 0;
    if ((p = plus(argc, argv, "+WAV="))) { wav = fopen(p, "wb"); if (wav) wav_header(wav, 0); }
    std::map<long, std::pair<unsigned, unsigned>> inputs;
    if ((p = plus(argc, argv, "+INPUTS="))) {
        FILE* f = fopen(p, "r");
        long fr; unsigned a, b;
        if (f) { while (fscanf(f, "%ld %x %x", &fr, &a, &b) == 3) inputs[fr] = {a, b}; fclose(f); }
    }

    t = new Vtb_top;
    t->in_p1 = 0xffff; t->in_p2 = 0xffff;
    if ((p = plus(argc, argv, "+P1="))) t->in_p1 = strtoul(p, nullptr, 16);
    if ((p = plus(argc, argv, "+P2="))) t->in_p2 = strtoul(p, nullptr, 16);
    t->reset = 1; t->clk = 0; t->clk_opl = 0;
    for (int i = 0; i < 32; i++) tick();
    t->reset = 0;

    long frame = 0, lates = 0, wds = 0;
    bool fatal = false;
    int prev_late = 0;
    auto t0 = std::chrono::steady_clock::now();
    while (frame < last && !fatal) {
        tick();
        if (t->late && !prev_late) { printf("late line first seen at frame %ld (line %d)\n", frame, (int)t->o_y); lates++; }
        prev_late = t->late;
        if (t->wd_rst) { printf("watchdog reset at frame %ld\n", frame); wds++; }
        if (t->halted) { printf("68000 halted at frame %ld clock %lld\n", frame, cycles); fatal = true; }
        if (t->ev_vbl) {
            frame++;
            auto it = inputs.find(frame);
            if (it != inputs.end()) { t->in_p1 = it->second.first; t->in_p2 = it->second.second; }
            if (progress && frame % progress == 0) {
                double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
                printf("frame %ld  %.1f s  pictures %ld  68000 A=%06x  Z80 A=%04x  EEPROM writes %ld\n", frame, s, pic_k,
                       (unsigned)t->maddr, (unsigned)t->zpc, ee_n);
                fflush(stdout);
            }
        }
    }
    printf("done: %ld frames, %lld clocks, %ld pictures, %d snapshots, watchdog resets %ld\n", frame, cycles, pic_k, snap_written, wds);
    if (wav) { wav_header(wav, wav_n); fclose(wav); }
    t->final();
    delete t;
    return fatal ? 1 : 0;
}
