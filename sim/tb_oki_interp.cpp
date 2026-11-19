// Clock driver for sim/tb_oki_interp.sv.
#include "Vtb_oki_interp.h"
#include "verilated.h"

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_oki_interp *t = new Vtb_oki_interp;
    while (!Verilated::gotFinish()) {
        t->clk = 0; t->eval();
        t->clk = 1; t->eval();
    }
    t->final();
    delete t;
    return 0;
}
