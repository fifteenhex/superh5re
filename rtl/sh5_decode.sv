// SHmedia instruction decoder (Vol. 1 ch. 4, Vol. 2 App. A).

module sh5_decode
  import sh5_pkg::*;
  import sh5_uop_pkg::*;
(
  input  logic [31:0] insn_i,
  input  logic [31:0] pc_i,
  input  logic        priv_i,       // SR.MD
  input  logic        fpu_dis_i,    // SR.FD or no FPU
  input  logic        isa_compact_i,// ISA bit is 0: SHcompact not implemented
  input  logic [11:0] fetch_fault_i,// ITLBMISS / EXECPROT from the fetch, 0 = none
  output uop_t        uop_o
);

  logic [5:0]  op, m, n, d;
  logic [3:0]  ext;
  logic [63:0] s6, s10, s16, u6, u16;
  uop_t u;

  assign op  = insn_op(insn_i);
  assign m   = insn_m(insn_i);
  assign ext = insn_ext(insn_i);
  assign n   = insn_n(insn_i);
  assign d   = insn_d(insn_i);
  assign s6  = {{58{insn_i[15]}}, insn_i[15:10]};
  assign u6  = {58'b0, insn_i[15:10]};
  assign s10 = {{54{insn_i[19]}}, insn_i[19:10]};
  assign s16 = {{48{insn_i[25]}}, insn_i[25:10]};
  assign u16 = {48'b0, insn_i[25:10]};

  // Helpers
  function automatic uop_t set_exc(input uop_t x, input logic [11:0] code);
    uop_t r = x;
    r.cls = UC_EXC;
    r.exc = code;
    r.wr_gpr = 1'b0; r.wr_tr = 1'b0; r.wr_fr = 1'b0;
    r.rd_fa = 1'b0; r.rd_fb = 1'b0; r.rd_fc = 1'b0; r.rd_tr = 1'b0;
    r.serialize = 1'b1;
    return r;
  endfunction

  always_comb begin
    logic resinst;
    logic fpu_insn;

    u = '0;
    u.valid = 1'b1;
    u.pc    = pc_i;
    u.insn  = insn_i;
    u.cls   = UC_NOP;
    u.alu   = A_ADD;
    u.ra = m; u.rb = n; u.rc = d; u.rd = d;
    u.tra = insn_tra(insn_i);
    u.trb = insn_trb(insn_i);
    u.likely = insn_l(insn_i);
    u.fa = m; u.fb = n; u.fc = d; u.fd = d;
    u.fa_w = 2'd0; u.fb_w = 2'd0; u.fc_w = 2'd0;
    u.imm = '0;
    resinst = 1'b0;
    fpu_insn = is_fpu_opcode(op);

    case (op)
      // ---------------- ALU ----------------
      OP_ALU0: begin
        u.cls = UC_ALU; u.wr_gpr = 1'b1;
        case (ext)
          4'd1:  u.alu = A_CMPEQ;
          4'd3:  u.alu = A_CMPGT;
          4'd7:  u.alu = A_CMPGTU;
          4'd8:  u.alu = A_ADDL;
          4'd9:  u.alu = A_ADD;
          4'd10: u.alu = A_SUBL;
          4'd11: u.alu = A_SUB;
          4'd12: u.alu = A_ADDZL;
          4'd13: u.alu = A_NSB;
          4'd14: begin u.cls = UC_MM; u.long_lat = 1'b1; end   // MULU.L
          4'd15: u.alu = A_BYTEREV;
          default: resinst = 1'b1;
        endcase
      end
      OP_ALU1: begin
        u.cls = UC_ALU; u.wr_gpr = 1'b1;
        case (ext)
          4'd0:  u.alu = A_SHLLDL;
          4'd1:  u.alu = A_SHLLD;
          4'd2:  u.alu = A_SHLRDL;
          4'd3:  u.alu = A_SHLRD;
          4'd6:  u.alu = A_SHARDL;
          4'd7:  u.alu = A_SHARD;
          4'd9:  u.alu = A_OR;
          4'd11: u.alu = A_AND;
          4'd13: u.alu = A_XOR;
          4'd14: begin u.cls = UC_MM; u.long_lat = 1'b1; end   // MULS.L
          4'd15: u.alu = A_ANDC;
          default: resinst = 1'b1;
        endcase
      end
      OP_ALU49: begin  // immediate shifts, XORI
        u.cls = UC_ALU; u.wr_gpr = 1'b1; u.use_imm = 1'b1; u.imm = u6;
        case (ext)
          4'd0:  u.alu = A_SHLLDL;
          4'd1:  u.alu = A_SHLLD;
          4'd2:  u.alu = A_SHLRDL;
          4'd3:  u.alu = A_SHLRD;
          4'd6:  u.alu = A_SHARDL;
          4'd7:  u.alu = A_SHARD;
          4'd13: begin u.alu = A_XOR; u.imm = s6; end
          default: resinst = 1'b1;
        endcase
      end
      OP_MOVI:  begin u.cls = UC_ALU; u.wr_gpr = 1'b1; u.alu = A_MOVI;  u.use_imm = 1'b1; u.imm = s16; u.ra = 6'd63; end
      OP_SHORI: begin u.cls = UC_ALU; u.wr_gpr = 1'b1; u.alu = A_SHORI; u.use_imm = 1'b1; u.imm = u16; u.ra = d; end
      OP_ADDI:  begin u.cls = UC_ALU; u.wr_gpr = 1'b1; u.alu = A_ADD;   u.use_imm = 1'b1; u.imm = s10; end
      OP_ADDIL: begin u.cls = UC_ALU; u.wr_gpr = 1'b1; u.alu = A_ADDL;  u.use_imm = 1'b1; u.imm = s10; end
      OP_ANDI:  begin u.cls = UC_ALU; u.wr_gpr = 1'b1; u.alu = A_AND;   u.use_imm = 1'b1; u.imm = s10; end
      OP_ORI:   begin u.cls = UC_ALU; u.wr_gpr = 1'b1; u.alu = A_OR;    u.use_imm = 1'b1; u.imm = s10; end

      // ---------------- RMW, GETCON ----------------
      OP_RMW8: begin
        case (ext)
          4'd1: begin u.cls = UC_ALU; u.alu = A_CMVEQ; u.wr_gpr = 1'b1; end
          4'd5: begin u.cls = UC_ALU; u.alu = A_CMVNE; u.wr_gpr = 1'b1; end
          4'd3: begin u.cls = UC_SWAP; u.wr_gpr = 1'b1; u.long_lat = 1'b1; u.msize = 2'd3; end
          default: resinst = 1'b1;
        endcase
      end
      OP_MISC9: begin
        if (ext == 4'd15) begin
          u.cls = UC_GETCON; u.wr_gpr = 1'b1; u.alu = A_PASS_B;
          if (m < 6'd32 && !priv_i) resinst = 1'b1;
        end else resinst = 1'b1;
      end

      // ---------------- multimedia ----------------
      OP_MM2, OP_MM3, OP_MM10, OP_MM11, OP_MM18, OP_MM19: begin
        if (ext_is_defined(op, ext)) begin
          u.cls = UC_MM; u.wr_gpr = 1'b1; u.long_lat = 1'b1;
        end else resinst = 1'b1;
      end

      // ---------------- loads and stores ----------------
      OP_LDB, OP_LDW, OP_LDL, OP_LDQ, OP_LDUB, OP_LDUW: begin
        u.cls = (d == 6'd63) ? UC_NOP : UC_LOAD;   // destination R63: prefetch
        u.wr_gpr = (d != 6'd63); u.long_lat = 1'b1; u.use_imm = 1'b1;
        u.mkind = M_NORMAL;
        case (op)
          OP_LDB:  begin u.msize = 2'd0; u.msigned = 1'b1; u.imm = s10; end
          OP_LDUB: begin u.msize = 2'd0; u.msigned = 1'b0; u.imm = s10; end
          OP_LDW:  begin u.msize = 2'd1; u.msigned = 1'b1; u.imm = s10 << 1; end
          OP_LDUW: begin u.msize = 2'd1; u.msigned = 1'b0; u.imm = s10 << 1; end
          OP_LDL:  begin u.msize = 2'd2; u.msigned = 1'b1; u.imm = s10 << 2; end
          default: begin u.msize = 2'd3; u.msigned = 1'b0; u.imm = s10 << 3; end
        endcase
      end
      OP_STB, OP_STW, OP_STL, OP_STQ: begin
        u.cls = UC_STORE; u.use_imm = 1'b1; u.mkind = M_NORMAL;
        case (op)
          OP_STB:  begin u.msize = 2'd0; u.imm = s10; end
          OP_STW:  begin u.msize = 2'd1; u.imm = s10 << 1; end
          OP_STL:  begin u.msize = 2'd2; u.imm = s10 << 2; end
          default: begin u.msize = 2'd3; u.imm = s10 << 3; end
        endcase
      end
      OP_LOAD16: begin  // LDX
        u.cls = (d == 6'd63) ? UC_NOP : UC_LOAD;
        u.wr_gpr = (d != 6'd63); u.long_lat = 1'b1; u.mkind = M_NORMAL;
        case (ext)
          4'd0: begin u.msize = 2'd0; u.msigned = 1'b1; end
          4'd1: begin u.msize = 2'd1; u.msigned = 1'b1; end
          4'd2: begin u.msize = 2'd2; u.msigned = 1'b1; end
          4'd3: begin u.msize = 2'd3; u.msigned = 1'b0; end
          4'd4: begin u.msize = 2'd0; u.msigned = 1'b0; end
          4'd5: begin u.msize = 2'd1; u.msigned = 1'b0; end
          default: resinst = 1'b1;
        endcase
      end
      OP_STORE24: begin  // STX
        u.cls = UC_STORE; u.mkind = M_NORMAL;
        case (ext)
          4'd0: u.msize = 2'd0;
          4'd1: u.msize = 2'd1;
          4'd2: u.msize = 2'd2;
          4'd3: u.msize = 2'd3;
          default: resinst = 1'b1;
        endcase
      end
      OP_LOAD48: begin  // LDLO, LDHI, GETCFG
        u.use_imm = 1'b1; u.imm = s6;
        case (ext)
          4'd2: begin u.cls = UC_LOAD; u.wr_gpr = 1'b1; u.long_lat = 1'b1; u.mkind = M_LO; u.msize = 2'd2; u.msigned = 1'b0; end
          4'd3: begin u.cls = UC_LOAD; u.wr_gpr = 1'b1; u.long_lat = 1'b1; u.mkind = M_LO; u.msize = 2'd3; u.msigned = 1'b0; end
          4'd6: begin u.cls = UC_LOAD; u.wr_gpr = 1'b1; u.long_lat = 1'b1; u.mkind = M_HI; u.msize = 2'd2; u.msigned = 1'b1; end
          4'd7: begin u.cls = UC_LOAD; u.wr_gpr = 1'b1; u.long_lat = 1'b1; u.mkind = M_HI; u.msize = 2'd3; u.msigned = 1'b0; end
          4'd15: begin
            u.cls = UC_GETCFG; u.wr_gpr = 1'b1; u.alu = A_PASS_B;
            if (!priv_i) resinst = 1'b1;
          end
          default: resinst = 1'b1;
        endcase
      end
      OP_STORE56: begin  // cache ops, STLO, STHI, PUTCFG
        u.use_imm = 1'b1; u.imm = s6;
        case (ext)
          4'd1:  begin u.cls = UC_CACHEOP; u.cop = COP_PREFI;  u.imm = s6 << 5; end
          4'd4:  begin u.cls = UC_CACHEOP; u.cop = COP_ALLOCO; u.imm = s6 << 5; end
          4'd5:  begin u.cls = UC_CACHEOP; u.cop = COP_ICBI;   u.imm = s6 << 5; end
          4'd8:  begin u.cls = UC_CACHEOP; u.cop = COP_OCBP;   u.imm = s6 << 5; end
          4'd9:  begin u.cls = UC_CACHEOP; u.cop = COP_OCBI;   u.imm = s6 << 5; end
          4'd12: begin u.cls = UC_CACHEOP; u.cop = COP_OCBWB;  u.imm = s6 << 5; end
          4'd2: begin u.cls = UC_STORE; u.mkind = M_LO; u.msize = 2'd2; end
          4'd3: begin u.cls = UC_STORE; u.mkind = M_LO; u.msize = 2'd3; end
          4'd6: begin u.cls = UC_STORE; u.mkind = M_HI; u.msize = 2'd2; end
          4'd7: begin u.cls = UC_STORE; u.mkind = M_HI; u.msize = 2'd3; end
          4'd15: begin
            u.cls = UC_PUTCFG; u.serialize = 1'b1;
            if (!priv_i) resinst = 1'b1;
          end
          default: resinst = 1'b1;
        endcase
      end

      // ---------------- branches and targets ----------------
      OP_BRANCH25: begin
        u.cls = UC_BRANCH; u.rd_tr = 1'b1; u.trb = insn_tra(insn_i);
        case (ext)
          4'd1:  u.bcond = BC_EQ;
          4'd3:  u.bcond = BC_GE;
          4'd5:  u.bcond = BC_NE;
          4'd7:  u.bcond = BC_GT;
          4'd11: u.bcond = BC_GEU;
          4'd15: u.bcond = BC_GTU;
          default: resinst = 1'b1;
        endcase
      end
      OP_BRANCH57: begin
        u.cls = UC_BRANCH; u.rd_tr = 1'b1; u.trb = insn_tra(insn_i);
        u.use_imm = 1'b1; u.imm = s6;
        case (ext)
          4'd1: u.bcond = BC_EQ;
          4'd5: u.bcond = BC_NE;
          default: resinst = 1'b1;
        endcase
      end
      OP_BRANCH17: begin
        case (ext)
          4'd1: begin u.cls = UC_BLINK; u.rd_tr = 1'b1; u.wr_gpr = 1'b1; end
          4'd5: begin u.cls = UC_GETTR; u.rd_tr = 1'b1; u.wr_gpr = 1'b1; u.alu = A_PASS_B; end
          default: resinst = 1'b1;
        endcase
      end
      OP_PT26: begin
        // PTABS Rn, TRa (target = Rn); PTREL Rn, TRa (target = PC + Rn)
        u.cls = UC_PT; u.wr_tr = 1'b1; u.ra = n;
        case (ext)
          4'd1: u.imm = '0;
          4'd5: u.imm = {{32{pc_i[31]}}, pc_i};
          default: resinst = 1'b1;
        endcase
      end
      OP_PTA: begin u.cls = UC_PT; u.wr_tr = 1'b1; u.ra = 6'd63; u.imm = {{32{pc_i[31]}}, pc_i} + (s16 << 2) + 64'd1; end
      OP_PTB: begin u.cls = UC_PT; u.wr_tr = 1'b1; u.ra = 6'd63; u.imm = {{32{pc_i[31]}}, pc_i} + (s16 << 2); end

      // ---------------- system ----------------
      OP_MISC27: begin
        case (ext)
          4'd0: u.cls = UC_NOP;
          4'd1: begin u.cls = UC_EXC; u.exc = EVT_TRAP; u.serialize = 1'b1; end  // TRAPA Rm: TRA = Rm (read in E1)
          4'd2: begin u.cls = UC_SYNCI; u.serialize = 1'b1; end
          4'd3: begin u.cls = UC_RTE; u.serialize = 1'b1; if (!priv_i) resinst = 1'b1; end
          4'd5: begin u.cls = UC_EXC; u.exc = EVT_BREAK; u.serialize = 1'b1; end
          4'd6: begin u.cls = UC_SYNCO; u.serialize = 1'b1; end
          4'd7: begin u.cls = UC_SLEEP; u.serialize = 1'b1; if (!priv_i) resinst = 1'b1; end
          4'd15: begin
            u.cls = UC_PUTCON; u.serialize = 1'b1; u.rc = m;   // PUTCON Rm, Cj: j = d
            if (d < 6'd32 && !priv_i) resinst = 1'b1;
          end
          default: resinst = 1'b1;
        endcase
      end

      // ---------------- floating point ----------------
      OP_FPU5: begin  // FIPR.S, FTRV.S
        u.cls = UC_FPU; u.wr_fr = 1'b1;
        case (ext)
          4'd6:  begin u.rd_fa = 1'b1; u.fa_w = 2'd2; u.rd_fb = 1'b1; u.fb_w = 2'd2; u.fw = FW_32; end
          4'd14: begin u.rd_fa = 1'b1; u.fa_w = 2'd3; u.rd_fb = 1'b1; u.fb_w = 2'd2; u.fw = FW_128; end
          default: resinst = 1'b1;
        endcase
      end
      OP_FPU6: begin  // FABS, FNEG, FSINA, FSRRA, FCOSA
        u.rd_fa = 1'b1;
        case (ext)
          4'd0:  begin u.cls = UC_FMOV; u.fmov = FM_ABSS; u.wr_fr = 1'b1; u.fw = FW_32; end
          4'd1:  begin u.cls = UC_FMOV; u.fmov = FM_ABSD; u.wr_fr = 1'b1; u.fw = FW_64; u.fa_w = 2'd1; end
          4'd2:  begin u.cls = UC_FMOV; u.fmov = FM_NEGS; u.wr_fr = 1'b1; u.fw = FW_32; end
          4'd3:  begin u.cls = UC_FMOV; u.fmov = FM_NEGD; u.wr_fr = 1'b1; u.fw = FW_64; u.fa_w = 2'd1; end
          4'd8, 4'd10, 4'd12: begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_32; end
          default: resinst = 1'b1;
        endcase
      end
      OP_FLOAD7: begin  // FMOV.LS, FMOV.QD, FGETSCR, FLDX
        case (ext)
          4'd0:  begin u.cls = UC_FMOV; u.fmov = FM_LS; u.wr_fr = 1'b1; u.fw = FW_32; end
          4'd1:  begin u.cls = UC_FMOV; u.fmov = FM_QD; u.wr_fr = 1'b1; u.fw = FW_64; end
          4'd2:  begin u.cls = UC_FMOV; u.fmov = FM_GETSCR; u.wr_fr = 1'b1; u.fw = FW_32; u.serialize = 1'b1; end
          4'd8:  begin u.cls = UC_FLOAD; u.wr_fr = 1'b1; u.fw = FW_32;   u.mkind = M_FP_S; u.msize = 2'd2; u.long_lat = 1'b1; end
          4'd9:  begin u.cls = UC_FLOAD; u.wr_fr = 1'b1; u.fw = FW_64;   u.mkind = M_FP_D; u.msize = 2'd3; u.long_lat = 1'b1; end
          4'd13: begin u.cls = UC_FLOAD; u.wr_fr = 1'b1; u.fw = FW_PAIR; u.mkind = M_FP_P; u.msize = 2'd3; u.long_lat = 1'b1; end
          default: resinst = 1'b1;
        endcase
      end
      OP_FPU12: begin  // FMOV.SL, FMOV.DQ, FPUTSCR, FCMP*
        case (ext)
          4'd0: begin u.cls = UC_FMOV; u.fmov = FM_SL; u.wr_gpr = 1'b1; u.rd_fa = 1'b1; end
          4'd1: begin u.cls = UC_FMOV; u.fmov = FM_DQ; u.wr_gpr = 1'b1; u.rd_fa = 1'b1; u.fa_w = 2'd1; end
          4'd2: begin u.cls = UC_FPUTSCR; u.rd_fa = 1'b1; u.serialize = 1'b1; end
          4'd8, 4'd10, 4'd12, 4'd14: begin u.cls = UC_FPU; u.fpu_wr_gpr = 1'b1; u.rd_fa = 1'b1; u.rd_fb = 1'b1; end
          4'd9, 4'd11, 4'd13, 4'd15: begin u.cls = UC_FPU; u.fpu_wr_gpr = 1'b1; u.rd_fa = 1'b1; u.rd_fb = 1'b1; u.fa_w = 2'd1; u.fb_w = 2'd1; end
          default: resinst = 1'b1;
        endcase
      end
      OP_FPU13: begin  // FADD FSUB FDIV FMUL (S/D), FMAC.S
        u.cls = UC_FPU; u.wr_fr = 1'b1; u.rd_fa = 1'b1; u.rd_fb = 1'b1;
        case (ext)
          4'd0, 4'd2, 4'd4, 4'd6: u.fw = FW_32;
          4'd1, 4'd3, 4'd5, 4'd7: begin u.fw = FW_64; u.fa_w = 2'd1; u.fb_w = 2'd1; end
          4'd14: begin u.fw = FW_32; u.rd_fc = 1'b1; end
          default: resinst = 1'b1;
        endcase
      end
      OP_FPU14: begin  // FMOV.S/D, FSQRT, FCNV, FTRC, FLOAT
        u.rd_fa = 1'b1;
        case (ext)
          4'd0:  begin u.cls = UC_FMOV; u.fmov = FM_S; u.wr_fr = 1'b1; u.fw = FW_32; end
          4'd1:  begin u.cls = UC_FMOV; u.fmov = FM_D; u.wr_fr = 1'b1; u.fw = FW_64; u.fa_w = 2'd1; end
          4'd4:  begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_32; end                  // FSQRT.S
          4'd5:  begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_64; u.fa_w = 2'd1; end   // FSQRT.D
          4'd6:  begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_64; end                  // FCNV.SD
          4'd7:  begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_32; u.fa_w = 2'd1; end   // FCNV.DS
          4'd8:  begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_32; end                  // FTRC.SL
          4'd9:  begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_64; u.fa_w = 2'd1; end   // FTRC.DQ
          4'd10: begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_64; end                  // FTRC.SQ
          4'd11: begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_32; u.fa_w = 2'd1; end   // FTRC.DL
          4'd12: begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_32; end                  // FLOAT.LS
          4'd13: begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_64; u.fa_w = 2'd1; end   // FLOAT.QD
          4'd14: begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_64; end                  // FLOAT.LD
          4'd15: begin u.cls = UC_FPU; u.wr_fr = 1'b1; u.fw = FW_32; u.fa_w = 2'd1; end   // FLOAT.QS
          default: resinst = 1'b1;
        endcase
      end
      OP_FSTORE15: begin  // FSTX
        u.cls = UC_FSTORE; u.rd_fc = 1'b1;
        case (ext)
          4'd8:  begin u.mkind = M_FP_S; u.msize = 2'd2; end
          4'd9:  begin u.mkind = M_FP_D; u.msize = 2'd3; u.fc_w = 2'd1; end
          4'd13: begin u.mkind = M_FP_P; u.msize = 2'd3; u.fc_w = 2'd1; end
          default: resinst = 1'b1;
        endcase
      end
      OP_FLDS: begin u.cls = UC_FLOAD; u.wr_fr = 1'b1; u.fw = FW_32;   u.mkind = M_FP_S; u.msize = 2'd2; u.long_lat = 1'b1; u.use_imm = 1'b1; u.imm = s10 << 2; end
      OP_FLDD: begin u.cls = UC_FLOAD; u.wr_fr = 1'b1; u.fw = FW_64;   u.mkind = M_FP_D; u.msize = 2'd3; u.long_lat = 1'b1; u.use_imm = 1'b1; u.imm = s10 << 3; end
      OP_FLDP: begin u.cls = UC_FLOAD; u.wr_fr = 1'b1; u.fw = FW_PAIR; u.mkind = M_FP_P; u.msize = 2'd3; u.long_lat = 1'b1; u.use_imm = 1'b1; u.imm = s10 << 3; end
      OP_FSTS: begin u.cls = UC_FSTORE; u.rd_fc = 1'b1; u.mkind = M_FP_S; u.msize = 2'd2; u.use_imm = 1'b1; u.imm = s10 << 2; end
      OP_FSTD: begin u.cls = UC_FSTORE; u.rd_fc = 1'b1; u.fc_w = 2'd1; u.mkind = M_FP_D; u.msize = 2'd3; u.use_imm = 1'b1; u.imm = s10 << 3; end
      OP_FSTP: begin u.cls = UC_FSTORE; u.rd_fc = 1'b1; u.fc_w = 2'd1; u.mkind = M_FP_P; u.msize = 2'd3; u.use_imm = 1'b1; u.imm = s10 << 3; end

      default: resinst = 1'b1;   // reserved opcodes, FPU-reserved group
    endcase

    // Exception precedence at decode (Vol. 2 A.3, A.6; Vol. 1 Table 157)
    if (fetch_fault_i != 12'h0) begin
      u = set_exc(u, fetch_fault_i);
      u.tea_valid = 1'b1;
      u.fetch_fault = 1'b1;
    end else if (isa_compact_i) begin
      u = set_exc(u, EVT_RESINST);
    end else if (insn_r(insn_i) != 4'b0000) begin
      u = set_exc(u, EVT_RESINST);
    end else if (fpu_insn && fpu_dis_i) begin
      u = set_exc(u, EVT_FPUDIS);
    end else if (resinst) begin
      u = set_exc(u, EVT_RESINST);
    end

    uop_o = u;
  end

endmodule
