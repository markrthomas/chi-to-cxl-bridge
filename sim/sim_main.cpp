// Verilator coverage harness for chi_to_cxl_bridge.
//
// Dual-clock: host side clk = 10 time-units period, CXL cxl_clk = 14 (an
// asynchronous ~1.4:1 ratio, to exercise the Gray-code async FIFOs / CDC).
// This driver does not self-check (the directed TB owns correctness); its job
// is to walk the RTL through every opcode, both flow-control FIFOs to full and
// back to empty, the CRC-mismatch INVALID path, the error-injection window, and
// a link-down drain so `make coverage` emits meaningful coverage.
//
// Run from the Verilator --Mdir (cwd holds coverage.dat); the root Makefile
// then feeds coverage.dat to verilator_coverage --write-info.

#include "Vchi_to_cxl_bridge.h"
#include "verilated.h"
#include "verilated_cov.h"
#if VM_TRACE
#include "verilated_vcd_c.h"  // built with `verilator --trace` (make vlt-vcd)
#endif

#include <cstdint>
#include <cstdio>
#include <cstring>

// ---- packet kinds / opcodes (mirror src/chi_to_cxl_bridge_defs.vh) ----
enum {
    KIND_CHI_READ = 0x1, KIND_CHI_WRITE = 0x2, KIND_CHI_ATOMIC = 0x3, KIND_CHI_DATALESS = 0x4,
    KIND_DRS = 0xa, KIND_NDR = 0xb, KIND_DBID = 0xc, KIND_CXL_ERROR = 0xe,
};
enum { RD_NOSNP = 0x0, RD_ONCE = 0x1 };
enum { WR_NOSNP = 0x0, WR_UNIQUE = 0x1, WR_PTL = 0x2 };
enum { RSP_OK = 0x1, RSP_ERR = 0x2 };

static uint64_t pack(uint8_t kind, uint8_t code, uint8_t tag, uint16_t addr,
                     uint8_t len, uint8_t id, uint8_t aux, uint8_t misc) {
    return ((uint64_t)(kind & 0xF) << 60) | ((uint64_t)(code & 0xF) << 56) |
           ((uint64_t)tag << 48) | ((uint64_t)addr << 32) | ((uint64_t)len << 24) |
           ((uint64_t)id << 16) | ((uint64_t)aux << 8) | (uint64_t)misc;
}

// CRC-8/CCITT (poly 0x07, init 0x00) over header bytes [63:8]; matches
// bridge_checksum / crc8_step in the defs header.
static uint8_t crc8_step(uint8_t b) {
    for (int i = 0; i < 8; ++i) b = (b & 0x80) ? ((b << 1) ^ 0x07) : (b << 1);
    return b;
}
static uint64_t with_checksum(uint64_t p) {
    p &= ~0xFFull;
    uint8_t c = 0;
    for (int sh = 56; sh >= 8; sh -= 8) c = crc8_step(c ^ (uint8_t)((p >> sh) & 0xFF));
    return p | c;
}

// req (CHI->CXL) stimulus: every kind + opcode, plus an invalid kind (0x0).
static const uint64_t REQ[] = {
    pack(KIND_CHI_READ,     RD_NOSNP,  0x10, 0x1000, 0x04, 0xA1, 0x00, 0),
    pack(KIND_CHI_READ,     RD_ONCE,   0x11, 0x1040, 0x04, 0xA2, 0x01, 0),
    pack(KIND_CHI_WRITE,    WR_NOSNP,  0x12, 0x2000, 0x08, 0xB1, 0x00, 0),
    pack(KIND_CHI_WRITE,    WR_UNIQUE, 0x13, 0x2080, 0x08, 0xB2, 0x01, 0),
    pack(KIND_CHI_WRITE,    WR_PTL,    0x14, 0x20C0, 0x02, 0xB3, 0x0F, 0),
    pack(KIND_CHI_ATOMIC,   0x0,       0x15, 0x0003, 0x00, 0xC1, 0x00, 0),
    pack(KIND_CHI_DATALESS, 0x0,       0x16, 0x0003, 0x5A, 0xC2, 0x00, 0),
    pack(0x0,               0x0,       0x17, 0x0000, 0x00, 0x00, 0x00, 0), // invalid kind
};
static const int N_REQ = sizeof(REQ) / sizeof(REQ[0]);

// rsp (CXL->CHI) stimulus: ok/err for each response kind, an ERROR flit, plus a
// deliberately CRC-corrupted flit to drive the INVALID-completion path.
static const uint64_t RSP[] = {
    with_checksum(pack(KIND_DRS,       RSP_OK,  0x10, 0x0040, 0x04, 0xA1, 0x00, 0)),
    with_checksum(pack(KIND_NDR,       RSP_OK,  0x12, 0x0040, 0x08, 0xB1, 0x00, 0)),
    with_checksum(pack(KIND_DBID,      RSP_OK,  0x15, 0x0002, 0x00, 0xC1, 0x00, 0)),
    with_checksum(pack(KIND_DRS,       RSP_ERR, 0x11, 0x0040, 0x04, 0xA2, 0x00, 0)),
    with_checksum(pack(KIND_CXL_ERROR, 0x0,     0x13, 0x0000, 0x00, 0x00, 0x00, 0)),
    with_checksum(pack(KIND_DRS,       RSP_OK,  0x14, 0x0040, 0x02, 0xB3, 0x00, 0)) ^ 0xAB, // bad CRC -> INVALID (DRS)
    with_checksum(pack(KIND_NDR,       RSP_OK,  0x16, 0x0040, 0x08, 0xB2, 0x00, 0)) ^ 0xAB, // bad CRC -> INVALID (NDR)
    with_checksum(pack(KIND_DBID,      RSP_OK,  0x17, 0x0002, 0x00, 0xC2, 0x00, 0)) ^ 0xAB, // bad CRC -> INVALID (DBID)
};
static const int N_RSP = sizeof(RSP) / sizeof(RSP[0]);

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vchi_to_cxl_bridge* dut = new Vchi_to_cxl_bridge;

#if VM_TRACE
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    const char* vcd_path = "waves.vcd";
    for (int i = 1; i < argc; ++i)
        if (!strncmp(argv[i], "+vcd=", 5)) vcd_path = argv[i] + 5;
    tfp->open(vcd_path);
#endif

    dut->rst_n = 0;
    dut->clk = 0;
    dut->cxl_clk = 0;
    dut->link_up = 0;
    dut->err_inj_en = 0;
    dut->chi_req_valid = 0;
    dut->chi_req_data = 0;
    dut->cxl_rx_valid = 0;
    dut->cxl_rx_data = 0;
    dut->cxl_tx_ready = 1;
    dut->chi_rsp_ready = 1;
    dut->eval();

    const int CLK_H = 5;       // clk half-period (period 10)
    const int CXL_H = 7;       // cxl_clk half-period (period 14, async to clk)
    const uint64_t T_END = 200000;

    int prev_clk = 0, prev_cxl = 0;
    long clk_cyc = 0, cxl_cyc = 0;
    int req_i = 0, rsp_i = 0;
    int prev_chi_req_ready = 0, prev_cxl_rx_ready = 0;

    for (uint64_t t = 1; t < T_END && !Verilated::gotFinish(); ++t) {
        int clk = (int)((t / CLK_H) & 1);
        int cxl = (int)((t / CXL_H) & 1);

        // Async control sequencing, keyed on host-clock cycles.
        if (clk_cyc >= 20)  dut->rst_n = 1;
        if (clk_cyc >= 40)  dut->link_up = 1;
        dut->err_inj_en = (clk_cyc >= 1500 && clk_cyc < 1600) ? 1 : 0;
        if (clk_cyc >= 3000 && clk_cyc < 3300) dut->link_up = 0; // drain window
        else if (clk_cyc >= 3300)              dut->link_up = 1; // bring link back

        dut->clk = clk;
        dut->cxl_clk = cxl;
        dut->eval();
#if VM_TRACE
        tfp->dump((uint64_t)t);
#endif

        int clk_rise = (clk == 1 && prev_clk == 0);
        int cxl_rise = (cxl == 1 && prev_cxl == 0);

        if (clk_rise) {
            ++clk_cyc;
            // Backpressure the req output (cxl_tx) hard for a window so the
            // posted / non-posted FIFOs fill and chi_req_ready deasserts.
            dut->cxl_tx_ready = (clk_cyc >= 500 && clk_cyc < 700) ? 0
                              : ((clk_cyc & 3) != 0);
            // Drive the upstream request stream as a protocol-compliant producer:
            // valid/data only change after a handshake or while idle.
            int accepted = dut->chi_req_valid && prev_chi_req_ready;
            if (accepted) req_i = (req_i + 1) % N_REQ;
            if (!dut->chi_req_valid || accepted) {
                int active = (clk_cyc >= 50);
                int gap = ((clk_cyc % 5) == 4);
                dut->chi_req_valid = active && !gap;
                dut->chi_req_data = REQ[req_i];
            }
        }

        if (cxl_rise) {
            ++cxl_cyc;
            // Backpressure the rsp output (chi_rsp) for a window so the
            // response FIFO fills and cxl_rx_ready deasserts.
            dut->chi_rsp_ready = (cxl_cyc >= 900 && cxl_cyc < 1100) ? 0
                               : ((cxl_cyc & 3) != 0);
            int r_accepted = dut->cxl_rx_valid && prev_cxl_rx_ready;
            if (r_accepted) rsp_i = (rsp_i + 1) % N_RSP;
            if (!dut->cxl_rx_valid || r_accepted) {
                int active = (cxl_cyc >= 40);
                int gap = ((cxl_cyc % 4) == 3);
                dut->cxl_rx_valid = active && !gap;
                dut->cxl_rx_data = RSP[rsp_i];
            }
        }

        prev_clk = clk;
        prev_cxl = cxl;
        prev_chi_req_ready = dut->chi_req_ready;
        prev_cxl_rx_ready = dut->cxl_rx_ready;
    }

    dut->final();
#if VM_TRACE
    tfp->close();
    delete tfp;
    printf("[sim_cov] VCD written to %s\n", vcd_path);
#endif
    VerilatedCov::write("coverage.dat");
    printf("[sim_cov] done: %ld clk cycles, %ld cxl_clk cycles\n", clk_cyc, cxl_cyc);
    delete dut;
    return 0;
}
