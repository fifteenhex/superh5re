// Verilator testbench for sh5_core: sparse memory and a Cayman-style SCIF on
// the bus port, ELF loader, commit trace.
//
//   tb_core --elf image.elf [--max-cycles N] [--trace file] [--latency N]
//           [--quiet] [--done "string"]
//
// Exit status: 0 when the program printed the done string and no "failures"
// other than 0 appeared in an "isa: SUMMARY" line; 1 otherwise.

#include "Vsh5_core.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>
#include <fstream>

namespace {

struct Memory {
    std::unordered_map<uint32_t, std::vector<uint8_t>> pages;
    std::vector<uint8_t> &page(uint32_t addr) {
        auto it = pages.find(addr >> 12);
        if (it == pages.end()) it = pages.emplace(addr >> 12, std::vector<uint8_t>(4096, 0)).first;
        return it->second;
    }
    uint8_t rd8(uint32_t a) { return page(a)[a & 0xfff]; }
    void wr8(uint32_t a, uint8_t v) { page(a)[a & 0xfff] = v; }
    uint64_t rd64(uint32_t a) {
        uint64_t v = 0;
        for (int i = 0; i < 8; i++) v |= (uint64_t)rd8((a & ~7u) + i) << (8 * i);
        return v;
    }
    void wr64(uint32_t a, uint64_t v, uint8_t mask) {
        for (int i = 0; i < 8; i++)
            if (mask & (1 << i)) wr8((a & ~7u) + i, (uint8_t)(v >> (8 * i)));
    }
};

struct Rsp {
    uint64_t when;
    uint8_t opc, src, tid;
    std::vector<uint64_t> data;
};

const uint8_t OPC_LOAD8 = 0x31, OPC_LOAD16 = 0x41, OPC_LOAD32 = 0x51;
const uint8_t OPC_STORE8 = 0x32, OPC_STORE16 = 0x42, OPC_STORE32 = 0x52;
const uint8_t OPC_SWAP8 = 0x35, OPC_SUCCESS = 0x80, OPC_FAILURE = 0x81;

const uint32_t SCIF_BASE = 0x0a030000;

struct Tb {
    Vsh5_core *top;
    Memory mem;
    std::deque<Rsp> rsps;
    uint64_t cycle = 0;
    unsigned latency = 1;
    std::string out;
    FILE *trace = nullptr;
    bool quiet = false;
    bool bustrace = false;
    bool done = false;
    int failures = -1;
    // multi-beat request assembly
    bool req_open = false;
    Rsp req_cur;
    uint32_t req_addr = 0;
    std::vector<uint64_t> req_data;
    std::vector<uint8_t> req_mask;

    bool is_scif(uint32_t a) { return (a & 0xffff0000u) == SCIF_BASE; }

    uint64_t dev_read(uint32_t a) {
        if (is_scif(a)) {
            uint64_t w = 0;
            // 0x10 FSR: TDFE | TEND; everything else 0
            uint32_t off = a & 0xffff & ~7u;
            if (off == 0x10) w |= (uint64_t)0x0060 << 0;   // FSR at +0x10 is lane 0..1 of the word at 0x10
            return w;
        }
        return mem.rd64(a);
    }

    void dev_write(uint32_t a, uint64_t v, uint8_t mask) {
        if (is_scif(a)) {
            uint32_t off = a & 0xffff & ~7u;
            if (off == 0x08) {
                // 0x0c FTDR is byte lane 4 of the word at 0x08
                if (mask & 0x10) {
                    char c = (char)(v >> 32);
                    putc_out(c);
                }
            }
            return;
        }
        mem.wr64(a, v, mask);
    }

    void putc_out(char c) {
        if (!quiet) { fputc(c, stdout); fflush(stdout); }
        out.push_back(c);
        if (out.size() > 4096) out.erase(0, out.size() - 4096);
    }

    void handle_request() {
        Vsh5_core &t = *top;
        if (!(t.ireq_valid && t.ireq_ready)) return;
        if (!req_open) {
            req_cur = Rsp{};
            req_cur.opc = t.ireq_opc; req_cur.src = t.ireq_src; req_cur.tid = t.ireq_tid;
            req_addr = t.ireq_addr;
            req_data.clear(); req_mask.clear();
            req_open = true;
        }
        req_data.push_back(t.ireq_data);
        req_mask.push_back(t.ireq_mask);
        if (!t.ireq_last) return;
        req_open = false;
        if (bustrace && trace)
            fprintf(trace, "bus %llu req opc=%02x addr=%08x tid=%02x mask=%02x data=%016llx\n",
                    (unsigned long long)cycle, req_cur.opc, req_addr, req_cur.tid, req_mask[0],
                    (unsigned long long)req_data[0]);
        Rsp r = req_cur;
        r.when = cycle + latency;
        r.opc = OPC_SUCCESS;
        unsigned words = 1;
        switch (req_cur.opc) {
        case OPC_LOAD8: words = 1; break;
        case OPC_LOAD16: words = 2; break;
        case OPC_LOAD32: words = 4; break;
        case OPC_STORE8: case OPC_STORE16: case OPC_STORE32: case OPC_SWAP8: words = 1; break;
        default: r.opc = OPC_FAILURE; rsps.push_back(r); return;
        }
        uint32_t base = req_addr & ~7u;
        unsigned nw = (req_cur.opc == OPC_LOAD16 || req_cur.opc == OPC_STORE16) ? 2
                    : (req_cur.opc == OPC_LOAD32 || req_cur.opc == OPC_STORE32) ? 4 : 1;
        uint32_t span = nw * 8;
        uint32_t blk = req_addr & ~(span - 1);
        unsigned first = (req_addr & (span - 1)) >> 3;   // critical word first
        if (req_cur.opc == OPC_LOAD8 || req_cur.opc == OPC_LOAD16 || req_cur.opc == OPC_LOAD32) {
            for (unsigned k = 0; k < nw; k++) {
                unsigned w = (first + k) % nw;
                r.data.push_back(dev_read(blk + 8 * w));
            }
        } else if (req_cur.opc == OPC_SWAP8) {
            uint64_t old = dev_read(base);
            dev_write(base, req_data[0], req_mask[0]);
            r.data.push_back(old);
        } else {
            for (unsigned k = 0; k < nw && k < req_data.size(); k++) {
                unsigned w = (first + k) % nw;
                dev_write(blk + 8 * w, req_data[k], req_mask[k]);
            }
        }
        (void)words;
        rsps.push_back(r);
    }

    // drive the response channel for this cycle (before eval of the posedge)
    unsigned rsp_beat = 0;
    void drive_response() {
        Vsh5_core &t = *top;
        t.irsp_valid = 0;
        t.irsp_last = 0;
        if (rsps.empty() || rsps.front().when > cycle) return;
        Rsp &r = rsps.front();
        t.irsp_valid = 1;
        t.irsp_opc = r.opc; t.irsp_src = r.src; t.irsp_tid = r.tid;
        t.irsp_data = r.data.empty() ? 0 : r.data[rsp_beat];
        t.irsp_last = r.data.size() <= 1 || rsp_beat + 1 == r.data.size();
    }
    void response_accepted() {
        Vsh5_core &t = *top;
        if (!(t.irsp_valid && t.irsp_ready)) return;
        Rsp &r = rsps.front();
        if (bustrace && trace)
            fprintf(trace, "bus %llu rsp opc=%02x tid=%02x data=%016llx\n", (unsigned long long)cycle,
                    r.opc, r.tid, (unsigned long long)(r.data.empty() ? 0 : r.data[rsp_beat]));
        if (t.irsp_last) { rsps.pop_front(); rsp_beat = 0; }
        else rsp_beat++;
    }

    void trace_commit() {
        Vsh5_core &t = *top;
        if (!trace) return;
        if (t.trace_valid_o) {
            if (bustrace) fprintf(trace, "%llu ", (unsigned long long)cycle);
            fprintf(trace, "%08x %08x", t.trace_pc_o, t.trace_insn_o);
            if (t.trace_gpr_we_o) fprintf(trace, " r%d=%016llx", t.trace_gpr_idx_o, (unsigned long long)t.trace_gpr_val_o);
            fputc('\n', trace);
        }
        if (t.trace_fpu_we_o) {
            fprintf(trace, "fpu f%d=%08x_%08x_%08x_%08x\n", t.trace_fpu_idx_o,
                    t.trace_fpu_val_o[3], t.trace_fpu_val_o[2], t.trace_fpu_val_o[1], t.trace_fpu_val_o[0]);
        }
    }
};

bool load_elf(Memory &mem, const char *path, uint32_t &entry) {
    std::ifstream f(path, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return false; }
    std::vector<uint8_t> img((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (img.size() < 52 || memcmp(img.data(), "\x7f" "ELF", 4) != 0 || img[4] != 1 || img[5] != 1) {
        fprintf(stderr, "%s: not a little-endian ELF32 file\n", path); return false;
    }
    auto r32 = [&](size_t o) { return (uint32_t)img[o] | (uint32_t)img[o+1] << 8 | (uint32_t)img[o+2] << 16 | (uint32_t)img[o+3] << 24; };
    auto r16 = [&](size_t o) { return (uint16_t)(img[o] | img[o+1] << 8); };
    entry = r32(24);
    uint32_t phoff = r32(28);
    uint16_t phentsize = r16(42), phnum = r16(44);
    for (unsigned i = 0; i < phnum; i++) {
        size_t p = phoff + (size_t)i * phentsize;
        uint32_t type = r32(p), offset = r32(p + 4), paddr = r32(p + 12);
        uint32_t filesz = r32(p + 16), memsz = r32(p + 20);
        if (type != 1) continue;
        for (uint32_t k = 0; k < memsz; k++)
            mem.wr8(paddr + k, k < filesz ? img[offset + k] : 0);
    }
    return true;
}

} // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *elf = nullptr, *tracefile = nullptr;
    const char *done_str = "isa: DONE";
    uint64_t max_cycles = 200000000ULL;
    Tb tb;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--elf") && i + 1 < argc) elf = argv[++i];
        else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--trace") && i + 1 < argc) tracefile = argv[++i];
        else if (!strcmp(argv[i], "--latency") && i + 1 < argc) tb.latency = strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--quiet")) tb.quiet = true;
        else if (!strcmp(argv[i], "--bus")) tb.bustrace = true;
        else if (!strcmp(argv[i], "--done") && i + 1 < argc) done_str = argv[++i];
    }
    if (!elf) { fprintf(stderr, "usage: tb_core --elf image.elf [options]\n"); return 2; }
    uint32_t entry = 0;
    if (!load_elf(tb.mem, elf, entry)) return 2;
    if (tracefile) tb.trace = fopen(tracefile, "w");

    Vsh5_core top;
    tb.top = &top;
    top.clk = 0; top.rst_n = 0;
    top.reset_pc_i = entry & ~1u;
    top.big_endian_i = 0;
    top.cpu_reset_i = 0; top.nmi_i = 0; top.debugint_i = 0;
    top.extint_valid_i = 0; top.extint_level_i = 0; top.extint_code_i = 0;
    top.dbrvec_i = 0; top.dbrmode_i = 0;
    top.dbg_ia_hit_i = 0; top.dbg_iv_hit_i = 0; top.dbg_oa_hit_i = 0;
    top.ireq_ready = 1;
    top.irsp_valid = 0; top.irsp_opc = 0; top.irsp_src = 0; top.irsp_tid = 0; top.irsp_data = 0; top.irsp_last = 0;
    top.treq_valid = 0; top.treq_opc = 0; top.treq_addr = 0; top.treq_src = 0; top.treq_tid = 0;
    top.treq_mask = 0; top.treq_data = 0; top.treq_last = 0; top.trsp_ready = 1;

    for (int i = 0; i < 4; i++) { top.clk = 0; top.eval(); top.clk = 1; top.eval(); }
    top.rst_n = 1;

    uint64_t done_cycle = 0;
    while (tb.cycle < max_cycles) {
        // falling edge: present responses for the coming posedge
        top.clk = 0;
        tb.drive_response();
        top.eval();
        // sample request/response handshakes as they stand before the edge
        tb.handle_request();
        tb.response_accepted();
        // rising edge
        top.clk = 1;
        top.eval();
        tb.trace_commit();
        tb.cycle++;
        if (!tb.done && tb.out.find(done_str) != std::string::npos) {
            tb.done = true;
            done_cycle = tb.cycle;
        }
        if (tb.done && tb.cycle > done_cycle + 20) break;
    }
    if (tb.trace) fclose(tb.trace);

    size_t p = tb.out.rfind("isa: SUMMARY");
    if (p != std::string::npos) {
        unsigned tests = 0, fails = 0;
        if (sscanf(tb.out.c_str() + p, "isa: SUMMARY %u tests, %u failures", &tests, &fails) == 2) tb.failures = (int)fails;
    }
    std::string summary;
    if (p != std::string::npos) {
        size_t e = tb.out.find_first_of("\r\n", p);
        summary = tb.out.substr(p, e == std::string::npos ? std::string::npos : e - p);
    }
    fprintf(stderr, "[tb] %llu cycles, %s%s%s\n", (unsigned long long)tb.cycle, tb.done ? "done" : "timeout",
            summary.empty() ? "" : ", ", summary.c_str());
    top.final();
    return (tb.done && tb.failures <= 0) ? 0 : 1;
}
