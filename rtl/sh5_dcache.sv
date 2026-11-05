// Operand cache: 4-way, 256 sets, 32-byte blocks, indexed and tagged by
// effective address with a physical address tag per block for alias
// resolution and physical look-ups (Vol. 4 9.1, Tables 44, 53, 54).
// Requests are processed one at a time. Write-back or write-through per
// block (tag WT), 6-bit LRU, way locking; uncached and device accesses and
// accesses with the MMU off go to the bus as single words.
//
// The tag and data arrays are block RAM (sh5_ram_sdp, one per way). The
// read port takes the set of the request being accepted (or of a GETCFG)
// while idle; S_LOOKUP and the states after it work from the port's output,
// which holds until the next request is accepted. Writes use the other port
// and only happen outside S_IDLE, so a read and a write never meet at one
// edge. The valid and dirty bits and the LRU state are flops: OCCR0.OCI
// clears every valid bit at once, and they are read for every way of a set.

module sh5_dcache
  import sh5_pkg::*;
  import sh5_uop_pkg::*;
#(
  parameter int WAYS = 4,
  parameter int SETS = 256
) (
  input  logic         clk,
  input  logic         rst_n,

  input  logic         inv_all_i,      // OCCR0.OCI written with 1
  input  logic [3:0]   w_lock_i,       // OCCR1.OW_LOCK

  // request
  input  logic         req_valid_i,
  output logic         req_ready_o,
  input  dkind_t       req_kind_i,
  input  logic [31:0]  req_ea_i,
  input  logic [31:0]  req_pa_i,
  input  logic [7:0]   req_mask_i,     // byte lanes of the 8-byte word
  input  logic [63:0]  req_data_i,     // store / swap data in its lanes
  input  logic [1:0]   req_cb_i,       // resolved behaviour: CB_UNCACHED, CB_DEVICE, CB_WRITEBACK, CB_WRITETHROUGH
  input  logic         req_mmu_i,
  input  logic [7:0]   req_asid_i,
  input  logic         req_sh_i,
  input  logic         req_prr_i,
  input  logic         req_prw_i,
  input  logic         req_pru_i,
  output logic         rsp_valid_o,    // loads and swaps: data; every other request: completion
  output logic [63:0]  rsp_data_o,
  output logic         idle_o,         // no request in progress

  // configuration view: OCACHETAG0/1[way,idx] (bank 0, reg 0/1), OCACHEDATA[way,idx,reg] (bank 1);
  // cfg_req_i held until cfg_rvalid_o, which marks the cycle cfg_rdata_o is valid
  input  logic         cfg_req_i,
  output logic         cfg_rvalid_o,
  input  logic         cfg_bank_i,
  input  logic [1:0]   cfg_way_i,
  input  logic [7:0]   cfg_idx_i,
  input  logic [1:0]   cfg_reg_i,
  output logic [63:0]  cfg_rdata_o,

  // bus data read port
  output logic         ld_req_valid_o,
  input  logic         ld_req_ready_i,
  output logic         ld_req_swap_o,
  output logic         ld_req_line_o,
  output logic [31:3]  ld_req_addr_o,
  output logic [7:0]   ld_req_mask_o,
  output logic [63:0]  ld_req_data_o,
  input  logic         ld_rsp_valid_i,
  input  logic [255:0] ld_rsp_data_i,
  // bus store port
  output logic         st_req_valid_o,
  input  logic         st_req_ready_i,
  output logic         st_req_line_o,
  output logic [31:3]  st_req_addr_o,
  output logic [7:0]   st_req_mask_o,
  output logic [255:0] st_req_data_o
);

  // ------------------------------------------------------------------
  // Arrays
  typedef struct packed {
    logic        sh;
    logic [7:0]  asid;
    logic [18:0] ea;      // EA[31:13]
    logic        prr, prw, pru;
    logic        wt;
    logic [19:0] pa;      // PA[31:12]
  } dtag_t;

  logic         tag_v [WAYS][SETS];
  logic         tag_u [WAYS][SETS];   // dirty
  logic [5:0]   lru   [SETS];

  logic         a_en;
  logic [7:0]   a_addr, b_addr;
  dtag_t        tag_rd  [WAYS];
  logic [255:0] data_rd [WAYS];
  logic [3:0]   tag_we, data_we;
  dtag_t        tag_wd;
  logic [255:0] data_wd;

  for (genvar w = 0; w < WAYS; w++) begin : g_way
    sh5_ram_sdp #(.W($bits(dtag_t)), .DEPTH(SETS)) u_tag (
      .clk, .re(a_en), .raddr(a_addr), .rdata(tag_rd[w]),
      .we(tag_we[w]), .waddr(b_addr), .wdata(tag_wd)
    );
    sh5_ram_sdp #(.W(256), .DEPTH(SETS)) u_data (
      .clk, .re(a_en), .raddr(a_addr), .rdata(data_rd[w]),
      .we(data_we[w]), .waddr(b_addr), .wdata(data_wd)
    );
  end

  function automatic logic [5:0] lru_touch(input logic [5:0] l, input logic [1:0] w);
    lru_touch = l;
    case (w)
      2'd0: begin lru_touch[0] = 1'b1; lru_touch[1] = 1'b1; lru_touch[2] = 1'b1; end
      2'd1: begin lru_touch[0] = 1'b0; lru_touch[3] = 1'b1; lru_touch[4] = 1'b1; end
      2'd2: begin lru_touch[1] = 1'b0; lru_touch[3] = 1'b0; lru_touch[5] = 1'b1; end
      default: begin lru_touch[2] = 1'b0; lru_touch[4] = 1'b0; lru_touch[5] = 1'b0; end
    endcase
  endfunction

  function automatic logic [1:0] lru_rank(input logic [5:0] l, input logic [1:0] w);
    case (w)
      2'd0: lru_rank = 2'(!l[0]) + 2'(!l[1]) + 2'(!l[2]);
      2'd1: lru_rank = 2'(l[0])  + 2'(!l[3]) + 2'(!l[4]);
      2'd2: lru_rank = 2'(l[1])  + 2'(l[3])  + 2'(!l[5]);
      default: lru_rank = 2'(l[2]) + 2'(l[4]) + 2'(l[5]);
    endcase
  endfunction

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

  // physical address [31:3] of the block held in a way (PA bits 11:5 equal EA bits 11:5)
  function automatic logic [31:3] blk_addr(input logic [19:0] pa_tag, input logic [31:0] ea);
    blk_addr = {pa_tag, ea[11:5], 2'b00};
  endfunction

  // merge the store bytes into a block word
  function automatic logic [255:0] merge_word(input logic [255:0] blk, input logic [1:0] word,
                                              input logic [63:0] d, input logic [7:0] mask);
    merge_word = blk;
    for (int b = 0; b < 8; b++)
      if (mask[b]) merge_word[64 * word + 8 * b +: 8] = d[8 * b +: 8];
  endfunction

  // ------------------------------------------------------------------
  // Registered request and state
  typedef enum logic [3:0] {
    S_IDLE, S_LOOKUP, S_WB, S_FILL_REQ, S_FILL_WAIT, S_UNC_REQ, S_UNC_WAIT, S_ST_UNC
  } state_t;
  state_t state_q, state_d;

  dkind_t      r_kind;
  logic [31:0] r_ea, r_pa;
  logic [7:0]  r_mask, r_asid;
  logic [63:0] r_data;
  logic [1:0]  r_cb;
  logic        r_mmu, r_sh, r_prr, r_prw, r_pru;

  logic [1:0]   m_way_q, m_way_d;             // way being filled / written back
  logic [255:0] wb_data_q, wb_data_d;
  logic [31:3]  wb_addr_q, wb_addr_d;
  logic         wb_then_fill_q, wb_then_fill_d; // after the write-back: fill (1) or finish (0)
  logic         fill_alloco_q, fill_alloco_d;   // allocate without fetch (ALLOCO)
  logic [63:0]  rsp_data_q, rsp_data_d;
  logic         rsp_valid_q, rsp_valid_d;
  logic         cfg_rvalid_q;

  // flop array updates, all at the registered request's set
  logic [3:0]   v_we, v_wd, u_we, u_wd;
  logic         lru_we;
  logic [5:0]   lru_wd;
  logic         alloc;            // write the tags of way alloc_way for the registered request
  logic [1:0]   alloc_way;
  logic         alloc_dirty;

  logic [7:0]  idx;
  logic        cachable;              // write-back or write-through behaviour
  logic [3:0]  ea_hit_vec, pa_hit_vec, valid_vec;
  logic        ea_hit, pa_hit;
  logic [1:0]  ea_way, pa_way, hit_way;
  logic        victim_found;
  logic [1:0]  victim_way;

  assign idx = r_ea[12:5];
  assign cachable = r_mmu && (r_cb == CB_WRITEBACK || r_cb == CB_WRITETHROUGH);

  always_comb begin
    ea_hit_vec = '0; pa_hit_vec = '0; valid_vec = '0;
    for (int w = 0; w < WAYS; w++) begin
      valid_vec[w]  = tag_v[w][idx];
      ea_hit_vec[w] = tag_v[w][idx] && (tag_rd[w].ea == r_ea[31:13]) &&
                      (tag_rd[w].sh || tag_rd[w].asid == r_asid);
      pa_hit_vec[w] = tag_v[w][idx] && (tag_rd[w].pa == r_pa[31:12]);
    end
    ea_hit = |ea_hit_vec;
    pa_hit = |pa_hit_vec;
    ea_way = ea_hit_vec[1] ? 2'd1 : ea_hit_vec[2] ? 2'd2 : ea_hit_vec[3] ? 2'd3 : 2'd0;
    pa_way = pa_hit_vec[1] ? 2'd1 : pa_hit_vec[2] ? 2'd2 : pa_hit_vec[3] ? 2'd3 : 2'd0;
    hit_way = ea_hit ? ea_way : pa_way;
    pick_victim(lru[idx], valid_vec, w_lock_i, victim_found, victim_way);
  end

  // ------------------------------------------------------------------
  // The request port. Fast path for uncached words: a store enters the bus
  // store queue and a load is presented to the bus read port in the cycle
  // it is accepted.
  logic req_unc, fast_st, fast_ld, take_cfg;
  assign req_unc  = !(req_mmu_i && (req_cb_i == CB_WRITEBACK || req_cb_i == CB_WRITETHROUGH));
  assign take_cfg = cfg_req_i && (state_q == S_IDLE);
  assign fast_st  = (state_q == S_IDLE) && !take_cfg && req_valid_i && req_unc && (req_kind_i == DK_STORE);
  assign fast_ld  = (state_q == S_IDLE) && !take_cfg && req_valid_i && req_unc && (req_kind_i == DK_LOAD);

  assign req_ready_o  = (state_q == S_IDLE) && !take_cfg && !(fast_st && !st_req_ready_i);
  assign idle_o       = (state_q == S_IDLE);
  assign rsp_valid_o  = rsp_valid_q;
  assign rsp_data_o   = rsp_data_q;
  assign cfg_rvalid_o = cfg_rvalid_q;

  // the read port: the set of the request being accepted, or the GETCFG set
  assign a_en   = (state_q == S_IDLE);
  assign a_addr = take_cfg ? cfg_idx_i : req_ea_i[12:5];
  assign b_addr = idx;

  // bus ports
  assign ld_req_valid_o = (state_q == S_FILL_REQ) || (state_q == S_UNC_REQ) || fast_ld;
  assign ld_req_swap_o  = (state_q == S_UNC_REQ) && (r_kind == DK_SWAP);
  assign ld_req_line_o  = (state_q == S_FILL_REQ);
  assign ld_req_addr_o  = fast_ld ? req_pa_i[31:3] : r_pa[31:3];
  assign ld_req_mask_o  = fast_ld ? req_mask_i : r_mask;
  assign ld_req_data_o  = fast_ld ? req_data_i : r_data;
  assign st_req_valid_o = (state_q == S_WB) || (state_q == S_ST_UNC) || fast_st;
  assign st_req_line_o  = (state_q == S_WB);
  assign st_req_addr_o  = (state_q == S_WB) ? wb_addr_q : fast_st ? req_pa_i[31:3] : r_pa[31:3];
  assign st_req_mask_o  = fast_st ? req_mask_i : r_mask;
  always_comb begin
    st_req_data_o = wb_data_q;
    if (fast_st) begin
      st_req_data_o = '0;
      st_req_data_o[64 * req_pa_i[4:3] +: 64] = req_data_i;
    end else if (state_q == S_ST_UNC) begin
      st_req_data_o = '0;
      st_req_data_o[64 * r_pa[4:3] +: 64] = r_data;
    end
  end

  // ------------------------------------------------------------------
  // Next state, array writes
  always_comb begin
    state_d = state_q;
    rsp_valid_d = 1'b0; rsp_data_d = rsp_data_q;
    m_way_d = m_way_q; wb_data_d = wb_data_q; wb_addr_d = wb_addr_q;
    wb_then_fill_d = wb_then_fill_q; fill_alloco_d = fill_alloco_q;
    tag_we = '0; data_we = '0; tag_wd = '0; data_wd = '0;
    v_we = '0; v_wd = '0; u_we = '0; u_wd = '0; lru_we = 1'b0; lru_wd = lru[idx];
    alloc = 1'b0; alloc_way = 2'd0; alloc_dirty = 1'b0;

    case (state_q)
      S_IDLE: begin
        if (req_valid_i && req_ready_o) begin
          if (fast_st)      rsp_valid_d = 1'b1;                      // queued: complete
          else if (fast_ld) state_d = ld_req_ready_i ? S_UNC_WAIT : S_UNC_REQ;
          else              state_d = S_LOOKUP;
        end
      end

      S_LOOKUP: begin
        case (r_kind)
          DK_LOAD, DK_STORE: begin
            if (!cachable) begin
              // device, uncached, or MMU off: single word on the bus
              state_d = (r_kind == DK_LOAD) ? S_UNC_REQ : S_ST_UNC;
            end else if (ea_hit || pa_hit) begin
              // a physical hit in another way is an alias: re-tag that way
              // (Vol. 1 18.10) and continue as a hit
              if (!ea_hit) begin
                tag_we[hit_way] = 1'b1;
                tag_wd = tag_rd[hit_way];
                tag_wd.sh = r_sh; tag_wd.asid = r_asid; tag_wd.ea = r_ea[31:13];
                tag_wd.prr = r_prr; tag_wd.prw = r_prw; tag_wd.pru = r_pru;
                tag_wd.wt = (r_cb == CB_WRITETHROUGH);
              end
              lru_we = 1'b1; lru_wd = lru_touch(lru[idx], hit_way);
              if (r_kind == DK_LOAD) begin
                rsp_data_d = data_rd[hit_way][64 * r_ea[4:3] +: 64];
                rsp_valid_d = 1'b1;
                state_d = S_IDLE;
              end else begin
                data_we[hit_way] = 1'b1;
                data_wd = merge_word(data_rd[hit_way], r_ea[4:3], r_data, r_mask);
                if (r_cb == CB_WRITETHROUGH || tag_rd[hit_way].wt) begin
                  state_d = S_ST_UNC;          // write through to memory as well
                end else begin
                  u_we[hit_way] = 1'b1; u_wd[hit_way] = 1'b1;
                  rsp_valid_d = 1'b1;
                  state_d = S_IDLE;
                end
              end
            end else if (r_kind == DK_STORE && r_cb == CB_WRITETHROUGH) begin
              state_d = S_ST_UNC;              // write-through miss: no allocation
            end else if (!victim_found) begin
              state_d = (r_kind == DK_LOAD) ? S_UNC_REQ : S_ST_UNC;   // every way locked
            end else begin
              m_way_d = victim_way;
              fill_alloco_d = 1'b0;
              if (tag_v[victim_way][idx] && tag_u[victim_way][idx]) begin
                wb_data_d = data_rd[victim_way];
                wb_addr_d = blk_addr(tag_rd[victim_way].pa, r_ea);
                wb_then_fill_d = 1'b1;
                state_d = S_WB;
              end else begin
                state_d = S_FILL_REQ;
              end
            end
          end

          DK_SWAP: begin
            // physical look-up: purge or invalidate, then swap in memory (Vol. 1 6.5.1)
            if (r_mmu && pa_hit) begin
              v_we[pa_way] = 1'b1; v_wd[pa_way] = 1'b0;
              if (tag_u[pa_way][idx]) begin
                wb_data_d = data_rd[pa_way];
                wb_addr_d = blk_addr(tag_rd[pa_way].pa, r_ea);
                wb_then_fill_d = 1'b0;
                state_d = S_WB;
              end else begin
                state_d = S_UNC_REQ;
              end
            end else begin
              state_d = S_UNC_REQ;
            end
          end

          DK_OCBI: begin
            if (pa_hit) begin v_we[pa_way] = 1'b1; v_wd[pa_way] = 1'b0; end
            rsp_valid_d = 1'b1;
            state_d = S_IDLE;
          end

          DK_OCBP, DK_OCBWB: begin
            if (pa_hit) begin
              if (r_kind == DK_OCBP) begin v_we[pa_way] = 1'b1; v_wd[pa_way] = 1'b0; end
              u_we[pa_way] = 1'b1; u_wd[pa_way] = 1'b0;
              lru_we = 1'b1; lru_wd = lru_touch(lru[idx], pa_way);
              if (tag_u[pa_way][idx]) begin
                wb_data_d = data_rd[pa_way];
                wb_addr_d = blk_addr(tag_rd[pa_way].pa, r_ea);
                wb_then_fill_d = 1'b0;
                state_d = S_WB;
              end else begin
                rsp_valid_d = 1'b1;
                state_d = S_IDLE;
              end
            end else begin
              rsp_valid_d = 1'b1;
              state_d = S_IDLE;
            end
          end

          default: begin // DK_ALLOCO: write-back behaviour only (Vol. 4 9.1.5)
            if (r_mmu && r_cb == CB_WRITEBACK && !ea_hit && !pa_hit && victim_found) begin
              m_way_d = victim_way;
              fill_alloco_d = 1'b1;
              if (tag_v[victim_way][idx] && tag_u[victim_way][idx]) begin
                wb_data_d = data_rd[victim_way];
                wb_addr_d = blk_addr(tag_rd[victim_way].pa, r_ea);
                wb_then_fill_d = 1'b1;
                state_d = S_WB;
              end else begin
                data_we[victim_way] = 1'b1; data_wd = '0;
                alloc = 1'b1; alloc_way = victim_way; alloc_dirty = 1'b1;
                rsp_valid_d = 1'b1;
                state_d = S_IDLE;
              end
            end else begin
              if (ea_hit || pa_hit) begin lru_we = 1'b1; lru_wd = lru_touch(lru[idx], hit_way); end
              rsp_valid_d = 1'b1;
              state_d = S_IDLE;
            end
          end
        endcase
      end

      S_WB: begin
        if (st_req_ready_i) begin
          if (!wb_then_fill_q) begin
            // purge/write-back done; a swap continues on the bus
            if (r_kind == DK_SWAP) state_d = S_UNC_REQ;
            else begin rsp_valid_d = 1'b1; state_d = S_IDLE; end
          end else if (fill_alloco_q) begin
            data_we[m_way_q] = 1'b1; data_wd = '0;
            alloc = 1'b1; alloc_way = m_way_q; alloc_dirty = 1'b1;
            rsp_valid_d = 1'b1;
            state_d = S_IDLE;
          end else begin
            state_d = S_FILL_REQ;
          end
        end
      end

      S_FILL_REQ: begin
        if (ld_req_ready_i) state_d = S_FILL_WAIT;
      end

      S_FILL_WAIT: begin
        if (ld_rsp_valid_i) begin
          data_we[m_way_q] = 1'b1;
          alloc = 1'b1; alloc_way = m_way_q;
          if (r_kind == DK_STORE) begin
            data_wd = merge_word(ld_rsp_data_i, r_ea[4:3], r_data, r_mask);
            alloc_dirty = 1'b1;
          end else begin
            data_wd = ld_rsp_data_i;
            alloc_dirty = 1'b0;
            rsp_data_d = ld_rsp_data_i[64 * r_ea[4:3] +: 64];
          end
          rsp_valid_d = 1'b1;
          state_d = S_IDLE;
        end
      end

      S_UNC_REQ: begin
        if (ld_req_ready_i) state_d = S_UNC_WAIT;
      end

      S_UNC_WAIT: begin
        if (ld_rsp_valid_i) begin
          rsp_data_d = ld_rsp_data_i[64 * r_pa[4:3] +: 64];
          rsp_valid_d = 1'b1;
          state_d = S_IDLE;
        end
      end

      default: begin // S_ST_UNC: single word store to the bus
        if (st_req_ready_i) begin
          rsp_valid_d = 1'b1;
          state_d = S_IDLE;
        end
      end
    endcase

    // allocate a block in way alloc_way for the registered request
    if (alloc) begin
      tag_we[alloc_way] = 1'b1;
      tag_wd = '{sh: r_sh, asid: r_asid, ea: r_ea[31:13], prr: r_prr, prw: r_prw, pru: r_pru,
                 wt: (r_cb == CB_WRITETHROUGH), pa: r_pa[31:12]};
      v_we[alloc_way] = 1'b1; v_wd[alloc_way] = 1'b1;
      u_we[alloc_way] = 1'b1; u_wd[alloc_way] = alloc_dirty;
      lru_we = 1'b1; lru_wd = lru_touch(lru[idx], alloc_way);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
      rsp_valid_q <= 1'b0; rsp_data_q <= 64'h0; cfg_rvalid_q <= 1'b0;
      m_way_q <= 2'd0; wb_data_q <= '0; wb_addr_q <= '0; wb_then_fill_q <= 1'b0; fill_alloco_q <= 1'b0;
      r_kind <= DK_LOAD; r_ea <= 32'h0; r_pa <= 32'h0; r_mask <= 8'h0; r_asid <= 8'h0; r_data <= 64'h0;
      r_cb <= 2'd0; r_mmu <= 1'b0; r_sh <= 1'b0; r_prr <= 1'b0; r_prw <= 1'b0; r_pru <= 1'b0;
      for (int w = 0; w < WAYS; w++) for (int s = 0; s < SETS; s++) begin tag_v[w][s] <= 1'b0; tag_u[w][s] <= 1'b0; end
      for (int s = 0; s < SETS; s++) lru[s] <= 6'h0;
    end else begin
      state_q <= state_d;
      rsp_valid_q <= rsp_valid_d; rsp_data_q <= rsp_data_d;
      cfg_rvalid_q <= take_cfg;
      m_way_q <= m_way_d; wb_data_q <= wb_data_d; wb_addr_q <= wb_addr_d;
      wb_then_fill_q <= wb_then_fill_d; fill_alloco_q <= fill_alloco_d;

      if (state_q == S_IDLE && req_valid_i && req_ready_o) begin
        r_kind <= req_kind_i; r_ea <= req_ea_i; r_pa <= req_pa_i; r_mask <= req_mask_i;
        r_data <= req_data_i; r_cb <= req_cb_i; r_mmu <= req_mmu_i; r_asid <= req_asid_i;
        r_sh <= req_sh_i; r_prr <= req_prr_i; r_prw <= req_prw_i; r_pru <= req_pru_i;
      end

      for (int w = 0; w < WAYS; w++) begin
        if (v_we[w]) tag_v[w][idx] <= v_wd[w];
        if (u_we[w]) tag_u[w][idx] <= u_wd[w];
      end
      if (lru_we) lru[idx] <= lru_wd;
      if (inv_all_i) begin
        for (int w = 0; w < WAYS; w++) for (int s = 0; s < SETS; s++) tag_v[w][s] <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------
  // Configuration view (Vol. 4 Tables 53, 54, 55), valid with cfg_rvalid_o
  always_comb begin
    cfg_rdata_o = 64'h0;
    if (!cfg_bank_i) begin
      if (cfg_reg_i == 2'd0) begin
        cfg_rdata_o[TAG_V]  = tag_v[cfg_way_i][cfg_idx_i];
        cfg_rdata_o[TAG_SH] = tag_rd[cfg_way_i].sh;
        cfg_rdata_o[TAG_ASID +: 8] = tag_rd[cfg_way_i].asid;
        cfg_rdata_o[TAG_EADDR +: 19] = tag_rd[cfg_way_i].ea;
        cfg_rdata_o[TAG_PRR] = tag_rd[cfg_way_i].prr;
        cfg_rdata_o[TAG_PRW] = tag_rd[cfg_way_i].prw;
        cfg_rdata_o[TAG_PRU] = tag_rd[cfg_way_i].pru;
        cfg_rdata_o[TAG_WT]  = tag_rd[cfg_way_i].wt;
        cfg_rdata_o[TAG_U]   = tag_u[cfg_way_i][cfg_idx_i];
        cfg_rdata_o[TAG_LRU +: 6] = lru[cfg_idx_i];
      end else if (cfg_reg_i == 2'd1) begin
        cfg_rdata_o[TAG_V] = tag_v[cfg_way_i][cfg_idx_i];
        cfg_rdata_o[TAG1_PADDR +: 20] = tag_rd[cfg_way_i].pa;
      end
    end else begin
      cfg_rdata_o = data_rd[cfg_way_i][64 * cfg_reg_i +: 64];
    end
  end

endmodule
