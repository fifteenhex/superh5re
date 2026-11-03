// SH-5 core: pipeline F1 F2 D E1 E2 E3 W (docs/core-design.md).
// This revision runs with the MMU off: no caches, no TLB lookup, every
// memory access is a single bus word.

module sh5_core
  import sh5_pkg::*;
  import sh5_uop_pkg::*;
  import shwy_pkg::*;
#(
  parameter bit          FPU_PRESENT    = 1'b1,
  parameter int          TID_BITS       = 3,
  parameter logic [7:0]  BUS_SRC_ID     = 8'h0d,
  parameter logic [15:0] MODULE_ID      = 16'h51e2,
  parameter logic [15:0] MODULE_VERSION = 16'h0001,
  parameter int          ICACHE_WAYS    = CACHE_WAYS,
  parameter int          ICACHE_SETS    = CACHE_SETS,
  parameter int          DCACHE_WAYS    = CACHE_WAYS,
  parameter int          DCACHE_SETS    = CACHE_SETS,
  parameter int          ITLB_ENTRIES   = 64,
  parameter int          DTLB_ENTRIES   = 64
) (
  input  logic        clk,
  input  logic        rst_n,          // power-on reset (POWERON)
  input  logic [31:0] reset_pc_i,     // PC after power-on reset (Vol. 1 16.6.1 allows a system override of 0)

  input  logic        big_endian_i,

  // Asynchronous events (Vol. 1 16.2)
  input  logic        cpu_reset_i,
  input  logic        nmi_i,
  input  logic        debugint_i,
  input  logic        extint_valid_i,
  input  logic [3:0]  extint_level_i,
  input  logic [31:0] extint_code_i,
  output logic        extint_ack_o,
  output logic [3:0]  extint_ack_level_o,
  input  logic [31:0] dbrvec_i,
  input  logic        dbrmode_i,
  output logic        sleep_o,
  output logic        bus_error_o,

  // Debug watchpoints (later)
  input  logic        dbg_ia_hit_i,
  input  logic        dbg_iv_hit_i,
  input  logic        dbg_oa_hit_i,
  output logic [31:0] dbg_fetch_addr_o,
  output logic [31:0] dbg_insn_o,
  output logic [31:0] dbg_op_addr_o,
  output logic        dbg_op_valid_o,

  // Commit trace (simulation aid)
  output logic        trace_valid_o,
  output logic [31:0] trace_pc_o,
  output logic [31:0] trace_insn_o,
  output logic        trace_gpr_we_o,
  output logic [5:0]  trace_gpr_idx_o,
  output logic [63:0] trace_gpr_val_o,
  output logic        trace_fpu_we_o,     // asynchronous FPU writeback this cycle
  output logic [5:0]  trace_fpu_idx_o,
  output logic [127:0] trace_fpu_val_o,

  // Bus initiator
  output logic        ireq_valid,
  input  logic        ireq_ready,
  output logic [7:0]  ireq_opc,
  output logic [31:0] ireq_addr,
  output logic [7:0]  ireq_src,
  output logic [7:0]  ireq_tid,
  output logic [7:0]  ireq_mask,
  output logic [63:0] ireq_data,
  output logic        ireq_last,
  input  logic        irsp_valid,
  output logic        irsp_ready,
  input  logic [7:0]  irsp_opc,
  input  logic [7:0]  irsp_src,
  input  logic [7:0]  irsp_tid,
  input  logic [63:0] irsp_data,
  input  logic        irsp_last,

  // Bus target (VCR)
  input  logic        treq_valid,
  output logic        treq_ready,
  input  logic [7:0]  treq_opc,
  input  logic [31:0] treq_addr,
  input  logic [7:0]  treq_src,
  input  logic [7:0]  treq_tid,
  input  logic [7:0]  treq_mask,
  input  logic [63:0] treq_data,
  input  logic        treq_last,
  output logic        trsp_valid,
  input  logic        trsp_ready,
  output logic [7:0]  trsp_opc,
  output logic [7:0]  trsp_src,
  output logic [7:0]  trsp_tid,
  output logic [63:0] trsp_data,
  output logic        trsp_last
);

  // ===================================================================
  // Register files
  logic [63:0] gr_q [64];
  logic [31:0] tr_q [8];
  logic [31:0] fr_q [64];

  function automatic logic [63:0] gr_rd(input logic [5:0] i);
    gr_rd = (i == 6'd63) ? 64'h0 : gr_q[i];
  endfunction

  function automatic logic [63:0] sext32(input logic [31:0] v);
    sext32 = {{32{v[31]}}, v};
  endfunction

  // FR reads: width 0 = FR, 1 = DR (FR[g&~1] high half), 2 = FV, 3 = MTRX
  function automatic logic [63:0] fr_rd64(input logic [5:0] g, input logic [1:0] w);
    if (w == 2'd0) fr_rd64 = {32'h0, fr_q[g]};
    else           fr_rd64 = {fr_q[{g[5:1], 1'b0}], fr_q[{g[5:1], 1'b1}]};
  endfunction

  function automatic logic [127:0] fr_rd128(input logic [5:0] g);
    logic [5:0] b;
    b = {g[5:2], 2'b00};
    fr_rd128 = {fr_q[b + 6'd3], fr_q[b + 6'd2], fr_q[b + 6'd1], fr_q[b]};
  endfunction

  function automatic logic [511:0] fr_rd512(input logic [5:0] g);
    logic [5:0] b;
    b = {g[5:4], 4'b0000};
    for (int k = 0; k < 16; k++) fr_rd512[32*k +: 32] = fr_q[b + 6'(k)];
  endfunction

  // 64-bit mask of FR indices touched by a write of mode fw at f
  function automatic logic [63:0] fr_mask(input logic [5:0] f, input fwmode_t fw);
    case (fw)
      FW_32:   fr_mask = 64'h1 << f;
      FW_64, FW_PAIR: fr_mask = 64'h3 << {f[5:1], 1'b0};
      default: fr_mask = 64'hf << {f[5:2], 2'b00};
    endcase
  endfunction

  function automatic logic [63:0] fr_rmask(input logic [5:0] f, input logic [1:0] w);
    case (w)
      2'd0:    fr_rmask = 64'h1 << f;
      2'd1:    fr_rmask = 64'h3 << {f[5:1], 1'b0};
      2'd2:    fr_rmask = 64'hf << {f[5:2], 2'b00};
      default: fr_rmask = 64'hffff << {f[5:4], 4'b0000};
    endcase
  endfunction

  // ===================================================================
  // Control block
  logic [31:0] sr, fpscr;
  logic        ctrl_isa;
  logic [31:0] iccr0, occr0;
  logic [5:0]  getcon_idx;
  logic [63:0] getcon_val;
  logic        putcon_en;
  logic [5:0]  putcon_idx;
  logic [63:0] putcon_val;
  logic [31:0] getcfg_idx;
  logic [63:0] getcfg_val;
  logic        putcfg_en;
  logic [31:0] putcfg_idx;
  logic [63:0] putcfg_val;
  logic        fputscr_en;
  logic [31:0] fputscr_val;
  logic        fpu_done;
  logic [5:0]  fpu_cause;
  logic [7:0]  usr_set_gprs, usr_set_fprs;
  logic        launch_en, launch_is_irq, launch_is_reset, launch_tea_valid;
  logic [11:0] launch_code;
  logic [3:0]  launch_irq_level;
  logic [31:0] launch_irq_code, launch_pc, launch_tea, launch_tra;
  logic        rte_en;
  logic [31:0] ctrl_new_pc;

  sh5_ctrl #(.FPU_PRESENT(FPU_PRESENT), .TLB_ENTRIES(DTLB_ENTRIES)) u_ctrl (
    .clk, .rst_n,
    .sr_o(sr), .fpscr_o(fpscr), .isa_o(ctrl_isa), .iccr0_o(iccr0), .occr0_o(occr0),
    .getcon_idx_i(getcon_idx), .getcon_val_o(getcon_val),
    .putcon_en_i(putcon_en), .putcon_idx_i(putcon_idx), .putcon_val_i(putcon_val),
    .getcfg_idx_i(getcfg_idx), .getcfg_val_o(getcfg_val),
    .putcfg_en_i(putcfg_en), .putcfg_idx_i(putcfg_idx), .putcfg_val_i(putcfg_val),
    .fputscr_en_i(fputscr_en), .fputscr_val_i(fputscr_val),
    .fpu_done_i(fpu_done), .fpu_cause_i(fpu_cause),
    .usr_set_gprs_i(usr_set_gprs), .usr_set_fprs_i(usr_set_fprs),
    .launch_en_i(launch_en), .launch_code_i(launch_code), .launch_is_irq_i(launch_is_irq),
    .launch_is_reset_i(launch_is_reset), .launch_irq_level_i(launch_irq_level),
    .launch_irq_code_i(launch_irq_code), .launch_pc_i(launch_pc),
    .launch_tea_valid_i(launch_tea_valid), .launch_tea_i(launch_tea), .launch_tra_i(launch_tra),
    .rte_en_i(rte_en), .new_pc_o(ctrl_new_pc),
    .dbrvec_i, .dbrmode_i
  );

  // ===================================================================
  // Bus interface unit
  logic        if_req_valid, if_req_ready, if_rsp_valid;
  logic [31:3] if_req_addr;
  logic [63:0] if_rsp_data;
  logic        ld_req_valid, ld_req_ready, ld_req_swap, ld_rsp_valid;
  logic [31:3] ld_req_addr;
  logic [7:0]  ld_req_mask;
  logic [63:0] ld_req_data, ld_rsp_data;
  logic        st_req_valid, st_req_ready, st_pending;
  logic [31:3] st_req_addr;
  logic [7:0]  st_req_mask;
  logic [63:0] st_req_data;

  sh5_biu #(.TID_BITS(TID_BITS), .BUS_SRC_ID(BUS_SRC_ID)) u_biu (
    .clk, .rst_n,
    .if_req_valid_i(if_req_valid), .if_req_ready_o(if_req_ready), .if_req_addr_i(if_req_addr),
    .if_rsp_valid_o(if_rsp_valid), .if_rsp_data_o(if_rsp_data),
    .ld_req_valid_i(ld_req_valid), .ld_req_ready_o(ld_req_ready), .ld_req_swap_i(ld_req_swap),
    .ld_req_addr_i(ld_req_addr), .ld_req_mask_i(ld_req_mask), .ld_req_data_i(ld_req_data),
    .ld_rsp_valid_o(ld_rsp_valid), .ld_rsp_data_o(ld_rsp_data),
    .st_req_valid_i(st_req_valid), .st_req_ready_o(st_req_ready), .st_req_addr_i(st_req_addr),
    .st_req_mask_i(st_req_mask), .st_req_data_i(st_req_data), .st_pending_o(st_pending),
    .bus_error_o,
    .ireq_valid, .ireq_ready, .ireq_opc, .ireq_addr, .ireq_src, .ireq_tid, .ireq_mask,
    .ireq_data, .ireq_last,
    .irsp_valid, .irsp_ready, .irsp_opc, .irsp_src, .irsp_tid, .irsp_data, .irsp_last
  );

  // ===================================================================
  // Fetch
  logic        redirect, flush;
  logic [31:0] redirect_pc;
  logic        fetch_en;
  logic        if_insn_valid, if_consume;
  logic [31:0] if_insn, if_insn_pc;
  logic        sleeping_q;
  logic        reset_q;         // first cycle after reset: start fetching at reset_pc_i

  sh5_ifu u_ifu (
    .clk, .rst_n,
    .redirect_i(redirect), .redirect_pc_i(redirect_pc), .fetch_en_i(fetch_en),
    .insn_valid_o(if_insn_valid), .insn_o(if_insn), .insn_pc_o(if_insn_pc), .consume_i(if_consume),
    .req_valid_o(if_req_valid), .req_ready_i(if_req_ready), .req_addr_o(if_req_addr),
    .rsp_valid_i(if_rsp_valid), .rsp_data_i(if_rsp_data)
  );

  assign fetch_en = !sleeping_q && !reset_q;

  // ===================================================================
  // Pipeline stage payload
  typedef struct packed {
    uop_t        u;
    logic [63:0] a, b, c;        // GPR source values read in D (ra, rb, rc)
    logic [31:0] trv;            // TR source value read in D
    logic [63:0] fa, fb, fc;     // FR source values (32 or 64 bits)
    logic [63:0] res;            // result or value carried to W
    logic [31:0] ea;             // effective address
    logic [63:0] sdata;          // store data placed in bus lanes
    logic [7:0]  smask;
    logic        fpu_trap;       // FPUEXC: wait for the FPU to drain at W
  } pstage_t;

  pstage_t e1_q, e2_q, e3_q, w_q;
  logic [127:0] e1_va_q, e1_vb_q;
  logic [511:0] e1_mtrx_q;

  logic hold, advance;
  logic hold_e1, hold_e2, hold_e3, hold_w;
  logic e1_fpu_issued_q, e1_redir_done_q, e2_issued_q, e3_have_q, w_acted_q;
  logic [63:0] e3_data_q;

  // writeback forwarding registers (values written to GR / TR last cycle)
  logic        wb_valid_q;
  logic [5:0]  wb_idx_q;
  logic [63:0] wb_val_q;
  logic        wbt_valid_q;
  logic [2:0]  wbt_idx_q;
  logic [31:0] wbt_val_q;

  // FPU scoreboard
  logic [63:0] fr_busy_q, gr_busy_q;

  // ===================================================================
  // D: decode, hazards, operand read
  uop_t d_uop_raw, d_uop;
  logic d_valid, d_stall, d_issue, serial_block_q;
  logic isa_compact;
  logic blink_compact_q;

  assign isa_compact = !ctrl_isa || blink_compact_q;

  sh5_decode u_dec (
    .insn_i(if_insn), .pc_i(if_insn_pc),
    .priv_i(sr[SR_MD]), .fpu_dis_i(sr[SR_FD] || !FPU_PRESENT),
    .isa_compact_i(isa_compact),
    .uop_o(d_uop_raw)
  );

  // interrupt acceptance from the current SR (Vol. 1 16.10)
  logic irq_nmi, irq_dbg, irq_ext, irq_any;
  assign irq_nmi = nmi_i;
  assign irq_dbg = debugint_i && !sr[SR_BL];
  assign irq_ext = extint_valid_i && !sr[SR_BL] && (extint_level_i > sr[SR_IMASK +: 4]);
  assign irq_any = cpu_reset_i || irq_nmi || irq_dbg || irq_ext;

  always_comb begin
    d_uop = d_uop_raw;
    if (irq_any) begin
      d_uop.cls = UC_EXC;
      d_uop.wr_gpr = 1'b0; d_uop.wr_tr = 1'b0; d_uop.wr_fr = 1'b0;
      d_uop.rd_fa = 1'b0; d_uop.rd_fb = 1'b0; d_uop.rd_fc = 1'b0; d_uop.rd_tr = 1'b0;
      d_uop.serialize = 1'b1;
      d_uop.exc_is_irq = !cpu_reset_i;
      d_uop.exc_is_reset = cpu_reset_i;
      d_uop.irq_level = extint_level_i;
      d_uop.imm = {32'h0, extint_code_i};
      if (cpu_reset_i)      d_uop.exc = EVT_CPURESET;
      else if (irq_nmi)     d_uop.exc = EVT_NMI;
      else if (irq_dbg)     d_uop.exc = EVT_INT_DEBUGINT;
      else                  d_uop.exc = EVT_INT_EXTINT;
    end
  end

  // a redirect from E1 or W kills the instruction in decode
  assign d_valid = if_insn_valid && !serial_block_q && !sleeping_q && !flush && !e1_redirect;

  // GPR hazards: long-latency producers in E1/E2, FPU results pending
  logic uses_rc;
  assign uses_rc = (d_uop.cls == UC_STORE) || (d_uop.cls == UC_SWAP) || (d_uop.cls == UC_PUTCON) ||
                   (d_uop.cls == UC_PUTCFG) || (d_uop.cls == UC_MM) ||
                   (d_uop.cls == UC_ALU && (d_uop.alu == A_CMVEQ || d_uop.alu == A_CMVNE || d_uop.alu == A_SHORI));

  function automatic logic gpr_hazard(input logic [5:0] src);
    gpr_hazard = (src != 6'd63) &&
                 ((e1_q.u.valid && e1_q.u.wr_gpr && e1_q.u.long_lat && e1_q.u.rd == src) ||
                  (e2_q.u.valid && e2_q.u.wr_gpr && e2_q.u.long_lat && e2_q.u.rd == src) ||
                  gr_busy_q[src]);
  endfunction

  logic [63:0] fr_rdmask, fr_wrmask, fr_inflight;
  logic fpu_fifo_empty;
  always_comb begin
    fr_rdmask = '0;
    if (d_uop.rd_fa) fr_rdmask |= fr_rmask(d_uop.fa, d_uop.fa_w);
    if (d_uop.rd_fb) fr_rdmask |= fr_rmask(d_uop.fb, d_uop.fb_w);
    if (d_uop.rd_fc) fr_rdmask |= fr_rmask(d_uop.fc, d_uop.fc_w);
    fr_wrmask = d_uop.wr_fr ? fr_mask(d_uop.fd, d_uop.fw) : '0;
    fr_inflight = fr_busy_q;
    if (e1_q.u.valid && e1_q.u.wr_fr && e1_q.u.cls != UC_FPU) fr_inflight |= fr_mask(e1_q.u.fd, e1_q.u.fw);
    if (e2_q.u.valid && e2_q.u.wr_fr && e2_q.u.cls != UC_FPU) fr_inflight |= fr_mask(e2_q.u.fd, e2_q.u.fw);
    if (e3_q.u.valid && e3_q.u.wr_fr && e3_q.u.cls != UC_FPU) fr_inflight |= fr_mask(e3_q.u.fd, e3_q.u.fw);
    if (w_q.u.valid  && w_q.u.wr_fr  && w_q.u.cls  != UC_FPU) fr_inflight |= fr_mask(w_q.u.fd, w_q.u.fw);
  end

  always_comb begin
    d_stall = 1'b0;
    if (d_uop.cls != UC_EXC) begin
      if (gpr_hazard(d_uop.ra)) d_stall = 1'b1;
      if (!d_uop.use_imm && gpr_hazard(d_uop.rb)) d_stall = 1'b1;
      if (uses_rc && gpr_hazard(d_uop.rc)) d_stall = 1'b1;
      if (d_uop.wr_gpr && d_uop.rd != 6'd63 && gr_busy_q[d_uop.rd]) d_stall = 1'b1;
      if (d_uop.fpu_wr_gpr && gr_busy_q[d_uop.rd]) d_stall = 1'b1;
      if (|((fr_rdmask | fr_wrmask) & fr_inflight)) d_stall = 1'b1;
      if ((d_uop.cls == UC_FPUTSCR || (d_uop.cls == UC_FMOV && d_uop.fmov == FM_GETSCR)) && !fpu_fifo_empty) d_stall = 1'b1;
    end
  end

  assign d_issue   = d_valid && !d_stall && !hold;
  assign if_consume = d_issue;

  // ===================================================================
  // Pipeline advance / hold
  assign hold    = hold_e1 || hold_e2 || hold_e3 || hold_w;
  assign advance = !hold;

  // ===================================================================
  // E1: forwarding, ALU, address, branches, PT, FPU issue, control reads
  logic [63:0] w_result;
  logic [63:0] mm_res;
  logic [63:0] e1_a, e1_b, e1_c, e1_bop;
  logic [31:0] e1_trv;

  function automatic logic [63:0] fwd(input logic [5:0] idx, input logic [63:0] dval);
    if (idx == 6'd63) fwd = 64'h0;
    else if (e2_q.u.valid && e2_q.u.wr_gpr && !e2_q.u.long_lat && e2_q.u.cls != UC_FPU && e2_q.u.rd == idx) fwd = e2_q.res;
    else if (e3_q.u.valid && e3_q.u.wr_gpr && !e3_q.u.long_lat && e3_q.u.cls != UC_FPU && e3_q.u.rd == idx) fwd = e3_q.res;
    else if (w_q.u.valid && w_q.u.wr_gpr && w_q.u.cls != UC_FPU && w_q.u.rd == idx && w_q.u.exc == 12'h0) fwd = w_result;
    else if (wb_valid_q && wb_idx_q == idx) fwd = wb_val_q;
    else fwd = dval;
  endfunction

  function automatic logic [31:0] fwd_tr(input logic [2:0] idx, input logic [31:0] dval);
    if (e2_q.u.valid && e2_q.u.wr_tr && e2_q.u.tra == idx) fwd_tr = e2_q.res[31:0];
    else if (e3_q.u.valid && e3_q.u.wr_tr && e3_q.u.tra == idx) fwd_tr = e3_q.res[31:0];
    else if (w_q.u.valid && w_q.u.wr_tr && w_q.u.tra == idx && w_q.u.exc == 12'h0) fwd_tr = w_q.res[31:0];
    else if (wbt_valid_q && wbt_idx_q == idx) fwd_tr = wbt_val_q;
    else fwd_tr = dval;
  endfunction

  assign e1_a   = fwd(e1_q.u.ra, e1_q.a);
  assign e1_b   = fwd(e1_q.u.rb, e1_q.b);
  // FSTORE carries FR data in c (read in D), not a GPR
  assign e1_c   = (e1_q.u.cls == UC_FSTORE) ? e1_q.c : fwd(e1_q.u.rc, e1_q.c);
  assign e1_bop = e1_q.u.use_imm ? e1_q.u.imm : e1_b;
  assign e1_trv = fwd_tr(e1_q.u.trb, e1_q.trv);

  logic [63:0] alu_res;
  sh5_alu u_alu (.op_i(e1_q.u.alu), .a_i(e1_a), .b_i(e1_bop), .c_i(e1_c), .r_o(alu_res));

  // effective address and access checks
  logic [63:0] e1_ea64;
  logic        e1_ea_bad, e1_misaligned, e1_is_mem, e1_is_read;
  assign e1_ea64 = e1_a + e1_bop;
  assign e1_ea_bad = !((e1_ea64[63:31] == 33'h0) || (e1_ea64[63:31] == {33{1'b1}}));
  assign e1_is_mem = (e1_q.u.cls == UC_LOAD) || (e1_q.u.cls == UC_STORE) || (e1_q.u.cls == UC_SWAP) ||
                     (e1_q.u.cls == UC_FLOAD) || (e1_q.u.cls == UC_FSTORE);
  assign e1_is_read = (e1_q.u.cls == UC_LOAD) || (e1_q.u.cls == UC_SWAP) || (e1_q.u.cls == UC_FLOAD);
  always_comb begin
    case (e1_q.u.msize)
      2'd0: e1_misaligned = 1'b0;
      2'd1: e1_misaligned = e1_ea64[0];
      2'd2: e1_misaligned = |e1_ea64[1:0];
      default: e1_misaligned = |e1_ea64[2:0];
    endcase
    if (e1_q.u.mkind == M_HI || e1_q.u.mkind == M_LO) e1_misaligned = 1'b0;
  end

  // store data and byte mask (little-endian lanes; big-endian mirrors them)
  logic [63:0] e1_sdata;
  logic [7:0]  e1_smask;
  always_comb begin
    logic [2:0] o;
    logic [3:0] w;          // access width in bytes for HI/LO
    logic [2:0] off, blk;
    logic [63:0] v, vbe;
    o = e1_ea64[2:0];
    e1_sdata = 64'h0;
    e1_smask = 8'h0;
    v = e1_c;
    vbe = v;
    case (e1_q.u.mkind)
      M_HI, M_LO: begin
        w   = (e1_q.u.msize == 2'd3) ? 4'd8 : 4'd4;
        off = (e1_q.u.msize == 2'd3) ? o : {1'b0, o[1:0]};
        blk = (e1_q.u.msize == 2'd3) ? 3'd0 : {o[2], 2'b00};
        if (e1_q.u.mkind == M_LO) begin
          // bytes at address .. end of block from the low bytes of the value
          e1_smask = 8'((16'h1 << (w - {1'b0, off})) - 16'h1) << (blk + off);
          e1_sdata = v << (8 * (blk + off));
          if (e1_q.u.msize == 2'd2) e1_sdata[63:32] = 32'h0;
        end else begin
          // bytes at block start .. address from the high bytes of the value
          e1_smask = 8'((16'h1 << ({1'b0, off} + 4'd1)) - 16'h1) << blk;
          e1_sdata = (v >> (8 * (w - 4'd1 - {1'b0, off}))) << (8 * blk);
        end
      end
      default: begin
        if (!big_endian_i) begin
          e1_smask = byte_mask(4'd1 << e1_q.u.msize, o, 1'b0);
          e1_sdata = v << (8 * o);
        end else begin
          // reverse the bytes of the element, place at the mirrored offset
          case (e1_q.u.msize)
            2'd0: vbe = v;
            2'd1: vbe = {48'h0, v[7:0], v[15:8]};
            2'd2: vbe = {32'h0, v[7:0], v[15:8], v[23:16], v[31:24]};
            default: vbe = {v[7:0], v[15:8], v[23:16], v[31:24], v[39:32], v[47:40], v[55:48], v[63:56]};
          endcase
          e1_smask = byte_mask(4'd1 << e1_q.u.msize, o, 1'b1);
          e1_sdata = vbe << (8 * (4'd8 - {1'b0, o} - (4'd1 << e1_q.u.msize)));
        end
      end
    endcase
  end

  // branch resolution
  logic e1_taken;
  always_comb begin
    case (e1_q.u.bcond)
      BC_EQ:  e1_taken = (e1_a == e1_bop);
      BC_NE:  e1_taken = (e1_a != e1_bop);
      BC_GT:  e1_taken = ($signed(e1_a) > $signed(e1_bop));
      BC_GE:  e1_taken = ($signed(e1_a) >= $signed(e1_bop));
      BC_GTU: e1_taken = (e1_a > e1_bop);
      default: e1_taken = (e1_a >= e1_bop);
    endcase
  end

  // prepare target
  logic [63:0] e1_pt_target;
  logic        e1_pt_bad;
  assign e1_pt_target = e1_a + e1_q.u.imm;
  assign e1_pt_bad = !((e1_pt_target[63:31] == 33'h0) || (e1_pt_target[63:31] == {33{1'b1}})) ||
                     (e1_pt_target[1:0] == 2'b11);

  // control register / configuration reads
  assign getcon_idx = e1_q.u.ra;
  assign getcfg_idx = e1_ea64[31:0];

  // FPU
  logic         fpu_issue, fpu_ready, fpu_trap, fpu_done_raw;
  logic [127:0] fpu_result;
  logic [5:0]   fpu_cause_raw;
  logic         fpu_may_issue, older_exc;
  logic [7:0]   fpu_tag_unused;

  assign older_exc = (e2_q.u.valid && e2_q.u.exc != 12'h0) || (e3_q.u.valid && e3_q.u.exc != 12'h0) ||
                     (w_q.u.valid && w_q.u.exc != 12'h0);
  assign fpu_may_issue = e1_q.u.valid && (e1_q.u.cls == UC_FPU) && (e1_q.u.exc == 12'h0) &&
                         !e1_fpu_issued_q && !older_exc;
  assign fpu_issue = fpu_may_issue && fpu_ready;
  assign hold_e1 = fpu_may_issue && !fpu_ready;

  sh5_fpu u_fpu (
    .clk, .rst_n,
    .issue_i(fpu_issue), .ready_o(fpu_ready),
    .op_i(insn_op(e1_q.u.insn)), .ext_i(insn_ext(e1_q.u.insn)),
    .a_i(e1_q.fa), .b_i(e1_q.fb), .c_i(e1_q.fc),
    .va_i((e1_q.u.fa_w == 2'd2) ? e1_va_q : e1_vb_q), .vb_i(e1_vb_q), .mtrx_i(e1_mtrx_q),
    .fpscr_i(fpscr), .tag_i(8'h00),
    .trap_o(fpu_trap),
    .done_o(fpu_done_raw), .tag_o(fpu_tag_unused), .result_o(fpu_result), .cause_o(fpu_cause_raw)
  );

  // E1 result
  logic [63:0] e1_res;
  logic [11:0] e1_exc;
  logic        e1_tea_valid;
  logic [31:0] e1_tea;
  always_comb begin
    e1_res = alu_res;
    e1_exc = e1_q.u.exc;
    e1_tea_valid = e1_q.u.tea_valid;
    e1_tea = 32'h0;
    case (e1_q.u.cls)
      UC_GETCON: e1_res = getcon_val;
      UC_GETCFG: e1_res = getcfg_val;
      UC_GETTR:  e1_res = sext32(e1_trv);
      UC_BLINK:  e1_res = sext32({e1_q.u.pc[31:2] + 30'd1, 2'b01});
      UC_PT: begin
        e1_res = e1_pt_target;
        if (e1_pt_bad && e1_exc == 12'h0) begin
          e1_exc = EVT_IADDERR; e1_tea_valid = 1'b1; e1_tea = e1_pt_target[31:0];
        end
      end
      UC_PUTCON, UC_PUTCFG: e1_res = e1_c;
      UC_EXC:    e1_res = e1_a;      // TRAPA operand
      UC_FMOV: begin
        case (e1_q.u.fmov)
          FM_LS, FM_QD: e1_res = e1_a;
          FM_SL:        e1_res = sext32(e1_q.fa[31:0]);
          FM_DQ, FM_D:  e1_res = e1_q.fa;
          FM_S:         e1_res = {32'h0, e1_q.fa[31:0]};
          FM_ABSS:      e1_res = {32'h0, 1'b0, e1_q.fa[30:0]};
          FM_NEGS:      e1_res = {32'h0, ~e1_q.fa[31], e1_q.fa[30:0]};
          FM_ABSD:      e1_res = {1'b0, e1_q.fa[62:0]};
          FM_NEGD:      e1_res = {~e1_q.fa[63], e1_q.fa[62:0]};
          default:      e1_res = {32'h0, fpscr};
        endcase
      end
      default: ;
    endcase
    if (e1_is_mem && e1_exc == 12'h0 && (e1_ea_bad || e1_misaligned)) begin
      e1_exc = e1_is_read ? EVT_RADDERR : EVT_WADDERR;
      e1_tea_valid = 1'b1;
      e1_tea = e1_ea64[31:0];
    end
    if (fpu_issue && fpu_trap && e1_exc == 12'h0) begin
      e1_exc = EVT_FPUEXC;
    end
  end

  // branch redirect (BLINK may switch to SHcompact, which is not implemented)
  logic e1_redirect;
  assign e1_redirect = e1_q.u.valid && (e1_q.u.exc == 12'h0) && !e1_redir_done_q && !hold &&
                       ((e1_q.u.cls == UC_BRANCH && e1_taken) || (e1_q.u.cls == UC_BLINK));

  // ===================================================================
  // E2: memory request
  logic e2_is_read, e2_ok;
  assign e2_is_read = e2_q.u.valid && (e2_q.u.exc == 12'h0) &&
                      ((e2_q.u.cls == UC_LOAD) || (e2_q.u.cls == UC_SWAP) || (e2_q.u.cls == UC_FLOAD));
  // older instructions must be unable to launch: no pending exception in E3/W
  assign e2_ok = !(e3_q.u.valid && e3_q.u.exc != 12'h0) && !(w_q.u.valid && w_q.u.exc != 12'h0) &&
                 !st_pending && !(w_q.u.valid && (w_q.u.cls == UC_STORE || w_q.u.cls == UC_FSTORE) && !w_acted_q);
  assign ld_req_valid = e2_is_read && !e2_issued_q && e2_ok;
  assign ld_req_swap  = (e2_q.u.cls == UC_SWAP);
  assign ld_req_addr  = e2_q.ea[31:3];
  assign ld_req_mask  = e2_q.smask;
  assign ld_req_data  = e2_q.sdata;
  assign hold_e2 = e2_is_read && !e2_issued_q && !(ld_req_valid && ld_req_ready);

  // ===================================================================
  // E3: wait for load data
  logic e3_is_read;
  assign e3_is_read = e3_q.u.valid && (e3_q.u.exc == 12'h0) &&
                      ((e3_q.u.cls == UC_LOAD) || (e3_q.u.cls == UC_SWAP) || (e3_q.u.cls == UC_FLOAD));
  assign hold_e3 = e3_is_read && !e3_have_q && !ld_rsp_valid;

  // load data extraction
  logic [63:0] e3_ldata, e3_lres;
  assign e3_ldata = e3_have_q ? e3_data_q : ld_rsp_data;
  always_comb begin
    logic [2:0]  o, off, blk;
    logic [3:0]  w;
    logic [63:0] v, t;
    o = e3_q.ea[2:0];
    e3_lres = 64'h0;
    case (e3_q.u.mkind)
      M_HI, M_LO: begin
        w   = (e3_q.u.msize == 2'd3) ? 4'd8 : 4'd4;
        off = (e3_q.u.msize == 2'd3) ? o : {1'b0, o[1:0]};
        blk = (e3_q.u.msize == 2'd3) ? 3'd0 : {o[2], 2'b00};
        if (e3_q.u.mkind == M_LO) begin
          t = e3_ldata >> (8 * (blk + off));
          if (e3_q.u.msize == 2'd2) t = t & 64'h0000_0000_ffff_ffff;
          // keep w - off bytes
          for (int i = 0; i < 8; i++) if (4'(i) >= w - {1'b0, off}) t[8*i +: 8] = 8'h0;
          e3_lres = t;
        end else begin
          t = e3_ldata >> (8 * blk);
          for (int i = 0; i < 8; i++) if (3'(i) > off) t[8*i +: 8] = 8'h0;
          t = t << (8 * (w - 4'd1 - {1'b0, off}));
          if (e3_q.u.msize == 2'd2) e3_lres = sext32(t[31:0]);
          else e3_lres = t;
        end
      end
      default: begin
        if (!big_endian_i) begin
          v = e3_ldata >> (8 * o);
        end else begin
          t = e3_ldata >> (8 * (4'd8 - {1'b0, o} - (4'd1 << e3_q.u.msize)));
          case (e3_q.u.msize)
            2'd0: v = t;
            2'd1: v = {48'h0, t[7:0], t[15:8]};
            2'd2: v = {32'h0, t[7:0], t[15:8], t[23:16], t[31:24]};
            default: v = {t[7:0], t[15:8], t[23:16], t[31:24], t[39:32], t[47:40], t[55:48], t[63:56]};
          endcase
        end
        case (e3_q.u.msize)
          2'd0: e3_lres = e3_q.u.msigned ? {{56{v[7]}}, v[7:0]}   : {56'h0, v[7:0]};
          2'd1: e3_lres = e3_q.u.msigned ? {{48{v[15]}}, v[15:0]} : {48'h0, v[15:0]};
          2'd2: e3_lres = e3_q.u.msigned ? sext32(v[31:0])        : {32'h0, v[31:0]};
          default: e3_lres = v;
        endcase
      end
    endcase
  end

  // ===================================================================
  // Multimedia unit (3 stages aligned with E2, E3, W)
  sh5_mm u_mm (
    .clk, .en_i(advance),
    .op_i(insn_op(e1_q.u.insn)), .ext_i(insn_ext(e1_q.u.insn)),
    .a_i(e1_a), .b_i(e1_b), .c_i(e1_c),
    .result_o(mm_res)
  );

  // ===================================================================
  // FPU completion FIFO (in order)
  typedef struct packed {
    logic        wr_fr;
    logic [5:0]  fd;
    fwmode_t     fw;
    logic        wr_gpr;
    logic [5:0]  rd;
    logic        discard;
  } fpu_ent_t;

  fpu_ent_t fpu_fifo_q [8];
  logic [2:0] fpu_wr_q, fpu_rd_q;
  logic [3:0] fpu_cnt_q;
  fpu_ent_t fpu_head;

  assign fpu_fifo_empty = (fpu_cnt_q == 4'd0);
  assign fpu_head = fpu_fifo_q[fpu_rd_q];
  assign fpu_done  = fpu_done_raw;
  assign fpu_cause = fpu_cause_raw;

  // ===================================================================
  // W: commit
  logic w_exc, w_irq_ok_now, w_do, w_wait;
  logic w_is_store;

  assign w_result = (w_q.u.cls == UC_MM) ? mm_res : w_q.res;
  assign w_exc = w_q.u.valid && (w_q.u.exc != 12'h0);
  assign w_is_store = (w_q.u.cls == UC_STORE) || (w_q.u.cls == UC_FSTORE);
  assign w_irq_ok_now = w_q.u.exc_is_reset ||
                        (w_q.u.exc == EVT_NMI) ||
                        (w_q.u.exc == EVT_INT_DEBUGINT && !sr[SR_BL]) ||
                        (w_q.u.exc == EVT_INT_EXTINT && !sr[SR_BL] && (w_q.u.irq_level > sr[SR_IMASK +: 4]));

  always_comb begin
    w_wait = 1'b0;
    if (w_q.u.valid && !w_acted_q) begin
      if (w_q.fpu_trap && !fpu_fifo_empty) w_wait = 1'b1;
      if (!w_exc) begin
        if (w_is_store && !st_req_ready) w_wait = 1'b1;
        if (w_q.u.cls == UC_SYNCO && st_pending) w_wait = 1'b1;
      end
    end
  end
  assign hold_w = w_wait;
  assign w_do = w_q.u.valid && !w_acted_q && !w_wait;

  // launch / RTE / redirects from W
  logic w_launch, w_rte, w_refetch, w_irq_cancel;
  assign w_launch = w_do && w_exc && (!w_q.u.exc_is_irq || w_irq_ok_now);
  assign w_irq_cancel = w_do && w_exc && w_q.u.exc_is_irq && !w_irq_ok_now;
  assign w_rte = w_do && !w_exc && (w_q.u.cls == UC_RTE);
  assign w_refetch = w_do && !w_exc && (w_q.u.cls == UC_SYNCI);

  assign launch_en        = w_launch;
  assign launch_code      = w_q.u.exc;
  assign launch_is_irq    = w_q.u.exc_is_irq;
  assign launch_is_reset  = w_q.u.exc_is_reset;
  assign launch_irq_level = w_q.u.irq_level;
  assign launch_irq_code  = w_q.u.imm[31:0];
  assign launch_pc        = w_q.u.pc;
  assign launch_tea_valid = w_q.u.tea_valid;
  assign launch_tea       = w_q.ea;
  assign launch_tra       = w_q.res[31:0];
  assign rte_en           = w_rte;

  assign putcon_en  = w_do && !w_exc && (w_q.u.cls == UC_PUTCON);
  assign putcon_idx = w_q.u.rd;
  assign putcon_val = w_q.res;
  assign putcfg_en  = w_do && !w_exc && (w_q.u.cls == UC_PUTCFG);
  assign putcfg_idx = w_q.ea;
  assign putcfg_val = w_q.res;
  assign fputscr_en  = w_do && !w_exc && (w_q.u.cls == UC_FPUTSCR);
  assign fputscr_val = w_q.fa[31:0];

  assign st_req_valid = w_q.u.valid && !w_acted_q && !w_exc && w_is_store && !(w_q.fpu_trap);
  assign st_req_addr  = w_q.ea[31:3];
  assign st_req_mask  = w_q.smask;
  assign st_req_data  = w_q.sdata;

  // flush and redirect
  assign flush = w_launch || w_rte || w_refetch || w_irq_cancel;
  always_comb begin
    redirect = 1'b0;
    redirect_pc = 32'h0;
    if (reset_q) begin
      redirect = 1'b1; redirect_pc = reset_pc_i;
    end else if (w_launch || w_rte) begin
      redirect = 1'b1; redirect_pc = ctrl_new_pc;
    end else if (w_refetch || w_irq_cancel) begin
      redirect = 1'b1; redirect_pc = w_q.u.pc + ((w_q.u.cls == UC_SYNCI) ? 32'd4 : 32'd0);
    end else if (e1_redirect) begin
      redirect = 1'b1;
      redirect_pc = (e1_q.u.cls == UC_BLINK) ? {e1_trv[31:1], 1'b0} : {e1_trv[31:2], 2'b00};
    end
  end

  // register writes at W
  logic        gw_en;
  logic [5:0]  gw_idx;
  logic [63:0] gw_val;
  logic        fw_en;
  logic [5:0]  fw_idx;
  fwmode_t     fw_mode;
  logic [127:0] fw_val;

  assign gw_en  = w_do && !w_exc && w_q.u.wr_gpr && (w_q.u.cls != UC_FPU) && (w_q.u.rd != 6'd63);
  assign gw_idx = w_q.u.rd;
  assign gw_val = w_result;
  assign fw_en   = w_do && !w_exc && w_q.u.wr_fr && (w_q.u.cls != UC_FPU);
  assign fw_idx  = w_q.u.fd;
  assign fw_mode = w_q.u.fw;
  assign fw_val  = {64'h0, w_result};

  // FPU writeback (asynchronous to the pipeline)
  logic        fgw_en, ffw_en;
  assign fgw_en = fpu_done_raw && fpu_head.wr_gpr && !fpu_head.discard && (fpu_head.rd != 6'd63);
  assign ffw_en = fpu_done_raw && fpu_head.wr_fr && !fpu_head.discard;

  // USR dirty bits
  always_comb begin
    usr_set_gprs = 8'h0;
    usr_set_fprs = 8'h0;
    if (gw_en)  usr_set_gprs |= 8'h1 << gw_idx[5:3];
    if (fgw_en) usr_set_gprs |= 8'h1 << fpu_head.rd[5:3];
    if (fw_en)  usr_set_fprs |= 8'h1 << fw_idx[5:3];
    if (ffw_en) usr_set_fprs |= 8'h1 << fpu_head.fd[5:3];
  end

  // ===================================================================
  // Register file writes
  function automatic void fr_write(input logic [5:0] f, input fwmode_t fw, input logic [127:0] v);
    case (fw)
      FW_32:   fr_q[f] <= v[31:0];
      FW_64:   begin fr_q[{f[5:1], 1'b0}] <= v[63:32]; fr_q[{f[5:1], 1'b1}] <= v[31:0]; end
      FW_PAIR: begin fr_q[{f[5:1], 1'b0}] <= v[31:0];  fr_q[{f[5:1], 1'b1}] <= v[63:32]; end
      default: begin
        fr_q[{f[5:2], 2'b00}] <= v[31:0];
        fr_q[{f[5:2], 2'b01}] <= v[63:32];
        fr_q[{f[5:2], 2'b10}] <= v[95:64];
        fr_q[{f[5:2], 2'b11}] <= v[127:96];
      end
    endcase
  endfunction

  always_ff @(posedge clk) begin
    if (gw_en)  gr_q[gw_idx] <= gw_val;
    if (fgw_en) gr_q[fpu_head.rd] <= {63'h0, fpu_result[0]};
    if (fw_en)  fr_write(fw_idx, fw_mode, fw_val);
    if (ffw_en) fr_write(fpu_head.fd, fpu_head.fw, fpu_result);
    if (w_do && !w_exc && w_q.u.wr_tr) tr_q[w_q.u.tra] <= w_q.res[31:0];
  end

  // ===================================================================
  // Pipeline registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      e1_q <= '0; e2_q <= '0; e3_q <= '0; w_q <= '0;
      e1_va_q <= '0; e1_vb_q <= '0; e1_mtrx_q <= '0;
      e1_fpu_issued_q <= 1'b0; e1_redir_done_q <= 1'b0; e2_issued_q <= 1'b0;
      e3_have_q <= 1'b0; e3_data_q <= 64'h0; w_acted_q <= 1'b0;
      wb_valid_q <= 1'b0; wb_idx_q <= 6'd0; wb_val_q <= 64'h0;
      wbt_valid_q <= 1'b0; wbt_idx_q <= 3'd0; wbt_val_q <= 32'h0;
      serial_block_q <= 1'b0; sleeping_q <= 1'b0; reset_q <= 1'b1;
      blink_compact_q <= 1'b0;
      fr_busy_q <= '0; gr_busy_q <= '0;
      fpu_wr_q <= 3'd0; fpu_rd_q <= 3'd0; fpu_cnt_q <= 4'd0;
    end else begin
      reset_q <= 1'b0;

      // FPU scoreboard and FIFO
      if (fpu_issue) begin
        fpu_fifo_q[fpu_wr_q] <= '{wr_fr: e1_q.u.wr_fr, fd: e1_q.u.fd, fw: e1_q.u.fw,
                                  wr_gpr: e1_q.u.fpu_wr_gpr, rd: e1_q.u.rd, discard: fpu_trap};
        fpu_wr_q <= fpu_wr_q + 3'd1;
        if (!fpu_trap) begin
          if (e1_q.u.wr_fr) fr_busy_q <= fr_busy_q | fr_mask(e1_q.u.fd, e1_q.u.fw);
          if (e1_q.u.fpu_wr_gpr) gr_busy_q[e1_q.u.rd] <= 1'b1;
        end
      end
      if (fpu_done_raw) begin
        fpu_rd_q <= fpu_rd_q + 3'd1;
        if (!fpu_head.discard) begin
          if (fpu_head.wr_fr) fr_busy_q <= (fr_busy_q & ~fr_mask(fpu_head.fd, fpu_head.fw)) |
                                           ((fpu_issue && !fpu_trap && e1_q.u.wr_fr) ? fr_mask(e1_q.u.fd, e1_q.u.fw) : 64'h0);
          if (fpu_head.wr_gpr) gr_busy_q[fpu_head.rd] <= (fpu_issue && !fpu_trap && e1_q.u.fpu_wr_gpr && e1_q.u.rd == fpu_head.rd);
        end
      end
      fpu_cnt_q <= fpu_cnt_q + (fpu_issue ? 4'd1 : 4'd0) - (fpu_done_raw ? 4'd1 : 4'd0);

      // writeback forwarding register
      wb_valid_q <= gw_en;
      wb_idx_q   <= gw_idx;
      wb_val_q   <= gw_val;
      wbt_valid_q <= w_do && !w_exc && w_q.u.wr_tr;
      wbt_idx_q   <= w_q.u.tra;
      wbt_val_q   <= w_q.res[31:0];

      // one-shot flags within a held stage
      if (fpu_issue) e1_fpu_issued_q <= 1'b1;
      if (e1_redirect) e1_redir_done_q <= 1'b1;
      if (ld_req_valid && ld_req_ready) e2_issued_q <= 1'b1;
      if (ld_rsp_valid && e3_is_read && !e3_have_q) begin
        e3_have_q <= 1'b1;
        e3_data_q <= ld_rsp_data;
      end
      if (w_do) w_acted_q <= 1'b1;

      // serialization: block decode behind serializing instructions
      if (d_issue && d_uop.serialize) serial_block_q <= 1'b1;
      if (advance && w_q.u.valid && w_q.u.serialize) serial_block_q <= 1'b0;
      if (flush) serial_block_q <= 1'b0;

      // sleep
      if (w_do && !w_exc && w_q.u.cls == UC_SLEEP) sleeping_q <= 1'b1;
      if (sleeping_q && (cpu_reset_i || nmi_i || debugint_i || extint_valid_i)) sleeping_q <= 1'b0;

      // ISA tracking
      if (e1_redirect && e1_q.u.cls == UC_BLINK && !e1_trv[0]) blink_compact_q <= 1'b1;
      if (w_launch || w_rte) blink_compact_q <= 1'b0;

      if (advance) begin
        e1_fpu_issued_q <= 1'b0;
        e1_redir_done_q <= 1'b0;
        e2_issued_q <= 1'b0;
        e3_have_q <= 1'b0;
        w_acted_q <= 1'b0;

        // W <- E3
        w_q <= e3_q;
        if (e3_is_read) w_q.res <= e3_lres;
        if (flush) w_q.u.valid <= 1'b0;

        // E3 <- E2
        e3_q <= e2_q;
        if (flush) e3_q.u.valid <= 1'b0;

        // E2 <- E1
        e2_q <= e1_q;
        e2_q.res <= e1_res;
        e2_q.u.exc <= e1_exc;
        e2_q.u.tea_valid <= e1_tea_valid;
        e2_q.ea <= (e1_q.u.cls == UC_PT) ? e1_pt_target[31:0] :
                   (e1_tea_valid && e1_q.u.cls != UC_PT) ? e1_tea : e1_ea64[31:0];
        if (e1_q.u.cls == UC_PT && e1_pt_bad) e2_q.ea <= e1_pt_target[31:0];
        e2_q.sdata <= e1_sdata;
        e2_q.smask <= e1_smask;
        e2_q.a <= e1_a; e2_q.b <= e1_b; e2_q.c <= e1_c;
        e2_q.fpu_trap <= fpu_issue && fpu_trap;
        if (e1_q.u.cls == UC_SWAP) begin e2_q.sdata <= e1_c; e2_q.smask <= 8'hff; end
        if (flush) e2_q.u.valid <= 1'b0;

        // E1 <- D
        e1_q <= '0;
        if (d_issue) begin
          e1_q.u   <= d_uop;
          e1_q.a   <= gr_rd(d_uop.ra);
          e1_q.b   <= gr_rd(d_uop.rb);
          e1_q.c   <= gr_rd(d_uop.rc);
          e1_q.trv <= tr_q[d_uop.trb];
          e1_q.fa  <= fr_rd64(d_uop.fa, d_uop.fa_w);
          e1_q.fb  <= fr_rd64(d_uop.fb, d_uop.fb_w);
          e1_q.fc  <= fr_rd64(d_uop.fc, d_uop.fc_w);
          // FP store data: the 64-bit memory image
          if (d_uop.cls == UC_FSTORE) begin
            case (d_uop.mkind)
              M_FP_S:  e1_q.c <= {32'h0, fr_q[d_uop.fc]};
              M_FP_D:  e1_q.c <= {fr_q[{d_uop.fc[5:1], 1'b0}], fr_q[{d_uop.fc[5:1], 1'b1}]};
              default: e1_q.c <= {fr_q[{d_uop.fc[5:1], 1'b1}], fr_q[{d_uop.fc[5:1], 1'b0}]};
            endcase
          end
          e1_va_q   <= fr_rd128(d_uop.fa);
          e1_vb_q   <= fr_rd128(d_uop.fb);
          e1_mtrx_q <= fr_rd512(d_uop.fa);
        end
      end else begin
        // held: a late load response is captured above; nothing else moves
      end

    end
  end

  // ===================================================================
  // Outputs
  assign sleep_o = sleeping_q;
  assign extint_ack_o = w_launch && (w_q.u.exc == EVT_INT_EXTINT);
  assign extint_ack_level_o = w_q.u.irq_level;

  assign trace_valid_o   = advance && w_q.u.valid;
  assign trace_pc_o      = w_q.u.pc;
  assign trace_insn_o    = w_q.u.insn;
  assign trace_gpr_we_o  = trace_valid_o && !w_exc && w_q.u.wr_gpr && (w_q.u.cls != UC_FPU) && (w_q.u.rd != 6'd63);
  assign trace_gpr_idx_o = w_q.u.rd;
  assign trace_gpr_val_o = w_result;
  assign trace_fpu_we_o  = fgw_en || ffw_en;
  assign trace_fpu_idx_o = fpu_head.wr_gpr ? fpu_head.rd : fpu_head.fd;
  assign trace_fpu_val_o = fpu_result;

  assign dbg_fetch_addr_o = if_insn_pc;
  assign dbg_insn_o       = if_insn;
  assign dbg_op_addr_o    = e2_q.ea;
  assign dbg_op_valid_o   = ld_req_valid || st_req_valid;

  // ===================================================================
  // Target port: VCR at offsets 0x00 and 0x08 (docs/bus-interface.md)
  logic [7:0]  vcr_err_q;
  logic [63:0] vcr;
  logic        treq_pending_q, treq_vcr_hit_q;
  logic [7:0]  treq_opc_q, treq_src_q, treq_tid_q;

  assign vcr = {vcr_err_q, 8'h00, MODULE_ID, MODULE_VERSION, 16'h0000};
  assign treq_ready = !treq_pending_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      treq_pending_q <= 1'b0; treq_opc_q <= 8'h00; treq_src_q <= 8'h00; treq_tid_q <= 8'h00;
      treq_vcr_hit_q <= 1'b0; vcr_err_q <= 8'h00;
    end else begin
      if (bus_error_o) vcr_err_q[0] <= 1'b1;
      if (treq_valid && treq_ready && treq_last) begin
        treq_pending_q <= 1'b1;
        treq_opc_q <= treq_opc; treq_src_q <= treq_src; treq_tid_q <= treq_tid;
        treq_vcr_hit_q <= (treq_addr[23:4] == 20'h0) && (treq_opc == OPC_LOAD8 || treq_opc == OPC_STORE8);
        if (treq_opc == OPC_STORE8 && treq_addr[23:3] == 21'h0) vcr_err_q <= 8'h00;
      end
      if (trsp_valid && trsp_ready) treq_pending_q <= 1'b0;
    end
  end

  assign trsp_valid = treq_pending_q;
  assign trsp_opc   = treq_vcr_hit_q ? OPC_SUCCESS : OPC_FAILURE;
  assign trsp_src   = treq_src_q;
  assign trsp_tid   = treq_tid_q;
  assign trsp_data  = (treq_vcr_hit_q && treq_opc_q == OPC_LOAD8) ? vcr : 64'h0;
  assign trsp_last  = 1'b1;

  logic unused_ok;
  assign unused_ok = &{1'b0, dbg_ia_hit_i, dbg_iv_hit_i, dbg_oa_hit_i, treq_mask, treq_data,
                       treq_addr[31:24], treq_addr[2:0], iccr0, occr0, e1_q.u.likely, fpu_tag_unused,
                       ICACHE_WAYS[0], ICACHE_SETS[0], DCACHE_WAYS[0], DCACHE_SETS[0], ITLB_ENTRIES[0], 1'b0};

endmodule
