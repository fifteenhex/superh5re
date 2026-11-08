// Decoded instruction (micro-op) carried down the pipeline.

package sh5_uop_pkg;

  typedef enum logic [4:0] {
    UC_NOP,       // no architectural effect (NOP, prefetch to R63, cache ops with no cache)
    UC_ALU,       // result from sh5_alu in E1
    UC_MM,        // result from sh5_mm after E3 (SIMD, MULS.L, MULU.L)
    UC_LOAD,      // memory read, result after E3
    UC_STORE,     // memory write at W
    UC_SWAP,      // SWAP.Q: atomic exchange, result after E3
    UC_BRANCH,    // conditional branch, resolved in E1
    UC_BLINK,     // unconditional branch, link written at W
    UC_PT,        // prepare target: TR written at W
    UC_GETTR,
    UC_GETCON,
    UC_PUTCON,
    UC_GETCFG,
    UC_PUTCFG,
    UC_RTE,
    UC_SYNCI,
    UC_SYNCO,
    UC_SLEEP,
    UC_FPU,       // operation issued to sh5_fpu in E1
    UC_FMOV,      // register moves between/within FR and GR, FABS/FNEG, FGETSCR
    UC_FLOAD,     // memory read into FR
    UC_FSTORE,    // memory write from FR
    UC_FPUTSCR,
    UC_CACHEOP,   // ALLOCO, ICBI, OCBI, OCBP, OCBWB, PREFI: address and translation checks only (no cache)
    UC_EXC,       // exception or interrupt launch when it reaches W
    UC_SRFLAG     // SHcompact: SR flag bits (S, Q, M, PR, SZ, FR) <- operand under a mask, at W
  } uclass_t;

  typedef enum logic [2:0] {
    COP_PREFI, COP_ALLOCO, COP_ICBI, COP_OCBP, COP_OCBI, COP_OCBWB
  } cop_t;

  // operand cache request kinds
  typedef enum logic [2:0] {
    DK_LOAD, DK_STORE, DK_SWAP, DK_OCBI, DK_OCBP, DK_OCBWB, DK_ALLOCO
  } dkind_t;

  typedef enum logic [4:0] {
    A_ADD, A_ADDL, A_ADDZL, A_SUB, A_SUBL,
    A_CMPEQ, A_CMPGT, A_CMPGTU,
    A_AND, A_ANDC, A_OR, A_XOR,
    A_SHLLD, A_SHLLDL, A_SHLRD, A_SHLRDL, A_SHARD, A_SHARDL,
    A_NSB, A_BYTEREV, A_CMVEQ, A_CMVNE,
    A_MOVI, A_SHORI,
    A_PASS_B,     // result = operand b (GETCON, GETTR)
    // SHcompact expansion helpers (sh5_cexpand)
    A_DIV1,       // {Q' at 40, T' at 32, Rn' [31:0]} of DIV1 Rm(a), Rn(b) with T = c[0], SR.M/Q
    A_DIV0S,      // {M at 9, Q at 8, T at 0} of DIV0S Rm(a), Rn(b)
    A_ADDSAT48,   // a + b saturated to the signed 48-bit range (MAC.L, S = 1)
    A_MACWSAT     // MAC.W with S = 1: {MACH' , MACL'} from the accumulator a and the product b
  } aluop_t;

  typedef enum logic [2:0] {
    BC_EQ, BC_NE, BC_GT, BC_GE, BC_GTU, BC_GEU
  } bcond_t;

  // Memory access kinds
  typedef enum logic [2:0] {
    M_NORMAL,     // aligned access of mem_size bytes
    M_HI,         // LDHI/STHI: bytes from the aligned block start up to the address
    M_LO,         // LDLO/STLO: bytes from the address to the aligned block end
    M_FP_S,       // 32-bit to/from FR
    M_FP_D,       // 64-bit to/from DR
    M_FP_P        // pair: FR[f] from the low word, FR[f|1] from the high word
  } mkind_t;

  // FR write modes
  typedef enum logic [1:0] {
    FW_32,        // FR[f]
    FW_64,        // DR: FR[f&~1] = data[63:32], FR[f|1] = data[31:0]
    FW_PAIR,      // FR[f&~1] = data[31:0], FR[f|1] = data[63:32]
    FW_128        // FV: FR[f+k] = data[32k+31:32k]
  } fwmode_t;

  typedef enum logic [3:0] {
    FM_LS,        // FMOV.LS  Rm -> FRf
    FM_SL,        // FMOV.SL  FRg -> Rd (sign-extended)
    FM_QD,        // FMOV.QD  Rm -> DRf
    FM_DQ,        // FMOV.DQ  DRg -> Rd
    FM_S,         // FMOV.S
    FM_D,         // FMOV.D
    FM_ABSS, FM_NEGS, FM_ABSD, FM_NEGD,
    FM_GETSCR     // FGETSCR -> FRf
  } fmov_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] pc_next;     // address of the next instruction in sequence (SHmedia: pc + 4)
    logic [31:0] insn;        // SHmedia encoding (for SHcompact: the expanded micro-op)
    logic        compact;     // micro-op of an SHcompact instruction
    logic [15:0] cinsn;       // the SHcompact instruction
    uclass_t     cls;
    aluop_t      alu;
    bcond_t      bcond;
    logic        likely;
    // general-purpose register operands
    logic [5:0]  ra;          // left source (m)
    logic [5:0]  rb;          // right source (n)
    logic [5:0]  rc;          // extra source: store data, RMW old value, PUTCON/PUTCFG value
    logic [5:0]  rd;          // destination
    logic        wr_gpr;
    logic        use_imm;     // operand b is imm
    logic [63:0] imm;
    // target registers
    logic [2:0]  tra;         // TR destination (PT)
    logic [2:0]  trb;         // TR source (branches, GETTR)
    logic        wr_tr;
    logic        rd_tr;
    // floating-point registers
    logic [5:0]  fa;          // g
    logic [5:0]  fb;          // h
    logic [5:0]  fc;          // q / z (accumulator or store source)
    logic [5:0]  fd;          // f
    logic        rd_fa, rd_fb, rd_fc;
    logic [1:0]  fa_w, fb_w, fc_w;  // 0: 32, 1: 64, 2: 128 (FV), 3: 512 (MTRX) bits read
    logic        wr_fr;
    fwmode_t     fw;
    fmov_t       fmov;
    logic        fpu_wr_gpr;  // FPU result goes to rd (FCMP*)
    // memory
    mkind_t      mkind;
    logic [1:0]  msize;       // log2 bytes
    logic        msigned;
    // exception carried to W: event code, 0 = none
    logic [11:0] exc;
    logic        exc_is_irq;  // interrupt pseudo-op: re-check acceptance at W
    logic        exc_is_reset;// CPURESET pseudo-op
    logic        tea_valid;   // exc delivers an address in TEA
    logic        fetch_fault; // exc raised by the instruction fetch: TEA = the fetch address (PC, or PC + 2 for an SHcompact delay slot, whose PC is its branch's)
    logic        slot;        // SHcompact delay slot (pc is the branch's address, the instruction sits at pc + 2)
    cop_t        cop;
    logic [3:0]  irq_level;
    logic        pred;        // branch predicted taken in D from a target buffer
    logic [31:0] pred_pc;     // predicted next PC
    logic        serialize;   // block decode until this instruction leaves W
    logic        long_lat;    // result available only after E3 (load, MM, swap)
  } uop_t;

endpackage
