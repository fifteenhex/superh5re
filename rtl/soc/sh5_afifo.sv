// sh5_afifo.sv - asynchronous FIFO, two clocks, Gray-code pointers with
// two-flop synchronisers (the textbook design). First word falls through:
// rdata is the head while !rempty. Storage is a small distributed RAM.
//
// Both resets must be asserted together (the pointers of one side are
// meaningless to the other after a one-sided reset); deassertion in any
// order. That is mem_cdc's contract too, and sh5_board_top meets it.

module sh5_afifo #(
  parameter int W     = 64,
  parameter int LOG2D = 3
) (
  input  logic         wclk,
  input  logic         wrst,        // active high
  input  logic         wpush,
  input  logic [W-1:0] wdata,
  output logic         wfull,

  input  logic         rclk,
  input  logic         rrst,        // active high
  input  logic         rpop,
  output logic [W-1:0] rdata,
  output logic         rempty
);

  localparam int D = 1 << LOG2D;

  logic [W-1:0] mem [D];

  // pointers carry one extra bit to tell full from empty
  logic [LOG2D:0] wbin_q, wgray_q, rbin_q, rgray_q;
  logic [LOG2D:0] rgray_w1_q, rgray_w2_q;   // read pointer seen from the write side
  logic [LOG2D:0] wgray_r1_q, wgray_r2_q;   // write pointer seen from the read side

  function automatic logic [LOG2D:0] bin2gray(input logic [LOG2D:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  // ---- write side ----
  logic [LOG2D:0] wbin_next, wgray_next;
  assign wbin_next  = wbin_q + (LOG2D+1)'(wpush && !wfull);
  assign wgray_next = bin2gray(wbin_next);

  always_ff @(posedge wclk or posedge wrst) begin
    if (wrst) begin
      wbin_q <= '0; wgray_q <= '0;
      rgray_w1_q <= '0; rgray_w2_q <= '0;
      wfull <= 1'b0;
    end else begin
      wbin_q  <= wbin_next;
      wgray_q <= wgray_next;
      rgray_w1_q <= rgray_q;
      rgray_w2_q <= rgray_w1_q;
      // full when the next write pointer equals the read pointer with the
      // two top bits inverted (Cummings)
      wfull <= (wgray_next == {~rgray_w2_q[LOG2D:LOG2D-1], rgray_w2_q[LOG2D-2:0]});
    end
  end

  always_ff @(posedge wclk) begin
    if (wpush && !wfull) mem[wbin_q[LOG2D-1:0]] <= wdata;
  end

  // ---- read side ----
  logic [LOG2D:0] rbin_next, rgray_next;
  assign rbin_next  = rbin_q + (LOG2D+1)'(rpop && !rempty);
  assign rgray_next = bin2gray(rbin_next);

  always_ff @(posedge rclk or posedge rrst) begin
    if (rrst) begin
      rbin_q <= '0; rgray_q <= '0;
      wgray_r1_q <= '0; wgray_r2_q <= '0;
      rempty <= 1'b1;
    end else begin
      rbin_q  <= rbin_next;
      rgray_q <= rgray_next;
      wgray_r1_q <= wgray_q;
      wgray_r2_q <= wgray_r1_q;
      rempty <= (rgray_next == wgray_r2_q);
    end
  end

  assign rdata = mem[rbin_q[LOG2D-1:0]];

endmodule
