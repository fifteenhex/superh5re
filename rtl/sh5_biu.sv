// Bus interface unit: turns instruction fetches, data accesses, cache line
// fills and write-backs into bus packets (docs/bus-interface.md).
// Packets: Load8/Store8/Swap8 for single words, Load32/Store32 for 32-byte
// lines (requested with address bits [4:3] = 0, so the beats arrive in
// word order).

module sh5_biu
  import shwy_pkg::*;
#(
  parameter int         TID_BITS   = 3,
  parameter logic [7:0] BUS_SRC_ID = 8'h0d
) (
  input  logic         clk,
  input  logic         rst_n,

  // instruction fetch port: one 8-byte word or a 32-byte line, responses
  // in request order, up to 2 outstanding
  input  logic         if_req_valid_i,
  output logic         if_req_ready_o,
  input  logic         if_req_line_i,
  input  logic [31:3]  if_req_addr_i,
  output logic         if_rsp_valid_o,
  output logic [255:0] if_rsp_data_o,    // word k in [64k +: 64]; single word in word addr[4:3]
  output logic         if_idle_o,        // no fetch outstanding or undelivered

  // data read port: one outstanding access (word load, swap, or line fill)
  input  logic         ld_req_valid_i,
  output logic         ld_req_ready_o,
  input  logic         ld_req_swap_i,
  input  logic         ld_req_line_i,
  input  logic [31:3]  ld_req_addr_i,
  input  logic [7:0]   ld_req_mask_i,
  input  logic [63:0]  ld_req_data_i,    // swap value
  output logic         ld_rsp_valid_o,
  output logic [255:0] ld_rsp_data_o,

  // store port: queued, acknowledged asynchronously; a word store or a line write-back
  input  logic         st_req_valid_i,
  output logic         st_req_ready_o,
  input  logic         st_req_line_i,
  input  logic [31:3]  st_req_addr_i,
  input  logic [7:0]   st_req_mask_i,
  input  logic [255:0] st_req_data_i,    // word store: data in word addr[4:3]
  output logic         st_pending_o,     // stores queued or not yet acknowledged

  output logic         bus_error_o,

  // bus initiator
  output logic        ireq_valid,
  input  logic        ireq_ready,
  output logic [7:0]  ireq_opc,
  output logic [31:0] ireq_addr,
  output logic [7:0]  ireq_src,
  output logic [7:0]  ireq_tid,
  output logic [7:0]  ireq_mask,
  output logic [63:0] ireq_data,
  output logic        ireq_last,
  input  logic        irsp_valid,
  output logic        irsp_ready,
  input  logic [7:0]  irsp_opc,
  input  logic [7:0]  irsp_src,
  input  logic [7:0]  irsp_tid,
  input  logic [63:0] irsp_data,
  input  logic        irsp_last
);

  localparam int NTID = 1 << TID_BITS;

  // ------------------------------------------------------------------
  // Store queue (4 entries)
  logic         sq_line [4];
  logic [31:3]  sq_addr [4];
  logic [7:0]   sq_mask [4];
  logic [255:0] sq_data [4];
  logic [1:0]   sq_rd_q, sq_wr_q;
  logic [2:0]   sq_cnt_q;
  logic [1:0]   sq_beat_q;          // beat of a Store32 in progress
  logic         sq_full, sq_empty;
  logic [3:0]   st_outstanding_q;   // issued, awaiting Success/Failure

  assign sq_full  = (sq_cnt_q == 3'd4);
  assign sq_empty = (sq_cnt_q == 3'd0);
  assign st_req_ready_o = !sq_full;
  assign st_pending_o   = !sq_empty || (st_outstanding_q != 4'd0);

  // ------------------------------------------------------------------
  // Fetch tracking: up to 2 outstanding, in-order delivery
  logic         if_busy_q [2];
  logic         if_done_q [2];
  logic [255:0] if_data_q [2];
  logic [1:0]   if_beat_q [2];
  logic         if_issue_q;    // next slot to allocate
  logic         if_retire_q;   // next slot to deliver

  // data read tracking
  logic         ld_busy_q;
  logic         ld_done_q;
  logic [255:0] ld_data_q;
  logic [1:0]   ld_beat_q;

  // ------------------------------------------------------------------
  // Request arbitration: store queue head > load > fetch. A Store32 holds
  // the bus for its four beats.
  logic do_store, do_load, do_fetch;
  logic st_slot_free, st_in_burst;

  assign st_slot_free = (st_outstanding_q != 4'd15);
  assign st_in_burst  = (sq_beat_q != 2'd0);
  assign do_store = !sq_empty && (st_slot_free || st_in_burst);
  assign do_load  = !do_store && ld_req_valid_i && !ld_busy_q && !ld_done_q;
  assign do_fetch = !do_store && !do_load && if_req_valid_i && !if_busy_q[if_issue_q] && !if_done_q[if_issue_q];

  assign ireq_valid = do_store || do_load || do_fetch;
  assign ireq_src   = BUS_SRC_ID;
  assign ld_req_ready_o = do_load && ireq_ready;
  assign if_req_ready_o = do_fetch && ireq_ready;

  always_comb begin
    ireq_last = 1'b1;
    if (do_store) begin
      ireq_opc  = sq_line[sq_rd_q] ? OPC_STORE32 : OPC_STORE8;
      ireq_addr = sq_line[sq_rd_q] ? {sq_addr[sq_rd_q][31:5], 5'b00000} : {sq_addr[sq_rd_q], 3'b000};
      ireq_tid  = 8'h81;
      ireq_mask = sq_line[sq_rd_q] ? 8'hff : sq_mask[sq_rd_q];
      ireq_data = sq_line[sq_rd_q] ? sq_data[sq_rd_q][64 * sq_beat_q +: 64]
                                   : sq_data[sq_rd_q][64 * sq_addr[sq_rd_q][4:3] +: 64];
      ireq_last = !sq_line[sq_rd_q] || (sq_beat_q == 2'd3);
    end else if (do_load) begin
      ireq_opc  = ld_req_swap_i ? OPC_SWAP8 : (ld_req_line_i ? OPC_LOAD32 : OPC_LOAD8);
      ireq_addr = ld_req_line_i ? {ld_req_addr_i[31:5], 5'b00000} : {ld_req_addr_i, 3'b000};
      ireq_tid  = 8'h80;
      ireq_mask = ld_req_line_i ? 8'hff : ld_req_mask_i;
      ireq_data = ld_req_data_i;
    end else begin
      ireq_opc  = if_req_line_i ? OPC_LOAD32 : OPC_LOAD8;
      ireq_addr = if_req_line_i ? {if_req_addr_i[31:5], 5'b00000} : {if_req_addr_i, 3'b000};
      ireq_tid  = {7'h00, if_issue_q};
      ireq_mask = 8'hff;
      ireq_data = 64'h0;
    end
  end

  // ------------------------------------------------------------------
  // Responses
  assign irsp_ready = 1'b1;
  logic rsp_fail;
  assign rsp_fail = irsp_valid && irsp_last && (irsp_opc == OPC_FAILURE);
  assign bus_error_o = rsp_fail;

  assign if_rsp_valid_o = if_done_q[if_retire_q];
  assign if_rsp_data_o  = if_data_q[if_retire_q];
  assign if_idle_o = !if_busy_q[0] && !if_busy_q[1] && !if_done_q[0] && !if_done_q[1];
  assign ld_rsp_valid_o = ld_done_q;
  assign ld_rsp_data_o  = ld_data_q;

  // addresses of the outstanding requests, to place single words in their lane
  logic [1:0] if_word_q [2];
  logic [1:0] ld_word_q;
  logic       ld_line_q;
  logic       if_line_q [2];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sq_rd_q <= 2'd0; sq_wr_q <= 2'd0; sq_cnt_q <= 3'd0; sq_beat_q <= 2'd0;
      st_outstanding_q <= 4'd0;
      if_busy_q[0] <= 1'b0; if_busy_q[1] <= 1'b0;
      if_done_q[0] <= 1'b0; if_done_q[1] <= 1'b0;
      if_beat_q[0] <= 2'd0; if_beat_q[1] <= 2'd0;
      if_word_q[0] <= 2'd0; if_word_q[1] <= 2'd0;
      if_line_q[0] <= 1'b0; if_line_q[1] <= 1'b0;
      if_issue_q <= 1'b0; if_retire_q <= 1'b0;
      ld_busy_q <= 1'b0; ld_done_q <= 1'b0; ld_beat_q <= 2'd0; ld_word_q <= 2'd0; ld_line_q <= 1'b0;
      ld_data_q <= '0;
      if_data_q[0] <= '0; if_data_q[1] <= '0;
    end else begin
      // store queue push
      if (st_req_valid_i && !sq_full) begin
        sq_line[sq_wr_q] <= st_req_line_i;
        sq_addr[sq_wr_q] <= st_req_addr_i;
        sq_mask[sq_wr_q] <= st_req_mask_i;
        sq_data[sq_wr_q] <= st_req_data_i;
        sq_wr_q <= sq_wr_q + 2'd1;
      end
      // issue
      if (ireq_valid && ireq_ready) begin
        if (do_store) begin
          if (ireq_last) begin
            sq_rd_q <= sq_rd_q + 2'd1;
            sq_beat_q <= 2'd0;
          end else begin
            sq_beat_q <= sq_beat_q + 2'd1;
          end
        end else if (do_load) begin
          ld_busy_q <= 1'b1;
          ld_beat_q <= 2'd0;
          ld_word_q <= ld_req_addr_i[4:3];
          ld_line_q <= ld_req_line_i;
        end else begin
          if_busy_q[if_issue_q] <= 1'b1;
          if_beat_q[if_issue_q] <= 2'd0;
          if_word_q[if_issue_q] <= if_req_addr_i[4:3];
          if_line_q[if_issue_q] <= if_req_line_i;
          if_issue_q <= ~if_issue_q;
        end
      end
      // queue count: pop when the last beat of a store goes out
      case ({st_req_valid_i && !sq_full, ireq_valid && ireq_ready && do_store && ireq_last})
        2'b10: sq_cnt_q <= sq_cnt_q + 3'd1;
        2'b01: sq_cnt_q <= sq_cnt_q - 3'd1;
        default: ;
      endcase
      // outstanding stores
      case ({ireq_valid && ireq_ready && do_store && ireq_last,
             irsp_valid && irsp_last && irsp_tid == 8'h81})
        2'b10: st_outstanding_q <= st_outstanding_q + 4'd1;
        2'b01: st_outstanding_q <= st_outstanding_q - 4'd1;
        default: ;
      endcase
      // responses: beats of a line are placed in word order; a single word
      // goes to its lane
      if (irsp_valid) begin
        if (irsp_tid == 8'h80) begin
          if (ld_line_q) ld_data_q[64 * ld_beat_q +: 64] <= (irsp_opc == OPC_SUCCESS) ? irsp_data : 64'h0;
          else           ld_data_q[64 * ld_word_q +: 64] <= (irsp_opc == OPC_SUCCESS) ? irsp_data : 64'h0;
          ld_beat_q <= ld_beat_q + 2'd1;
          if (irsp_last) begin
            ld_busy_q <= 1'b0;
            ld_done_q <= 1'b1;
          end
        end else if (irsp_tid[7] == 1'b0) begin
          if (if_line_q[irsp_tid[0]])
            if_data_q[irsp_tid[0]][64 * if_beat_q[irsp_tid[0]] +: 64] <= (irsp_opc == OPC_SUCCESS) ? irsp_data : 64'h0;
          else
            if_data_q[irsp_tid[0]][64 * if_word_q[irsp_tid[0]] +: 64] <= (irsp_opc == OPC_SUCCESS) ? irsp_data : 64'h0;
          if_beat_q[irsp_tid[0]] <= if_beat_q[irsp_tid[0]] + 2'd1;
          if (irsp_last) begin
            if_busy_q[irsp_tid[0]] <= 1'b0;
            if_done_q[irsp_tid[0]] <= 1'b1;
          end
        end
      end
      // delivery: the consumer takes the response in the cycle it is valid
      if (ld_done_q) ld_done_q <= 1'b0;
      if (if_done_q[if_retire_q]) begin
        if_done_q[if_retire_q] <= 1'b0;
        if_retire_q <= ~if_retire_q;
      end
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, irsp_src, NTID[0], 1'b0};

endmodule
