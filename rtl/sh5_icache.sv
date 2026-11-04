// Instruction cache: 4-way, 256 sets, 32-byte blocks, indexed and tagged by
// effective address with ASID/SH and a PRU copy in the tag (Vol. 4 9.1).
// Cached requests are served one at a time in order: a hit answers in the
// next cycle, a miss fills the block with a Load32. Uncached fetches (Load8)
// are passed to the bus port with up to two outstanding.

module sh5_icache
  import sh5_pkg::*;
#(
  parameter int WAYS = 4,
  parameter int SETS = 256
) (
  input  logic         clk,
  input  logic         rst_n,

  // ICCR0.ICE, ICCR0.ICI write, ICCR1 lock bits
  input  logic         ice_i,
  input  logic         inv_all_i,
  input  logic [3:0]   w_lock_i,

  // fetch request: one 8-byte word
  input  logic         req_valid_i,
  output logic         req_ready_o,
  input  logic [31:3]  req_ea_i,
  input  logic [31:3]  req_pa_i,
  input  logic         req_mmu_i,      // MMU enabled: cache may be used
  input  logic         req_cachable_i, // page is cachable (PTEL.CB1) and the translation exists
  input  logic [11:0]  req_fault_i,    // ITLBMISS/EXECPROT if the cache misses; 0 = none
  input  logic         req_priv_i,     // SR.MD
  input  logic [7:0]   req_asid_i,
  input  logic         req_sh_i,
  input  logic         req_pru_i,
  input  logic [3:0]   req_tag_i,      // returned with the response
  output logic [3:0]   rsp_tag_o,
  output logic         rsp_valid_o,
  output logic [63:0]  rsp_data_o,
  output logic [11:0]  rsp_fault_o,

  // ICBI: invalidate the block holding (EA, ASID) if present
  input  logic         inv_valid_i,
  input  logic [31:5]  inv_ea_i,
  input  logic [7:0]   inv_asid_i,

  // configuration view: ICACHETAG0[way,idx] (bank 0) and ICACHEDATA[way,idx,reg] (bank 1)
  input  logic         cfg_bank_i,
  input  logic [1:0]   cfg_way_i,
  input  logic [7:0]   cfg_idx_i,
  input  logic [1:0]   cfg_reg_i,
  output logic [63:0]  cfg_rdata_o,

  // bus fetch port
  output logic         if_req_valid_o,
  input  logic         if_req_ready_i,
  output logic         if_req_line_o,
  output logic [31:3]  if_req_addr_o,
  input  logic         if_rsp_valid_i,
  input  logic [255:0] if_rsp_data_i
);

  // ------------------------------------------------------------------
  // Arrays
  logic         tag_v   [WAYS][SETS];
  logic         tag_sh  [WAYS][SETS];
  logic [7:0]   tag_asid[WAYS][SETS];
  logic [18:0]  tag_ea  [WAYS][SETS];   // EA[31:13]
  logic         tag_pru [WAYS][SETS];
  logic [255:0] data    [WAYS][SETS];
  logic [5:0]   lru     [SETS];

  // ------------------------------------------------------------------
  // LRU helpers (Vol. 4 Table 42): bit 0 (0,1) 1 (0,2) 2 (0,3) 3 (1,2) 4 (1,3) 5 (2,3);
  // a set bit means the lower-numbered way was accessed more recently.
  function automatic logic [5:0] lru_touch(input logic [5:0] l, input logic [1:0] w);
    lru_touch = l;
    case (w)
      2'd0: begin lru_touch[0] = 1'b1; lru_touch[1] = 1'b1; lru_touch[2] = 1'b1; end
      2'd1: begin lru_touch[0] = 1'b0; lru_touch[3] = 1'b1; lru_touch[4] = 1'b1; end
      2'd2: begin lru_touch[1] = 1'b0; lru_touch[3] = 1'b0; lru_touch[5] = 1'b1; end
      default: begin lru_touch[2] = 1'b0; lru_touch[4] = 1'b0; lru_touch[5] = 1'b0; end
    endcase
  endfunction

  // number of ways more recently used than way w (3 = least recent)
  function automatic logic [1:0] lru_rank(input logic [5:0] l, input logic [1:0] w);
    case (w)
      2'd0: lru_rank = 2'(!l[0]) + 2'(!l[1]) + 2'(!l[2]);
      2'd1: lru_rank = 2'(l[0])  + 2'(!l[3]) + 2'(!l[4]);
      2'd2: lru_rank = 2'(l[1])  + 2'(l[3])  + 2'(!l[5]);
      default: lru_rank = 2'(l[2]) + 2'(l[4]) + 2'(l[5]);
    endcase
  endfunction

  // Victim selection (Vol. 4 9.1.3): lowest invalid unlocked way, else the
  // least recently used unlocked way; none when every way is locked.
  function automatic void pick_victim(input logic [5:0] l, input logic [3:0] valid, input logic [3:0] lock,
                                      output logic found, output logic [1:0] way);
    logic [1:0] best_rank;
    found = 1'b0; way = 2'd0; best_rank = 2'd0;
    for (int w = WAYS - 1; w >= 0; w--) begin
      if (!valid[w] && !lock[w]) begin found = 1'b1; way = 2'(w); end
    end
    if (!found) begin
      for (int w = 0; w < WAYS; w++) begin
        if (!lock[w] && (!found || lru_rank(l, 2'(w)) > best_rank)) begin
          found = 1'b1; way = 2'(w); best_rank = lru_rank(l, 2'(w));
        end
      end
    end
  endfunction

  // ------------------------------------------------------------------
  // Lookup of the request address
  logic [7:0]  idx;
  logic [18:0] etag;
  logic [3:0]  hit_way_vec, valid_vec;
  logic        hit;
  logic [1:0]  hit_way;
  logic        use_cache;

  assign idx  = req_ea_i[12:5];
  assign etag = req_ea_i[31:13];
  assign use_cache = req_mmu_i && ice_i && req_cachable_i;

  always_comb begin
    hit_way_vec = '0;
    valid_vec = '0;
    for (int w = 0; w < WAYS; w++) begin
      valid_vec[w] = tag_v[w][idx];
      hit_way_vec[w] = tag_v[w][idx] && (tag_ea[w][idx] == etag) &&
                       (tag_sh[w][idx] || tag_asid[w][idx] == req_asid_i);
    end
    hit = |hit_way_vec;
    hit_way = hit_way_vec[1] ? 2'd1 : hit_way_vec[2] ? 2'd2 : hit_way_vec[3] ? 2'd3 : 2'd0;
  end

  // ------------------------------------------------------------------
  // State machine. Cached requests (hit, fault, fill) are served one at a
  // time; uncached words are passed to the bus port as they arrive, up to
  // two outstanding, and never mixed with a fill or a lookup so that the
  // responses stay in request order.
  typedef enum logic { S_IDLE, S_FILL } state_t;
  state_t state_q;

  logic         rsp_valid_q;
  logic [63:0]  rsp_data_q;
  logic [11:0]  rsp_fault_q;
  logic [3:0]   rsp_tag_q;
  assign rsp_tag_o = rsp_tag_q;
  logic [31:3]  m_ea_q;         // address of the request being filled
  logic [31:3]  m_pa_q;
  logic [7:0]   m_asid_q;
  logic         m_sh_q, m_pru_q;
  logic [1:0]   m_way_q;
  logic         req_sent_q;

  // outstanding uncached words: tag and word select, in order
  logic [1:0]   unc_cnt_q;
  logic         unc_head_q, unc_tail_q;
  logic [3:0]   unc_tag_q [2];
  logic [1:0]   unc_sel_q [2];

  logic victim_found;
  logic [1:0] victim_way;

  always_comb begin
    pick_victim(lru[idx], valid_vec, w_lock_i, victim_found, victim_way);
  end

  // classification of the request at the port (Vol. 4 Table 44)
  logic kind_hit, kind_fault, kind_fill, kind_unc;
  assign kind_hit   = req_mmu_i && use_cache && hit;
  assign kind_fault = req_mmu_i && !kind_hit && (req_fault_i != 12'h0);
  assign kind_fill  = req_mmu_i && !kind_hit && !kind_fault && use_cache && victim_found;
  assign kind_unc   = !kind_hit && !kind_fault && !kind_fill;   // MMU off, uncachable page, cache disabled, all ways locked

  logic unc_issue;   // an uncached request can be presented to the bus port
  assign unc_issue = req_valid_i && kind_unc && (state_q == S_IDLE) && (unc_cnt_q < 2'd2);

  assign req_ready_o = kind_unc ? (unc_issue && if_req_ready_i)
                                : ((state_q == S_IDLE) && (unc_cnt_q == 2'd0));
  assign rsp_valid_o = rsp_valid_q;
  assign rsp_data_o  = rsp_data_q;
  assign rsp_fault_o = rsp_fault_q;

  assign if_req_valid_o = ((state_q == S_FILL) && !req_sent_q) || unc_issue;
  assign if_req_line_o  = (state_q == S_FILL);
  assign if_req_addr_o  = (state_q == S_FILL) ? m_pa_q : req_pa_i;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
      rsp_valid_q <= 1'b0; rsp_data_q <= 64'h0; rsp_fault_q <= 12'h0; rsp_tag_q <= 4'h0;
      m_ea_q <= '0; m_pa_q <= '0; m_asid_q <= 8'h0; m_sh_q <= 1'b0; m_pru_q <= 1'b0;
      m_way_q <= 2'd0; req_sent_q <= 1'b0;
      unc_cnt_q <= 2'd0; unc_head_q <= 1'b0; unc_tail_q <= 1'b0;
      for (int k = 0; k < 2; k++) begin unc_tag_q[k] <= 4'h0; unc_sel_q[k] <= 2'd0; end
      for (int w = 0; w < WAYS; w++) for (int s = 0; s < SETS; s++) tag_v[w][s] <= 1'b0;
      for (int s = 0; s < SETS; s++) lru[s] <= 6'h0;
    end else begin
      // whole-cache invalidation (ICCR0.ICI) and ICBI
      if (inv_all_i) begin
        for (int w = 0; w < WAYS; w++) for (int s = 0; s < SETS; s++) tag_v[w][s] <= 1'b0;
      end else if (inv_valid_i) begin
        for (int w = 0; w < WAYS; w++) begin
          if (tag_v[w][inv_ea_i[12:5]] && tag_ea[w][inv_ea_i[12:5]] == inv_ea_i[31:13] &&
              (tag_sh[w][inv_ea_i[12:5]] || tag_asid[w][inv_ea_i[12:5]] == inv_asid_i))
            tag_v[w][inv_ea_i[12:5]] <= 1'b0;
        end
      end

      rsp_valid_q <= 1'b0;

      // uncached word returned (only while no fill is in flight)
      if (if_rsp_valid_i && unc_cnt_q != 2'd0) begin
        rsp_valid_q <= 1'b1;
        rsp_data_q  <= if_rsp_data_i[64 * unc_sel_q[unc_head_q] +: 64];
        rsp_fault_q <= 12'h0;
        rsp_tag_q   <= unc_tag_q[unc_head_q];
        unc_head_q  <= !unc_head_q;
        unc_cnt_q   <= unc_cnt_q - 2'd1;
      end

      if (req_valid_i && req_ready_o) begin
        if (kind_unc) begin
          unc_tag_q[unc_tail_q] <= req_tag_i;
          unc_sel_q[unc_tail_q] <= req_pa_i[4:3];
          unc_tail_q <= !unc_tail_q;
          unc_cnt_q  <= unc_cnt_q + 2'd1 - ((if_rsp_valid_i && unc_cnt_q != 2'd0) ? 2'd1 : 2'd0);
        end else if (kind_hit) begin
          // hit: protection from the tag copy
          rsp_valid_q <= 1'b1;
          rsp_data_q  <= data[hit_way][idx][64 * req_ea_i[4:3] +: 64];
          rsp_fault_q <= (!req_priv_i && !tag_pru[hit_way][idx]) ? EVT_EXECPROT : 12'h0;
          rsp_tag_q   <= req_tag_i;
          lru[idx] <= lru_touch(lru[idx], hit_way);
        end else if (kind_fault) begin
          rsp_valid_q <= 1'b1;
          rsp_data_q  <= 64'h0;
          rsp_fault_q <= req_fault_i;
          rsp_tag_q   <= req_tag_i;
        end else begin
          state_q <= S_FILL;
          m_ea_q <= req_ea_i; m_pa_q <= req_pa_i; m_asid_q <= req_asid_i; m_sh_q <= req_sh_i;
          m_pru_q <= req_pru_i; m_way_q <= victim_way; rsp_tag_q <= req_tag_i;
          req_sent_q <= 1'b0;
        end
      end

      if (state_q == S_FILL) begin
        if (if_req_valid_o && if_req_ready_i) req_sent_q <= 1'b1;
        if (if_rsp_valid_i) begin
          data[m_way_q][m_ea_q[12:5]]     <= if_rsp_data_i;
          tag_v[m_way_q][m_ea_q[12:5]]    <= 1'b1;
          tag_sh[m_way_q][m_ea_q[12:5]]   <= m_sh_q;
          tag_asid[m_way_q][m_ea_q[12:5]] <= m_asid_q;
          tag_ea[m_way_q][m_ea_q[12:5]]   <= m_ea_q[31:13];
          tag_pru[m_way_q][m_ea_q[12:5]]  <= m_pru_q;
          lru[m_ea_q[12:5]] <= lru_touch(lru[m_ea_q[12:5]], m_way_q);
          rsp_valid_q <= 1'b1;
          rsp_data_q  <= if_rsp_data_i[64 * m_ea_q[4:3] +: 64];
          rsp_fault_q <= 12'h0;
          state_q <= S_IDLE;
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Configuration view (Vol. 4 Tables 49, 50)
  always_comb begin
    if (!cfg_bank_i) begin
      cfg_rdata_o = 64'h0;
      cfg_rdata_o[TAG_V]  = tag_v[cfg_way_i][cfg_idx_i];
      cfg_rdata_o[TAG_SH] = tag_sh[cfg_way_i][cfg_idx_i];
      cfg_rdata_o[TAG_ASID +: 8] = tag_asid[cfg_way_i][cfg_idx_i];
      cfg_rdata_o[TAG_EADDR +: 19] = tag_ea[cfg_way_i][cfg_idx_i];
      cfg_rdata_o[TAG_PRU] = tag_pru[cfg_way_i][cfg_idx_i];
      cfg_rdata_o[TAG_LRU +: 6] = lru[cfg_idx_i];
    end else begin
      cfg_rdata_o = data[cfg_way_i][cfg_idx_i][64 * cfg_reg_i +: 64];
    end
  end

endmodule
