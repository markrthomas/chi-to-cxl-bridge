`timescale 1ns / 1ps

`include "chi_to_cxl_bridge_defs.vh"

module tb_chi_to_cxl_bridge;

  localparam integer FIFO_DEPTH = 8;

  reg clk;
  reg cxl_clk;
  reg rst_n;

  real cxl_clk_half = 5.0;

  reg                  chi_req_valid;
  reg [CHI_REQ_W-1:0]  chi_req_data;
  wire                 chi_req_ready;

  reg                  chi_wr_data_valid;
  reg [CHI_DAT_W-1:0]  chi_wr_data;
  wire                 chi_wr_data_ready;

  wire                 cxl_tx_req_valid;
  wire [CXL_REQ_W-1:0] cxl_tx_req_data;
  reg                  cxl_tx_req_ready;

  wire                 cxl_tx_rwd_valid;
  wire [CXL_RWD_W-1:0] cxl_tx_rwd_data;
  reg                  cxl_tx_rwd_ready;

  reg                  cxl_rx_ndr_valid;
  reg [CXL_NDR_W-1:0]  cxl_rx_ndr_data;
  wire                 cxl_rx_ndr_ready;

  reg                  cxl_rx_drs_valid;
  reg [CXL_DRS_W-1:0]  cxl_rx_drs_data;
  wire                 cxl_rx_drs_ready;

  wire                 chi_rsp_valid;
  wire [CHI_RSP_W-1:0] chi_rsp_data;
  reg                  chi_rsp_ready;

  wire                 chi_comp_data_valid;
  wire [CHI_DAT_W-1:0] chi_comp_data;
  reg                  chi_comp_data_ready;

  reg         link_up;
  reg         err_inj_en;
  wire        drain_done;

  chi_to_cxl_bridge #(
    .FIFO_DEPTH (FIFO_DEPTH)
  ) dut (
    .clk(clk),
    .cxl_clk(cxl_clk),
    .rst_n(rst_n),
    .chi_req_valid(chi_req_valid),
    .chi_req_data(chi_req_data),
    .chi_req_ready(chi_req_ready),
    .chi_wr_data_valid(chi_wr_data_valid),
    .chi_wr_data(chi_wr_data),
    .chi_wr_data_ready(chi_wr_data_ready),
    .cxl_tx_req_valid(cxl_tx_req_valid),
    .cxl_tx_req_data(cxl_tx_req_data),
    .cxl_tx_req_ready(cxl_tx_req_ready),
    .cxl_tx_rwd_valid(cxl_tx_rwd_valid),
    .cxl_tx_rwd_data(cxl_tx_rwd_data),
    .cxl_tx_rwd_ready(cxl_tx_rwd_ready),
    .cxl_rx_ndr_valid(cxl_rx_ndr_valid),
    .cxl_rx_ndr_data(cxl_rx_ndr_data),
    .cxl_rx_ndr_ready(cxl_rx_ndr_ready),
    .cxl_rx_drs_valid(cxl_rx_drs_valid),
    .cxl_rx_drs_data(cxl_rx_drs_data),
    .cxl_rx_drs_ready(cxl_rx_drs_ready),
    .chi_rsp_valid(chi_rsp_valid),
    .chi_rsp_data(chi_rsp_data),
    .chi_rsp_ready(chi_rsp_ready),
    .chi_comp_data_valid(chi_comp_data_valid),
    .chi_comp_data(chi_comp_data),
    .chi_comp_data_ready(chi_comp_data_ready),
    .link_up(link_up),
    .err_inj_en(err_inj_en),
    .drain_done(drain_done),
    .crc_err_cnt(),
    .drain_cnt(),
    .max_occ_req(),
    .max_occ_rsp()
  );

  always #5 clk = ~clk;

  initial begin
    cxl_clk = 1'b0;
    #2.5;
    forever begin
      #(cxl_clk_half) cxl_clk = ~cxl_clk;
    end
  end

  task automatic do_reset;
    begin
      rst_n              = 1'b0;
      chi_req_valid      = 1'b0;
      chi_req_data       = {CHI_REQ_W{1'b0}};
      chi_wr_data_valid  = 1'b0;
      chi_wr_data        = {CHI_DAT_W{1'b0}};
      cxl_tx_req_ready   = 1'b0;
      cxl_tx_rwd_ready   = 1'b0;
      cxl_rx_ndr_valid   = 1'b0;
      cxl_rx_ndr_data    = {CXL_NDR_W{1'b0}};
      cxl_rx_drs_valid   = 1'b0;
      cxl_rx_drs_data    = {CXL_DRS_W{1'b0}};
      chi_rsp_ready      = 1'b0;
      chi_comp_data_ready = 1'b0;
      link_up            = 1'b0;
      err_inj_en         = 1'b0;
      repeat (6) @(posedge clk);
      rst_n   = 1'b1;
      link_up = 1'b1;
      repeat (4) @(posedge clk);
      repeat (4) @(posedge cxl_clk);
    end
  endtask

  initial begin
    clk                = 1'b0;
    cxl_clk            = 1'b0;
    cxl_clk_half       = 5.0;
    do_reset();

    $display("INFO: Starting Phase 3a REQ smoke test");
    @(posedge clk);
    chi_req_data = {CHI_REQ_W{1'b0}};
    chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = CHI_REQ_READNOSNP;
    chi_req_data[CHI_REQ_ADDR_LSB   +: CHI_REQ_ADDR_W]   = 48'hBEEF_CAFE_1234;
    chi_req_data[CHI_REQ_TXNID_LSB  +: CHI_REQ_TXNID_W]  = 8'h3C;
    chi_req_valid = 1'b1;
    cxl_tx_req_ready = 1'b1;

    @(posedge clk);
    while (!chi_req_ready) @(posedge clk);
    chi_req_valid = 1'b0;

    $display("INFO: REQ sent to bridge, waiting for CXL TX REQ");
    wait (cxl_tx_req_valid);
    $display("INFO: CXL TX REQ detected: opcode=%h addr=%h tag=%h",
             cxl_tx_req_data[CXL_REQ_MEMOP_LSB +: CXL_REQ_MEMOP_W],
             cxl_tx_req_data[CXL_REQ_ADDR_LSB  +: CXL_REQ_ADDR_W],
             cxl_tx_req_data[CXL_REQ_TAG_LSB   +: CXL_REQ_TAG_W]);

    if (cxl_tx_req_data[CXL_REQ_MEMOP_LSB +: CXL_REQ_MEMOP_W] !== CXL_MEMRD) begin
       $display("FAIL: expected CXL_MEMRD"); $finish(1);
    end
    if (cxl_tx_req_data[CXL_REQ_ADDR_LSB +: CXL_REQ_ADDR_W] !== 48'hBEEF_CAFE_1234) begin
       $display("FAIL: addr mismatch"); $finish(1);
    end

    $display("INFO: Starting Phase 3a WR smoke test");
    @(posedge clk);
    chi_req_data = {CHI_REQ_W{1'b0}};
    chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = CHI_REQ_WRITENOSNPFULL;
    chi_req_data[CHI_REQ_ADDR_LSB   +: CHI_REQ_ADDR_W]   = 48'hDEAD_BEEF_5678;
    chi_req_data[CHI_REQ_TXNID_LSB  +: CHI_REQ_TXNID_W]  = 8'hD2;
    chi_req_valid = 1'b1;

    chi_wr_data = {CHI_DAT_W{1'b0}};
    chi_wr_data[CHI_DAT_DATA_LSB +: CHI_DAT_DATA_W] = 512'h12345678_9ABCDEF0_FEDCBA98_76543210_11223344_55667788_99AABBCC_DDEEFF00;
    chi_wr_data[CHI_DAT_BE_LSB   +: CHI_DAT_BE_W]   = {BE_W{1'b1}}; // All bytes enabled
    chi_wr_data_valid = 1'b1;

    cxl_tx_rwd_ready = 1'b1;

    @(posedge clk);
    while (!chi_req_ready) @(posedge clk);
    chi_req_valid = 1'b0;
    chi_wr_data_valid = 1'b0;

    $display("INFO: WR sent to bridge, waiting for CXL TX RWD");
    wait (cxl_tx_rwd_valid);
    $display("INFO: CXL TX RWD detected: opcode=%h addr=%h data_lsb=%h",
             cxl_tx_rwd_data[CXL_RWD_MEMOP_LSB +: CXL_RWD_MEMOP_W],
             cxl_tx_rwd_data[CXL_RWD_ADDR_LSB  +: CXL_RWD_ADDR_W],
             cxl_tx_rwd_data[CXL_RWD_DATA_LSB  +: 64]); // Just print some data

    if (cxl_tx_rwd_data[CXL_RWD_MEMOP_LSB +: CXL_RWD_MEMOP_W] !== CXL_MEMWR) begin
       $display("FAIL: expected CXL_MEMWR"); $finish(1);
    end
    if (cxl_tx_rwd_data[CXL_RWD_ADDR_LSB +: CXL_RWD_ADDR_W] !== 48'hDEAD_BEEF_5678) begin
       $display("FAIL: addr mismatch"); $finish(1);
    end
    if (cxl_tx_rwd_data[CXL_RWD_DATA_LSB +: CHI_DAT_DATA_W] !== 512'h12345678_9ABCDEF0_FEDCBA98_76543210_11223344_55667788_99AABBCC_DDEEFF00) begin
       $display("FAIL: data mismatch"); $finish(1);
    end

    $display("INFO: Starting Phase 3a RSP smoke test");
    @(posedge clk);
    cxl_rx_ndr_data = {CXL_NDR_W{1'b0}};
    cxl_rx_ndr_data[CXL_NDR_OPCODE_LSB +: CXL_NDR_OPCODE_W] = CXL_NDR_CMP;
    cxl_rx_ndr_data[CXL_NDR_TAG_LSB    +: CXL_NDR_TAG_W]    = 4'hC;
    cxl_rx_ndr_valid = 1'b1;
    chi_rsp_ready    = 1'b1;

    @(posedge cxl_clk);
    while (!cxl_rx_ndr_ready) @(posedge cxl_clk);
    cxl_rx_ndr_valid = 1'b0;

    $display("INFO: NDR sent to bridge, waiting for CHI RSP");
    wait (chi_rsp_valid);
    $display("INFO: CHI RSP detected: opcode=%h dbid=%h",
             chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W],
             chi_rsp_data[CHI_RSP_DBID_LSB   +: CHI_RSP_DBID_W]);

    if (chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W] !== CHI_RSP_COMP) begin
       $display("FAIL: expected CHI_RSP_COMP"); $finish(1);
    end
    if (chi_rsp_data[CHI_RSP_DBID_LSB +: CHI_RSP_DBID_W] !== 4'hC) begin
       $display("FAIL: dbid mismatch"); $finish(1);
    end

    $display("INFO: Starting Phase 3a DRS smoke test");
    @(posedge clk);
    cxl_rx_drs_data = {CXL_DRS_W{1'b0}};
    cxl_rx_drs_data[CXL_DRS_OPCODE_LSB +: CXL_DRS_OPCODE_W] = CXL_DRS_MEMDATA;
    cxl_rx_drs_data[CXL_DRS_TAG_LSB    +: CXL_DRS_TAG_W]    = 4'hA;
    cxl_rx_drs_data[CXL_DRS_DATA_LSB   +: 64]               = 64'hFEED_FACE_CAFE_BABE;
    cxl_rx_drs_valid = 1'b1;
    chi_comp_data_ready = 1'b1;

    @(posedge cxl_clk);
    while (!cxl_rx_drs_ready) @(posedge cxl_clk);
    cxl_rx_drs_valid = 1'b0;

    $display("INFO: DRS sent to bridge, waiting for CHI COMP_DATA");
    wait (chi_comp_data_valid);
    $display("INFO: CHI COMP_DATA detected: opcode=%h txnid=%h data_lsb=%h",
             chi_comp_data[CHI_DAT_OPCODE_LSB +: CHI_DAT_OPCODE_W],
             chi_comp_data[CHI_DAT_TXNID_LSB  +: CHI_DAT_TXNID_W],
             chi_comp_data[CHI_DAT_DATA_LSB   +: 64]);

    if (chi_comp_data[CHI_DAT_OPCODE_LSB +: CHI_DAT_OPCODE_W] !== CHI_DAT_COMPDATA) begin
       $display("FAIL: expected CHI_DAT_COMPDATA"); $finish(1);
    end
    if (chi_comp_data[CHI_DAT_DATA_LSB +: 64] !== 64'hFEED_FACE_CAFE_BABE) begin
       $display("FAIL: data mismatch"); $finish(1);
    end

    $display("PASS Phase 3a bidirectional smoke tests");
    $finish(0);
  end

endmodule
