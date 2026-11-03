# Core bus interface

The core's boundary to the system is a pair of packet channels modelled on
SuperHyway as far as it is documented. The SuperHyway interface
definitions (SH4-202-SHY-DEO-00026..28, `refs/sources.md`) are not held.
What is documented: 64-bit split-transaction bus at half the CPU clock
(HC13 slide 4); request and response packets with the fields and opcodes
below (SA Vol. 3 §3.6, which specifies the DBUS as a serialisation of
SuperHyway packets and the bus analyser as a watchpoint on the same
fields); per-module 64-bit VCR at offset 0 of the module's 16 MB p-port
window, address bits 31:24 = module number (SA Vol. 3 §3.6.8,
`cayman-platform.md`).

Marking as in `core-design.md`: **D** documented, **C** our choice.

## Packets

### Request (SA Vol. 3 §3.6.1, §3.6.8) **D**

| Field | Width | Meaning |
|---|---|---|
| OPC | 8 | 0x31 Load8, 0x41 Load16, 0x51 Load32, 0x32 Store8, 0x42 Store16, 0x52 Store32, 0x35 Swap8, 0x18 Flush, 0x08 Purge |
| ADDR | 32 | byte address; [31:24] module; [2:0] not significant; Load16/Store16: [3] critical word; Load32/Store32: [4:3] critical word |
| SRC | 8 | source identifier, assigned by the system |
| TID | 8 | transaction identifier, assigned by the initiator |
| MSK | 8 per data word | byte significance; one mask per 8-byte word for stores, a single mask for all words of a load |
| DATA | 64 per word | 0 (loads, Flush, Purge), 1 (Store8, Swap8), 2 (Store16) or 4 (Store32) words |

### Response **D**

| Field | Width | Meaning |
|---|---|---|
| R_OPC | 8 | 0x80 Success, 0x81 Failure |
| R_SRC | 8 | copy of SRC |
| R_TID | 8 | copy of TID |
| R_DATA | 64 per word | 1, 2 or 4 words for Load8/16/32 and Swap8 (old value); none otherwise |

### Burst order (SA Vol. 3 §3.6.5, Tables 79, 80) **D**

Bursts are critical word first with linear wrap: Load32/Store32 with
ADDR[4:3] = 1 transfers words 1, 2, 3, 0. Cache refills and write-backs
from the core always use this order; the core's MMU/cache sets ADDR[4:3]
to the word the pipeline is waiting for.

### Byte lanes (SA Vol. 3 Table 81) **D**

Mask bit i covers DATA[8i+7:8i]. Little endian: mask bit i is address
offset i. Big endian: mask bit i is address offset 7 - i. The core applies
this mapping from its `big_endian_i` input; the bus itself is endian
agnostic.

## Channels **C**

Four unidirectional channels with `valid`/`ready` handshake (transfer when
both are 1 in the same cycle; `valid` may not be withdrawn before
`ready`). Header fields are presented on every beat of a multi-word packet
and are constant across the packet; `last` marks the final beat.

| Channel | Direction | Signals |
|---|---|---|
| Initiator request | core -> system | `ireq_valid`, `ireq_ready`, `ireq_opc[7:0]`, `ireq_addr[31:0]`, `ireq_src[7:0]`, `ireq_tid[7:0]`, `ireq_mask[7:0]`, `ireq_data[63:0]`, `ireq_last` |
| Initiator response | system -> core | `irsp_valid`, `irsp_ready`, `irsp_opc[7:0]`, `irsp_src[7:0]`, `irsp_tid[7:0]`, `irsp_data[63:0]`, `irsp_last` |
| Target request | system -> core | `treq_valid`, `treq_ready`, `treq_opc`, `treq_addr`, `treq_src`, `treq_tid`, `treq_mask`, `treq_data`, `treq_last` |
| Target response | core -> system | `trsp_valid`, `trsp_ready`, `trsp_opc`, `trsp_src`, `trsp_tid`, `trsp_data`, `trsp_last` |

Rules:

- The core issues at most `2**TID_BITS` outstanding requests (parameter,
  default 3 bits = 8) and never reuses a TID before its response has
  arrived. Responses to different TIDs may arrive in any order; beats of
  one response arrive back to back without interleaving.
- A Store or Swap request's data beats follow its header beat without
  interleaving with other requests.
- Load responses carry exactly the number of words of the request; a
  Failure response carries no data words (`last` on the header beat).
- Store responses are one beat. The core counts them to implement SYNCO
  and the write-through and device ordering rules.
- The core issues Load8/Store8/Swap8 for uncached and device accesses and
  MMU-off accesses (exact size via MSK), Load32 for cache refills and
  instruction fetch with the MMU on, Store32 for write-backs, Store8 for
  write-through writes. Load16/Store16, Flush and Purge are not issued.
- Target side: the core answers Load8 to `ADDR[23:0]` = 0x00 and 0x08 with
  the VCR (both offsets, the evaluation chip shows the VCR at offset 8 as
  well, `cayman-platform.md`), ignores Store8 to them, and answers every
  other target request with Failure. Flush/Purge targeting the operand
  cache are a later addition.
- All channels run on the core clock. A clock domain crossing to a bus
  clock, if any, is outside the core.

## VCR **C**

64-bit, read only: `[47:32]` module id (parameter `MODULE_ID`), `[31:16]`
module version (`MODULE_VERSION`), `[63:56]` and `[55:48]` error flags
(set when an initiator transaction receives Failure: bit 56 for loads,
bit 57 for stores, bit 58 for swaps), cleared by a Store8 to offset 0.
The field positions follow the per-module VCR layout seen on the
evaluation chip (`cayman-platform.md`).

## Failure handling **C**

The CPU architecture has no bus error event. A Failure response to a load
returns zeros to the pipeline, sets the VCR flag and pulses
`bus_error_o`; a Failure to a store or write-back sets the flag and pulses
`bus_error_o`. The system may route `bus_error_o` to the INTC.

## Bridging

The channel carries a strict superset of what AXI4 or Wishbone pipelined
need: OPC maps to read/write with burst length 1, 2 or 4 and size 8;
MSK to byte strobes; TID to the AXI id; Swap8 needs an exclusive or
locked access on the far side. A reconstructed SuperHyway arbiter can
pass the packets through unchanged.
