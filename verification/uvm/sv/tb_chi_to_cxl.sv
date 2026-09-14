// -----------------------------------------------------------------------------
// tb_chi_to_cxl -- SV UVM top for chi_to_cxl_bridge (PLAN Phase 4).
//
// Generates the two clock domains, sequences reset + link-up, instantiates the
// DUT through the chi_to_cxl_if bundle, hands the vif to UVM, and runs the
// round-trip test. Coincident 2 ns clocks (both domains) keep the run
// deterministic, matching the PyUVM round-trip test.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_chi_to_cxl;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import chi_to_cxl_uvm_pkg::*;

  logic clk = 0, cxl_clk = 0, rst_n = 0, link_up = 0;

  // Non-coincident 2 ns / 3 ns domains (matches the PyUVM round-trip TB): the
  // real CDC needs distinct edges so the CXL-side responder has clean sampling
  // windows and never races the bridge's egress the way coincident edges do.
  always #1.0 clk     = ~clk;
  always #1.5 cxl_clk = ~cxl_clk;

  // Reset deasserts at 11 ns (a non-edge time); link comes up just after.
  initial begin
    rst_n = 0; link_up = 0;
    #11;
    rst_n = 1;
    #4;
    link_up = 1;
  end

  chi_to_cxl_if vif (.clk(clk), .cxl_clk(cxl_clk), .rst_n(rst_n));

  chi_to_cxl_bridge dut (
    .clk(clk), .cxl_clk(cxl_clk), .rst_n(rst_n),
    .chi_req_valid(vif.chi_req_valid), .chi_req_data(vif.chi_req_data),
    .chi_req_ready(vif.chi_req_ready),
    .chi_wr_data_valid(vif.chi_wr_data_valid), .chi_wr_data(vif.chi_wr_data),
    .chi_wr_data_ready(vif.chi_wr_data_ready),
    .cxl_tx_req_valid(vif.cxl_tx_req_valid), .cxl_tx_req_data(vif.cxl_tx_req_data),
    .cxl_tx_req_ready(vif.cxl_tx_req_ready),
    .cxl_tx_rwd_valid(vif.cxl_tx_rwd_valid), .cxl_tx_rwd_data(vif.cxl_tx_rwd_data),
    .cxl_tx_rwd_ready(vif.cxl_tx_rwd_ready),
    .cxl_rx_ndr_valid(vif.cxl_rx_ndr_valid), .cxl_rx_ndr_data(vif.cxl_rx_ndr_data),
    .cxl_rx_ndr_ready(vif.cxl_rx_ndr_ready),
    .cxl_rx_drs_valid(vif.cxl_rx_drs_valid), .cxl_rx_drs_data(vif.cxl_rx_drs_data),
    .cxl_rx_drs_ready(vif.cxl_rx_drs_ready),
    .chi_rsp_valid(vif.chi_rsp_valid), .chi_rsp_data(vif.chi_rsp_data),
    .chi_rsp_ready(vif.chi_rsp_ready),
    .chi_comp_data_valid(vif.chi_comp_data_valid), .chi_comp_data(vif.chi_comp_data),
    .chi_comp_data_ready(vif.chi_comp_data_ready),
    .chi_snp_valid(vif.chi_snp_valid), .chi_snp_data(vif.chi_snp_data),
    .chi_snp_ready(vif.chi_snp_ready),
    .chi_snp_resp_valid(vif.chi_snp_resp_valid), .chi_snp_resp_data(vif.chi_snp_resp_data),
    .chi_snp_resp_ready(vif.chi_snp_resp_ready),
    .link_up(link_up), .err_inj_en(vif.err_inj_en), .drain_done(vif.drain_done),
    .crc_err_cnt(vif.crc_err_cnt), .drain_cnt(vif.drain_cnt),
    .max_occ_req(vif.max_occ_req), .max_occ_rsp(vif.max_occ_rsp)
  );

  initial begin
    uvm_config_db#(virtual chi_to_cxl_if)::set(null, "*", "vif", vif);
    run_test("chi_roundtrip_test");
  end
endmodule : tb_chi_to_cxl
