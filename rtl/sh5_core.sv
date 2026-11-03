// SH-5 core: top-level port contract. See docs/core-design.md and
// docs/bus-interface.md. The body instantiates the units of the design;
// until they exist the outputs are tied off so the interface lints.

module sh5_core
  import sh5_pkg::*;
  import shwy_pkg::*;
#(
  parameter bit          FPU_PRESENT    = 1'b1,
  parameter int          TID_BITS       = 3,            // outstanding bus requests: 2**TID_BITS
  parameter logic [7:0]  BUS_SRC_ID     = 8'h0d,        // SuperHyway source id of the CPU
  parameter logic [15:0] MODULE_ID      = 16'h51e2,     // VCR module id
  parameter logic [15:0] MODULE_VERSION = 16'h0001,     // VCR module version
  parameter int          ICACHE_WAYS    = CACHE_WAYS,
  parameter int          ICACHE_SETS    = CACHE_SETS,
  parameter int          DCACHE_WAYS    = CACHE_WAYS,
  parameter int          DCACHE_SETS    = CACHE_SETS,
  parameter int          ITLB_ENTRIES   = 64,
  parameter int          DTLB_ENTRIES   = 64
) (
  input  logic        clk,
  input  logic        rst_n,          // power-on reset (POWERON)

  // Static configuration
  input  logic        big_endian_i,

  // Asynchronous events (Vol. 1 16.2)
  input  logic        cpu_reset_i,    // CPURESET
  input  logic        nmi_i,
  input  logic        debugint_i,
  input  logic        extint_valid_i,
  input  logic [3:0]  extint_level_i,
  input  logic [31:0] extint_code_i,  // INTEVT value supplied by the INTC
  output logic        extint_ack_o,
  output logic [3:0]  extint_ack_level_o,
  input  logic [31:0] dbrvec_i,       // DBRVEC (bit 0 = MMUOFF)
  input  logic        dbrmode_i,
  output logic        sleep_o,
  output logic        bus_error_o,

  // Debug watchpoints (later); tied off in phase 1
  input  logic        dbg_ia_hit_i,
  input  logic        dbg_iv_hit_i,
  input  logic        dbg_oa_hit_i,
  output logic [31:0] dbg_fetch_addr_o,
  output logic [31:0] dbg_insn_o,
  output logic [31:0] dbg_op_addr_o,
  output logic        dbg_op_valid_o,

  // Bus initiator: request
  output logic        ireq_valid,
  input  logic        ireq_ready,
  output logic [7:0]  ireq_opc,
  output logic [31:0] ireq_addr,
  output logic [7:0]  ireq_src,
  output logic [7:0]  ireq_tid,
  output logic [7:0]  ireq_mask,
  output logic [63:0] ireq_data,
  output logic        ireq_last,
  // Bus initiator: response
  input  logic        irsp_valid,
  output logic        irsp_ready,
  input  logic [7:0]  irsp_opc,
  input  logic [7:0]  irsp_src,
  input  logic [7:0]  irsp_tid,
  input  logic [63:0] irsp_data,
  input  logic        irsp_last,

  // Bus target: request (VCR, later Flush/Purge)
  input  logic        treq_valid,
  output logic        treq_ready,
  input  logic [7:0]  treq_opc,
  input  logic [31:0] treq_addr,
  input  logic [7:0]  treq_src,
  input  logic [7:0]  treq_tid,
  input  logic [7:0]  treq_mask,
  input  logic [63:0] treq_data,
  input  logic        treq_last,
  // Bus target: response
  output logic        trsp_valid,
  input  logic        trsp_ready,
  output logic [7:0]  trsp_opc,
  output logic [7:0]  trsp_src,
  output logic [7:0]  trsp_tid,
  output logic [63:0] trsp_data,
  output logic        trsp_last
);

  // VCR (docs/bus-interface.md): [63:48] error flags, [47:32] module id,
  // [31:16] version.
  logic [7:0] vcr_err_q;
  logic [63:0] vcr;
  assign vcr = {vcr_err_q, 8'h00, MODULE_ID, MODULE_VERSION, 16'h0000};

  // -------------------------------------------------------------------
  // Target port: answer Load8 at offsets 0x00 and 0x08 with the VCR,
  // accept Store8 to offset 0 as "clear error flags", fail everything else.
  logic        treq_pending_q;
  logic [7:0]  treq_opc_q, treq_src_q, treq_tid_q;
  logic        treq_vcr_hit_q;

  assign treq_ready = !treq_pending_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      treq_pending_q <= 1'b0;
      treq_opc_q     <= 8'h00;
      treq_src_q     <= 8'h00;
      treq_tid_q     <= 8'h00;
      treq_vcr_hit_q <= 1'b0;
      vcr_err_q      <= 8'h00;
    end else begin
      if (treq_valid && treq_ready && treq_last) begin
        treq_pending_q <= 1'b1;
        treq_opc_q     <= treq_opc;
        treq_src_q     <= treq_src;
        treq_tid_q     <= treq_tid;
        treq_vcr_hit_q <= (treq_addr[23:4] == 20'h0) &&
                          (treq_opc == OPC_LOAD8 || treq_opc == OPC_STORE8);
        if (treq_opc == OPC_STORE8 && treq_addr[23:3] == 21'h0) begin
          vcr_err_q <= 8'h00;
        end
      end
      if (trsp_valid && trsp_ready) begin
        treq_pending_q <= 1'b0;
      end
    end
  end

  assign trsp_valid = treq_pending_q;
  assign trsp_opc   = treq_vcr_hit_q ? OPC_SUCCESS : OPC_FAILURE;
  assign trsp_src   = treq_src_q;
  assign trsp_tid   = treq_tid_q;
  assign trsp_data  = (treq_vcr_hit_q && treq_opc_q == OPC_LOAD8) ? vcr : 64'h0;
  assign trsp_last  = 1'b1;

  // -------------------------------------------------------------------
  // Initiator port and core: not yet implemented.
  assign ireq_valid = 1'b0;
  assign ireq_opc   = OPC_LOAD8;
  assign ireq_addr  = 32'h0;
  assign ireq_src   = BUS_SRC_ID;
  assign ireq_tid   = 8'h0;
  assign ireq_mask  = 8'hff;
  assign ireq_data  = 64'h0;
  assign ireq_last  = 1'b1;
  assign irsp_ready = 1'b1;

  assign extint_ack_o       = 1'b0;
  assign extint_ack_level_o = 4'h0;
  assign sleep_o            = 1'b0;
  assign bus_error_o        = 1'b0;
  assign dbg_fetch_addr_o   = 32'h0;
  assign dbg_insn_o         = 32'h0;
  assign dbg_op_addr_o      = 32'h0;
  assign dbg_op_valid_o     = 1'b0;

  logic unused_ok;
  assign unused_ok = &{1'b0, big_endian_i, cpu_reset_i, nmi_i, debugint_i,
                       extint_valid_i, extint_level_i, extint_code_i,
                       dbrvec_i, dbrmode_i, dbg_ia_hit_i, dbg_iv_hit_i,
                       dbg_oa_hit_i, ireq_ready, irsp_valid, irsp_opc,
                       irsp_src, irsp_tid, irsp_data, irsp_last,
                       treq_mask, treq_data, treq_addr[31:24], treq_addr[2:0],
                       FPU_PRESENT, 1'b0};

endmodule
