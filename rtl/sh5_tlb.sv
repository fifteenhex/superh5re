// PTE array (TLB): fully associative, software loaded (Vol. 1 17.7,
// Vol. 4 8.5). One instance for instructions (MMUIR), one for data (MMUDR).

module sh5_tlb
  import sh5_pkg::*;
#(
  parameter int ENTRIES = 64,
  parameter bit ITLB    = 1'b0
) (
  input  logic        clk,

  // configuration register access (GETCFG/PUTCFG); idx selects the entry,
  // sel = 0 PTEH, 1 PTEL
  input  logic        cfg_we_i,
  input  logic [$clog2(ENTRIES)-1:0] cfg_widx_i,
  input  logic        cfg_wsel_i,
  input  logic [31:0] cfg_wdata_i,
  input  logic [$clog2(ENTRIES)-1:0] cfg_ridx_i,
  input  logic        cfg_rsel_i,
  output logic [31:0] cfg_rdata_o,

  // lookup
  input  logic [31:0] ea_i,
  input  logic [7:0]  asid_i,
  output logic        hit_o,
  output logic [31:0] pa_o,
  output logic        pr_r_o,
  output logic        pr_w_o,
  output logic        pr_x_o,
  output logic        pr_u_o,
  output logic        sh_o,
  output logic [1:0]  cb_o
);

  logic [31:0] pteh_q [ENTRIES];
  logic [31:0] ptel_q [ENTRIES];

  localparam logic [31:0] PTEL_MASK = ITLB ? PTEL_IMPL_MASK_ITLB : PTEL_IMPL_MASK_DTLB;

  always_ff @(posedge clk) begin
    if (cfg_we_i) begin
      if (cfg_wsel_i) ptel_q[cfg_widx_i] <= cfg_wdata_i & PTEL_MASK;
      else            pteh_q[cfg_widx_i] <= cfg_wdata_i & PTEH_IMPL_MASK;
    end
  end

  assign cfg_rdata_o = cfg_rsel_i ? ptel_q[cfg_ridx_i] : pteh_q[cfg_ridx_i];

  // page offset mask for each entry's size
  function automatic logic [31:12] epn_mask(input logic [1:0] sz);
    case (sz)
      2'd0:    epn_mask = 20'hfffff;   // 4 KB
      2'd1:    epn_mask = 20'hffff0;   // 64 KB
      2'd2:    epn_mask = 20'hfff00;   // 1 MB
      default: epn_mask = 20'he0000;   // 512 MB
    endcase
  endfunction

  always_comb begin
    hit_o  = 1'b0;
    pa_o   = ea_i;
    pr_r_o = 1'b0; pr_w_o = 1'b0; pr_x_o = 1'b0; pr_u_o = 1'b0;
    sh_o   = 1'b0;
    cb_o   = 2'd0;
    for (int i = ENTRIES - 1; i >= 0; i--) begin
      logic [31:12] m;
      m = epn_mask(ptel_q[i][PTEL_SZ +: 2]);
      if (pteh_q[i][PTEH_V] &&
          (pteh_q[i][PTEH_SH] || pteh_q[i][PTEH_ASID +: 8] == asid_i) &&
          (((pteh_q[i][31:12] ^ ea_i[31:12]) & m) == 20'h0)) begin
        hit_o  = 1'b1;
        pa_o   = {(ptel_q[i][31:12] & m) | (ea_i[31:12] & ~m), ea_i[11:0]};
        pr_r_o = ptel_q[i][PTEL_PRR];
        pr_w_o = ptel_q[i][PTEL_PRW];
        pr_x_o = ptel_q[i][PTEL_PRX];
        pr_u_o = ptel_q[i][PTEL_PRU];
        sh_o   = pteh_q[i][PTEH_SH];
        cb_o   = ptel_q[i][PTEL_CB +: 2];
      end
    end
  end

endmodule
