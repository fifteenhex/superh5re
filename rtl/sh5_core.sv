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
  output logic        trace_launch_o,     // event launch this cycle
  output logic [11:0] trace_launch_code_o,
  output logic [31:0] trace_launch_tea_o,
  output logic [31:0] trace_launch_pc_o,
  output logic        trace_pred_o,       // branch resolved in E1 that was predicted taken
  output logic        trace_mispred_o,    // branch resolved in E1 that redirected fetch

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
  logic [31:0] iccr0, occr0, iccr1, occr1;
  logic        ici_pulse, oci_pulse;
  logic [5:0]  getcon_idx;
  logic [63:0] getcon_val;
  logic        putcon_en;
  logic [5:0]  putcon_idx;
  logic [63:0] putcon_val;
  logic        getcon_fpscr, srflag_en, launch_isa;
  logic [31:0] srflag_mask, srflag_val;
  logic [31:0] getcfg_idx;
  logic [63:0] getcfg_val, ctrl_getcfg_val;
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

  sh5_ctrl #(.FPU_PRESENT(FPU_PRESENT)) u_ctrl (
    .clk, .rst_n,
    .sr_o(sr), .fpscr_o(fpscr), .isa_o(ctrl_isa), .iccr0_o(iccr0), .occr0_o(occr0),
    .iccr1_o(iccr1), .occr1_o(occr1), .ici_o(ici_pulse), .oci_o(oci_pulse),
    .getcon_idx_i(getcon_idx), .getcon_fpscr_i(getcon_fpscr), .getcon_val_o(getcon_val),
    .srflag_en_i(srflag_en), .srflag_mask_i(srflag_mask), .srflag_val_i(srflag_val),
    .putcon_en_i(putcon_en), .putcon_idx_i(putcon_idx), .putcon_val_i(putcon_val),
    .getcfg_idx_i(getcfg_idx), .getcfg_val_o(ctrl_getcfg_val),
    .putcfg_en_i(putcfg_en), .putcfg_idx_i(putcfg_idx), .putcfg_val_i(putcfg_val),
    .fputscr_en_i(fputscr_en), .fputscr_val_i(fputscr_val),
    .fpu_done_i(fpu_done), .fpu_cause_i(fpu_cause),
    .usr_set_gprs_i(usr_set_gprs), .usr_set_fprs_i(usr_set_fprs),
    .launch_en_i(launch_en), .launch_code_i(launch_code), .launch_is_irq_i(launch_is_irq),
    .launch_is_reset_i(launch_is_reset), .launch_irq_level_i(launch_irq_level),
    .launch_irq_code_i(launch_irq_code), .launch_pc_i(launch_pc), .launch_isa_i(launch_isa),
    .launch_tea_valid_i(launch_tea_valid), .launch_tea_i(launch_tea), .launch_tra_i(launch_tra),
    .rte_en_i(rte_en), .new_pc_o(ctrl_new_pc),
    .dbrvec_i, .dbrmode_i
  );

  // ===================================================================
  // TLBs (Vol. 4 8.5): MMUIR at 0x00000000, MMUDR at 0x00800000, 16 per entry
  localparam int ITLB_IDX = $clog2(ITLB_ENTRIES);
  localparam int DTLB_IDX = $clog2(DTLB_ENTRIES);
  logic        cfg_is_itlb_r, cfg_is_dtlb_r, cfg_is_itlb_w, cfg_is_dtlb_w;
  logic [31:0] itlb_cfg_rdata, dtlb_cfg_rdata;
  logic [31:0] itlb_ea, dtlb_ea, itlb_pa, dtlb_pa;
  logic        itlb_hit, itlb_x, itlb_u, dtlb_hit, dtlb_r, dtlb_w, dtlb_u;
  logic        itlb_r_unused, itlb_w_unused, dtlb_x_unused;
  logic [1:0]  itlb_cb, dtlb_cb;
  logic        itlb_sh, dtlb_sh;
  logic [7:0]  cur_asid;

  assign cur_asid = sr[SR_ASID +: 8];
  assign cfg_is_itlb_r = (getcfg_idx[31:21] == 11'h000) && (getcfg_idx[15:4] < 12'(ITLB_ENTRIES)) && (getcfg_idx[3:1] == 3'b000);
  assign cfg_is_dtlb_r = (getcfg_idx[31:21] == 11'h004) && (getcfg_idx[15:4] < 12'(DTLB_ENTRIES)) && (getcfg_idx[3:1] == 3'b000);
  assign cfg_is_itlb_w = (putcfg_idx[31:21] == 11'h000) && (putcfg_idx[15:4] < 12'(ITLB_ENTRIES)) && (putcfg_idx[3:1] == 3'b000);
  assign cfg_is_dtlb_w = (putcfg_idx[31:21] == 11'h004) && (putcfg_idx[15:4] < 12'(DTLB_ENTRIES)) && (putcfg_idx[3:1] == 3'b000);
  logic [63:0] ic_cfg_rdata, dc_cfg_rdata;
  logic        cfg_is_icache_r, cfg_is_dcache_r;
  logic        ic_cfg_req, ic_cfg_rvalid, dc_cfg_req, dc_cfg_rvalid;
  // region 1: bank 0 ICACHETAG, 1 ICACHEDATA, 3 ICCR, 4 OCACHETAG, 5 OCACHEDATA, 7 OCCR (Vol. 4 Table 28)
  assign cfg_is_icache_r = (getcfg_idx[31:24] == 8'h01) && (getcfg_idx[23:22] == 2'b00);
  assign cfg_is_dcache_r = (getcfg_idx[31:24] == 8'h01) && (getcfg_idx[23:22] == 2'b10);
  assign getcfg_val = cfg_is_itlb_r ? {32'h0, itlb_cfg_rdata} :
                      cfg_is_dtlb_r ? {32'h0, dtlb_cfg_rdata} :
                      cfg_is_icache_r ? ic_cfg_rdata :
                      cfg_is_dcache_r ? dc_cfg_rdata : ctrl_getcfg_val;

  sh5_tlb #(.ENTRIES(ITLB_ENTRIES), .ITLB(1'b1)) u_itlb (
    .clk,
    .cfg_we_i(putcfg_en && cfg_is_itlb_w), .cfg_widx_i(putcfg_idx[4 +: ITLB_IDX]), .cfg_wsel_i(putcfg_idx[0]),
    .cfg_wdata_i(putcfg_val[31:0]),
    .cfg_ridx_i(getcfg_idx[4 +: ITLB_IDX]), .cfg_rsel_i(getcfg_idx[0]), .cfg_rdata_o(itlb_cfg_rdata),
    .ea_i(itlb_ea), .asid_i(cur_asid), .hit_o(itlb_hit), .pa_o(itlb_pa),
    .pr_r_o(itlb_r_unused), .pr_w_o(itlb_w_unused), .pr_x_o(itlb_x), .pr_u_o(itlb_u), .sh_o(itlb_sh), .cb_o(itlb_cb)
  );

  sh5_tlb #(.ENTRIES(DTLB_ENTRIES), .ITLB(1'b0)) u_dtlb (
    .clk,
    .cfg_we_i(putcfg_en && cfg_is_dtlb_w), .cfg_widx_i(putcfg_idx[4 +: DTLB_IDX]), .cfg_wsel_i(putcfg_idx[0]),
    .cfg_wdata_i(putcfg_val[31:0]),
    .cfg_ridx_i(getcfg_idx[4 +: DTLB_IDX]), .cfg_rsel_i(getcfg_idx[0]), .cfg_rdata_o(dtlb_cfg_rdata),
    .ea_i(dtlb_ea), .asid_i(cur_asid), .hit_o(dtlb_hit), .pa_o(dtlb_pa),
    .pr_r_o(dtlb_r), .pr_w_o(dtlb_w), .pr_x_o(dtlb_x_unused), .pr_u_o(dtlb_u), .sh_o(dtlb_sh), .cb_o(dtlb_cb)
  );

  // ===================================================================
  // Bus interface unit, behind the caches
  logic         bif_req_valid, bif_req_ready, bif_req_line, bif_rsp_valid, bif_idle;
  logic [31:3]  bif_req_addr;
  logic [255:0] bif_rsp_data;
  logic         bld_req_valid, bld_req_ready, bld_req_swap, bld_req_line, bld_rsp_valid;
  logic [31:3]  bld_req_addr;
  logic [7:0]   bld_req_mask;
  logic [63:0]  bld_req_data;
  logic [255:0] bld_rsp_data;
  logic         bst_req_valid, bst_req_ready, bst_req_line, bst_pending;
  logic [31:3]  bst_req_addr;
  logic [7:0]   bst_req_mask;
  logic [255:0] bst_req_data;

  sh5_biu #(.TID_BITS(TID_BITS), .BUS_SRC_ID(BUS_SRC_ID)) u_biu (
    .clk, .rst_n,
    .if_req_valid_i(bif_req_valid), .if_req_ready_o(bif_req_ready), .if_req_line_i(bif_req_line),
    .if_req_addr_i(bif_req_addr),
    .if_rsp_valid_o(bif_rsp_valid), .if_rsp_data_o(bif_rsp_data), .if_idle_o(bif_idle),
    .ld_req_valid_i(bld_req_valid), .ld_req_ready_o(bld_req_ready), .ld_req_swap_i(bld_req_swap),
    .ld_req_line_i(bld_req_line), .ld_req_addr_i(bld_req_addr), .ld_req_mask_i(bld_req_mask),
    .ld_req_data_i(bld_req_data),
    .ld_rsp_valid_o(bld_rsp_valid), .ld_rsp_data_o(bld_rsp_data),
    .st_req_valid_i(bst_req_valid), .st_req_ready_o(bst_req_ready), .st_req_line_i(bst_req_line),
    .st_req_addr_i(bst_req_addr), .st_req_mask_i(bst_req_mask), .st_req_data_i(bst_req_data),
    .st_pending_o(bst_pending),
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
  // declared here because the IFU instance below names them: a name used
  // before its declaration becomes an implicit one-bit wire in Vivado
  logic        d_redirect;      // D-stage branch prediction (target buffer hit)
  logic        e1_redirect;     // E1 branch resolution
  logic [63:0] tb_data_q [8];   // target buffer data, injected into fetch

  logic [11:0] if_insn_fault;
  logic        if_req_valid, if_req_ready;
  logic [31:3] if_req_addr;
  logic [11:0] if_fault_code;
  logic        ifu_rsp_valid;
  logic [63:0] ifu_rsp_data;
  logic [11:0] ifu_rsp_fault;

  sh5_ifu u_ifu (
    .clk, .rst_n,
    .redirect_i(redirect), .redirect_pc_i(redirect_pc), .fetch_en_i(fetch_en),
    .inject_i(d_redirect && !e1_redirect && !flush && !reset_q), .inject_data_i(tb_data_q[d_uop.trb]),
    .insn_valid_o(if_insn_valid), .insn_o(if_insn), .insn_pc_o(if_insn_pc), .insn_fault_o(if_insn_fault),
    .consume_i(if_consume),
    .req_valid_o(if_req_valid), .req_ready_i(if_req_ready), .req_addr_o(if_req_addr),
    .rsp_valid_i(ifu_rsp_valid), .rsp_data_i(ifu_rsp_data), .rsp_fault_i(ifu_rsp_fault)
  );

  assign fetch_en = !sleeping_q && !reset_q;

  // Instruction address translation (Vol. 1 17.7.6, 16.11.1) and instruction
  // cache. With the MMU off the physical address is the effective address and
  // the cache is bypassed. The fault code applies when the cache misses; a
  // cache hit never consults the PTE array (Vol. 4 9.1.1).
  logic ic_inv_valid, ic_inv_ready;

  // Target register buffers (docs/core-design.md 4.4): one fetch block per
  // TR, filled by a preload request after a PT with the likely bit, used by
  // branches predicted taken in D. Invalidated by TR writes, SYNCI, every
  // launch and RTE, ICBI, ICCR0.ICI, PUTCFG to the MMU or cache regions,
  // and whenever the MMU is off (Vol. 1 18.11.2).
  logic         tb_valid_q [8];
  logic [31:3]  tb_addr_q  [8];
  logic         pl_pending_q, pl_sent_q, pl_drop_q;
  logic [2:0]   pl_tr_q;
  logic [31:3]  pl_ea_q, pl_ea_sent_q;
  logic         ic_req_valid, ic_req_ready;
  logic [31:3]  ic_req_ea;
  logic [3:0]   ic_rsp_tag;
  logic         ic_rsp_valid;
  logic [63:0]  ic_rsp_data;
  logic [11:0]  ic_rsp_fault;
  logic [31:0]  d_redirect_pc;

  // a preload is only issued for cachable pages (no speculative device reads)
  logic pl_skip;
  assign pl_skip = pl_pending_q && !(itlb_hit && itlb_cb[1]);
  assign ic_req_valid = (pl_pending_q && !pl_skip) || if_req_valid;
  assign ic_req_ea    = pl_pending_q ? pl_ea_q : if_req_addr;
  assign if_req_ready = ic_req_ready && !pl_pending_q;
  assign ifu_rsp_valid = ic_rsp_valid && !ic_rsp_tag[3];
  assign ifu_rsp_data  = ic_rsp_data;
  assign ifu_rsp_fault = ic_rsp_fault;
  assign itlb_ea = {ic_req_ea, 3'b000};
  always_comb begin
    if_fault_code = 12'h0;
    if (sr[SR_MMU]) begin
      if (!itlb_hit) if_fault_code = EVT_ITLBMISS;
      else if (!itlb_x || (!sr[SR_MD] && !itlb_u)) if_fault_code = EVT_EXECPROT;
    end
  end

  sh5_icache #(.WAYS(ICACHE_WAYS), .SETS(ICACHE_SETS)) u_icache (
    .clk, .rst_n,
    .ice_i(iccr0[CCR0_ENABLE]), .inv_all_i(ici_pulse), .w_lock_i(iccr1[CCR1_W_LOCK +: 4]),
    .req_valid_i(ic_req_valid), .req_ready_o(ic_req_ready),
    .req_ea_i(ic_req_ea), .req_pa_i(sr[SR_MMU] ? itlb_pa[31:3] : ic_req_ea),
    .req_mmu_i(sr[SR_MMU]), .req_cachable_i(itlb_hit && itlb_cb[1]),
    .req_fault_i(if_fault_code), .req_priv_i(sr[SR_MD]), .req_asid_i(cur_asid),
    .req_sh_i(itlb_sh), .req_pru_i(itlb_u),
    .req_tag_i(pl_pending_q ? {1'b1, pl_tr_q} : 4'h0), .rsp_tag_o(ic_rsp_tag),
    .rsp_valid_o(ic_rsp_valid), .rsp_data_o(ic_rsp_data), .rsp_fault_o(ic_rsp_fault),
    .inv_valid_i(ic_inv_valid), .inv_ready_o(ic_inv_ready), .inv_ea_i(e3_q.ea[31:5]), .inv_asid_i(cur_asid),
    .cfg_req_i(ic_cfg_req), .cfg_rvalid_o(ic_cfg_rvalid),
    .cfg_bank_i(getcfg_idx[21]), .cfg_way_i(getcfg_idx[17:16]), .cfg_idx_i(getcfg_idx[11:4]),
    .cfg_reg_i(getcfg_idx[1:0]), .cfg_rdata_o(ic_cfg_rdata),
    .if_req_valid_o(bif_req_valid), .if_req_ready_i(bif_req_ready), .if_req_line_o(bif_req_line),
    .if_req_addr_o(bif_req_addr), .if_rsp_valid_i(bif_rsp_valid), .if_rsp_data_i(bif_rsp_data)
  );

  // ===================================================================
  // Pipeline stage payload
  typedef struct packed {
    uop_t        u;
    logic [63:0] a, b, c;        // GPR source values read in D (ra, rb, rc)
    logic [31:0] trv;            // TR source value read in D
    logic [63:0] fa, fb, fc;     // FR source values (32 or 64 bits)
    logic [63:0] res;            // result or value carried to W
    logic [31:0] ea;             // effective address (TEA on a fault)
    logic [31:0] pa;             // physical address (translated in E2)
    logic [1:0]  cb;             // resolved cache behaviour (E2)
    logic        tsh, tprr, tprw, tpru;  // PTE bits copied into the operand cache tag
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
  logic isa_q;             // 1: SHmedia, 0: SHcompact (Vol. 1 2.5.3)
  logic launched_q;        // cycle after a launch or RTE: take the ISA from the control unit

  assign isa_compact = !isa_q;

  // SHcompact sequencing (docs/core-design.md 13): 16-bit instruction at
  // cpos_q within the fetch word, expansion step useq_q, delay slot of the
  // branch at slot_pc_q when slot_q.
  logic        cpos_q, slot_q;
  logic [3:0]  useq_q;
  logic [31:0] slot_pc_q, d_cpc;
  logic [15:0] d_cinsn;
  logic [31:0] exp_insn, exp_imm;
  logic        exp_last, exp_dbranch;
  assign d_cinsn = cpos_q ? if_insn[31:16] : if_insn[15:0];
  assign d_cpc   = {if_insn_pc[31:2], cpos_q, 1'b0};

  sh5_cexpand u_cexp (
    .insn_i(d_cinsn), .pc_i(d_cpc), .step_i(useq_q), .in_slot_i(slot_q),
    .sr_fr_i(sr[SR_FR]), .sr_sz_i(sr[SR_SZ]), .sr_pr_i(sr[SR_PR]), .sr_fd_i(sr[SR_FD] || !FPU_PRESENT), .sr_s_i(sr[SR_S]),
    .insn_o(exp_insn), .imm32_o(exp_imm), .last_o(exp_last), .dbranch_o(exp_dbranch)
  );

  sh5_decode u_dec (
    .insn_i(isa_compact ? exp_insn : if_insn),
    .pc_i(isa_compact ? (slot_q ? slot_pc_q : d_cpc) : if_insn_pc),
    .priv_i(sr[SR_MD]), .fpu_dis_i(sr[SR_FD] || !FPU_PRESENT),
    .expand_i(isa_compact), .imm32_i(exp_imm), .fetch_fault_i(if_insn_fault),
    .uop_o(d_uop_raw)
  );

  // interrupt acceptance from the current SR (Vol. 1 16.10)
  logic irq_nmi, irq_dbg, irq_ext, irq_any;
  assign irq_nmi = nmi_i;
  assign irq_dbg = debugint_i && !sr[SR_BL];
  assign irq_ext = extint_valid_i && !sr[SR_BL] && (extint_level_i > sr[SR_IMASK +: 4]);
  assign irq_any = cpu_reset_i || irq_nmi || irq_dbg || irq_ext;
  // an SHcompact instruction and a delayed branch with its slot are indivisible
  logic irq_take;
  assign irq_take = irq_any && !(isa_compact && (useq_q != 4'd0 || slot_q));

  always_comb begin
    d_uop = d_uop_raw;
    d_uop.compact = isa_compact;
    d_uop.cinsn   = d_cinsn;
    d_uop.pc_next = isa_compact ? (slot_q ? slot_pc_q + 32'd4 : d_cpc + 32'd2) : if_insn_pc + 32'd4;
    if (irq_take) begin
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
                   (d_uop.cls == UC_ALU && (d_uop.alu == A_CMVEQ || d_uop.alu == A_CMVNE || d_uop.alu == A_SHORI || d_uop.alu == A_DIV1));

  // FCMP results arrive through the FPU: busy from issue (gr_busy) and, before
  // issue, while the instruction is in E1
  function automatic logic gpr_hazard(input logic [5:0] src);
    gpr_hazard = (src != 6'd63) &&
                 ((e1_q.u.valid && e1_q.u.wr_gpr && e1_q.u.long_lat && e1_q.u.rd == src) ||
                  (e2_q.u.valid && e2_q.u.wr_gpr && e2_q.u.long_lat && e2_q.u.rd == src) ||
                  (e1_q.u.valid && e1_q.u.fpu_wr_gpr && e1_q.u.rd == src) ||
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
    // FPU operations in E1 are not yet in the scoreboard
    if (e1_q.u.valid && e1_q.u.wr_fr) fr_inflight |= fr_mask(e1_q.u.fd, e1_q.u.fw);
    if (e2_q.u.valid && e2_q.u.wr_fr && e2_q.u.cls != UC_FPU) fr_inflight |= fr_mask(e2_q.u.fd, e2_q.u.fw);
    if (e3_q.u.valid && e3_q.u.wr_fr && e3_q.u.cls != UC_FPU) fr_inflight |= fr_mask(e3_q.u.fd, e3_q.u.fw);
    if (w_q.u.valid  && w_q.u.wr_fr  && w_q.u.cls  != UC_FPU) fr_inflight |= fr_mask(w_q.u.fd, w_q.u.fw);
  end

  always_comb begin
    d_stall = 1'b0;
    // UC_EXC includes TRAPA, whose operand (ra) must be current
    if (!d_uop.exc_is_irq && !d_uop.exc_is_reset) begin
      if (gpr_hazard(d_uop.ra)) d_stall = 1'b1;
      if (!d_uop.use_imm && gpr_hazard(d_uop.rb)) d_stall = 1'b1;
      if (uses_rc && gpr_hazard(d_uop.rc)) d_stall = 1'b1;
      if (d_uop.wr_gpr && d_uop.rd != 6'd63 && gr_busy_q[d_uop.rd]) d_stall = 1'b1;
      if (d_uop.fpu_wr_gpr && gr_busy_q[d_uop.rd]) d_stall = 1'b1;
      if (|((fr_rdmask | fr_wrmask) & fr_inflight)) d_stall = 1'b1;
      if ((d_uop.cls == UC_FPUTSCR || (d_uop.cls == UC_FMOV && d_uop.fmov == FM_GETSCR) ||
           (d_uop.cls == UC_GETCON && d_uop.fmov == FM_GETSCR)) &&
          (!fpu_fifo_empty || (e1_q.u.valid && e1_q.u.cls == UC_FPU))) d_stall = 1'b1;
      // GETCON USR observes the dirty bits of every earlier instruction (Vol. 4 6.2.14)
      if (d_uop.cls == UC_GETCON && d_uop.ra == CR_USR &&
          (e1_q.u.valid || e2_q.u.valid || e3_q.u.valid || w_q.u.valid || !fpu_fifo_empty)) d_stall = 1'b1;
    end
  end

  assign d_issue   = d_valid && !d_stall && !hold;
  // an SHcompact instruction is consumed after its last step, and the fetch
  // word only after its second half
  assign if_consume = d_issue && (!isa_compact || (exp_last && cpos_q));

  // Prediction (Vol. 1 5.3.3): conditional branches with the likely bit and
  // BLINK are predicted taken when the buffer of their target register
  // holds the block at the current target register value.
  logic [31:0] d_trv;
  logic        d_pred_ok;
  assign d_trv = tr_q[d_uop.trb];
  assign d_pred_ok = sr[SR_MMU] && !isa_compact && tb_valid_q[d_uop.trb] && (tb_addr_q[d_uop.trb] == d_trv[31:3]) &&
                     ((d_uop.cls == UC_BRANCH && d_uop.likely) || (d_uop.cls == UC_BLINK && d_trv[0]));
  assign d_redirect_pc = (d_uop.cls == UC_BLINK) ? {d_trv[31:1], 1'b0} : {d_trv[31:2], 2'b00};
  assign d_redirect = d_issue && d_pred_ok && (d_uop.exc == 12'h0);

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
  sh5_alu u_alu (.op_i(e1_q.u.alu), .a_i(e1_a), .b_i(e1_bop), .c_i(e1_c), .m_i(sr[SR_M]), .q_i(sr[SR_Q]), .r_o(alu_res));
  assign getcon_fpscr = (e1_q.u.cls == UC_GETCON) && (e1_q.u.fmov == FM_GETSCR);

  // effective address and access checks
  logic [63:0] e1_ea64;
  logic        e1_ea_bad, e1_misaligned, e1_is_mem, e1_is_read;
  assign e1_ea64 = e1_a + e1_bop;
  assign e1_ea_bad = !((e1_ea64[63:31] == 33'h0) || (e1_ea64[63:31] == {33{1'b1}}));
  assign e1_is_mem = (e1_q.u.cls == UC_LOAD) || (e1_q.u.cls == UC_STORE) || (e1_q.u.cls == UC_SWAP) ||
                     (e1_q.u.cls == UC_FLOAD) || (e1_q.u.cls == UC_FSTORE) ||
                     (e1_q.u.cls == UC_CACHEOP && e1_q.u.cop != COP_PREFI);
  // OCBP/OCBWB are checked as reads, OCBI/ALLOCO as writes, ICBI as a fetch (Vol. 1 6.6.3)
  assign e1_is_read = (e1_q.u.cls == UC_LOAD) || (e1_q.u.cls == UC_FLOAD) ||
                      (e1_q.u.cls == UC_CACHEOP && (e1_q.u.cop == COP_OCBP || e1_q.u.cop == COP_OCBWB));
  always_comb begin
    case (e1_q.u.msize)
      2'd0: e1_misaligned = 1'b0;
      2'd1: e1_misaligned = e1_ea64[0];
      2'd2: e1_misaligned = |e1_ea64[1:0];
      default: e1_misaligned = |e1_ea64[2:0];
    endcase
    if (e1_q.u.mkind == M_HI || e1_q.u.mkind == M_LO || e1_q.u.cls == UC_CACHEOP) e1_misaligned = 1'b0;
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
  // the cache arrays are block RAM: a GETCFG of a tag or data word holds E1
  // until the cache has read it (one cycle when the cache is idle)
  logic e1_cfg_cache;
  assign e1_cfg_cache = e1_q.u.valid && (e1_q.u.cls == UC_GETCFG) && (e1_q.u.exc == 12'h0) && !older_exc &&
                        (cfg_is_icache_r || cfg_is_dcache_r);
  assign ic_cfg_req = e1_cfg_cache && cfg_is_icache_r;
  assign dc_cfg_req = e1_cfg_cache && cfg_is_dcache_r;
  assign hold_e1 = (fpu_may_issue && !fpu_ready) ||
                   (e1_cfg_cache && !(cfg_is_icache_r ? ic_cfg_rvalid : dc_cfg_rvalid));

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
      UC_SRFLAG: e1_res = e1_a;
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
      e1_exc = (e1_q.u.cls == UC_CACHEOP && e1_q.u.cop == COP_ICBI) ? EVT_IADDERR :
               e1_is_read ? EVT_RADDERR : EVT_WADDERR;
      e1_tea_valid = 1'b1;
      e1_tea = e1_ea64[31:0];
    end
    if (fpu_issue && fpu_trap && e1_exc == 12'h0) begin
      e1_exc = EVT_FPUEXC;
    end
  end

  // branch resolution: redirect when the actual next PC differs from the one
  // fetch is following (BLINK switches the ISA with bit 0 of the target)
  logic        e1_br_taken;
  logic [31:0] e1_actual_pc, e1_followed_pc;
  assign e1_br_taken = (e1_q.u.cls == UC_BRANCH && e1_taken) || (e1_q.u.cls == UC_BLINK);
  // SHmedia conditional branches ignore target bits 1:0; SHcompact BT/BF
  // targets are 2-byte aligned
  assign e1_actual_pc = (e1_q.u.cls == UC_BLINK) ? {e1_trv[31:1], 1'b0} :
                        e1_br_taken ? (e1_q.u.compact ? {e1_trv[31:1], 1'b0} : {e1_trv[31:2], 2'b00}) : e1_q.u.pc_next;
  assign e1_followed_pc = e1_q.u.pred ? e1_q.u.pred_pc : e1_q.u.pc_next;
  assign e1_redirect = e1_q.u.valid && (e1_q.u.exc == 12'h0) && !e1_redir_done_q && !hold &&
                       (e1_q.u.cls == UC_BRANCH || e1_q.u.cls == UC_BLINK) &&
                       (e1_actual_pc != e1_followed_pc);

  // ===================================================================
  // E2: data address translation (Vol. 1 17.7.6, 16.11.3) and memory request
  logic        e2_mem, e2_write, e2_rw_either, e2_cache_ignore;
  assign e2_cache_ignore = 1'b0;
  logic [11:0] e2_mmu_exc;
  logic [31:0] e2_pa;
  assign dtlb_ea = e2_q.ea;
  assign e2_mem = e2_q.u.valid && (e2_q.u.exc == 12'h0) &&
                  ((e2_q.u.cls == UC_LOAD) || (e2_q.u.cls == UC_STORE) || (e2_q.u.cls == UC_SWAP) ||
                   (e2_q.u.cls == UC_FLOAD) || (e2_q.u.cls == UC_FSTORE) ||
                   (e2_q.u.cls == UC_CACHEOP && e2_q.u.cop != COP_PREFI && e2_q.u.cop != COP_ICBI));
  // SWAP.Q, stores, OCBI and ALLOCO need write permission
  assign e2_write = (e2_q.u.cls == UC_STORE) || (e2_q.u.cls == UC_FSTORE) || (e2_q.u.cls == UC_SWAP) ||
                    (e2_q.u.cls == UC_CACHEOP && (e2_q.u.cop == COP_OCBI || e2_q.u.cop == COP_ALLOCO));
  // OCBP/OCBWB are allowed with either read or write permission
  assign e2_rw_either = (e2_q.u.cls == UC_CACHEOP) && (e2_q.u.cop == COP_OCBP || e2_q.u.cop == COP_OCBWB);
  always_comb begin
    e2_mmu_exc = 12'h0;
    e2_pa = e2_q.ea;
    if (e2_mem && sr[SR_MMU]) begin
      e2_pa = dtlb_pa;
      if (!dtlb_hit) begin
        e2_mmu_exc = e2_write ? EVT_WTLBMISS : EVT_RTLBMISS;
      end else if (!sr[SR_MD] && !dtlb_u) begin
        e2_mmu_exc = e2_write ? EVT_WRITEPROT : EVT_READPROT;
      end else if (e2_rw_either ? !(dtlb_r || dtlb_w) : (e2_write ? !dtlb_w : !dtlb_r)) begin
        e2_mmu_exc = e2_write ? EVT_WRITEPROT : EVT_READPROT;
      end
    end
  end

  logic [1:0] e2_cb;
  always_comb begin
    if (!sr[SR_MMU])                 e2_cb = CB_DEVICE;
    else if (!occr0[CCR0_ENABLE])    e2_cb = (dtlb_cb == CB_DEVICE) ? CB_DEVICE : CB_UNCACHED;
    else if (occr0[OCCR0_OWT] && dtlb_cb == CB_WRITEBACK) e2_cb = CB_WRITETHROUGH;
    else                             e2_cb = dtlb_cb;
  end

  logic e2_is_read, e2_ok, e3_issue, e3_issued_q;
  logic e3_is_read, e3_is_store, e3_is_cop, e3_acted_q;
  // operand cache request
  logic        dc_req_valid, dc_req_ready, dc_rsp_valid, dc_idle;
  dkind_t      dc_req_kind;
  logic [31:0] dc_req_ea, dc_req_pa;
  logic [7:0]  dc_req_mask;
  logic [63:0] dc_req_data, dc_rsp_data;
  logic [1:0]  dc_req_cb;
  logic        dc_req_sh, dc_req_prr, dc_req_prw, dc_req_pru;
  logic        ld_req_valid, ld_req_ready, ld_rsp_valid;
  logic [63:0] ld_rsp_data;
  logic        st_pending;
  logic        ld_out_q, ld_have_q, ld_discard_q;
  logic [63:0] ld_data_q;
  assign e2_is_read = e2_mem && (e2_mmu_exc == 12'h0) &&
                      ((e2_q.u.cls == UC_LOAD) || (e2_q.u.cls == UC_SWAP) || (e2_q.u.cls == UC_FLOAD));
  // older instructions must be unable to launch: no pending exception in E3/W
  // loads are ordered behind stores: none may be in E3 (not yet pushed), in W
  // unpushed, or in the store queue
  // The operand cache serialises requests, so a load issued after an older
  // store is ordered behind it; a load must not pass a store or cache
  // operation still waiting in E3.
  assign e2_ok = !(e3_q.u.valid && e3_q.u.exc != 12'h0) && !(w_q.u.valid && w_q.u.exc != 12'h0) &&
                 !((e3_is_store || e3_is_cop) && !e3_acted_q) && !ld_out_q && !ld_have_q;
  // A read that could not issue in E2 issues from E3 when W is not launching.
  assign e3_issue = e3_is_read && !e3_issued_q && !(w_q.u.valid && w_q.u.exc != 12'h0) && !ld_out_q && !ld_have_q;
  assign ld_req_valid = e3_issue || (e2_is_read && !e2_issued_q && e2_ok && !(e3_is_read && !e3_issued_q));
  assign hold_e2 = 1'b0;

  // ===================================================================
  // E3: wait for load data; stores enter the store queue (their exceptions
  // are all known by now; an older instruction in W must not be launching)
  assign e3_is_read = e3_q.u.valid && (e3_q.u.exc == 12'h0) &&
                      ((e3_q.u.cls == UC_LOAD) || (e3_q.u.cls == UC_SWAP) || (e3_q.u.cls == UC_FLOAD));
  assign e3_is_store = e3_q.u.valid && (e3_q.u.exc == 12'h0) &&
                       ((e3_q.u.cls == UC_STORE) || (e3_q.u.cls == UC_FSTORE));
  assign e3_is_cop = e3_q.u.valid && (e3_q.u.exc == 12'h0) && (e3_q.u.cls == UC_CACHEOP) &&
                     (e3_q.u.cop != COP_PREFI);
  logic st_req_valid, st_req_ready;
  assign st_req_valid = (e3_is_store || e3_is_cop) && !e3_acted_q && !(w_q.u.valid && w_q.u.exc != 12'h0);
  // ICBI invalidates the instruction cache directly; every other request goes to the operand cache
  assign ic_inv_valid = st_req_valid && e3_is_cop && (e3_q.u.cop == COP_ICBI) && sr[SR_MMU];
  assign st_req_ready = (e3_is_cop && e3_q.u.cop == COP_ICBI) ? (!sr[SR_MMU] || ic_inv_ready) : dc_req_ready;

  // request multiplexer: E3 store/cache operation, E3 read, E2 read
  always_comb begin
    dc_req_valid = 1'b0;
    dc_req_kind  = DK_LOAD;
    dc_req_ea = e2_q.ea; dc_req_pa = e2_pa; dc_req_mask = e2_q.smask; dc_req_data = e2_q.sdata;
    dc_req_cb = e2_cb; dc_req_sh = dtlb_sh; dc_req_prr = dtlb_r; dc_req_prw = dtlb_w; dc_req_pru = dtlb_u;
    ld_req_ready = 1'b0;
    if (st_req_valid && !(e3_is_cop && e3_q.u.cop == COP_ICBI)) begin
      dc_req_valid = 1'b1;
      dc_req_ea = e3_q.ea; dc_req_pa = e3_q.pa; dc_req_mask = e3_q.smask; dc_req_data = e3_q.sdata;
      dc_req_cb = e3_q.cb; dc_req_sh = e3_q.tsh; dc_req_prr = e3_q.tprr; dc_req_prw = e3_q.tprw; dc_req_pru = e3_q.tpru;
      if (e3_is_store) dc_req_kind = DK_STORE;
      else case (e3_q.u.cop)
        COP_OCBI:  dc_req_kind = DK_OCBI;
        COP_OCBP:  dc_req_kind = DK_OCBP;
        COP_OCBWB: dc_req_kind = DK_OCBWB;
        default:   dc_req_kind = DK_ALLOCO;
      endcase
    end else if (ld_req_valid) begin
      dc_req_valid = 1'b1;
      ld_req_ready = dc_req_ready;
      if (e3_issue) begin
        dc_req_ea = e3_q.ea; dc_req_pa = e3_q.pa; dc_req_mask = e3_q.smask; dc_req_data = e3_q.sdata;
        dc_req_cb = e3_q.cb; dc_req_sh = e3_q.tsh; dc_req_prr = e3_q.tprr; dc_req_prw = e3_q.tprw; dc_req_pru = e3_q.tpru;
        dc_req_kind = (e3_q.u.cls == UC_SWAP) ? DK_SWAP : DK_LOAD;
      end else begin
        dc_req_kind = (e2_q.u.cls == UC_SWAP) ? DK_SWAP : DK_LOAD;
      end
    end
  end

  sh5_dcache #(.WAYS(DCACHE_WAYS), .SETS(DCACHE_SETS)) u_dcache (
    .clk, .rst_n,
    .inv_all_i(oci_pulse), .w_lock_i(occr1[CCR1_W_LOCK +: 4]),
    .req_valid_i(dc_req_valid), .req_ready_o(dc_req_ready), .req_kind_i(dc_req_kind),
    .req_ea_i(dc_req_ea), .req_pa_i(dc_req_pa), .req_mask_i(dc_req_mask), .req_data_i(dc_req_data),
    .req_cb_i(dc_req_cb), .req_mmu_i(sr[SR_MMU]), .req_asid_i(cur_asid), .req_sh_i(dc_req_sh),
    .req_prr_i(dc_req_prr), .req_prw_i(dc_req_prw), .req_pru_i(dc_req_pru),
    .rsp_valid_o(dc_rsp_valid), .rsp_data_o(dc_rsp_data), .idle_o(dc_idle),
    .cfg_req_i(dc_cfg_req), .cfg_rvalid_o(dc_cfg_rvalid),
    .cfg_bank_i(getcfg_idx[21]), .cfg_way_i(getcfg_idx[17:16]), .cfg_idx_i(getcfg_idx[11:4]),
    .cfg_reg_i(getcfg_idx[1:0]), .cfg_rdata_o(dc_cfg_rdata),
    .ld_req_valid_o(bld_req_valid), .ld_req_ready_i(bld_req_ready), .ld_req_swap_o(bld_req_swap),
    .ld_req_line_o(bld_req_line), .ld_req_addr_o(bld_req_addr), .ld_req_mask_o(bld_req_mask),
    .ld_req_data_o(bld_req_data), .ld_rsp_valid_i(bld_rsp_valid), .ld_rsp_data_i(bld_rsp_data),
    .st_req_valid_o(bst_req_valid), .st_req_ready_i(bst_req_ready), .st_req_line_o(bst_req_line),
    .st_req_addr_o(bst_req_addr), .st_req_mask_o(bst_req_mask), .st_req_data_o(bst_req_data)
  );

  // read responses: only for an outstanding read (stores and cache operations also complete)
  assign ld_rsp_valid = dc_rsp_valid && ld_out_q && !ld_discard_q;
  assign ld_rsp_data  = dc_rsp_data;
  assign st_pending   = !dc_idle || bst_pending || ld_out_q;
  assign hold_e3 = (e3_is_read && (!e3_issued_q || !(ld_have_q || ld_rsp_valid))) ||
                   ((e3_is_store || e3_is_cop) && !e3_acted_q && !(st_req_valid && st_req_ready));

  // load data extraction
  logic [63:0] e3_ldata, e3_lres;
  assign e3_ldata = ld_have_q ? ld_data_q : ld_rsp_data;
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
      if (!w_exc && w_q.u.cls == UC_SYNCO && st_pending) w_wait = 1'b1;
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
  assign launch_isa       = !w_q.u.compact;
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
  assign srflag_en   = w_do && !w_exc && (w_q.u.cls == UC_SRFLAG);
  assign srflag_mask = w_q.u.imm[31:0];
  assign srflag_val  = w_q.res[31:0];


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
      redirect = 1'b1; redirect_pc = w_refetch ? w_q.u.pc_next : w_q.u.pc;
    end else if (e1_redirect) begin
      redirect = 1'b1;
      redirect_pc = e1_actual_pc;
    end else if (d_redirect) begin
      redirect = 1'b1;
      redirect_pc = d_redirect_pc;
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
  // Register file writes. Each file has two write ports (the W stage and
  // the FPU's completion), resolved into one enable and one value per
  // register first; the FPU's write wins a same-cycle collision, as the
  // statement order of the first version had it. Vivado could not make a
  // memory of an array written twice in one process and left an undriven
  // net in the register file, so the first bitstream executed with every
  // general register reading as zero (NOTES, 2026-11-07).
  logic [63:0] gr_we;
  logic [63:0] gr_wd [64];
  logic [63:0] fr_we;
  logic [31:0] fr_wd [64];

  always_comb begin
    for (int i = 0; i < 64; i++) begin gr_we[i] = 1'b0; gr_wd[i] = 64'h0; end
    if (gw_en)  begin gr_we[gw_idx] = 1'b1;       gr_wd[gw_idx] = gw_val; end
    if (fgw_en) begin gr_we[fpu_head.rd] = 1'b1;  gr_wd[fpu_head.rd] = {63'h0, fpu_result[0]}; end
  end

  always_comb begin
    for (int i = 0; i < 64; i++) begin fr_we[i] = 1'b0; fr_wd[i] = 32'h0; end
    for (int p = 0; p < 2; p++) begin
      logic         en;
      logic [5:0]   f;
      fwmode_t      m;
      logic [127:0] v;
      if (p == 0) begin en = fw_en;  f = fw_idx;      m = fw_mode;     v = fw_val; end
      else        begin en = ffw_en; f = fpu_head.fd; m = fpu_head.fw; v = fpu_result; end
      if (en) begin
        case (m)
          FW_32:   begin fr_we[f] = 1'b1; fr_wd[f] = v[31:0]; end
          FW_64:   begin
            fr_we[{f[5:1], 1'b0}] = 1'b1; fr_wd[{f[5:1], 1'b0}] = v[63:32];
            fr_we[{f[5:1], 1'b1}] = 1'b1; fr_wd[{f[5:1], 1'b1}] = v[31:0];
          end
          FW_PAIR: begin
            fr_we[{f[5:1], 1'b0}] = 1'b1; fr_wd[{f[5:1], 1'b0}] = v[31:0];
            fr_we[{f[5:1], 1'b1}] = 1'b1; fr_wd[{f[5:1], 1'b1}] = v[63:32];
          end
          default: begin
            fr_we[{f[5:2], 2'b00}] = 1'b1; fr_wd[{f[5:2], 2'b00}] = v[31:0];
            fr_we[{f[5:2], 2'b01}] = 1'b1; fr_wd[{f[5:2], 2'b01}] = v[63:32];
            fr_we[{f[5:2], 2'b10}] = 1'b1; fr_wd[{f[5:2], 2'b10}] = v[95:64];
            fr_we[{f[5:2], 2'b11}] = 1'b1; fr_wd[{f[5:2], 2'b11}] = v[127:96];
          end
        endcase
      end
    end
  end

  always_ff @(posedge clk) begin
    for (int i = 0; i < 64; i++) begin
      if (gr_we[i]) gr_q[i] <= gr_wd[i];
      if (fr_we[i]) fr_q[i] <= fr_wd[i];
    end
  end

  always_ff @(posedge clk) begin
    if (w_do && !w_exc && w_q.u.wr_tr) tr_q[w_q.u.tra] <= w_q.res[31:0];
  end

  // ===================================================================
  // Pipeline registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      e1_q <= '0; e2_q <= '0; e3_q <= '0; w_q <= '0;
      e1_va_q <= '0; e1_vb_q <= '0; e1_mtrx_q <= '0;
      e1_fpu_issued_q <= 1'b0; e1_redir_done_q <= 1'b0; e2_issued_q <= 1'b0;
      e3_have_q <= 1'b0; e3_data_q <= 64'h0; w_acted_q <= 1'b0; e3_acted_q <= 1'b0; e3_issued_q <= 1'b0;
      ld_out_q <= 1'b0; ld_have_q <= 1'b0; ld_discard_q <= 1'b0; ld_data_q <= 64'h0;
      wb_valid_q <= 1'b0; wb_idx_q <= 6'd0; wb_val_q <= 64'h0;
      wbt_valid_q <= 1'b0; wbt_idx_q <= 3'd0; wbt_val_q <= 32'h0;
      serial_block_q <= 1'b0; sleeping_q <= 1'b0; reset_q <= 1'b1;
      isa_q <= 1'b1; launched_q <= 1'b0;
      cpos_q <= 1'b0; slot_q <= 1'b0; useq_q <= 4'd0; slot_pc_q <= 32'h0;
      fr_busy_q <= '0; gr_busy_q <= '0;
      pl_pending_q <= 1'b0; pl_sent_q <= 1'b0; pl_drop_q <= 1'b0; pl_tr_q <= 3'd0; pl_ea_q <= '0; pl_ea_sent_q <= '0;
      for (int t = 0; t < 8; t++) begin tb_valid_q[t] <= 1'b0; tb_addr_q[t] <= '0; tb_data_q[t] <= '0; end
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
      if (ld_req_valid && ld_req_ready) begin
        if (e3_issue) e3_issued_q <= 1'b1;
        else e2_issued_q <= 1'b1;
        ld_out_q <= 1'b1;
      end
      if (st_req_valid && st_req_ready) e3_acted_q <= 1'b1;
      if (dc_rsp_valid && ld_out_q) begin
        ld_out_q <= 1'b0;
        ld_discard_q <= 1'b0;
        if (!ld_discard_q) begin
          ld_have_q <= 1'b1;
          ld_data_q <= dc_rsp_data;
        end
      end
      if (w_do) w_acted_q <= 1'b1;

      // serialization: block decode behind serializing instructions
      if (d_issue && d_uop.serialize) serial_block_q <= 1'b1;
      if (advance && w_q.u.valid && w_q.u.serialize) serial_block_q <= 1'b0;
      if (flush) serial_block_q <= 1'b0;

      // sleep
      if (w_do && !w_exc && w_q.u.cls == UC_SLEEP) sleeping_q <= 1'b1;
      if (sleeping_q && (cpu_reset_i || nmi_i || debugint_i || extint_valid_i)) sleeping_q <= 1'b0;

      // target register buffers and preload
      if (flush || !sr[SR_MMU] || ici_pulse || ic_inv_valid ||
          (putcfg_en && (cfg_is_itlb_w || putcfg_idx[31:24] == 8'h01))) begin
        for (int t = 0; t < 8; t++) tb_valid_q[t] <= 1'b0;
        if (pl_pending_q || pl_sent_q) pl_drop_q <= 1'b1;
        pl_pending_q <= 1'b0;
      end else if (advance && e2_q.u.valid && e2_q.u.cls == UC_PT && e2_q.u.exc == 12'h0) begin
        // a new target: drop the old block, preload the new one when likely
        tb_valid_q[e2_q.u.tra] <= 1'b0;
        if (e2_q.u.likely) begin
          pl_pending_q <= 1'b1;
          pl_tr_q <= e2_q.u.tra;
          pl_ea_q <= e2_q.res[31:3];
          if (pl_sent_q) pl_drop_q <= 1'b1;   // a preload still in flight is superseded
        end
      end
      if (pl_skip) pl_pending_q <= 1'b0;
      if (pl_pending_q && !pl_skip && ic_req_ready) begin
        pl_pending_q <= 1'b0;
        pl_sent_q <= 1'b1;
        pl_ea_sent_q <= pl_ea_q;
      end
      if (ic_rsp_valid && ic_rsp_tag[3]) begin
        pl_sent_q <= 1'b0;
        pl_drop_q <= 1'b0;
        if (!pl_drop_q && ic_rsp_fault == 12'h0 && sr[SR_MMU]) begin
          tb_valid_q[ic_rsp_tag[2:0]] <= 1'b1;
          tb_addr_q[ic_rsp_tag[2:0]]  <= pl_ea_sent_q;
          tb_data_q[ic_rsp_tag[2:0]]  <= ic_rsp_data;
        end
      end

      // ISA tracking: BLINK (and its SHcompact forms) switch with bit 0 of
      // the target; launches and RTE take the ISA of the vector or SPC
      launched_q <= w_launch || w_rte;
      if (launched_q) isa_q <= ctrl_isa;
      if (e1_q.u.valid && e1_q.u.exc == 12'h0 && !e1_redir_done_q && !hold && e1_q.u.cls == UC_BLINK)
        isa_q <= e1_trv[0];

      // SHcompact sequencing
      if (redirect) begin
        cpos_q <= redirect_pc[1]; useq_q <= 4'd0; slot_q <= 1'b0;
      end else if (d_issue && isa_compact && !irq_take) begin
        if (exp_last) begin
          useq_q <= 4'd0;
          cpos_q <= ~cpos_q;
          slot_q <= exp_dbranch;
          if (exp_dbranch) slot_pc_q <= d_cpc;
        end else begin
          useq_q <= useq_q + 4'd1;
        end
      end

      if (advance) begin
        e1_fpu_issued_q <= 1'b0;
        e1_redir_done_q <= 1'b0;
        e2_issued_q <= 1'b0;
        e3_issued_q <= e2_issued_q || (ld_req_valid && ld_req_ready && !e3_issue);
        e3_have_q <= 1'b0;
        if (e3_is_read) ld_have_q <= 1'b0;
        e3_acted_q <= 1'b0;
        w_acted_q <= 1'b0;

        // W <- E3
        w_q <= e3_q;
        if (e3_is_read) w_q.res <= e3_lres;
        if (flush) w_q.u.valid <= 1'b0;

        // E3 <- E2
        e3_q <= e2_q;
        e3_q.pa <= e2_pa;
        e3_q.cb <= e2_cb;
        e3_q.tsh <= dtlb_sh; e3_q.tprr <= dtlb_r; e3_q.tprw <= dtlb_w; e3_q.tpru <= dtlb_u;
        if (e2_mmu_exc != 12'h0) begin
          e3_q.u.exc <= e2_mmu_exc;
          e3_q.u.tea_valid <= 1'b1;
        end
        if (flush) e3_q.u.valid <= 1'b0;

        // E2 <- E1
        e2_q <= e1_q;
        e2_q.res <= e1_res;
        e2_q.u.exc <= e1_exc;
        e2_q.u.tea_valid <= e1_tea_valid;
        e2_q.ea <= (e1_q.u.cls == UC_PT) ? e1_pt_target[31:0] :
                   e1_q.u.fetch_fault ? e1_q.u.pc :
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
          e1_q.u.pred    <= d_redirect;
          e1_q.u.pred_pc <= d_redirect_pc;
          // register file reads, bypassing a write that completes this cycle
          e1_q.a   <= (gw_en && gw_idx == d_uop.ra) ? gw_val :
                      (fgw_en && fpu_head.rd == d_uop.ra) ? {63'h0, fpu_result[0]} : gr_rd(d_uop.ra);
          e1_q.b   <= (gw_en && gw_idx == d_uop.rb) ? gw_val :
                      (fgw_en && fpu_head.rd == d_uop.rb) ? {63'h0, fpu_result[0]} : gr_rd(d_uop.rb);
          e1_q.c   <= (gw_en && gw_idx == d_uop.rc) ? gw_val :
                      (fgw_en && fpu_head.rd == d_uop.rc) ? {63'h0, fpu_result[0]} : gr_rd(d_uop.rc);
          e1_q.trv <= (w_do && !w_exc && w_q.u.wr_tr && w_q.u.tra == d_uop.trb) ? w_q.res[31:0] : tr_q[d_uop.trb];
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
        // Held: operands read in D may be overtaken by writes that complete
        // now (the one-cycle write-back forwarding window closes while the
        // instruction waits in E1), so E1 snoops the register write ports.
        if (gw_en) begin
          if (gw_idx == e1_q.u.ra) e1_q.a <= gw_val;
          if (gw_idx == e1_q.u.rb) e1_q.b <= gw_val;
          if (gw_idx == e1_q.u.rc && e1_q.u.cls != UC_FSTORE) e1_q.c <= gw_val;
        end
        if (fgw_en) begin
          if (fpu_head.rd == e1_q.u.ra) e1_q.a <= {63'h0, fpu_result[0]};
          if (fpu_head.rd == e1_q.u.rb) e1_q.b <= {63'h0, fpu_result[0]};
          if (fpu_head.rd == e1_q.u.rc && e1_q.u.cls != UC_FSTORE) e1_q.c <= {63'h0, fpu_result[0]};
        end
        if (w_do && !w_exc && w_q.u.wr_tr && w_q.u.tra == e1_q.u.trb) e1_q.trv <= w_q.res[31:0];
      end
      if (flush) begin
        // a read in flight for a discarded instruction: drop its response
        if (ld_out_q && !(dc_rsp_valid && ld_out_q)) ld_discard_q <= 1'b1;
        ld_have_q <= 1'b0;
      end
      if (!advance && flush) begin
        // launch while held: the younger stages are discarded (W keeps its
        // acted flag until the pipeline moves)
        e1_q.u.valid <= 1'b0;
        e2_q.u.valid <= 1'b0;
        e3_q.u.valid <= 1'b0;
        e1_fpu_issued_q <= 1'b0;
        e1_redir_done_q <= 1'b0;
        e2_issued_q <= 1'b0;
        e3_issued_q <= 1'b0;
        e3_have_q <= 1'b0;
        e3_acted_q <= 1'b0;
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
  assign trace_insn_o    = w_q.u.compact ? {16'h0, w_q.u.cinsn} : w_q.u.insn;
  assign trace_gpr_we_o  = trace_valid_o && !w_exc && w_q.u.wr_gpr && (w_q.u.cls != UC_FPU) && (w_q.u.rd != 6'd63);
  assign trace_gpr_idx_o = w_q.u.rd;
  assign trace_gpr_val_o = w_result;
  assign trace_fpu_we_o  = fgw_en || ffw_en;
  assign trace_fpu_idx_o = fpu_head.wr_gpr ? fpu_head.rd : fpu_head.fd;
  assign trace_fpu_val_o = fpu_result;
  assign trace_launch_o      = w_launch;
  assign trace_launch_code_o = w_q.u.exc;
  assign trace_launch_tea_o  = w_q.u.exc_is_irq ? w_q.u.imm[31:0] : w_q.ea;   // INTEVT for interrupts
  assign trace_launch_pc_o   = ctrl_new_pc;
  assign trace_pred_o    = e1_q.u.valid && (e1_q.u.exc == 12'h0) && !e1_redir_done_q && !hold &&
                           (e1_q.u.cls == UC_BRANCH || e1_q.u.cls == UC_BLINK) && e1_q.u.pred;
  assign trace_mispred_o = e1_redirect;

  assign dbg_fetch_addr_o = if_insn_pc;
  assign dbg_insn_o       = if_insn;
  assign dbg_op_addr_o    = e2_q.ea;
  assign dbg_op_valid_o   = dc_req_valid;
  logic w_is_store_unused;
  assign w_is_store_unused = w_is_store;

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
                       itlb_r_unused, itlb_w_unused, dtlb_x_unused, itlb_cb[0], e2_cache_ignore, w_is_store_unused, bif_idle,
                       e3_have_q, e3_data_q,
                       ICACHE_WAYS[0], ICACHE_SETS[0], DCACHE_WAYS[0], DCACHE_SETS[0], ITLB_ENTRIES[0], 1'b0};

endmodule
