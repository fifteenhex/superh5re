// sh5_periph.sv - the Cayman peripherals the kernels need, as a req/ack
// slave on the core side of the system (docs/cayman-platform.md, and the
// C++ models in rtl/tb/core/tb_core.cpp which these follow register for
// register):
//
//   0x0a00_0000  INTC   ICR, INTPRI[8], INTSRC/INTREQ/INTENB/INTDISB
//   0x0a01_0000  CPRC   FRQ and PLL constants, the other registers writable
//   0x0a02_0000  TMU    SH-4 layout, 3 channels, peripheral clock = clk / PCLK_DIV
//   0x0a03_0000  SCIF   SH-4 layout; transmit bytes leave on con_tx_*, receive
//                       FIFO filled from con_rx_*
//   0x0a04_0000  RTC    R64CNT (128 Hz of CLK_HZ), RCR1/RCR2
//   0x0400_2000  system FPGA: BDMR, CPUMR, DATE constants, LEDCR, INTMR
//   0x0d/0x09/0x08 << 24  module VCRs at offsets 0 and 8
//
// Accesses are 64-bit words with byte strobes (the core issues Load8/Store8
// with the byte mask of the register size). 32-bit registers sit in the
// lane of their address, so a word read returns both registers of the
// 8-byte group. One-cycle acknowledge; a write takes effect in the cycle
// the request is first seen (fpgaslop's slop_card convention).
//
// Interrupts: INTC sources 32-34 TMU channels, 40 SCIF RXI, 42 SCIF TXI,
// 63 host (hub) doorbell; the highest-priority enabled pending source is
// presented to the core as EXTINT with its INTEVT code.
module sh5_periph #(
  parameter int unsigned CLK_HZ   = 256_000_000,
  parameter int unsigned PCLK_DIV = 12
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- req/ack slave (addresses are SH-5 physical) ----
  input  logic        s_req,
  input  logic        s_we,
  input  logic [31:0] s_addr,
  input  logic [63:0] s_wdata,
  input  logic [7:0]  s_wstrb,
  output logic        s_ack,
  output logic [63:0] s_rdata,

  // ---- console: SCIF transmit bytes out, receive bytes in ----
  output logic        con_tx_valid,
  output logic [7:0]  con_tx_byte,
  input  logic        con_rx_valid,    // push a byte into the receive FIFO
  input  logic [7:0]  con_rx_byte,
  output logic [4:0]  con_rx_count,    // bytes in the receive FIFO (16 deep)

  // ---- host doorbell (INTC source 63) ----
  input  logic        host_irq,

  // ---- LEDs: system FPGA LEDCR low bits ----
  output logic [3:0]  led,

  // ---- to the core ----
  output logic        extint_valid,
  output logic [3:0]  extint_level,
  output logic [31:0] extint_code
);

  // ------------------------------------------------------------------
  // request decode
  logic ack_q;
  logic first;                         // the cycle a request is first seen
  assign first = s_req && !ack_q;
  assign s_ack = ack_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ack_q <= 1'b0;
    else        ack_q <= s_req && !ack_q;
  end

  logic [15:0] base;
  logic [15:0] off;
  assign base = s_addr[31:16];
  assign off  = {s_addr[15:3], 3'b000};
  logic sel_intc, sel_cprc, sel_tmu, sel_scif, sel_rtc, sel_fpga, sel_vcr;
  assign sel_intc = (base == 16'h0a00);
  assign sel_cprc = (base == 16'h0a01);
  assign sel_tmu  = (base == 16'h0a02);
  assign sel_scif = (base == 16'h0a03);
  assign sel_rtc  = (base == 16'h0a04);
  assign sel_fpga = (base == 16'h0400) && (s_addr[15:8] == 8'h20);
  assign sel_vcr  = (s_addr[31:24] == 8'h0d) || (s_addr[31:24] == 8'h09) || (s_addr[31:24] == 8'h08);

  // 32-bit register writes: lane 0 (offset +0) and lane 1 (offset +4)
  logic wr_lo, wr_hi;
  assign wr_lo = first && s_we && (s_wstrb[3:0] != 4'h0);
  assign wr_hi = first && s_we && (s_wstrb[7:4] != 4'h0);
  logic [31:0] wd_lo, wd_hi;
  assign wd_lo = s_wdata[31:0];
  assign wd_hi = s_wdata[63:32];

  // ------------------------------------------------------------------
  // INTC (NetBSD sh5 intc driver register layout, tb_core.cpp Intc)
  logic [63:0] intc_src, intc_enb;
  logic [31:0] intc_icr;
  logic [31:0] intc_pri [8];

  // INTEVT codes of the Cayman sources
  function automatic logic [15:0] intevt(input int n);
    case (n)
      0: intevt = 16'h240; 1: intevt = 16'h2a0; 2: intevt = 16'h300; 3: intevt = 16'h360;
      4: intevt = 16'h800; 5: intevt = 16'h820; 6: intevt = 16'h840; 7: intevt = 16'h860;
      12: intevt = 16'ha00; 13: intevt = 16'ha20; 14: intevt = 16'ha40; 15: intevt = 16'ha60;
      16: intevt = 16'ha80; 17: intevt = 16'haa0;
      18: intevt = 16'h640; 19: intevt = 16'h660; 20: intevt = 16'h680; 21: intevt = 16'h6a0; 22: intevt = 16'h6c0;
      32: intevt = 16'h400; 33: intevt = 16'h420; 34: intevt = 16'h440; 35: intevt = 16'h460;
      36: intevt = 16'h480; 37: intevt = 16'h4a0; 38: intevt = 16'h4c0;
      39: intevt = 16'h700; 40: intevt = 16'h720; 41: intevt = 16'h740; 42: intevt = 16'h760;
      63: intevt = 16'h560;
      default: intevt = 16'h0;
    endcase
  endfunction

  logic [2:0] tmu_irq;
  logic       scif_txi, scif_rxi;
  always_comb begin
    intc_src = 64'h0;
    intc_src[32] = tmu_irq[0];
    intc_src[33] = tmu_irq[1];
    intc_src[34] = tmu_irq[2];
    intc_src[40] = scif_rxi;
    intc_src[42] = scif_txi;
    intc_src[63] = host_irq;
  end

  // highest priority pending source (level 1..15); the last of equal levels wins
  always_comb begin
    logic [3:0] p;
    extint_level = 4'd0;
    extint_code  = 32'h0;
    for (int i = 0; i < 64; i++) begin
      p = intc_pri[i / 8][(i % 8) * 4 +: 4];
      if (intc_src[i] && intc_enb[i] && (p > extint_level)) begin
        extint_level = p;
        extint_code  = {16'h0, intevt(i)};
      end
    end
    extint_valid = (extint_level != 4'd0);
  end

  logic [63:0] intc_rdata;
  always_comb begin
    logic [31:0] lo, hi;
    lo = 32'h0; hi = 32'h0;
    case (off)
      16'h0000: begin lo = intc_icr;  hi = 32'h0; end
      16'h0008: begin lo = intc_icr;  hi = 32'h0; end
      16'h0050: begin lo = intc_src[31:0]; hi = 32'h0; end
      16'h0058: begin lo = intc_src[63:32]; hi = 32'h0; end
      16'h0060: begin lo = intc_src[31:0] & intc_enb[31:0]; hi = 32'h0; end
      16'h0068: begin lo = intc_src[63:32] & intc_enb[63:32]; hi = 32'h0; end
      16'h0070: begin lo = intc_enb[31:0]; hi = 32'h0; end
      16'h0078: begin lo = intc_enb[63:32]; hi = 32'h0; end
      16'h0080: begin lo = ~intc_enb[31:0]; hi = 32'h0; end
      16'h0088: begin lo = ~intc_enb[63:32]; hi = 32'h0; end
      default: begin
        if (off >= 16'h0010 && off < 16'h0050) begin lo = intc_pri[off[5:3] - 3'd2]; hi = 32'h0; end
      end
    endcase
    intc_rdata = {hi, lo};
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      intc_icr <= 32'h0; intc_enb <= 64'h0;
      for (int k = 0; k < 8; k++) intc_pri[k] <= 32'h0;
    end else if (sel_intc && wr_lo) begin
      case (off)
        16'h0000: intc_icr <= intc_icr | wd_lo;
        16'h0008: intc_icr <= intc_icr & ~wd_lo;
        16'h0070: intc_enb[31:0]  <= intc_enb[31:0] | wd_lo;
        16'h0078: intc_enb[63:32] <= intc_enb[63:32] | wd_lo;
        16'h0080: intc_enb[31:0]  <= intc_enb[31:0] & ~wd_lo;
        16'h0088: intc_enb[63:32] <= intc_enb[63:32] & ~wd_lo;
        default: if (off >= 16'h0010 && off < 16'h0050) intc_pri[off[5:3] - 3'd2] <= wd_lo;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // CPRC: FRQ, PLL constants (PLL 512 MHz, CPU /2, EMI /8, SuperHyway /4,
  // peripheral /24, PCI /24, FEMI /8, ST /24); the rest readable/writable
  localparam logic [31:0] CPRC_FRQ = (32'd3 << 0) | (32'd1 << 3) | (32'd0 << 6) | (32'd7 << 12) |
                                     (32'd7 << 15) | (32'd3 << 18) | (32'd7 << 21) | 32'h400;
  localparam logic [31:0] CPRC_PLL = (32'h1 << 31) | (32'h1 << 30);
  logic [31:0] cprc_q [8];
  logic [63:0] cprc_rdata;
  always_comb begin
    logic [31:0] lo, hi;
    lo = cprc_q[off[5:3]]; hi = cprc_q[off[5:3]];   // one 32-bit register per 8-byte slot
    if (off[15:6] != 10'h0) begin lo = 32'h0; hi = 32'h0; end
    else if (off[5:3] == 3'd0) lo = CPRC_FRQ;
    else if (off[5:3] == 3'd1) lo = CPRC_PLL;
    cprc_rdata = {hi, lo};
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) for (int k = 0; k < 8; k++) cprc_q[k] <= 32'h0;
    else if (sel_cprc && off[15:6] == 10'h0) begin
      if (wr_lo) cprc_q[off[5:3]] <= wd_lo;
      if (wr_hi) cprc_q[off[5:3]] <= wd_hi;
    end
  end

  // ------------------------------------------------------------------
  // TMU: TOCR +0, TSTR +4, channel n: TCOR +8+12n, TCNT +0xc+12n, TCR +0x10+12n.
  // Counts on the peripheral clock (clk / PCLK_DIV) divided by the TCR prescaler.
  logic        tocr_q;
  logic [2:0]  tstr_q;
  logic [31:0] tcor_q [3], tcnt_q [3];
  logic [7:0]  tcr_q [3];
  logic [2:0]  unf_q;
  logic [9:0]  pre_q [3];
  logic [$clog2(PCLK_DIV+1)-1:0] pclk_q;
  logic        ptick;
  assign ptick = (32'(pclk_q) == PCLK_DIV - 1);
  for (genvar n = 0; n < 3; n++) begin : g_tirq
    assign tmu_irq[n] = unf_q[n] && tcr_q[n][5];
  end

  // register access by 32-bit offset (TMU registers are 4-byte apart)
  function automatic logic [31:0] tmu_reg(input logic [7:0] a4);
    tmu_reg = 32'h0;
    case (a4)
      8'h00: tmu_reg = {31'h0, tocr_q};
      8'h04: tmu_reg = {29'h0, tstr_q};
      8'h08: tmu_reg = tcor_q[0]; 8'h0c: tmu_reg = tcnt_q[0]; 8'h10: tmu_reg = {23'h0, unf_q[0], tcr_q[0]};
      8'h14: tmu_reg = tcor_q[1]; 8'h18: tmu_reg = tcnt_q[1]; 8'h1c: tmu_reg = {23'h0, unf_q[1], tcr_q[1]};
      8'h20: tmu_reg = tcor_q[2]; 8'h24: tmu_reg = tcnt_q[2]; 8'h28: tmu_reg = {23'h0, unf_q[2], tcr_q[2]};
      default: ;
    endcase
  endfunction
  logic [63:0] tmu_rdata;
  assign tmu_rdata = (off[15:8] != 8'h0) ? 64'h0 : {tmu_reg(off[7:0] + 8'd4), tmu_reg(off[7:0])};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tocr_q <= 1'b0; tstr_q <= 3'b0; unf_q <= 3'b0; pclk_q <= '0;
      for (int n = 0; n < 3; n++) begin tcor_q[n] <= 32'hffff_ffff; tcnt_q[n] <= 32'hffff_ffff; tcr_q[n] <= 8'h0; pre_q[n] <= 10'd0; end
    end else begin
      pclk_q <= ptick ? '0 : pclk_q + 1'b1;
      for (int n = 0; n < 3; n++) begin
        if (ptick && tstr_q[n]) begin
          // prescaler 4 << (2 * TPSC)
          if (32'({pre_q[n], 2'b00}) >= (32'd4 << (2 * tcr_q[n][2:0]))) begin
            pre_q[n] <= 10'd0;
            if (tcnt_q[n] == 32'h0) begin tcnt_q[n] <= tcor_q[n]; unf_q[n] <= 1'b1; end
            else tcnt_q[n] <= tcnt_q[n] - 32'd1;
          end else pre_q[n] <= pre_q[n] + 10'd1;
        end
      end
      if (sel_tmu && off[15:8] == 8'h0) begin
        for (int half = 0; half < 2; half++) begin
          logic [7:0]  a4;
          logic [31:0] w;
          logic        en;
          a4 = off[7:0] + (half[0] ? 8'd4 : 8'd0);
          w  = half[0] ? wd_hi : wd_lo;
          en = half[0] ? wr_hi : wr_lo;
          if (en) begin
            case (a4)
              8'h00: tocr_q <= w[0];
              8'h04: tstr_q <= w[2:0];
              8'h08: tcor_q[0] <= w; 8'h0c: tcnt_q[0] <= w; 8'h10: begin tcr_q[0] <= w[7:0]; if (!w[8]) unf_q[0] <= 1'b0; end
              8'h14: tcor_q[1] <= w; 8'h18: tcnt_q[1] <= w; 8'h1c: begin tcr_q[1] <= w[7:0]; if (!w[8]) unf_q[1] <= 1'b0; end
              8'h20: tcor_q[2] <= w; 8'h24: tcnt_q[2] <= w; 8'h28: begin tcr_q[2] <= w[7:0]; if (!w[8]) unf_q[2] <= 1'b0; end
              default: ;
            endcase
          end
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // SCIF (SH-4 layout, SH7750 semantics as in tb_core.cpp): SMR +0, BRR +4,
  // SCR +8, FTDR +0xc, FSR +0x10, FRDR +0x14, FCR +0x18, FDR +0x1c.
  // Transmit: FTDR bytes leave immediately (TDFE/TEND always set), TXI while
  // SCR.TIE. Receive: 16-byte FIFO, RDF at the trigger or after a timeout,
  // RXI while RDF and SCR.RIE.
  logic [15:0] scr_q, fcr_q;
  logic        rdf_q;
  logic [15:0] rx_idle_q;
  logic [7:0]  rx_q [16];
  logic [3:0]  rx_rd_q, rx_wr_q;
  logic [4:0]  rx_cnt_q;
  logic [4:0]  rtrg;
  assign rtrg = (fcr_q[7:6] == 2'd0) ? 5'd1 : (fcr_q[7:6] == 2'd1) ? 5'd4 : (fcr_q[7:6] == 2'd2) ? 5'd8 : 5'd14;
  assign con_rx_count = rx_cnt_q;
  assign scif_txi = scr_q[7];
  assign scif_rxi = rdf_q && scr_q[6];
  assign con_tx_valid = sel_scif && first && s_we && (off == 16'h0008) && s_wstrb[4];
  assign con_tx_byte  = s_wdata[39:32];

  logic rx_pop;
  assign rx_pop = sel_scif && first && !s_we && (off == 16'h0010) && s_wstrb[4] && (rx_cnt_q != 5'd0);
  logic rx_push;
  assign rx_push = con_rx_valid && (rx_cnt_q != 5'd16);

  logic [63:0] scif_rdata;
  always_comb begin
    scif_rdata = 64'h0;
    case (off)
      16'h0008: scif_rdata = {32'h0, 16'h0, scr_q};
      16'h0010: scif_rdata = {24'h0, (rx_cnt_q != 5'd0) ? rx_q[rx_rd_q] : 8'h0, 16'h0,
                              16'h0060 | (rdf_q ? 16'h2 : 16'h0) | ((rx_cnt_q != 5'd0) ? 16'h1 : 16'h0)};
      16'h0018: scif_rdata = {32'h0 | {27'h0, rx_cnt_q}, 16'h0, fcr_q};
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scr_q <= 16'h0; fcr_q <= 16'h0; rdf_q <= 1'b0; rx_idle_q <= 16'h0;
      rx_rd_q <= 4'd0; rx_wr_q <= 4'd0; rx_cnt_q <= 5'd0;
      for (int k = 0; k < 16; k++) rx_q[k] <= 8'h0;
    end else begin
      if (sel_scif && first && s_we) begin
        if (off == 16'h0008 && (s_wstrb[1:0] != 2'b00)) scr_q <= s_wdata[15:0];
        if (off == 16'h0010 && (s_wstrb[1:0] != 2'b00) && !s_wdata[1]) rdf_q <= 1'b0;
        if (off == 16'h0018 && (s_wstrb[1:0] != 2'b00)) begin
          fcr_q <= s_wdata[15:0];
          if (s_wdata[1]) begin rx_rd_q <= 4'd0; rx_wr_q <= 4'd0; rx_cnt_q <= 5'd0; rdf_q <= 1'b0; end
        end
      end
      if (rx_push) begin
        rx_q[rx_wr_q] <= con_rx_byte;
        rx_wr_q <= rx_wr_q + 4'd1;
      end
      if (rx_pop) rx_rd_q <= rx_rd_q + 4'd1;
      if (rx_push && !rx_pop) rx_cnt_q <= rx_cnt_q + 5'd1;
      else if (rx_pop && !rx_push) rx_cnt_q <= rx_cnt_q - 5'd1;
      if (rx_push || rx_pop) rx_idle_q <= 16'h0;
      else if (rx_cnt_q != 5'd0 && rx_idle_q != 16'hffff) rx_idle_q <= rx_idle_q + 16'd1;
      if (rx_cnt_q != 5'd0) begin
        if (rx_cnt_q >= rtrg) rdf_q <= 1'b1;
        else if (rx_idle_q > 16'd50000) rdf_q <= 1'b1;
      end
      if (rx_pop && (rx_cnt_q - 5'd1) < rtrg) rdf_q <= 1'b0;
    end
  end

  // ------------------------------------------------------------------
  // RTC: R64CNT at +0 counts at 128 Hz; RCR1 +0x38, RCR2 +0x3c
  localparam int unsigned R64_DIV = CLK_HZ / 128;
  logic [$clog2(R64_DIV)-1:0] r64_div_q;
  logic [6:0] r64_q;
  logic [7:0] rcr1_q, rcr2_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin r64_div_q <= '0; r64_q <= 7'h0; rcr1_q <= 8'h0; rcr2_q <= 8'h0; end
    else begin
      if (32'(r64_div_q) == R64_DIV - 1) begin r64_div_q <= '0; r64_q <= r64_q + 7'd1; end
      else r64_div_q <= r64_div_q + 1'b1;
      if (sel_rtc && off == 16'h0038) begin
        if (wr_lo) rcr1_q <= wd_lo[7:0];
        if (wr_hi) rcr2_q <= wd_hi[7:0];
      end
    end
  end
  logic [63:0] rtc_rdata;
  assign rtc_rdata = (off == 16'h0000) ? {57'h0, r64_q} :
                     (off == 16'h0038) ? {24'h0, rcr2_q, 24'h0, rcr1_q} : 64'h0;

  // ------------------------------------------------------------------
  // system FPGA registers (hw/sh5/cayman_sysfpga.c): BDMR 0, CPUMR 4,
  // LEDCR 8, INTSR 0x10.., INTMR 0x20.., DATE 0x60
  logic [31:0] ledcr_q;
  logic [7:0]  intmr_q [4];
  assign led = ledcr_q[3:0];
  function automatic logic [31:0] fpga_reg(input logic [7:0] a);
    fpga_reg = 32'h0;
    case (a)
      8'h00: fpga_reg = 32'd2 << 9;
      8'h04: fpga_reg = 32'd3;
      8'h08: fpga_reg = ledcr_q;
      8'h20: fpga_reg = {24'h0, intmr_q[0]};
      8'h24: fpga_reg = {24'h0, intmr_q[1]};
      8'h28: fpga_reg = {24'h0, intmr_q[2]};
      8'h2c: fpga_reg = {24'h0, intmr_q[3]};
      8'h60: fpga_reg = 32'h0205_2405;
      default: ;
    endcase
  endfunction
  logic [63:0] fpga_rdata;
  assign fpga_rdata = {fpga_reg(off[7:0] + 8'd4), fpga_reg(off[7:0])};
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ledcr_q <= 32'h0; for (int k = 0; k < 4; k++) intmr_q[k] <= 8'h0; end
    else if (sel_fpga) begin
      for (int half = 0; half < 2; half++) begin
        logic [7:0]  a;
        logic [31:0] w;
        logic        en;
        a = off[7:0] + (half[0] ? 8'd4 : 8'd0);
        w = half[0] ? wd_hi : wd_lo;
        en = half[0] ? wr_hi : wr_lo;
        if (en) begin
          case (a)
            8'h08: ledcr_q <= w;
            8'h20: intmr_q[0] <= w[7:0];
            8'h24: intmr_q[1] <= w[7:0];
            8'h28: intmr_q[2] <= w[7:0];
            8'h2c: intmr_q[3] <= w[7:0];
            default: ;
          endcase
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // module VCRs: module id in [47:32]
  logic [63:0] vcr_rdata;
  always_comb begin
    vcr_rdata = 64'h0;
    if (s_addr[31:24] == 8'h0d && s_addr[23:4] == 20'h0) vcr_rdata = 64'h51e2 << 32;
    if (s_addr[31:24] == 8'h09 && s_addr[23:3] == 21'h0) vcr_rdata = 64'h448f << 32;
    if (s_addr[31:24] == 8'h08 && s_addr[23:3] == 21'h0) vcr_rdata = 64'h2185 << 32;
  end

  // ------------------------------------------------------------------
  // read data: registered with the acknowledge
  logic [63:0] rdata_mux;
  always_comb begin
    rdata_mux = 64'h0;
    if (sel_intc) rdata_mux = intc_rdata;
    else if (sel_cprc) rdata_mux = cprc_rdata;
    else if (sel_tmu)  rdata_mux = tmu_rdata;
    else if (sel_scif) rdata_mux = scif_rdata;
    else if (sel_rtc)  rdata_mux = rtc_rdata;
    else if (sel_fpga) rdata_mux = fpga_rdata;
    else if (sel_vcr)  rdata_mux = vcr_rdata;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s_rdata <= 64'h0;
    else if (first) s_rdata <= rdata_mux;
  end

endmodule
