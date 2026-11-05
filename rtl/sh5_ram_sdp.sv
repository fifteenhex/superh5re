// Simple dual-port memory: one synchronous read port, one write port, one
// clock. Written in the shape Vivado infers block RAM from (UG901, "Simple
// Dual-Port Block RAM"): no reset on the array, the read registered, the
// write guarded by its enable only. The cache arrays use it; written as
// flops they were five times the size of the FPGA.
//
// A read and a write of the same address at the same edge return the old
// contents or undefined data depending on the write mode the tool picks;
// the users never do that (comments at the instances).

module sh5_ram_sdp #(
  parameter int W     = 64,
  parameter int DEPTH = 256,
  parameter int AW    = $clog2(DEPTH)
) (
  input  logic          clk,
  input  logic          re,
  input  logic [AW-1:0] raddr,
  output logic [W-1:0]  rdata,
  input  logic          we,
  input  logic [AW-1:0] waddr,
  input  logic [W-1:0]  wdata
);

  (* ram_style = "block" *) logic [W-1:0] mem [DEPTH];

  always_ff @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
    if (re) rdata <= mem[raddr];
  end

endmodule
