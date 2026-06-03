// Shared packet/command-field definitions for the CHI <-> CXL bridge.
//
// Upstream  (host side):  64-bit AMBA CHI request and response flits (a compact
//                         model of the CHI REQ channel inbound and RSP/DAT
//                         channel outbound).
// Downstream (link side): 64-bit CXL.mem flits — M2S Req/RwD outbound and
//                         S2M DRS/NDR responses inbound.
//
// A CHI request is decoded into a single CXL.mem M2S flit:
//   READ      -> MEMRD  / MEMRDS  (snooped / shared, ReadOnce)
//   WRITE     -> MEMWR  / MEMWRPTL (partial / WriteNoSnpPtl)
//   ATOMIC    -> MEMINV  (atomic / ownership)
//   DATALESS  -> MEMINV  (cache-maintenance, e.g. CleanInvalid)
// A CXL.mem S2M response is decoded back into a CHI response flit:
//   DRS (MemData) -> CompData     (read-data return)
//   NDR (Cmp)     -> Comp         (write completion)
//   NDR (DBID)    -> DBIDResp     (data-buffer-ID grant)
// The 16-bit CHI address is carried through unchanged in the ADDR field so the
// mapping is reversible for end-to-end scoreboard checking.

`ifndef CHI_TO_CXL_BRIDGE_DEFS_VH
`define CHI_TO_CXL_BRIDGE_DEFS_VH

// ---- CHI request packet kinds [63:60] (upstream ingress) ----
localparam [3:0] CHI_REQ_KIND_READ      = 4'h1; // read request        (non-posted)
localparam [3:0] CHI_REQ_KIND_WRITE     = 4'h2; // write request       (posted)
localparam [3:0] CHI_REQ_KIND_ATOMIC    = 4'h3; // atomic request      (non-posted)
localparam [3:0] CHI_REQ_KIND_DATALESS  = 4'h4; // dataless / cmo req  (non-posted)

// ---- CHI response packet kinds [63:60] (upstream egress) ----
localparam [3:0] CHI_RSP_KIND_COMPDATA  = 4'h8; // read-data completion  (CompData)
localparam [3:0] CHI_RSP_KIND_COMP      = 4'h9; // write completion       (Comp)
localparam [3:0] CHI_RSP_KIND_DBIDRESP  = 4'ha; // data-buffer-id grant   (DBIDResp)
localparam [3:0] CHI_RSP_KIND_INVALID   = 4'hf; // protocol/CRC error     (RespErr)

// ---- CHI read opcodes (PKT_CODE of CHI_REQ_KIND_READ) ----
localparam [3:0] CHI_RD_OP_NOSNP        = 4'h0; // ReadNoSnp
localparam [3:0] CHI_RD_OP_ONCE         = 4'h1; // ReadOnce  (snooped / shared)

// ---- CHI write opcodes (PKT_CODE of CHI_REQ_KIND_WRITE) ----
localparam [3:0] CHI_WR_OP_NOSNP        = 4'h0; // WriteNoSnpFull
localparam [3:0] CHI_WR_OP_UNIQUE       = 4'h1; // WriteUniqueFull
localparam [3:0] CHI_WR_OP_PTL          = 4'h2; // WriteNoSnpPtl (partial)

// ---- CHI response status (PKT_CODE of *_RSP) ----
localparam [3:0] CHI_RESP_OK            = 4'h1; // RespErr = OK / Okay
localparam [3:0] CHI_RESP_ERR           = 4'h2; // RespErr = NDERR / DERR

// ---- CXL.mem downstream packet kinds [63:60] ----
localparam [3:0] CXL_M2S_KIND_REQ       = 4'h8; // M2S Req/RwD (op in PKT_CODE)
localparam [3:0] CXL_S2M_KIND_DRS       = 4'ha; // S2M Data Response (MemData)  (upstream)
localparam [3:0] CXL_S2M_KIND_NDR       = 4'hb; // S2M No-Data Response (Cmp)   (upstream)
localparam [3:0] CXL_S2M_KIND_DBID      = 4'hc; // S2M DBID response            (upstream)
localparam [3:0] CXL_KIND_ERROR         = 4'he;

// ---- CXL M2S sub-ops (PKT_CODE of CXL_M2S_KIND_REQ) ----
localparam [3:0] CXL_M2S_MEMRD          = 4'h1; // MemRd
localparam [3:0] CXL_M2S_MEMRDS         = 4'h2; // MemRd, snooped / shared
localparam [3:0] CXL_M2S_MEMWR          = 4'h3; // MemWr
localparam [3:0] CXL_M2S_MEMWRPTL       = 4'h4; // MemWr, partial (byte-enabled)
localparam [3:0] CXL_M2S_MEMINV         = 4'h5; // MemInv (atomic / ownership / cmo)

// ---- CXL S2M response status (PKT_CODE of *_DRS / *_NDR / *_DBID) ----
localparam [3:0] CXL_RSP_OK             = 4'h1;
localparam [3:0] CXL_RSP_ERR            = 4'h2; // uncorrectable / poison / abort

// ---- 64-bit packet field bit-ranges (shared by both directions) ----
localparam integer PKT_KIND_MSB         = 63;
localparam integer PKT_KIND_LSB         = 60;
localparam integer PKT_CODE_MSB         = 59;
localparam integer PKT_CODE_LSB         = 56;
localparam integer PKT_TAG_MSB          = 55;  // CHI TxnID / CXL Tag (correlates req<->rsp)
localparam integer PKT_TAG_LSB          = 48;
localparam integer PKT_ADDR_MSB         = 47;  // 16-bit address (carried through unchanged)
localparam integer PKT_ADDR_LSB         = 32;
localparam integer PKT_LEN_MSB          = 31;  // burst length / data size
localparam integer PKT_LEN_LSB          = 24;
localparam integer PKT_ID_MSB           = 23;  // CHI SrcID / CXL completer/requester ID
localparam integer PKT_ID_LSB           = 16;
localparam integer PKT_AUX_MSB          = 15;  // attributes (snoop/order/cache state)
localparam integer PKT_AUX_LSB          = 8;
localparam integer PKT_MISC_MSB         = 7;   // CRC-8 checksum on the link channel
localparam integer PKT_MISC_LSB         = 0;

// ---- CHI request pack helpers ----

function automatic [63:0] pack_chi_read;
  input [3:0]  opcode;
  input [7:0]  txn_id;
  input [15:0] addr16;
  input [7:0]  size;
  input [7:0]  src_id;
  input [7:0]  attr;
  begin
    pack_chi_read = {CHI_REQ_KIND_READ, opcode, txn_id, addr16,
                     size, src_id, attr, 8'h00};
  end
endfunction

function automatic [63:0] pack_chi_write;
  input [3:0]  opcode;
  input [7:0]  txn_id;
  input [15:0] addr16;
  input [7:0]  size;
  input [7:0]  src_id;
  input [7:0]  attr;
  begin
    pack_chi_write = {CHI_REQ_KIND_WRITE, opcode, txn_id, addr16,
                      size, src_id, attr, 8'h00};
  end
endfunction

function automatic [63:0] pack_chi_atomic;
  input [3:0]  opcode;
  input [7:0]  txn_id;
  input [15:0] addr16;
  input [7:0]  size;
  input [7:0]  src_id;
  input [7:0]  attr;
  begin
    pack_chi_atomic = {CHI_REQ_KIND_ATOMIC, opcode, txn_id, addr16,
                       size, src_id, attr, 8'h00};
  end
endfunction

function automatic [63:0] pack_chi_dataless;
  input [3:0]  opcode;
  input [7:0]  txn_id;
  input [15:0] addr16;
  input [7:0]  size;
  input [7:0]  src_id;
  input [7:0]  attr;
  begin
    pack_chi_dataless = {CHI_REQ_KIND_DATALESS, opcode, txn_id, addr16,
                         size, src_id, attr, 8'h00};
  end
endfunction

// ---- CHI response pack helpers ----

function automatic [63:0] pack_chi_compdata;
  input [3:0]  resp;
  input [7:0]  txn_id;
  input [15:0] byte_count;
  input [7:0]  size;
  input [7:0]  src_id;
  input [7:0]  attr;
  begin
    pack_chi_compdata = {CHI_RSP_KIND_COMPDATA, resp, txn_id, byte_count,
                         size, src_id, attr, 8'h00};
  end
endfunction

function automatic [63:0] pack_chi_comp;
  input [3:0]  resp;
  input [7:0]  txn_id;
  input [15:0] byte_count;
  input [7:0]  size;
  input [7:0]  src_id;
  input [7:0]  attr;
  begin
    pack_chi_comp = {CHI_RSP_KIND_COMP, resp, txn_id, byte_count,
                     size, src_id, attr, 8'h00};
  end
endfunction

function automatic [63:0] pack_chi_dbidresp;
  input [3:0]  resp;
  input [7:0]  txn_id;
  input [15:0] byte_count;
  input [7:0]  size;
  input [7:0]  src_id;
  input [7:0]  attr;
  begin
    pack_chi_dbidresp = {CHI_RSP_KIND_DBIDRESP, resp, txn_id, byte_count,
                         size, src_id, attr, 8'h00};
  end
endfunction

// ---- CXL.mem M2S / S2M pack helpers ----

function automatic [63:0] pack_cxl_m2s;
  input [3:0]  cxl_op;
  input [7:0]  tag;
  input [15:0] addr16;
  input [7:0]  size;
  input [7:0]  src_id;
  input [7:0]  attr;
  input [7:0]  checksum;
  begin
    pack_cxl_m2s = {CXL_M2S_KIND_REQ, cxl_op, tag, addr16,
                    size, src_id, attr, checksum};
  end
endfunction

function automatic [63:0] pack_cxl_drs;
  input [3:0]  status;
  input [7:0]  tag;
  input [15:0] byte_count;
  input [7:0]  size;
  input [7:0]  src_id;
  input [7:0]  attr;
  input [7:0]  checksum;
  begin
    pack_cxl_drs = {CXL_S2M_KIND_DRS, status, tag, byte_count,
                    size, src_id, attr, checksum};
  end
endfunction

function automatic [63:0] pack_cxl_ndr;
  input [3:0]  status;
  input [7:0]  tag;
  input [15:0] byte_count;
  input [7:0]  size;
  input [7:0]  src_id;
  input [7:0]  attr;
  input [7:0]  checksum;
  begin
    pack_cxl_ndr = {CXL_S2M_KIND_NDR, status, tag, byte_count,
                    size, src_id, attr, checksum};
  end
endfunction

function automatic [63:0] pack_cxl_dbid;
  input [3:0]  status;
  input [7:0]  tag;
  input [15:0] byte_count;
  input [7:0]  size;
  input [7:0]  src_id;
  input [7:0]  attr;
  input [7:0]  checksum;
  begin
    pack_cxl_dbid = {CXL_S2M_KIND_DBID, status, tag, byte_count,
                     size, src_id, attr, checksum};
  end
endfunction

// ---- Checksum ----
// CRC-8/CCITT (poly 0x07, init 0x00) over header bytes [63:8] (7 bytes).
// Caller must zero the misc byte [7:0] before calling; that byte is not read here.
/* verilator lint_off UNUSEDSIGNAL */
function automatic [7:0] bridge_checksum;
  input [63:0] p; // packet_wo_checksum
  reg [7:0] c;     // crc
  begin
    c = 8'h00;
    c = crc8_step(c ^ p[63:56]);
    c = crc8_step(c ^ p[55:48]);
    c = crc8_step(c ^ p[47:40]);
    c = crc8_step(c ^ p[39:32]);
    c = crc8_step(c ^ p[31:24]);
    c = crc8_step(c ^ p[23:16]);
    c = crc8_step(c ^ p[15:8]);
    bridge_checksum = c;
  end
endfunction

// Combinational single-byte CRC-8/CCITT step (8 shift iterations).
function automatic [7:0] crc8_step;
  input [7:0] b;
  reg [7:0] c0, c1, c2, c3, c4, c5, c6, c7;
  begin
    c0 = b[7] ? ((b << 1) ^ 8'h07) : (b << 1);
    c1 = c0[7] ? ((c0 << 1) ^ 8'h07) : (c0 << 1);
    c2 = c1[7] ? ((c1 << 1) ^ 8'h07) : (c1 << 1);
    c3 = c2[7] ? ((c2 << 1) ^ 8'h07) : (c2 << 1);
    c4 = c3[7] ? ((c3 << 1) ^ 8'h07) : (c3 << 1);
    c5 = c4[7] ? ((c4 << 1) ^ 8'h07) : (c4 << 1);
    c6 = c5[7] ? ((c5 << 1) ^ 8'h07) : (c5 << 1);
    c7 = c6[7] ? ((c6 << 1) ^ 8'h07) : (c6 << 1);
    crc8_step = c7;
  end
endfunction
/* verilator lint_on UNUSEDSIGNAL */

`endif
