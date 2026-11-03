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

const uint32_t INTC_BASE = 0x0a000000;
const uint32_t CPRC_BASE = 0x0a010000;
const uint32_t TMU_BASE  = 0x0a020000;
const uint32_t SCIF_BASE = 0x0a030000;
const uint32_t RTC_BASE  = 0x0a040000;
const uint32_t RAM_BASE  = 0x80000000;
const uint32_t RAM_SIZE  = 128u << 20;

// INTEVT codes of the Cayman interrupt sources (NetBSD sh5 intc driver)
static uint16_t intc_intevt_table[64];
static void init_intevt() {
    static const struct { int n; uint16_t code; } t[] = {
        {0, 0x240}, {1, 0x2a0}, {2, 0x300}, {3, 0x360},
        {4, 0x800}, {5, 0x820}, {6, 0x840}, {7, 0x860},
        {12, 0xa00}, {13, 0xa20}, {14, 0xa40}, {15, 0xa60}, {16, 0xa80}, {17, 0xaa0},
        {18, 0x640}, {19, 0x660}, {20, 0x680}, {21, 0x6a0}, {22, 0x6c0},
        {32, 0x400}, {33, 0x420}, {34, 0x440}, {35, 0x460}, {36, 0x480}, {37, 0x4a0}, {38, 0x4c0},
        {39, 0x700}, {40, 0x720}, {41, 0x740}, {42, 0x760},
        {63, 0x560},
    };
    for (auto &e : t) intc_intevt_table[e.n] = e.code;
}
#define intc_intevt intc_intevt_table

// Interrupt controller: ICR +0/+8, INTPRI[8] +0x10 step 8, INTSRC +0x50/58,
// INTREQ +0x60/68, INTENB +0x70/78, INTDISB +0x80/88.
struct Intc {
    uint64_t src = 0, enb = 0;
    uint32_t icr = 0, intpri[8] = {0};
    void set(int n, bool level) { if (level) src |= 1ull << n; else src &= ~(1ull << n); }
    // highest priority pending source: level 1..15, 0 = none
    void best(int &level, uint32_t &code) {
        level = 0; code = 0;
        uint64_t pend = src & enb;
        for (int i = 0; i < 64; i++) if (pend & (1ull << i)) {
            int p = (intpri[i / 8] >> ((i % 8) * 4)) & 0xf;
            if (p > level) { level = p; code = intc_intevt[i]; }
        }
    }
    uint32_t read(uint32_t off) {
        if (off == 0x00 || off == 0x08) return icr;
        if (off >= 0x10 && off < 0x50) return intpri[(off - 0x10) / 8];
        switch (off) {
        case 0x50: return (uint32_t)src;        case 0x58: return src >> 32;
        case 0x60: return (uint32_t)(src & enb); case 0x68: return (src & enb) >> 32;
        case 0x70: return (uint32_t)enb;        case 0x78: return enb >> 32;
        case 0x80: return (uint32_t)~enb;       case 0x88: return ~enb >> 32;
        }
        return 0;
    }
    void write(uint32_t off, uint32_t v) {
        if (off == 0x00) icr |= v;
        else if (off == 0x08) icr &= ~v;
        else if (off >= 0x10 && off < 0x50) intpri[(off - 0x10) / 8] = v;
        else if (off == 0x70) enb |= v;
        else if (off == 0x78) enb |= (uint64_t)v << 32;
        else if (off == 0x80) enb &= ~(uint64_t)v;
        else if (off == 0x88) enb &= ~((uint64_t)v << 32);
    }
};

// Timer unit (TMU, SH-4 layout): TOCR +0, TSTR +4, channel n: TCOR +8+12n,
// TCNT +0xc+12n, TCR +0x10+12n. Counts on the peripheral clock, modelled as
// the core clock divided by PCLK_DIV, further divided by the TCR prescaler.
const unsigned PCLK_DIV = 12;
struct Tmu {
    uint8_t tocr = 0, tstr = 0;
    uint32_t tcor[3] = {0xffffffff, 0xffffffff, 0xffffffff};
    uint32_t tcnt[3] = {0xffffffff, 0xffffffff, 0xffffffff};
    uint16_t tcr[3] = {0, 0, 0};
    bool unf[3] = {false, false, false};
    unsigned pre[3] = {0, 0, 0};
    unsigned pclk = 0;
    bool irq(int n) const { return unf[n] && (tcr[n] & 0x20); }
    void tick() {
        if (++pclk < PCLK_DIV) return;
        pclk = 0;
        for (int n = 0; n < 3; n++) {
            if (!(tstr & (1 << n))) continue;
            unsigned div = 4u << (2 * (tcr[n] & 7));
            if (++pre[n] < div) continue;
            pre[n] = 0;
            if (tcnt[n] == 0) { tcnt[n] = tcor[n]; unf[n] = true; }
            else tcnt[n]--;
        }
    }
    uint32_t read(uint32_t off) {
        if (off == 0) return tocr;
        if (off == 4) return tstr;
        int n = (off - 8) / 12, r = (off - 8) % 12;
        if (n < 0 || n > 2) return 0;
        if (r == 0) return tcor[n];
        if (r == 4) return tcnt[n];
        if (r == 8) return tcr[n] | (unf[n] ? 0x100 : 0);
        return 0;
    }
    void write(uint32_t off, uint32_t v) {
        if (off == 0) { tocr = v & 1; return; }
        if (off == 4) { tstr = v & 7; return; }
        int n = (off - 8) / 12, r = (off - 8) % 12;
        if (n < 0 || n > 2) return;
        if (r == 0) tcor[n] = v;
        else if (r == 4) tcnt[n] = v;
        else if (r == 8) { if (!(v & 0x100)) unf[n] = false; tcr[n] = v & 0xff; }
    }
};

struct Tb {
    Vsh5_core *top;
    Memory mem;
    Intc intc;
    Tmu tmu;
    uint32_t cprc_regs[8] = {0};
    uint8_t rcr1 = 0, rcr2 = 0;
    FILE *conlog = nullptr;
    std::deque<Rsp> rsps;
    uint64_t cycle = 0;
    unsigned latency = 1;
    std::string out;
    FILE *trace = nullptr;
    bool quiet = false;
    bool bustrace = false;
    uint64_t trace_max = ~0ull, traced = 0;
    bool done = false;
    int failures = -1;
    // multi-beat request assembly
    bool req_open = false;
    Rsp req_cur;
    uint32_t req_addr = 0;
    std::vector<uint64_t> req_data;
    std::vector<uint8_t> req_mask;

    bool is_scif(uint32_t a) { return (a & 0xffff0000u) == SCIF_BASE; }
    bool is_ram(uint32_t a) { return a >= RAM_BASE && a < RAM_BASE + RAM_SIZE; }

    // 32-bit register read placed in its lane of the 8-byte word
    static uint64_t lane32(uint32_t v, uint32_t a) { return (uint64_t)v << ((a & 4) ? 32 : 0); }

    uint64_t dev_read(uint32_t a) {
        uint32_t base = a & 0xffff0000u, off = a & 0xfff8;
        if (is_ram(a)) return mem.rd64(a);
        if (base == SCIF_BASE) {
            // FSR (+0x10): TDFE | TEND; FRDR/others 0
            return off == 0x10 ? 0x0060 : 0;
        }
        if (base == INTC_BASE) return lane32(intc.read(off), off) | lane32(intc.read(off + 4), off + 4) * ((off & 7) ? 0 : 1);
        if (base == TMU_BASE)  return lane32(tmu.read(off), off) | lane32(tmu.read(off + 4), off + 4);
        if (base == CPRC_BASE) {
            // FRQ: PLL 512 MHz, CPU /2, EMI /8, SuperHyway /4, peripheral /24, PCI /24, FEMI /8, ST /24
            const uint32_t FRQ = (3 << 0) | (1 << 3) | (0 << 6) | (7 << 12) | (7 << 15) | (3 << 18) | (7 << 21) | 0x400;
            const uint32_t PLL = (1u << 31) | (1u << 30);
            if (off == 0x00) return FRQ;
            if (off == 0x08) return PLL;
            return cprc_regs[off / 8];
        }
        if (base == RTC_BASE) {
            if (off == 0x38) return (uint64_t)rcr1 | (uint64_t)rcr2 << 32;
            return 0;
        }
        // SuperHyway module VCRs: module id in [47:32], version in [31:16]
        if ((a >> 24) == 0x0d && off < 0x10) return (uint64_t)0x51e2 << 32;
        if ((a >> 24) == 0x09 && off == 0)   return (uint64_t)0x448f << 32;
        if ((a >> 24) == 0x08 && off == 0)   return (uint64_t)0x2185 << 32;
        return 0;    // system FPGA, debug module, unmapped
    }

    void dev_write(uint32_t a, uint64_t v, uint8_t mask) {
        uint32_t base = a & 0xffff0000u, off = a & 0xfff8;
        if (is_ram(a)) { mem.wr64(a, v, mask); return; }
        if (base == SCIF_BASE) {
            // FTDR (+0x0c) is byte lane 4 of the word at +0x08
            if (off == 0x08 && (mask & 0x10)) putc_out((char)(v >> 32));
            return;
        }
        if (base == INTC_BASE || base == TMU_BASE || base == CPRC_BASE) {
            for (int half = 0; half < 2; half++) {
                if (!(mask & (0x0f << (4 * half)))) continue;
                uint32_t r = off + 4 * half, w = (uint32_t)(v >> (32 * half));
                if (base == INTC_BASE) intc.write(r, w);
                else if (base == TMU_BASE) tmu.write(r, w);
                else if (r == 0x38 && (w & 1)) { fprintf(stderr, "[tb] CPRC reset request\n"); }
                else cprc_regs[r / 8] = w;
            }
            return;
        }
        if (base == RTC_BASE) {
            if (off == 0x38) { if (mask & 0x0f) rcr1 = (uint8_t)v; if (mask & 0xf0) rcr2 = (uint8_t)(v >> 32); }
            return;
        }
    }

    // timers and interrupt lines, once per core clock
    void tick_devices() {
        tmu.tick();
        intc.set(32, tmu.irq(0));
        intc.set(33, tmu.irq(1));
        intc.set(34, tmu.irq(2));
        int level; uint32_t code;
        intc.best(level, code);
        top->extint_valid_i = level > 0;
        top->extint_level_i = level;
        top->extint_code_i = code;
    }

    void putc_out(char c) {
        if (!quiet) { fputc(c, stdout); fflush(stdout); }
        if (conlog) { fputc(c, conlog); fflush(conlog); }
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
            if (++traced > trace_max) { fclose(trace); trace = nullptr; return; }
            if (bustrace) fprintf(trace, "%llu ", (unsigned long long)cycle);
            fprintf(trace, "%08x %08x", t.trace_pc_o, t.trace_insn_o);
            if (t.trace_gpr_we_o) fprintf(trace, " r%d=%016llx", t.trace_gpr_idx_o, (unsigned long long)t.trace_gpr_val_o);
            fputc('\n', trace);
        }
        if (t.trace_launch_o) {
            fprintf(trace, "launch code=%03x tea=%08x -> %08x\n", t.trace_launch_code_o, t.trace_launch_tea_o, t.trace_launch_pc_o);
        }
        if (t.trace_fpu_we_o) {
            fprintf(trace, "fpu f%d=%08x_%08x_%08x_%08x\n", t.trace_fpu_idx_o,
                    t.trace_fpu_val_o[3], t.trace_fpu_val_o[2], t.trace_fpu_val_o[1], t.trace_fpu_val_o[0]);
        }
    }
};

bool load_elf(Memory &mem, const char *path, uint32_t &entry, uint32_t &highaddr) {
    std::ifstream f(path, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return false; }
    std::vector<uint8_t> img((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (img.size() < 52 || memcmp(img.data(), "\x7f" "ELF", 4) != 0 || img[4] != 1 || img[5] != 1) {
        fprintf(stderr, "%s: not a little-endian ELF32 file\n", path); return false;
    }
    auto r32 = [&](size_t o) { return (uint32_t)img[o] | (uint32_t)img[o+1] << 8 | (uint32_t)img[o+2] << 16 | (uint32_t)img[o+3] << 24; };
    auto r16 = [&](size_t o) { return (uint16_t)(img[o] | img[o+1] << 8); };
    entry = r32(24);
    highaddr = 0;
    uint32_t phoff = r32(28);
    uint16_t phentsize = r16(42), phnum = r16(44);
    for (unsigned i = 0; i < phnum; i++) {
        size_t p = phoff + (size_t)i * phentsize;
        uint32_t type = r32(p), offset = r32(p + 4), paddr = r32(p + 12);
        uint32_t filesz = r32(p + 16), memsz = r32(p + 20);
        if (type != 1) continue;
        for (uint32_t k = 0; k < memsz; k++)
            mem.wr8(paddr + k, k < filesz ? img[offset + k] : 0);
        if (paddr + memsz > highaddr) highaddr = paddr + memsz;
    }
    return true;
}

} // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    init_intevt();
    const char *elf = nullptr, *tracefile = nullptr, *cmdline = nullptr, *initrd = nullptr, *conlog = nullptr;
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
        else if (!strcmp(argv[i], "--trace-max") && i + 1 < argc) tb.trace_max = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--done") && i + 1 < argc) done_str = argv[++i];
        else if (!strcmp(argv[i], "--cmdline") && i + 1 < argc) cmdline = argv[++i];
        else if (!strcmp(argv[i], "--initrd") && i + 1 < argc) initrd = argv[++i];
        else if (!strcmp(argv[i], "--console-log") && i + 1 < argc) conlog = argv[++i];
    }
    if (!elf) { fprintf(stderr, "usage: tb_core --elf image.elf [options]\n"); return 2; }
    uint32_t entry = 0, highaddr = 0;
    if (!load_elf(tb.mem, elf, entry, highaddr)) return 2;
    if (tracefile) tb.trace = fopen(tracefile, "w");
    if (conlog) tb.conlog = fopen(conlog, "w");
    // Linux: command line at empty_zero_page + 0x100 (the page before _stext),
    // initrd location at +0x10/+0x14 as offset from the RAM base; the initrd is
    // placed 1 MB aligned after the kernel image.
    if (cmdline || initrd) {
        uint32_t zp = (entry & ~1u) - 0x1000;
        if (cmdline) for (size_t k = 0; k <= strlen(cmdline); k++) tb.mem.wr8(zp + 0x100 + k, cmdline[k]);
        if (initrd) {
            std::ifstream f(initrd, std::ios::binary);
            std::vector<uint8_t> img((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            uint32_t base = (highaddr + (1u << 20) - 1) & ~((1u << 20) - 1);
            for (size_t k = 0; k < img.size(); k++) tb.mem.wr8(base + k, img[k]);
            uint32_t v[2] = { base - RAM_BASE, (uint32_t)img.size() };
            for (int k = 0; k < 4; k++) { tb.mem.wr8(zp + 0x10 + k, v[0] >> (8 * k)); tb.mem.wr8(zp + 0x14 + k, v[1] >> (8 * k)); }
            fprintf(stderr, "[tb] initrd at 0x%08x, %zu bytes\n", base, img.size());
        }
    }

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
        // falling edge: present responses and interrupt lines for the coming posedge
        top.clk = 0;
        tb.drive_response();
        tb.tick_devices();
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
    if (tb.conlog) fclose(tb.conlog);

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
