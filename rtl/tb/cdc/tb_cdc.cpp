// tb_cdc.cpp - the memory path with sh5_mem_cdc: memarb (both ports),
// the crossing, req_to_axi4 and an AXI slave, at the board's 4:1 clock
// ratio. Random traffic against a reference memory, then the cost of each
// kind of access in a_clk cycles. The AXI slave is fpgaslop's from
// tb_memchain.cpp, with a programmable latency.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <map>
#include "Vtb_cdc_top.h"
#include "verilated.h"

static Vtb_cdc_top *d;
static uint64_t tick_count;
static int fails;
static int lat = 12;                      // b_clk cycles before the slave answers

// ---- AXI slave: a memory with bursts both ways and a fixed latency ----
static std::map<uint32_t, uint64_t> mem;
static bool wr_addr_v, wr_pending; static uint32_t wr_addr; static int wr_beats, wr_wait;
static bool rd_pending; static uint32_t rd_addr; static int rd_beats, rd_wait;

static void axi_slave(void)
{
    d->m_awready = !wr_addr_v;
    if (d->m_awvalid && d->m_awready) { wr_addr = d->m_awaddr; wr_beats = d->m_awlen + 1; wr_addr_v = true; wr_wait = lat; }
    if (wr_wait) wr_wait--;
    d->m_wready = wr_addr_v && wr_beats > 0 && !wr_pending && wr_wait == 0;
    if (d->m_wvalid && d->m_wready) {
        if ((d->m_wlast != 0) != (wr_beats == 1)) { printf("FAIL: wlast %d with %d beat(s) left\n", (int)d->m_wlast, wr_beats); fails++; }
        uint64_t old = mem.count(wr_addr) ? mem[wr_addr] : 0, v = 0;
        for (int i = 0; i < 8; i++) {
            uint64_t m = 0xffull << (8 * i);
            v |= (d->m_wstrb & (1 << i)) ? (d->m_wdata & m) : (old & m);
        }
        mem[wr_addr] = v;
        wr_addr += 8;
        if (--wr_beats == 0) wr_pending = true;
    }
    d->m_bvalid = wr_pending; d->m_bresp = 0;
    if (wr_pending && d->m_bready) { wr_pending = false; wr_addr_v = false; }
    d->m_arready = !rd_pending;
    if (d->m_arvalid && d->m_arready) { rd_addr = d->m_araddr; rd_beats = d->m_arlen + 1; rd_pending = true; rd_wait = lat; }
    if (rd_wait) rd_wait--;
    d->m_rvalid = rd_pending && rd_wait == 0;
    d->m_rlast  = d->m_rvalid && (rd_beats == 1);
    d->m_rresp  = 0;
    d->m_rdata  = d->m_rvalid && mem.count(rd_addr) ? mem[rd_addr] : 0;
    if (d->m_rvalid && d->m_rready) { rd_addr += 8; if (--rd_beats == 0) rd_pending = false; }
}

// b_clk ticks; every fourth carries an a_clk edge (25 MHz against 100 MHz)
static bool tick(void)
{
    d->b_clk = 0; d->eval();
    axi_slave();
    d->eval();
    d->b_clk = 1; d->eval();
    bool a_edge = (tick_count % 4 == 0);
    if (a_edge) { d->a_clk = 0; d->eval(); d->a_clk = 1; d->eval(); }
    tick_count++;
    if (tick_count > 40000000) { printf("FAIL: harness timeout\n"); exit(1); }
    return a_edge;
}

static void reset_all(void)
{
    d->a_rst = 1; d->b_rst = 1;
    d->cpu_req = 0; d->cpu_we = 0; d->cpu_len = 0; d->cpu_wstrb = 0xff;
    d->host_req = 0; d->host_we = 0; d->host_wstrb = 0xff;
    for (int i = 0; i < 40; i++) tick();
    d->a_rst = 0; d->b_rst = 0;
    for (int i = 0; i < 40; i++) tick();
}

// ---- reference memory, byte strobes honoured ----
static std::map<uint32_t, uint64_t> ref;
static void ref_write(uint32_t a, uint64_t v, uint8_t strb)
{
    uint64_t old = ref.count(a) ? ref[a] : 0, n = 0;
    for (int i = 0; i < 8; i++) { uint64_t m = 0xffull << (8 * i); n |= (strb & (1 << i)) ? (v & m) : (old & m); }
    ref[a] = n;
}
static uint64_t ref_read(uint32_t a) { return ref.count(a) ? ref[a] : 0; }

// A burst on the CPU port (memarb A): len+1 beats, data per beat, acks counted
// on a_clk edges; returns a_clk cycles from request to the last ack
static int cpu_burst(bool we, uint32_t addr, int len, uint64_t *data, uint8_t strb)
{
    d->cpu_we = we; d->cpu_addr = addr; d->cpu_len = len; d->cpu_wstrb = strb; d->cpu_wdata = data[0];
    d->cpu_req = 1;
    int acks = 0, cycles = 0;
    for (int i = 0; i < 400000 && acks <= len; i++) {
        bool a_edge = tick();
        if (getenv("DBG") && i < 300)
            printf("    t=%llu %s cpu_req=%d a_st=%d b_st=%d cmd e/f=%d/%d wd_e=%d rd_e=%d m_req=%d m_ack=%d | b_req=%d b_ack=%d wr_rdy=%d rd_rdy=%d | awv=%d awr=%d wv=%d wr=%d bv=%d br=%d arv=%d rv=%d rr=%d\n",
                   (unsigned long long)tick_count, a_edge ? "A" : " ", (int)d->cpu_req, (int)d->o_a_st, (int)d->o_b_st, (int)d->o_cmd_empty, (int)d->o_cmd_full, (int)d->o_wd_empty, (int)d->o_rd_empty, (int)d->o_m_req, (int)d->o_m_ack, (int)d->o_b_req, (int)d->o_b_ack,
                   (int)d->o_b_wr_ready, (int)d->o_b_rd_ready, (int)d->m_awvalid, (int)d->m_awready, (int)d->m_wvalid,
                   (int)d->m_wready, (int)d->m_bvalid, (int)d->m_bready, (int)d->m_arvalid, (int)d->m_rvalid, (int)d->m_rready);
        if (a_edge) {
            cycles++;
            if (d->cpu_ack) {
                if (!we) data[acks] = d->cpu_rdata;
                acks++;
                if (we && acks <= len) d->cpu_wdata = data[acks];
            }
        }
    }
    d->cpu_req = 0; d->cpu_we = 0; d->cpu_len = 0;
    if (acks != len + 1) { printf("FAIL: cpu %s burst len %d got %d acks\n", we ? "write" : "read", len, acks); fails++; }
    // the master drops req for a cycle afterwards
    while (!tick()) ;
    if (getenv("DBG")) printf("    gap done at t=%llu a_st=%d cpu_req=%d m_req=%d\n", (unsigned long long)tick_count, (int)d->o_a_st, (int)d->cpu_req, (int)d->o_m_req);
    return cycles;
}

static void host_xfer(bool we, uint32_t addr, uint64_t *data)
{
    d->host_we = we; d->host_addr = addr; d->host_wdata = *data; d->host_req = 1;
    bool got = false;
    for (int i = 0; i < 400000 && !got; i++) {
        bool a_edge = tick();
        if (a_edge && d->host_ack) { if (!we) *data = d->host_rdata; got = true; }
    }
    d->host_req = 0; d->host_we = 0;
    if (!got) { printf("FAIL: host access never acknowledged\n"); fails++; }
    while (!tick()) ;
}

static uint64_t rnd64(void) { return ((uint64_t)rand() << 40) ^ ((uint64_t)rand() << 20) ^ (uint64_t)rand(); }

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc > 1) lat = atoi(argv[1]);
    d = new Vtb_cdc_top;
    reset_all();
    srand(1);
    if (getenv("DBG")) {
        uint64_t v[8] = {0x1122334455667788ull};
        cpu_burst(true, 0x40, 0, v, 0xff);
        v[0] = 0;
        cpu_burst(false, 0x40, 0, v, 0xff);
        printf("read back %016llx\n", (unsigned long long)v[0]);
        return fails;
    }

    // ---- random traffic: single and 4-beat accesses on the CPU port, single
    // beats on the host port, every read compared with the model ----
    for (int n = 0; n < 1500 && !fails; n++) {
        int kind = rand() % 6;
        uint32_t a = (uint32_t)((rand() % 64) * 32);          // 64 lines
        uint64_t data[8];
        if (kind == 0 || kind == 1) {                         // 4-beat write / read of a line
            bool we = (kind == 0);
            for (int i = 0; i < 4; i++) data[i] = rnd64();
            cpu_burst(we, a, 3, data, 0xff);
            for (int i = 0; i < 4; i++) {
                if (we) ref_write(a + 8 * i, data[i], 0xff);
                else if (data[i] != ref_read(a + 8 * i)) {
                    printf("FAIL: op %d line read %08x beat %d: %016llx want %016llx\n", n, a, i,
                           (unsigned long long)data[i], (unsigned long long)ref_read(a + 8 * i));
                    fails++; break;
                }
            }
        } else if (kind == 2 || kind == 3) {                  // single beat, partial strobe on writes
            bool we = (kind == 2);
            a += (rand() % 4) * 8;
            uint8_t strb = we ? (uint8_t)(rand() & 0xff) : 0xff;
            if (!strb) strb = 0x0f;
            data[0] = rnd64();
            cpu_burst(we, a, 0, data, strb);
            if (we) ref_write(a, data[0], strb);
            else if (data[0] != ref_read(a)) {
                printf("FAIL: op %d word read %08x: %016llx want %016llx\n", n, a,
                       (unsigned long long)data[0], (unsigned long long)ref_read(a));
                fails++;
            }
        } else {                                               // the host, single beats
            bool we = (kind == 4);
            a += (rand() % 4) * 8;
            data[0] = rnd64();
            host_xfer(we, a, data);
            if (we) ref_write(a, data[0], 0xff);
            else if (data[0] != ref_read(a)) {
                printf("FAIL: op %d host read %08x: %016llx want %016llx\n", n, a,
                       (unsigned long long)data[0], (unsigned long long)ref_read(a));
                fails++;
            }
        }
    }
    if (!fails) printf("  ok   1500 random accesses agree with the model (two ports, bursts, strobes)\n");

    // the whole model against the slave's memory: every posted write landed
    // (the last ones are still crossing: let them)
    for (int i = 0; i < 400; i++) tick();
    for (auto &kv : ref) {
        uint32_t a = kv.first;
        if (!mem.count(a) || mem[a] != kv.second) {
            printf("FAIL: memory at %08x holds %016llx, model %016llx\n", a,
                   (unsigned long long)(mem.count(a) ? mem[a] : 0), (unsigned long long)kv.second);
            fails++; break;
        }
    }
    if (!fails) printf("  ok   the slave's memory matches the model\n");

    // ---- cost, in a_clk cycles, slave latency %d b_clk cycles ----
    {
        uint64_t data[8] = {0};
        for (int i = 0; i < 4; i++) data[i] = 0x1000 + i;
        int w1 = cpu_burst(true, 0x10000, 0, data, 0xff);
        int w4 = cpu_burst(true, 0x10020, 3, data, 0xff);
        int r1 = cpu_burst(false, 0x10000, 0, data, 0xff);
        int r4 = cpu_burst(false, 0x10020, 3, data, 0xff);
        printf("  --   a_clk cycles to the last ack, slave latency %d b_clk: write 1 beat %d, 4 beats %d; read 1 beat %d, 4 beats %d\n",
               lat, w1, w4, r1, r4);
    }
    printf(fails ? "FAIL (%llu ticks)\n" : "PASS (%llu ticks)\n", (unsigned long long)tick_count);
    d->final();
    return fails ? 1 : 0;
}
