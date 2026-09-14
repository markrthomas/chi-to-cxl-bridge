// -----------------------------------------------------------------------------
// chi_to_cxl_sva -- bound SystemVerilog assertions on the chi_to_cxl_bridge
// boundary (aligned with ../ucie2-pipe7-bridge/dv/uvm/sv/ucie2_pipe7_sva.sv).
//
// A checker module bound into `chi_to_cxl_bridge`. It contains NO logic and
// drives nothing: it only observes the boundary ports and asserts properties
// that must hold. There are no RTL edits -- the bind at the bottom attaches it to
// every chi_to_cxl_bridge instance.
//
// Where it runs: the pyuvm tier builds it in (ASSERT=1 -> `make sva` at the repo
// root passes Verilator --assert), so the properties are checked during the
// round-trip / random runs. It is NOT in rtl.f, so `make lint`, the plain pyuvm
// gate, and formal never see it.
//
// Two clock domains are observed: clk (CHI side) and cxl_clk (CXL link side).
// Each property names its own clock and is disabled during reset.
// -----------------------------------------------------------------------------
`default_nettype none

// The defs header supplies the flit field offsets used below; not every constant
// is referenced here, so waive unused-parameter noise (cf. the RTL include).
/* verilator lint_off UNUSEDPARAM */
`include "chi_to_cxl_bridge_defs.vh"
/* verilator lint_on UNUSEDPARAM */

// disable iff (!rst_n) reads the async reset net the RTL uses asynchronously --
// the standard way to reset-qualify an assertion; suppress the -Wall-only warning.
/* verilator lint_off SYNCASYNCNET */
module chi_to_cxl_sva (
  input wire                 clk,
  input wire                 cxl_clk,
  input wire                 rst_n,
  // CXL M2S (cxl_clk)
  input wire                 cxl_tx_req_valid,
  input wire [CXL_REQ_W-1:0] cxl_tx_req_data,
  input wire                 cxl_tx_req_ready,
  input wire                 cxl_tx_rwd_valid,
  input wire [CXL_RWD_W-1:0] cxl_tx_rwd_data,
  input wire                 cxl_tx_rwd_ready,
  // CHI response / completion (clk)
  input wire                 chi_rsp_valid,
  input wire [CHI_RSP_W-1:0] chi_rsp_data,
  input wire                 chi_rsp_ready,
  input wire                 chi_comp_data_valid,
  input wire [CHI_DAT_W-1:0] chi_comp_data,
  input wire                 chi_comp_data_ready,
  // CHI SnpResp egress (clk)
  input wire                    chi_snp_resp_valid,
  input wire [CHI_SNPRSP_W-1:0] chi_snp_resp_data,
  input wire                    chi_snp_resp_ready
);

  // ===========================================================================
  // P1/P2 -- M2S egress handshake stability (cxl_clk): a presented flit is held
  // with stable data until the CXL link accepts it.
  // ===========================================================================
  a_tx_req_stable: assert property (
    @(posedge cxl_clk) disable iff (!rst_n)
      (cxl_tx_req_valid && !cxl_tx_req_ready) |=>
        (cxl_tx_req_valid && $stable(cxl_tx_req_data))
  ) else $error("[SVA] cxl_tx_req flit changed/dropped while stalled");

  a_tx_rwd_stable: assert property (
    @(posedge cxl_clk) disable iff (!rst_n)
      (cxl_tx_rwd_valid && !cxl_tx_rwd_ready) |=>
        (cxl_tx_rwd_valid && $stable(cxl_tx_rwd_data))
  ) else $error("[SVA] cxl_tx_rwd flit changed/dropped while stalled");

  // ===========================================================================
  // P3 -- no phantom read on the M2S Req channel. The bridge only translates CHI
  // reads onto Req (MemRd / MemRdData); a MemInv there is the stale/empty-FIFO
  // phantom Req regression (chi_to_cxl_bridge.v egress qualifier). This is the
  // per-cycle guard for the bug the pyuvm cross-check also catches.
  // ===========================================================================
  a_no_phantom_req: assert property (
    @(posedge cxl_clk) disable iff (!rst_n)
      cxl_tx_req_valid |->
        (cxl_tx_req_data[CXL_REQ_MEMOP_LSB +: CXL_REQ_MEMOP_W] == CXL_MEMRD ||
         cxl_tx_req_data[CXL_REQ_MEMOP_LSB +: CXL_REQ_MEMOP_W] == CXL_MEMRDDATA)
  ) else $error("[SVA] phantom M2S Req: MemOpcode=%h",
                cxl_tx_req_data[CXL_REQ_MEMOP_LSB +: CXL_REQ_MEMOP_W]);

  // ===========================================================================
  // P4/P5 -- CHI response handshake stability (clk).
  // ===========================================================================
  a_rsp_stable: assert property (
    @(posedge clk) disable iff (!rst_n)
      (chi_rsp_valid && !chi_rsp_ready) |=>
        (chi_rsp_valid && $stable(chi_rsp_data))
  ) else $error("[SVA] chi_rsp flit changed/dropped while stalled");

  a_comp_data_stable: assert property (
    @(posedge clk) disable iff (!rst_n)
      (chi_comp_data_valid && !chi_comp_data_ready) |=>
        (chi_comp_data_valid && $stable(chi_comp_data))
  ) else $error("[SVA] chi_comp_data flit changed/dropped while stalled");

  // ===========================================================================
  // P6 -- every CHI response is a legal opcode (DBIDResp for a write's data
  // grant, or Comp for a write completion). CompData rides the separate
  // chi_comp_data channel, so the RSP channel only ever carries DBIDResp/Comp.
  // ===========================================================================
  a_rsp_opcode_legal: assert property (
    @(posedge clk) disable iff (!rst_n)
      chi_rsp_valid |->
        (chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W] == CHI_RSP_DBIDRESP ||
         chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W] == CHI_RSP_COMP)
  ) else $error("[SVA] illegal CHI RSP opcode=%h",
                chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W]);

  // ===========================================================================
  // P7 -- SnpResp egress. The memory-only device answers every snoop with
  // SnpResp, final state Invalid; the response channel is a well-formed
  // valid/ready stream.
  // ===========================================================================
  a_snp_resp_stable: assert property (
    @(posedge clk) disable iff (!rst_n)
      (chi_snp_resp_valid && !chi_snp_resp_ready) |=>
        (chi_snp_resp_valid && $stable(chi_snp_resp_data))
  ) else $error("[SVA] chi_snp_resp flit changed/dropped while stalled");

  a_snp_resp_is_snpresp_i: assert property (
    @(posedge clk) disable iff (!rst_n)
      chi_snp_resp_valid |->
        (chi_snp_resp_data[CHI_SNPRSP_OPCODE_LSB +: CHI_SNPRSP_OPCODE_W] == CHI_RSP_SNPRESP &&
         chi_snp_resp_data[CHI_SNPRSP_RESP_LSB   +: CHI_SNPRSP_RESP_W]   == CHI_CACHE_I    &&
         chi_snp_resp_data[CHI_SNPRSP_RESPERR_LSB +: CHI_SNPRSP_RESPERR_W] == CHI_RESPERR_OK)
  ) else $error("[SVA] SnpResp not SnpResp_I/OK: op=%h resp=%h",
                chi_snp_resp_data[CHI_SNPRSP_OPCODE_LSB +: CHI_SNPRSP_OPCODE_W],
                chi_snp_resp_data[CHI_SNPRSP_RESP_LSB +: CHI_SNPRSP_RESP_W]);

endmodule : chi_to_cxl_sva
/* verilator lint_on SYNCASYNCNET */

// Bind one checker into every bridge instance, by explicit name to the bridge's
// own boundary ports -- no RTL hierarchy is reached into.
bind chi_to_cxl_bridge chi_to_cxl_sva u_sva (
  .clk(clk), .cxl_clk(cxl_clk), .rst_n(rst_n),
  .cxl_tx_req_valid(cxl_tx_req_valid), .cxl_tx_req_data(cxl_tx_req_data),
  .cxl_tx_req_ready(cxl_tx_req_ready),
  .cxl_tx_rwd_valid(cxl_tx_rwd_valid), .cxl_tx_rwd_data(cxl_tx_rwd_data),
  .cxl_tx_rwd_ready(cxl_tx_rwd_ready),
  .chi_rsp_valid(chi_rsp_valid), .chi_rsp_data(chi_rsp_data),
  .chi_rsp_ready(chi_rsp_ready),
  .chi_comp_data_valid(chi_comp_data_valid), .chi_comp_data(chi_comp_data),
  .chi_comp_data_ready(chi_comp_data_ready),
  .chi_snp_resp_valid(chi_snp_resp_valid), .chi_snp_resp_data(chi_snp_resp_data),
  .chi_snp_resp_ready(chi_snp_resp_ready)
);

`default_nettype wire
