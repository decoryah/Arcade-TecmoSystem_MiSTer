#include "Vtb_raster.h"
#include "verilated.h"
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_raster *top = new Vtb_raster;
    top->clk = 0;
    top->eval();
    while (!Verilated::gotFinish()) {
        top->clk = !top->clk;
        top->eval();
    }
    top->final();
    delete top;
    return 0;
}
