// Instruction cache: 4-way, 256 sets, 32-byte blocks, indexed and tagged by
// effective address with ASID/SH and a PRU copy in the tag (Vol. 4 9.1).
//
// The tag and data arrays are block RAM (sh5_ram_sdp, one per way): a
// lookup presents the set on the read port in the cycle the request is
// accepted and resolves in the next cycle from the port's output, answering
// a hit in that cycle. The valid bits and the LRU state are flops, so that
// ICCR0.ICI can clear every block at once. One lookup can be accepted per
// cycle; a miss fills the block with a Load32 and holds off further
// lookups until the fill completes. Uncached fetches (Load8) are passed to
// the bus port with up to two outstanding.
//
// The read port is shared by lookups, ICBI (which reads the set and clears
// the matching valid bits) and the configuration view (GETCFG of
// ICACHETAG/ICACHEDATA), in that priority; the latter two answer a cycle
// after they take the port. The write port is used by fills only.

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
  output logic         inv_ready_o,
  input  logic [31:5]  inv_ea_i,
  input  logic [7:0]   inv_asid_i,

  // configuration view: ICACHETAG0[way,idx] (bank 0) and ICACHEDATA[way,idx,reg] (bank 1);
  // cfg_req_i held until cfg_rvalid_o, which marks the cycle cfg_rdata_o is valid
  input  logic         cfg_req_i,
  output logic         cfg_rvalid_o,
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
  typedef struct packed {
    logic        sh;
    logic [7:0]  asid;
    logic [18:0] ea;      // EA[31:13]
    logic        pru;
  } itag_t;

  logic         tag_v [WAYS][SETS];
  logic [5:0]   lru   [SETS];

  logic         a_en;
  logic [7:0]   a_addr;
  itag_t        tag_rd  [WAYS];
  logic [255:0] data_rd [WAYS];
  logic         fill_we;
  logic [7:0]   fill_addr;
  itag_t        fill_tag;
  logic [1:0]   m_way_q;

  for (genvar w = 0; w < WAYS; w++) begin : g_way
    sh5_ram_sdp #(.W($bits(itag_t)), .DEPTH(SETS)) u_tag (
      .clk, .re(a_en), .raddr(a_addr), .rdata(tag_rd[w]),
      .we(fill_we && (m_way_q == 2'(w))), .waddr(fill_addr), .wdata(fill_tag)
    );
    sh5_ram_sdp #(.W(256), .DEPTH(SETS)) u_data (
      .clk, .re(a_en), .raddr(a_addr), .rdata(data_rd[w]),
      .we(fill_we && (m_way_q == 2'(w))), .waddr(fill_addr), .wdata(if_rsp_data_i)
    );
  end

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
  // State
  typedef enum logic { S_IDLE, S_FILL } state_t;
  state_t state_q;

  // what the read port was given last cycle
  typedef enum logic [2:0] { LK_NONE, LK_FETCH, LK_FAULT, LK_INV, LK_CFG } lk_t;
  lk_t          lk_q;
  logic [31:3]  lk_ea_q, lk_pa_q;
  logic [7:0]   lk_asid_q;
  logic         lk_sh_q, lk_pru_q, lk_priv_q;
  logic [11:0]  lk_fault_q;
  logic [3:0]   lk_tag_q;

  logic         rsp_valid_q;
  logic [63:0]  rsp_data_q;
  logic [11:0]  rsp_fault_q;
  logic [3:0]   rsp_tag_q;
  logic [31:3]  m_ea_q;         // address of the request being filled
  logic [31:3]  m_pa_q;
  logic [7:0]   m_asid_q;
  logic         m_sh_q, m_pru_q;
  logic         m_line_q;       // 1: allocate the block; 0: every way locked, one word uncached
  logic         req_sent_q;

  // outstanding uncached words: tag and word select, in order
  logic [1:0]   unc_cnt_q;
  logic         unc_head_q, unc_tail_q;
  logic [3:0]   unc_tag_q [2];
  logic [1:0]   unc_sel_q [2];

  // ------------------------------------------------------------------
  // Resolution of the lookup accepted last cycle
  logic [7:0]  lk_idx;
  logic [3:0]  hit_vec, valid_vec;
  logic        hit, victim_found, lk_fill, lk_rsp;
  logic [1:0]  hit_way, victim_way;

  assign lk_idx = lk_ea_q[12:5];
  always_comb begin
    hit_vec = '0; valid_vec = '0;
    for (int w = 0; w < WAYS; w++) begin
      valid_vec[w] = tag_v[w][lk_idx];
      hit_vec[w]   = tag_v[w][lk_idx] && (tag_rd[w].ea == lk_ea_q[31:13]) &&
                     (tag_rd[w].sh || tag_rd[w].asid == lk_asid_q);
    end
    hit = |hit_vec;
    hit_way = hit_vec[1] ? 2'd1 : hit_vec[2] ? 2'd2 : hit_vec[3] ? 2'd3 : 2'd0;
    pick_victim(lru[lk_idx], valid_vec, w_lock_i, victim_found, victim_way);
  end

  // a fetch that missed without a fault goes to the bus (fill, or one word if every way is locked)
  assign lk_fill = (lk_q == LK_FETCH) && !hit && (lk_fault_q == 12'h0);
  // a fetch that hit or faulted answers now
  assign lk_rsp  = ((lk_q == LK_FETCH) && (hit || lk_fault_q != 12'h0)) || (lk_q == LK_FAULT);

  // ------------------------------------------------------------------
  // The read port and the request port
  logic use_cache, req_unc, take_inv, take_cfg, take_req, idle_ok, unc_issue;

  assign use_cache = req_mmu_i && ice_i && req_cachable_i;
  // MMU off, uncachable page or cache disabled, and no fault: a single word on the bus
  assign req_unc   = !use_cache && !(req_mmu_i && req_fault_i != 12'h0);

  // ICBI waits out the edge a fill writes the arrays (same-address collision otherwise)
  assign inv_ready_o = !((state_q == S_FILL) && if_rsp_valid_i);
  assign take_inv    = inv_valid_i && inv_ready_o;
  assign take_cfg    = !take_inv && cfg_req_i && (state_q != S_FILL);

  assign idle_ok  = (state_q == S_IDLE) && !take_inv && !take_cfg && !lk_fill;
  assign unc_issue = req_valid_i && req_unc && idle_ok && (unc_cnt_q < 2'd2);
  assign req_ready_o = req_unc ? (unc_issue && if_req_ready_i)
                               : (idle_ok && (unc_cnt_q == 2'd0));
  assign take_req = req_valid_i && req_ready_o && !req_unc;

  assign a_en   = take_inv || take_cfg || take_req;
  assign a_addr = take_inv ? inv_ea_i[12:5] : take_cfg ? cfg_idx_i : req_ea_i[12:5];

  // ------------------------------------------------------------------
  // Responses: a resolved lookup this cycle, else what the bus delivered last cycle
  assign rsp_valid_o = rsp_valid_q || lk_rsp;
  assign rsp_tag_o   = lk_rsp ? lk_tag_q : rsp_tag_q;
  assign rsp_data_o  = lk_rsp ? data_rd[hit_way][64 * lk_ea_q[4:3] +: 64] : rsp_data_q;
  always_comb begin
    if (!lk_rsp)                          rsp_fault_o = rsp_fault_q;
    else if (lk_q == LK_FETCH && hit)     rsp_fault_o = (!lk_priv_q && !tag_rd[hit_way].pru) ? EVT_EXECPROT : 12'h0;
    else                                  rsp_fault_o = lk_fault_q;
  end

  assign cfg_rvalid_o = (lk_q == LK_CFG);

  // bus port
  assign if_req_valid_o = ((state_q == S_FILL) && !req_sent_q) || unc_issue;
  assign if_req_line_o  = (state_q == S_FILL) && m_line_q;
  assign if_req_addr_o  = (state_q == S_FILL) ? m_pa_q : req_pa_i;

  // fill write
  assign fill_we   = (state_q == S_FILL) && if_rsp_valid_i && m_line_q;
  assign fill_addr = m_ea_q[12:5];
  assign fill_tag  = '{sh: m_sh_q, asid: m_asid_q, ea: m_ea_q[31:13], pru: m_pru_q};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
      lk_q <= LK_NONE; lk_ea_q <= '0; lk_pa_q <= '0; lk_asid_q <= 8'h0;
      lk_sh_q <= 1'b0; lk_pru_q <= 1'b0; lk_priv_q <= 1'b0; lk_fault_q <= 12'h0; lk_tag_q <= 4'h0;
      rsp_valid_q <= 1'b0; rsp_data_q <= 64'h0; rsp_fault_q <= 12'h0; rsp_tag_q <= 4'h0;
      m_ea_q <= '0; m_pa_q <= '0; m_asid_q <= 8'h0; m_sh_q <= 1'b0; m_pru_q <= 1'b0;
      m_way_q <= 2'd0; m_line_q <= 1'b0; req_sent_q <= 1'b0;
      unc_cnt_q <= 2'd0; unc_head_q <= 1'b0; unc_tail_q <= 1'b0;
      for (int k = 0; k < 2; k++) begin unc_tag_q[k] <= 4'h0; unc_sel_q[k] <= 2'd0; end
      for (int w = 0; w < WAYS; w++) for (int s = 0; s < SETS; s++) tag_v[w][s] <= 1'b0;
      for (int s = 0; s < SETS; s++) lru[s] <= 6'h0;
    end else begin
      // whole-cache invalidation (ICCR0.ICI)
      if (inv_all_i) begin
        for (int w = 0; w < WAYS; w++) for (int s = 0; s < SETS; s++) tag_v[w][s] <= 1'b0;
      end

      // ---- the lookup accepted last cycle ----
      case (lk_q)
        LK_FETCH: begin
          if (hit) begin
            lru[lk_idx] <= lru_touch(lru[lk_idx], hit_way);
          end else if (lk_fault_q == 12'h0) begin
            state_q <= S_FILL;
            m_ea_q <= lk_ea_q; m_pa_q <= lk_pa_q; m_asid_q <= lk_asid_q; m_sh_q <= lk_sh_q;
            m_pru_q <= lk_pru_q; m_way_q <= victim_way; m_line_q <= victim_found;
            rsp_tag_q <= lk_tag_q;
            req_sent_q <= 1'b0;
          end
        end
        LK_INV: begin
          for (int w = 0; w < WAYS; w++)
            if (hit_vec[w]) tag_v[w][lk_idx] <= 1'b0;
        end
        default: ;
      endcase

      // ---- what the read port is given this cycle ----
      lk_q <= LK_NONE;
      if (take_inv) begin
        lk_q <= LK_INV;
        lk_ea_q <= {inv_ea_i, 2'b00}; lk_asid_q <= inv_asid_i;
      end else if (take_cfg) begin
        lk_q <= LK_CFG;
      end else if (take_req) begin
        lk_q <= use_cache ? LK_FETCH : LK_FAULT;
        lk_ea_q <= req_ea_i; lk_pa_q <= req_pa_i; lk_asid_q <= req_asid_i;
        lk_sh_q <= req_sh_i; lk_pru_q <= req_pru_i; lk_priv_q <= req_priv_i;
        lk_fault_q <= req_fault_i; lk_tag_q <= req_tag_i;
      end

      // ---- the bus ----
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

      if (unc_issue && if_req_ready_i) begin
        unc_tag_q[unc_tail_q] <= req_tag_i;
        unc_sel_q[unc_tail_q] <= req_pa_i[4:3];
        unc_tail_q <= !unc_tail_q;
        unc_cnt_q  <= unc_cnt_q + 2'd1 - ((if_rsp_valid_i && unc_cnt_q != 2'd0) ? 2'd1 : 2'd0);
      end

      if (state_q == S_FILL) begin
        if (if_req_valid_o && if_req_ready_i) req_sent_q <= 1'b1;
        if (if_rsp_valid_i) begin
          if (m_line_q) begin
            tag_v[m_way_q][m_ea_q[12:5]] <= 1'b1;
            lru[m_ea_q[12:5]] <= lru_touch(lru[m_ea_q[12:5]], m_way_q);
          end
          rsp_valid_q <= 1'b1;
          rsp_data_q  <= if_rsp_data_i[64 * m_ea_q[4:3] +: 64];
          rsp_fault_q <= 12'h0;
          state_q <= S_IDLE;
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Configuration view (Vol. 4 Tables 49, 50), valid with cfg_rvalid_o
  always_comb begin
    if (!cfg_bank_i) begin
      cfg_rdata_o = 64'h0;
      cfg_rdata_o[TAG_V]  = tag_v[cfg_way_i][cfg_idx_i];
      cfg_rdata_o[TAG_SH] = tag_rd[cfg_way_i].sh;
      cfg_rdata_o[TAG_ASID +: 8] = tag_rd[cfg_way_i].asid;
      cfg_rdata_o[TAG_EADDR +: 19] = tag_rd[cfg_way_i].ea;
      cfg_rdata_o[TAG_PRU] = tag_rd[cfg_way_i].pru;
      cfg_rdata_o[TAG_LRU +: 6] = lru[cfg_idx_i];
    end else begin
      cfg_rdata_o = data_rd[cfg_way_i][64 * cfg_reg_i +: 64];
    end
  end

endmodule
