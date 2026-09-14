// -----------------------------------------------------------------------------
// chi_to_cxl_if -- DUT boundary bundle for the chi_to_cxl_bridge SV env.
//
// Aligned with ../ucie2-pipe7-bridge/dv/uvm/sv/ucie2_pipe7_if.sv: carries the
// structured-flit CHI (clk) + CXL.mem (cxl_clk) channel set the pyuvm bench and
// the bound SVA observe. Inputs to the DUT are initialised to a defined idle so
// the bridge simulates deterministically from reset.
//
// Widths reference the packed-flit localparams in src/chi_to_cxl_bridge_defs.vh.
// -----------------------------------------------------------------------------
`include "chi_to_cxl_bridge_defs.vh"

interface chi_to_cxl_if (
  input logic clk,
  input logic cxl_clk,
  input logic rst_n
);
  // CHI -> CXL (clk domain in)
  logic [CHI_REQ_W-1:0] chi_req_data     = '0;
  logic                 chi_req_valid    = 1'b0;
  logic                 chi_req_ready;
  logic [CHI_DAT_W-1:0] chi_wr_data      = '0;
  logic                 chi_wr_data_valid = 1'b0;
  logic                 chi_wr_data_ready;

  // CXL M2S (cxl_clk domain out)
  logic                 cxl_tx_req_valid;
  logic [CXL_REQ_W-1:0] cxl_tx_req_data;
  logic                 cxl_tx_req_ready = 1'b0;
  logic                 cxl_tx_rwd_valid;
  logic [CXL_RWD_W-1:0] cxl_tx_rwd_data;
  logic                 cxl_tx_rwd_ready = 1'b0;

  // CXL S2M (cxl_clk domain in)
  logic                 cxl_rx_ndr_valid = 1'b0;
  logic [CXL_NDR_W-1:0] cxl_rx_ndr_data  = '0;
  logic                 cxl_rx_ndr_ready;
  logic                 cxl_rx_drs_valid = 1'b0;
  logic [CXL_DRS_W-1:0] cxl_rx_drs_data  = '0;
  logic                 cxl_rx_drs_ready;

  // CHI response / completion (clk domain out)
  logic                 chi_rsp_valid;
  logic [CHI_RSP_W-1:0] chi_rsp_data;
  logic                 chi_rsp_ready       = 1'b0;
  logic                 chi_comp_data_valid;
  logic [CHI_DAT_W-1:0] chi_comp_data;
  logic                 chi_comp_data_ready = 1'b0;

  // CHI SNP request in / SnpResp out (clk domain)
  logic                 chi_snp_valid       = 1'b0;
  logic [CHI_SNP_W-1:0] chi_snp_data        = '0;
  logic                 chi_snp_ready;
  logic                 chi_snp_resp_valid;
  logic [CHI_SNPRSP_W-1:0] chi_snp_resp_data;
  logic                 chi_snp_resp_ready  = 1'b0;

  // Link readiness / status
  logic                 link_up     = 1'b0;
  logic                 err_inj_en  = 1'b0;
  logic                 drain_done;
  logic [15:0]          crc_err_cnt;
  logic [15:0]          drain_cnt;
  logic [7:0]           max_occ_req;
  logic [7:0]           max_occ_rsp;
endinterface : chi_to_cxl_if
