// SH-5 SHmedia floating-point unit (Vol. 1 ch. 8, Vol. 2 ch. 2).
//
// Operations: FADD/FSUB/FMUL/FDIV/FSQRT .S/.D, FMAC.S, FCMPEQ/FCMPUN/FCMPGT/FCMPGE
// .S/.D, FCNV.SD/.DS, FTRC.SL/DL/SQ/DQ, FLOAT.LS/LD/QS/QD, FIPR.S, FTRV.S,
// FSINA.S, FCOSA.S, FSRRA.S.  Moves, FABS, FNEG and FPSCR access are not
// arithmetic (Vol. 1 8.3.3, 8.3.9) and are handled by the core.
//
// Structure: one operation in flight (ready_o = 0 while busy), completion in
// issue order.  Every rounded result is produced by one datapath: up to four
// exact terms (significand, exponent of its LSB, sign) are aligned to the term
// with the largest LSB exponent in a window of G guard bits below that LSB,
// summed in two's complement with sticky bits for everything shifted out,
// normalized and rounded once to the destination format (Vol. 1 8.3.2: round
// to nearest even or toward zero; tininess detected after rounding; underflow
// = tiny and inexact; overflow always with inexact; 8.4.1: DN flushes
// denormalized sources before and denormalized results after the operation,
// a flushed result signals U and I).
//   FADD/FSUB: two terms.  FMUL: one 106-bit product.  FMAC.S: exact 48-bit
//   product plus the addend, one rounding (Vol. 1 8.4.2).  FIPR.S: four exact
//   products, one rounding; the window keeps at least G = 32 bits below the
//   LSB of the largest term, which is within the error bound of Vol. 1 8.7.3.
//   FTRV.S: four FIPR.S passes, one per result element (Vol. 1 8.7.2).
//   FCNV, FLOAT: one term.  FDIV/FSQRT: radix-2 restoring iteration producing
//   p+2 quotient/root bits and a remainder sticky bit, then the rounder.
//   FSRRA.S: correctly rounded square root followed by a correctly rounded
//   reciprocal; the error is below 2^(E-22), within Vol. 1 8.7.4.
//   FSINA.S/FCOSA.S: quadrant and octant reduction of the 16-bit angle, then
//   a fixed-point Taylor polynomial (degree 9 / 10, Q2.30) of the reduced
//   angle, accurate to about 2^-26 (bound 2^-21, Vol. 1 8.7.4).
// Special cases (NaN, infinities, zeros, FPU error) are decided from the
// operand classes (Vol. 2 special case tables) and bypass the datapath.
// trap_o (Vol. 1 8.3.8, Vol. 2 instruction pseudocode) depends only on the
// operand classes and FPSCR.ENABLE.
//
// Latency in clocks from the accepting edge to done_o:
//   special cases, compares, FTRC: 2; FADD/FSUB/FMUL/FMAC/FCNV/FLOAT/FIPR: 6;
//   FTRV: 21; FDIV.S/FSQRT.S: 32; FDIV.D/FSQRT.D: 61; FSINA/FCOSA: 12;
//   FSRRA: 63.
module sh5_fpu import sh5_pkg::*; (
  input  logic         clk,
  input  logic         rst_n,
  // Issue.  One operation is presented; it is accepted when issue_i && ready_o.
  input  logic         issue_i,
  output logic         ready_o,
  input  logic [5:0]   op_i,        // instruction bits [31:26]
  input  logic [3:0]   ext_i,       // instruction bits [19:16]
  input  logic [63:0]  a_i,         // Fg in [31:0] or Dg; FMAC.S: Fg
  input  logic [63:0]  b_i,         // Fh / Dh; FMAC.S: Fh
  input  logic [63:0]  c_i,         // FMAC.S: Fq accumulator in [31:0]
  input  logic [127:0] va_i,        // FIPR.S: FVg; FTRV.S: FVh; element i in [32i+31:32i]
  input  logic [127:0] vb_i,        // FIPR.S: FVh
  input  logic [511:0] mtrx_i,      // FTRV.S: MTRXg, element i+4j in [32(i+4j)+31:32(i+4j)]
  input  logic [31:0]  fpscr_i,     // current FPSCR (RM, ENABLE, DN are used)
  input  logic [7:0]   tag_i,
  // Early exception decision for the operation on the inputs (Vol. 1 8.3.8),
  // combinational, meaningful while issue_i = 1.
  output logic         trap_o,
  // Completion: done_o is a one-cycle pulse per accepted operation.
  output logic         done_o,
  output logic [7:0]   tag_o,
  output logic [127:0] result_o,    // FTRV.S: four elements as in va_i; FCMP*: bit 0;
                                    // single results in [31:0]; double and 64-bit integer
                                    // results in [63:0]; FTRC.SL/DL in [31:0]
  output logic [5:0]   cause_o      // CAUSE bits, FPSCR order: E V Z O U I (= FPSCR[17:12])
);

  // ------------------------------------------------------------------------
  // Datapath geometry
  localparam int G  = 32;         // guard bits below the LSB of the leading term
  localparam int TW = 106;        // widest term significand (FMUL.D product)
  localparam int W  = G + TW;     // alignment window
  localparam int SW = W + 3;      // signed sum of four terms
  localparam int EW = 16;         // internal exponent width (two's complement)

  localparam logic [5:0] C_I = 6'b000001;
  localparam logic [5:0] C_U = 6'b000010;
  localparam logic [5:0] C_O = 6'b000100;
  localparam logic [5:0] C_Z = 6'b001000;
  localparam logic [5:0] C_V = 6'b010000;
  localparam logic [5:0] C_E = 6'b100000;

  // Quiet NaN values (Vol. 1 Table 75)
  localparam logic [63:0] QNAN_S = 64'h0000_0000_7FBF_FFFF;
  localparam logic [63:0] QNAN_D = 64'h7FF7_FFFF_FFFF_FFFF;

  // FSINA.S/FCOSA.S: Taylor coefficients of sin(u*pi/4) (odd powers of u)
  // and cos(u*pi/4) (even powers of u), u in [0, 1], Q2.30 two's complement.
  localparam logic [31:0] PC0 = 32'h3243F6A9;
  localparam logic [31:0] PC1 = 32'hFAD510C6;
  localparam logic [31:0] PC2 = 32'h0028CD79;
  localparam logic [31:0] PC3 = 32'hFFFF6697;
  localparam logic [31:0] PC4 = 32'h00000150;
  localparam logic [31:0] PD0 = 32'h40000000;
  localparam logic [31:0] PD1 = 32'hEC42C336;
  localparam logic [31:0] PD2 = 32'h0103C1F1;
  localparam logic [31:0] PD3 = 32'hFFFAA8B1;
  localparam logic [31:0] PD4 = 32'h00000F10;
  localparam logic [31:0] PD5 = 32'hFFFFFFE6;

  // ------------------------------------------------------------------------
  // Types
  typedef enum logic [4:0] {
    K_NONE, K_ADD, K_SUB, K_MUL, K_DIV, K_SQRT, K_MAC,
    K_CMPEQ, K_CMPUN, K_CMPGT, K_CMPGE,
    K_CNV, K_TRC, K_FLOAT, K_IPR, K_TRV, K_SINA, K_COSA, K_SRRA
  } kind_t;

  typedef struct packed {
    kind_t kind;
    logic  sd;      // source operands are double
    logic  dd;      // destination is double
    logic  i64;     // 64-bit integer side (FTRC destination, FLOAT source)
  } dec_t;

  // Classified operand.  Value = sig * 2^(e - 23) (single) or sig * 2^(e - 52)
  // (double); denormalized numbers carry e = Emin and no hidden bit.
  typedef struct packed {
    logic          sign;
    logic [EW-1:0] e;
    logic [52:0]   sig;
    logic          zero;
    logic          den;
    logic          norm;
    logic          inf;
    logic          qnan;
    logic          snan;
  } fpc_t;

  // Term of the sum: value = (-1)^sign * m * 2^e.
  typedef struct packed {
    logic          nz;      // m != 0
    logic          used;    // participates (for the sign of an exact zero sum)
    logic          sign;
    logic [EW-1:0] e;
    logic [TW-1:0] m;
  } term_t;

  // FIPR.S/FTRV.S operand pair classification (Vol. 2 FIPR.S special cases)
  typedef struct packed {
    logic nan;
    logic invalid;
    logic pinf;
    logic ninf;
  } iprc_t;

  // Result decided from operand classes
  typedef struct packed {
    logic        valid;
    logic [63:0] res;
    logic [5:0]  cause;
  } spec_t;

  typedef enum logic [2:0] {
    S_IDLE, S_PREP, S_ALIGN, S_SUM, S_NORM, S_ROUND, S_ITER, S_POLY
  } state_t;

  // ------------------------------------------------------------------------
  // Functions.  Several take whole classified operands and use only some of
  // the fields.
  /* verilator lint_off UNUSEDSIGNAL */

  function automatic dec_t decode(input logic [5:0] op, input logic [3:0] ext);
    dec_t d;
    d = '{kind: K_NONE, sd: 1'b0, dd: 1'b0, i64: 1'b0};
    case (op)
      OP_FPU13: begin
        d.sd = ext[0];
        d.dd = ext[0];
        case (ext[3:1])
          3'b000: d.kind = K_ADD;
          3'b001: d.kind = K_SUB;
          3'b010: d.kind = K_DIV;
          3'b011: d.kind = K_MUL;
          3'b111: begin d.kind = K_MAC; d.sd = 1'b0; d.dd = 1'b0; end
          default: ;
        endcase
      end
      OP_FPU14: begin
        case (ext)
          4'd4, 4'd5: begin d.kind = K_SQRT;  d.sd = ext[0]; d.dd = ext[0]; end
          4'd6:       begin d.kind = K_CNV;   d.sd = 1'b0; d.dd = 1'b1; end
          4'd7:       begin d.kind = K_CNV;   d.sd = 1'b1; d.dd = 1'b0; end
          4'd8:       begin d.kind = K_TRC;   d.sd = 1'b0; d.i64 = 1'b0; end
          4'd9:       begin d.kind = K_TRC;   d.sd = 1'b1; d.i64 = 1'b1; end
          4'd10:      begin d.kind = K_TRC;   d.sd = 1'b0; d.i64 = 1'b1; end
          4'd11:      begin d.kind = K_TRC;   d.sd = 1'b1; d.i64 = 1'b0; end
          4'd12:      begin d.kind = K_FLOAT; d.i64 = 1'b0; d.dd = 1'b0; end
          4'd13:      begin d.kind = K_FLOAT; d.i64 = 1'b1; d.dd = 1'b1; end
          4'd14:      begin d.kind = K_FLOAT; d.i64 = 1'b0; d.dd = 1'b1; end
          4'd15:      begin d.kind = K_FLOAT; d.i64 = 1'b1; d.dd = 1'b0; end
          default: ;
        endcase
      end
      OP_FPU12: begin
        d.sd = ext[0];
        d.dd = ext[0];
        case (ext[3:1])
          3'b100: d.kind = K_CMPEQ;
          3'b101: d.kind = K_CMPUN;
          3'b110: d.kind = K_CMPGT;
          3'b111: d.kind = K_CMPGE;
          default: ;
        endcase
      end
      OP_FPU5: begin
        case (ext)
          4'd6:  d.kind = K_IPR;
          4'd14: d.kind = K_TRV;
          default: ;
        endcase
      end
      OP_FPU6: begin
        case (ext)
          4'd8:  d.kind = K_SINA;
          4'd10: d.kind = K_SRRA;
          4'd12: d.kind = K_COSA;
          default: ;
        endcase
      end
      default: ;
    endcase
    return d;
  endfunction

  // Classify a single ([31:0]) or double operand.  A signaling NaN has the
  // most significant fraction bit set (Vol. 1 3.4).  flush: FPSCR.DN = 1.
  function automatic fpc_t unpack(input logic [63:0] b, input logic dbl, input logic flush);
    fpc_t r;
    logic [10:0] ef;
    logic [51:0] f;
    logic emax, ezero, fmsb;
    if (dbl) begin
      r.sign = b[63];
      ef = b[62:52];
      f = b[51:0];
      emax = &ef;
      fmsb = f[51];
    end else begin
      r.sign = b[31];
      ef = {3'b0, b[30:23]};
      f = {29'b0, b[22:0]};
      emax = &ef[7:0];
      fmsb = f[22];
    end
    ezero = (ef == 11'd0);
    r.inf  = emax & (f == 52'd0);
    r.snan = emax & (f != 52'd0) & fmsb;
    r.qnan = emax & (f != 52'd0) & ~fmsb;
    r.zero = ezero & (f == 52'd0);
    r.den  = ezero & (f != 52'd0);
    r.norm = ~emax & ~ezero;
    if (r.norm)
      r.e = EW'(signed'({5'b0, ef})) - (dbl ? EW'(1023) : EW'(127));
    else
      r.e = dbl ? EW'(-1022) : EW'(-126);
    r.sig = dbl ? {r.norm, f} : {29'b0, r.norm, f[22:0]};
    if (flush & r.den) begin
      r.den = 1'b0;
      r.zero = 1'b1;
      r.sig = '0;
    end
    return r;
  endfunction

  function automatic logic [63:0] fp_inf(input logic s, input logic dbl);
    return dbl ? {s, 11'h7FF, 52'd0} : {32'd0, s, 8'hFF, 23'd0};
  endfunction

  function automatic logic [63:0] fp_zero(input logic s, input logic dbl);
    return dbl ? {s, 63'd0} : {32'd0, s, 31'd0};
  endfunction

  function automatic logic [63:0] fp_maxfinite(input logic s, input logic dbl);
    return dbl ? {s, 11'h7FE, {52{1'b1}}} : {32'd0, s, 8'hFE, {23{1'b1}}};
  endfunction

  // FIPR.S pair classification over the four products (Vol. 2 FIPR.S tables).
  function automatic iprc_t ipr_classify(input fpc_t g0, input fpc_t g1, input fpc_t g2, input fpc_t g3,
                                         input fpc_t h0, input fpc_t h1, input fpc_t h2, input fpc_t h3);
    iprc_t r;
    fpc_t g [4];
    fpc_t h [4];
    g[0] = g0; g[1] = g1; g[2] = g2; g[3] = g3;
    h[0] = h0; h[1] = h1; h[2] = h2; h[3] = h3;
    r = '{nan: 1'b0, invalid: 1'b0, pinf: 1'b0, ninf: 1'b0};
    for (int i = 0; i < 4; i++) begin
      if (g[i].snan | h[i].snan) begin
        r.nan = 1'b1;
        r.invalid = 1'b1;
      end else if (g[i].qnan | h[i].qnan) begin
        r.nan = 1'b1;
      end else if ((g[i].zero & h[i].inf) | (g[i].inf & h[i].zero)) begin
        r.nan = 1'b1;
        r.invalid = 1'b1;
      end else if (g[i].inf | h[i].inf) begin
        if (g[i].sign ^ h[i].sign) r.ninf = 1'b1;
        else                       r.pinf = 1'b1;
      end
    end
    return r;
  endfunction

  // FTRC: truncation with saturation; invalid for NaN, infinity and out of
  // range; denormalized numbers give 0 (Vol. 2 FTRC special cases).
  function automatic spec_t ftrc_calc(input fpc_t A, input logic sd, input logic i64);
    spec_t s;
    logic [63:0] t, mag, neg;
    logic [63:0] imin, imax;
    logic ovf, big;
    logic [5:0] shr;
    s.valid = 1'b1;
    s.res = '0;
    s.cause = '0;
    imin = i64 ? 64'h8000_0000_0000_0000 : 64'h0000_0000_8000_0000;
    imax = i64 ? 64'h7FFF_FFFF_FFFF_FFFF : 64'h0000_0000_7FFF_FFFF;
    t = sd ? {A.sig, 11'd0} : {A.sig[23:0], 40'd0};
    big = ($signed(A.e) >= EW'(64));
    shr = 6'd63 - A.e[5:0];
    mag = big ? '0 : (t >> shr);
    if (i64)
      ovf = big | (mag[63] & ~(A.sign & (mag[62:0] == 63'd0)));
    else
      ovf = big | (|mag[63:32]) | (mag[31] & ~(A.sign & (mag[30:0] == 31'd0)));
    neg = -mag;
    if (A.qnan | A.snan) begin
      s.res = imin;
      s.cause = C_V;
    end else if (A.inf) begin
      s.res = A.sign ? imin : imax;
      s.cause = C_V;
    end else if (A.zero | A.den | $signed(A.e) < EW'(0)) begin
      s.res = '0;
    end else if (ovf) begin
      s.res = A.sign ? imin : imax;
      s.cause = C_V;
    end else begin
      s.res = A.sign ? neg : mag;
      if (!i64) s.res[63:32] = '0;
    end
    return s;
  endfunction

  // Compares (Vol. 2 FCMP* special cases): EQ and UN signal invalid for a
  // signaling NaN only, GT and GE for any NaN.
  function automatic spec_t cmp_calc(input dec_t d, input fpc_t A, input fpc_t B,
                                     input logic [63:0] rawa, input logic [63:0] rawb);
    spec_t s;
    logic nan, snan, eqz, eq, gt;
    logic [62:0] maga, magb;
    s.valid = 1'b1;
    s.res = '0;
    s.cause = '0;
    nan = A.qnan | A.snan | B.qnan | B.snan;
    snan = A.snan | B.snan;
    maga = A.zero ? '0 : (d.sd ? rawa[62:0] : {32'd0, rawa[30:0]});
    magb = B.zero ? '0 : (d.sd ? rawb[62:0] : {32'd0, rawb[30:0]});
    eqz = A.zero & B.zero;
    eq = eqz | ((maga == magb) & (A.sign == B.sign));
    gt = ~eqz & ((A.sign != B.sign) ? ~A.sign : (A.sign ? (maga < magb) : (maga > magb)));
    case (d.kind)
      K_CMPEQ: begin s.res[0] = nan ? 1'b0 : eq;        s.cause = snan ? C_V : '0; end
      K_CMPUN: begin s.res[0] = nan;                    s.cause = snan ? C_V : '0; end
      K_CMPGT: begin s.res[0] = nan ? 1'b0 : gt;        s.cause = nan ? C_V : '0; end
      default: begin s.res[0] = nan ? 1'b0 : (eq | gt); s.cause = nan ? C_V : '0; end
    endcase
    return s;
  endfunction

  // Results decided by the operand classes (Vol. 2 special case tables; the
  // checks are in the order given there: invalid, divide by zero, FPU error).
  // valid = 0: the datapath computes the result.
  function automatic spec_t specials(input dec_t d, input fpc_t A, input fpc_t B, input fpc_t C,
                                     input iprc_t P, input logic [63:0] rawa, input logic [63:0] rawb);
    spec_t s;
    logic sb, sp;
    logic [63:0] qn;
    s.valid = 1'b1;
    s.res = '0;
    s.cause = '0;
    qn = d.dd ? QNAN_D : QNAN_S;
    sb = B.sign ^ (d.kind == K_SUB);
    sp = A.sign ^ B.sign;
    case (d.kind)
      K_ADD, K_SUB: begin
        if (A.snan | B.snan)      begin s.res = qn; s.cause = C_V; end
        else if (A.qnan | B.qnan) s.res = qn;
        else if (A.den | B.den)   begin s.res = qn; s.cause = C_E; end
        else if (A.inf & B.inf) begin
          if (A.sign == sb) s.res = fp_inf(A.sign, d.dd);
          else begin s.res = qn; s.cause = C_V; end
        end
        else if (A.inf) s.res = fp_inf(A.sign, d.dd);
        else if (B.inf) s.res = fp_inf(sb, d.dd);
        else s.valid = 1'b0;
      end
      K_MUL: begin
        if (A.snan | B.snan)      begin s.res = qn; s.cause = C_V; end
        else if (A.qnan | B.qnan) s.res = qn;
        else if ((A.zero & B.inf) | (A.inf & B.zero)) begin s.res = qn; s.cause = C_V; end
        else if (A.den | B.den)   begin s.res = qn; s.cause = C_E; end
        else if (A.inf | B.inf)   s.res = fp_inf(sp, d.dd);
        else if (A.zero | B.zero) s.res = fp_zero(sp, d.dd);
        else s.valid = 1'b0;
      end
      K_DIV: begin
        if (A.snan | B.snan)      begin s.res = qn; s.cause = C_V; end
        else if (A.qnan | B.qnan) s.res = qn;
        else if ((A.zero & B.zero) | (A.inf & B.inf)) begin s.res = qn; s.cause = C_V; end
        else if (B.zero & (A.norm | A.den)) begin s.res = fp_inf(sp, d.dd); s.cause = C_Z; end
        else if (A.den | B.den)   begin s.res = qn; s.cause = C_E; end
        else if (A.inf)           s.res = fp_inf(sp, d.dd);
        else if (B.inf | A.zero)  s.res = fp_zero(sp, d.dd);
        else s.valid = 1'b0;
      end
      K_SQRT: begin
        if (A.snan)      begin s.res = qn; s.cause = C_V; end
        else if (A.qnan) s.res = qn;
        else if (A.zero) s.res = fp_zero(A.sign, d.dd);
        else if (A.sign) begin s.res = qn; s.cause = C_V; end
        else if (A.inf)  s.res = fp_inf(1'b0, d.dd);
        else if (A.den)  begin s.res = qn; s.cause = C_E; end
        else s.valid = 1'b0;
      end
      K_SRRA: begin
        if (A.snan)      begin s.res = qn; s.cause = C_V; end
        else if (A.qnan) s.res = qn;
        else if (A.zero) begin s.res = fp_inf(A.sign, 1'b0); s.cause = C_Z; end
        else if (A.sign) begin s.res = qn; s.cause = C_V; end
        else if (A.inf)  s.res = fp_zero(1'b0, 1'b0);
        else if (A.den)  begin s.res = qn; s.cause = C_E; end
        else s.valid = 1'b0;
      end
      K_MAC: begin
        if (A.snan | B.snan | C.snan) begin s.res = qn; s.cause = C_V; end
        else if ((A.zero & B.inf) | (A.inf & B.zero)) begin s.res = qn; s.cause = C_V; end
        else if (A.qnan | B.qnan | C.qnan) s.res = qn;
        else if (A.den | B.den | C.den) begin s.res = qn; s.cause = C_E; end
        else if (A.inf | B.inf) begin
          if (C.inf & (C.sign != sp)) begin s.res = qn; s.cause = C_V; end
          else s.res = fp_inf(sp, 1'b0);
        end
        else if (C.inf) s.res = fp_inf(C.sign, 1'b0);
        else s.valid = 1'b0;
      end
      K_CNV: begin
        if (A.snan)      begin s.res = qn; s.cause = C_V; end
        else if (A.qnan) s.res = qn;
        else if (A.inf)  s.res = fp_inf(A.sign, d.dd);
        else if (A.zero) s.res = fp_zero(A.sign, d.dd);
        else if (A.den)  begin s.res = qn; s.cause = C_E; end
        else s.valid = 1'b0;
      end
      K_IPR, K_TRV: begin
        if (P.nan)               begin s.res = QNAN_S; s.cause = P.invalid ? C_V : '0; end
        else if (P.pinf & P.ninf) begin s.res = QNAN_S; s.cause = C_V; end
        else if (P.pinf)         s.res = fp_inf(1'b0, 1'b0);
        else if (P.ninf)         s.res = fp_inf(1'b1, 1'b0);
        else s.valid = 1'b0;
      end
      K_TRC: s = ftrc_calc(A, d.sd, d.i64);
      K_CMPEQ, K_CMPUN, K_CMPGT, K_CMPGE: s = cmp_calc(d, A, B, rawa, rawb);
      default: s.valid = 1'b0;
    endcase
    return s;
  endfunction

  // Exception launch decision (Vol. 1 8.3.8; Vol. 2 instruction pseudocode).
  // en = FPSCR.ENABLE [11:7] = V Z O U I.
  function automatic logic trap_rule(input dec_t d, input logic [5:0] cause, input logic [4:0] en);
    logic v, z, e, iou, i;
    v = en[4] & cause[4];
    z = en[3] & cause[3];
    e = cause[5];
    iou = |en[2:0];
    i = en[0];
    case (d.kind)
      K_ADD, K_SUB, K_MUL, K_MAC: return v | e | iou;
      K_CNV:   return d.sd ? (v | e | iou) : (v | e);   // FCNV.SD is exact
      K_DIV:   return v | z | e | iou;
      K_SQRT:  return v | e | i;
      K_SRRA:  return v | z | e | i;
      K_FLOAT: return (d.dd & ~d.i64) ? 1'b0 : i;      // FLOAT.LD is exact
      K_CMPEQ, K_CMPUN, K_CMPGT, K_CMPGE, K_TRC: return v;
      K_IPR:   return v | iou;
      K_TRV:   return en[4] | iou;                      // raised whenever V is enabled
      K_SINA, K_COSA: return i;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic [7:0] lzc_sw(input logic [SW-1:0] x);
    logic [7:0] n;
    logic found;
    n = 8'(SW);
    found = 1'b0;
    for (int i = SW - 1; i >= 0; i--) begin
      if (!found && x[i]) begin
        n = 8'(SW - 1 - i);
        found = 1'b1;
      end
    end
    return n;
  endfunction

  // Signed Q2.30 product
  function automatic logic [31:0] qmul(input logic [31:0] a, input logic [31:0] b);
    logic signed [63:0] p;
    p = signed'(a) * signed'(b);
    return p[61:30];
  endfunction

  // ------------------------------------------------------------------------
  // Early trap decision on the inputs (only the cause bits of spec_i are used)
  dec_t  dec_i;
  fpc_t  ai_c, bi_c, ci_c;
  fpc_t  gi_c [4];
  fpc_t  hi_c [4];
  iprc_t pi_c;
  spec_t spec_i;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    dec_i = decode(op_i, ext_i);
    ai_c = unpack(a_i, dec_i.sd, fpscr_i[FPSCR_DN]);
    bi_c = unpack(b_i, dec_i.sd, fpscr_i[FPSCR_DN]);
    ci_c = unpack(c_i, 1'b0, fpscr_i[FPSCR_DN]);
    for (int i = 0; i < 4; i++) begin
      gi_c[i] = unpack({32'd0, va_i[32*i +: 32]}, 1'b0, fpscr_i[FPSCR_DN]);
      hi_c[i] = unpack({32'd0, vb_i[32*i +: 32]}, 1'b0, fpscr_i[FPSCR_DN]);
    end
    pi_c = ipr_classify(gi_c[0], gi_c[1], gi_c[2], gi_c[3], hi_c[0], hi_c[1], hi_c[2], hi_c[3]);
    spec_i = specials(dec_i, ai_c, bi_c, ci_c, pi_c, a_i, b_i);
    trap_o = trap_rule(dec_i, spec_i.cause, fpscr_i[FPSCR_ENABLE +: 5]);
  end

  // ------------------------------------------------------------------------
  // State
  state_t        state_r;
  dec_t          dec_r;
  logic [7:0]    tag_r;
  logic          rm_r;             // FPSCR.RM: 1 = round toward zero
  logic          dn_r;             // FPSCR.DN
  logic [63:0]   ra_r, rb_r, rc_r;
  logic [127:0]  rva_r, rvb_r;
  logic [511:0]  rm_m_r;
  logic [1:0]    row_r;            // FTRV.S result element
  logic          srra_div_r;       // FSRRA.S: second pass (reciprocal)
  logic [31:0]   pass_r;           // FSRRA.S: rounded square root
  logic [127:0]  res_r;
  logic [5:0]    cause_r;
  logic [5:0]    cause_acc_r;      // FTRV.S: OR over the elements
  logic          done_r;

  term_t         term_r [4];
  logic          zsign_r;          // sign of an exact zero sum when no term is nonzero
  logic          allzero_r;
  logic          xsticky_r;        // remainder sticky of FDIV/FSQRT

  logic [W-1:0]  al_r [4];
  logic          st_r [4];
  logic          neg_r [4];
  logic [EW-1:0] ebase_r;

  logic [SW-1:0] sum_r;
  logic          sticky_r;

  logic [SW-1:0] norm_r;
  logic [EW-1:0] elead_r;
  logic          sign_r;
  logic          zero_r;

  // FDIV/FSQRT iteration
  logic [59:0]   it_rem_r;
  logic [55:0]   it_q_r;
  logic [109:0]  it_x_r;
  logic [52:0]   it_b_r;
  logic [6:0]    it_cnt_r;
  logic          it_sqrt_r;
  logic          it_sign_r;
  logic [EW-1:0] it_e_r;

  // FSINA/FCOSA polynomial
  logic [31:0]   pl_acc_r, pl_v_r, pl_u_r;
  logic [2:0]    pl_step_r;
  logic          pl_cos_r;
  logic          pl_sign_r;

  assign ready_o  = (state_r == S_IDLE);
  assign done_o   = done_r;
  assign tag_o    = tag_r;
  assign result_o = res_r;
  assign cause_o  = cause_r;

  // ------------------------------------------------------------------------
  // PREP: classify the registered operands, decide special cases, form terms
  kind_t         ekind;            // effective kind (FSRRA pass 2 divides)
  logic [63:0]   opa, opb;
  fpc_t          A, B, C;
  fpc_t          g_c [4];
  fpc_t          h_c [4];
  iprc_t         p_c;
  spec_t         spec_c;
  dec_t          edec;
  logic [105:0]  prod_big;
  logic [47:0]   prod_v [4];
  term_t         t_c [4];
  logic [EW-1:0] psm1;             // source precision - 1
  logic [63:0]   int_c, mag_c;
  logic          zsign_c, allzero_c;
  logic          it_odd;
  logic [15:0]   ang;
  logic [14:0]   red;
  logic          use_cos_theta, use_c_poly, pl_sign_c;

  always_comb begin
    ekind = dec_r.kind;
    if (dec_r.kind == K_SRRA) ekind = srra_div_r ? K_DIV : K_SQRT;
    // special cases of FSRRA.S are its own (Vol. 2 FSRRA.S table); the second
    // pass is a plain division of 1.0 by a positive normalized number
    edec = dec_r;
    if (srra_div_r) edec.kind = K_DIV;
    opa = srra_div_r ? 64'h0000_0000_3F80_0000 : ra_r;
    opb = srra_div_r ? {32'd0, pass_r} : rb_r;
    A = unpack(opa, dec_r.sd, dn_r);
    B = unpack(opb, dec_r.sd, dn_r);
    C = unpack(rc_r, 1'b0, dn_r);
    for (int i = 0; i < 4; i++) begin
      if (dec_r.kind == K_TRV) begin
        g_c[i] = unpack({32'd0, rm_m_r[32 * ({3'd0, row_r} + 5'd4 * 5'(i)) +: 32]}, 1'b0, dn_r);
        h_c[i] = unpack({32'd0, rva_r[32*i +: 32]}, 1'b0, dn_r);
      end else begin
        g_c[i] = unpack({32'd0, rva_r[32*i +: 32]}, 1'b0, dn_r);
        h_c[i] = unpack({32'd0, rvb_r[32*i +: 32]}, 1'b0, dn_r);
      end
      prod_v[i] = {24'd0, g_c[i].sig[23:0]} * {24'd0, h_c[i].sig[23:0]};
    end
    p_c = ipr_classify(g_c[0], g_c[1], g_c[2], g_c[3], h_c[0], h_c[1], h_c[2], h_c[3]);
    spec_c = specials(edec, A, B, C, p_c, opa, opb);
    prod_big = {53'd0, A.sig} * {53'd0, B.sig};
    psm1 = dec_r.sd ? EW'(52) : EW'(23);

    int_c = dec_r.i64 ? ra_r : {{32{ra_r[31]}}, ra_r[31:0]};
    mag_c = int_c[63] ? -int_c : int_c;

    for (int i = 0; i < 4; i++)
      t_c[i] = '{nz: 1'b0, used: 1'b0, sign: 1'b0, e: '0, m: '0};
    case (ekind)
      K_ADD, K_SUB: begin
        t_c[0] = '{nz: ~A.zero, used: 1'b1, sign: A.sign, e: A.e - psm1, m: {53'd0, A.sig}};
        t_c[1] = '{nz: ~B.zero, used: 1'b1, sign: B.sign ^ (ekind == K_SUB), e: B.e - psm1, m: {53'd0, B.sig}};
      end
      K_MUL: begin
        t_c[0] = '{nz: ~(A.zero | B.zero), used: 1'b1, sign: A.sign ^ B.sign,
                   e: A.e + B.e - psm1 - psm1, m: prod_big};
      end
      K_MAC: begin
        t_c[0] = '{nz: ~(A.zero | B.zero), used: 1'b1, sign: A.sign ^ B.sign,
                   e: A.e + B.e - EW'(46), m: prod_big};
        t_c[1] = '{nz: ~C.zero, used: 1'b1, sign: C.sign, e: C.e - EW'(23), m: {53'd0, C.sig}};
      end
      K_CNV: begin
        t_c[0] = '{nz: ~A.zero, used: 1'b1, sign: A.sign, e: A.e - psm1, m: {53'd0, A.sig}};
      end
      K_FLOAT: begin
        t_c[0] = '{nz: (int_c != 64'd0), used: 1'b1, sign: int_c[63], e: '0, m: {42'd0, mag_c}};
      end
      K_IPR, K_TRV: begin
        for (int i = 0; i < 4; i++)
          t_c[i] = '{nz: ~(g_c[i].zero | h_c[i].zero), used: 1'b1, sign: g_c[i].sign ^ h_c[i].sign,
                     e: g_c[i].e + h_c[i].e - EW'(46), m: {58'd0, prod_v[i]}};
      end
      default: ;
    endcase
    allzero_c = 1'b1;
    zsign_c = 1'b1;
    for (int i = 0; i < 4; i++) begin
      if (t_c[i].nz) allzero_c = 1'b0;
      if (t_c[i].used & ~t_c[i].sign) zsign_c = 1'b0;
    end

    // FSQRT: an odd exponent is made even by doubling the significand
    it_odd = A.e[0];

    // FSINA/FCOSA: angle in 1/65536 turn; quadrant ang[15:14], octant red[13]
    ang = ra_r[15:0];
    red = ang[13] ? (15'd16384 - {1'b0, ang[13:0]}) : {1'b0, ang[13:0]};
    // sin(q*90 + t) and cos(q*90 + t) in terms of sin t / cos t
    use_cos_theta = (dec_r.kind == K_SINA) ? ang[14] : ~ang[14];
    pl_sign_c     = (dec_r.kind == K_SINA) ? ang[15] : (ang[15] ^ ang[14]);
    // octant: sin t = cos(90 - t)
    use_c_poly = ang[13] ? ~use_cos_theta : use_cos_theta;
  end

  // ------------------------------------------------------------------------
  // ALIGN: shift every term to the LSB exponent of the leading term
  logic [EW-1:0] emax_c;
  logic [W-1:0]  al_c [4];
  logic          st_c [4];
  logic [EW-1:0] ebase_c;

  always_comb begin
    emax_c = EW'(-32768);
    for (int i = 0; i < 4; i++)
      if (term_r[i].nz && $signed(term_r[i].e) > $signed(emax_c)) emax_c = term_r[i].e;
    ebase_c = emax_c - EW'(G);
    for (int i = 0; i < 4; i++) begin : align_term
      logic [EW-1:0] d;
      logic [7:0]    dc;
      logic [W-1:0]  placed, mask;
      d = emax_c - term_r[i].e;
      dc = ($signed(d) > EW'(255)) ? 8'd255 : d[7:0];
      placed = {term_r[i].m, {G{1'b0}}};
      mask = ~({W{1'b1}} << dc);
      if (term_r[i].nz) begin
        al_c[i] = placed >> dc;
        st_c[i] = |(placed & mask);
      end else begin
        al_c[i] = '0;
        st_c[i] = 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------------
  // SUM: two's complement sum.  A negative term whose shifted-out bits are
  // non-zero is represented by its one's complement, so that the sum is the
  // floor of the exact value and the sticky bit marks a non-zero fraction.
  logic [SW-1:0] sum_c;
  always_comb begin
    sum_c = '0;
    for (int i = 0; i < 4; i++) begin : sum_term
      logic [SW-1:0] ext;
      ext = {3'd0, al_r[i]};
      if (neg_r[i]) sum_c = sum_c + ~ext + {{(SW-1){1'b0}}, ~st_r[i]};
      else          sum_c = sum_c + ext;
    end
  end

  // ------------------------------------------------------------------------
  // NORM
  logic          nsign_c;
  logic [SW-1:0] mag_n_c, norm_c;
  logic [7:0]    lzc_c;
  logic [EW-1:0] elead_c;
  always_comb begin
    nsign_c = sum_r[SW-1];
    mag_n_c = nsign_c ? (sticky_r ? ~sum_r : -sum_r) : sum_r;
    lzc_c = lzc_sw(mag_n_c);
    norm_c = mag_n_c << lzc_c;
    elead_c = ebase_r + EW'(SW - 1) - EW'(lzc_c);
  end

  // ------------------------------------------------------------------------
  // ROUND
  logic [63:0]   rres_c;
  logic [5:0]    rcause_c;
  always_comb begin : round_blk
    logic          dd, rn;
    logic [EW-1:0] emin, emaxf, bias, below, eres;
    logic [7:0]    sh;
    logic [SW-1:0] v, v2, n2, mask;
    logic          lost, lost2, n2lost;
    logic [52:0]   m, m0;
    logic          rb, rest, rb0, rest0, inexact, rup, rup0, allones, unb_carry, tiny, carry, minnorm;
    logic [53:0]   m1;
    logic [51:0]   mant;
    logic [10:0]   expf;
    logic          force_i;

    dd = dec_r.dd;
    rn = ~rm_r;
    emin  = dd ? EW'(-1022) : EW'(-126);
    emaxf = dd ? EW'(1023) : EW'(127);
    bias  = dd ? EW'(1023) : EW'(127);
    force_i = (dec_r.kind == K_IPR) | (dec_r.kind == K_TRV) | (dec_r.kind == K_SINA) |
              (dec_r.kind == K_COSA) | (dec_r.kind == K_SRRA);

    // tiny range: pre-shift into the denormalized grid
    below = emin - elead_r;
    if ($signed(below) > EW'(0)) sh = ($signed(below) > EW'(255)) ? 8'd255 : below[7:0];
    else                         sh = 8'd0;
    mask = ~({SW{1'b1}} << sh);
    v = norm_r >> sh;
    lost = |(norm_r & mask);
    v2 = dd ? v : (v >> 29);
    lost2 = dd ? 1'b0 : |v[28:0];
    m = v2[SW-1 -: 53];
    rb = v2[SW-54];
    rest = (|v2[SW-55:0]) | lost2 | lost | sticky_r;
    inexact = rb | rest;
    rup = rn & rb & (rest | m[0]);
    m1 = {1'b0, m} + {53'd0, rup};

    // rounding with an unbounded exponent range, for tininess after rounding
    n2 = dd ? norm_r : (norm_r >> 29);
    n2lost = dd ? 1'b0 : |norm_r[28:0];
    m0 = n2[SW-1 -: 53];
    rb0 = n2[SW-54];
    rest0 = (|n2[SW-55:0]) | n2lost | sticky_r;
    rup0 = rn & rb0 & (rest0 | m0[0]);
    allones = dd ? (&m0) : (&m0[23:0]);
    unb_carry = allones & rup0;
    tiny = (sh != 8'd0) & ~((below == EW'(1)) & unb_carry);

    carry = dd ? m1[53] : m1[24];
    minnorm = dd ? m1[52] : m1[23];
    mant = carry ? m1[52:1] : m1[51:0];
    eres = elead_r + EW'(carry);
    expf = 11'(eres + bias);

    rres_c = '0;
    rcause_c = '0;
    if (zero_r) begin
      rres_c = fp_zero(allzero_r & zsign_r, dd);
    end else if (sh == 8'd0) begin
      if ($signed(eres) > $signed(emaxf)) begin
        rres_c = rn ? fp_inf(sign_r, dd) : fp_maxfinite(sign_r, dd);
        rcause_c = C_O | C_I;
      end else begin
        rres_c = dd ? {sign_r, expf, mant} : {32'd0, sign_r, expf[7:0], mant[22:0]};
        rcause_c = inexact ? C_I : '0;
      end
    end else if (minnorm) begin
      rres_c = dd ? {sign_r, 11'd1, 52'd0} : {32'd0, sign_r, 8'd1, 23'd0};
      rcause_c = tiny ? (C_U | C_I) : C_I;
    end else if (dn_r) begin
      rres_c = fp_zero(sign_r, dd);
      rcause_c = C_U | C_I;
    end else begin
      rres_c = dd ? {sign_r, 11'd0, m1[51:0]} : {32'd0, sign_r, 8'd0, m1[22:0]};
      rcause_c = inexact ? (C_U | C_I) : '0;
    end
    if (force_i) rcause_c = rcause_c | C_I;
  end

  // ------------------------------------------------------------------------
  // FDIV/FSQRT step (radix-2 restoring)
  logic [59:0]  it_rem_n;
  logic [55:0]  it_q_n;
  logic [109:0] it_x_n;
  always_comb begin : iter_blk
    logic [59:0] t, trial, bext;
    t = {it_rem_r[57:0], it_x_r[109:108]};
    trial = {2'd0, it_q_r, 2'b01};
    bext = {7'd0, it_b_r};
    if (it_sqrt_r) begin
      if (t >= trial) begin
        it_rem_n = t - trial;
        it_q_n = {it_q_r[54:0], 1'b1};
      end else begin
        it_rem_n = t;
        it_q_n = {it_q_r[54:0], 1'b0};
      end
      it_x_n = {it_x_r[107:0], 2'b00};
    end else begin
      if (it_rem_r >= bext) begin
        it_rem_n = (it_rem_r - bext) << 1;
        it_q_n = {it_q_r[54:0], 1'b1};
      end else begin
        it_rem_n = it_rem_r << 1;
        it_q_n = {it_q_r[54:0], 1'b0};
      end
      it_x_n = it_x_r;
    end
  end

  // ------------------------------------------------------------------------
  // FSINA/FCOSA polynomial step (Horner, one Q2.30 multiply per cycle)
  logic [31:0] pl_acc_n, pl_v_n;
  always_comb begin : poly_blk
    logic [31:0] coef;
    logic last_sin;
    coef = '0;
    last_sin = ~pl_cos_r & (pl_step_r == 3'd5);
    case (pl_step_r)
      3'd1: coef = pl_cos_r ? PD4 : PC3;
      3'd2: coef = pl_cos_r ? PD3 : PC2;
      3'd3: coef = pl_cos_r ? PD2 : PC1;
      3'd4: coef = pl_cos_r ? PD1 : PC0;
      3'd5: coef = pl_cos_r ? PD0 : '0;
      default: ;
    endcase
    pl_v_n = pl_v_r;
    pl_acc_n = pl_acc_r;
    if (pl_step_r == 3'd0) begin
      pl_v_n = qmul(pl_u_r, pl_u_r);
      pl_acc_n = pl_cos_r ? PD5 : PC4;
    end else if (last_sin) begin
      pl_acc_n = qmul(pl_acc_r, pl_u_r);
    end else begin
      pl_acc_n = qmul(pl_acc_r, pl_v_r) + coef;
    end
  end

  // ------------------------------------------------------------------------
  // Control
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
      done_r <= 1'b0;
      res_r <= '0;
      cause_r <= '0;
      cause_acc_r <= '0;
      tag_r <= '0;
      dec_r <= '{kind: K_NONE, sd: 1'b0, dd: 1'b0, i64: 1'b0};
      rm_r <= 1'b0;
      dn_r <= 1'b0;
      ra_r <= '0;
      rb_r <= '0;
      rc_r <= '0;
      rva_r <= '0;
      rvb_r <= '0;
      rm_m_r <= '0;
      row_r <= 2'd0;
      srra_div_r <= 1'b0;
      pass_r <= '0;
      for (int i = 0; i < 4; i++) begin
        term_r[i] <= '{nz: 1'b0, used: 1'b0, sign: 1'b0, e: '0, m: '0};
        al_r[i] <= '0;
        st_r[i] <= 1'b0;
        neg_r[i] <= 1'b0;
      end
      zsign_r <= 1'b0;
      allzero_r <= 1'b0;
      xsticky_r <= 1'b0;
      ebase_r <= '0;
      sum_r <= '0;
      sticky_r <= 1'b0;
      norm_r <= '0;
      elead_r <= '0;
      sign_r <= 1'b0;
      zero_r <= 1'b0;
      it_rem_r <= '0;
      it_q_r <= '0;
      it_x_r <= '0;
      it_b_r <= '0;
      it_cnt_r <= '0;
      it_sqrt_r <= 1'b0;
      it_sign_r <= 1'b0;
      it_e_r <= '0;
      pl_acc_r <= '0;
      pl_v_r <= '0;
      pl_u_r <= '0;
      pl_step_r <= '0;
      pl_cos_r <= 1'b0;
      pl_sign_r <= 1'b0;
    end else begin
      case (state_r)
        S_IDLE: begin
          done_r <= 1'b0;
          if (issue_i) begin
            dec_r <= dec_i;
            tag_r <= tag_i;
            rm_r <= fpscr_i[FPSCR_RM];
            dn_r <= fpscr_i[FPSCR_DN];
            ra_r <= a_i;
            rb_r <= b_i;
            rc_r <= c_i;
            rva_r <= va_i;
            rvb_r <= vb_i;
            rm_m_r <= mtrx_i;
            row_r <= 2'd0;
            srra_div_r <= 1'b0;
            cause_acc_r <= '0;
            res_r <= '0;
            state_r <= S_PREP;
          end
        end

        S_PREP: begin
          xsticky_r <= 1'b0;
          for (int i = 0; i < 4; i++) term_r[i] <= t_c[i];
          zsign_r <= zsign_c;
          allzero_r <= allzero_c;
          if (spec_c.valid) begin
            // result decided by the operand classes
            if (dec_r.kind == K_TRV) begin
              res_r[32 * row_r +: 32] <= spec_c.res[31:0];
              cause_acc_r <= cause_acc_r | spec_c.cause;
              if (row_r == 2'd3) begin
                cause_r <= cause_acc_r | spec_c.cause;
                done_r <= 1'b1;
                state_r <= S_IDLE;
              end else begin
                row_r <= row_r + 2'd1;
              end
            end else begin
              res_r <= {64'd0, spec_c.res};
              cause_r <= spec_c.cause;
              done_r <= 1'b1;
              state_r <= S_IDLE;
            end
          end else begin
            case (ekind)
              K_DIV: begin
                it_sqrt_r <= 1'b0;
                it_rem_r <= {7'd0, A.sig};
                it_b_r <= B.sig;
                it_q_r <= '0;
                it_cnt_r <= dec_r.sd ? 7'd55 : 7'd26;
                it_sign_r <= A.sign ^ B.sign;
                it_e_r <= A.e - B.e - psm1 - EW'(2);
                state_r <= S_ITER;
              end
              K_SQRT: begin
                it_sqrt_r <= 1'b1;
                it_rem_r <= '0;
                it_q_r <= '0;
                it_x_r <= dec_r.sd ? ({57'd0, A.sig} << (it_odd ? 57 : 56))
                                   : ({57'd0, A.sig} << (it_odd ? 86 : 85));
                it_cnt_r <= dec_r.sd ? 7'd55 : 7'd26;
                it_sign_r <= 1'b0;
                it_e_r <= EW'($signed(A.e) >>> 1) - psm1 - EW'(2);
                state_r <= S_ITER;
              end
              K_SINA, K_COSA: begin
                pl_u_r <= {red, 17'd0};
                pl_cos_r <= use_c_poly;
                pl_sign_r <= pl_sign_c;
                pl_step_r <= 3'd0;
                state_r <= S_POLY;
              end
              default: state_r <= S_ALIGN;
            endcase
          end
        end

        S_ITER: begin
          it_rem_r <= it_rem_n;
          it_q_r <= it_q_n;
          it_x_r <= it_x_n;
          it_cnt_r <= it_cnt_r - 7'd1;
          if (it_cnt_r == 7'd1) begin
            term_r[0] <= '{nz: 1'b1, used: 1'b1, sign: it_sign_r, e: it_e_r, m: {50'd0, it_q_n}};
            allzero_r <= 1'b0;
            xsticky_r <= (it_rem_n != 60'd0);
            state_r <= S_ALIGN;
          end
        end

        S_POLY: begin
          pl_acc_r <= pl_acc_n;
          pl_v_r <= pl_v_n;
          pl_step_r <= pl_step_r + 3'd1;
          if (pl_step_r == 3'd5) begin
            term_r[0] <= '{nz: (pl_acc_n[30:0] != 31'd0), used: 1'b1, sign: pl_sign_r,
                           e: EW'(-30), m: {75'd0, pl_acc_n[30:0]}};
            allzero_r <= (pl_acc_n[30:0] == 31'd0);
            zsign_r <= pl_sign_r;
            state_r <= S_ALIGN;
          end
        end

        S_ALIGN: begin
          for (int i = 0; i < 4; i++) begin
            al_r[i] <= al_c[i];
            st_r[i] <= st_c[i];
            neg_r[i] <= term_r[i].sign & term_r[i].nz;
          end
          // the remainder of FDIV/FSQRT is a non-zero fraction of term 0
          st_r[0] <= st_c[0] | xsticky_r;
          ebase_r <= ebase_c;
          state_r <= S_SUM;
        end

        S_SUM: begin
          sum_r <= sum_c;
          sticky_r <= st_r[0] | st_r[1] | st_r[2] | st_r[3];
          state_r <= S_NORM;
        end

        S_NORM: begin
          norm_r <= norm_c;
          elead_r <= elead_c;
          sign_r <= nsign_c;
          zero_r <= (mag_n_c == '0);
          state_r <= S_ROUND;
        end

        S_ROUND: begin
          if (dec_r.kind == K_TRV) begin
            res_r[32 * row_r +: 32] <= rres_c[31:0];
            cause_acc_r <= cause_acc_r | rcause_c;
            if (row_r == 2'd3) begin
              cause_r <= cause_acc_r | rcause_c;
              done_r <= 1'b1;
              state_r <= S_IDLE;
            end else begin
              row_r <= row_r + 2'd1;
              state_r <= S_PREP;
            end
          end else if (dec_r.kind == K_SRRA && !srra_div_r) begin
            pass_r <= rres_c[31:0];
            srra_div_r <= 1'b1;
            state_r <= S_PREP;
          end else begin
            res_r <= {64'd0, rres_c};
            cause_r <= rcause_c;
            done_r <= 1'b1;
            state_r <= S_IDLE;
          end
        end

        default: state_r <= S_IDLE;
      endcase
    end
  end

endmodule
