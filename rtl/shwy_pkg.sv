// SuperHyway-style packet definitions for the core bus port.
// Sources: SH-5 System Architecture Vol. 3 (Debug) 3.6 (DBUS mirrors the
// SuperHyway request/response packets). See docs/bus-interface.md.

package shwy_pkg;

  // Request opcodes (SA Vol. 3 Table 82)
  localparam logic [7:0] OPC_LOAD8   = 8'h31;
  localparam logic [7:0] OPC_LOAD16  = 8'h41;
  localparam logic [7:0] OPC_LOAD32  = 8'h51;
  localparam logic [7:0] OPC_STORE8  = 8'h32;
  localparam logic [7:0] OPC_STORE16 = 8'h42;
  localparam logic [7:0] OPC_STORE32 = 8'h52;
  localparam logic [7:0] OPC_SWAP8   = 8'h35;
  localparam logic [7:0] OPC_FLUSH   = 8'h18;
  localparam logic [7:0] OPC_PURGE   = 8'h08;
  // Response opcodes
  localparam logic [7:0] OPC_SUCCESS = 8'h80;
  localparam logic [7:0] OPC_FAILURE = 8'h81;

  typedef struct packed {
    logic [7:0]  opc;
    logic [31:0] addr;
    logic [7:0]  src;
    logic [7:0]  tid;
  } req_hdr_t;

  typedef struct packed {
    logic [7:0]  opc;
    logic [7:0]  src;
    logic [7:0]  tid;
  } rsp_hdr_t;

  // Number of 64-bit data words carried by a request of this opcode.
  function automatic logic [2:0] req_words(input logic [7:0] opc);
    case (opc)
      OPC_STORE8, OPC_SWAP8: req_words = 3'd1;
      OPC_STORE16:           req_words = 3'd2;
      OPC_STORE32:           req_words = 3'd4;
      default:               req_words = 3'd0;
    endcase
  endfunction

  // Number of 64-bit data words in a Success response to this request.
  function automatic logic [2:0] rsp_words(input logic [7:0] opc);
    case (opc)
      OPC_LOAD8, OPC_SWAP8: rsp_words = 3'd1;
      OPC_LOAD16:           rsp_words = 3'd2;
      OPC_LOAD32:           rsp_words = 3'd4;
      default:              rsp_words = 3'd0;
    endcase
  endfunction

  // Byte mask for an access of 1, 2, 4 or 8 bytes at offset addr[2:0]
  // (SA Vol. 3 Table 81). Mask bit i covers data[8i+7:8i]; in big-endian
  // mode mask bit i is address offset 7-i.
  function automatic logic [7:0] byte_mask(input logic [3:0] size,
                                           input logic [2:0] offset,
                                           input logic       big_endian);
    logic [7:0] m;
    case (size)
      4'd1:    m = 8'h01 << offset;
      4'd2:    m = 8'h03 << {offset[2:1], 1'b0};
      4'd4:    m = 8'h0f << {offset[2], 2'b00};
      default: m = 8'hff;
    endcase
    byte_mask = big_endian ? {m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7]} : m;
  endfunction

  // Critical-word-first burst order (SA Vol. 3 Tables 79, 80): word index
  // of beat `beat` for a 4-word burst whose address has word addr[4:3].
  function automatic logic [1:0] burst_word(input logic [1:0] first,
                                            input logic [1:0] beat);
    burst_word = first + beat;
  endfunction

endpackage
