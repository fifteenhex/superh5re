// sh5_hub.sv - the host's view of the SH-5 system: identity, reset and boot
// control, the console, a doorbell. A req/ack slave on the host window
// (64-bit registers, one-cycle acknowledge, whole-word writes).
//
//   0x000  ID          "superh5 "                               r
//   0x008  VERSION     {major[31:16], minor[15:0]}              r
//   0x010  RAM_SIZE    bytes of DRAM the core can reach          r
//   0x018  STATUS      bit 0 core held in reset, bit 1 core asleep (SLEEP),
//                      bit 2 bus error seen (sticky, cleared by a write)  r/w
//   0x020  RESET_HOLD  bit 0: 1 holds the core in reset (reset value 1 on
//                      a board: the host deposits an image first)   rw
//   0x028  BOOT_PC     the address the core starts at when released rw
//   0x030  CYCLES      free-running core clock counter             r
//   0x038  IRQ         write bit 0: pulse NMI; bit 1 sets / bit 2 clears
//                      the host doorbell (INTC source 63)          w
//   0x100  CON_STATUS  [31:16] bytes waiting in the transmit FIFO,
//                      bit 3 transmit FIFO overflowed (sticky, cleared
//                      by a write), [3:0] (bits 11:8) bytes free in the
//                      receive FIFO                                r/w
//   0x108  CON_POP     reading pops one byte: bit 8 valid, [7:0] byte r
//   0x110  CON_PUSH    write [7:0]: one byte into the SCIF receive FIFO w
//
// The transmit FIFO is 4 KiB in block RAM; a byte arriving while it is
// full is dropped and the overflow bit set. The host drains it by polling
// CON_POP, exactly as smol68k's host tool drains its hub console.
//
// Reset: this module runs off the hard reset only. A soft reset restarts
// the core and the peripherals; the console contents, RESET_HOLD and
// BOOT_PC survive it so the host can reload and restart without losing
// its settings.
module sh5_hub #(
  parameter logic [63:0] RAM_SIZE   = 64'd256 << 20,
  parameter bit          AUTOSTART  = 1'b0,    // 1: RESET_HOLD reset value 0 (simulation with a preloaded image)
  parameter logic [31:0] BOOT_PC    = 32'h8000_0000
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        s_req,
  input  logic        s_we,
  input  logic [11:0] s_addr,
  input  logic [63:0] s_wdata,
  output logic        s_ack,
  output logic [63:0] s_rdata,

  // ---- core control ----
  output logic        reset_hold,
  output logic [31:0] boot_pc,
  output logic        nmi,              // one-cycle pulse
  output logic        host_irq,         // level, INTC source 63
  input  logic        core_sleep,
  input  logic        bus_error,

  // ---- console ----
  input  logic        tx_valid,         // from the SCIF transmit register
  input  logic [7:0]  tx_byte,
  output logic        rx_valid,         // one byte to the SCIF receive FIFO
  output logic [7:0]  rx_byte,
  input  logic [4:0]  rx_count
);

  logic ack_q, first;
  assign first = s_req && !ack_q;
  assign s_ack = ack_q;

  logic        hold_q, nmi_q, irq_q, berr_q, ovf_q;
  logic [31:0] bootpc_q;
  logic [63:0] cycles_q;

  // ---- transmit FIFO: 4096 bytes, in block RAM (its own process, no reset) ----
  (* ram_style = "block" *) logic [7:0] fifo [4096];
  logic [12:0] wr_q, rd_q;             // one extra bit: full/empty
  logic [12:0] count;
  logic        pop, push, full, push_q, can_pop;
  assign count = wr_q - rd_q;
  assign full  = count[12];
  assign push  = tx_valid && !full;
  // the head byte is read a cycle behind the pointer: a byte pushed last
  // cycle into an otherwise empty FIFO is not at rd_byte_q yet
  assign can_pop = (count != 13'd0) && !(push_q && count == 13'd1);
  assign pop   = first && !s_we && (s_addr == 12'h108) && can_pop;
  logic [7:0]  rd_byte_q;

  assign reset_hold = hold_q;
  assign boot_pc    = bootpc_q;
  assign nmi        = nmi_q;
  assign host_irq   = irq_q;
  assign rx_valid   = first && s_we && (s_addr == 12'h110);
  assign rx_byte    = s_wdata[7:0];

  logic [63:0] rdata_mux;
  always_comb begin
    case (s_addr)
      12'h000: rdata_mux = 64'h7375_7065_7268_3520;   // "superh5 "
      12'h008: rdata_mux = {32'h0, 16'd1, 16'd0};
      12'h010: rdata_mux = RAM_SIZE;
      12'h018: rdata_mux = {61'h0, berr_q, core_sleep, hold_q};
      12'h020: rdata_mux = {63'h0, hold_q};
      12'h028: rdata_mux = {32'h0, bootpc_q};
      12'h030: rdata_mux = cycles_q;
      12'h100: rdata_mux = {32'h0, {3'b000, count}, 3'h0, 5'd16 - rx_count, 4'b0000, ovf_q, 3'b000};
      12'h108: rdata_mux = {55'h0, can_pop, rd_byte_q};
      default: rdata_mux = 64'h0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (push) fifo[wr_q[11:0]] <= tx_byte;
    rd_byte_q <= fifo[rd_q[11:0]];
    push_q <= push;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ack_q <= 1'b0; hold_q <= !AUTOSTART; nmi_q <= 1'b0; irq_q <= 1'b0; berr_q <= 1'b0; ovf_q <= 1'b0;
      bootpc_q <= BOOT_PC; cycles_q <= 64'h0;
      wr_q <= 13'd0; rd_q <= 13'd0; s_rdata <= 64'h0;
    end else begin
      ack_q <= s_req && !ack_q;
      cycles_q <= cycles_q + 64'd1;
      nmi_q <= 1'b0;
      if (bus_error) berr_q <= 1'b1;
      if (push) wr_q <= wr_q + 13'd1;
      if (tx_valid && full) ovf_q <= 1'b1;
      if (pop) rd_q <= rd_q + 13'd1;
      if (first) s_rdata <= rdata_mux;
      if (first && s_we) begin
        case (s_addr)
          12'h018: berr_q <= 1'b0;
          12'h020: hold_q <= s_wdata[0];
          12'h028: bootpc_q <= s_wdata[31:0];
          12'h038: begin
            if (s_wdata[0]) nmi_q <= 1'b1;
            if (s_wdata[1]) irq_q <= 1'b1;
            if (s_wdata[2]) irq_q <= 1'b0;
          end
          12'h100: ovf_q <= 1'b0;
          default: ;
        endcase
      end
    end
  end

endmodule
