// Instruction fetch: 8-byte blocks into a 4-entry queue, one instruction
// per cycle to decode. No cache in this revision (MMU off, Load8 per block).
// Responses arrive in request order; responses issued before a redirect are
// dropped.

module sh5_ifu (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        redirect_i,       // flush and restart at redirect_pc_i
  input  logic [31:0] redirect_pc_i,
  input  logic        fetch_en_i,       // 0: do not issue new fetches

  output logic        insn_valid_o,
  output logic [31:0] insn_o,
  output logic [31:0] insn_pc_o,
  output logic [11:0] insn_fault_o,    // fetch exception code for this block, 0 = none
  input  logic        consume_i,

  output logic        req_valid_o,
  input  logic        req_ready_i,
  output logic [31:3] req_addr_o,
  input  logic        rsp_valid_i,
  input  logic [63:0] rsp_data_i,
  input  logic [11:0] rsp_fault_i
);

  logic [31:3] q_addr [4];
  logic [63:0] q_data [4];
  logic [11:0] q_fault [4];
  logic [1:0]  q_rd_q, q_wr_q;
  logic [2:0]  q_cnt_q;        // filled entries
  logic        half_q;         // 0: low word of the head block is next
  logic [31:3] fetch_pc_q;     // next block to request
  logic [2:0]  inflight_q;     // live requests outstanding
  logic [2:0]  stale_q;        // pre-redirect requests outstanding (responses dropped)

  logic issue, rsp_live, rsp_stale, pop;

  assign req_valid_o = fetch_en_i && !redirect_i && ((q_cnt_q + inflight_q) < 3'd4);
  assign req_addr_o  = fetch_pc_q;
  assign issue       = req_valid_o && req_ready_i;

  assign rsp_stale = rsp_valid_i && (stale_q != 3'd0);
  assign rsp_live  = rsp_valid_i && (stale_q == 3'd0);

  assign insn_valid_o = (q_cnt_q != 3'd0);
  assign insn_o       = half_q ? q_data[q_rd_q][63:32] : q_data[q_rd_q][31:0];
  assign insn_pc_o    = {q_addr[q_rd_q], half_q, 2'b00};
  assign insn_fault_o = q_fault[q_rd_q];
  assign pop          = consume_i && insn_valid_o && half_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_rd_q <= 2'd0; q_wr_q <= 2'd0; q_cnt_q <= 3'd0;
      half_q <= 1'b0; fetch_pc_q <= 29'd0;
      inflight_q <= 3'd0; stale_q <= 3'd0;
    end else if (redirect_i) begin
      q_rd_q <= 2'd0; q_wr_q <= 2'd0; q_cnt_q <= 3'd0;
      fetch_pc_q <= redirect_pc_i[31:3];
      half_q <= redirect_pc_i[2];
      // every outstanding request becomes stale; a response this cycle retires one
      stale_q <= stale_q + inflight_q - (rsp_valid_i ? 3'd1 : 3'd0);
      inflight_q <= 3'd0;
    end else begin
      if (rsp_stale) stale_q <= stale_q - 3'd1;
      if (rsp_live) begin
        q_data[q_wr_q] <= rsp_data_i;
        q_fault[q_wr_q] <= rsp_fault_i;
        q_addr[q_wr_q] <= fetch_pc_q - 29'(inflight_q);
        q_wr_q <= q_wr_q + 2'd1;
      end
      inflight_q <= inflight_q + (issue ? 3'd1 : 3'd0) - (rsp_live ? 3'd1 : 3'd0);
      if (issue) fetch_pc_q <= fetch_pc_q + 29'd1;
      q_cnt_q <= q_cnt_q + (rsp_live ? 3'd1 : 3'd0) - (pop ? 3'd1 : 3'd0);
      if (consume_i && insn_valid_o) begin
        half_q <= ~half_q;
        if (half_q) q_rd_q <= q_rd_q + 2'd1;
      end
    end
  end

endmodule
