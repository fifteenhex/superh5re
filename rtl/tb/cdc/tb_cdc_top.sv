// tb_cdc_top.sv - memarb -> sh5_mem_cdc -> req_to_axi4, the board's memory
// path with our crossing in the middle. The shape of fpgaslop's
// tb_memchain_top (its header says why the seam between the blocks is
// where bugs live); the AXI slave is in tb_cdc.cpp.
`default_nettype none
module tb_cdc_top (
    input  var logic        a_clk,
    input  var logic        a_rst,
    input  var logic        b_clk,
    input  var logic        b_rst,
    // memarb port A -- the core's bridge
    input  var logic        cpu_req,
    input  var logic        cpu_we,
    input  var logic [63:0] cpu_addr,
    input  var logic [63:0] cpu_wdata,
    input  var logic [7:0]  cpu_wstrb,
    input  var logic [2:0]  cpu_len,
    output var logic        cpu_ack,
    output var logic [63:0] cpu_rdata,
    // memarb port B -- the host window
    input  var logic        host_req,
    input  var logic        host_we,
    input  var logic [63:0] host_addr,
    input  var logic [63:0] host_wdata,
    input  var logic [7:0]  host_wstrb,
    output var logic        host_ack,
    output var logic [63:0] host_rdata,
    // AXI4 out of req_to_axi4, modelled in C++
    output var logic [31:0] m_awaddr,
    output var logic [7:0]  m_awlen,
    output var logic        m_awvalid,
    input  var logic        m_awready,
    output var logic [63:0] m_wdata,
    output var logic [7:0]  m_wstrb,
    output var logic        m_wlast,
    output var logic        m_wvalid,
    input  var logic        m_wready,
    input  var logic [1:0]  m_bresp,
    input  var logic        m_bvalid,
    output var logic        m_bready,
    output var logic [31:0] m_araddr,
    output var logic [7:0]  m_arlen,
    output var logic        m_arvalid,
    input  var logic        m_arready,
    input  var logic [63:0] m_rdata,
    input  var logic [1:0]  m_rresp,
    input  var logic        m_rlast,
    input  var logic        m_rvalid,
    output var logic        m_rready,
    output var logic [31:0] wr_done,
    // observation
    output var logic        o_m_req, o_m_ack, o_b_req, o_b_ack, o_b_wr_ready, o_b_rd_ready,
    output var logic [1:0]  o_a_st, o_b_st,
    output var logic        o_cmd_empty, o_cmd_full, o_wd_empty, o_rd_empty
);
    logic        m_req, m_we, m_ack;
    logic [63:0] m_addr, m_wdata_w, m_rdata_w;
    logic [7:0]  m_wstrb_w;
    logic [2:0]  m_len;
    memarb arb (
        .clk(a_clk), .rst(a_rst),
        .a_req(cpu_req), .a_we(cpu_we), .a_addr(cpu_addr),
        .a_wdata(cpu_wdata), .a_wstrb(cpu_wstrb), .a_len(cpu_len),
        .a_ack(cpu_ack), .a_rdata(cpu_rdata),
        .b_req(host_req), .b_we(host_we), .b_addr(host_addr),
        .b_wdata(host_wdata), .b_wstrb(host_wstrb), .b_len(3'd0),
        .b_ack(host_ack), .b_rdata(host_rdata),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr),
        .m_wdata(m_wdata_w), .m_wstrb(m_wstrb_w), .m_len(m_len),
        .m_ack(m_ack), .m_rdata(m_rdata_w)
    );
    logic        b_req, b_we, b_ack, b_rd_ready, b_wr_ready;
    logic [63:0] b_addr, b_wdata, b_rdata;
    logic [7:0]  b_wstrb;
    logic [2:0]  b_len;
    sh5_mem_cdc cdc (
        .a_clk(a_clk), .a_rst(a_rst),
        .a_req(m_req), .a_we(m_we), .a_addr(m_addr),
        .a_wdata(m_wdata_w), .a_wstrb(m_wstrb_w), .a_len(m_len),
        .a_ack(m_ack), .a_rdata(m_rdata_w),
        .b_clk(b_clk), .b_rst(b_rst),
        .b_req(b_req), .b_we(b_we), .b_addr(b_addr),
        .b_wdata(b_wdata), .b_wstrb(b_wstrb), .b_len(b_len),
        .b_ack(b_ack), .b_rdata(b_rdata),
        .b_rd_ready(b_rd_ready), .b_wr_ready(b_wr_ready)
    );
    assign o_m_req = m_req; assign o_m_ack = m_ack; assign o_b_req = b_req; assign o_b_ack = b_ack;
    assign o_b_wr_ready = b_wr_ready; assign o_b_rd_ready = b_rd_ready;
    assign o_a_st = cdc.a_st; assign o_b_st = cdc.b_st;
    assign o_cmd_empty = cdc.cmd_empty; assign o_cmd_full = cdc.cmd_full; assign o_wd_empty = cdc.wd_empty; assign o_rd_empty = cdc.rd_empty;
    req_to_axi4 #(.ADDR_WIDTH(32), .DATA_WIDTH(64)) bridge (
        .clk(b_clk), .rst(b_rst),
        .req(b_req), .we(b_we), .addr(b_addr),
        .wdata(b_wdata), .wstrb(b_wstrb),
        .ack(b_ack), .rdata(b_rdata),
        .req_len(b_len), .rd_ready(b_rd_ready), .wr_ready(b_wr_ready),
        .err(), .wedged_o(), .wr_done(wr_done),
        .init_calib_complete(1'b1),
        .m_awid(), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
        .m_awsize(), .m_awburst(), .m_awlock(), .m_awcache(),
        .m_awprot(), .m_awqos(),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
        .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bid(4'd0), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
        .m_bready(m_bready),
        .m_arid(), .m_araddr(m_araddr), .m_arlen(m_arlen),
        .m_arsize(), .m_arburst(), .m_arlock(), .m_arcache(),
        .m_arprot(), .m_arqos(),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rid(4'd0), .m_rdata(m_rdata), .m_rresp(m_rresp),
        .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready)
    );
endmodule
`default_nettype wire
