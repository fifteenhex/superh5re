// sh5_top.sv - the synthesisable SH-5 system for a NiteFury II, everything
// inward of fpgaslop's req/ack bus (docs/soc.md):
//
//   h_* (BAR, 64-bit req/ack) -> sh5_hostif -+-> slop_card / sh5_hub
//                                             `-> memarb port B
//   sh5_core --packets--> sh5_shwy_req -+-> peripherals (sh5_periph)
//                                       `-> memarb port A
//   memarb -> mem_* (to mem_cdc -> req_to_axi4 -> MIG, in the board top)
//
// The board top (fpga/nitefury/sh5_board_top.sv) adds the PCIe endpoint,
// the clock converter, axi4_to_req, mem_cdc, req_to_axi4 and the MIG; the
// board testbench (rtl/tb/board) drives h_* and mem_* directly.
module sh5_top #(
  parameter logic [63:0] BUILD_ID  = 64'd0,
  parameter logic [63:0] BUILD_CFG = 64'd0,
  parameter int unsigned CLK_HZ    = 25_000_000,
  parameter int unsigned PCLK_DIV  = 12,
  parameter int          RAM_BITS  = 28,          // 256 MB DRAM window at 0x8000_0000
  parameter bit          AUTOSTART = 1'b0,
  parameter logic [31:0] BOOT_PC   = 32'h8000_0000,
  parameter bit          FPU_PRESENT = 1'b1,
  parameter int          VIO_SLOTS = 1              // virtio-mmio transports at 0x0b00_0000
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- the host (fpgaslop req/ack, from axi4_to_req) ----
  input  logic        h_req,
  input  logic        h_we,
  input  logic [63:0] h_addr,
  input  logic [63:0] h_wdata,
  input  logic [7:0]  h_wstrb,
  output logic        h_ack,
  output logic [63:0] h_rdata,
  output logic        h_err,
  output logic        msi,

  // ---- memory controller status, into the identity block ----
  input  logic        calib_complete,
  input  logic        dram_err,
  input  logic        dram_wedged,
  input  logic [31:0] wr_in,
  input  logic [31:0] wr_out,

  // ---- fpgaslop's memory bus ----
  output logic        mem_req,
  output logic        mem_we,
  output logic [63:0] mem_addr,
  output logic [63:0] mem_wdata,
  output logic [7:0]  mem_wstrb,
  output logic [2:0]  mem_len,
  input  logic        mem_ack,
  input  logic [63:0] mem_rdata,
  input  logic        mem_err,

  // ---- observation ----
  output logic        con_valid,        // SCIF transmit byte (also in the hub FIFO)
  output logic [7:0]  con_char,
  output logic [3:0]  led,
  output logic        core_sleep,
  output logic        soft_rst,
  output logic        trace_valid,
  output logic [31:0] trace_pc,
  output logic [31:0] trace_insn
);

  // ---- host interface, hub, card page ----
  logic        reset_hold, nmi, host_irq, bus_error;
  logic [31:0] boot_pc;
  logic        d_req, d_we, d_ack;
  logic [63:0] d_addr, d_wdata, d_rdata;
  logic [7:0]  d_wstrb;
  logic        rx_valid;
  logic [7:0]  rx_byte;
  logic [4:0]  rx_count;
  logic        bridge_idle;

  // the virtio host pages, between the host interface and the transports
  logic        vio_h_req, vio_h_we, vio_kick;   // vio_kick: any slot's QueueNotify, to the host MSI
  logic [11:0] vio_h_addr;
  logic [63:0] vio_h_wdata, vio_h_rdata;
  logic [7:0]  vio_h_wstrb;
  // the core's bus, declared here because the host interface's debug view names it
  logic        ireq_valid, ireq_ready, ireq_last;
  logic [7:0]  ireq_opc, ireq_src, ireq_tid, ireq_mask;
  logic [31:0] ireq_addr;
  logic [63:0] ireq_data;
  logic        irsp_valid, irsp_ready, irsp_last;
  logic [7:0]  irsp_opc, irsp_src, irsp_tid;
  logic [63:0] irsp_data;

  sh5_hostif #(.BUILD_ID(BUILD_ID), .BUILD_CFG(BUILD_CFG), .RAM_SIZE(64'd1 << RAM_BITS),
               .AUTOSTART(AUTOSTART), .BOOT_PC(BOOT_PC)) u_hostif (
    .clk(clk), .rst_n(rst_n),
    .h_req(h_req), .h_we(h_we), .h_addr(h_addr), .h_wdata(h_wdata), .h_wstrb(h_wstrb),
    .h_ack(h_ack), .h_rdata(h_rdata), .h_err(h_err),
    .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_wdata(d_wdata), .d_wstrb(d_wstrb),
    .d_ack(d_ack), .d_rdata(d_rdata), .d_err(mem_err),
    .vio_req(vio_h_req), .vio_we(vio_h_we), .vio_addr(vio_h_addr), .vio_wdata(vio_h_wdata),
    .vio_wstrb(vio_h_wstrb), .vio_rdata(vio_h_rdata),
    .soft_rst(soft_rst), .reset_hold(reset_hold), .boot_pc(boot_pc), .nmi(nmi), .host_irq(host_irq),
    .core_sleep(core_sleep), .bus_error(bus_error),
    .dbg_req_valid(ireq_valid && ireq_ready), .dbg_req_opc(ireq_opc), .dbg_req_tid(ireq_tid),
    .dbg_req_mask(ireq_mask), .dbg_req_addr(ireq_addr),
    .dbg_rsp_valid(irsp_valid && irsp_ready), .dbg_rsp_opc(irsp_opc), .dbg_rsp_tid(irsp_tid),
    .dbg_trace_valid(trace_valid), .dbg_trace_pc(trace_pc), .dbg_trace_insn(trace_insn),
    // nothing of the core's in flight on the memory path
    .quiet(bridge_idle && !mem_req), .msi(msi), .kick(vio_kick),
    .tx_valid(con_valid), .tx_byte(con_char), .rx_valid(rx_valid), .rx_byte(rx_byte), .rx_count(rx_count),
    .calib_complete(calib_complete), .dram_err(dram_err), .dram_wedged(dram_wedged),
    .wr_in(wr_in), .wr_out(wr_out)
  );

  // The core and the peripherals restart on a soft reset or while the host
  // holds the core; the host path, the arbiter and the hub do not.
  // The peripherals and the bridge are reset with the core: a kernel
  // leaves the TMU running and INTC priorities set, and the next kernel
  // deposited by the host would be interrupted before it has handlers
  // (NetBSD printed stray interrupts into an unattached console on the
  // card, after Linux). The host path and the hub are never reset here.
  logic core_rst_n, periph_rst_n;
  assign core_rst_n   = rst_n && !soft_rst && !reset_hold;
  assign periph_rst_n = rst_n && !soft_rst && !reset_hold;

  // ---- the core ----
  logic        extint_valid;
  logic [3:0]  extint_level;
  logic [31:0] extint_code;

  sh5_core #(.FPU_PRESENT(FPU_PRESENT)) u_core (
    .clk(clk), .rst_n(core_rst_n),
    .reset_pc_i(boot_pc), .big_endian_i(1'b0),
    .cpu_reset_i(1'b0), .nmi_i(nmi), .debugint_i(1'b0),
    .extint_valid_i(extint_valid), .extint_level_i(extint_level), .extint_code_i(extint_code),
    .extint_ack_o(), .extint_ack_level_o(),
    .dbrvec_i(32'h0), .dbrmode_i(1'b0),
    .sleep_o(core_sleep), .bus_error_o(bus_error),
    .dbg_ia_hit_i(1'b0), .dbg_iv_hit_i(1'b0), .dbg_oa_hit_i(1'b0),
    .dbg_fetch_addr_o(), .dbg_insn_o(), .dbg_op_valid_o(), .dbg_op_addr_o(),
    .trace_valid_o(trace_valid), .trace_pc_o(trace_pc), .trace_insn_o(trace_insn),
    .trace_gpr_we_o(), .trace_gpr_idx_o(), .trace_gpr_val_o(),
    .trace_fpu_we_o(), .trace_fpu_idx_o(), .trace_fpu_val_o(),
    .trace_launch_o(), .trace_launch_code_o(), .trace_launch_tea_o(), .trace_launch_pc_o(),
    .trace_pred_o(), .trace_mispred_o(),
    .ireq_valid(ireq_valid), .ireq_ready(ireq_ready), .ireq_opc(ireq_opc), .ireq_addr(ireq_addr),
    .ireq_src(ireq_src), .ireq_tid(ireq_tid), .ireq_mask(ireq_mask), .ireq_data(ireq_data), .ireq_last(ireq_last),
    .irsp_valid(irsp_valid), .irsp_ready(irsp_ready), .irsp_opc(irsp_opc), .irsp_src(irsp_src),
    .irsp_tid(irsp_tid), .irsp_data(irsp_data), .irsp_last(irsp_last),
    // no other initiator on this bus: the VCR is answered by sh5_periph
    .treq_valid(1'b0), .treq_ready(), .treq_opc(8'h0), .treq_addr(32'h0), .treq_src(8'h0), .treq_tid(8'h0),
    .treq_mask(8'h0), .treq_data(64'h0), .treq_last(1'b0),
    .trsp_valid(), .trsp_ready(1'b1), .trsp_opc(), .trsp_src(), .trsp_tid(), .trsp_data(), .trsp_last()
  );

  // ---- packets -> req/ack, split between DRAM and the peripherals ----
  logic        b_req, b_we, b_sel_ram, b_ack, b_err;
  logic [63:0] b_addr, b_wdata, b_rdata;
  logic [7:0]  b_wstrb;
  logic [2:0]  b_len;

  sh5_shwy_req #(.RAM_BITS(RAM_BITS)) u_bridge (
    .clk(clk), .rst_n(periph_rst_n),
    .ireq_valid(ireq_valid), .ireq_ready(ireq_ready), .ireq_opc(ireq_opc), .ireq_addr(ireq_addr),
    .ireq_src(ireq_src), .ireq_tid(ireq_tid), .ireq_mask(ireq_mask), .ireq_data(ireq_data), .ireq_last(ireq_last),
    .irsp_valid(irsp_valid), .irsp_ready(irsp_ready), .irsp_opc(irsp_opc), .irsp_src(irsp_src),
    .irsp_tid(irsp_tid), .irsp_data(irsp_data), .irsp_last(irsp_last),
    .m_req(b_req), .m_we(b_we), .m_sel_ram(b_sel_ram), .m_addr(b_addr), .m_wdata(b_wdata),
    .m_wstrb(b_wstrb), .m_len(b_len), .m_ack(b_ack), .m_rdata(b_rdata), .m_err(b_err),
    .idle_o(bridge_idle)
  );

  logic        p_ack, a_ack;
  logic [63:0] p_rdata, a_rdata;
  // ---- virtio-mmio transports (fpgaslop slop_virtio_slots): the guest
  // page at 0x0b00_0000 (slot n at +n*0x200), the host pages at register
  // window +0x2_0000; the rings are in DRAM, which both sides reach. The
  // interrupt joins the hub doorbell as INTC source 63 (INTEVT 0x560, Linux
  // irq 63); virtio-mmio drivers share a line by design. `kick` (any slot's
  // QueueNotify) goes to the host interface, where slop_card turns it into
  // the host MSI when the host has set the mailbox IRQ enable; the host
  // polls the kick latches otherwise.
  logic        b_sel_vio, vio_ack_q, vio_irq;
  logic [63:0] vio_rdata;
  assign b_sel_vio = !b_sel_ram && (b_addr[31:20] == 12'h0b0);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) vio_ack_q <= 1'b0;
    else        vio_ack_q <= b_req && b_sel_vio && !vio_ack_q;
  end
  // Not reset by reset_hold: the host presents the device (identity,
  // features, config) while the core is held, before releasing it, and
  // that must survive. The guest-owned half is reset by the driver itself
  // (Status = 0 is a device reset); a soft reset still clears everything.
  slop_virtio_slots #(.N_SLOTS(VIO_SLOTS), .N_QUEUES(2)) u_vio (
    .clk(clk), .rst(~(rst_n && !soft_rst)),
    .req(b_req && b_sel_vio && !vio_ack_q), .we(b_we), .addr(b_addr[11:0]), .wdata(b_wdata), .wstrb(b_wstrb),
    .rdata(vio_rdata),
    .h_req(vio_h_req), .h_we(vio_h_we), .h_addr(vio_h_addr), .h_wdata(vio_h_wdata), .h_wstrb(vio_h_wstrb),
    .h_rdata(vio_h_rdata),
    .kick(vio_kick), .irq(vio_irq)
  );

`ifdef VERILATOR
  // +viotrace: every guest access to the virtio page (writes when
  // accepted, reads with the data the core samples)
  logic vio_trace;
  longint vio_cycle;
  initial begin vio_trace = $test$plusargs("viotrace"); vio_cycle = 0; end
  always_ff @(posedge clk) if (vio_trace) begin
    vio_cycle <= vio_cycle + 1;
    if (b_req && b_sel_vio && !vio_ack_q && b_we)
      $display("[vio] %0d wr %03x strb %02x data %016x", vio_cycle, b_addr[11:0], b_wstrb, b_wdata);
    if (vio_ack_q && !b_we)
      $display("[vio] %0d rd %03x -> %016x", vio_cycle, b_addr[11:0], vio_rdata);
    if (vio_h_req && vio_h_we)       // host writes only: the host polls by reading
      $display("[vio] %0d host wr %03x data %016x", vio_cycle, vio_h_addr, vio_h_wdata);
  end
`endif
  assign b_ack   = b_sel_ram ? a_ack : b_sel_vio ? vio_ack_q : p_ack;
  assign b_rdata = b_sel_ram ? a_rdata : b_sel_vio ? vio_rdata : p_rdata;
  assign b_err   = b_sel_ram && mem_err;

  sh5_periph #(.CLK_HZ(CLK_HZ), .PCLK_DIV(PCLK_DIV)) u_periph (
    .clk(clk), .rst_n(periph_rst_n),
    .s_req(b_req && !b_sel_ram && !b_sel_vio), .s_we(b_we), .s_addr(b_addr[31:0]), .s_wdata(b_wdata), .s_wstrb(b_wstrb),
    .s_ack(p_ack), .s_rdata(p_rdata),
    .con_tx_valid(con_valid), .con_tx_byte(con_char),
    .con_rx_valid(rx_valid), .con_rx_byte(rx_byte), .con_rx_count(rx_count),
    .host_irq(host_irq || vio_irq), .led(led),
    .extint_valid(extint_valid), .extint_level(extint_level), .extint_code(extint_code)
  );

  // ---- DRAM arbiter: the core first, the host's window second ----
  memarb u_arb (
    .clk(clk), .rst(~rst_n),
    .a_req(b_req && b_sel_ram), .a_we(b_we), .a_addr(b_addr), .a_wdata(b_wdata), .a_wstrb(b_wstrb),
    .a_ack(a_ack), .a_rdata(a_rdata), .a_len(b_len),
    .b_req(d_req), .b_we(d_we), .b_addr(d_addr), .b_wdata(d_wdata), .b_wstrb(d_wstrb),
    .b_ack(d_ack), .b_rdata(d_rdata), .b_len(3'd0),
    .m_req(mem_req), .m_we(mem_we), .m_addr(mem_addr), .m_wdata(mem_wdata), .m_wstrb(mem_wstrb),
    .m_len(mem_len), .m_ack(mem_ack), .m_rdata(mem_rdata)
  );

endmodule
