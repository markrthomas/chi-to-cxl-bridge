// Structured flit / field definitions for the CHI <-> CXL.mem bridge (Phase 3a).
//
// Compact-model note: this replaces the earlier single 64-bit packet abstraction
// with realistically-fielded AMBA CHI and CXL.mem channel flits. Flits are packed
// bit-vectors with `<FLIT>_<FIELD>_LSB` / `<FLIT>_<FIELD>_W` localparams; slice
// with the indexed part-select `flit[<...>_LSB +: <...>_W]` (Verilog-2001, OSS
// tool friendly -- no SystemVerilog structs). Single 512-bit (64-byte) data beat;
// multi-beat bursts, the SNP channel, atomics, and CompAck are deferred.
//
// Channels (single clock):
//   CHI host : REQ in, RSP out, DAT(CompData) out, DAT(WrData) in
//   CXL link : M2S Req out, M2S RwD out, S2M NDR in, S2M DRS in
//
// Handshakes (ExpCompAck = 0):
//   Read  : REQ -> M2S Req(MemRd)  -> S2M DRS(MemData) -> CHI CompData
//   Write : REQ -> CHI DBIDResp -> CHI WrData -> M2S RwD(MemWr/MemWrPtl)
//           -> S2M NDR(Cmp) -> CHI Comp

`ifndef CHI_TO_CXL_BRIDGE_DEFS_VH
`define CHI_TO_CXL_BRIDGE_DEFS_VH

// ---- Global widths ----
// Data-width abstraction for the integrated formal `prove`: the bridge's safety
// properties (handshake valid/data stability, credit conservation, FIFO
// occupancy, routing) are width-independent, but a full 512-bit datapath makes
// the unbounded SMT proof intractable on memory. FORMAL_SMALL_DATA shrinks the
// beat for the bridge .sby only; simulation, coverage, SVA and synth keep 512.
`ifdef FORMAL_SMALL_DATA
localparam integer DATA_W   = 8;            // abstracted beat (formal prove only)
`else
localparam integer DATA_W   = 512;          // one 64-byte beat
`endif
localparam integer BE_W     = DATA_W/8;     // 64
localparam integer CHI_CXL_ADDR_W = 48;
localparam integer TXNID_W  = 8;            // CHI TxnID
localparam integer NODEID_W = 7;            // CHI SrcID / TgtID
localparam integer QOS_W    = 4;
localparam integer TAG_W    = 4;            // CXL Tag / CHI DBID == bridge txn slot
localparam integer N_OUTSTANDING = 16;      // 2**TAG_W

// ---- Multi-beat bursts (Phase 3 completion) ----
// A CHI request transfers LEN data beats (1..MAX_BEATS), a runtime-variable
// burst length carried in the request's Size field. A transaction's beats are
// contiguous on each data channel (the CXL device returns a read's beats as one
// burst), so the datapath tracks beats with a single counter per channel rather
// than per-tag state. LEN is conveyed to the CXL device in the M2S Req (see
// CXL_REQ_LEN below) so it returns the right number of DRS beats.
localparam integer MAX_BEATS = 4;
localparam integer BEATCNT_W = 3;           // holds a beat count 1..MAX_BEATS

// ============================ CHI opcodes / codes ============================
// Representative encodings (not bit-exact to the CHI spec, but distinct & stable).

// CHI REQ opcodes (7b)
localparam [6:0] CHI_REQ_READNOSNP       = 7'h04;
localparam [6:0] CHI_REQ_READONCE        = 7'h03;
localparam [6:0] CHI_REQ_WRITENOSNPFULL  = 7'h1D;
localparam [6:0] CHI_REQ_WRITENOSNPPTL   = 7'h1C;
localparam [6:0] CHI_REQ_WRITEUNIQUEFULL = 7'h19;

// CHI RSP opcodes (4b)
localparam [3:0] CHI_RSP_COMP            = 4'h4;
localparam [3:0] CHI_RSP_DBIDRESP        = 4'h3;
localparam [3:0] CHI_RSP_COMPDBIDRESP    = 4'h5;

// CHI SNP opcodes (5b, representative) — host-side snoops of the device.
localparam [4:0] CHI_SNP_SNPONCE         = 5'h03;
localparam [4:0] CHI_SNP_SNPSHARED       = 5'h01;
localparam [4:0] CHI_SNP_SNPUNIQUE       = 5'h07;

// CHI SnpResp opcode (4b) and cache-state Resp (3b, reuses CHI_CACHE_*).
// A CXL.mem device is memory-only (holds no cached copy), so every snoop is
// answered SnpResp with final state Invalid — the minimal snoop path.
localparam [3:0] CHI_RSP_SNPRESP         = 4'h1;

// CHI DAT opcodes (4b)
localparam [3:0] CHI_DAT_COMPDATA        = 4'h4;
localparam [3:0] CHI_DAT_NCBWRDATA       = 4'h3;

// CHI RespErr (2b)
localparam [1:0] CHI_RESPERR_OK    = 2'b00;
localparam [1:0] CHI_RESPERR_EXOK  = 2'b01;
localparam [1:0] CHI_RESPERR_DERR  = 2'b10;  // data error (poisoned read data)
localparam [1:0] CHI_RESPERR_NDERR = 2'b11;  // non-data error (errored write/cmp)

// CHI cache-state Resp on CompData (3b)
localparam [2:0] CHI_CACHE_I  = 3'b000;
localparam [2:0] CHI_CACHE_SC = 3'b001;
localparam [2:0] CHI_CACHE_UC = 3'b010;

// ============================ CXL.mem opcodes ============================
// CXL M2S MemOpcode (4b)
localparam [3:0] CXL_MEMRD     = 4'h1;
localparam [3:0] CXL_MEMRDDATA = 4'h2;
localparam [3:0] CXL_MEMWR     = 4'h3;
localparam [3:0] CXL_MEMWRPTL  = 4'h4;
localparam [3:0] CXL_MEMINV    = 4'h5;
localparam [3:0] CXL_MEMSPECRD = 4'h6;

// CXL S2M NDR opcode (3b)
localparam [2:0] CXL_NDR_CMP   = 3'h0;
localparam [2:0] CXL_NDR_CMPS  = 3'h1;
localparam [2:0] CXL_NDR_CMPE  = 3'h2;

// CXL S2M DRS opcode (3b)
localparam [2:0] CXL_DRS_MEMDATA = 3'h0;

// ======================== CHI REQ flit field map ========================
// {QoS, TgtID, SrcID, TxnID, Opcode, Addr, Size, MemAttr, Order}
localparam integer CHI_REQ_ORDER_W   = 2;
localparam integer CHI_REQ_MEMATTR_W = 4;
localparam integer CHI_REQ_SIZE_W    = 3;
localparam integer CHI_REQ_ADDR_W    = CHI_CXL_ADDR_W;
localparam integer CHI_REQ_OPCODE_W  = 7;
localparam integer CHI_REQ_TXNID_W   = TXNID_W;
localparam integer CHI_REQ_SRCID_W   = NODEID_W;
localparam integer CHI_REQ_TGTID_W   = NODEID_W;
localparam integer CHI_REQ_QOS_W     = QOS_W;

localparam integer CHI_REQ_ORDER_LSB   = 0;
localparam integer CHI_REQ_MEMATTR_LSB = CHI_REQ_ORDER_LSB   + CHI_REQ_ORDER_W;
localparam integer CHI_REQ_SIZE_LSB    = CHI_REQ_MEMATTR_LSB + CHI_REQ_MEMATTR_W;
localparam integer CHI_REQ_ADDR_LSB    = CHI_REQ_SIZE_LSB    + CHI_REQ_SIZE_W;
localparam integer CHI_REQ_OPCODE_LSB  = CHI_REQ_ADDR_LSB    + CHI_REQ_ADDR_W;
localparam integer CHI_REQ_TXNID_LSB   = CHI_REQ_OPCODE_LSB  + CHI_REQ_OPCODE_W;
localparam integer CHI_REQ_SRCID_LSB   = CHI_REQ_TXNID_LSB   + CHI_REQ_TXNID_W;
localparam integer CHI_REQ_TGTID_LSB   = CHI_REQ_SRCID_LSB   + CHI_REQ_SRCID_W;
localparam integer CHI_REQ_QOS_LSB     = CHI_REQ_TGTID_LSB   + CHI_REQ_TGTID_W;
localparam integer CHI_REQ_W           = CHI_REQ_QOS_LSB     + CHI_REQ_QOS_W;  // 90

// ======================== CHI RSP flit field map ========================
// {SrcID, Opcode, TxnID, DBID, RespErr}
localparam integer CHI_RSP_RESPERR_W = 2;
localparam integer CHI_RSP_DBID_W    = TAG_W;
localparam integer CHI_RSP_TXNID_W   = TXNID_W;
localparam integer CHI_RSP_OPCODE_W  = 4;
localparam integer CHI_RSP_SRCID_W   = NODEID_W;

localparam integer CHI_RSP_RESPERR_LSB = 0;
localparam integer CHI_RSP_DBID_LSB    = CHI_RSP_RESPERR_LSB + CHI_RSP_RESPERR_W;
localparam integer CHI_RSP_TXNID_LSB   = CHI_RSP_DBID_LSB    + CHI_RSP_DBID_W;
localparam integer CHI_RSP_OPCODE_LSB  = CHI_RSP_TXNID_LSB   + CHI_RSP_TXNID_W;
localparam integer CHI_RSP_SRCID_LSB   = CHI_RSP_OPCODE_LSB  + CHI_RSP_OPCODE_W;
localparam integer CHI_RSP_W           = CHI_RSP_SRCID_LSB   + CHI_RSP_SRCID_W;  // 25

// ======================== CHI DAT flit field map ========================
// shared by CompData (out) and NCBWrData (in)
// {Opcode, TxnID/DBID, Resp(cache), RespErr, DataID, Poison, BE, Data}
localparam integer CHI_DAT_DATA_W    = DATA_W;
localparam integer CHI_DAT_BE_W      = BE_W;
localparam integer CHI_DAT_POISON_W  = 1;
localparam integer CHI_DAT_DATAID_W  = 4;
localparam integer CHI_DAT_RESPERR_W = 2;
localparam integer CHI_DAT_RESP_W    = 3;
localparam integer CHI_DAT_TXNID_W   = TXNID_W;
localparam integer CHI_DAT_OPCODE_W  = 4;

localparam integer CHI_DAT_DATA_LSB    = 0;
localparam integer CHI_DAT_BE_LSB      = CHI_DAT_DATA_LSB    + CHI_DAT_DATA_W;
localparam integer CHI_DAT_POISON_LSB  = CHI_DAT_BE_LSB      + CHI_DAT_BE_W;
localparam integer CHI_DAT_DATAID_LSB  = CHI_DAT_POISON_LSB  + CHI_DAT_POISON_W;
localparam integer CHI_DAT_RESPERR_LSB = CHI_DAT_DATAID_LSB  + CHI_DAT_DATAID_W;
localparam integer CHI_DAT_RESP_LSB    = CHI_DAT_RESPERR_LSB + CHI_DAT_RESPERR_W;
localparam integer CHI_DAT_TXNID_LSB   = CHI_DAT_RESP_LSB    + CHI_DAT_RESP_W;
localparam integer CHI_DAT_OPCODE_LSB  = CHI_DAT_TXNID_LSB   + CHI_DAT_TXNID_W;
localparam integer CHI_DAT_W           = CHI_DAT_OPCODE_LSB  + CHI_DAT_OPCODE_W;  // 598

// ======================== CXL M2S Req flit field map ========================
// {MemOpcode, Len, SnpType, MetaField, MetaValue, Tag, Addr, TC}
// Len carries the burst beat count so the device returns that many DRS beats.
localparam integer CXL_REQ_TC_W        = 2;
localparam integer CXL_REQ_ADDR_W      = CHI_CXL_ADDR_W;
localparam integer CXL_REQ_TAG_W       = TAG_W;
localparam integer CXL_REQ_METAVAL_W   = 2;
localparam integer CXL_REQ_METAFLD_W   = 2;
localparam integer CXL_REQ_SNPTYPE_W   = 3;
localparam integer CXL_REQ_LEN_W       = BEATCNT_W;
localparam integer CXL_REQ_MEMOP_W     = 4;

localparam integer CXL_REQ_TC_LSB      = 0;
localparam integer CXL_REQ_ADDR_LSB    = CXL_REQ_TC_LSB      + CXL_REQ_TC_W;
localparam integer CXL_REQ_TAG_LSB     = CXL_REQ_ADDR_LSB    + CXL_REQ_ADDR_W;
localparam integer CXL_REQ_METAVAL_LSB = CXL_REQ_TAG_LSB     + CXL_REQ_TAG_W;
localparam integer CXL_REQ_METAFLD_LSB = CXL_REQ_METAVAL_LSB + CXL_REQ_METAVAL_W;
localparam integer CXL_REQ_SNPTYPE_LSB = CXL_REQ_METAFLD_LSB + CXL_REQ_METAFLD_W;
localparam integer CXL_REQ_LEN_LSB     = CXL_REQ_SNPTYPE_LSB + CXL_REQ_SNPTYPE_W;
localparam integer CXL_REQ_MEMOP_LSB   = CXL_REQ_LEN_LSB     + CXL_REQ_LEN_W;
localparam integer CXL_REQ_W           = CXL_REQ_MEMOP_LSB   + CXL_REQ_MEMOP_W;  // 68

// ======================== CXL M2S RwD flit field map ========================
// {MemOpcode, Len, Tag, Addr, MetaField, MetaValue, Poison, BE, Data}
// Len carries the write burst length (1..MAX_BEATS) so the device knows how many
// RwD beats to consume before completing (NDR), mirroring CXL_REQ_LEN for reads.
localparam integer CXL_RWD_DATA_W    = DATA_W;
localparam integer CXL_RWD_BE_W      = BE_W;
localparam integer CXL_RWD_POISON_W  = 1;
localparam integer CXL_RWD_METAVAL_W = 2;
localparam integer CXL_RWD_METAFLD_W = 2;
localparam integer CXL_RWD_ADDR_W    = CHI_CXL_ADDR_W;
localparam integer CXL_RWD_TAG_W     = TAG_W;
localparam integer CXL_RWD_LEN_W     = BEATCNT_W;
localparam integer CXL_RWD_MEMOP_W   = 4;

localparam integer CXL_RWD_DATA_LSB    = 0;
localparam integer CXL_RWD_BE_LSB      = CXL_RWD_DATA_LSB    + CXL_RWD_DATA_W;
localparam integer CXL_RWD_POISON_LSB  = CXL_RWD_BE_LSB      + CXL_RWD_BE_W;
localparam integer CXL_RWD_METAVAL_LSB = CXL_RWD_POISON_LSB  + CXL_RWD_POISON_W;
localparam integer CXL_RWD_METAFLD_LSB = CXL_RWD_METAVAL_LSB + CXL_RWD_METAVAL_W;
localparam integer CXL_RWD_ADDR_LSB    = CXL_RWD_METAFLD_LSB + CXL_RWD_METAFLD_W;
localparam integer CXL_RWD_TAG_LSB     = CXL_RWD_ADDR_LSB    + CXL_RWD_ADDR_W;
localparam integer CXL_RWD_LEN_LSB     = CXL_RWD_TAG_LSB     + CXL_RWD_TAG_W;
localparam integer CXL_RWD_MEMOP_LSB   = CXL_RWD_LEN_LSB     + CXL_RWD_LEN_W;
localparam integer CXL_RWD_W           = CXL_RWD_MEMOP_LSB   + CXL_RWD_MEMOP_W;  // 640

// ======================== CXL S2M NDR flit field map ========================
// {Opcode, MetaField, MetaValue, Tag, DevLoad}
localparam integer CXL_NDR_DEVLOAD_W = 2;
localparam integer CXL_NDR_TAG_W     = TAG_W;
localparam integer CXL_NDR_METAVAL_W = 2;
localparam integer CXL_NDR_METAFLD_W = 2;
localparam integer CXL_NDR_OPCODE_W  = 3;

localparam integer CXL_NDR_DEVLOAD_LSB = 0;
localparam integer CXL_NDR_TAG_LSB     = CXL_NDR_DEVLOAD_LSB + CXL_NDR_DEVLOAD_W;
localparam integer CXL_NDR_METAVAL_LSB = CXL_NDR_TAG_LSB     + CXL_NDR_TAG_W;
localparam integer CXL_NDR_METAFLD_LSB = CXL_NDR_METAVAL_LSB + CXL_NDR_METAVAL_W;
localparam integer CXL_NDR_OPCODE_LSB  = CXL_NDR_METAFLD_LSB + CXL_NDR_METAFLD_W;
localparam integer CXL_NDR_W           = CXL_NDR_OPCODE_LSB  + CXL_NDR_OPCODE_W;  // 13

// ======================== CXL S2M DRS flit field map ========================
// {Opcode, MetaField, MetaValue, Tag, DevLoad, Poison, Data}
localparam integer CXL_DRS_DATA_W    = DATA_W;
localparam integer CXL_DRS_POISON_W  = 1;
localparam integer CXL_DRS_DEVLOAD_W = 2;
localparam integer CXL_DRS_TAG_W     = TAG_W;
localparam integer CXL_DRS_METAVAL_W = 2;
localparam integer CXL_DRS_METAFLD_W = 2;
localparam integer CXL_DRS_OPCODE_W  = 3;

localparam integer CXL_DRS_DATA_LSB    = 0;
localparam integer CXL_DRS_POISON_LSB  = CXL_DRS_DATA_LSB    + CXL_DRS_DATA_W;
localparam integer CXL_DRS_DEVLOAD_LSB = CXL_DRS_POISON_LSB  + CXL_DRS_POISON_W;
localparam integer CXL_DRS_TAG_LSB     = CXL_DRS_DEVLOAD_LSB + CXL_DRS_DEVLOAD_W;
localparam integer CXL_DRS_METAVAL_LSB = CXL_DRS_TAG_LSB     + CXL_DRS_TAG_W;
localparam integer CXL_DRS_METAFLD_LSB = CXL_DRS_METAVAL_LSB + CXL_DRS_METAVAL_W;
localparam integer CXL_DRS_OPCODE_LSB  = CXL_DRS_METAFLD_LSB + CXL_DRS_METAFLD_W;
localparam integer CXL_DRS_W           = CXL_DRS_OPCODE_LSB  + CXL_DRS_OPCODE_W;  // 526

// ======================== CHI SNP flit field map ========================
// Host-side snoop request into the bridge. {SrcID, Opcode, TxnID, Addr}
localparam integer CHI_SNP_ADDR_W   = CHI_CXL_ADDR_W;
localparam integer CHI_SNP_TXNID_W  = TXNID_W;
localparam integer CHI_SNP_OPCODE_W = 5;
localparam integer CHI_SNP_SRCID_W  = NODEID_W;

localparam integer CHI_SNP_ADDR_LSB   = 0;
localparam integer CHI_SNP_TXNID_LSB  = CHI_SNP_ADDR_LSB   + CHI_SNP_ADDR_W;
localparam integer CHI_SNP_OPCODE_LSB = CHI_SNP_TXNID_LSB  + CHI_SNP_TXNID_W;
localparam integer CHI_SNP_SRCID_LSB  = CHI_SNP_OPCODE_LSB + CHI_SNP_OPCODE_W;
localparam integer CHI_SNP_W          = CHI_SNP_SRCID_LSB  + CHI_SNP_SRCID_W;  // 68

// ======================== CHI SnpResp flit field map ========================
// Snoop response out of the bridge. {SrcID, Opcode, TxnID, Resp(cache state), RespErr}
localparam integer CHI_SNPRSP_RESPERR_W = 2;
localparam integer CHI_SNPRSP_RESP_W    = 3;
localparam integer CHI_SNPRSP_TXNID_W   = TXNID_W;
localparam integer CHI_SNPRSP_OPCODE_W  = 4;
localparam integer CHI_SNPRSP_SRCID_W   = NODEID_W;

localparam integer CHI_SNPRSP_RESPERR_LSB = 0;
localparam integer CHI_SNPRSP_RESP_LSB    = CHI_SNPRSP_RESPERR_LSB + CHI_SNPRSP_RESPERR_W;
localparam integer CHI_SNPRSP_TXNID_LSB   = CHI_SNPRSP_RESP_LSB    + CHI_SNPRSP_RESP_W;
localparam integer CHI_SNPRSP_OPCODE_LSB  = CHI_SNPRSP_TXNID_LSB   + CHI_SNPRSP_TXNID_W;
localparam integer CHI_SNPRSP_SRCID_LSB   = CHI_SNPRSP_OPCODE_LSB  + CHI_SNPRSP_OPCODE_W;
localparam integer CHI_SNPRSP_W           = CHI_SNPRSP_SRCID_LSB   + CHI_SNPRSP_SRCID_W;  // 24

// ---- Classification helpers ----
// Burst beat count from a CHI REQ Size field: Size holds the count directly
// (1..MAX_BEATS); 0 or out-of-range is treated as a single beat.
function automatic [BEATCNT_W-1:0] chi_req_beats;
  input [CHI_REQ_SIZE_W-1:0] size;
  begin
    if (size == 0 || {{(BEATCNT_W-CHI_REQ_SIZE_W){1'b0}}, size} > MAX_BEATS[BEATCNT_W-1:0])
      chi_req_beats = 3'd1;
    else
      chi_req_beats = {{(BEATCNT_W-CHI_REQ_SIZE_W){1'b0}}, size};
  end
endfunction

// True for CHI REQ opcodes that are writes (carry a WrData phase).
function automatic is_chi_write;
  input [6:0] opcode;
  begin
    case (opcode)
      CHI_REQ_WRITENOSNPFULL,
      CHI_REQ_WRITENOSNPPTL,
      CHI_REQ_WRITEUNIQUEFULL: is_chi_write = 1'b1;
      default:                 is_chi_write = 1'b0;
    endcase
  end
endfunction

// True for CHI REQ opcodes that are reads.
function automatic is_chi_read;
  input [6:0] opcode;
  begin
    case (opcode)
      CHI_REQ_READNOSNP,
      CHI_REQ_READONCE: is_chi_read = 1'b1;
      default:          is_chi_read = 1'b0;
    endcase
  end
endfunction

`endif
