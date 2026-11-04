// 64-bit integer ALU (Vol. 1 ch. 5). Combinational, used in E1.

module sh5_alu
  import sh5_uop_pkg::*;
(
  input  aluop_t      op_i,
  input  logic [63:0] a_i,     // Rm
  input  logic [63:0] b_i,     // Rn or immediate
  input  logic [63:0] c_i,     // old destination value (CMVEQ/CMVNE, SHORI); T for A_DIV1
  input  logic        m_i,     // SR.M
  input  logic        q_i,     // SR.Q
  output logic [63:0] r_o
);

  // DIV1 (Vol. 3): 33-bit step on the zero-extended low words
  logic        div_oldq, div_q, div_t;
  logic [32:0] div_op2;
  always_comb begin
    div_oldq = q_i;
    div_q    = b_i[31];
    div_op2  = {1'b0, b_i[30:0], c_i[0]};                 // ZeroExtend32(op2 << 1) | t
    div_op2  = (div_oldq == m_i) ? div_op2 - {1'b0, a_i[31:0]} : div_op2 + {1'b0, a_i[31:0]};
    div_q    = (div_q ^ m_i) ^ div_op2[32];
    div_t    = 1'b1 ^ (div_q ^ m_i);
  end

  // MAC.L saturation to [-2^47, 2^47) of the 65-bit sum
  logic [64:0] sat_sum;
  logic [63:0] sat48;
  always_comb begin
    sat_sum = {a_i[63], a_i} + {b_i[63], b_i};
    if ($signed(sat_sum) > $signed(65'h0_0000_7fff_ffff_ffff))      sat48 = 64'h0000_7fff_ffff_ffff;
    else if ($signed(sat_sum) < $signed({1'b1, 64'hffff_8000_0000_0000})) sat48 = 64'hffff_8000_0000_0000;
    else sat48 = sat_sum[63:0];
  end

  // MAC.W with S = 1: MACL = saturate32(MACL + product), MACH = 1 on overflow
  logic [32:0] macw_sum;
  logic [63:0] macw;
  always_comb begin
    macw_sum = {a_i[31], a_i[31:0]} + {b_i[31], b_i[31:0]};
    if ($signed(macw_sum) > $signed(33'h0_7fff_ffff))      macw = {32'd1, 32'h7fff_ffff};
    else if ($signed(macw_sum) < $signed(33'h1_8000_0000)) macw = {32'd1, 32'h8000_0000};
    else macw = {a_i[63:32], macw_sum[31:0]};
  end

  logic [63:0] sum, dif;
  logic [5:0]  cnt6;
  logic [4:0]  cnt5;
  logic [63:0] shl, shr, sar;
  logic [31:0] shl_l, shr_l, sar_l;
  logic [6:0]  nsb;

  assign sum  = a_i + b_i;
  assign dif  = a_i - b_i;
  assign cnt6 = b_i[5:0];
  assign cnt5 = b_i[4:0];
  assign shl  = a_i << cnt6;
  assign shr  = a_i >> cnt6;
  assign sar  = $signed(a_i) >>> cnt6;
  assign shl_l = a_i[31:0] << cnt5;
  assign shr_l = a_i[31:0] >> cnt5;
  assign sar_l = $signed(a_i[31:0]) >>> cnt5;

  // NSB: number of leading bits equal to the sign bit, minus one (0..63)
  always_comb begin
    logic found;
    nsb = 7'd0;
    found = 1'b0;
    for (int i = 62; i >= 0; i--) begin
      if (!found) begin
        if (a_i[i] == a_i[63]) nsb = nsb + 7'd1;
        else found = 1'b1;
      end
    end
  end

  always_comb begin
    case (op_i)
      A_ADD:    r_o = sum;
      A_ADDL:   r_o = {{32{sum[31]}}, sum[31:0]};
      A_ADDZL:  r_o = {32'b0, sum[31:0]};
      A_SUB:    r_o = dif;
      A_SUBL:   r_o = {{32{dif[31]}}, dif[31:0]};
      A_CMPEQ:  r_o = {63'b0, a_i == b_i};
      A_CMPGT:  r_o = {63'b0, $signed(a_i) > $signed(b_i)};
      A_CMPGTU: r_o = {63'b0, a_i > b_i};
      A_AND:    r_o = a_i & b_i;
      A_ANDC:   r_o = a_i & ~b_i;
      A_OR:     r_o = a_i | b_i;
      A_XOR:    r_o = a_i ^ b_i;
      A_SHLLD:  r_o = shl;
      A_SHLLDL: r_o = {{32{shl_l[31]}}, shl_l};
      A_SHLRD:  r_o = shr;
      A_SHLRDL: r_o = {{32{shr_l[31]}}, shr_l};
      A_SHARD:  r_o = sar;
      A_SHARDL: r_o = {{32{sar_l[31]}}, sar_l};
      A_NSB:    r_o = {57'b0, nsb};
      A_BYTEREV: r_o = {a_i[7:0], a_i[15:8], a_i[23:16], a_i[31:24],
                        a_i[39:32], a_i[47:40], a_i[55:48], a_i[63:56]};
      A_CMVEQ:  r_o = (a_i == 64'd0) ? b_i : c_i;
      A_CMVNE:  r_o = (a_i != 64'd0) ? b_i : c_i;
      A_MOVI:   r_o = b_i;
      A_SHORI:  r_o = {c_i[47:0], 16'b0} | b_i;
      A_DIV1:   r_o = {23'b0, div_q, 7'b0, div_t, div_op2[31:0]};
      A_DIV0S:  r_o = {54'b0, a_i[31], b_i[31], 7'b0, a_i[31] ^ b_i[31]};
      A_ADDSAT48: r_o = sat48;
      A_MACWSAT:  r_o = macw;
      default:  r_o = b_i;   // A_PASS_B
    endcase
  end

endmodule
