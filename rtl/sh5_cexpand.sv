// SHcompact instruction expander (Vol. 3; docs/core-design.md 13).
//
// Each 16-bit SHcompact instruction is executed as a sequence of SHmedia
// micro-operations produced here one per step; the decoder turns them into
// pipeline micro-ops.  The SHcompact state maps onto R0-R15, GBR = R16,
// MACL/MACH = R17, PR = R18, T = R19 bit 0 (Vol. 1 Table 4); R20-R23, TR0-TR3
// and FR33 are the scratch registers that the architecture declares undefined
// after any SHcompact instruction.  Steps that can raise exceptions (loads,
// stores, PT checks) come before any write of architectural state so that an
// exception leaves the instruction without effect.
//
// Delayed branches: the branch's own steps leave the target in TR0 (for the
// conditional forms the fall-through address when not taken) and write PR;
// the core then expands the delay slot instruction with in_slot_i set, which
// appends a final "BLINK TR0, R63" step and turns the slot-illegal
// instructions into ILLSLOT (Vol. 3 Table 11).

module sh5_cexpand
  import sh5_pkg::*;
(
  input  logic [15:0] insn_i,
  input  logic [31:0] pc_i,        // address of the SHcompact instruction
  input  logic [3:0]  step_i,
  input  logic        in_slot_i,   // instruction is the delay slot of the pending branch in TR0
  input  logic        sr_fr_i, sr_sz_i, sr_pr_i, sr_fd_i, sr_s_i,
  output logic [31:0] insn_o,      // SHmedia encoding of this step
  output logic [31:0] imm32_o,     // immediate of the pseudo-operations
  output logic        last_o,      // last step of the instruction
  output logic        dbranch_o    // instruction is a delayed branch: a slot follows
);

  localparam logic [5:0] GBR = 6'd16, MAC = 6'd17, PR = 6'd18, T = 6'd19;
  localparam logic [5:0] S0 = 6'd20, S1 = 6'd21, S2 = 6'd22, S3 = 6'd23, Z = 6'd63;
  localparam logic [5:0] FPUL = 6'd32, FSCR = 6'd33;
  localparam logic [2:0] TR0 = 3'd0;
  // SR bit masks for PS_SRFLAG
  localparam logic [31:0] M_S = 32'h0000_0002, M_Q = 32'h0000_0100, M_M = 32'h0000_0200;
  localparam logic [31:0] M_PR = 32'h0000_1000, M_SZ = 32'h0000_2000, M_FR = 32'h0000_4000;

  // ---- SHmedia encodings
  function automatic logic [31:0] I(input logic [5:0] op, input logic [5:0] m, input logic [3:0] ext,
                                     input logic [5:0] n, input logic [5:0] d);
    I = {op, m, ext, n, d, 4'b0000};
  endfunction
  function automatic logic [31:0] I10(input logic [5:0] op, input logic [5:0] m, input logic [9:0] s10, input logic [5:0] d);
    I10 = {op, m, s10, d, 4'b0000};
  endfunction
  function automatic logic [31:0] MOVI(input logic [15:0] s16, input logic [5:0] d);
    MOVI = {OP_MOVI, s16, d, 4'b0000};
  endfunction
  function automatic logic [31:0] PS(input logic [3:0] ext, input logic [5:0] m, input logic [5:0] n, input logic [5:0] d);
    PS = {OP_FPURES4, m, ext, n, d, 4'b0000};
  endfunction
  // ALU0/ALU1 three-register forms
  function automatic logic [31:0] ADD   (input logic [5:0] m, n, d); ADD   = I(OP_ALU0, m, 4'd9, n, d);  endfunction
  function automatic logic [31:0] ADDL  (input logic [5:0] m, n, d); ADDL  = I(OP_ALU0, m, 4'd8, n, d);  endfunction
  function automatic logic [31:0] ADDZL (input logic [5:0] m, n, d); ADDZL = I(OP_ALU0, m, 4'd12, n, d); endfunction
  function automatic logic [31:0] SUB   (input logic [5:0] m, n, d); SUB   = I(OP_ALU0, m, 4'd11, n, d); endfunction
  function automatic logic [31:0] SUBL  (input logic [5:0] m, n, d); SUBL  = I(OP_ALU0, m, 4'd10, n, d); endfunction
  function automatic logic [31:0] CMPEQ (input logic [5:0] m, n, d); CMPEQ = I(OP_ALU0, m, 4'd1, n, d);  endfunction
  function automatic logic [31:0] CMPGT (input logic [5:0] m, n, d); CMPGT = I(OP_ALU0, m, 4'd3, n, d);  endfunction
  function automatic logic [31:0] CMPGTU(input logic [5:0] m, n, d); CMPGTU = I(OP_ALU0, m, 4'd7, n, d); endfunction
  function automatic logic [31:0] BYTEREV(input logic [5:0] m, d);  BYTEREV = I(OP_ALU0, m, 4'd15, Z, d); endfunction
  function automatic logic [31:0] MULUL (input logic [5:0] m, n, d); MULUL = I(OP_ALU0, m, 4'd14, n, d); endfunction
  function automatic logic [31:0] MULSL (input logic [5:0] m, n, d); MULSL = I(OP_ALU1, m, 4'd14, n, d); endfunction
  function automatic logic [31:0] SHLLDL(input logic [5:0] m, n, d); SHLLDL = I(OP_ALU1, m, 4'd0, n, d); endfunction
  function automatic logic [31:0] SHLRDL(input logic [5:0] m, n, d); SHLRDL = I(OP_ALU1, m, 4'd2, n, d); endfunction
  function automatic logic [31:0] SHARDL(input logic [5:0] m, n, d); SHARDL = I(OP_ALU1, m, 4'd6, n, d); endfunction
  function automatic logic [31:0] OR    (input logic [5:0] m, n, d); OR    = I(OP_ALU1, m, 4'd9, n, d);  endfunction
  function automatic logic [31:0] AND   (input logic [5:0] m, n, d); AND   = I(OP_ALU1, m, 4'd11, n, d); endfunction
  function automatic logic [31:0] XOR   (input logic [5:0] m, n, d); XOR   = I(OP_ALU1, m, 4'd13, n, d); endfunction
  function automatic logic [31:0] MCMPEQB(input logic [5:0] m, n, d); MCMPEQB = I(OP_MM10, m, 4'd0, n, d); endfunction
  // immediate forms
  function automatic logic [31:0] SHLLI (input logic [5:0] m, input logic [5:0] k, input logic [5:0] d); SHLLI  = I(OP_ALU49, m, 4'd1, k, d); endfunction
  function automatic logic [31:0] SHLLIL(input logic [5:0] m, input logic [5:0] k, input logic [5:0] d); SHLLIL = I(OP_ALU49, m, 4'd0, k, d); endfunction
  function automatic logic [31:0] SHLRI (input logic [5:0] m, input logic [5:0] k, input logic [5:0] d); SHLRI  = I(OP_ALU49, m, 4'd3, k, d); endfunction
  function automatic logic [31:0] SHLRIL(input logic [5:0] m, input logic [5:0] k, input logic [5:0] d); SHLRIL = I(OP_ALU49, m, 4'd2, k, d); endfunction
  function automatic logic [31:0] SHARI (input logic [5:0] m, input logic [5:0] k, input logic [5:0] d); SHARI  = I(OP_ALU49, m, 4'd7, k, d); endfunction
  function automatic logic [31:0] SHARIL(input logic [5:0] m, input logic [5:0] k, input logic [5:0] d); SHARIL = I(OP_ALU49, m, 4'd6, k, d); endfunction
  function automatic logic [31:0] XORI  (input logic [5:0] m, input logic [5:0] s6, input logic [5:0] d); XORI = I(OP_ALU49, m, 4'd13, s6, d); endfunction
  function automatic logic [31:0] ADDI  (input logic [5:0] m, input logic [9:0] s10, input logic [5:0] d); ADDI  = I10(OP_ADDI, m, s10, d);  endfunction
  function automatic logic [31:0] ADDIL (input logic [5:0] m, input logic [9:0] s10, input logic [5:0] d); ADDIL = I10(OP_ADDIL, m, s10, d); endfunction
  function automatic logic [31:0] ANDI  (input logic [5:0] m, input logic [9:0] s10, input logic [5:0] d); ANDI  = I10(OP_ANDI, m, s10, d);  endfunction
  function automatic logic [31:0] ORI   (input logic [5:0] m, input logic [9:0] s10, input logic [5:0] d); ORI   = I10(OP_ORI, m, s10, d);   endfunction
  function automatic logic [31:0] CMVEQ (input logic [5:0] m, n, d); CMVEQ = I(OP_RMW8, m, 4'd1, n, d); endfunction
  function automatic logic [31:0] CMVNE (input logic [5:0] m, n, d); CMVNE = I(OP_RMW8, m, 4'd5, n, d); endfunction
  // memory: displacement in units of the access size
  function automatic logic [31:0] LD(input logic [1:0] sz, input logic sgn, input logic [5:0] m, input logic [9:0] disp, input logic [5:0] d);
    case ({sz, sgn})
      3'b001:  LD = I10(OP_LDB, m, disp, d);
      3'b000:  LD = I10(OP_LDUB, m, disp, d);
      3'b011:  LD = I10(OP_LDW, m, disp, d);
      3'b010:  LD = I10(OP_LDUW, m, disp, d);
      default: LD = I10(OP_LDL, m, disp, d);
    endcase
  endfunction
  function automatic logic [31:0] ST(input logic [1:0] sz, input logic [5:0] m, input logic [9:0] disp, input logic [5:0] src);
    case (sz)
      2'd0:    ST = I10(OP_STB, m, disp, src);
      2'd1:    ST = I10(OP_STW, m, disp, src);
      default: ST = I10(OP_STL, m, disp, src);
    endcase
  endfunction
  function automatic logic [31:0] LDX(input logic [1:0] sz, input logic sgn, input logic [5:0] m, n, d);
    case ({sz, sgn})
      3'b001:  LDX = I(OP_LOAD16, m, 4'd0, n, d);
      3'b000:  LDX = I(OP_LOAD16, m, 4'd4, n, d);
      3'b011:  LDX = I(OP_LOAD16, m, 4'd1, n, d);
      3'b010:  LDX = I(OP_LOAD16, m, 4'd5, n, d);
      default: LDX = I(OP_LOAD16, m, 4'd2, n, d);
    endcase
  endfunction
  function automatic logic [31:0] STX(input logic [1:0] sz, input logic [5:0] m, n, src);
    STX = I(OP_STORE24, m, {2'b00, sz}, n, src);
  endfunction
  function automatic logic [31:0] CACHEOP(input logic [3:0] ext, input logic [5:0] m);
    CACHEOP = I(OP_STORE56, m, ext, 6'd0, Z);
  endfunction
  // branches and targets
  function automatic logic [31:0] PTABS(input logic [5:0] rn, input logic [2:0] tr); PTABS = I(OP_PT26, 6'd0, 4'd1, rn, {3'b000, tr}); endfunction
  function automatic logic [31:0] BLINK(input logic [2:0] tr, input logic [5:0] d); BLINK = I(OP_BRANCH17, {3'b000, tr}, 4'd1, Z, d); endfunction
  function automatic logic [31:0] BEQ(input logic [5:0] m, n, input logic [2:0] tr); BEQ = I(OP_BRANCH25, m, 4'd1, n, {3'b000, tr}); endfunction
  function automatic logic [31:0] BNE(input logic [5:0] m, n, input logic [2:0] tr); BNE = I(OP_BRANCH25, m, 4'd5, n, {3'b000, tr}); endfunction
  function automatic logic [31:0] TRAPA(input logic [5:0] m); TRAPA = I(OP_MISC27, m, 4'd1, Z, Z); endfunction
  // floating point
  function automatic logic [31:0] FMOVLS(input logic [5:0] m, input logic [5:0] fd); FMOVLS = I(OP_FLOAD7, m, 4'd0, Z, fd); endfunction
  function automatic logic [31:0] FMOVSL(input logic [5:0] fa, input logic [5:0] d); FMOVSL = I(OP_FPU12, fa, 4'd0, Z, d); endfunction
  function automatic logic [31:0] FMOVS (input logic [5:0] fa, fd); FMOVS = I(OP_FPU14, fa, 4'd0, Z, fd); endfunction
  function automatic logic [31:0] FMOVD (input logic [5:0] fa, fd); FMOVD = I(OP_FPU14, fa, 4'd1, Z, fd); endfunction
  function automatic logic [31:0] FPU6  (input logic [3:0] ext, input logic [5:0] fa, fd); FPU6 = I(OP_FPU6, fa, ext, Z, fd); endfunction
  function automatic logic [31:0] FPU13 (input logic [3:0] ext, input logic [5:0] fa, fb, fd); FPU13 = I(OP_FPU13, fa, ext, fb, fd); endfunction
  function automatic logic [31:0] FPU14 (input logic [3:0] ext, input logic [5:0] fa, fd); FPU14 = I(OP_FPU14, fa, ext, Z, fd); endfunction
  function automatic logic [31:0] FCMP  (input logic [3:0] ext, input logic [5:0] fa, fb, d); FCMP = I(OP_FPU12, fa, ext, fb, d); endfunction
  function automatic logic [31:0] FIPR  (input logic [5:0] fa, fb, fd); FIPR = I(OP_FPU5, fa, 4'd6, fb, fd); endfunction
  function automatic logic [31:0] FTRV  (input logic [5:0] fa, fb, fd); FTRV = I(OP_FPU5, fa, 4'd14, fb, fd); endfunction
  function automatic logic [31:0] FLDS  (input logic [5:0] m, input logic [9:0] disp, input logic [5:0] fd); FLDS = I10(OP_FLDS, m, disp, fd); endfunction
  function automatic logic [31:0] FLDD  (input logic [5:0] m, input logic [9:0] disp, input logic [5:0] fd); FLDD = I10(OP_FLDD, m, disp, fd); endfunction
  function automatic logic [31:0] FSTS  (input logic [5:0] m, input logic [9:0] disp, input logic [5:0] fs); FSTS = I10(OP_FSTS, m, disp, fs); endfunction
  function automatic logic [31:0] FSTD  (input logic [5:0] m, input logic [9:0] disp, input logic [5:0] fs); FSTD = I10(OP_FSTD, m, disp, fs); endfunction
  function automatic logic [31:0] FLDP  (input logic [5:0] m, input logic [9:0] disp, input logic [5:0] fd); FLDP = I10(OP_FLDP, m, disp, fd); endfunction
  function automatic logic [31:0] FSTP  (input logic [5:0] m, input logic [9:0] disp, input logic [5:0] fs); FSTP = I10(OP_FSTP, m, disp, fs); endfunction
  function automatic logic [31:0] FLDXP (input logic [5:0] m, n, fd); FLDXP = I(OP_FLOAD7, m, 4'd13, n, fd); endfunction
  function automatic logic [31:0] FSTXP (input logic [5:0] m, n, fs); FSTXP = I(OP_FSTORE15, m, 4'd13, n, fs); endfunction
  function automatic logic [31:0] FLDXS (input logic [5:0] m, n, fd); FLDXS = I(OP_FLOAD7, m, 4'd8, n, fd); endfunction
  function automatic logic [31:0] FLDXD (input logic [5:0] m, n, fd); FLDXD = I(OP_FLOAD7, m, 4'd9, n, fd); endfunction
  function automatic logic [31:0] FSTXS (input logic [5:0] m, n, fs); FSTXS = I(OP_FSTORE15, m, 4'd8, n, fs); endfunction
  function automatic logic [31:0] FSTXD (input logic [5:0] m, n, fs); FSTXD = I(OP_FSTORE15, m, 4'd9, n, fs); endfunction
  function automatic logic [31:0] FPUTSCR(input logic [5:0] fa); FPUTSCR = I(OP_FPU12, fa, 4'd2, Z, Z); endfunction
  function automatic logic [31:0] NOP(); NOP = I(OP_MISC27, Z, 4'd0, Z, Z); endfunction
  function automatic logic [31:0] BRK(); BRK = I(OP_MISC27, Z, 4'd5, Z, Z); endfunction

  // ---- fields
  logic [3:0] n4, m4;
  logic [5:0] rn, rm;
  logic [7:0] imm8;
  logic [31:0] s8, s12, u8;
  logic [31:0] pc4;
  assign n4 = insn_i[11:8];
  assign m4 = insn_i[7:4];
  assign rn = {2'b00, n4};
  assign rm = {2'b00, m4};
  assign imm8 = insn_i[7:0];
  assign s8  = {{24{imm8[7]}}, imm8};
  assign u8  = {24'b0, imm8};
  assign s12 = {{20{insn_i[11]}}, insn_i[11:0]};
  assign pc4 = pc_i + 32'd4;

  // floating-point register mapping (Vol. 1 Table 6)
  function automatic logic [5:0] fr(input logic [3:0] k);  fr = sr_fr_i ? {2'b01, k} : {2'b00, k}; endfunction
  function automatic logic [5:0] xf(input logic [3:0] k);  xf = sr_fr_i ? {2'b00, k} : {2'b01, k}; endfunction
  // DRn / XDn by the low bit of the 4-bit field (SZ = 1 FMOV forms)
  function automatic logic [5:0] dx(input logic [3:0] k);  dx = k[0] ? xf({k[3:1], 1'b0}) : fr({k[3:1], 1'b0}); endfunction

  // ---- expansion
  logic [31:0] ins, imm;     // encoding and immediate of the selected step
  logic [7:0]  k;            // instruction kind (index of its decode entry)
  logic [4:0]  n;            // number of own steps
  logic        illslot, isfpu, dbr, resinst;

  always_comb begin
    ins = NOP(); imm = 32'h0; k = 8'd255;
    n = 5'd1; illslot = 1'b0; isfpu = 1'b0; dbr = 1'b0; resinst = 1'b0;

    casez (insn_i)
      // ---------------- 0000 ----------------
      16'b0000_????_0000_0011: begin k = 8'd0; dbr = 1'b1; n = 5'd4; end  // BSRF Rn
      16'b0000_????_0010_0011: begin k = 8'd1; dbr = 1'b1; n = 5'd3; end  // BRAF Rn
      16'b0000_????_1000_0011: begin k = 8'd2; n = 5'd1; end  // PREF @Rn: no operation on this core
      16'b0000_????_1001_0011: begin k = 8'd3;  end  // OCBI
      16'b0000_????_1010_0011: begin k = 8'd4;  end  // OCBP
      16'b0000_????_1011_0011: begin k = 8'd5;  end  // OCBWB
      16'b0000_????_1100_0011: begin k = 8'd6; n = 5'd2; end  // MOVCA.L R0, @Rn
      16'b0000_????_????_0100: begin k = 8'd7;  end  // MOV.B Rm, @(R0, Rn)
      16'b0000_????_????_0101: begin k = 8'd8;  end  // MOV.W
      16'b0000_????_????_0110: begin k = 8'd9;  end  // MOV.L
      16'b0000_????_????_0111: begin k = 8'd10; n = 5'd5; end  // MUL.L Rm, Rn: MACL = low 32 bits of the product, MACH kept
      16'b0000_0000_0000_1000: begin k = 8'd11;  end  // CLRT
      16'b0000_0000_0001_1000: begin k = 8'd12;  end  // SETT
      16'b0000_0000_0010_1000: begin k = 8'd13;  end  // CLRMAC
      16'b0000_0000_0011_1011: begin k = 8'd14;  end  // BRK (0x003b)
      16'b0000_0000_0100_1000: begin k = 8'd15;  end  // CLRS
      16'b0000_0000_0101_1000: begin k = 8'd16; n = 5'd2; end  // SETS
      16'b0000_0000_0000_1001: begin k = 8'd17;  end  // NOP
      16'b0000_0000_0001_1001: begin k = 8'd18; n = 5'd2; end  // DIV0U
      16'b0000_????_0010_1001: begin k = 8'd19;  end  // MOVT Rn
      16'b0000_0000_0000_1011: begin k = 8'd20; dbr = 1'b1; end  // RTS
      16'b0000_0000_0001_1011: begin k = 8'd21;  end  // SLEEP: privileged
      16'b0000_0000_0010_1011: begin k = 8'd22;  end  // RTE: privileged
      16'b0000_????_????_1100: begin k = 8'd23;  end  // MOV.B @(R0, Rm), Rn
      16'b0000_????_????_1101: begin k = 8'd24;  end  // MOV.W
      16'b0000_????_????_1110: begin k = 8'd25;  end  // MOV.L
      16'b0000_????_????_1111: begin k = 8'd26; n = (n4 == m4) ? 5'd5 : 5'd6; end  // MAC.L @Rm+, @Rn+
      16'b0000_????_0000_0010: begin k = 8'd27;  end  // STC SR: privileged
      16'b0000_????_0001_0010: begin k = 8'd28;  end  // STC GBR, Rn
      16'b0000_????_0010_0010: begin k = 8'd29;  end  // STC VBR
      16'b0000_????_0011_0010: begin k = 8'd30;  end  // STC SSR
      16'b0000_????_0100_0010: begin k = 8'd31;  end  // STC SPC
      16'b0000_????_1???_0010: begin k = 8'd32;  end  // STC Rn_BANK
      16'b0000_????_0000_1010: begin k = 8'd33;  end  // STS MACH, Rn
      16'b0000_????_0001_1010: begin k = 8'd34;  end  // STS MACL, Rn
      16'b0000_????_0010_1010: begin k = 8'd35;  end  // STS PR, Rn
      16'b0000_????_0101_1010: begin k = 8'd36; isfpu = 1'b1; end  // STS FPUL, Rn
      16'b0000_????_0110_1010: begin k = 8'd37; isfpu = 1'b1; end  // STS FPSCR, Rn

      // ---------------- 0001: MOV.L Rm, @(disp, Rn) ----------------
      16'b0001_????_????_????: begin k = 8'd38;  end  // ---------------- 0010 ----------------

      // ---------------- 0010 ----------------
      16'b0010_????_????_0000: begin k = 8'd39;  end  // MOV.B Rm, @Rn
      16'b0010_????_????_0001: begin k = 8'd40;  end  // MOV.W
      16'b0010_????_????_0010: begin k = 8'd41;  end  // MOV.L
      16'b0010_????_????_0100: begin k = 8'd42; n = 5'd3; end  // MOV.B Rm, @-Rn
      16'b0010_????_????_0101: begin k = 8'd43; n = 5'd3; end  // MOV.W Rm, @-Rn
      16'b0010_????_????_0110: begin k = 8'd44; n = 5'd3; end  // MOV.L Rm, @-Rn
      16'b0010_????_????_0111: begin k = 8'd45; n = 5'd3; end  // DIV0S Rm, Rn
      16'b0010_????_????_1000: begin k = 8'd46; n = 5'd2; end  // TST Rm, Rn
      16'b0010_????_????_1001: begin k = 8'd47;  end  // AND Rm, Rn
      16'b0010_????_????_1010: begin k = 8'd48;  end  // XOR
      16'b0010_????_????_1011: begin k = 8'd49;  end  // OR
      16'b0010_????_????_1100: begin k = 8'd50; n = 5'd4; end  // CMP/STR Rm, Rn: any byte of the low words equal
      16'b0010_????_????_1101: begin k = 8'd51; n = 5'd3; end  // XTRCT
      16'b0010_????_????_1110: begin k = 8'd52; n = 5'd9; end  // MULU.W Rm, Rn
      16'b0010_????_????_1111: begin k = 8'd53; n = 5'd9; end  // MULS.W Rm, Rn

      // ---------------- 0011 ----------------
      16'b0011_????_????_0000: begin k = 8'd54;  end  // CMP/EQ Rm, Rn
      16'b0011_????_????_0010: begin k = 8'd55; n = 5'd2; end  // CMP/HS
      16'b0011_????_????_0011: begin k = 8'd56; n = 5'd2; end  // CMP/GE
      16'b0011_????_????_0110: begin k = 8'd57;  end  // CMP/HI
      16'b0011_????_????_0111: begin k = 8'd58;  end  // CMP/GT
      16'b0011_????_????_0100: begin k = 8'd59; n = 5'd5; end  // DIV1 Rm, Rn
      16'b0011_????_????_0101: begin k = 8'd60;  end  // DMULU.L
      16'b0011_????_????_1101: begin k = 8'd61;  end  // DMULS.L
      16'b0011_????_????_1000: begin k = 8'd62;  end  // SUB Rm, Rn
      16'b0011_????_????_1010: begin k = 8'd63; n = 5'd6; end  // SUBC Rm, Rn
      16'b0011_????_????_1011: begin k = 8'd64; n = 5'd5; end  // SUBV Rm, Rn
      16'b0011_????_????_1100: begin k = 8'd65;  end  // ADD Rm, Rn
      16'b0011_????_????_1110: begin k = 8'd66; n = 5'd6; end  // ADDC Rm, Rn
      16'b0011_????_????_1111: begin k = 8'd67; n = 5'd5; end  // ADDV Rm, Rn

      // ---------------- 0100 ----------------
      16'b0100_????_0000_0000: begin k = 8'd68; n = 5'd3; end  // SHLL
      16'b0100_????_0010_0000: begin k = 8'd69; n = 5'd3; end  // SHAL
      16'b0100_????_0000_0001: begin k = 8'd70; n = 5'd2; end  // SHLR
      16'b0100_????_0010_0001: begin k = 8'd71; n = 5'd2; end  // SHAR
      16'b0100_????_0000_0100: begin k = 8'd72; n = 5'd4; end  // ROTL Rn
      16'b0100_????_0000_0101: begin k = 8'd73; n = 5'd4; end  // ROTR Rn
      16'b0100_????_0010_0100: begin k = 8'd74; n = 5'd5; end  // ROTCL Rn
      16'b0100_????_0010_0101: begin k = 8'd75; n = 5'd5; end  // ROTCR Rn
      16'b0100_????_0000_1000: begin k = 8'd76;  end  // SHLL2
      16'b0100_????_0001_1000: begin k = 8'd77;  end  // SHLL8
      16'b0100_????_0010_1000: begin k = 8'd78;  end  // SHLL16
      16'b0100_????_0000_1001: begin k = 8'd79;  end  // SHLR2
      16'b0100_????_0001_1001: begin k = 8'd80;  end  // SHLR8
      16'b0100_????_0010_1001: begin k = 8'd81;  end  // SHLR16
      16'b0100_????_0000_0010: begin k = 8'd82; n = 5'd4; end  // STS.L MACH, @-Rn
      16'b0100_????_0001_0010: begin k = 8'd83; n = 5'd3; end  // STS.L MACL, @-Rn
      16'b0100_????_0010_0010: begin k = 8'd84; n = 5'd3; end  // STS.L PR, @-Rn
      16'b0100_????_0101_0010: begin k = 8'd85; isfpu = 1'b1; n = 5'd3; end  // STS.L FPUL, @-Rn
      16'b0100_????_0110_0010: begin k = 8'd86; isfpu = 1'b1; n = 5'd4; end  // STS.L FPSCR, @-Rn
      16'b0100_????_0000_0011: begin k = 8'd87;  end  // STC.L SR
      16'b0100_????_0001_0011: begin k = 8'd88; n = 5'd3; end  // STC.L GBR, @-Rn
      16'b0100_????_0010_0011,
      16'b0100_????_0011_0011,
      16'b0100_????_0100_0011,
      16'b0100_????_1???_0011: begin k = 8'd89;  end  // STC.L VBR/SSR/SPC/Rn_BANK
      16'b0100_????_0000_0110: begin k = 8'd90; n = 5'd5; end  // LDS.L @Rm+, MACH
      16'b0100_????_0001_0110: begin k = 8'd91; n = 5'd6; end  // LDS.L @Rm+, MACL
      16'b0100_????_0010_0110: begin k = 8'd92; n = 5'd2; end  // LDS.L @Rm+, PR
      16'b0100_????_0101_0110: begin k = 8'd93; isfpu = 1'b1; n = 5'd2; end  // LDS.L @Rm+, FPUL
      16'b0100_????_0110_0110: begin k = 8'd94; isfpu = 1'b1; n = 5'd6; end  // LDS.L @Rm+, FPSCR
      16'b0100_????_0000_0111: begin k = 8'd95;  end  // LDC.L SR
      16'b0100_????_0001_0111: begin k = 8'd96; n = 5'd2; end  // LDC.L @Rm+, GBR
      16'b0100_????_0010_0111,
      16'b0100_????_0011_0111,
      16'b0100_????_0100_0111,
      16'b0100_????_1???_0111: begin k = 8'd97;  end  // LDC.L VBR/SSR/SPC/Rn_BANK
      16'b0100_????_0000_1010: begin k = 8'd98; n = 5'd3; end  // LDS Rm, MACH
      16'b0100_????_0001_1010: begin k = 8'd99; n = 5'd4; end  // LDS Rm, MACL
      16'b0100_????_0010_1010: begin k = 8'd100;  end  // LDS Rm, PR
      16'b0100_????_0101_1010: begin k = 8'd101; isfpu = 1'b1; end  // LDS Rm, FPUL
      16'b0100_????_0110_1010: begin k = 8'd102; isfpu = 1'b1; n = 5'd4; end  // LDS Rm, FPSCR
      16'b0100_????_0000_1011: begin k = 8'd103; dbr = 1'b1; n = 5'd2; end  // JSR @Rn
      16'b0100_????_0001_1011: begin k = 8'd104; n = 5'd4; end  // TAS.B @Rn
      16'b0100_????_0010_1011: begin k = 8'd105; dbr = 1'b1; end  // JMP @Rn
      16'b0100_????_0000_1110: begin k = 8'd106;  end  // LDC Rm, SR
      16'b0100_????_0001_1110: begin k = 8'd107;  end  // LDC Rm, GBR
      16'b0100_????_0010_1110,
      16'b0100_????_0011_1110,
      16'b0100_????_0100_1110,
      16'b0100_????_1???_1110: begin k = 8'd108;  end  // LDC VBR/SSR/SPC/Rn_BANK
      16'b0100_????_0001_0000: begin k = 8'd109; n = 5'd2; end  // DT Rn
      16'b0100_????_0001_0001: begin k = 8'd110; n = 5'd2; end  // CMP/PZ
      16'b0100_????_0001_0101: begin k = 8'd111;  end  // CMP/PL
      16'b0100_????_????_1100: begin k = 8'd112; n = 5'd10; end  // SHAD Rm, Rn
      16'b0100_????_????_1101: begin k = 8'd113; n = 5'd9; end  // SHLD Rm, Rn
      16'b0100_????_????_1111: begin k = 8'd114; n = (n4 == m4) ? 5'd5 : 5'd6; end  // MAC.W @Rm+, @Rn+

      // ---------------- 0101: MOV.L @(disp, Rm), Rn ----------------
      16'b0101_????_????_????: begin k = 8'd115;  end  // ---------------- 0110 ----------------

      // ---------------- 0110 ----------------
      16'b0110_????_????_0000: begin k = 8'd116;  end  // MOV.B @Rm, Rn
      16'b0110_????_????_0001: begin k = 8'd117;  end  // MOV.W
      16'b0110_????_????_0010: begin k = 8'd118;  end  // MOV.L
      16'b0110_????_????_0011: begin k = 8'd119;  end  // MOV Rm, Rn (64-bit)
      16'b0110_????_????_0100: begin k = 8'd120; n = (n4 == m4) ? 5'd1 : 5'd2; end  // MOV.B @Rm+, Rn
      16'b0110_????_????_0101: begin k = 8'd121; n = (n4 == m4) ? 5'd1 : 5'd2; end  // MOV.W @Rm+, Rn
      16'b0110_????_????_0110: begin k = 8'd122; n = (n4 == m4) ? 5'd1 : 5'd2; end  // MOV.L @Rm+, Rn
      16'b0110_????_????_0111: begin k = 8'd123;  end  // NOT Rm, Rn (64-bit)
      16'b0110_????_????_1000: begin k = 8'd124; n = 5'd5; end  // SWAP.B Rm, Rn
      16'b0110_????_????_1001: begin k = 8'd125; n = 5'd3; end  // SWAP.W
      16'b0110_????_????_1010: begin k = 8'd126; n = 5'd5; end  // NEGC Rm, Rn
      16'b0110_????_????_1011: begin k = 8'd127;  end  // NEG Rm, Rn
      16'b0110_????_????_1100: begin k = 8'd128;  end  // EXTU.B
      16'b0110_????_????_1101: begin k = 8'd129; n = 5'd2; end  // EXTU.W
      16'b0110_????_????_1110: begin k = 8'd130; n = 5'd2; end  // EXTS.B
      16'b0110_????_????_1111: begin k = 8'd131; n = 5'd2; end  // EXTS.W

      // ---------------- 0111: ADD #imm, Rn ----------------
      16'b0111_????_????_????: begin k = 8'd132;  end  // ---------------- 1000 ----------------

      // ---------------- 1000 ----------------
      16'b1000_0000_????_????: begin k = 8'd133;  end  // MOV.B R0, @(disp, Rn)
      16'b1000_0001_????_????: begin k = 8'd134;  end  // MOV.W R0, @(disp, Rn)
      16'b1000_0100_????_????: begin k = 8'd135;  end  // MOV.B @(disp, Rm), R0
      16'b1000_0101_????_????: begin k = 8'd136;  end  // MOV.W @(disp, Rm), R0
      16'b1000_1000_????_????: begin k = 8'd137; n = 5'd2; end  // CMP/EQ #imm, R0
      16'b1000_1001_????_????: begin k = 8'd138; illslot = 1'b1; n = 5'd2; end  // BT label
      16'b1000_1011_????_????: begin k = 8'd139; illslot = 1'b1; n = 5'd2; end  // BF label
      16'b1000_1101_????_????: begin k = 8'd140; illslot = 1'b1; dbr = 1'b1; n = 5'd4; end  // BT/S label: TR0 = T ? label : pc + 4
      16'b1000_1111_????_????: begin k = 8'd141; illslot = 1'b1; dbr = 1'b1; n = 5'd4; end  // BF/S label

      // ---------------- 1001: MOV.W @(disp, PC), Rn ----------------
      16'b1001_????_????_????: begin k = 8'd142; illslot = 1'b1; n = 5'd2; end  // ---------------- 1010 / 1011: BRA, BSR ----------------

      // ---------------- 1010 / 1011: BRA, BSR ----------------
      16'b1010_????_????_????: begin k = 8'd143; illslot = 1'b1; dbr = 1'b1; n = 5'd1; end  
      16'b1011_????_????_????: begin k = 8'd144; illslot = 1'b1; dbr = 1'b1; n = 5'd2; end  // ---------------- 1100 ----------------

      // ---------------- 1100 ----------------
      16'b1100_0000_????_????: begin k = 8'd145;  end  // MOV.B R0, @(disp, GBR)
      16'b1100_0001_????_????: begin k = 8'd146;  end  // MOV.W
      16'b1100_0010_????_????: begin k = 8'd147;  end  // MOV.L
      16'b1100_0011_????_????: begin k = 8'd148; illslot = 1'b1; n = 5'd2; end  // TRAPA #imm
      16'b1100_0100_????_????: begin k = 8'd149;  end  // MOV.B @(disp, GBR), R0
      16'b1100_0101_????_????: begin k = 8'd150;  end  // MOV.W
      16'b1100_0110_????_????: begin k = 8'd151;  end  // MOV.L
      16'b1100_0111_????_????: begin k = 8'd152; illslot = 1'b1; end  // MOVA
      16'b1100_1000_????_????: begin k = 8'd153; n = 5'd2; end  // TST #imm, R0
      16'b1100_1001_????_????: begin k = 8'd154;  end  // AND #imm, R0
      16'b1100_1010_????_????: begin k = 8'd155; n = 5'd2; end  // XOR #imm, R0
      16'b1100_1011_????_????: begin k = 8'd156;  end  // OR #imm, R0
      16'b1100_1100_????_????: begin k = 8'd157; n = 5'd3; end  // TST.B
      16'b1100_1101_????_????: begin k = 8'd158; n = 5'd3; end  // AND.B
      16'b1100_1110_????_????: begin k = 8'd159; n = 5'd4; end  // XOR.B
      16'b1100_1111_????_????: begin k = 8'd160; n = 5'd3; end  // OR.B

      // ---------------- 1101: MOV.L @(disp, PC), Rn ----------------
      16'b1101_????_????_????: begin k = 8'd161; illslot = 1'b1; n = 5'd2; end  // ---------------- 1110: MOV #imm, Rn ----------------

      // ---------------- 1110: MOV #imm, Rn ----------------
      16'b1110_????_????_????: begin k = 8'd162;  end  // ---------------- 1111: floating point ----------------

      // ---------------- 1111: floating point ----------------
      16'b1111_????_????_0000: begin k = 8'd163; isfpu = 1'b1; if (sr_pr_i && (n4[0] | m4[0])) resinst = 1'b1; end  // FADD
      16'b1111_????_????_0001: begin k = 8'd164; isfpu = 1'b1; if (sr_pr_i && (n4[0] | m4[0])) resinst = 1'b1; end  // FSUB
      16'b1111_????_????_0010: begin k = 8'd165; isfpu = 1'b1; if (sr_pr_i && (n4[0] | m4[0])) resinst = 1'b1; end  // FMUL
      16'b1111_????_????_0011: begin k = 8'd166; isfpu = 1'b1; if (sr_pr_i && (n4[0] | m4[0])) resinst = 1'b1; end  // FDIV
      16'b1111_????_????_0100: begin k = 8'd167; isfpu = 1'b1; if (sr_pr_i && (n4[0] | m4[0])) resinst = 1'b1; end  // FCMP/EQ
      16'b1111_????_????_0101: begin k = 8'd168; isfpu = 1'b1; if (sr_pr_i && (n4[0] | m4[0])) resinst = 1'b1; end  // FCMP/GT
      16'b1111_????_????_0110: begin k = 8'd169; isfpu = 1'b1; end  // FMOV @(R0, Rm), FRn / DRn / XDn
      16'b1111_????_????_0111: begin k = 8'd170; isfpu = 1'b1; end  // FMOV FRm, @(R0, Rn)
      16'b1111_????_????_1000: begin k = 8'd171; isfpu = 1'b1; end  // FMOV @Rm, FRn
      16'b1111_????_????_1001: begin k = 8'd172; isfpu = 1'b1; n = 5'd2; end  // FMOV @Rm+, FRn
      16'b1111_????_????_1010: begin k = 8'd173; isfpu = 1'b1; end  // FMOV FRm, @Rn
      16'b1111_????_????_1011: begin k = 8'd174; isfpu = 1'b1; n = 5'd3; end  // FMOV FRm, @-Rn
      16'b1111_????_????_1100: begin k = 8'd175; isfpu = 1'b1; end  // FMOV FRm, FRn (SZ = 0) / DR, XD pairs (SZ = 1)
      16'b1111_????_0000_1101: begin k = 8'd176; isfpu = 1'b1; end  // FSTS FPUL, FRn
      16'b1111_????_0001_1101: begin k = 8'd177; isfpu = 1'b1; end  // FLDS FRm, FPUL
      16'b1111_????_0010_1101: begin k = 8'd178; isfpu = 1'b1; if (sr_pr_i && n4[0]) resinst = 1'b1; end  // FLOAT FPUL, FRn/DRn
      16'b1111_????_0011_1101: begin k = 8'd179; isfpu = 1'b1; if (sr_pr_i && n4[0]) resinst = 1'b1; end  // FTRC FRm/DRm, FPUL
      16'b1111_????_0100_1101: begin k = 8'd180; isfpu = 1'b1; if (sr_pr_i && n4[0]) resinst = 1'b1; end  // FNEG
      16'b1111_????_0101_1101: begin k = 8'd181; isfpu = 1'b1; if (sr_pr_i && n4[0]) resinst = 1'b1; end  // FABS
      16'b1111_????_0110_1101: begin k = 8'd182; isfpu = 1'b1; if (sr_pr_i && n4[0]) resinst = 1'b1; end  // FSQRT
      16'b1111_????_0111_1101: begin k = 8'd183; isfpu = 1'b1; if (sr_pr_i) resinst = 1'b1; end  // FSRRA
      16'b1111_????_1000_1101: begin k = 8'd184; isfpu = 1'b1; if (sr_pr_i) resinst = 1'b1; end  // FLDI0
      16'b1111_????_1001_1101: begin k = 8'd185; isfpu = 1'b1; n = 5'd2; if (sr_pr_i) resinst = 1'b1; end  // FLDI1
      16'b1111_???0_1010_1101: begin k = 8'd186; isfpu = 1'b1; if (!sr_pr_i) resinst = 1'b1; end  // FCNVSD FPUL, DRn
      16'b1111_???0_1011_1101: begin k = 8'd187; isfpu = 1'b1; if (!sr_pr_i) resinst = 1'b1; end  // FCNVDS DRm, FPUL
      16'b1111_1011_1111_1101: begin k = 8'd188; isfpu = 1'b1; n = 5'd2; end  // FRCHG
      16'b1111_0011_1111_1101: begin k = 8'd189; isfpu = 1'b1; n = 5'd2; end  // FSCHG
      16'b1111_??01_1111_1101: begin k = 8'd190; isfpu = 1'b1; if (sr_pr_i) resinst = 1'b1; end  // FTRV XMTRX, FVn
      16'b1111_???0_1111_1101: begin k = 8'd191; isfpu = 1'b1; n = 5'd2; if (sr_pr_i) resinst = 1'b1; end  // FSCA FPUL, DRn
      16'b1111_????_1110_1101: begin k = 8'd192; isfpu = 1'b1; if (sr_pr_i) resinst = 1'b1; end  // FIPR FVm, FVn
      16'b1111_????_????_1110: begin k = 8'd193; isfpu = 1'b1; if (sr_pr_i) resinst = 1'b1; end  // FMAC FR0, FRm, FRn
      default: resinst = 1'b1;
    endcase

    // step encodings of the selected instruction kind
    case (k)
      8'd0: begin  // BSRF Rn
        if (step_i == 4'd0) ins = PS(PS_MOVI32, Z, Z, S0);
        if (step_i == 4'd0) imm = pc4;
        if (step_i == 4'd1) ins = ADD(S0, rn, S0);
        if (step_i == 4'd2) ins = PTABS(S0, TR0);
        if (step_i == 4'd3) ins = PS(PS_MOVI32, Z, Z, PR);
        if (step_i == 4'd3) imm = pc4;
      end
      8'd1: begin  // BRAF Rn
        if (step_i == 4'd0) ins = PS(PS_MOVI32, Z, Z, S0);
        if (step_i == 4'd0) imm = pc4;
        if (step_i == 4'd1) ins = ADD(S0, rn, S0);
        if (step_i == 4'd2) ins = PTABS(S0, TR0);
      end
      8'd2: begin  // PREF @Rn: no operation on this core
        if (step_i == 4'd0) ins = NOP();
      end
      8'd3: begin  // OCBI
        if (step_i == 4'd0) ins = CACHEOP(4'd9, rn);
      end
      8'd4: begin  // OCBP
        if (step_i == 4'd0) ins = CACHEOP(4'd8, rn);
      end
      8'd5: begin  // OCBWB
        if (step_i == 4'd0) ins = CACHEOP(4'd12, rn);
      end
      8'd6: begin  // MOVCA.L R0, @Rn
        if (step_i == 4'd0) ins = CACHEOP(4'd4, rn);
        if (step_i == 4'd1) ins = ST(2'd2, rn, 10'd0, 6'd0);
      end
      8'd7: begin  // MOV.B Rm, @(R0, Rn)
        if (step_i == 4'd0) ins = STX(2'd0, rn, 6'd0, rm);
      end
      8'd8: begin  // MOV.W
        if (step_i == 4'd0) ins = STX(2'd1, rn, 6'd0, rm);
      end
      8'd9: begin  // MOV.L
        if (step_i == 4'd0) ins = STX(2'd2, rn, 6'd0, rm);
      end
      8'd10: begin  // MUL.L Rm, Rn: MACL = low 32 bits of the product, MACH kept
        if (step_i == 4'd0) ins = MULSL(rn, rm, S0);
        if (step_i == 4'd1) ins = SHLRI(MAC, 6'd32, S1);
        if (step_i == 4'd2) ins = SHLLI(S1, 6'd32, S1);
        if (step_i == 4'd3) ins = ADDZL(S0, Z, S0);
        if (step_i == 4'd4) ins = OR(S1, S0, MAC);
      end
      8'd11: begin  // CLRT
        if (step_i == 4'd0) ins = OR(Z, Z, T);
      end
      8'd12: begin  // SETT
        if (step_i == 4'd0) ins = ADDI(Z, 10'd1, T);
      end
      8'd13: begin  // CLRMAC
        if (step_i == 4'd0) ins = OR(Z, Z, MAC);
      end
      8'd14: begin  // BRK (0x003b)
        if (step_i == 4'd0) ins = BRK();
      end
      8'd15: begin  // CLRS
        if (step_i == 4'd0) ins = PS(PS_SRFLAG, Z, Z, Z);
        if (step_i == 4'd0) imm = M_S;
      end
      8'd16: begin  // SETS
        if (step_i == 4'd0) ins = MOVI(16'd2, S0);
        if (step_i == 4'd1) ins = PS(PS_SRFLAG, S0, Z, Z);
        if (step_i == 4'd1) imm = M_S;
      end
      8'd17: begin  // NOP
        if (step_i == 4'd0) ins = NOP();
      end
      8'd18: begin  // DIV0U
        if (step_i == 4'd0) ins = PS(PS_SRFLAG, Z, Z, Z);
        if (step_i == 4'd0) imm = M_Q | M_M;
        if (step_i == 4'd1) ins = OR(Z, Z, T);
      end
      8'd19: begin  // MOVT Rn
        if (step_i == 4'd0) ins = OR(T, Z, rn);
      end
      8'd20: begin  // RTS
        if (step_i == 4'd0) ins = PTABS(PR, TR0);
      end
      8'd21: begin  // SLEEP: privileged
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd22: begin  // RTE: privileged
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd23: begin  // MOV.B @(R0, Rm), Rn
        if (step_i == 4'd0) ins = LDX(2'd0, 1'b1, rm, 6'd0, rn);
      end
      8'd24: begin  // MOV.W
        if (step_i == 4'd0) ins = LDX(2'd1, 1'b1, rm, 6'd0, rn);
      end
      8'd25: begin  // MOV.L
        if (step_i == 4'd0) ins = LDX(2'd2, 1'b1, rm, 6'd0, rn);
      end
      8'd26: begin  // MAC.L @Rm+, @Rn+
        if (step_i == 4'd0) ins = LD(2'd2, 1'b1, rn, 10'd0, S0);
        if (step_i == 4'd1) ins = (n4 == m4) ? LD(2'd2, 1'b1, rn, 10'd1, S1) : LD(2'd2, 1'b1, rm, 10'd0, S1);
        if (step_i == 4'd2) ins = MULSL(S0, S1, S2);
        if (step_i == 4'd3) ins = sr_s_i ? PS(PS_ADDSAT48, MAC, S2, MAC) : ADD(MAC, S2, MAC);
        if (step_i == 4'd4) ins = (n4 == m4) ? ADDIL(rn, 10'd8, rn) : ADDIL(rn, 10'd4, rn);
        if (step_i == 4'd5) ins = ADDIL(rm, 10'd4, rm);
      end
      8'd27: begin  // STC SR: privileged
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd28: begin  // STC GBR, Rn
        if (step_i == 4'd0) ins = ADDL(GBR, Z, rn);
      end
      8'd29: begin  // STC VBR
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd30: begin  // STC SSR
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd31: begin  // STC SPC
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd32: begin  // STC Rn_BANK
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd33: begin  // STS MACH, Rn
        if (step_i == 4'd0) ins = SHARI(MAC, 6'd32, rn);
      end
      8'd34: begin  // STS MACL, Rn
        if (step_i == 4'd0) ins = ADDL(MAC, Z, rn);
      end
      8'd35: begin  // STS PR, Rn
        if (step_i == 4'd0) ins = ADDL(PR, Z, rn);
      end
      8'd36: begin  // STS FPUL, Rn
        if (step_i == 4'd0) ins = FMOVSL(FPUL, rn);
      end
      8'd37: begin  // STS FPSCR, Rn
        if (step_i == 4'd0) ins = PS(PS_GETFPSCR, Z, Z, rn);
      end
      8'd38: begin  // ---------------- 0010 ----------------
        if (step_i == 4'd0) ins = ST(2'd2, rn, {6'b0, insn_i[3:0]}, rm);
      end
      8'd39: begin  // MOV.B Rm, @Rn
        if (step_i == 4'd0) ins = ST(2'd0, rn, 10'd0, rm);
      end
      8'd40: begin  // MOV.W
        if (step_i == 4'd0) ins = ST(2'd1, rn, 10'd0, rm);
      end
      8'd41: begin  // MOV.L
        if (step_i == 4'd0) ins = ST(2'd2, rn, 10'd0, rm);
      end
      8'd42: begin  // MOV.B Rm, @-Rn
        if (step_i == 4'd0) ins = ADDI(rn, 10'h3ff, S0);
        if (step_i == 4'd1) ins = ST(2'd0, S0, 10'd0, rm);
        if (step_i == 4'd2) ins = ADDL(S0, Z, rn);
      end
      8'd43: begin  // MOV.W Rm, @-Rn
        if (step_i == 4'd0) ins = ADDI(rn, 10'h3fe, S0);
        if (step_i == 4'd1) ins = ST(2'd1, S0, 10'd0, rm);
        if (step_i == 4'd2) ins = ADDL(S0, Z, rn);
      end
      8'd44: begin  // MOV.L Rm, @-Rn
        if (step_i == 4'd0) ins = ADDI(rn, 10'h3fc, S0);
        if (step_i == 4'd1) ins = ST(2'd2, S0, 10'd0, rm);
        if (step_i == 4'd2) ins = ADDL(S0, Z, rn);
      end
      8'd45: begin  // DIV0S Rm, Rn
        if (step_i == 4'd0) ins = PS(PS_DIV0S, rm, rn, S0);
        if (step_i == 4'd1) ins = ANDI(S0, 10'd1, T);
        if (step_i == 4'd2) ins = PS(PS_SRFLAG, S0, Z, Z);
        if (step_i == 4'd2) imm = M_Q | M_M;
      end
      8'd46: begin  // TST Rm, Rn
        if (step_i == 4'd0) ins = AND(rn, rm, S0);
        if (step_i == 4'd1) ins = CMPEQ(S0, Z, T);
      end
      8'd47: begin  // AND Rm, Rn
        if (step_i == 4'd0) ins = AND(rn, rm, rn);
      end
      8'd48: begin  // XOR
        if (step_i == 4'd0) ins = XOR(rn, rm, rn);
      end
      8'd49: begin  // OR
        if (step_i == 4'd0) ins = OR(rn, rm, rn);
      end
      8'd50: begin  // CMP/STR Rm, Rn: any byte of the low words equal
        if (step_i == 4'd0) ins = MCMPEQB(rn, rm, S0);
        if (step_i == 4'd1) ins = SHLLI(S0, 6'd32, S0);
        if (step_i == 4'd2) ins = CMPEQ(S0, Z, S1);
        if (step_i == 4'd3) ins = XORI(S1, 6'd1, T);
      end
      8'd51: begin  // XTRCT
        if (step_i == 4'd0) ins = SHLLIL(rm, 6'd16, S0);
        if (step_i == 4'd1) ins = SHLRIL(rn, 6'd16, S1);
        if (step_i == 4'd2) ins = OR(S0, S1, rn);
      end
      8'd52: begin  // MULU.W Rm, Rn
        if (step_i == 4'd0) ins = SHLLI(rn, 6'd48, S0);
        if (step_i == 4'd1) ins = SHLRI(S0, 6'd48, S0);
        if (step_i == 4'd2) ins = SHLLI(rm, 6'd48, S1);
        if (step_i == 4'd3) ins = SHLRI(S1, 6'd48, S1);
        if (step_i == 4'd4) ins = MULUL(S0, S1, S0);
        if (step_i == 4'd5) ins = SHLRI(MAC, 6'd32, S1);
        if (step_i == 4'd6) ins = SHLLI(S1, 6'd32, S1);
        if (step_i == 4'd7) ins = ADDZL(S0, Z, S0);
        if (step_i == 4'd8) ins = OR(S1, S0, MAC);
      end
      8'd53: begin  // MULS.W Rm, Rn
        if (step_i == 4'd0) ins = SHLLI(rn, 6'd48, S0);
        if (step_i == 4'd1) ins = SHARI(S0, 6'd48, S0);
        if (step_i == 4'd2) ins = SHLLI(rm, 6'd48, S1);
        if (step_i == 4'd3) ins = SHARI(S1, 6'd48, S1);
        if (step_i == 4'd4) ins = MULSL(S0, S1, S0);
        if (step_i == 4'd5) ins = SHLRI(MAC, 6'd32, S1);
        if (step_i == 4'd6) ins = SHLLI(S1, 6'd32, S1);
        if (step_i == 4'd7) ins = ADDZL(S0, Z, S0);
        if (step_i == 4'd8) ins = OR(S1, S0, MAC);
      end
      8'd54: begin  // CMP/EQ Rm, Rn
        if (step_i == 4'd0) ins = CMPEQ(rn, rm, T);
      end
      8'd55: begin  // CMP/HS
        if (step_i == 4'd0) ins = CMPGTU(rm, rn, S0);
        if (step_i == 4'd1) ins = XORI(S0, 6'd1, T);
      end
      8'd56: begin  // CMP/GE
        if (step_i == 4'd0) ins = CMPGT(rm, rn, S0);
        if (step_i == 4'd1) ins = XORI(S0, 6'd1, T);
      end
      8'd57: begin  // CMP/HI
        if (step_i == 4'd0) ins = CMPGTU(rn, rm, T);
      end
      8'd58: begin  // CMP/GT
        if (step_i == 4'd0) ins = CMPGT(rn, rm, T);
      end
      8'd59: begin  // DIV1 Rm, Rn
        if (step_i == 4'd0) ins = PS(PS_DIV1, rm, rn, S0);
        if (step_i == 4'd1) ins = ADDL(S0, Z, rn);
        if (step_i == 4'd2) ins = SHLRI(S0, 6'd32, S1);
        if (step_i == 4'd3) ins = ANDI(S1, 10'd1, T);
        if (step_i == 4'd4) ins = PS(PS_SRFLAG, S1, Z, Z);
        if (step_i == 4'd4) imm = M_Q;
      end
      8'd60: begin  // DMULU.L
        if (step_i == 4'd0) ins = MULUL(rn, rm, MAC);
      end
      8'd61: begin  // DMULS.L
        if (step_i == 4'd0) ins = MULSL(rn, rm, MAC);
      end
      8'd62: begin  // SUB Rm, Rn
        if (step_i == 4'd0) ins = SUBL(rn, rm, rn);
      end
      8'd63: begin  // SUBC Rm, Rn
        if (step_i == 4'd0) ins = ADDZL(rn, Z, S0);
        if (step_i == 4'd1) ins = ADDZL(rm, Z, S1);
        if (step_i == 4'd2) ins = SUB(S0, S1, S0);
        if (step_i == 4'd3) ins = SUB(S0, T, S0);
        if (step_i == 4'd4) ins = ADDL(S0, Z, rn);
        if (step_i == 4'd5) ins = SHLRI(S0, 6'd63, T);
      end
      8'd64: begin  // SUBV Rm, Rn
        if (step_i == 4'd0) ins = SUB(rn, rm, S0);
        if (step_i == 4'd1) ins = SUBL(rn, rm, S1);
        if (step_i == 4'd2) ins = CMPEQ(S0, S1, S2);
        if (step_i == 4'd3) ins = XORI(S2, 6'd1, T);
        if (step_i == 4'd4) ins = OR(S1, Z, rn);
      end
      8'd65: begin  // ADD Rm, Rn
        if (step_i == 4'd0) ins = ADDL(rn, rm, rn);
      end
      8'd66: begin  // ADDC Rm, Rn
        if (step_i == 4'd0) ins = ADDZL(rn, Z, S0);
        if (step_i == 4'd1) ins = ADDZL(rm, Z, S1);
        if (step_i == 4'd2) ins = ADD(S0, S1, S0);
        if (step_i == 4'd3) ins = ADD(S0, T, S0);
        if (step_i == 4'd4) ins = ADDL(S0, Z, rn);
        if (step_i == 4'd5) ins = SHLRI(S0, 6'd32, T);
      end
      8'd67: begin  // ADDV Rm, Rn
        if (step_i == 4'd0) ins = ADD(rn, rm, S0);
        if (step_i == 4'd1) ins = ADDL(rn, rm, S1);
        if (step_i == 4'd2) ins = CMPEQ(S0, S1, S2);
        if (step_i == 4'd3) ins = XORI(S2, 6'd1, T);
        if (step_i == 4'd4) ins = OR(S1, Z, rn);
      end
      8'd68: begin  // SHLL
        if (step_i == 4'd0) ins = SHLRI(rn, 6'd31, S1);
        if (step_i == 4'd1) ins = ANDI(S1, 10'd1, T);
        if (step_i == 4'd2) ins = SHLLIL(rn, 6'd1, rn);
      end
      8'd69: begin  // SHAL
        if (step_i == 4'd0) ins = SHLRI(rn, 6'd31, S1);
        if (step_i == 4'd1) ins = ANDI(S1, 10'd1, T);
        if (step_i == 4'd2) ins = SHLLIL(rn, 6'd1, rn);
      end
      8'd70: begin  // SHLR
        if (step_i == 4'd0) ins = ANDI(rn, 10'd1, T);
        if (step_i == 4'd1) ins = SHLRIL(rn, 6'd1, rn);
      end
      8'd71: begin  // SHAR
        if (step_i == 4'd0) ins = ANDI(rn, 10'd1, T);
        if (step_i == 4'd1) ins = SHARIL(rn, 6'd1, rn);
      end
      8'd72: begin  // ROTL Rn
        if (step_i == 4'd0) ins = SHLRI(rn, 6'd31, S1);
        if (step_i == 4'd1) ins = ANDI(S1, 10'd1, T);
        if (step_i == 4'd2) ins = SHLLIL(rn, 6'd1, S0);
        if (step_i == 4'd3) ins = OR(S0, T, rn);
      end
      8'd73: begin  // ROTR Rn
        if (step_i == 4'd0) ins = ANDI(rn, 10'd1, T);
        if (step_i == 4'd1) ins = SHLRIL(rn, 6'd1, S0);
        if (step_i == 4'd2) ins = SHLLIL(T, 6'd31, S1);
        if (step_i == 4'd3) ins = OR(S0, S1, rn);
      end
      8'd74: begin  // ROTCL Rn
        if (step_i == 4'd0) ins = SHLLIL(rn, 6'd1, S0);
        if (step_i == 4'd1) ins = OR(S0, T, S0);
        if (step_i == 4'd2) ins = SHLRI(rn, 6'd31, S1);
        if (step_i == 4'd3) ins = ANDI(S1, 10'd1, T);
        if (step_i == 4'd4) ins = OR(S0, Z, rn);
      end
      8'd75: begin  // ROTCR Rn
        if (step_i == 4'd0) ins = SHLRIL(rn, 6'd1, S0);
        if (step_i == 4'd1) ins = SHLLIL(T, 6'd31, S1);
        if (step_i == 4'd2) ins = OR(S0, S1, S0);
        if (step_i == 4'd3) ins = ANDI(rn, 10'd1, T);
        if (step_i == 4'd4) ins = OR(S0, Z, rn);
      end
      8'd76: begin  // SHLL2
        if (step_i == 4'd0) ins = SHLLIL(rn, 6'd2, rn);
      end
      8'd77: begin  // SHLL8
        if (step_i == 4'd0) ins = SHLLIL(rn, 6'd8, rn);
      end
      8'd78: begin  // SHLL16
        if (step_i == 4'd0) ins = SHLLIL(rn, 6'd16, rn);
      end
      8'd79: begin  // SHLR2
        if (step_i == 4'd0) ins = SHLRIL(rn, 6'd2, rn);
      end
      8'd80: begin  // SHLR8
        if (step_i == 4'd0) ins = SHLRIL(rn, 6'd8, rn);
      end
      8'd81: begin  // SHLR16
        if (step_i == 4'd0) ins = SHLRIL(rn, 6'd16, rn);
      end
      8'd82: begin  // STS.L MACH, @-Rn
        if (step_i == 4'd0) ins = SHARI(MAC, 6'd32, S1);
        if (step_i == 4'd1) ins = ADDI(rn, 10'h3fc, S0);
        if (step_i == 4'd2) ins = ST(2'd2, S0, 10'd0, S1);
        if (step_i == 4'd3) ins = ADDL(S0, Z, rn);
      end
      8'd83: begin  // STS.L MACL, @-Rn
        if (step_i == 4'd0) ins = ADDI(rn, 10'h3fc, S0);
        if (step_i == 4'd1) ins = ST(2'd2, S0, 10'd0, MAC);
        if (step_i == 4'd2) ins = ADDL(S0, Z, rn);
      end
      8'd84: begin  // STS.L PR, @-Rn
        if (step_i == 4'd0) ins = ADDI(rn, 10'h3fc, S0);
        if (step_i == 4'd1) ins = ST(2'd2, S0, 10'd0, PR);
        if (step_i == 4'd2) ins = ADDL(S0, Z, rn);
      end
      8'd85: begin  // STS.L FPUL, @-Rn
        if (step_i == 4'd0) ins = ADDI(rn, 10'h3fc, S0);
        if (step_i == 4'd1) ins = FSTS(S0, 10'd0, FPUL);
        if (step_i == 4'd2) ins = ADDL(S0, Z, rn);
      end
      8'd86: begin  // STS.L FPSCR, @-Rn
        if (step_i == 4'd0) ins = PS(PS_GETFPSCR, Z, Z, S1);
        if (step_i == 4'd1) ins = ADDI(rn, 10'h3fc, S0);
        if (step_i == 4'd2) ins = ST(2'd2, S0, 10'd0, S1);
        if (step_i == 4'd3) ins = ADDL(S0, Z, rn);
      end
      8'd87: begin  // STC.L SR
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd88: begin  // STC.L GBR, @-Rn
        if (step_i == 4'd0) ins = ADDI(rn, 10'h3fc, S0);
        if (step_i == 4'd1) ins = ST(2'd2, S0, 10'd0, GBR);
        if (step_i == 4'd2) ins = ADDL(S0, Z, rn);
      end
      8'd89: begin  // STC.L VBR/SSR/SPC/Rn_BANK
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd90: begin  // LDS.L @Rm+, MACH
        if (step_i == 4'd0) ins = LD(2'd2, 1'b1, rn, 10'd0, S2);
        if (step_i == 4'd1) ins = ADDZL(MAC, Z, S0);
        if (step_i == 4'd2) ins = SHLLI(S2, 6'd32, S1);
        if (step_i == 4'd3) ins = OR(S0, S1, MAC);
        if (step_i == 4'd4) ins = ADDIL(rn, 10'd4, rn);
      end
      8'd91: begin  // LDS.L @Rm+, MACL
        if (step_i == 4'd0) ins = LD(2'd2, 1'b1, rn, 10'd0, S2);
        if (step_i == 4'd1) ins = SHLRI(MAC, 6'd32, S0);
        if (step_i == 4'd2) ins = SHLLI(S0, 6'd32, S0);
        if (step_i == 4'd3) ins = ADDZL(S2, Z, S1);
        if (step_i == 4'd4) ins = OR(S0, S1, MAC);
        if (step_i == 4'd5) ins = ADDIL(rn, 10'd4, rn);
      end
      8'd92: begin  // LDS.L @Rm+, PR
        if (step_i == 4'd0) ins = LD(2'd2, 1'b1, rn, 10'd0, PR);
        if (step_i == 4'd1) ins = ADDIL(rn, 10'd4, rn);
      end
      8'd93: begin  // LDS.L @Rm+, FPUL
        if (step_i == 4'd0) ins = FLDS(rn, 10'd0, FPUL);
        if (step_i == 4'd1) ins = ADDIL(rn, 10'd4, rn);
      end
      8'd94: begin  // LDS.L @Rm+, FPSCR
        if (step_i == 4'd0) ins = LD(2'd2, 1'b1, rn, 10'd0, S1);
        if (step_i == 4'd1) ins = FMOVLS(S1, FSCR);
        if (step_i == 4'd2) ins = FPUTSCR(FSCR);
        if (step_i == 4'd3) ins = SHLRI(S1, 6'd7, S0);
        if (step_i == 4'd4) ins = PS(PS_SRFLAG, S0, Z, Z);
        if (step_i == 4'd4) imm = M_PR | M_SZ | M_FR;
        if (step_i == 4'd5) ins = ADDIL(rn, 10'd4, rn);
      end
      8'd95: begin  // LDC.L SR
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd96: begin  // LDC.L @Rm+, GBR
        if (step_i == 4'd0) ins = LD(2'd2, 1'b1, rn, 10'd0, GBR);
        if (step_i == 4'd1) ins = ADDIL(rn, 10'd4, rn);
      end
      8'd97: begin  // LDC.L VBR/SSR/SPC/Rn_BANK
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd98: begin  // LDS Rm, MACH
        if (step_i == 4'd0) ins = ADDZL(MAC, Z, S0);
        if (step_i == 4'd1) ins = SHLLI(rn, 6'd32, S1);
        if (step_i == 4'd2) ins = OR(S0, S1, MAC);
      end
      8'd99: begin  // LDS Rm, MACL
        if (step_i == 4'd0) ins = SHLRI(MAC, 6'd32, S0);
        if (step_i == 4'd1) ins = SHLLI(S0, 6'd32, S0);
        if (step_i == 4'd2) ins = ADDZL(rn, Z, S1);
        if (step_i == 4'd3) ins = OR(S0, S1, MAC);
      end
      8'd100: begin  // LDS Rm, PR
        if (step_i == 4'd0) ins = ADDL(rn, Z, PR);
      end
      8'd101: begin  // LDS Rm, FPUL
        if (step_i == 4'd0) ins = FMOVLS(rn, FPUL);
      end
      8'd102: begin  // LDS Rm, FPSCR
        if (step_i == 4'd0) ins = FMOVLS(rn, FSCR);
        if (step_i == 4'd1) ins = FPUTSCR(FSCR);
        if (step_i == 4'd2) ins = SHLRI(rn, 6'd7, S0);
        if (step_i == 4'd3) ins = PS(PS_SRFLAG, S0, Z, Z);
        if (step_i == 4'd3) imm = M_PR | M_SZ | M_FR;
      end
      8'd103: begin  // JSR @Rn
        if (step_i == 4'd0) ins = PTABS(rn, TR0);
        if (step_i == 4'd1) ins = PS(PS_MOVI32, Z, Z, PR);
        if (step_i == 4'd1) imm = pc4;
      end
      8'd104: begin  // TAS.B @Rn
        if (step_i == 4'd0) ins = LD(2'd0, 1'b0, rn, 10'd0, S0);
        if (step_i == 4'd1) ins = CMPEQ(S0, Z, T);
        if (step_i == 4'd2) ins = ORI(S0, 10'h080, S1);
        if (step_i == 4'd3) ins = ST(2'd0, rn, 10'd0, S1);
      end
      8'd105: begin  // JMP @Rn
        if (step_i == 4'd0) ins = PTABS(rn, TR0);
      end
      8'd106: begin  // LDC Rm, SR
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd107: begin  // LDC Rm, GBR
        if (step_i == 4'd0) ins = ADDL(rn, Z, GBR);
      end
      8'd108: begin  // LDC VBR/SSR/SPC/Rn_BANK
        if (step_i == 4'd0) ins = PS(PS_EXC, Z, Z, Z);
        if (step_i == 4'd0) imm = {20'h0, EVT_RESINST};
      end
      8'd109: begin  // DT Rn
        if (step_i == 4'd0) ins = ADDIL(rn, 10'h3ff, rn);
        if (step_i == 4'd1) ins = CMPEQ(rn, Z, T);
      end
      8'd110: begin  // CMP/PZ
        if (step_i == 4'd0) ins = CMPGT(Z, rn, S0);
        if (step_i == 4'd1) ins = XORI(S0, 6'd1, T);
      end
      8'd111: begin  // CMP/PL
        if (step_i == 4'd0) ins = CMPGT(rn, Z, T);
      end
      8'd112: begin  // SHAD Rm, Rn
        if (step_i == 4'd0) ins = SHLLDL(rn, rm, S0);
        if (step_i == 4'd1) ins = SUB(Z, rm, S1);
        if (step_i == 4'd2) ins = SHARDL(rn, S1, S1);
        if (step_i == 4'd3) ins = ANDI(rm, 10'd31, S2);
        if (step_i == 4'd4) ins = SHARIL(rn, 6'd31, S3);
        if (step_i == 4'd5) ins = CMVEQ(S2, S3, S1);
        if (step_i == 4'd6) ins = SHLRI(rm, 6'd31, S2);
        if (step_i == 4'd7) ins = ANDI(S2, 10'd1, S2);
        if (step_i == 4'd8) ins = CMVNE(S2, S1, S0);
        if (step_i == 4'd9) ins = OR(S0, Z, rn);
      end
      8'd113: begin  // SHLD Rm, Rn
        if (step_i == 4'd0) ins = SHLLDL(rn, rm, S0);
        if (step_i == 4'd1) ins = SUB(Z, rm, S1);
        if (step_i == 4'd2) ins = SHLRDL(rn, S1, S1);
        if (step_i == 4'd3) ins = ANDI(rm, 10'd31, S2);
        if (step_i == 4'd4) ins = CMVEQ(S2, Z, S1);
        if (step_i == 4'd5) ins = SHLRI(rm, 6'd31, S2);
        if (step_i == 4'd6) ins = ANDI(S2, 10'd1, S2);
        if (step_i == 4'd7) ins = CMVNE(S2, S1, S0);
        if (step_i == 4'd8) ins = OR(S0, Z, rn);
      end
      8'd114: begin  // MAC.W @Rm+, @Rn+
        if (step_i == 4'd0) ins = LD(2'd1, 1'b1, rn, 10'd0, S0);
        if (step_i == 4'd1) ins = (n4 == m4) ? LD(2'd1, 1'b1, rn, 10'd1, S1) : LD(2'd1, 1'b1, rm, 10'd0, S1);
        if (step_i == 4'd2) ins = MULSL(S0, S1, S2);
        if (step_i == 4'd3) ins = sr_s_i ? PS(PS_MACWSAT, MAC, S2, MAC) : ADD(MAC, S2, MAC);
        if (step_i == 4'd4) ins = (n4 == m4) ? ADDIL(rn, 10'd4, rn) : ADDIL(rn, 10'd2, rn);
        if (step_i == 4'd5) ins = ADDIL(rm, 10'd2, rm);
      end
      8'd115: begin  // ---------------- 0110 ----------------
        if (step_i == 4'd0) ins = LD(2'd2, 1'b1, rm, {6'b0, insn_i[3:0]}, rn);
      end
      8'd116: begin  // MOV.B @Rm, Rn
        if (step_i == 4'd0) ins = LD(2'd0, 1'b1, rm, 10'd0, rn);
      end
      8'd117: begin  // MOV.W
        if (step_i == 4'd0) ins = LD(2'd1, 1'b1, rm, 10'd0, rn);
      end
      8'd118: begin  // MOV.L
        if (step_i == 4'd0) ins = LD(2'd2, 1'b1, rm, 10'd0, rn);
      end
      8'd119: begin  // MOV Rm, Rn (64-bit)
        if (step_i == 4'd0) ins = OR(rm, Z, rn);
      end
      8'd120: begin  // MOV.B @Rm+, Rn
        if (step_i == 4'd0) ins = LD(2'd0, 1'b1, rm, 10'd0, rn);
        if (step_i == 4'd1) ins = ADDIL(rm, 10'd1, rm);
      end
      8'd121: begin  // MOV.W @Rm+, Rn
        if (step_i == 4'd0) ins = LD(2'd1, 1'b1, rm, 10'd0, rn);
        if (step_i == 4'd1) ins = ADDIL(rm, 10'd2, rm);
      end
      8'd122: begin  // MOV.L @Rm+, Rn
        if (step_i == 4'd0) ins = LD(2'd2, 1'b1, rm, 10'd0, rn);
        if (step_i == 4'd1) ins = ADDIL(rm, 10'd4, rm);
      end
      8'd123: begin  // NOT Rm, Rn (64-bit)
        if (step_i == 4'd0) ins = XORI(rm, 6'h3f, rn);
      end
      8'd124: begin  // SWAP.B Rm, Rn
        if (step_i == 4'd0) ins = BYTEREV(rm, S0);
        if (step_i == 4'd1) ins = SHLRI(S0, 6'd48, S0);
        if (step_i == 4'd2) ins = SHARI(rm, 6'd16, S1);
        if (step_i == 4'd3) ins = SHLLI(S1, 6'd16, S1);
        if (step_i == 4'd4) ins = OR(S0, S1, rn);
      end
      8'd125: begin  // SWAP.W
        if (step_i == 4'd0) ins = SHLLIL(rm, 6'd16, S0);
        if (step_i == 4'd1) ins = SHLRIL(rm, 6'd16, S1);
        if (step_i == 4'd2) ins = OR(S0, S1, rn);
      end
      8'd126: begin  // NEGC Rm, Rn
        if (step_i == 4'd0) ins = ADDZL(rm, Z, S1);
        if (step_i == 4'd1) ins = SUB(Z, S1, S0);
        if (step_i == 4'd2) ins = SUB(S0, T, S0);
        if (step_i == 4'd3) ins = ADDL(S0, Z, rn);
        if (step_i == 4'd4) ins = SHLRI(S0, 6'd63, T);
      end
      8'd127: begin  // NEG Rm, Rn
        if (step_i == 4'd0) ins = SUBL(Z, rm, rn);
      end
      8'd128: begin  // EXTU.B
        if (step_i == 4'd0) ins = ANDI(rm, 10'd255, rn);
      end
      8'd129: begin  // EXTU.W
        if (step_i == 4'd0) ins = SHLLI(rm, 6'd48, S0);
        if (step_i == 4'd1) ins = SHLRI(S0, 6'd48, rn);
      end
      8'd130: begin  // EXTS.B
        if (step_i == 4'd0) ins = SHLLI(rm, 6'd56, S0);
        if (step_i == 4'd1) ins = SHARI(S0, 6'd56, rn);
      end
      8'd131: begin  // EXTS.W
        if (step_i == 4'd0) ins = SHLLI(rm, 6'd48, S0);
        if (step_i == 4'd1) ins = SHARI(S0, 6'd48, rn);
      end
      8'd132: begin  // ---------------- 1000 ----------------
        if (step_i == 4'd0) ins = ADDIL(rn, s8[9:0], rn);
      end
      8'd133: begin  // MOV.B R0, @(disp, Rn)
        if (step_i == 4'd0) ins = ST(2'd0, rm, {6'b0, insn_i[3:0]}, 6'd0);
      end
      8'd134: begin  // MOV.W R0, @(disp, Rn)
        if (step_i == 4'd0) ins = ST(2'd1, rm, {6'b0, insn_i[3:0]}, 6'd0);
      end
      8'd135: begin  // MOV.B @(disp, Rm), R0
        if (step_i == 4'd0) ins = LD(2'd0, 1'b1, rm, {6'b0, insn_i[3:0]}, 6'd0);
      end
      8'd136: begin  // MOV.W @(disp, Rm), R0
        if (step_i == 4'd0) ins = LD(2'd1, 1'b1, rm, {6'b0, insn_i[3:0]}, 6'd0);
      end
      8'd137: begin  // CMP/EQ #imm, R0
        if (step_i == 4'd0) ins = MOVI(s8[15:0], S0);
        if (step_i == 4'd1) ins = CMPEQ(6'd0, S0, T);
      end
      8'd138: begin  // BT label
        if (step_i == 4'd0) ins = PS(PS_PT32, Z, Z, {3'b000, TR0});
        if (step_i == 4'd0) imm = pc4 + (s8 << 1);
        if (step_i == 4'd1) ins = BNE(T, Z, TR0);
      end
      8'd139: begin  // BF label
        if (step_i == 4'd0) ins = PS(PS_PT32, Z, Z, {3'b000, TR0});
        if (step_i == 4'd0) imm = pc4 + (s8 << 1);
        if (step_i == 4'd1) ins = BEQ(T, Z, TR0);
      end
      8'd140: begin  // BT/S label: TR0 = T ? label : pc + 4
        if (step_i == 4'd0) ins = PS(PS_MOVI32, Z, Z, S0);
        if (step_i == 4'd0) imm = pc4 + (s8 << 1);
        if (step_i == 4'd1) ins = PS(PS_MOVI32, Z, Z, S1);
        if (step_i == 4'd1) imm = pc4;
        if (step_i == 4'd2) ins = CMVNE(T, S0, S1);
        if (step_i == 4'd3) ins = PTABS(S1, TR0);
      end
      8'd141: begin  // BF/S label
        if (step_i == 4'd0) ins = PS(PS_MOVI32, Z, Z, S0);
        if (step_i == 4'd0) imm = pc4 + (s8 << 1);
        if (step_i == 4'd1) ins = PS(PS_MOVI32, Z, Z, S1);
        if (step_i == 4'd1) imm = pc4;
        if (step_i == 4'd2) ins = CMVEQ(T, S0, S1);
        if (step_i == 4'd3) ins = PTABS(S1, TR0);
      end
      8'd142: begin  // ---------------- 1010 / 1011: BRA, BSR ----------------
        if (step_i == 4'd0) ins = PS(PS_MOVI32, Z, Z, S0);
        if (step_i == 4'd0) imm = pc4 + (u8 << 1);
        if (step_i == 4'd1) ins = LD(2'd1, 1'b1, S0, 10'd0, rn);
      end
      8'd143: begin  
        if (step_i == 4'd0) ins = PS(PS_PT32, Z, Z, {3'b000, TR0});
        if (step_i == 4'd0) imm = pc4 + (s12 << 1);
      end
      8'd144: begin  // ---------------- 1100 ----------------
        if (step_i == 4'd0) ins = PS(PS_PT32, Z, Z, {3'b000, TR0});
        if (step_i == 4'd0) imm = pc4 + (s12 << 1);
        if (step_i == 4'd1) ins = PS(PS_MOVI32, Z, Z, PR);
        if (step_i == 4'd1) imm = pc4;
      end
      8'd145: begin  // MOV.B R0, @(disp, GBR)
        if (step_i == 4'd0) ins = ST(2'd0, GBR, {2'b0, imm8}, 6'd0);
      end
      8'd146: begin  // MOV.W
        if (step_i == 4'd0) ins = ST(2'd1, GBR, {2'b0, imm8}, 6'd0);
      end
      8'd147: begin  // MOV.L
        if (step_i == 4'd0) ins = ST(2'd2, GBR, {2'b0, imm8}, 6'd0);
      end
      8'd148: begin  // TRAPA #imm
        if (step_i == 4'd0) ins = MOVI({8'h0, imm8}, S0);
        if (step_i == 4'd1) ins = TRAPA(S0);
      end
      8'd149: begin  // MOV.B @(disp, GBR), R0
        if (step_i == 4'd0) ins = LD(2'd0, 1'b1, GBR, {2'b0, imm8}, 6'd0);
      end
      8'd150: begin  // MOV.W
        if (step_i == 4'd0) ins = LD(2'd1, 1'b1, GBR, {2'b0, imm8}, 6'd0);
      end
      8'd151: begin  // MOV.L
        if (step_i == 4'd0) ins = LD(2'd2, 1'b1, GBR, {2'b0, imm8}, 6'd0);
      end
      8'd152: begin  // MOVA
        if (step_i == 4'd0) ins = PS(PS_MOVI32, Z, Z, 6'd0);
        if (step_i == 4'd0) imm = {pc4[31:2], 2'b00} + (u8 << 2);
      end
      8'd153: begin  // TST #imm, R0
        if (step_i == 4'd0) ins = ANDI(6'd0, {2'b0, imm8}, S0);
        if (step_i == 4'd1) ins = CMPEQ(S0, Z, T);
      end
      8'd154: begin  // AND #imm, R0
        if (step_i == 4'd0) ins = ANDI(6'd0, {2'b0, imm8}, 6'd0);
      end
      8'd155: begin  // XOR #imm, R0
        if (step_i == 4'd0) ins = MOVI({8'h0, imm8}, S0);
        if (step_i == 4'd1) ins = XOR(6'd0, S0, 6'd0);
      end
      8'd156: begin  // OR #imm, R0
        if (step_i == 4'd0) ins = ORI(6'd0, {2'b0, imm8}, 6'd0);
      end
      8'd157: begin  // TST.B
        if (step_i == 4'd0) ins = LDX(2'd0, 1'b0, GBR, 6'd0, S0);
        if (step_i == 4'd1) ins = ANDI(S0, {2'b0, imm8}, S0);
        if (step_i == 4'd2) ins = CMPEQ(S0, Z, T);
      end
      8'd158: begin  // AND.B
        if (step_i == 4'd0) ins = LDX(2'd0, 1'b0, GBR, 6'd0, S0);
        if (step_i == 4'd1) ins = ANDI(S0, {2'b0, imm8}, S0);
        if (step_i == 4'd2) ins = STX(2'd0, GBR, 6'd0, S0);
      end
      8'd159: begin  // XOR.B
        if (step_i == 4'd0) ins = LDX(2'd0, 1'b0, GBR, 6'd0, S0);
        if (step_i == 4'd1) ins = MOVI({8'h0, imm8}, S1);
        if (step_i == 4'd2) ins = XOR(S0, S1, S0);
        if (step_i == 4'd3) ins = STX(2'd0, GBR, 6'd0, S0);
      end
      8'd160: begin  // OR.B
        if (step_i == 4'd0) ins = LDX(2'd0, 1'b0, GBR, 6'd0, S0);
        if (step_i == 4'd1) ins = ORI(S0, {2'b0, imm8}, S0);
        if (step_i == 4'd2) ins = STX(2'd0, GBR, 6'd0, S0);
      end
      8'd161: begin  // ---------------- 1110: MOV #imm, Rn ----------------
        if (step_i == 4'd0) ins = PS(PS_MOVI32, Z, Z, S0);
        if (step_i == 4'd0) imm = {pc4[31:2], 2'b00} + (u8 << 2);
        if (step_i == 4'd1) ins = LD(2'd2, 1'b1, S0, 10'd0, rn);
      end
      8'd162: begin  // ---------------- 1111: floating point ----------------
        if (step_i == 4'd0) ins = MOVI(s8[15:0], rn);
      end
      8'd163: begin  // FADD
        if (step_i == 4'd0) ins = sr_pr_i ? FPU13(4'd1, fr(m4), fr(n4), fr(n4)) : FPU13(4'd0, fr(m4), fr(n4), fr(n4));
      end
      8'd164: begin  // FSUB
        if (step_i == 4'd0) ins = sr_pr_i ? FPU13(4'd3, fr(n4), fr(m4), fr(n4)) : FPU13(4'd2, fr(n4), fr(m4), fr(n4));
      end
      8'd165: begin  // FMUL
        if (step_i == 4'd0) ins = sr_pr_i ? FPU13(4'd7, fr(m4), fr(n4), fr(n4)) : FPU13(4'd6, fr(m4), fr(n4), fr(n4));
      end
      8'd166: begin  // FDIV
        if (step_i == 4'd0) ins = sr_pr_i ? FPU13(4'd5, fr(n4), fr(m4), fr(n4)) : FPU13(4'd4, fr(n4), fr(m4), fr(n4));
      end
      8'd167: begin  // FCMP/EQ
        if (step_i == 4'd0) ins = sr_pr_i ? FCMP(4'd9, fr(n4), fr(m4), T) : FCMP(4'd8, fr(n4), fr(m4), T);
      end
      8'd168: begin  // FCMP/GT
        if (step_i == 4'd0) ins = sr_pr_i ? FCMP(4'd13, fr(n4), fr(m4), T) : FCMP(4'd12, fr(n4), fr(m4), T);
      end
      8'd169: begin  // FMOV @(R0, Rm), FRn / DRn / XDn
        if (step_i == 4'd0) ins = sr_sz_i ? FLDXP(rm, 6'd0, dx(n4)) : FLDXS(rm, 6'd0, fr(n4));
      end
      8'd170: begin  // FMOV FRm, @(R0, Rn)
        if (step_i == 4'd0) ins = sr_sz_i ? FSTXP(rn, 6'd0, dx(m4)) : FSTXS(rn, 6'd0, fr(m4));
      end
      8'd171: begin  // FMOV @Rm, FRn
        if (step_i == 4'd0) ins = sr_sz_i ? FLDP(rm, 10'd0, dx(n4)) : FLDS(rm, 10'd0, fr(n4));
      end
      8'd172: begin  // FMOV @Rm+, FRn
        if (step_i == 4'd0) ins = sr_sz_i ? FLDP(rm, 10'd0, dx(n4)) : FLDS(rm, 10'd0, fr(n4));
        if (step_i == 4'd1) ins = ADDIL(rm, sr_sz_i ? 10'd8 : 10'd4, rm);
      end
      8'd173: begin  // FMOV FRm, @Rn
        if (step_i == 4'd0) ins = sr_sz_i ? FSTP(rn, 10'd0, dx(m4)) : FSTS(rn, 10'd0, fr(m4));
      end
      8'd174: begin  // FMOV FRm, @-Rn
        if (step_i == 4'd0) ins = ADDI(rn, sr_sz_i ? 10'h3f8 : 10'h3fc, S0);
        if (step_i == 4'd1) ins = sr_sz_i ? FSTP(S0, 10'd0, dx(m4)) : FSTS(S0, 10'd0, fr(m4));
        if (step_i == 4'd2) ins = ADDL(S0, Z, rn);
      end
      8'd175: begin  // FMOV FRm, FRn (SZ = 0) / DR, XD pairs (SZ = 1)
        if (step_i == 4'd0) ins = sr_sz_i ? FMOVD(dx(m4), dx(n4)) : FMOVS(fr(m4), fr(n4));
      end
      8'd176: begin  // FSTS FPUL, FRn
        if (step_i == 4'd0) ins = FMOVS(FPUL, fr(n4));
      end
      8'd177: begin  // FLDS FRm, FPUL
        if (step_i == 4'd0) ins = FMOVS(fr(n4), FPUL);
      end
      8'd178: begin  // FLOAT FPUL, FRn/DRn
        if (step_i == 4'd0) ins = sr_pr_i ? FPU14(4'd14, FPUL, fr(n4)) : FPU14(4'd12, FPUL, fr(n4));
      end
      8'd179: begin  // FTRC FRm/DRm, FPUL
        if (step_i == 4'd0) ins = sr_pr_i ? FPU14(4'd11, fr(n4), FPUL) : FPU14(4'd8, fr(n4), FPUL);
      end
      8'd180: begin  // FNEG
        if (step_i == 4'd0) ins = sr_pr_i ? FPU6(4'd3, fr(n4), fr(n4)) : FPU6(4'd2, fr(n4), fr(n4));
      end
      8'd181: begin  // FABS
        if (step_i == 4'd0) ins = sr_pr_i ? FPU6(4'd1, fr(n4), fr(n4)) : FPU6(4'd0, fr(n4), fr(n4));
      end
      8'd182: begin  // FSQRT
        if (step_i == 4'd0) ins = sr_pr_i ? FPU14(4'd5, fr(n4), fr(n4)) : FPU14(4'd4, fr(n4), fr(n4));
      end
      8'd183: begin  // FSRRA
        if (step_i == 4'd0) ins = FPU6(4'd10, fr(n4), fr(n4));
      end
      8'd184: begin  // FLDI0
        if (step_i == 4'd0) ins = FMOVLS(Z, fr(n4));
      end
      8'd185: begin  // FLDI1
        if (step_i == 4'd0) ins = PS(PS_MOVI32, Z, Z, S0);
        if (step_i == 4'd0) imm = 32'h3f80_0000;
        if (step_i == 4'd1) ins = FMOVLS(S0, fr(n4));
      end
      8'd186: begin  // FCNVSD FPUL, DRn (1111 nnn0 1010 1101)
        if (step_i == 4'd0) ins = FPU14(4'd6, FPUL, fr(n4));
      end
      8'd187: begin  // FCNVDS DRm, FPUL (1111 mmm0 1011 1101)
        if (step_i == 4'd0) ins = FPU14(4'd7, fr(n4), FPUL);
      end
      8'd188: begin  // FRCHG
        if (step_i == 4'd0) ins = MOVI(sr_fr_i ? 16'h0000 : 16'h4000, S0);
        if (step_i == 4'd1) ins = PS(PS_SRFLAG, S0, Z, Z);
        if (step_i == 4'd1) imm = M_FR;
      end
      8'd189: begin  // FSCHG
        if (step_i == 4'd0) ins = MOVI(sr_sz_i ? 16'h0000 : 16'h2000, S0);
        if (step_i == 4'd1) ins = PS(PS_SRFLAG, S0, Z, Z);
        if (step_i == 4'd1) imm = M_SZ;
      end
      8'd190: begin  // FTRV XMTRX, FVn
        if (step_i == 4'd0) ins = FTRV(xf(4'd0), fr({n4[3:2], 2'b00}), fr({n4[3:2], 2'b00}));
      end
      8'd191: begin  // FSCA FPUL, DRn
        if (step_i == 4'd0) ins = FPU6(4'd8, FPUL, fr({n4[3:1], 1'b0}));
        if (step_i == 4'd1) ins = FPU6(4'd12, FPUL, fr({n4[3:1], 1'b1}));
      end
      8'd192: begin  // FIPR FVm, FVn
        if (step_i == 4'd0) ins = FIPR(fr({insn_i[9:8], 2'b00}), fr({n4[3:2], 2'b00}), fr({n4[3:2], 2'b11}));
      end
      8'd193: begin  // FMAC FR0, FRm, FRn
        if (step_i == 4'd0) ins = FPU13(4'd14, fr(4'd0), fr(m4), fr(n4));
      end
      default: ;
    endcase

    if (resinst) begin
      n = 5'd1; ins = PS(PS_EXC, Z, Z, Z); imm = {20'h0, EVT_RESINST}; dbr = 1'b0;
    end

    // delay slot rules (Vol. 3 1.6)
    dbranch_o = dbr && !in_slot_i;
    if (in_slot_i && (illslot || dbr)) begin
      insn_o = PS(PS_EXC, Z, Z, Z); imm32_o = {20'h0, EVT_ILLSLOT}; last_o = 1'b1;
    end else if (in_slot_i && isfpu && sr_fd_i) begin
      insn_o = PS(PS_EXC, Z, Z, Z); imm32_o = {20'h0, EVT_SLOTFPUDIS}; last_o = 1'b1;
    end else if (in_slot_i && step_i == n[3:0]) begin
      insn_o = BLINK(TR0, Z); imm32_o = 32'h0; last_o = 1'b1;    // the pending branch
    end else begin
      insn_o = ins; imm32_o = imm;
      last_o = in_slot_i ? 1'b0 : (step_i == n[3:0] - 4'd1);
    end
  end

endmodule
