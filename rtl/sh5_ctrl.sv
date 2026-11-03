// Control registers, FPSCR, configuration registers and event launch
// (Vol. 1 ch. 15-16, Vol. 4 ch. 6-9).

module sh5_ctrl
  import sh5_pkg::*;
#(
  parameter bit FPU_PRESENT = 1'b1,
  parameter int TLB_ENTRIES = 64
) (
  input  logic        clk,
  input  logic        rst_n,

  // architectural state visible to the pipeline
  output logic [31:0] sr_o,
  output logic [31:0] fpscr_o,
  output logic        isa_o,          // ISA bit of the next instruction stream after launch/RTE
  output logic [31:0] iccr0_o,
  output logic [31:0] occr0_o,

  // control register read (E1) and write (W)
  input  logic [5:0]  getcon_idx_i,
  output logic [63:0] getcon_val_o,
  input  logic        putcon_en_i,
  input  logic [5:0]  putcon_idx_i,
  input  logic [63:0] putcon_val_i,

  // configuration register read (E1) and write (W)
  input  logic [31:0] getcfg_idx_i,
  output logic [63:0] getcfg_val_o,
  input  logic        putcfg_en_i,
  input  logic [31:0] putcfg_idx_i,
  input  logic [63:0] putcfg_val_i,

  // FPSCR
  input  logic        fputscr_en_i,
  input  logic [31:0] fputscr_val_i,
  input  logic        fpu_done_i,
  input  logic [5:0]  fpu_cause_i,    // {E,V,Z,O,U,I}

  // USR dirty bits
  input  logic [7:0]  usr_set_gprs_i,
  input  logic [7:0]  usr_set_fprs_i,

  // launch / RTE (W). new_pc_o is valid in the cycle of launch_en_i or rte_en_i.
  input  logic        launch_en_i,
  input  logic [11:0] launch_code_i,  // event code (EVT_*)
  input  logic        launch_is_irq_i,// NMI, DEBUGINT, EXTINT
  input  logic        launch_is_reset_i, // CPURESET
  input  logic [3:0]  launch_irq_level_i,
  input  logic [31:0] launch_irq_code_i, // INTEVT for EXTINT
  input  logic [31:0] launch_pc_i,    // PC saved in SPC
  input  logic        launch_tea_valid_i,
  input  logic [31:0] launch_tea_i,
  input  logic [31:0] launch_tra_i,
  input  logic        rte_en_i,
  output logic [31:0] new_pc_o,

  input  logic [31:0] dbrvec_i,
  input  logic        dbrmode_i
);

  // ------------------------------------------------------------------
  // Control registers
  logic [31:0] sr_q, ssr_q, pssr_q;
  logic [31:0] intevt_q, expevt_q, pexpevt_q, tra_q;
  logic [31:0] spc_q, pspc_q, resvec_q, vbr_q, tea_q;
  logic [63:0] dcr_q, kcr0_q, kcr1_q;
  logic [31:0] ctc_q;
  logic [15:0] usr_q;
  logic [31:0] fpscr_q;
  logic        isa_q;

  assign sr_o    = sr_q;
  assign fpscr_o = fpscr_q;
  assign isa_o   = isa_q;

  function automatic logic [63:0] sext32(input logic [31:0] v);
    sext32 = {{32{v[31]}}, v};
  endfunction

  // ------------------------------------------------------------------
  // Configuration registers: TLB arrays and cache control registers
  logic [31:0] itlb_pteh_q [TLB_ENTRIES];
  logic [31:0] itlb_ptel_q [TLB_ENTRIES];
  logic [31:0] dtlb_pteh_q [TLB_ENTRIES];
  logic [31:0] dtlb_ptel_q [TLB_ENTRIES];
  logic [31:0] iccr0_q, iccr1_q, occr0_q, occr1_q;

  assign iccr0_o = iccr0_q;
  assign occr0_o = occr0_q;

  localparam int TLB_IDX_BITS = $clog2(TLB_ENTRIES);

  function automatic logic cfg_is_itlb(input logic [31:0] idx);
    cfg_is_itlb = (idx[31:24] == 8'h00) && (idx[23:21] == 3'b000) &&
                  (idx[15:4] < 12'(TLB_ENTRIES)) && (idx[3:1] == 3'b000);
  endfunction
  function automatic logic cfg_is_dtlb(input logic [31:0] idx);
    cfg_is_dtlb = (idx[31:24] == 8'h00) && (idx[23:21] == 3'b100) &&
                  (idx[15:4] < 12'(TLB_ENTRIES)) && (idx[3:1] == 3'b000);
  endfunction

  always_comb begin
    logic [TLB_IDX_BITS-1:0] ti;
    ti = getcfg_idx_i[4 +: TLB_IDX_BITS];
    getcfg_val_o = 64'h0;
    if (cfg_is_itlb(getcfg_idx_i)) begin
      getcfg_val_o = {32'h0, getcfg_idx_i[0] ? itlb_ptel_q[ti] : itlb_pteh_q[ti]};
    end else if (cfg_is_dtlb(getcfg_idx_i)) begin
      getcfg_val_o = {32'h0, getcfg_idx_i[0] ? dtlb_ptel_q[ti] : dtlb_pteh_q[ti]};
    end else if (getcfg_idx_i == CFG_ICCR) begin
      getcfg_val_o = {32'h0, iccr0_q};
    end else if (getcfg_idx_i == CFG_ICCR + 32'd1) begin
      getcfg_val_o = {32'h0, iccr1_q};
    end else if (getcfg_idx_i == CFG_OCCR) begin
      getcfg_val_o = {32'h0, occr0_q};
    end else if (getcfg_idx_i == CFG_OCCR + 32'd1) begin
      getcfg_val_o = {32'h0, occr1_q};
    end
  end

  always_ff @(posedge clk) begin
    logic [TLB_IDX_BITS-1:0] ti;
    ti = putcfg_idx_i[4 +: TLB_IDX_BITS];
    if (putcfg_en_i) begin
      if (cfg_is_itlb(putcfg_idx_i)) begin
        if (putcfg_idx_i[0]) itlb_ptel_q[ti] <= putcfg_val_i[31:0] & PTEL_IMPL_MASK_ITLB;
        else                 itlb_pteh_q[ti] <= putcfg_val_i[31:0] & PTEH_IMPL_MASK;
      end else if (cfg_is_dtlb(putcfg_idx_i)) begin
        if (putcfg_idx_i[0]) dtlb_ptel_q[ti] <= putcfg_val_i[31:0] & PTEL_IMPL_MASK_DTLB;
        else                 dtlb_pteh_q[ti] <= putcfg_val_i[31:0] & PTEH_IMPL_MASK;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      iccr0_q <= 32'h0; iccr1_q <= 32'h0; occr0_q <= 32'h0; occr1_q <= 32'h0;
    end else if (putcfg_en_i) begin
      // ICI/OCI (bit 1) read as 0 (Vol. 4 Tables 47, 51)
      if (putcfg_idx_i == CFG_ICCR)           iccr0_q <= putcfg_val_i[31:0] & 32'h0000_0001;
      if (putcfg_idx_i == CFG_ICCR + 32'd1)   iccr1_q <= putcfg_val_i[31:0] & 32'h0000_0f83;
      if (putcfg_idx_i == CFG_OCCR)           occr0_q <= putcfg_val_i[31:0] & 32'h0000_0005;
      if (putcfg_idx_i == CFG_OCCR + 32'd1)   occr1_q <= putcfg_val_i[31:0] & 32'h0000_0f83;
    end
  end

  // ------------------------------------------------------------------
  // GETCON (Vol. 4 6.2)
  always_comb begin
    logic priv;
    priv = sr_q[SR_MD];
    case (getcon_idx_i)
      CR_SR:      getcon_val_o = {32'h0, sr_q};
      CR_SSR:     getcon_val_o = {32'h0, ssr_q};
      CR_PSSR:    getcon_val_o = {32'h0, pssr_q};
      CR_INTEVT:  getcon_val_o = {32'h0, intevt_q};
      CR_EXPEVT:  getcon_val_o = {32'h0, expevt_q};
      CR_PEXPEVT: getcon_val_o = {32'h0, pexpevt_q};
      CR_TRA:     getcon_val_o = {32'h0, tra_q};
      CR_SPC:     getcon_val_o = sext32(spc_q);
      CR_PSPC:    getcon_val_o = sext32(pspc_q);
      CR_RESVEC:  getcon_val_o = sext32(resvec_q);
      CR_VBR:     getcon_val_o = sext32(vbr_q);
      CR_TEA:     getcon_val_o = sext32(tea_q);
      CR_DCR:     getcon_val_o = dcr_q;
      CR_KCR0:    getcon_val_o = kcr0_q;
      CR_KCR1:    getcon_val_o = kcr1_q;
      CR_CTC:     getcon_val_o = (!priv && sr_q[SR_CD]) ? 64'h0 : {32'h0, ctc_q};
      CR_USR:     getcon_val_o = {48'h0, usr_q};
      default:    getcon_val_o = 64'h0;
    endcase
  end

  // ------------------------------------------------------------------
  // Launch (Vol. 1 16.6.2, 16.14) and RTE (16.7)
  logic        ev_debug, ev_tlbmiss, ev_panic;
  logic [31:0] vec_base;       // RESVEC or DBRVEC
  logic [31:0] sr_launch;
  logic [31:0] pc_launch;

  always_comb begin
    ev_debug   = (launch_code_i == EVT_DEBUGIA) || (launch_code_i == EVT_DEBUGIV) ||
                 (launch_code_i == EVT_BREAK)   || (launch_code_i == EVT_DEBUGOA) ||
                 (launch_code_i == EVT_DEBUGSS);
    ev_tlbmiss = (launch_code_i == EVT_ITLBMISS) || (launch_code_i == EVT_RTLBMISS) ||
                 (launch_code_i == EVT_WTLBMISS);
    // an exception (not an interrupt, not a reset) while SR.BL = 1 is a panic
    ev_panic   = !launch_is_irq_i && !launch_is_reset_i && sr_q[SR_BL];
    vec_base   = dbrmode_i ? dbrvec_i : resvec_q;

    // SR after launch
    sr_launch = sr_q;
    sr_launch[SR_MD] = 1'b1;
    sr_launch[SR_BL] = 1'b1;
    if (launch_is_reset_i) begin
      sr_launch[SR_STEP] = 1'b0; sr_launch[SR_WATCH] = 1'b0; sr_launch[SR_MMU] = 1'b0;
      sr_launch[SR_CD] = 1'b0; sr_launch[SR_FR] = 1'b0; sr_launch[SR_SZ] = 1'b0;
      sr_launch[SR_PR] = 1'b0; sr_launch[SR_FD] = 1'b1;
    end else if (ev_panic) begin
      sr_launch[SR_STEP] = 1'b0; sr_launch[SR_WATCH] = 1'b0; sr_launch[SR_MMU] = 1'b0;
    end else if (launch_is_irq_i && launch_code_i == EVT_INT_DEBUGINT) begin
      // DEBUGINT: debug event vectored through VEC + 0x200
      sr_launch[SR_STEP] = 1'b0; sr_launch[SR_WATCH] = 1'b0;
      if (vec_base[0]) sr_launch[SR_MMU] = 1'b0;
    end else if (launch_is_irq_i) begin
      if (launch_code_i != EVT_NMI) sr_launch[SR_IMASK +: 4] = launch_irq_level_i;
    end else if (ev_debug) begin
      sr_launch[SR_STEP] = 1'b0; sr_launch[SR_WATCH] = 1'b0;
      if (vec_base[0]) sr_launch[SR_MMU] = 1'b0;
    end

    // handler address (Vol. 1 Table 151)
    if (launch_is_reset_i || ev_panic) begin
      pc_launch = {vec_base[31:2], 2'b00} + {20'h0, VEC_RESET};
    end else if (launch_is_irq_i && launch_code_i == EVT_INT_DEBUGINT) begin
      pc_launch = {vec_base[31:2], 2'b00} + {20'h0, VEC_DEBUGINT};
    end else if (launch_is_irq_i) begin
      pc_launch = {vbr_q[31:2], 2'b00} + {20'h0, VEC_INTERRUPT};
    end else if (ev_debug) begin
      pc_launch = {vec_base[31:2], 2'b00} + {20'h0, VEC_DEBUGEXC};
    end else if (ev_tlbmiss) begin
      pc_launch = {vbr_q[31:2], 2'b00} + {20'h0, VEC_TLBMISS};
    end else begin
      pc_launch = {vbr_q[31:2], 2'b00} + {20'h0, VEC_EXCEPTION};
    end

    new_pc_o = rte_en_i ? {spc_q[31:2], 2'b00} : pc_launch;
  end

  // ------------------------------------------------------------------
  // State update
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sr_q      <= SR_RESET;
      ssr_q     <= 32'h0;
      pssr_q    <= 32'h0;
      intevt_q  <= 32'h0;
      expevt_q  <= 32'h0;
      pexpevt_q <= 32'h0;
      tra_q     <= 32'h0;
      spc_q     <= 32'h0;
      pspc_q    <= 32'h0;
      resvec_q  <= 32'h0;
      vbr_q     <= 32'h0;
      tea_q     <= 32'h0;
      dcr_q     <= 64'h0;
      kcr0_q    <= 64'h0;
      kcr1_q    <= 64'h0;
      ctc_q     <= 32'h0;
      usr_q     <= 16'h0;
      fpscr_q   <= 32'h0;
      isa_q     <= 1'b1;
    end else begin
      ctc_q <= ctc_q - 32'd1;
      usr_q <= usr_q | {usr_set_fprs_i, usr_set_gprs_i};

      if (fpu_done_i) begin
        fpscr_q[FPSCR_CAUSE +: 6] <= fpu_cause_i;
        fpscr_q[FPSCR_FLAG +: 5]  <= fpscr_q[FPSCR_FLAG +: 5] | fpu_cause_i[4:0];
      end
      if (fputscr_en_i) begin
        fpscr_q <= fputscr_val_i & FPSCR_IMPL_MASK;
      end

      if (putcon_en_i) begin
        case (putcon_idx_i)
          CR_SR: begin
            sr_q <= (sr_q & ~SR_PUTCON_MASK) | (putcon_val_i[31:0] & SR_PUTCON_MASK &
                     (FPU_PRESENT ? 32'hffff_ffff : ~(32'h1 << SR_FD)));
          end
          CR_SSR:     ssr_q     <= putcon_val_i[31:0] & SR_IMPL_MASK;
          CR_PSSR:    pssr_q    <= putcon_val_i[31:0] & SR_IMPL_MASK;
          CR_INTEVT:  intevt_q  <= putcon_val_i[31:0];
          CR_EXPEVT:  expevt_q  <= putcon_val_i[31:0];
          CR_PEXPEVT: pexpevt_q <= putcon_val_i[31:0];
          CR_TRA:     tra_q     <= putcon_val_i[31:0];
          CR_SPC:     spc_q     <= putcon_val_i[31:0];
          CR_PSPC:    pspc_q    <= putcon_val_i[31:0];
          CR_RESVEC:  resvec_q  <= putcon_val_i[31:0] & 32'hffff_fffd;
          CR_VBR:     vbr_q     <= putcon_val_i[31:0] & 32'hffff_fffc;
          CR_TEA:     tea_q     <= putcon_val_i[31:0];
          CR_DCR:     dcr_q     <= putcon_val_i;
          CR_KCR0:    kcr0_q    <= putcon_val_i;
          CR_KCR1:    kcr1_q    <= putcon_val_i;
          CR_CTC:     if (sr_q[SR_MD]) ctc_q <= putcon_val_i[31:0];
          CR_USR:     usr_q     <= putcon_val_i[15:0] | {usr_set_fprs_i, usr_set_gprs_i};
          default: ;
        endcase
      end

      if (rte_en_i) begin
        isa_q <= spc_q[0];
        sr_q  <= ssr_q & SR_IMPL_MASK;
        spc_q <= pspc_q;
        ssr_q <= pssr_q;
      end

      if (launch_en_i) begin
        isa_q <= 1'b1;
        sr_q  <= sr_launch;
        if (ev_panic) begin
          pssr_q    <= ssr_q;
          pspc_q    <= spc_q;
          pexpevt_q <= expevt_q;
        end
        spc_q <= {launch_pc_i[31:1], 1'b1};
        ssr_q <= sr_q;
        if (launch_is_reset_i) begin
          expevt_q <= {20'h0, EVT_CPURESET};
        end else if (launch_is_irq_i) begin
          if (launch_code_i == EVT_NMI) intevt_q <= {20'h0, EVT_NMI};
          else if (launch_code_i == EVT_INT_EXTINT) intevt_q <= launch_irq_code_i;
        end else begin
          expevt_q <= {20'h0, launch_code_i};
          if (!ev_panic) begin
            if (launch_code_i == EVT_TRAP) tra_q <= launch_tra_i;
            if (launch_tea_valid_i) tea_q <= launch_tea_i;
          end
        end
      end
    end
  end

endmodule
