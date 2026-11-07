// sh5_hostif.sv - the PCIe host's way in: fpgaslop's 64-bit BAR on one
// side, the DRAM arbiter and the hub on the other.
//
//     host (fpgaslop req/ack, 64-bit, byte strobes)
//       |
//       +-- BAR bit 28 clear ------> DRAM port (d_*): the DDR3 byte address is
//       |                            the BAR offset; the core sees the same
//       |                            bytes at 0x8000_0000 + offset
//       |
//       +-- BAR bit 28 set --+-- +0x0_0000..0FFF  slop_card (fpgaslop/rtl/slop_card.sv):
//                            |                    identity, soft reset, mailbox,
//                            |                    flash and DMA registers
//                            +-- +0x1_0000..1FFF  sh5_hub
//                            `-- anything else    baadf00d_baadf00d
//
// Same shape as smol68k's hostif (its header explains the reasons): the
// card page is answered here, in one cycle, independent of everything
// else, so the card can be identified while the rest is broken; the soft
// reset reaches the core and the peripherals and nothing on the host path;
// a forwarded access waits out a soft reset rather than being refused.
//
// Unlike smol68k the host's DRAM traffic does not pass through the core's
// caches: the core has no coherence protocol, and the kernels flush their
// caches after a deposit anyway (the host deposits with the core in reset,
// whose release invalidates both caches). The DRAM port goes to a memarb
// alongside the core.
module sh5_hostif #(
  parameter logic [63:0] BUILD_ID  = 64'd0,
  parameter logic [63:0] BUILD_CFG = 64'd0,
  parameter logic [63:0] RAM_SIZE  = 64'd256 << 20,
  parameter bit          AUTOSTART = 1'b0,
  parameter logic [31:0] BOOT_PC   = 32'h8000_0000
) (
  input  logic        clk,
  /* verilator lint_off SYNCASYNCNET */
  input  logic        rst_n,
  /* verilator lint_on SYNCASYNCNET */

  // ---- the host ----
  input  logic        h_req,
  input  logic        h_we,
  input  logic [63:0] h_addr,
  input  logic [63:0] h_wdata,
  input  logic [7:0]  h_wstrb,
  output logic        h_ack,
  output logic [63:0] h_rdata,
  output logic        h_err,

  // ---- DRAM, to the arbiter ----
  output logic        d_req,
  output logic        d_we,
  output logic [63:0] d_addr,
  output logic [63:0] d_wdata,
  output logic [7:0]  d_wstrb,
  input  logic        d_ack,
  input  logic [63:0] d_rdata,
  input  logic        d_err,

  // ---- the virtio transports' host pages, +0x2_0000 (one-cycle request pulses) ----
  output logic        vio_req,
  output logic        vio_we,
  output logic [11:0] vio_addr,
  output logic [63:0] vio_wdata,
  output logic [7:0]  vio_wstrb,
  input  logic [63:0] vio_rdata,

  // ---- the core and the peripherals ----
  output logic        soft_rst,
  output logic        reset_hold,
  output logic [31:0] boot_pc,
  output logic        nmi,
  output logic        host_irq,
  input  logic        core_sleep,
  input  logic        bus_error,
  // ---- debug view of the core's bus and retirement (read-only registers 0x040..0x070) ----
  input  logic        dbg_req_valid,
  input  logic [7:0]  dbg_req_opc,
  input  logic [7:0]  dbg_req_tid,
  input  logic [7:0]  dbg_req_mask,
  input  logic [31:0] dbg_req_addr,
  input  logic        dbg_rsp_valid,
  input  logic [7:0]  dbg_rsp_opc,
  input  logic [7:0]  dbg_rsp_tid,
  input  logic        dbg_trace_valid,
  input  logic [31:0] dbg_trace_pc,
  input  logic [31:0] dbg_trace_insn,
  input  logic        quiet,
  output logic        msi,

  // ---- console, to and from the SCIF ----
  input  logic        tx_valid,
  input  logic [7:0]  tx_byte,
  output logic        rx_valid,
  output logic [7:0]  rx_byte,
  input  logic [4:0]  rx_count,

  // ---- live status for the identity block ----
  input  logic        calib_complete,
  input  logic        dram_err,
  input  logic        dram_wedged,
  input  logic [31:0] wr_in,
  input  logic [31:0] wr_out
);

  localparam int SEL_BIT = 28;
  wire win      = h_addr[SEL_BIT];
  wire is_dram  = !win;
  wire card_sel = win && (h_addr[27:12] == 16'd0);
  wire hub_sel  = win && (h_addr[27:12] == 16'h0010);
  wire vio_sel  = win && (h_addr[27:12] == 16'h0020);
  wire dead_sel = win && !card_sel && !hub_sel && !vio_sel;

  // ---- the shared card page ----
  // CAPS: DRAM aperture, CPU, RESET. No mailbox to the CPU side, no MSI,
  // no DMA (slop_id.h): the bits stay clear until each is wired and proven.
  localparam logic [63:0] DESIGN = 64'h7375_7065_7268_3520;   // "superh5 "
  localparam logic [63:0] CAPS   = 64'h0000_0000_0000_0031;

  logic        card_ack;
  logic [63:0] card_q;

  slop_card #(.DESIGN(DESIGN), .BUILD_ID(BUILD_ID), .BUILD_CFG(BUILD_CFG), .CAPS(CAPS)) u_card (
    .clk(clk), .rst(~rst_n),
    .h_req(h_req && card_sel), .h_we(h_we), .h_addr(h_addr[11:0]), .h_wdata(h_wdata),
    .h_ack(card_ack), .h_rdata(card_q), .h_msi(msi),
    .c_req(1'b0), .c_we(1'b0), .c_addr(12'd0), .c_wdata(64'd0),
    .c_ack(), .c_rdata(), .c_irq(),
    .quiet(quiet), .soft_rst(soft_rst),
    .kick(1'b0),
    .calib_complete(calib_complete), .dram_err(dram_err), .dram_wedged(dram_wedged),
    .wr_in(wr_in), .wr_out(wr_out),
    .fsck(), .fmosi(), .fmiso(1'b1), .fcs_n(),
    .dma_h_len(), .dma_h_req(), .dma_h_we(), .dma_h_addr(), .dma_h_wdata(), .dma_h_wstrb(),
    .dma_h_ack(1'b0), .dma_h_rdata(64'd0),
    .dma_c_len(), .dma_c_req(), .dma_c_we(), .dma_c_addr(), .dma_c_wdata(), .dma_c_wstrb(),
    .dma_c_ack(1'b0), .dma_c_rdata(64'd0),
    .x_h_sel(), .x_c_sel(), .x_h_rdata(64'd0), .x_c_rdata(64'd0),
    .x_h_irq(1'b0), .x_c_irq(1'b0), .x_h_done(1'b1), .x_c_done(1'b1)
  );

  // ---- the hub ----
  logic        hub_ack;
  logic [63:0] hub_q;
  sh5_hub #(.RAM_SIZE(RAM_SIZE), .AUTOSTART(AUTOSTART), .BOOT_PC(BOOT_PC)) u_hub (
    .clk(clk), .rst_n(rst_n),
    .s_req(h_req && hub_sel), .s_we(h_we), .s_addr(h_addr[11:0]), .s_wdata(h_wdata),
    .s_ack(hub_ack), .s_rdata(hub_q),
    .reset_hold(reset_hold), .boot_pc(boot_pc), .nmi(nmi), .host_irq(host_irq),
    .core_sleep(core_sleep), .bus_error(bus_error),
    .dbg_req_valid(dbg_req_valid), .dbg_req_opc(dbg_req_opc), .dbg_req_tid(dbg_req_tid),
    .dbg_req_mask(dbg_req_mask), .dbg_req_addr(dbg_req_addr),
    .dbg_rsp_valid(dbg_rsp_valid), .dbg_rsp_opc(dbg_rsp_opc), .dbg_rsp_tid(dbg_rsp_tid),
    .dbg_trace_valid(dbg_trace_valid), .dbg_trace_pc(dbg_trace_pc), .dbg_trace_insn(dbg_trace_insn),
    .tx_valid(tx_valid), .tx_byte(tx_byte), .rx_valid(rx_valid), .rx_byte(rx_byte), .rx_count(rx_count)
  );

  // ---- DRAM forwarding: one transaction, held until the arbiter answers ----
  // Not started while the core is in soft reset: the arbiter is not reset
  // by it, but keeping the host out of the pulse keeps the quiet promise
  // true (fpgaslop/rtl/slop_reset.sv).
  typedef enum logic [1:0] { S_IDLE, S_ISSUE, S_WAIT } state_e;
  state_e state;
  logic        fwd_ack, fwd_err;
  logic [63:0] fwd_rdata;

  assign d_req   = (state == S_ISSUE);
  assign d_we    = h_we;
  assign d_addr  = {36'h0, h_addr[27:0]};
  assign d_wdata = h_wdata;
  assign d_wstrb = h_wstrb;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE; fwd_ack <= 1'b0; fwd_err <= 1'b0; fwd_rdata <= 64'h0;
    end else begin
      fwd_ack <= 1'b0;
      case (state)
        S_IDLE:  if (h_req && is_dram && !soft_rst) state <= S_ISSUE;
        S_ISSUE: if (d_ack) begin fwd_rdata <= d_rdata; fwd_err <= d_err; fwd_ack <= 1'b1; state <= S_WAIT; end
        // the request is finished when it is withdrawn: the host sees the
        // ack in this state's first cycle and drops req in the next
        S_WAIT:  if (!h_req) state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

  // ---- the dead window and the virtio pages answer in one cycle ----
  // slop_virtio wants h_req for exactly one cycle per access and answers
  // reads combinationally from the address, which the host holds until ack
  logic dead_ack, vio_ack;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin dead_ack <= 1'b0; vio_ack <= 1'b0; end
    else begin
      dead_ack <= h_req && dead_sel && !dead_ack;
      vio_ack  <= h_req && vio_sel && !vio_ack;
    end
  end
  assign vio_req   = h_req && vio_sel && !vio_ack;
  assign vio_we    = h_we;
  assign vio_addr  = h_addr[11:0];
  assign vio_wdata = h_wdata;
  assign vio_wstrb = h_wstrb;

  assign h_ack   = card_ack | hub_ack | fwd_ack | dead_ack | vio_ack;
  assign h_rdata = card_ack ? card_q : hub_ack ? hub_q : fwd_ack ? fwd_rdata : vio_ack ? vio_rdata : 64'hbaad_f00d_baad_f00d;
  assign h_err   = fwd_ack & fwd_err;

endmodule
