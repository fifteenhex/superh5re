// sh5_shwy_req.sv - the core's SuperHyway-style packet port -> fpgaslop's
// req/ack bus (docs/bus-interface.md, fpgaslop docs/proposal-shared-soc-blocks.md).
//
// One request packet at a time: the core may have several outstanding
// (two fetches, a load, four stores) and tolerates responses in any order,
// so serialising them here is legal; it costs bandwidth, not correctness.
//
//   Load8          one read beat
//   Load16/Load32  a burst read of 2/4 beats (m_len = 1/3) from the aligned
//                  block, answered to the core critical word first (SA Vol. 3
//                  Tables 79/80): the response starts at the word in
//                  ADDR[4:3] and wraps
//   Store8         one write beat, wstrb = MSK
//   Store16/32     to RAM: one burst write of 2/4 beats, ascending words of
//                  the block, each beat's data and mask presented until its
//                  ack (fpgaslop docs/porting-write-bursts.md: memarb,
//                  mem_cdc and req_to_axi4 carry write bursts, req_to_axi4's
//                  wr_ready must come from the crossing); elsewhere, single
//                  beats in the order the core sent them
//   Swap8          read then write of one word; the response carries the old
//                  value. Atomic against the core (it is the only initiator
//                  here); the host's DRAM window may interleave between the
//                  two beats at the arbiter -- acceptable for a host that
//                  deposits images and reads results
//   anything else  Failure
//
// The target decides the address: `m_sel_ram` is set for the DRAM window
// (ADDR[31:28] = 0x8, 256 MB) with the DDR3 byte address in m_addr; every
// other address goes out unchanged for the peripherals. Addresses outside
// both get a Failure response without a bus transaction.
//
// req is held until ack and dropped for a cycle afterwards; for a burst it
// stays up across the beats (req_to_axi4's contract). m_err sampled with an
// ack turns the response into Failure.
module sh5_shwy_req
  import shwy_pkg::*;
#(
  parameter logic [31:0] RAM_BASE = 32'h8000_0000,
  parameter int          RAM_BITS = 28            // 256 MB window
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- initiator request / response of the core ----
  input  logic        ireq_valid,
  output logic        ireq_ready,
  input  logic [7:0]  ireq_opc,
  input  logic [31:0] ireq_addr,
  input  logic [7:0]  ireq_src,
  input  logic [7:0]  ireq_tid,
  input  logic [7:0]  ireq_mask,
  input  logic [63:0] ireq_data,
  input  logic        ireq_last,
  output logic        irsp_valid,
  input  logic        irsp_ready,
  output logic [7:0]  irsp_opc,
  output logic [7:0]  irsp_src,
  output logic [7:0]  irsp_tid,
  output logic [63:0] irsp_data,
  output logic        irsp_last,

  // ---- req/ack master ----
  output logic        m_req,
  output logic        m_we,
  output logic        m_sel_ram,     // DRAM window (m_addr is the DDR3 byte address)
  output logic [63:0] m_addr,
  output logic [63:0] m_wdata,
  output logic [7:0]  m_wstrb,
  output logic [2:0]  m_len,         // beats - 1 of a burst read
  input  logic        m_ack,
  input  logic [63:0] m_rdata,
  input  logic        m_err,

  output logic        idle_o
);

  typedef enum logic [2:0] { S_COLLECT, S_ISSUE, S_WAIT, S_GAP, S_RESPOND } state_t;
  state_t state_q;

  // the packet
  logic [7:0]  opc_q, src_q, tid_q;
  logic [31:0] addr_q;
  logic [63:0] data_q [4];
  logic [7:0]  mask_q [4];
  logic [1:0]  nbeat_q;         // data beats collected
  // execution
  logic [2:0]  beat_q;          // beats done (reads: received; writes: issued)
  logic [2:0]  nbeats;          // beats of the transaction minus one
  logic        is_load, is_store, is_swap, swap_wr_q, fail_q;
  logic [63:0] rd_q [4];
  logic        in_ram, in_periph;
  logic [1:0]  first;           // critical word
  logic [1:0]  wr_word;         // word of the current single-beat write

  assign is_load  = (opc_q == OPC_LOAD8) || (opc_q == OPC_LOAD16) || (opc_q == OPC_LOAD32);
  assign is_store = (opc_q == OPC_STORE8) || (opc_q == OPC_STORE32) || (opc_q == OPC_STORE16);
  assign is_swap  = (opc_q == OPC_SWAP8);
  assign nbeats   = (opc_q == OPC_LOAD32 || opc_q == OPC_STORE32) ? 3'd3 :
                    (opc_q == OPC_LOAD16 || opc_q == OPC_STORE16) ? 3'd1 : 3'd0;
  assign first    = (nbeats == 3'd3) ? addr_q[4:3] : (nbeats == 3'd1) ? {1'b0, addr_q[3]} : 2'd0;
  assign in_ram   = (addr_q[31:RAM_BITS] == RAM_BASE[31:RAM_BITS]);
  // peripheral windows this system implements (sh5_periph.sv)
  assign in_periph = (addr_q[31:20] == 12'h0a0) ||          // INTC CPRC TMU SCIF RTC
                     (addr_q[31:16] == 16'h0400) ||          // system FPGA
                     (addr_q[31:24] == 8'h0d) || (addr_q[31:24] == 8'h09) || (addr_q[31:24] == 8'h08) ||  // VCRs
                     (addr_q[31:20] == 12'h0c1);             // debug module (writes ignored)

  // bus side
  logic burst_rd, burst_wr;
  assign burst_rd  = in_ram && is_load && (nbeats != 3'd0);
  assign burst_wr  = in_ram && is_store && (nbeats != 3'd0);
  // word written by write beat k: ascending in a burst, else the order the core sent them
  assign wr_word = burst_wr ? beat_q[1:0] :
                   (nbeats == 3'd3) ? (first + beat_q[1:0]) : (nbeats == 3'd1) ? {1'b0, first[0] ^ beat_q[0]} : addr_q[4:3];
  // the collected beat holding that word: beat k of the packet is word first + k
  logic [1:0] wr_idx;
  assign wr_idx = (nbeats == 3'd3) ? (wr_word - first) : (nbeats == 3'd1) ? {1'b0, wr_word[0] ^ first[0]} : 2'd0;
  assign m_req     = (state_q == S_WAIT);      // S_ISSUE decodes; a failing address never reaches the bus
  assign m_we      = is_store || (is_swap && swap_wr_q);
  assign m_sel_ram = in_ram;
  assign m_len     = (burst_rd || burst_wr) ? nbeats : 3'd0;
  always_comb begin
    logic [31:0] a;
    a = addr_q;
    if (burst_rd || burst_wr) a = {addr_q[31:5], 5'b00000};           // the whole block, ascending
    else if (is_store && nbeats != 3'd0) a = {addr_q[31:5], wr_word, 3'b000};
    else if (is_load && nbeats != 3'd0) a = {addr_q[31:5], first + beat_q[1:0], 3'b000};  // word by word, critical first
    m_addr = in_ram ? {36'h0, a[RAM_BITS-1:0]} : {32'h0, a};
  end
  assign m_wdata = is_swap ? data_q[0] : data_q[wr_idx];
  assign m_wstrb = is_swap ? mask_q[0] : mask_q[wr_idx];

  assign ireq_ready = (state_q == S_COLLECT);
  assign idle_o     = (state_q == S_COLLECT) && !ireq_valid;

  // response beats: critical word first
  logic [2:0] rsp_beat_q;
  logic [1:0] rsp_word;
  assign rsp_word   = (nbeats == 3'd3) ? (first + rsp_beat_q[1:0]) : (nbeats == 3'd1) ? {1'b0, first[0] ^ rsp_beat_q[0]} : 2'd0;
  assign irsp_valid = (state_q == S_RESPOND);
  assign irsp_opc   = fail_q ? OPC_FAILURE : OPC_SUCCESS;
  assign irsp_src   = src_q;
  assign irsp_tid   = tid_q;
  assign irsp_data  = burst_rd ? rd_q[rsp_word] : rd_q[rsp_beat_q[1:0]];
  assign irsp_last  = fail_q || !(is_load || is_swap) || (rsp_beat_q == nbeats);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_COLLECT;
      opc_q <= 8'h0; src_q <= 8'h0; tid_q <= 8'h0; addr_q <= 32'h0;
      nbeat_q <= 2'd0; beat_q <= 3'd0; swap_wr_q <= 1'b0; fail_q <= 1'b0; rsp_beat_q <= 3'd0;
      for (int k = 0; k < 4; k++) begin data_q[k] <= 64'h0; mask_q[k] <= 8'h0; rd_q[k] <= 64'h0; end
    end else begin
      case (state_q)
        S_COLLECT: begin
          if (ireq_valid) begin
            if (nbeat_q == 2'd0) begin
              opc_q <= ireq_opc; src_q <= ireq_src; tid_q <= ireq_tid; addr_q <= ireq_addr;
            end
            data_q[nbeat_q] <= ireq_data;
            mask_q[nbeat_q] <= ireq_mask;
            nbeat_q <= nbeat_q + 2'd1;
            if (ireq_last) begin
              nbeat_q <= 2'd0; beat_q <= 3'd0; rsp_beat_q <= 3'd0; swap_wr_q <= 1'b0; fail_q <= 1'b0;
              state_q <= S_ISSUE;
            end
          end
        end
        S_ISSUE: begin
          // decode once the packet is complete (opc_q etc. are valid now)
          if (!(is_load || is_store || is_swap) || !(in_ram || in_periph)) begin
            fail_q <= 1'b1;
            state_q <= S_RESPOND;
          end else begin
            state_q <= S_WAIT;
          end
        end
        S_WAIT: begin
          if (m_ack) begin
            if (m_err) fail_q <= 1'b1;
            if (is_load) begin
              if (burst_rd) rd_q[beat_q[1:0]] <= m_rdata;        // ascending words of the block
              else          rd_q[beat_q[1:0]] <= m_rdata;        // beat order = critical word first
            end
            if (is_swap && !swap_wr_q) rd_q[0] <= m_rdata;
            if (burst_rd || burst_wr) begin
              // one bus transaction, several acks
              beat_q <= beat_q + 3'd1;
              if (beat_q == nbeats) state_q <= S_RESPOND;
            end else begin
              beat_q <= beat_q + 3'd1;
              state_q <= S_GAP;
            end
          end
        end
        S_GAP: begin
          // req low for a cycle between single-beat transactions
          if (is_swap && !swap_wr_q) begin
            swap_wr_q <= 1'b1; state_q <= S_ISSUE;
          end else if (beat_q <= nbeats && !is_swap) begin
            state_q <= S_ISSUE;
          end else begin
            state_q <= S_RESPOND;
          end
        end
        S_RESPOND: begin
          if (irsp_ready) begin
            rsp_beat_q <= rsp_beat_q + 3'd1;
            if (irsp_last) begin
              state_q <= S_COLLECT;
              rsp_beat_q <= 3'd0;
            end
          end
        end
        default: state_q <= S_COLLECT;
      endcase
    end
  end

endmodule
