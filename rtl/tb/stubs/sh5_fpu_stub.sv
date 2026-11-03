// Placeholder FPU for building the core without the real unit: every
// operation completes one cycle after issue with a zero result.
module sh5_fpu import sh5_pkg::*; (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         issue_i,
  output logic         ready_o,
  input  logic [5:0]   op_i,
  input  logic [3:0]   ext_i,
  input  logic [63:0]  a_i,
  input  logic [63:0]  b_i,
  input  logic [63:0]  c_i,
  input  logic [127:0] va_i,
  input  logic [127:0] vb_i,
  input  logic [511:0] mtrx_i,
  input  logic [31:0]  fpscr_i,
  input  logic [7:0]   tag_i,
  output logic         trap_o,
  output logic         done_o,
  output logic [7:0]   tag_o,
  output logic [127:0] result_o,
  output logic [5:0]   cause_o
);
  logic pend_q;
  logic [7:0] tag_q;
  assign ready_o = !pend_q;
  assign trap_o = 1'b0;
  assign done_o = pend_q;
  assign tag_o = tag_q;
  assign result_o = 128'h0;
  assign cause_o = 6'h0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin pend_q <= 1'b0; tag_q <= 8'h0; end
    else begin
      if (pend_q) pend_q <= 1'b0;
      if (issue_i && ready_o) begin pend_q <= 1'b1; tag_q <= tag_i; end
    end
  end
  logic unused_ok;
  assign unused_ok = &{1'b0, op_i, ext_i, a_i, b_i, c_i, va_i, vb_i, mtrx_i, fpscr_i, 1'b0};
endmodule
