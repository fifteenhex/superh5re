// sh5_board_top.sv - a NiteFury II running SH-5 code.
//
//   PCIe BAR0 -> axi_pcie -> clock converter -> axi4_to_req -> h_*
//        -> sh5_top: sh5_hostif -+-> slop_card (identity, soft reset, mailbox/flash/DMA regs)
//                                +-> sh5_hub   (reset/boot control, console)
//                                `-> memarb    <- sh5_core via sh5_shwy_req (and sh5_periph)
//                    mem_* -> mem_cdc -> req_to_axi4 -> MIG -> DDR3
//
// Everything here that touches Vivado IP or a Xilinx primitive -- the
// clocking, the reset counter, the endpoint and clock-converter
// instantiations and their tie-offs, mem_cdc/req_to_axi4/MIG wiring -- is
// smol68k's board top (smol68k/fpga/nitefury/smol68k_board_top.sv), which
// has built and run on the card; its comments record why each tie-off
// exists. The design inside is sh5_top, which the board testbench
// (rtl/tb/board) simulates with the same h_* and mem_* contracts.
//
// This file has NEVER been through Vivado. It elaborates under Verilator
// with fpgaslop's primitive stubs (boards/nitefury/lint-top.sh), which
// checks ports, widths and drivers but not the IP configuration.
`timescale 1ns/1ps

module sh5_board_top #(
    parameter real          CORE_DIV  = 40.0,    // 1000 MHz VCO / n: 25 MHz
    parameter logic [63:0]  BUILD_ID  = 64'h0,
    parameter logic [63:0]  BUILD_CFG = 64'h0,
    parameter int unsigned  CLK_HZ    = 25_000_000,
    parameter bit           LED_ACTIVE_LOW = 1'b1
) (
    input  logic clk200_p,
    input  logic clk200_n,
    input  logic pci_reset_n,

    output logic [3:0] led,

    input  logic       pcie_refclk_p,
    input  logic       pcie_refclk_n,
    output logic [0:0] pci_exp_txp,
    output logic [0:0] pci_exp_txn,
    input  logic [0:0] pci_exp_rxp,
    input  logic [0:0] pci_exp_rxn,

    inout  wire  [15:0] ddr3_dq,
    inout  wire  [1:0]  ddr3_dqs_p,
    inout  wire  [1:0]  ddr3_dqs_n,
    output logic [15:0] ddr3_addr,
    output logic [2:0]  ddr3_ba,
    output logic        ddr3_ras_n,
    output logic        ddr3_cas_n,
    output logic        ddr3_we_n,
    output logic        ddr3_reset_n,
    output logic [0:0]  ddr3_ck_p,
    output logic [0:0]  ddr3_ck_n,
    output logic [0:0]  ddr3_cke,
    output logic [1:0]  ddr3_dm,
    output logic [0:0]  ddr3_odt
);

    // ------------------------------------------------------------------
    // clocking: one BUFG in front of both MMCMs (ddrslop's arrangement;
    // the pin and the core MMCM are not in the same clock region)
    // ------------------------------------------------------------------
    wire clk200, clk200g, clk_core, clk, mmcm_locked, clkfb;

    IBUFDS #(.DIFF_TERM("TRUE"), .IBUF_LOW_PWR("FALSE"))
        ibufds_clk (.I(clk200_p), .IB(clk200_n), .O(clk200));

    BUFG bufg_sys (.I(clk200), .O(clk200g));

    MMCME2_BASE #(
        .CLKIN1_PERIOD   (5.000),
        .DIVCLK_DIVIDE   (1),
        .CLKFBOUT_MULT_F (5.000),
        .CLKOUT0_DIVIDE_F(CORE_DIV)
    ) mmcm (
        .CLKIN1(clk200g), .CLKFBIN(clkfb), .CLKFBOUT(clkfb),
        .CLKOUT0(clk_core), .LOCKED(mmcm_locked),
        .PWRDWN(1'b0), .RST(1'b0),
        .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUTB());

    BUFG bufg_core (.I(clk_core), .O(clk));

    // Start IN reset and stay there until mmcm_locked has been high for
    // 256 cycles (projects/ddrslop/top.sv explains why an edge-driven
    // reset fails on a JTAG load into a running host).
    logic [8:0] rst_cnt = 9'd0;
    logic       rst_r   = 1'b1;
    always_ff @(posedge clk) begin
        if (!(pci_reset_n & mmcm_locked)) begin
            rst_cnt <= 9'd0;
            rst_r   <= 1'b1;
        end else if (!rst_cnt[8]) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_r   <= 1'b1;
        end else begin
            rst_r   <= 1'b0;
        end
    end
    wire rst = rst_r;

    // ------------------------------------------------------------------
    // the endpoint
    // ------------------------------------------------------------------
    wire axi_rstn = pci_reset_n & ~rst;

    wire pcie_clk, pcie_lnk_up, pcie_mmcm_lock;

    logic [1:0] prstn_sync = 2'b00;
    always_ff @(posedge pcie_clk) prstn_sync <= {prstn_sync[0], axi_rstn};
    wire pcie_aresetn = prstn_sync[1];

    wire pcie_refclk;
    IBUFDS_GTE2 ibufds_pcie (
        .I(pcie_refclk_p), .IB(pcie_refclk_n),
        .CEB(1'b0), .O(pcie_refclk), .ODIV2());

    wire [31:0] p_awaddr, p_araddr;
    wire [7:0]  p_awlen,  p_arlen;
    wire [2:0]  p_awsize, p_arsize;
    wire [1:0]  p_awburst, p_arburst;
    wire        p_awvalid, p_awready, p_arvalid, p_arready;
    wire [63:0] p_wdata,  p_rdata;
    wire [7:0]  p_wstrb;
    wire        p_wlast, p_wvalid, p_wready;
    wire [1:0]  p_bresp,  p_rresp;
    wire        p_bvalid, p_bready, p_rlast, p_rvalid, p_rready;

    wire [31:0] c_awaddr, c_araddr;
    wire [7:0]  c_awlen,  c_arlen;
    wire [2:0]  c_awsize, c_arsize;
    wire [1:0]  c_awburst, c_arburst;
    wire        c_awvalid, c_awready, c_arvalid, c_arready;
    wire [63:0] c_wdata,  c_rdata;
    wire [7:0]  c_wstrb;
    wire        c_wlast, c_wvalid, c_wready;
    wire [1:0]  c_bresp,  c_rresp;
    wire        c_bvalid, c_bready, c_rlast, c_rvalid, c_rready;

    // Tie-offs copied from the designs that built; each cost a build
    // (fpgaslop boards/nitefury/pcie.md). No interrupt: the host polls.
    sh5_pcie_ep ep (
        .REFCLK(pcie_refclk),
        .pci_exp_txp(pci_exp_txp), .pci_exp_txn(pci_exp_txn),
        .pci_exp_rxp(pci_exp_rxp), .pci_exp_rxn(pci_exp_rxn),

        .axi_aclk_out(pcie_clk),
        .axi_aresetn(axi_rstn),
        .user_link_up(pcie_lnk_up), .mmcm_lock(pcie_mmcm_lock),

        .INTX_MSI_Request(1'b0), .INTX_MSI_Grant(),
        .MSI_Vector_Num(5'd0),

        .m_axi_awaddr(p_awaddr), .m_axi_awlen(p_awlen),
        .m_axi_awsize(p_awsize), .m_axi_awburst(p_awburst),
        .m_axi_awvalid(p_awvalid), .m_axi_awready(p_awready),
        .m_axi_wdata(p_wdata), .m_axi_wstrb(p_wstrb),
        .m_axi_wlast(p_wlast), .m_axi_wvalid(p_wvalid),
        .m_axi_wready(p_wready),
        .m_axi_bresp(p_bresp), .m_axi_bvalid(p_bvalid),
        .m_axi_bready(p_bready),
        .m_axi_araddr(p_araddr), .m_axi_arlen(p_arlen),
        .m_axi_arsize(p_arsize), .m_axi_arburst(p_arburst),
        .m_axi_arvalid(p_arvalid), .m_axi_arready(p_arready),
        .m_axi_rdata(p_rdata), .m_axi_rresp(p_rresp),
        .m_axi_rlast(p_rlast), .m_axi_rvalid(p_rvalid),
        .m_axi_rready(p_rready),

        .s_axi_awid('0), .s_axi_awaddr('0), .s_axi_awregion('0),
        .s_axi_awlen('0), .s_axi_awsize('0), .s_axi_awburst('0),
        .s_axi_awvalid(1'b0),
        .s_axi_wdata('0), .s_axi_wstrb('0), .s_axi_wlast(1'b0),
        .s_axi_wvalid(1'b0),
        .s_axi_bready(1'b0),
        .s_axi_arid('0), .s_axi_araddr('0), .s_axi_arregion('0),
        .s_axi_arlen('0), .s_axi_arsize('0), .s_axi_arburst('0),
        .s_axi_arvalid(1'b0),
        .s_axi_rready(1'b0),

        .s_axi_ctl_awaddr('0), .s_axi_ctl_awvalid(1'b0),
        .s_axi_ctl_wdata('0),  .s_axi_ctl_wstrb('0),
        .s_axi_ctl_wvalid(1'b0), .s_axi_ctl_bready(1'b0),
        .s_axi_ctl_araddr('0), .s_axi_ctl_arvalid(1'b0),
        .s_axi_ctl_rready(1'b0));

    // The endpoint's AXI clock and the core clock are unrelated.
    sh5_pcie_cdc cdc (
        .s_axi_aclk(pcie_clk),  .s_axi_aresetn(pcie_aresetn),
        .m_axi_aclk(clk),       .m_axi_aresetn(~rst),

        .s_axi_awaddr(p_awaddr), .s_axi_awlen(p_awlen),
        .s_axi_awsize(p_awsize), .s_axi_awburst(p_awburst),
        .s_axi_awvalid(p_awvalid), .s_axi_awready(p_awready),
        .s_axi_awlock(1'b0), .s_axi_awcache(4'd0), .s_axi_awprot(3'd0),
        .s_axi_awregion(4'd0), .s_axi_awqos(4'd0),
        .s_axi_wdata(p_wdata), .s_axi_wstrb(p_wstrb),
        .s_axi_wlast(p_wlast), .s_axi_wvalid(p_wvalid),
        .s_axi_wready(p_wready),
        .s_axi_bresp(p_bresp), .s_axi_bvalid(p_bvalid),
        .s_axi_bready(p_bready),
        .s_axi_araddr(p_araddr), .s_axi_arlen(p_arlen),
        .s_axi_arsize(p_arsize), .s_axi_arburst(p_arburst),
        .s_axi_arvalid(p_arvalid), .s_axi_arready(p_arready),
        .s_axi_arlock(1'b0), .s_axi_arcache(4'd0), .s_axi_arprot(3'd0),
        .s_axi_arregion(4'd0), .s_axi_arqos(4'd0),
        .s_axi_rdata(p_rdata), .s_axi_rresp(p_rresp),
        .s_axi_rlast(p_rlast), .s_axi_rvalid(p_rvalid),
        .s_axi_rready(p_rready),

        .m_axi_awaddr(c_awaddr), .m_axi_awlen(c_awlen),
        .m_axi_awsize(c_awsize), .m_axi_awburst(c_awburst),
        .m_axi_awvalid(c_awvalid), .m_axi_awready(c_awready),
        .m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(),
        .m_axi_awregion(), .m_axi_awqos(),
        .m_axi_wdata(c_wdata), .m_axi_wstrb(c_wstrb),
        .m_axi_wlast(c_wlast), .m_axi_wvalid(c_wvalid),
        .m_axi_wready(c_wready),
        .m_axi_bresp(c_bresp), .m_axi_bvalid(c_bvalid),
        .m_axi_bready(c_bready),
        .m_axi_araddr(c_araddr), .m_axi_arlen(c_arlen),
        .m_axi_arsize(c_arsize), .m_axi_arburst(c_arburst),
        .m_axi_arvalid(c_arvalid), .m_axi_arready(c_arready),
        .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(),
        .m_axi_arregion(), .m_axi_arqos(),
        .m_axi_rdata(c_rdata), .m_axi_rresp(c_rresp),
        .m_axi_rlast(c_rlast), .m_axi_rvalid(c_rvalid),
        .m_axi_rready(c_rready));

    // ------------------------------------------------------------------
    // AXI4 -> req/ack -> the design
    // ------------------------------------------------------------------
    wire        h_req, h_we, h_ack, h_err;
    wire [63:0] h_addr, h_wdata, h_rdata;
    wire [7:0]  h_wstrb;

    axi4_to_req host (
        .clk(clk), .rst(rst),
        .s_awaddr(c_awaddr), .s_awlen(c_awlen), .s_awsize(c_awsize),
        .s_awburst(c_awburst), .s_awvalid(c_awvalid),
        .s_awready(c_awready),
        .s_wdata(c_wdata), .s_wstrb(c_wstrb), .s_wlast(c_wlast),
        .s_wvalid(c_wvalid), .s_wready(c_wready),
        .s_bresp(c_bresp), .s_bvalid(c_bvalid), .s_bready(c_bready),
        .s_araddr(c_araddr), .s_arlen(c_arlen), .s_arsize(c_arsize),
        .s_arburst(c_arburst), .s_arvalid(c_arvalid),
        .s_arready(c_arready),
        .s_rdata(c_rdata), .s_rresp(c_rresp), .s_rlast(c_rlast),
        .s_rvalid(c_rvalid), .s_rready(c_rready),
        .m_req(h_req), .m_we(h_we), .m_addr(h_addr),
        .m_wdata(h_wdata), .m_wstrb(h_wstrb),
        .m_ack(h_ack), .m_rdata(h_rdata));

    // The memory bundle, declared before every consumer (smol68k's synth
    // log found an implicit one-bit net here once).
    wire        m_req, m_we, m_ack;
    wire [2:0]  mem_len;
    wire [63:0] m_addr, m_wdata, m_rdata;
    wire [7:0]  m_wstrb;
    wire        init_calib_complete, dram_err, dram_wedged;
    wire [31:0] wr_done, rd_done;
    wire        con_valid, core_sleep, soft_rst, trace_valid;
    wire [7:0]  con_char;
    wire [3:0]  led_fpga;
    wire [31:0] trace_pc, trace_insn;

    // ------------------------------------------------------------------
    // the design: everything inward of the req/ack bus
    // ------------------------------------------------------------------
    sh5_top #(.BUILD_ID(BUILD_ID), .BUILD_CFG(BUILD_CFG), .CLK_HZ(CLK_HZ),
              .AUTOSTART(1'b0)) soc (
        .clk(clk), .rst_n(~rst),
        .h_req(h_req), .h_we(h_we), .h_addr(h_addr),
        .h_wdata(h_wdata), .h_wstrb(h_wstrb),
        .h_ack(h_ack), .h_rdata(h_rdata), .h_err(h_err),
        // the board takes no interrupt (see the endpoint above)
        .msi(),
        .calib_complete(init_calib_complete),
        .dram_err(dram_err), .dram_wedged(dram_wedged),
        .wr_in(rd_done), .wr_out(wr_done),
        .mem_req(m_req), .mem_we(m_we), .mem_addr(m_addr),
        .mem_wdata(m_wdata), .mem_wstrb(m_wstrb), .mem_len(mem_len),
        .mem_ack(m_ack), .mem_rdata(m_rdata), .mem_err(dram_err),
        .con_valid(con_valid), .con_char(con_char), .led(led_fpga),
        .core_sleep(core_sleep), .soft_rst(soft_rst),
        .trace_valid(trace_valid), .trace_pc(trace_pc), .trace_insn(trace_insn));

    // ------------------------------------------------------------------
    // the memory path (smol68k's wiring; the reset contract is in
    // fpgaslop/rtl/mem_cdc.sv and in smol68k's board top at this point)
    // ------------------------------------------------------------------
    wire        b_rd_ready;
    wire [2:0]  b_len;
    wire        b_req, b_we, b_ack;
    wire [63:0] b_addr, b_wdata, b_rdata;
    wire [7:0]  b_wstrb;
    wire        ui_clk, ui_clk_sync_rst;

    // sh5_mem_cdc (rtl/soc) in place of fpgaslop's mem_cdc: the same ports
    // and reset contract, FIFOs instead of a four-phase handshake, so a
    // burst crosses once and its beats stream (rtl/tb/cdc measures it).
    wire b_wr_ready;
    sh5_mem_cdc dram_cdc (
        .a_clk(clk), .a_rst(rst),
        .a_req(m_req), .a_we(m_we), .a_addr(m_addr),
        .a_wdata(m_wdata), .a_wstrb(m_wstrb),
        .a_ack(m_ack), .a_rdata(m_rdata),
        .b_clk(ui_clk), .b_rst(ui_clk_sync_rst),
        .b_req(b_req), .b_we(b_we), .b_addr(b_addr),
        .b_wdata(b_wdata), .b_wstrb(b_wstrb),
        .b_ack(b_ack), .b_rdata(b_rdata),
        .a_len(mem_len), .b_len(b_len), .b_rd_ready(b_rd_ready), .b_wr_ready(b_wr_ready));

    localparam int DDR_ADDR_WIDTH = 30;   // rank 1 + bank 3 + row 16 + col 10
    localparam int DDR_DATA_WIDTH = 64;

    wire [3:0]  ax_awid, ax_arid, ax_bid, ax_rid;
    wire [DDR_ADDR_WIDTH-1:0] ax_awaddr, ax_araddr;
    wire [7:0]  ax_awlen, ax_arlen;
    wire [2:0]  ax_awsize, ax_arsize;
    wire [1:0]  ax_awburst, ax_arburst;
    wire [0:0]  ax_awlock, ax_arlock;
    wire [3:0]  ax_awcache, ax_arcache, ax_awqos, ax_arqos;
    wire [2:0]  ax_awprot, ax_arprot;
    wire        ax_awvalid, ax_awready, ax_arvalid, ax_arready;
    wire [DDR_DATA_WIDTH-1:0] ax_wdata, ax_rdata;
    wire [(DDR_DATA_WIDTH/8)-1:0] ax_wstrb;
    wire        ax_wlast, ax_wvalid, ax_wready;
    wire [1:0]  ax_bresp, ax_rresp;
    wire        ax_bvalid, ax_bready, ax_rvalid, ax_rready, ax_rlast;

    // Line reads and write-backs burst (sh5_shwy_req sets mem_len for a
    // Load32/Store32 block). rd_ready and wr_ready come from the crossing's
    // FIFOs: room for the next read beat, the next write beat present.
    req_to_axi4 #(.ADDR_WIDTH(DDR_ADDR_WIDTH),
                  .DATA_WIDTH(DDR_DATA_WIDTH),
                  .ID_WIDTH(4)) adapt (
        .clk(ui_clk), .rst(ui_clk_sync_rst),
        .req(b_req), .we(b_we), .addr(b_addr),
        .wdata(b_wdata), .wstrb(b_wstrb),
        .ack(b_ack), .rdata(b_rdata),
        .err(dram_err), .wedged_o(dram_wedged), .wr_done(wr_done),
        .init_calib_complete(init_calib_complete),
        .req_len(b_len), .rd_ready(b_rd_ready), .wr_ready(b_wr_ready),
        .m_awid(ax_awid), .m_awaddr(ax_awaddr), .m_awlen(ax_awlen),
        .m_awsize(ax_awsize), .m_awburst(ax_awburst),
        .m_awlock(ax_awlock), .m_awcache(ax_awcache),
        .m_awprot(ax_awprot), .m_awqos(ax_awqos),
        .m_awvalid(ax_awvalid), .m_awready(ax_awready),
        .m_wdata(ax_wdata), .m_wstrb(ax_wstrb), .m_wlast(ax_wlast),
        .m_wvalid(ax_wvalid), .m_wready(ax_wready),
        .m_bid(ax_bid), .m_bresp(ax_bresp), .m_bvalid(ax_bvalid),
        .m_bready(ax_bready),
        .m_arid(ax_arid), .m_araddr(ax_araddr), .m_arlen(ax_arlen),
        .m_arsize(ax_arsize), .m_arburst(ax_arburst),
        .m_arlock(ax_arlock), .m_arcache(ax_arcache),
        .m_arprot(ax_arprot), .m_arqos(ax_arqos),
        .m_arvalid(ax_arvalid), .m_arready(ax_arready),
        .m_rid(ax_rid), .m_rdata(ax_rdata), .m_rresp(ax_rresp),
        .m_rlast(ax_rlast), .m_rvalid(ax_rvalid), .m_rready(ax_rready));

    logic [31:0] rd_count = 32'd0;
    always_ff @(posedge ui_clk) begin
        if (ui_clk_sync_rst) rd_count <= 32'd0;
        else if (ax_rvalid && ax_rready && ax_rlast) rd_count <= rd_count + 1;
    end
    assign rd_done = rd_count;

    sh5_ddr3 mig (
        .sys_clk_i(clk200g),
        .sys_rst(pci_reset_n),
        .ddr3_dq(ddr3_dq), .ddr3_dqs_p(ddr3_dqs_p), .ddr3_dqs_n(ddr3_dqs_n),
        .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba),
        .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n),
        .ddr3_we_n(ddr3_we_n), .ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cke(ddr3_cke), .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt),
        .ui_clk(ui_clk), .ui_clk_sync_rst(ui_clk_sync_rst),
        .mmcm_locked(), .aresetn(1'b1),
        .app_sr_req(1'b0), .app_ref_req(1'b0), .app_zq_req(1'b0),
        .app_sr_active(), .app_ref_ack(), .app_zq_ack(),
        .init_calib_complete(init_calib_complete),
        .device_temp(),
        .s_axi_awid(ax_awid), .s_axi_awaddr(ax_awaddr),
        .s_axi_awlen(ax_awlen), .s_axi_awsize(ax_awsize),
        .s_axi_awburst(ax_awburst), .s_axi_awlock(ax_awlock),
        .s_axi_awcache(ax_awcache), .s_axi_awprot(ax_awprot),
        .s_axi_awqos(ax_awqos), .s_axi_awvalid(ax_awvalid),
        .s_axi_awready(ax_awready),
        .s_axi_wdata(ax_wdata), .s_axi_wstrb(ax_wstrb),
        .s_axi_wlast(ax_wlast), .s_axi_wvalid(ax_wvalid),
        .s_axi_wready(ax_wready),
        .s_axi_bid(ax_bid), .s_axi_bresp(ax_bresp),
        .s_axi_bvalid(ax_bvalid), .s_axi_bready(ax_bready),
        .s_axi_arid(ax_arid), .s_axi_araddr(ax_araddr),
        .s_axi_arlen(ax_arlen), .s_axi_arsize(ax_arsize),
        .s_axi_arburst(ax_arburst), .s_axi_arlock(ax_arlock),
        .s_axi_arcache(ax_arcache), .s_axi_arprot(ax_arprot),
        .s_axi_arqos(ax_arqos), .s_axi_arvalid(ax_arvalid),
        .s_axi_arready(ax_arready),
        .s_axi_rid(ax_rid), .s_axi_rdata(ax_rdata),
        .s_axi_rresp(ax_rresp), .s_axi_rlast(ax_rlast),
        .s_axi_rvalid(ax_rvalid), .s_axi_rready(ax_rready));

    // ------------------------------------------------------------------
    // LEDs: 0 link up, 1 DDR3 calibrated, 2 the core is retiring
    // instructions (stretched heartbeat), 3 bit 0 of the system FPGA
    // LEDCR register, which the kernels drive
    // ------------------------------------------------------------------
    logic [23:0] hb_cnt = 24'd0;
    logic        hb     = 1'b0;
    always_ff @(posedge clk) begin
        if (rst) begin
            hb_cnt <= 24'd0;
            hb     <= 1'b0;
        end else if (trace_valid) begin
            hb_cnt <= 24'hFFFFFF;
            hb     <= 1'b1;
        end else if (hb_cnt != 24'd0) begin
            hb_cnt <= hb_cnt - 1'b1;
        end else begin
            hb     <= 1'b0;
        end
    end

    wire [3:0] led_i = {led_fpga[0], hb, init_calib_complete, pcie_lnk_up};
    assign led = LED_ACTIVE_LOW ? ~led_i : led_i;

    // con_valid/con_char and the trace are observation only; the console
    // reaches the host through the hub FIFO over the BAR.
    wire unused_ok = &{1'b0, con_valid, con_char, core_sleep, soft_rst, trace_pc, trace_insn,
                       pcie_mmcm_lock, h_err, led_fpga[3:1], 1'b0};

endmodule
