// sh5_mem_cdc.sv - the memory port across into the controller's clock, with
// FIFOs. Same ports and contract as fpgaslop's mem_cdc (its header has the
// reasons the domains are unrelated and the reset rule: assert both resets
// together), different cost: mem_cdc is a four-phase handshake that pays
// about seven a_clk cycles for every beat of a burst; here a command
// crosses once, write data streams one beat per a_clk cycle, read data
// streams back one beat per cycle, and the controller round trip is paid
// once per burst.
//
//   A (SoC, a_clk)                         B (req_to_axi4, b_clk)
//   a_req/a_we/a_addr/a_len --> cmd FIFO --> b_req held for the burst
//   a_wdata/a_wstrb, one beat per ack --> wdata FIFO --> b_wdata, b_wr_ready
//   a_ack, a_rdata <-- rdata FIFO <-- b_rdata on each b_ack, b_rd_ready
//
// Writes are posted: a beat is acknowledged to the master when it is in
// the FIFO, not when it is in memory. The command FIFO keeps the order, B
// issues one transaction at a time and req_to_axi4 waits for the write
// response before the next command, so a read behind a write sees it.
// Nothing on the A side can observe the difference; the completion
// counters (slop_id WR_COUNT) are on the B side.
//
// req_to_axi4 needs wr_ready (data for the next beat is at b_wdata) and
// rd_ready (room for the next read beat); both come straight from the
// FIFOs, which is the pacing the module was written for.

module sh5_mem_cdc (
  // ---- side A: the SoC ----
  input  logic        a_clk,
  input  logic        a_rst,          // active high
  input  logic        a_req,
  input  logic        a_we,
  input  logic [63:0] a_addr,
  input  logic [63:0] a_wdata,
  input  logic [7:0]  a_wstrb,
  input  logic [2:0]  a_len,          // beats - 1
  output logic        a_ack,
  output logic [63:0] a_rdata,

  // ---- side B: the memory ----
  input  logic        b_clk,
  input  logic        b_rst,          // active high
  output logic        b_req,
  output logic        b_we,
  output logic [63:0] b_addr,
  output logic [63:0] b_wdata,
  output logic [7:0]  b_wstrb,
  output logic [2:0]  b_len,
  input  logic        b_ack,
  input  logic [63:0] b_rdata,
  output logic        b_rd_ready,
  output logic        b_wr_ready
);

  // ---- the three FIFOs ----
  // command: {we, len[2:0], addr[31:0]} -- the DDR3 is 1 GB, the window 256 MB
  logic        cmd_push, cmd_full, cmd_pop, cmd_empty;
  logic [35:0] cmd_w, cmd_r;
  sh5_afifo #(.W(36), .LOG2D(2)) u_cmd (
    .wclk(a_clk), .wrst(a_rst), .wpush(cmd_push), .wdata(cmd_w), .wfull(cmd_full),
    .rclk(b_clk), .rrst(b_rst), .rpop(cmd_pop), .rdata(cmd_r), .rempty(cmd_empty)
  );
  // write data: {wstrb, wdata}, one entry per beat
  logic        wd_push, wd_full, wd_pop, wd_empty;
  logic [71:0] wd_w, wd_r;
  sh5_afifo #(.W(72), .LOG2D(3)) u_wd (
    .wclk(a_clk), .wrst(a_rst), .wpush(wd_push), .wdata(wd_w), .wfull(wd_full),
    .rclk(b_clk), .rrst(b_rst), .rpop(wd_pop), .rdata(wd_r), .rempty(wd_empty)
  );
  // read data, one entry per beat
  logic        rd_push, rd_full, rd_pop, rd_empty;
  logic [63:0] rd_r;
  sh5_afifo #(.W(64), .LOG2D(3)) u_rd (
    .wclk(b_clk), .wrst(b_rst), .wpush(rd_push), .wdata(b_rdata), .wfull(rd_full),
    .rclk(a_clk), .rrst(a_rst), .rpop(rd_pop), .rdata(rd_r), .rempty(rd_empty)
  );

  // ---- side A ----
  // a_ack is a registered one-cycle pulse per beat, with that beat's
  // a_rdata (mem_cdc's contract, which memarb and the testbenches sample
  // after the edge). The master changes its write data after it sees the
  // pulse, so write beats are taken every other cycle.
  typedef enum logic [1:0] { A_IDLE, A_WR, A_RD, A_DONE } a_state_t;
  a_state_t a_st;
  logic [2:0] a_left;
  logic       ack_q;
  logic [63:0] rdata_q;

  assign cmd_w   = {a_we, a_len, a_addr[31:0]};
  assign cmd_push = (a_st == A_IDLE) && a_req && !cmd_full;
  assign wd_w    = {a_wstrb, a_wdata};
  assign wd_push = (a_st == A_WR) && !wd_full && !ack_q;
  assign rd_pop  = (a_st == A_RD) && !rd_empty && !ack_q;
  assign a_ack   = ack_q;
  assign a_rdata = rdata_q;

  always_ff @(posedge a_clk or posedge a_rst) begin
    if (a_rst) begin
      a_st <= A_IDLE; a_left <= 3'd0; ack_q <= 1'b0; rdata_q <= 64'h0;
    end else begin
      ack_q <= wd_push || rd_pop;
      if (rd_pop) rdata_q <= rd_r;
      case (a_st)
        A_IDLE: if (cmd_push) begin
          a_left <= a_len;
          a_st <= a_we ? A_WR : A_RD;
        end
        A_WR, A_RD: if (wd_push || rd_pop) begin
          a_left <= a_left - 3'd1;
          if (a_left == 3'd0) a_st <= A_DONE;
        end
        // One cycle out: the ack pulse is on the wire, and memarb keeps
        // m_req asserted from its hold registers until it has sampled that
        // pulse, so what is on the request lines in this cycle is still the
        // finished transaction. From the next cycle on it is the master's.
        // (Waiting for req to fall instead deadlocks: a master that
        // re-requests the cycle after the ack never shows a low cycle
        // through memarb.)
        A_DONE: a_st <= A_IDLE;
        default: a_st <= A_IDLE;
      endcase
    end
  end

  // ---- side B ----
  typedef enum logic [1:0] { B_IDLE, B_RUN, B_GAP } b_state_t;
  b_state_t b_st;
  logic [2:0] b_left;
  logic       b_we_q;
  logic [2:0] b_len_q;
  logic [31:0] b_addr_q;

  // a write is issued only once its first beat is in the data FIFO, so that
  // req_to_axi4 latches valid data with the command
  wire cmd_we = cmd_r[35];
  assign cmd_pop = (b_st == B_IDLE) && !cmd_empty && (!cmd_we || !wd_empty);

  assign b_req   = (b_st == B_RUN);
  assign b_we    = b_we_q;
  assign b_len   = b_len_q;
  assign b_addr  = {32'h0, b_addr_q};
  assign b_wdata = wd_r[63:0];
  assign b_wstrb = wd_r[71:64];
  assign b_wr_ready = !wd_empty;
  assign b_rd_ready = !rd_full;
  assign wd_pop  = b_req && b_we_q && b_ack;
  assign rd_push = b_req && !b_we_q && b_ack;

  always_ff @(posedge b_clk or posedge b_rst) begin
    if (b_rst) begin
      b_st <= B_IDLE; b_left <= 3'd0; b_we_q <= 1'b0; b_len_q <= 3'd0; b_addr_q <= 32'h0;
    end else begin
      case (b_st)
        B_IDLE: if (cmd_pop) begin
          b_we_q <= cmd_r[35]; b_len_q <= cmd_r[34:32]; b_addr_q <= cmd_r[31:0];
          b_left <= cmd_r[34:32];
          b_st <= B_RUN;
        end
        B_RUN: if (b_ack) begin
          b_left <= b_left - 3'd1;
          if (b_left == 3'd0) b_st <= B_GAP;
        end
        // req low for a cycle between transactions (req_to_axi4's contract)
        default: b_st <= B_IDLE;
      endcase
    end
  end

endmodule
