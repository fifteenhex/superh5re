// SH-5 multimedia (packed SIMD) unit and 32 x 32 -> 64 multiplier.
//
// Implements the MND0 opcodes 000010, 000011, 001010, 001011, 010010,
// 010011 (Vol. 2 Tables 39-66: MADD*, MSUB*, MSH*, MCMP*, MABS, MEXTR1-7,
// MPERM.W, MSHF*, MSAD.UBQ, MMAC*, MCMV, MMULSUM.WQ, MMUL*, MCNVS*) and
// MULU.L / MULS.L (opcodes 000000 / 000001, extension 1110).
//
// Semantics follow the per-instruction pseudocode of Vol. 2 section 2.1
// with the conventions of Vol. 2 section 1.3: element i of an n-bit lane
// vector is bits [n*i +: n] of the register (MultiSignExtend_n /
// MultiZeroExtend_n), MultiRegister_n packs the low n bits of each element
// back in the same place, SignedSaturate_n / UnsignedSaturate_n clamp to
// the n-bit range (Table 11), LowerBytes_n / UpperBytes_n select bytes
// (Table 12).
//
// Pipeline: three register stages, fixed latency 3, every stage holds
// while en_i = 0.
//   stage 1: decode, operand capture, 4 x (16 x 16) and 2 x (32 x 32)
//            lane products, byte absolute differences
//   stage 2: lane add/subtract/shift/compare/select on sign- or
//            zero-extended elements, kept at full intermediate width
//   stage 3: saturate / truncate and pack
// Undefined {op, ext} combinations produce an unspecified result.

module sh5_mm import sh5_pkg::*; (
  input  logic        clk,
  input  logic        en_i,          // pipeline advance; when 0 every stage holds
  input  logic [5:0]  op_i,          // instruction opcode bits [31:26]
  input  logic [3:0]  ext_i,         // extension bits [19:16]
  input  logic [63:0] a_i,           // Rm
  input  logic [63:0] b_i,           // Rn
  input  logic [63:0] c_i,           // Rw (MCMV, MSAD.UBQ, MMACFX.WL, MMACNFX.WL, MMULSUM.WQ)
  output logic [63:0] result_o
);

  // ---------------------------------------------------------------------
  // Internal control encoding

  // Operation performed in stage 2
  typedef enum logic [4:0] {
    FN_NONE,
    FN_ADD,      // MADD.W/L, MADDS.UB/W/L
    FN_SUB,      // MSUB.W/L, MSUBS.UB/W/L
    FN_SHL,      // MSHLLD.W/L, MSHALDS.W/L
    FN_SHRA,     // MSHARD.W/L, MSHARDS.Q
    FN_SHRL,     // MSHLRD.W/L
    FN_ABS,      // MABS.W/L
    FN_CMPEQ,    // MCMPEQ.B/W/L
    FN_CMPGT,    // MCMPGT.W/L
    FN_CMPGTU,   // MCMPGT.UB
    FN_EXTR,     // MEXTR1-7
    FN_PERM,     // MPERM.W
    FN_SHFLO,    // MSHFLO.B/W/L
    FN_SHFHI,    // MSHFHI.B/W/L
    FN_CMV,      // MCMV
    FN_SAD,      // MSAD.UBQ
    FN_MULSUM,   // MMULSUM.WQ
    FN_MAC,      // MMACFX.WL
    FN_MACN,     // MMACNFX.WL
    FN_MULQ,     // MULU.L, MULS.L
    FN_MUL,      // MMUL.W/L
    FN_MULFX,    // MMULFX.W/L
    FN_MULFXRP,  // MMULFXRP.W
    FN_MULLO,    // MMULLO.WL
    FN_MULHI,    // MMULHI.WL
    FN_CNV       // MCNVS.WB, MCNVS.WUB, MCNVS.LW (source element width)
  } fn_t;

  // Source element width
  typedef enum logic [1:0] { W_B, W_W, W_L, W_Q } width_t;

  // Stage 3: how the stage-2 intermediate becomes the 64-bit result
  typedef enum logic [2:0] {
    PK_DIRECT,   // 64-bit value from stage 2 unchanged
    PK_B_SSAT,   // 8 x SignedSaturate8 of 16-bit intermediates
    PK_B_USAT,   // 8 x UnsignedSaturate8 of 16-bit intermediates
    PK_W_WRAP,   // 4 x low 16 bits of 32-bit intermediates
    PK_W_SSAT,   // 4 x SignedSaturate16 of 32-bit intermediates
    PK_L_WRAP,   // 2 x low 32 bits of 64-bit intermediates
    PK_L_SSAT,   // 2 x SignedSaturate32 of 64-bit intermediates
    PK_Q_SSAT16  // SignExtend64(SignedSaturate16(64-bit intermediate 0))
  } pk_t;

  // ---------------------------------------------------------------------
  // Saturation (Vol. 2 Table 11)

  function automatic logic [7:0] ssat8(input logic signed [15:0] v);
    if (v > 16'sd127)       ssat8 = 8'h7f;
    else if (v < -16'sd128) ssat8 = 8'h80;
    else                    ssat8 = v[7:0];
  endfunction

  function automatic logic [7:0] usat8(input logic signed [15:0] v);
    if (v < 16'sd0)         usat8 = 8'h00;
    else if (v > 16'sd255)  usat8 = 8'hff;
    else                    usat8 = v[7:0];
  endfunction

  function automatic logic [15:0] ssat16(input logic signed [31:0] v);
    if (v > 32'sd32767)       ssat16 = 16'h7fff;
    else if (v < -32'sd32768) ssat16 = 16'h8000;
    else                      ssat16 = v[15:0];
  endfunction

  function automatic logic [15:0] ssat16q(input logic signed [63:0] v);
    if (v > 64'sd32767)       ssat16q = 16'h7fff;
    else if (v < -64'sd32768) ssat16q = 16'h8000;
    else                      ssat16q = v[15:0];
  endfunction

  function automatic logic [31:0] ssat32(input logic signed [63:0] v);
    if (v > 64'sd2147483647)       ssat32 = 32'h7fff_ffff;
    else if (v < -64'sd2147483648) ssat32 = 32'h8000_0000;
    else                           ssat32 = v[31:0];
  endfunction

  // ---------------------------------------------------------------------
  // Decode (Vol. 2 Tables 39-66; extension values as in sh5_pkg ext_is_defined)

  fn_t    fn_d;
  width_t w_d;
  pk_t    pk_d;
  logic   mulu_d;    // MULU.L: zero-extend the 32-bit multiplier operands

  always_comb begin
    fn_d   = FN_NONE;
    w_d    = W_Q;
    pk_d   = PK_DIRECT;
    mulu_d = 1'b0;
    case (op_i)
      OP_ALU0: begin fn_d = FN_MULQ; mulu_d = 1'b1; end   // 1110 MULU.L
      OP_ALU1: fn_d = FN_MULQ;                            // 1110 MULS.L
      OP_MM2: begin                                       // x = 0 MADD, 1 MSUB
        fn_d = ext_i[3] ? FN_SUB : FN_ADD;
        case (ext_i[2:0])
          3'd1: begin w_d = W_W; pk_d = PK_W_WRAP; end    // x001 .W
          3'd2: begin w_d = W_L; pk_d = PK_L_WRAP; end    // x010 .L
          3'd4: begin w_d = W_B; pk_d = PK_B_USAT; end    // x100 S.UB
          3'd5: begin w_d = W_W; pk_d = PK_W_SSAT; end    // x101 S.W
          3'd6: begin w_d = W_L; pk_d = PK_L_SSAT; end    // x110 S.L
          default: ;
        endcase
      end
      OP_MM3: begin
        case (ext_i)
          4'd1:  begin fn_d = FN_SHL;  w_d = W_W; pk_d = PK_W_WRAP;   end  // MSHLLD.W
          4'd2:  begin fn_d = FN_SHL;  w_d = W_L; pk_d = PK_L_WRAP;   end  // MSHLLD.L
          4'd5:  begin fn_d = FN_SHL;  w_d = W_W; pk_d = PK_W_SSAT;   end  // MSHALDS.W
          4'd6:  begin fn_d = FN_SHL;  w_d = W_L; pk_d = PK_L_SSAT;   end  // MSHALDS.L
          4'd9:  begin fn_d = FN_SHRA; w_d = W_W; pk_d = PK_W_WRAP;   end  // MSHARD.W
          4'd10: begin fn_d = FN_SHRA; w_d = W_L; pk_d = PK_L_WRAP;   end  // MSHARD.L
          4'd11: begin fn_d = FN_SHRA; w_d = W_Q; pk_d = PK_Q_SSAT16; end  // MSHARDS.Q
          4'd13: begin fn_d = FN_SHRL; w_d = W_W; pk_d = PK_W_WRAP;   end  // MSHLRD.W
          4'd14: begin fn_d = FN_SHRL; w_d = W_L; pk_d = PK_L_WRAP;   end  // MSHLRD.L
          default: ;
        endcase
      end
      OP_MM10: begin
        case (ext_i)
          4'd0:  begin fn_d = FN_CMPEQ;  w_d = W_B; end                    // MCMPEQ.B
          4'd1:  begin fn_d = FN_CMPEQ;  w_d = W_W; end                    // MCMPEQ.W
          4'd2:  begin fn_d = FN_CMPEQ;  w_d = W_L; end                    // MCMPEQ.L
          4'd4:  begin fn_d = FN_CMPGTU; w_d = W_B; end                    // MCMPGT.UB
          4'd5:  begin fn_d = FN_CMPGT;  w_d = W_W; end                    // MCMPGT.W
          4'd6:  begin fn_d = FN_CMPGT;  w_d = W_L; end                    // MCMPGT.L
          4'd7, 4'd11, 4'd15: fn_d = FN_EXTR;                              // MEXTR1/2/3
          4'd9:  begin fn_d = FN_ABS; w_d = W_W; pk_d = PK_W_SSAT; end     // MABS.W
          4'd10: begin fn_d = FN_ABS; w_d = W_L; pk_d = PK_L_SSAT; end     // MABS.L
          4'd13: fn_d = FN_PERM;                                           // MPERM.W
          default: ;
        endcase
      end
      OP_MM11: begin
        case (ext_i)
          4'd0:  begin fn_d = FN_SHFLO; w_d = W_B; end                     // MSHFLO.B
          4'd1:  begin fn_d = FN_SHFLO; w_d = W_W; end                     // MSHFLO.W
          4'd2:  begin fn_d = FN_SHFLO; w_d = W_L; end                     // MSHFLO.L
          4'd4:  begin fn_d = FN_SHFHI; w_d = W_B; end                     // MSHFHI.B
          4'd5:  begin fn_d = FN_SHFHI; w_d = W_W; end                     // MSHFHI.W
          4'd6:  begin fn_d = FN_SHFHI; w_d = W_L; end                     // MSHFHI.L
          4'd3, 4'd7, 4'd11, 4'd15: fn_d = FN_EXTR;                        // MEXTR4/5/6/7
          default: ;
        endcase
      end
      OP_MM18: begin
        case (ext_i)
          4'd0: fn_d = FN_SAD;                                             // MSAD.UBQ
          4'd1: begin fn_d = FN_MAC;  pk_d = PK_L_SSAT; end                // MMACFX.WL
          4'd3: fn_d = FN_CMV;                                             // MCMV
          4'd5: begin fn_d = FN_MACN; pk_d = PK_L_SSAT; end                // MMACNFX.WL
          4'd9: fn_d = FN_MULSUM;                                          // MMULSUM.WQ
          default: ;
        endcase
      end
      OP_MM19: begin
        case (ext_i)
          4'd1:  begin fn_d = FN_MUL;     w_d = W_W; pk_d = PK_W_WRAP; end // MMUL.W
          4'd2:  begin fn_d = FN_MUL;     w_d = W_L; pk_d = PK_L_WRAP; end // MMUL.L
          4'd5:  begin fn_d = FN_MULFX;   w_d = W_W; pk_d = PK_W_SSAT; end // MMULFX.W
          4'd6:  begin fn_d = FN_MULFX;   w_d = W_L; pk_d = PK_L_SSAT; end // MMULFX.L
          4'd8:  begin fn_d = FN_CNV;     w_d = W_W; pk_d = PK_B_SSAT; end // MCNVS.WB
          4'd9:  begin fn_d = FN_MULFXRP; w_d = W_W; pk_d = PK_W_SSAT; end // MMULFXRP.W
          4'd10: begin fn_d = FN_MULLO;   w_d = W_L; pk_d = PK_L_WRAP; end // MMULLO.WL
          4'd12: begin fn_d = FN_CNV;     w_d = W_W; pk_d = PK_B_USAT; end // MCNVS.WUB
          4'd13: begin fn_d = FN_CNV;     w_d = W_L; pk_d = PK_W_SSAT; end // MCNVS.LW
          4'd14: begin fn_d = FN_MULHI;   w_d = W_L; pk_d = PK_L_WRAP; end // MMULHI.WL
          default: ;
        endcase
      end
      default: ;
    endcase
  end

  // MEXTRk: k = 1, 2, 3 at opcode 001010 ext 0111, 1011, 1111 and
  // k = 4..7 at opcode 001011 ext 0011, 0111, 1011, 1111.
  logic [2:0] k_d;
  assign k_d = {op_i[0], ext_i[3:2]};

  // ---------------------------------------------------------------------
  // Stage 1: products and byte differences

  logic signed [31:0] p16_d [4];   // signed 16 x 16 lane products
  logic        [63:0] p32_d [2];   // 32 x 32 lane products, signed or (MULU.L) unsigned
  logic        [7:0]  ad_d  [8];   // |Rm.byte[i] - Rn.byte[i]|

  always_comb begin
    for (int i = 0; i < 4; i++) begin
      p16_d[i] = $signed({{16{a_i[16*i+15]}}, a_i[16*i +: 16]}) *
                 $signed({{16{b_i[16*i+15]}}, b_i[16*i +: 16]});
    end
    for (int i = 0; i < 2; i++) begin
      logic [63:0] xa, xb;
      xa = {{32{a_i[32*i+31] & ~mulu_d}}, a_i[32*i +: 32]};
      xb = {{32{b_i[32*i+31] & ~mulu_d}}, b_i[32*i +: 32]};
      p32_d[i] = xa * xb;
    end
    for (int i = 0; i < 8; i++) begin
      logic [8:0] d;
      d = {1'b0, a_i[8*i +: 8]} - {1'b0, b_i[8*i +: 8]};
      ad_d[i] = d[8] ? -d[7:0] : d[7:0];
    end
  end

  fn_t                fn1;
  width_t             w1;
  pk_t                pk1;
  logic        [2:0]  k1;
  logic        [63:0] a1, b1, c1;
  logic signed [31:0] p16_1 [4];
  logic        [63:0] p32_1 [2];
  logic        [7:0]  ad1   [8];

  always_ff @(posedge clk) begin
    if (en_i) begin
      fn1   <= fn_d;
      w1    <= w_d;
      pk1   <= pk_d;
      k1    <= k_d;
      a1    <= a_i;
      b1    <= b_i;
      c1    <= c_i;
      p16_1 <= p16_d;
      p32_1 <= p32_d;
      ad1   <= ad_d;
    end
  end

  // ---------------------------------------------------------------------
  // Stage 2: lane arithmetic at full intermediate width
  //
  // w8: 8 lanes of 16 bits (byte adds, MCNVS.W* sources)
  // w4: 4 lanes of 32 bits (word adds/shifts/products, MCNVS.LW sources)
  // w2: 2 lanes of 64 bits (longword adds/shifts/products, MSHARDS.Q)
  // dd: complete 64-bit results (compares, byte moves, accumulations)

  logic signed [15:0] w8_d [8];
  logic signed [31:0] w4_d [4];
  logic signed [63:0] w2_d [2];
  logic        [63:0] dd_d;

  // Sign- and zero-extended elements of the stage-1 operands
  function automatic logic signed [15:0] zx8 (input logic [7:0]  v); zx8  = {8'b0, v};            endfunction
  function automatic logic signed [31:0] sx16(input logic [15:0] v); sx16 = {{16{v[15]}}, v};     endfunction
  function automatic logic signed [31:0] zx16(input logic [15:0] v); zx16 = {16'b0, v};           endfunction
  function automatic logic signed [63:0] sx32(input logic [31:0] v); sx32 = {{32{v[31]}}, v};     endfunction
  function automatic logic signed [63:0] zx32(input logic [31:0] v); zx32 = {32'b0, v};           endfunction
  function automatic logic signed [63:0] sx32s(input logic signed [31:0] v); sx32s = {{32{v[31]}}, v}; endfunction

  always_comb begin
    for (int i = 0; i < 8; i++) w8_d[i] = '0;
    for (int i = 0; i < 4; i++) w4_d[i] = '0;
    for (int i = 0; i < 2; i++) w2_d[i] = '0;
    dd_d = '0;

    case (fn1)
      // MADD*/MSUB*: byte forms (saturating unsigned) zero-extend, the
      // others sign-extend; the modulo forms do not depend on the extension.
      FN_ADD, FN_SUB: begin
        case (w1)
          W_B: for (int i = 0; i < 8; i++)
                 w8_d[i] = (fn1 == FN_SUB) ? zx8(a1[8*i +: 8]) - zx8(b1[8*i +: 8])
                                           : zx8(a1[8*i +: 8]) + zx8(b1[8*i +: 8]);
          W_W: for (int i = 0; i < 4; i++)
                 w4_d[i] = (fn1 == FN_SUB) ? sx16(a1[16*i +: 16]) - sx16(b1[16*i +: 16])
                                           : sx16(a1[16*i +: 16]) + sx16(b1[16*i +: 16]);
          W_L: for (int i = 0; i < 2; i++)
                 w2_d[i] = (fn1 == FN_SUB) ? sx32(a1[32*i +: 32]) - sx32(b1[32*i +: 32])
                                           : sx32(a1[32*i +: 32]) + sx32(b1[32*i +: 32]);
          default: ;
        endcase
      end

      // Shift amount: bits 0-3 of Rn for .W, 0-4 for .L, 0-5 for .Q.
      // Left shifts sign-extend (MSHALDS saturates on the signed value; the
      // low lane bits kept by MSHLLD are the same either way).
      FN_SHL: begin
        case (w1)
          W_W: for (int i = 0; i < 4; i++) w4_d[i] = sx16(a1[16*i +: 16]) <<< b1[3:0];
          W_L: for (int i = 0; i < 2; i++) w2_d[i] = sx32(a1[32*i +: 32]) <<< b1[4:0];
          default: ;
        endcase
      end
      FN_SHRA: begin
        case (w1)
          W_W: for (int i = 0; i < 4; i++) w4_d[i] = sx16(a1[16*i +: 16]) >>> b1[3:0];
          W_L: for (int i = 0; i < 2; i++) w2_d[i] = sx32(a1[32*i +: 32]) >>> b1[4:0];
          W_Q: w2_d[0] = $signed(a1) >>> b1[5:0];
          default: ;
        endcase
      end
      FN_SHRL: begin
        case (w1)
          W_W: for (int i = 0; i < 4; i++) w4_d[i] = zx16(a1[16*i +: 16]) >>> b1[3:0];
          W_L: for (int i = 0; i < 2; i++) w2_d[i] = zx32(a1[32*i +: 32]) >>> b1[4:0];
          default: ;
        endcase
      end

      // MABS: source >= 0 ? source : SignedSaturate_n(-source)
      FN_ABS: begin
        case (w1)
          W_W: for (int i = 0; i < 4; i++)
                 w4_d[i] = a1[16*i+15] ? -sx16(a1[16*i +: 16]) : sx16(a1[16*i +: 16]);
          W_L: for (int i = 0; i < 2; i++)
                 w2_d[i] = a1[32*i+31] ? -sx32(a1[32*i +: 32]) : sx32(a1[32*i +: 32]);
          default: ;
        endcase
      end

      // Compares: all ones in the lane where true
      FN_CMPEQ: begin
        case (w1)
          W_B: for (int i = 0; i < 8; i++) dd_d[8*i  +: 8]  = {8{a1[8*i +: 8] == b1[8*i +: 8]}};
          W_W: for (int i = 0; i < 4; i++) dd_d[16*i +: 16] = {16{a1[16*i +: 16] == b1[16*i +: 16]}};
          W_L: for (int i = 0; i < 2; i++) dd_d[32*i +: 32] = {32{a1[32*i +: 32] == b1[32*i +: 32]}};
          default: ;
        endcase
      end
      FN_CMPGT: begin
        case (w1)
          W_W: for (int i = 0; i < 4; i++)
                 dd_d[16*i +: 16] = {16{$signed(a1[16*i +: 16]) > $signed(b1[16*i +: 16])}};
          W_L: for (int i = 0; i < 2; i++)
                 dd_d[32*i +: 32] = {32{$signed(a1[32*i +: 32]) > $signed(b1[32*i +: 32])}};
          default: ;
        endcase
      end
      FN_CMPGTU: begin
        for (int i = 0; i < 8; i++) dd_d[8*i +: 8] = {8{a1[8*i +: 8] > b1[8*i +: 8]}};
      end

      // MEXTRk: (UpperBytes_(8-k)(Rm) >> 8k) OR (LowerBytes_k(Rn) << 8(8-k))
      FN_EXTR: dd_d = (a1 >> {k1, 3'b000}) | (b1 << (7'd64 - {1'b0, k1, 3'b000}));

      // MPERM.W: result[i] = source[control bits 2i+1..2i], control = Rn[7:0]
      FN_PERM: begin
        for (int i = 0; i < 4; i++) dd_d[16*i +: 16] = a1[{b1[2*i +: 2], 4'b0000} +: 16];
      end

      // MSHFLO / MSHFHI: interleave the low / high half of the elements of
      // Rm (even result lanes) and Rn (odd result lanes)
      FN_SHFLO, FN_SHFHI: begin
        case (w1)
          W_B: for (int i = 0; i < 4; i++) begin
                 dd_d[16*i   +: 8] = (fn1 == FN_SHFHI) ? a1[8*i+32 +: 8] : a1[8*i +: 8];
                 dd_d[16*i+8 +: 8] = (fn1 == FN_SHFHI) ? b1[8*i+32 +: 8] : b1[8*i +: 8];
               end
          W_W: for (int i = 0; i < 2; i++) begin
                 dd_d[32*i    +: 16] = (fn1 == FN_SHFHI) ? a1[16*i+32 +: 16] : a1[16*i +: 16];
                 dd_d[32*i+16 +: 16] = (fn1 == FN_SHFHI) ? b1[16*i+32 +: 16] : b1[16*i +: 16];
               end
          W_L: begin
                 dd_d[31:0]  = (fn1 == FN_SHFHI) ? a1[63:32] : a1[31:0];
                 dd_d[63:32] = (fn1 == FN_SHFHI) ? b1[63:32] : b1[31:0];
               end
          default: ;
        endcase
      end

      // MCMV: Rw = (Rm AND Rn) OR (Rw AND NOT Rn)
      FN_CMV: dd_d = (a1 & b1) | (c1 & ~b1);

      // MSAD.UBQ: Rw + sum of the eight byte absolute differences
      FN_SAD: dd_d = c1 + {56'b0, ad1[0]} + {56'b0, ad1[1]} + {56'b0, ad1[2]} + {56'b0, ad1[3]}
                        + {56'b0, ad1[4]} + {56'b0, ad1[5]} + {56'b0, ad1[6]} + {56'b0, ad1[7]};

      // MMULSUM.WQ: Rw + sum of the four signed word products, modulo 2^64
      FN_MULSUM: dd_d = c1 + sx32s(p16_1[0]) + sx32s(p16_1[1]) + sx32s(p16_1[2]) + sx32s(p16_1[3]);

      // MMACFX.WL / MMACNFX.WL:
      //   temp = SignedSaturate32(product << 1); Rw[i] = SignedSaturate32(Rw[i] +/- temp)
      FN_MAC, FN_MACN: begin
        for (int i = 0; i < 2; i++) begin
          logic signed [63:0] t;
          t = sx32s(ssat32({{31{p16_1[i][31]}}, p16_1[i], 1'b0}));
          w2_d[i] = (fn1 == FN_MACN) ? sx32(c1[32*i +: 32]) - t : sx32(c1[32*i +: 32]) + t;
        end
      end

      // MULU.L / MULS.L: full 64-bit product of the low 32 bits
      FN_MULQ: dd_d = p32_1[0];

      // MMUL.W / MMUL.L: low n bits of the lane product
      FN_MUL: begin
        case (w1)
          W_W: for (int i = 0; i < 4; i++) w4_d[i] = p16_1[i];
          W_L: for (int i = 0; i < 2; i++) w2_d[i] = $signed(p32_1[i]);
          default: ;
        endcase
      end

      // MMULFX.W / MMULFX.L: SignedSaturate_n(product >> (n - 1))
      FN_MULFX: begin
        case (w1)
          W_W: for (int i = 0; i < 4; i++) w4_d[i] = p16_1[i] >>> 15;
          W_L: for (int i = 0; i < 2; i++) w2_d[i] = $signed(p32_1[i]) >>> 31;
          default: ;
        endcase
      end

      // MMULFXRP.W: SignedSaturate16((product + 2^14) >> 15)
      FN_MULFXRP: begin
        for (int i = 0; i < 4; i++) w4_d[i] = (p16_1[i] + 32'sh0000_4000) >>> 15;
      end

      // MMULLO.WL / MMULHI.WL: 32-bit products of word elements 0,1 / 2,3
      FN_MULLO: for (int i = 0; i < 2; i++) w2_d[i] = sx32s(p16_1[i]);
      FN_MULHI: for (int i = 0; i < 2; i++) w2_d[i] = sx32s(p16_1[i+2]);

      // MCNVS.*: elements of Rm then Rn, each saturated to half width in stage 3
      FN_CNV: begin
        case (w1)
          W_W: for (int i = 0; i < 4; i++) begin
                 w8_d[i]   = $signed(a1[16*i +: 16]);
                 w8_d[i+4] = $signed(b1[16*i +: 16]);
               end
          W_L: for (int i = 0; i < 2; i++) begin
                 w4_d[i]   = $signed(a1[32*i +: 32]);
                 w4_d[i+2] = $signed(b1[32*i +: 32]);
               end
          default: ;
        endcase
      end

      default: ;
    endcase
  end

  pk_t                pk2;
  logic signed [15:0] w8_2 [8];
  logic signed [31:0] w4_2 [4];
  logic signed [63:0] w2_2 [2];
  logic        [63:0] dd_2;

  always_ff @(posedge clk) begin
    if (en_i) begin
      pk2  <= pk1;
      w8_2 <= w8_d;
      w4_2 <= w4_d;
      w2_2 <= w2_d;
      dd_2 <= dd_d;
    end
  end

  // ---------------------------------------------------------------------
  // Stage 3: saturate / truncate and pack (MultiRegister_n)

  logic [63:0] r_d;
  logic [15:0] q16;   // MSHARDS.Q result before sign extension

  always_comb begin
    q16 = ssat16q(w2_2[0]);
    r_d = dd_2;
    case (pk2)
      PK_B_SSAT:   for (int i = 0; i < 8; i++) r_d[8*i  +: 8]  = ssat8(w8_2[i]);
      PK_B_USAT:   for (int i = 0; i < 8; i++) r_d[8*i  +: 8]  = usat8(w8_2[i]);
      PK_W_WRAP:   for (int i = 0; i < 4; i++) r_d[16*i +: 16] = w4_2[i][15:0];
      PK_W_SSAT:   for (int i = 0; i < 4; i++) r_d[16*i +: 16] = ssat16(w4_2[i]);
      PK_L_WRAP:   for (int i = 0; i < 2; i++) r_d[32*i +: 32] = w2_2[i][31:0];
      PK_L_SSAT:   for (int i = 0; i < 2; i++) r_d[32*i +: 32] = ssat32(w2_2[i]);
      PK_Q_SSAT16: r_d = {{48{q16[15]}}, q16};
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (en_i) result_o <= r_d;
  end

endmodule
