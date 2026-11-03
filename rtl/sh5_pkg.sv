// SH-5 architectural constants.
// Sources: SH-5 CPU Core Vol. 1 (Architecture), Vol. 2 (SHmedia),
// Vol. 4 (Implementation). Section numbers are given per item.

package sh5_pkg;

  // ---------------------------------------------------------------------
  // Address space (Vol. 4 Tables 2, 30)
  localparam int NEFF  = 32;
  localparam int NPHYS = 32;

  // ---------------------------------------------------------------------
  // Control register numbers (Vol. 4 6.2)
  localparam logic [5:0] CR_SR      = 6'h00;
  localparam logic [5:0] CR_SSR     = 6'h01;
  localparam logic [5:0] CR_PSSR    = 6'h02;
  localparam logic [5:0] CR_INTEVT  = 6'h04;
  localparam logic [5:0] CR_EXPEVT  = 6'h05;
  localparam logic [5:0] CR_PEXPEVT = 6'h06;
  localparam logic [5:0] CR_TRA     = 6'h07;
  localparam logic [5:0] CR_SPC     = 6'h08;
  localparam logic [5:0] CR_PSPC    = 6'h09;
  localparam logic [5:0] CR_RESVEC  = 6'h0a;
  localparam logic [5:0] CR_VBR     = 6'h0b;
  localparam logic [5:0] CR_TEA     = 6'h0d;
  localparam logic [5:0] CR_DCR     = 6'h10;
  localparam logic [5:0] CR_KCR0    = 6'h11;
  localparam logic [5:0] CR_KCR1    = 6'h12;
  localparam logic [5:0] CR_CTC     = 6'h3e;
  localparam logic [5:0] CR_USR     = 6'h3f;
  // 0x20..0x3d RESERVED (read 0, write ignored); 0x03, 0x0c, 0x0e, 0x0f,
  // 0x13..0x1f UNDEFINED (implemented here as RESERVED).

  function automatic logic cr_is_defined(input logic [5:0] n);
    case (n)
      CR_SR, CR_SSR, CR_PSSR, CR_INTEVT, CR_EXPEVT, CR_PEXPEVT, CR_TRA,
      CR_SPC, CR_PSPC, CR_RESVEC, CR_VBR, CR_TEA, CR_DCR, CR_KCR0, CR_KCR1,
      CR_CTC, CR_USR: cr_is_defined = 1'b1;
      default:        cr_is_defined = 1'b0;
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // SR fields (Vol. 1 Fig. 4, Vol. 4 Table 9)
  localparam int SR_S     = 1;
  localparam int SR_IMASK = 4;   // [7:4]
  localparam int SR_Q     = 8;
  localparam int SR_M     = 9;
  localparam int SR_CD    = 11;
  localparam int SR_PR    = 12;
  localparam int SR_SZ    = 13;
  localparam int SR_FR    = 14;
  localparam int SR_FD    = 15;
  localparam int SR_ASID  = 16;  // [23:16]
  localparam int SR_WATCH = 26;
  localparam int SR_STEP  = 27;
  localparam int SR_BL    = 28;
  localparam int SR_MD    = 30;
  localparam int SR_MMU   = 31;

  // Fields writable by PUTCON (Vol. 4 Table 9): S, IMASK, Q, M, CD, PR,
  // SZ, FR, FD. ASID, WATCH, STEP, MD, MMU change only by launch and RTE.
  localparam logic [31:0] SR_PUTCON_MASK = 32'h0000_fbf2;
  // Implemented bits of SR (everything else reads 0)
  localparam logic [31:0] SR_IMPL_MASK   = 32'hdcff_fbf2;
  // Power-on reset: MD=1, BL=1, FD=1, MMU=0, WATCH=STEP=0, CD=PR=SZ=FR=0
  localparam logic [31:0] SR_RESET       = 32'h5000_8000;

  // ---------------------------------------------------------------------
  // FPSCR (Vol. 4 Table 5)
  localparam int FPSCR_RM     = 0;
  localparam int FPSCR_FLAG   = 2;   // [6:2]   I U O Z V
  localparam int FPSCR_ENABLE = 7;   // [11:7]  I U O Z V
  localparam int FPSCR_CAUSE  = 12;  // [17:12] I U O Z V E
  localparam int FPSCR_DN     = 18;
  localparam logic [31:0] FPSCR_IMPL_MASK = 32'h0007_fffd;

  // ---------------------------------------------------------------------
  // Event codes (Vol. 1 Tables 156, 157)
  localparam logic [11:0] EVT_POWERON    = 12'h000;
  localparam logic [11:0] EVT_CPURESET   = 12'h020;
  localparam logic [11:0] EVT_RTLBMISS   = 12'h040;
  localparam logic [11:0] EVT_WTLBMISS   = 12'h060;
  localparam logic [11:0] EVT_READPROT   = 12'h0a0;
  localparam logic [11:0] EVT_WRITEPROT  = 12'h0c0;
  localparam logic [11:0] EVT_RADDERR    = 12'h0e0;
  localparam logic [11:0] EVT_WADDERR    = 12'h100;
  localparam logic [11:0] EVT_FPUEXC     = 12'h120;
  localparam logic [11:0] EVT_TRAP       = 12'h160;
  localparam logic [11:0] EVT_RESINST    = 12'h180;
  localparam logic [11:0] EVT_ILLSLOT    = 12'h1a0;
  localparam logic [11:0] EVT_NMI        = 12'h1c0;  // INTEVT
  localparam logic [11:0] EVT_FPUDIS     = 12'h800;
  localparam logic [11:0] EVT_SLOTFPUDIS = 12'h820;
  localparam logic [11:0] EVT_DEBUGIA    = 12'h900;
  localparam logic [11:0] EVT_DEBUGIV    = 12'h920;
  localparam logic [11:0] EVT_BREAK      = 12'h940;
  localparam logic [11:0] EVT_DEBUGOA    = 12'h960;
  localparam logic [11:0] EVT_DEBUGSS    = 12'h980;
  localparam logic [11:0] EVT_ITLBMISS   = 12'ha40;
  localparam logic [11:0] EVT_EXECPROT   = 12'haa0;
  localparam logic [11:0] EVT_IADDERR    = 12'hae0;

  // Handler offsets (Vol. 1 Table 151)
  localparam logic [11:0] VEC_RESET     = 12'h000;  // RESVEC/DBRVEC: CPU reset, panic
  localparam logic [11:0] VEC_EXCEPTION = 12'h100;  // VBR: non-debug, not TLB miss
  localparam logic [11:0] VEC_DEBUGEXC  = 12'h100;  // RESVEC/DBRVEC: debug exception
  localparam logic [11:0] VEC_DEBUGINT  = 12'h200;  // RESVEC/DBRVEC
  localparam logic [11:0] VEC_TLBMISS   = 12'h400;  // VBR
  localparam logic [11:0] VEC_INTERRUPT = 12'h600;  // VBR

  // Synchronous event priority (Vol. 1 Table 157): lower value wins.
  typedef enum logic [4:0] {
    ORD_NONE       = 5'd31,
    ORD_PANIC      = 5'd1,
    ORD_DEBUGIA    = 5'd2,
    ORD_ITLBMISS   = 5'd3,
    ORD_EXECPROT   = 5'd4,
    ORD_DEBUGIV    = 5'd5,
    ORD_FPUDIS     = 5'd6,   // also SLOTFPUDIS
    ORD_OPCODE     = 5'd7,   // BREAK, TRAP, RESINST, ILLSLOT
    ORD_IADDERR    = 5'd8,
    ORD_DEBUGOA    = 5'd9,
    ORD_ADDERR     = 5'd10,  // RADDERR, WADDERR
    ORD_DTLBMISS   = 5'd11,  // RTLBMISS, WTLBMISS
    ORD_READPROT   = 5'd12,
    ORD_WRITEPROT  = 5'd13,
    ORD_FPUEXC     = 5'd14,
    ORD_DEBUGSS    = 5'd15   // post-execution
  } evt_order_t;

  // Interrupt priority levels (Vol. 1 Table 155)
  localparam logic [4:0] IRQ_LEVEL_NMI      = 5'd17;
  localparam logic [4:0] IRQ_LEVEL_DEBUGINT = 5'd16;

  // ---------------------------------------------------------------------
  // PTE layout (Vol. 4 Tables 36, 37, 39, 40)
  localparam int PTEH_V    = 0;
  localparam int PTEH_SH   = 1;
  localparam int PTEH_ASID = 2;   // [9:2]
  localparam int PTEH_EPN  = 12;  // [31:12]
  localparam int PTEL_CB   = 0;   // [1:0]  CB0 reserved in the ITLB
  localparam int PTEL_SZ   = 3;   // [4:3]
  localparam int PTEL_PRR  = 6;   // reserved in the ITLB
  localparam int PTEL_PRX  = 7;   // reserved in the DTLB
  localparam int PTEL_PRW  = 8;   // reserved in the ITLB
  localparam int PTEL_PRU  = 9;
  localparam int PTEL_PPN  = 12;  // [31:12]
  localparam logic [31:0] PTEH_IMPL_MASK      = 32'hffff_f3ff;
  localparam logic [31:0] PTEL_IMPL_MASK_ITLB = 32'hffff_f29a;
  localparam logic [31:0] PTEL_IMPL_MASK_DTLB = 32'hffff_f35b;

  // Page sizes (Vol. 4 Table 31): number of offset bits per PTEL.SZ
  function automatic logic [5:0] page_shift(input logic [1:0] sz);
    case (sz)
      2'd0:    page_shift = 6'd12;  // 4 KB
      2'd1:    page_shift = 6'd16;  // 64 KB
      2'd2:    page_shift = 6'd20;  // 1 MB
      default: page_shift = 6'd29;  // 512 MB
    endcase
  endfunction

  // Cache behaviour (Vol. 1 Table 166), data side
  typedef enum logic [1:0] {
    CB_UNCACHED     = 2'd0,
    CB_DEVICE       = 2'd1,
    CB_WRITEBACK    = 2'd2,
    CB_WRITETHROUGH = 2'd3
  } cb_t;

  // ---------------------------------------------------------------------
  // Configuration space (Vol. 4 Tables 28, 29, 46)
  //   [31:24] region, [23:21] bank, [20:16] way, [15:4] index, [3:0] reg
  localparam logic [31:0] CFG_MMUIR      = 32'h0000_0000;  // + 16*n + {0,1}
  localparam logic [31:0] CFG_MMUDR      = 32'h0080_0000;
  localparam logic [31:0] CFG_ICACHETAG  = 32'h0100_0000;  // + 65536*way + 16*index
  localparam logic [31:0] CFG_ICACHEDATA = 32'h0120_0000;  // + 65536*way + 16*index + r
  localparam logic [31:0] CFG_ICCR       = 32'h0160_0000;  // + {0,1}
  localparam logic [31:0] CFG_OCACHETAG  = 32'h0180_0000;  // + 65536*way + 16*index + {0,1}
  localparam logic [31:0] CFG_OCACHEDATA = 32'h01a0_0000;
  localparam logic [31:0] CFG_OCCR       = 32'h01e0_0000;  // + {0,1}

  // ICCR0 / OCCR0 (Tables 47, 51)
  localparam int CCR0_ENABLE     = 0;  // ICE / OCE
  localparam int CCR0_INVALIDATE = 1;  // ICI / OCI (write 1, reads 0)
  localparam int OCCR0_OWT       = 2;
  // ICCR1 / OCCR1 (Tables 48, 52)
  localparam int CCR1_W_LOAD = 0;      // [1:0]
  localparam int CCR1_W_LE   = 7;
  localparam int CCR1_W_LOCK = 8;      // [11:8]

  // Cache geometry (Vol. 4 Table 41)
  localparam int CACHE_LINE_BYTES = 32;
  localparam int CACHE_WAYS       = 4;
  localparam int CACHE_SETS       = 256;
  localparam int CACHE_OFFSET_BITS = 5;   // [4:0]
  localparam int CACHE_INDEX_BITS  = 8;   // [12:5]
  localparam int CACHE_EATAG_BITS  = 19;  // [31:13]
  localparam int CACHE_PATAG_BITS  = 20;  // [31:12]

  // Tag register views (Tables 49, 53, 54)
  localparam int TAG_V      = 0;
  localparam int TAG_SH     = 1;
  localparam int TAG_ASID   = 2;   // [9:2]
  localparam int TAG_EADDR  = 13;  // [31:13]
  localparam int TAG_PRR    = 52;  // operand cache only
  localparam int TAG_PRW    = 54;  // operand cache only
  localparam int TAG_PRU    = 55;
  localparam int TAG_WT     = 56;  // operand cache only
  localparam int TAG_U      = 57;  // operand cache only
  localparam int TAG_LRU    = 58;  // [63:58]
  localparam int TAG1_PADDR = 12;  // OCACHETAG1 [31:12]

  // ---------------------------------------------------------------------
  // Instruction fields (Vol. 1 Table 17)
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [5:0] insn_op (input logic [31:0] i); insn_op  = i[31:26]; endfunction
  function automatic logic [5:0] insn_m  (input logic [31:0] i); insn_m   = i[25:20]; endfunction
  function automatic logic [3:0] insn_ext(input logic [31:0] i); insn_ext = i[19:16]; endfunction
  function automatic logic [5:0] insn_n  (input logic [31:0] i); insn_n   = i[15:10]; endfunction
  function automatic logic [5:0] insn_d  (input logic [31:0] i); insn_d   = i[9:4];   endfunction
  function automatic logic [3:0] insn_r  (input logic [31:0] i); insn_r   = i[3:0];   endfunction
  function automatic logic       insn_l  (input logic [31:0] i); insn_l   = i[9];     endfunction
  function automatic logic [2:0] insn_tra(input logic [31:0] i); insn_tra = i[6:4];   endfunction
  function automatic logic [2:0] insn_trb(input logic [31:0] i); insn_trb = i[22:20]; endfunction
  function automatic logic [5:0]  insn_s6 (input logic [31:0] i); insn_s6  = i[15:10]; endfunction
  function automatic logic [9:0]  insn_s10(input logic [31:0] i); insn_s10 = i[19:10]; endfunction
  function automatic logic [15:0] insn_s16(input logic [31:0] i); insn_s16 = i[25:10]; endfunction

  /* verilator lint_on UNUSEDSIGNAL */

  // Major opcodes (Vol. 2 Table 37)
  localparam logic [5:0] OP_ALU0    = 6'b000000;  // CMPEQ.. BYTEREV
  localparam logic [5:0] OP_ALU1    = 6'b000001;  // SHLLD.. ANDC
  localparam logic [5:0] OP_MM2     = 6'b000010;  // MADD/MSUB
  localparam logic [5:0] OP_MM3     = 6'b000011;  // MSH* shifts
  localparam logic [5:0] OP_FPURES4 = 6'b000100;  // FPU-reserved
  localparam logic [5:0] OP_FPU5    = 6'b000101;  // FIPR, FTRV
  localparam logic [5:0] OP_FPU6    = 6'b000110;  // FABS, FNEG, FSINA, FSRRA, FCOSA
  localparam logic [5:0] OP_FLOAD7  = 6'b000111;  // FMOV.LS/QD, FGETSCR, FLDX
  localparam logic [5:0] OP_RMW8    = 6'b001000;  // CMVEQ, CMVNE, SWAP.Q
  localparam logic [5:0] OP_MISC9   = 6'b001001;  // GETCON
  localparam logic [5:0] OP_MM10    = 6'b001010;  // MCMP*, MABS, MPERM, MEXTR1-3
  localparam logic [5:0] OP_MM11    = 6'b001011;  // MSHF*, MEXTR4-7
  localparam logic [5:0] OP_FPU12   = 6'b001100;  // FMOV.SL/DQ, FPUTSCR, FCMP*
  localparam logic [5:0] OP_FPU13   = 6'b001101;  // FADD, FSUB, FDIV, FMUL, FMAC
  localparam logic [5:0] OP_FPU14   = 6'b001110;  // FMOV, FSQRT, FCNV, FTRC, FLOAT
  localparam logic [5:0] OP_FSTORE15= 6'b001111;  // FSTX
  localparam logic [5:0] OP_LOAD16  = 6'b010000;  // LDX
  localparam logic [5:0] OP_BRANCH17= 6'b010001;  // BLINK, GETTR
  localparam logic [5:0] OP_MM18    = 6'b010010;  // MSAD, MMACFX, MCMV, MMULSUM
  localparam logic [5:0] OP_MM19    = 6'b010011;  // MMUL*, MCNVS
  localparam logic [5:0] OP_STORE24 = 6'b011000;  // STX
  localparam logic [5:0] OP_BRANCH25= 6'b011001;  // BEQ.. BGTU
  localparam logic [5:0] OP_PT26    = 6'b011010;  // PTABS, PTREL
  localparam logic [5:0] OP_MISC27  = 6'b011011;  // NOP TRAPA SYNCI RTE BRK SYNCO SLEEP PUTCON
  localparam logic [5:0] OP_LDB     = 6'b100000;
  localparam logic [5:0] OP_LDW     = 6'b100001;
  localparam logic [5:0] OP_LDL     = 6'b100010;
  localparam logic [5:0] OP_LDQ     = 6'b100011;
  localparam logic [5:0] OP_LDUB    = 6'b100100;
  localparam logic [5:0] OP_FLDS    = 6'b100101;
  localparam logic [5:0] OP_FLDP    = 6'b100110;
  localparam logic [5:0] OP_FLDD    = 6'b100111;
  localparam logic [5:0] OP_STB     = 6'b101000;
  localparam logic [5:0] OP_STW     = 6'b101001;
  localparam logic [5:0] OP_STL     = 6'b101010;
  localparam logic [5:0] OP_STQ     = 6'b101011;
  localparam logic [5:0] OP_LDUW    = 6'b101100;
  localparam logic [5:0] OP_FSTS    = 6'b101101;
  localparam logic [5:0] OP_FSTP    = 6'b101110;
  localparam logic [5:0] OP_FSTD    = 6'b101111;
  localparam logic [5:0] OP_LOAD48  = 6'b110000;  // LDLO, LDHI, GETCFG (msd6)
  localparam logic [5:0] OP_ALU49   = 6'b110001;  // SHLLI.. XORI (msd6)
  localparam logic [5:0] OP_SHORI   = 6'b110010;
  localparam logic [5:0] OP_MOVI    = 6'b110011;
  localparam logic [5:0] OP_ADDI    = 6'b110100;
  localparam logic [5:0] OP_ADDIL   = 6'b110101;
  localparam logic [5:0] OP_ANDI    = 6'b110110;
  localparam logic [5:0] OP_ORI     = 6'b110111;
  localparam logic [5:0] OP_STORE56 = 6'b111000;  // PREFI STLO STHI ALLOCO ICBI OCB* PUTCFG (msd6)
  localparam logic [5:0] OP_BRANCH57= 6'b111001;  // BEQI, BNEI (msc6)
  localparam logic [5:0] OP_PTA     = 6'b111010;
  localparam logic [5:0] OP_PTB     = 6'b111011;

  typedef enum logic [2:0] {
    FMT_RESERVED = 3'd0,
    FMT_MND0     = 3'd1,
    FMT_MSD6     = 3'd2,
    FMT_MSD10    = 3'd3,
    FMT_XSD16    = 3'd4
  } major_fmt_t;

  // Major format from the opcode (Vol. 2 Table 36)
  function automatic major_fmt_t major_format(input logic [5:0] op);
    case (op[5:3])
      3'b000, 3'b001:
        major_format = FMT_MND0;
      3'b010, 3'b011:
        major_format = op[2] ? FMT_RESERVED : FMT_MND0;
      3'b100, 3'b101:
        major_format = FMT_MSD10;
      3'b110:
        case (op[2:0])
          3'b000, 3'b001: major_format = FMT_MSD6;
          3'b010, 3'b011: major_format = FMT_XSD16;
          default:        major_format = FMT_MSD10;
        endcase
      default: // 3'b111
        case (op[2:0])
          3'b000, 3'b001: major_format = FMT_MSD6;
          3'b010, 3'b011: major_format = FMT_XSD16;
          default:        major_format = FMT_RESERVED;
        endcase
    endcase
  endfunction

  // The 14 floating-point opcode groups (Vol. 2 A.6): FPUDIS applies to
  // every instruction in them when SR.FD = 1, including reserved ones.
  function automatic logic is_fpu_opcode(input logic [5:0] op);
    case (op)
      OP_FPURES4, OP_FPU5, OP_FPU6, OP_FLOAD7, OP_FPU12, OP_FPU13, OP_FPU14,
      OP_FSTORE15, OP_FLDS, OP_FLDP, OP_FLDD, OP_FSTS, OP_FSTP, OP_FSTD:
        is_fpu_opcode = 1'b1;
      default:
        is_fpu_opcode = 1'b0;
    endcase
  endfunction

  // Extension assignments for MND0/MSD6 opcodes (Vol. 2 Tables 39-66),
  // cross-checked against the emulator decode table exercised by tests/isa.
  // Returns 1 when {op, ext} names an instruction.
  function automatic logic ext_is_defined(input logic [5:0] op, input logic [3:0] ext);
    logic [15:0] m;
    case (op)
      OP_ALU0:     m = 16'b1111_1111_1000_1010;  // 1 CMPEQ, 3 CMPGT, 7 CMPGTU, 8 ADDL, 9 ADD, 10 SUBL, 11 SUB, 12 ADDZL, 13 NSB, 14 MULUL, 15 BYTEREV
      OP_ALU1:     m = 16'b1110_1010_1100_1111;  // 0 SHLLDL, 1 SHLLD, 2 SHLRDL, 3 SHLRD, 6 SHARDL, 7 SHARD, 9 OR, 11 AND, 13 XOR, 14 MULSL, 15 ANDC
      OP_MM2:      m = 16'b0111_0110_0111_0110;  // 1 MADDW, 2 MADDL, 4 MADDSUB, 5 MADDSW, 6 MADDSL, 9 MSUBW, 10 MSUBL, 12 MSUBSUB, 13 MSUBSW, 14 MSUBSL
      OP_MM3:      m = 16'b0110_1110_0110_0110;  // 1 MSHLLDW, 2 MSHLLDL, 5 MSHALDSW, 6 MSHALDSL, 9 MSHARDW, 10 MSHARDL, 11 MSHARDSQ, 13 MSHLRDW, 14 MSHLRDL
      OP_FPU5:     m = 16'b0100_0000_0100_0000;  // 6 FIPRS, 14 FTRVS
      OP_FPU6:     m = 16'b0001_0101_0000_1111;  // 0 FABSS, 1 FABSD, 2 FNEGS, 3 FNEGD, 8 FSINAS, 10 FSRRAS, 12 FCOSAS
      OP_FLOAD7:   m = 16'b0010_0011_0000_0111;  // 0 FMOVLS, 1 FMOVQD, 2 FGETSCR, 8 FLDXS, 9 FLDXD, 13 FLDXP
      OP_RMW8:     m = 16'b0000_0000_0010_1010;  // 1 CMVEQ, 3 SWAPQ, 5 CMVNE
      OP_MISC9:    m = 16'b1000_0000_0000_0000;  // 15 GETCON
      OP_MM10:     m = 16'b1010_1110_1111_0111;  // 0 MCMPEQB, 1 MCMPEQW, 2 MCMPEQL, 4 MCMPGTUB, 5 MCMPGTW, 6 MCMPGTL, 7 MEXTR1, 9 MABSW, 10 MABSL, 11 MEXTR2, 13 MPERMW, 15 MEXTR3
      OP_MM11:     m = 16'b1000_1000_1111_1111;  // 0 MSHFLOB, 1 MSHFLOW, 2 MSHFLOL, 3 MEXTR4, 4 MSHFHIB, 5 MSHFHIW, 6 MSHFHIL, 7 MEXTR5, 11 MEXTR6, 15 MEXTR7
      OP_FPU12:    m = 16'b1111_1111_0000_0111;  // 0 FMOVSL, 1 FMOVDQ, 2 FPUTSCR, 8 FCMPEQS, 9 FCMPEQD, 10 FCMPUNS, 11 FCMPUND, 12 FCMPGTS, 13 FCMPGTD, 14 FCMPGES, 15 FCMPGED
      OP_FPU13:    m = 16'b0100_0000_1111_1111;  // 0 FADDS, 1 FADDD, 2 FSUBS, 3 FSUBD, 4 FDIVS, 5 FDIVD, 6 FMULS, 7 FMULD, 14 FMACS
      OP_FPU14:    m = 16'b1111_1111_1111_0011;  // 0 FMOVS, 1 FMOVD, 4 FSQRTS, 5 FSQRTD, 6 FCNVSD, 7 FCNVDS, 8 FTRCSL, 9 FTRCDQ, 10 FTRCSQ, 11 FTRCDL, 12 FLOATLS, 13 FLOATQD, 14 FLOATLD, 15 FLOATQS
      OP_FSTORE15: m = 16'b0010_0011_0000_0000;  // 8 FSTXS, 9 FSTXD, 13 FSTXP
      OP_LOAD16:   m = 16'b0000_0000_0011_1111;  // 0 LDXB, 1 LDXW, 2 LDXL, 3 LDXQ, 4 LDXUB, 5 LDXUW
      OP_BRANCH17: m = 16'b0000_0000_0010_0010;  // 1 BLINK, 5 GETTR
      OP_MM18:     m = 16'b0000_0010_0010_1011;  // 0 MSADUBQ, 1 MMACFXWL, 3 MCMV, 5 MMACNFXWL, 9 MMULSUMWQ
      OP_MM19:     m = 16'b0111_0111_0110_0110;  // 1 MMULW, 2 MMULL, 5 MMULFXW, 6 MMULFXL, 8 MCNVSWB, 9 MMULFXRPW, 10 MMULLOWL, 12 MCNVSWUB, 13 MCNVSLW, 14 MMULHIWL
      OP_STORE24:  m = 16'b0000_0000_0000_1111;  // 0 STXB, 1 STXW, 2 STXL, 3 STXQ
      OP_BRANCH25: m = 16'b1000_1000_1010_1010;  // 1 BEQ, 3 BGE, 5 BNE, 7 BGT, 11 BGEU, 15 BGTU
      OP_PT26:     m = 16'b0000_0000_0010_0010;  // 1 PTABS, 5 PTREL
      OP_MISC27:   m = 16'b1000_0000_1110_1111;  // 0 NOP, 1 TRAPA, 2 SYNCI, 3 RTE, 5 BRK, 6 SYNCO, 7 SLEEP, 15 PUTCON
      OP_LOAD48:   m = 16'b1000_0000_1100_1100;  // 2 LDLOL, 3 LDLOQ, 6 LDHIL, 7 LDHIQ, 15 GETCFG
      OP_ALU49:    m = 16'b0010_0000_1100_1111;  // 0 SHLLIL, 1 SHLLI, 2 SHLRIL, 3 SHLRI, 6 SHARIL, 7 SHARI, 13 XORI
      OP_STORE56:  m = 16'b1001_0011_1111_1110;  // 1 PREFI, 2 STLOL, 3 STLOQ, 4 ALLOCO, 5 ICBI, 6 STHIL, 7 STHIQ, 8 OCBP, 9 OCBI, 12 OCBWB, 15 PUTCFG
      OP_BRANCH57: m = 16'b0000_0000_0010_0010;  // 1 BEQI, 5 BNEI
      default:     m = 16'b0;
    endcase
    ext_is_defined = m[ext];
  endfunction

  // Privileged instructions (RESINST in user mode): RTE, SLEEP, GETCFG,
  // PUTCFG, and GETCON/PUTCON of CR0..CR31 (checked separately).
  function automatic logic is_privileged(input logic [5:0] op, input logic [3:0] ext);
    is_privileged = (op == OP_MISC27 && (ext == 4'd3 || ext == 4'd7)) ||  // RTE, SLEEP
                    (op == OP_LOAD48 && ext == 4'd15) ||                   // GETCFG
                    (op == OP_STORE56 && ext == 4'd15);                    // PUTCFG
  endfunction

  // Guaranteed reserved instruction (Vol. 2 A.4)
  localparam logic [31:0] INSN_RESERVED_ALWAYS = 32'h6ff4_fff0;

endpackage
