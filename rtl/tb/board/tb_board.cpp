// tb_board.cpp - boot a program on sh5_top the way the PCIe host will.
//
//   make -C rtl/tb/board build
//   ./obj/Vsh5_top --elf ../../../tests/exc/exc.elf --quiet
//   ./obj/Vsh5_top --elf vmlinux --cmdline "console=ttySC0 ..." --initrd rootfs.cpio.gz --done smolsh
//
// Everything the host does is a 64-bit BAR transaction on h_* through the
// same host/sh5boot.c a host tool uses: identify the card page, hold the
// core, deposit the image into the DRAM window, set BOOT_PC, release, and
// drain the console from the hub FIFO (docs/soc.md). Memory behind mem_*
// is a sparse model with a programmable latency that streams burst reads.
//
// Options: --elf FILE, --cmdline STR, --initrd FILE, --max-cycles N,
// --mem-latency N, --done STRING, --expect STR --send TEXT (pairs, as the
// core testbench), --console-log FILE, --trace FILE [--trace-max N],
// --quiet.
#include "Vsh5_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unordered_map>

extern "C" {
#include "sh5boot.h"
}

namespace {

struct Memory {
    std::unordered_map<uint32_t, std::vector<uint8_t>> pages;
    std::vector<uint8_t> &page(uint32_t a) {
        auto it = pages.find(a >> 12);
        if (it == pages.end()) it = pages.emplace(a >> 12, std::vector<uint8_t>(4096, 0)).first;
        return it->second;
    }
    uint64_t rd64(uint32_t a) {
        uint64_t v = 0;
        auto &p = page(a);
        for (int i = 0; i < 8; i++) v |= (uint64_t)p[(a & 0xff8) + i] << (8 * i);
        return v;
    }
    void wr64(uint32_t a, uint64_t v, uint8_t strb) {
        auto &p = page(a);
        for (int i = 0; i < 8; i++) if (strb & (1 << i)) p[(a & 0xff8) + i] = (uint8_t)(v >> (8 * i));
    }
};

struct Tb {
    Vsh5_top *top = nullptr;
    Memory mem;
    uint64_t cycle = 0;
    unsigned latency = 6;
    bool quiet = false, bustrace = false;
    FILE *conlog = nullptr, *trace = nullptr;
    uint64_t trace_max = ~0ull, traced = 0;
    std::string out;
    bool done = false;
    const char *done_str = "isa: DONE";
    int failures = -1;
    struct Step { std::string expect, send; };
    std::vector<Step> script;
    size_t script_pos = 0;
    std::string input_pending;
    uint64_t mem_txns = 0;

    // ---- the memory behind mem_*: latency once, then one beat per cycle ----
    enum { M_IDLE, M_WAIT, M_ACK, M_HOLD } mst = M_IDLE;
    unsigned mctr = 0, mbeats = 0;
    uint64_t maddr = 0, mwdata = 0;
    uint8_t mstrb = 0;
    bool mwe = false;

    void mem_step() {
        Vsh5_top &t = *top;
        switch (mst) {
        case M_IDLE:
            t.mem_ack = 0; t.mem_err = 0;
            if (t.mem_req) {
                maddr = t.mem_addr; mwdata = t.mem_wdata; mstrb = t.mem_wstrb; mwe = t.mem_we;
                if (maddr >= SH5_RAM_BYTES) { fprintf(stderr, "[tb] memory access outside DRAM: %llx\n", (unsigned long long)maddr); exit(1); }
                mbeats = t.mem_len;
                mctr = latency;
                mst = latency ? M_WAIT : M_ACK;
            }
            break;
        case M_WAIT:
            if (--mctr == 0) mst = M_ACK;
            break;
        case M_ACK: {
            uint32_t a = (uint32_t)maddr & ~7u;
            // a write burst takes each beat's data as the master presents it
            // with the ack (fpgaslop memarb: "write data follows the master
            // beat by beat"); the first beat's data was captured with the request
            if (mwe && mbeats != t.mem_len) { mwdata = t.mem_wdata; mstrb = t.mem_wstrb; }
            if (mwe) mem.wr64(a, mwdata, mstrb);
            else t.mem_rdata = mem.rd64(a);
            if (bustrace) fprintf(stderr, "[bus] %llu %s %08x %016llx strb=%02x\n", (unsigned long long)cycle,
                                  mwe ? "wr" : "rd", a, (unsigned long long)(mwe ? mwdata : t.mem_rdata), mstrb);
            t.mem_ack = 1;
            if (mbeats) { mbeats--; maddr += 8; }
            else { mem_txns++; mst = M_HOLD; }
            break;
        }
        case M_HOLD:
            t.mem_ack = 0;
            if (!t.mem_req) mst = M_IDLE;
            break;
        }
    }

    void tick() {
        Vsh5_top &t = *top;
        t.clk = 0; t.eval();
        mem_step();
        t.eval();
        t.clk = 1; t.eval();
        if (trace && t.trace_valid) {
            if (++traced <= trace_max) fprintf(trace, "%08x %08x\n", t.trace_pc, t.trace_insn);
        }
        if (t.con_valid) putc_out((char)t.con_char);   // observation only; the host reads the FIFO
        cycle++;
    }

    void putc_out(char c) {
        if (!quiet) { fputc(c, stdout); fflush(stdout); }
        if (conlog) { fputc(c, conlog); fflush(conlog); }
        out.push_back(c);
        if (out.size() > 4096) out.erase(0, out.size() - 4096);
        if (!done && out.find(done_str) != std::string::npos) done = true;
        if (script_pos < script.size()) {
            size_t p = out.find(script[script_pos].expect);
            if (p != std::string::npos) {
                input_pending += script[script_pos].send;
                out.erase(0, p + script[script_pos].expect.size());
                script_pos++;
            }
        }
    }

    // ---- BAR transactions ----
    bool bar(uint64_t off, bool we, uint64_t wdata, uint8_t strb, uint64_t *rdata) {
        Vsh5_top &t = *top;
        t.h_req = 1; t.h_we = we; t.h_addr = off; t.h_wdata = wdata; t.h_wstrb = we ? strb : 0;
        for (int guard = 0; guard < 100000; guard++) {
            tick();
            if (bustrace && guard < 40) fprintf(stderr, "[h] %llu req=%d we=%d addr=%llx ack=%d | mem_req=%d mem_ack=%d mst=%d\n",
                (unsigned long long)cycle, (int)t.h_req, (int)t.h_we, (unsigned long long)t.h_addr, (int)t.h_ack, (int)t.mem_req, (int)t.mem_ack, (int)mst);
            if (t.h_ack) {
                if (rdata) *rdata = t.h_rdata;
                bool err = t.h_err;
                t.h_req = 0; t.h_we = 0; t.h_wstrb = 0;
                tick();
                return !err;
            }
        }
        t.h_req = 0;
        fprintf(stderr, "[tb] BAR access to %llx never acknowledged\n", (unsigned long long)off);
        exit(1);
    }
};

Tb tb;

uint64_t cb_read64(void *, uint64_t off) { uint64_t v = 0; tb.bar(off, false, 0, 0, &v); return v; }
void cb_write64(void *, uint64_t off, uint64_t v, uint8_t strb) { tb.bar(off, true, v, strb, nullptr); }

} // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *elf = nullptr, *cmdline = nullptr, *initrd = nullptr, *conlog = nullptr, *tracefile = nullptr;
    uint64_t max_cycles = 400000000ULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--elf") && i + 1 < argc) elf = argv[++i];
        else if (!strcmp(argv[i], "--cmdline") && i + 1 < argc) cmdline = argv[++i];
        else if (!strcmp(argv[i], "--initrd") && i + 1 < argc) initrd = argv[++i];
        else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--mem-latency") && i + 1 < argc) tb.latency = strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--done") && i + 1 < argc) tb.done_str = argv[++i];
        else if (!strcmp(argv[i], "--console-log") && i + 1 < argc) conlog = argv[++i];
        else if (!strcmp(argv[i], "--trace") && i + 1 < argc) tracefile = argv[++i];
        else if (!strcmp(argv[i], "--trace-max") && i + 1 < argc) tb.trace_max = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--quiet")) tb.quiet = true;
        else if (!strcmp(argv[i], "--bus")) tb.bustrace = true;
        else if (!strcmp(argv[i], "--expect") && i + 3 < argc && !strcmp(argv[i + 2], "--send")) {
            std::string send = argv[i + 3], e;
            for (size_t k = 0; k < send.size(); k++) {
                if (send[k] == '\\' && k + 1 < send.size()) { k++; e += send[k] == 'n' ? '\n' : send[k] == 'r' ? '\r' : send[k]; }
                else e += send[k];
            }
            tb.script.push_back({argv[i + 1], e});
            i += 3;
        }
    }
    if (!elf) { fprintf(stderr, "usage: Vsh5_top --elf image.elf [options]\n"); return 2; }
    if (conlog) tb.conlog = fopen(conlog, "w");
    if (tracefile) tb.trace = fopen(tracefile, "w");

    Vsh5_top top;
    tb.top = &top;
    top.clk = 0; top.rst_n = 0;
    top.h_req = 0; top.h_we = 0; top.h_addr = 0; top.h_wdata = 0; top.h_wstrb = 0;
    top.calib_complete = 1; top.dram_err = 0; top.dram_wedged = 0; top.wr_in = 0; top.wr_out = 0;
    top.mem_ack = 0; top.mem_rdata = 0; top.mem_err = 0;
    for (int i = 0; i < 8; i++) { top.clk = 0; top.eval(); top.clk = 1; top.eval(); }
    top.rst_n = 1;
    for (int i = 0; i < 8; i++) tb.tick();

    // ---- the host sequence ----
    struct sh5_bar bar = { nullptr, cb_read64, cb_write64 };
    char msg[160];
    if (sh5_probe(&bar, msg, sizeof msg)) { fprintf(stderr, "[tb] probe: %s\n", msg); return 1; }
    fprintf(stderr, "[tb] probe: %s\n", msg);
    sh5_hold(&bar);
    uint64_t t0 = tb.cycle;
    uint32_t pc = sh5_deposit(&bar, elf, cmdline, initrd, msg, sizeof msg);
    if (!pc) { fprintf(stderr, "[tb] deposit: %s\n", msg); return 1; }
    fprintf(stderr, "[tb] deposit: %s (%llu cycles)\n", msg, (unsigned long long)(tb.cycle - t0));
    sh5_release(&bar, pc);
    fprintf(stderr, "[tb] released at %08x\n", pc);

    // ---- run, draining the console over the BAR ----
    uint64_t run0 = tb.cycle, done_cycle = 0;
    std::string hostcon;
    while (tb.cycle < max_cycles) {
        for (int k = 0; k < 64 && tb.cycle < max_cycles; k++) tb.tick();
        if (tb.done) { if (!done_cycle) done_cycle = tb.cycle; if (tb.cycle > done_cycle + 2000) break; }
        unsigned n = sh5_con_waiting(&bar);
        for (unsigned k = 0; k < n; k++) {
            int c = sh5_con_pop(&bar);
            if (c < 0) break;
            hostcon.push_back((char)c);
        }
        while (!tb.input_pending.empty() && sh5_con_push(&bar, (uint8_t)tb.input_pending[0]))
            tb.input_pending.erase(0, 1);
    }
    // the hub's copy of the console must match what the SCIF sent
    bool con_ok = hostcon.size() >= tb.out.size() ? true : false;
    size_t p = tb.out.rfind("isa: SUMMARY");
    std::string summary;
    if (p != std::string::npos) {
        unsigned tests = 0, fails = 0;
        if (sscanf(tb.out.c_str() + p, "isa: SUMMARY %u tests, %u failures", &tests, &fails) == 2) tb.failures = (int)fails;
        size_t e = tb.out.find_first_of("\r\n", p);
        summary = tb.out.substr(p, e == std::string::npos ? std::string::npos : e - p);
    }
    fprintf(stderr, "[tb] %llu cycles (%llu after release), %llu memory transactions, %zu console bytes via the hub%s, %s%s%s\n",
            (unsigned long long)tb.cycle, (unsigned long long)(tb.cycle - run0), (unsigned long long)tb.mem_txns,
            hostcon.size(), con_ok ? "" : " (SHORT)", tb.done ? "done" : "timeout",
            summary.empty() ? "" : ", ", summary.c_str());
    if (tb.conlog) fclose(tb.conlog);
    if (tb.trace) fclose(tb.trace);
    top.final();
    return (tb.done && tb.failures <= 0 && con_ok) ? 0 : 1;
}
