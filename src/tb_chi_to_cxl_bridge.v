`timescale 1ns / 1ps

// Directed + stress testbench for chi_to_cxl_bridge.
// Dual-clock (clk=CHI host, cxl_clk=CXL link); clock-ratio tests 1:1, 2:1, 1:3.
// Smoke tests cover every request/response kind, ordering (posted bypass),
// link-up gating, granular opcodes, error injection, then a randomized
// scoreboard-checked stress run.

`include "chi_to_cxl_bridge_defs.vh"

module tb_chi_to_cxl_bridge;

  localparam integer W                = 64;
  localparam integer FIFO_DEPTH       = 8;
  localparam integer NUM_CYCLES       = 4000;
  localparam integer NUM_STRESS_HEAVY = 12000;
  localparam integer GOLD_SZ          = 32768;

  reg clk;
  reg cxl_clk;
  reg rst_n;

  // cxl_clk half-period (ns): changed per clock-ratio test.
  real cxl_clk_half;

  reg         chi_req_valid;
  reg [W-1:0] chi_req_data;
  wire        chi_req_ready;
  wire        cxl_tx_valid;
  wire [W-1:0] cxl_tx_data;
  reg         cxl_tx_ready;

  reg         cxl_rx_valid;
  reg [W-1:0] cxl_rx_data;
  wire        cxl_rx_ready;
  wire        chi_rsp_valid;
  wire [W-1:0] chi_rsp_data;
  reg         chi_rsp_ready;

  reg         link_up;
  reg         err_inj_en;
  wire        drain_done;

  reg [31:0] seed;
  integer cyc;
  integer p1_req_sent, p1_rsp_sent;

  // req gold queues split by ordering class
  reg [W-1:0] gold_req_posted[GOLD_SZ];
  reg [W-1:0] gold_req_np[GOLD_SZ];
  integer     req_posted_gold_wr, req_posted_gold_rd;
  integer     req_np_gold_wr,     req_np_gold_rd;

  reg [W-1:0] pending_req_data[GOLD_SZ];
  reg         pending_req_posted[GOLD_SZ];
  integer     req_pending_wr, req_pending_rd;

  reg [W-1:0] gold_rsp[GOLD_SZ];
  integer     rsp_gold_wr, rsp_gold_rd;

  integer     req_sent, rsp_sent;
  integer     req_rcvd, rsp_rcvd;

  chi_to_cxl_bridge #(
    .WIDTH      (W),
    .FIFO_DEPTH (FIFO_DEPTH)
  ) dut (
    .clk(clk),
    .cxl_clk(cxl_clk),
    .rst_n(rst_n),
    .chi_req_valid(chi_req_valid),
    .chi_req_data(chi_req_data),
    .chi_req_ready(chi_req_ready),
    .cxl_tx_valid(cxl_tx_valid),
    .cxl_tx_data(cxl_tx_data),
    .cxl_tx_ready(cxl_tx_ready),
    .cxl_rx_valid(cxl_rx_valid),
    .cxl_rx_data(cxl_rx_data),
    .cxl_rx_ready(cxl_rx_ready),
    .chi_rsp_valid(chi_rsp_valid),
    .chi_rsp_data(chi_rsp_data),
    .chi_rsp_ready(chi_rsp_ready),
    .link_up(link_up),
    .err_inj_en(err_inj_en),
    .drain_done(drain_done),
    .crc_err_cnt(),
    .drain_cnt(),
    .max_occ_req(),
    .max_occ_rsp()
  );

  chi_to_cxl_bridge_chk #(.WIDTH(W)) u_chk (
    .clk(clk),
    .cxl_clk(cxl_clk),
    .rst_n(rst_n),
    .cxl_tx_valid(cxl_tx_valid),
    .cxl_tx_data(cxl_tx_data),
    .cxl_tx_ready(cxl_tx_ready),
    .chi_rsp_valid(chi_rsp_valid),
    .chi_rsp_data(chi_rsp_data),
    .chi_rsp_ready(chi_rsp_ready)
  );

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("build/waves.vcd");
      $dumpvars(0, tb_chi_to_cxl_bridge);
    end
  end

  // CHI host clock: 10 ns period (100 MHz)
  always #5 clk = ~clk;

  // CXL link clock: phase-shifted so it never fires on the same timestamp as
  // clk. Period controlled by cxl_clk_half (set before each ratio test).
  initial begin
    cxl_clk = 1'b0;
    #2.5;
    forever begin
      #(cxl_clk_half) cxl_clk = ~cxl_clk;
    end
  end

  task automatic do_reset;
    begin
      rst_n         = 1'b0;
      chi_req_valid = 1'b0;
      chi_req_data  = {W{1'b0}};
      cxl_tx_ready  = 1'b0;
      cxl_rx_valid  = 1'b0;
      cxl_rx_data   = {W{1'b0}};
      chi_rsp_ready = 1'b0;
      link_up       = 1'b0;
      err_inj_en    = 1'b0;
      req_pending_wr = 0;
      req_pending_rd = 0;
      repeat (6) @(posedge clk);
      rst_n   = 1'b1;
      link_up = 1'b1;
      repeat (4) @(posedge clk);
      repeat (4) @(posedge cxl_clk);
    end
  endtask

  function automatic [31:0] rnd32;
    input [31:0] s;
    reg [31:0] x;
    begin
      x     = s;
      x     = x ^ (x << 13);
      x     = x ^ (x >> 17);
      x     = x ^ (x << 5);
      rnd32 = x;
    end
  endfunction

  // Gold model: mirrors translate_chi_to_cxl in the bridge RTL.
  function automatic [63:0] expect_cxl_from_chi;
    input [63:0] chi_pkt;
    reg [63:0] raw_pkt;
    reg [7:0]  attr;
    reg [3:0]  cxl_op;
    begin
      attr = chi_pkt[PKT_AUX_MSB:PKT_AUX_LSB] ^ chi_pkt[PKT_MISC_MSB:PKT_MISC_LSB];
      case (chi_pkt[PKT_KIND_MSB:PKT_KIND_LSB])
        CHI_REQ_KIND_READ: begin
          cxl_op = (chi_pkt[PKT_CODE_MSB:PKT_CODE_LSB] == CHI_RD_OP_ONCE) ?
                   CXL_M2S_MEMRDS : CXL_M2S_MEMRD;
          raw_pkt = pack_cxl_m2s(cxl_op, chi_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
            chi_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], chi_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
            chi_pkt[PKT_ID_MSB:PKT_ID_LSB], attr, 8'h00);
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          expect_cxl_from_chi = raw_pkt;
        end
        CHI_REQ_KIND_WRITE: begin
          cxl_op = (chi_pkt[PKT_CODE_MSB:PKT_CODE_LSB] == CHI_WR_OP_PTL) ?
                   CXL_M2S_MEMWRPTL : CXL_M2S_MEMWR;
          raw_pkt = pack_cxl_m2s(cxl_op, chi_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
            chi_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], chi_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
            chi_pkt[PKT_ID_MSB:PKT_ID_LSB], attr, 8'h00);
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          expect_cxl_from_chi = raw_pkt;
        end
        CHI_REQ_KIND_ATOMIC: begin
          raw_pkt = pack_cxl_m2s(CXL_M2S_MEMINV, chi_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
            chi_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], chi_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
            chi_pkt[PKT_ID_MSB:PKT_ID_LSB], attr, 8'h00);
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          expect_cxl_from_chi = raw_pkt;
        end
        CHI_REQ_KIND_DATALESS: begin
          raw_pkt = pack_cxl_m2s(CXL_M2S_MEMINV, chi_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
            chi_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], chi_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
            chi_pkt[PKT_ID_MSB:PKT_ID_LSB], attr, 8'h00);
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          expect_cxl_from_chi = raw_pkt;
        end
        default: begin
          raw_pkt = {CXL_KIND_ERROR, 4'h0, chi_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
                     16'h0000, 8'h00, chi_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          expect_cxl_from_chi = raw_pkt;
        end
      endcase
    end
  endfunction

  // Gold model: mirrors translate_cxl_to_chi in the bridge RTL.
  function automatic [63:0] expect_chi_from_cxl;
    input [63:0] cxl_pkt;
    reg [63:0] chk_pkt;
    begin
      chk_pkt = cxl_pkt;
      chk_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = 8'h00;
      case (cxl_pkt[PKT_KIND_MSB:PKT_KIND_LSB])
        CXL_S2M_KIND_DRS:
          if (cxl_pkt[PKT_MISC_MSB:PKT_MISC_LSB] == bridge_checksum(chk_pkt))
            expect_chi_from_cxl = pack_chi_compdata(
              cxl_pkt[PKT_CODE_MSB:PKT_CODE_LSB], cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
              cxl_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], cxl_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
              cxl_pkt[PKT_ID_MSB:PKT_ID_LSB], cxl_pkt[PKT_AUX_MSB:PKT_AUX_LSB]);
          else
            expect_chi_from_cxl = {CHI_RSP_KIND_INVALID, 4'h0,
              cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB], 16'h0000, 8'h00,
              cxl_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
        CXL_S2M_KIND_NDR:
          if (cxl_pkt[PKT_MISC_MSB:PKT_MISC_LSB] == bridge_checksum(chk_pkt))
            expect_chi_from_cxl = pack_chi_comp(
              cxl_pkt[PKT_CODE_MSB:PKT_CODE_LSB], cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
              cxl_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], cxl_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
              cxl_pkt[PKT_ID_MSB:PKT_ID_LSB], cxl_pkt[PKT_AUX_MSB:PKT_AUX_LSB]);
          else
            expect_chi_from_cxl = {CHI_RSP_KIND_INVALID, 4'h0,
              cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB], 16'h0000, 8'h00,
              cxl_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
        CXL_S2M_KIND_DBID:
          if (cxl_pkt[PKT_MISC_MSB:PKT_MISC_LSB] == bridge_checksum(chk_pkt))
            expect_chi_from_cxl = pack_chi_dbidresp(
              cxl_pkt[PKT_CODE_MSB:PKT_CODE_LSB], cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
              cxl_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], cxl_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
              cxl_pkt[PKT_ID_MSB:PKT_ID_LSB], cxl_pkt[PKT_AUX_MSB:PKT_AUX_LSB]);
          else
            expect_chi_from_cxl = {CHI_RSP_KIND_INVALID, 4'h0,
              cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB], 16'h0000, 8'h00,
              cxl_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
        default:
          expect_chi_from_cxl = {CHI_RSP_KIND_INVALID, 4'h0,
            cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB], 16'h0000, 8'h00,
            cxl_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
      endcase
    end
  endfunction

  // Mirrors bridge RTL is_posted: true for WRITE kind only.
  function automatic is_posted_chi;
    input [63:0] pkt;
    begin
      case (pkt[PKT_KIND_MSB:PKT_KIND_LSB])
        CHI_REQ_KIND_WRITE: is_posted_chi = 1'b1;
        default:            is_posted_chi = 1'b0;
      endcase
    end
  endfunction

  // Determines if a CXL M2S flit came from the posted req FIFO.
  // MEMWR / MEMWRPTL (writes) can only originate from posted CHI requests.
  function automatic is_cxl_posted;
    input [63:0] pkt;
    begin
      case (pkt[PKT_CODE_MSB:PKT_CODE_LSB])
        CXL_M2S_MEMWR:    is_cxl_posted = 1'b1;
        CXL_M2S_MEMWRPTL: is_cxl_posted = 1'b1;
        default:          is_cxl_posted = 1'b0;
      endcase
    end
  endfunction

  task automatic scoreboard_step_clk;
    begin
      if (chi_req_valid && chi_req_ready) begin
        if (is_posted_chi(chi_req_data)) begin
          if (req_posted_gold_wr >= GOLD_SZ) begin
            $display("FAIL: gold_req_posted overflow"); $finish(1);
          end
          gold_req_posted[req_posted_gold_wr] = expect_cxl_from_chi(chi_req_data);
          req_posted_gold_wr = req_posted_gold_wr + 1;
        end else begin
          if (req_np_gold_wr >= GOLD_SZ) begin
            $display("FAIL: gold_req_np overflow"); $finish(1);
          end
          gold_req_np[req_np_gold_wr] = expect_cxl_from_chi(chi_req_data);
          req_np_gold_wr = req_np_gold_wr + 1;
        end
        req_sent = req_sent + 1;
      end

      if (chi_rsp_valid && chi_rsp_ready) begin
        if (rsp_gold_rd >= rsp_gold_wr) begin
          $display("FAIL: rsp pop underrun"); $finish(1);
        end
        if (chi_rsp_data !== gold_rsp[rsp_gold_rd]) begin
          $display("FAIL: rsp data mismatch exp=%h got=%h", gold_rsp[rsp_gold_rd], chi_rsp_data);
          $finish(1);
        end
        rsp_gold_rd = rsp_gold_rd + 1;
        rsp_rcvd    = rsp_rcvd + 1;
      end

      while (req_pending_rd < req_pending_wr) begin
        if (pending_req_posted[req_pending_rd]) begin
          if (req_posted_gold_rd >= req_posted_gold_wr) begin
            $display("FAIL: req posted pop underrun"); $finish(1);
          end
          if (pending_req_data[req_pending_rd] !== gold_req_posted[req_posted_gold_rd]) begin
            $display("FAIL: req posted mismatch exp=%h got=%h",
                     gold_req_posted[req_posted_gold_rd], pending_req_data[req_pending_rd]);
            $finish(1);
          end
          req_posted_gold_rd = req_posted_gold_rd + 1;
        end else begin
          if (req_np_gold_rd >= req_np_gold_wr) begin
            $display("FAIL: req np pop underrun"); $finish(1);
          end
          if (pending_req_data[req_pending_rd] !== gold_req_np[req_np_gold_rd]) begin
            $display("FAIL: req np mismatch exp=%h got=%h",
                     gold_req_np[req_np_gold_rd], pending_req_data[req_pending_rd]);
            $finish(1);
          end
          req_np_gold_rd = req_np_gold_rd + 1;
        end
        req_pending_rd = req_pending_rd + 1;
        req_rcvd       = req_rcvd + 1;
      end
    end
  endtask

  task automatic scoreboard_step_cxl;
    begin
      if (cxl_tx_valid && cxl_tx_ready) begin
        if (req_pending_wr >= GOLD_SZ) begin
          $display("FAIL: req pending overflow"); $finish(1);
        end
        pending_req_data[req_pending_wr]   = cxl_tx_data;
        pending_req_posted[req_pending_wr] = is_cxl_posted(cxl_tx_data);
        req_pending_wr = req_pending_wr + 1;
      end

      if (cxl_rx_valid && cxl_rx_ready) begin
        if (rsp_gold_wr >= GOLD_SZ) begin
          $display("FAIL: gold_rsp overflow"); $finish(1);
        end
        gold_rsp[rsp_gold_wr] = expect_chi_from_cxl(cxl_rx_data);
        rsp_gold_wr           = rsp_gold_wr + 1;
        rsp_sent              = rsp_sent + 1;
      end
    end
  endtask

  initial begin
    forever begin
      @(posedge cxl_clk);
      if (rst_n) scoreboard_step_cxl();
    end
  end

  initial begin
    clk                = 1'b0;
    cxl_clk            = 1'b0;
    cxl_clk_half       = 5.0;   // start 1:1 (both 10 ns)
    rst_n              = 1'b0;
    chi_req_valid      = 1'b0;
    chi_req_data       = {W{1'b0}};
    cxl_tx_ready       = 1'b0;
    cxl_rx_valid       = 1'b0;
    cxl_rx_data        = {W{1'b0}};
    chi_rsp_ready      = 1'b0;
    link_up            = 1'b0;
    err_inj_en         = 1'b0;
    seed               = 32'hACE15EED;
    req_posted_gold_wr = 0;
    req_posted_gold_rd = 0;
    req_np_gold_wr     = 0;
    req_np_gold_rd     = 0;
    req_pending_wr     = 0;
    req_pending_rd     = 0;
    rsp_gold_wr        = 0;
    rsp_gold_rd        = 0;
    req_sent           = 0;
    rsp_sent           = 0;
    req_rcvd           = 0;
    rsp_rcvd           = 0;

    // --- Clock ratio 1:1 ---
    $display("INFO: clock ratio 1:1  clk=100MHz cxl_clk=100MHz");
    cxl_clk_half = 5.0;
    do_reset();

    // --- Smoke 1: CHI read -> CXL MEMRD, then DRS -> CHI CompData ---
    @(posedge clk);
    chi_req_data  = pack_chi_read(CHI_RD_OP_NOSNP, 8'h3c, 16'hbeef, 8'h04, 8'ha1, 8'h0f);
    chi_req_valid = 1'b1;
    cxl_tx_ready  = 1'b1;
    @(posedge clk);
    while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
    chi_req_valid = 1'b0;

    wait (cxl_tx_valid);
    if (cxl_tx_data !== expect_cxl_from_chi(pack_chi_read(CHI_RD_OP_NOSNP, 8'h3c, 16'hbeef, 8'h04, 8'ha1, 8'h0f))) begin
      $display("FAIL: smoke chi_read cxl_tx_data got %h", cxl_tx_data);
      $finish(1);
    end
    @(posedge cxl_clk); #1;

    @(posedge clk);
    cxl_rx_data   = pack_cxl_drs(CXL_RSP_OK, 8'h3c, 16'h0040, 8'h04, 8'hc3, 8'h18, 8'h00);
    cxl_rx_data[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(cxl_rx_data);
    cxl_rx_valid  = 1'b1;
    chi_rsp_ready = 1'b1;
    @(posedge clk);
    while (!(cxl_rx_valid && cxl_rx_ready)) @(posedge clk);
    cxl_rx_valid = 1'b0;

    wait (chi_rsp_valid);
    @(posedge clk);
    if (chi_rsp_data !== expect_chi_from_cxl(cxl_rx_data)) begin
      $display("FAIL: smoke drs chi_rsp_data got %h", chi_rsp_data);
      $finish(1);
    end

    // --- Smoke 2: all request/response kinds ---
    begin : blk_smoke_new_kinds
      reg [W-1:0] rpkt;

      // CHI write (posted) -> CXL MEMWR
      @(posedge clk);
      chi_req_data  = pack_chi_write(CHI_WR_OP_NOSNP, 8'h22, 16'h4000, 8'h04, 8'he5, 8'ha3);
      chi_req_valid = 1'b1; cxl_tx_ready = 1'b1;
      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;
      wait (cxl_tx_valid);
      if (cxl_tx_data !== expect_cxl_from_chi(pack_chi_write(CHI_WR_OP_NOSNP, 8'h22, 16'h4000, 8'h04, 8'he5, 8'ha3))) begin
        $display("FAIL: smoke chi_write got %h", cxl_tx_data); $finish(1);
      end
      @(posedge cxl_clk); #1;

      // CHI atomic (non-posted) -> CXL MEMINV
      @(posedge clk);
      chi_req_data  = pack_chi_atomic(4'h0, 8'h33, 16'h0008, 8'h01, 8'hf6, 8'h77);
      chi_req_valid = 1'b1;
      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;
      wait (cxl_tx_valid);
      if (cxl_tx_data !== expect_cxl_from_chi(pack_chi_atomic(4'h0, 8'h33, 16'h0008, 8'h01, 8'hf6, 8'h77))) begin
        $display("FAIL: smoke atomic got %h", cxl_tx_data); $finish(1);
      end
      @(posedge cxl_clk); #1;

      // CHI dataless (non-posted) -> CXL MEMINV
      @(posedge clk);
      chi_req_data  = pack_chi_dataless(4'h0, 8'h44, 16'h000c, 8'h01, 8'ha7, 8'h5b);
      chi_req_valid = 1'b1;
      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;
      wait (cxl_tx_valid);
      if (cxl_tx_data !== expect_cxl_from_chi(pack_chi_dataless(4'h0, 8'h44, 16'h000c, 8'h01, 8'ha7, 8'h5b))) begin
        $display("FAIL: smoke dataless got %h", cxl_tx_data); $finish(1);
      end
      @(posedge cxl_clk); #1;

      // CXL NDR -> CHI Comp
      rpkt = pack_cxl_ndr(CXL_RSP_OK, 8'h22, 16'h0040, 8'h04, 8'he5, 8'ha3, 8'h00);
      rpkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(rpkt);
      @(posedge clk);
      cxl_rx_data = rpkt; cxl_rx_valid = 1'b1; chi_rsp_ready = 1'b1;
      @(posedge clk); while (!(cxl_rx_valid && cxl_rx_ready)) @(posedge clk);
      cxl_rx_valid = 1'b0;
      wait (chi_rsp_valid); @(posedge clk);
      if (chi_rsp_data !== expect_chi_from_cxl(rpkt)) begin
        $display("FAIL: smoke ndr got %h", chi_rsp_data); $finish(1);
      end

      // CXL DBID -> CHI DBIDResp
      rpkt = pack_cxl_dbid(CXL_RSP_OK, 8'h33, 16'h0001, 8'h01, 8'hf6, 8'h77, 8'h00);
      rpkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(rpkt);
      @(posedge clk);
      cxl_rx_data = rpkt; cxl_rx_valid = 1'b1;
      @(posedge clk); while (!(cxl_rx_valid && cxl_rx_ready)) @(posedge clk);
      cxl_rx_valid = 1'b0;
      wait (chi_rsp_valid); @(posedge clk);
      if (chi_rsp_data !== expect_chi_from_cxl(rpkt)) begin
        $display("FAIL: smoke dbid got %h", chi_rsp_data); $finish(1);
      end

      // CXL DRS with ERR status -> CHI CompData (DERR-equivalent)
      rpkt = pack_cxl_drs(CXL_RSP_ERR, 8'h5a, 16'h0040, 8'h04, 8'hc3, 8'h18, 8'h00);
      rpkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(rpkt);
      @(posedge clk);
      cxl_rx_data = rpkt; cxl_rx_valid = 1'b1;
      @(posedge clk); while (!(cxl_rx_valid && cxl_rx_ready)) @(posedge clk);
      cxl_rx_valid = 1'b0;
      wait (chi_rsp_valid); @(posedge clk);
      if (chi_rsp_data !== expect_chi_from_cxl(rpkt)) begin
        $display("FAIL: smoke drs_err got %h", chi_rsp_data); $finish(1);
      end

      // CXL DRS with CORRUPT checksum -> CHI INVALID
      rpkt = pack_cxl_drs(CXL_RSP_OK, 8'h77, 16'h0040, 8'h04, 8'hc3, 8'h18, 8'h00);
      rpkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(rpkt) ^ 8'hFF;  // bad CRC
      @(posedge clk);
      cxl_rx_data = rpkt; cxl_rx_valid = 1'b1;
      @(posedge clk); while (!(cxl_rx_valid && cxl_rx_ready)) @(posedge clk);
      cxl_rx_valid = 1'b0;
      wait (chi_rsp_valid); @(posedge clk);
      if (chi_rsp_data !== expect_chi_from_cxl(rpkt)) begin
        $display("FAIL: smoke bad_crc got %h (want INVALID)", chi_rsp_data); $finish(1);
      end
      if (chi_rsp_data[PKT_KIND_MSB:PKT_KIND_LSB] !== CHI_RSP_KIND_INVALID) begin
        $display("FAIL: bad_crc did not map to INVALID got %h", chi_rsp_data); $finish(1);
      end
    end

    // --- Smoke 3: ordering — posted (writes) bypass non-posted (reads) ---
    begin : blk_ordering
      reg [W-1:0] exp_posted0, exp_posted1, exp_np0, exp_np1;

      cxl_tx_ready = 1'b0;

      // posted packet 0: WRITE
      @(posedge clk);
      chi_req_data  = pack_chi_write(CHI_WR_OP_NOSNP, 8'hB1, 16'h3000, 8'h04, 8'h30, 8'h00);
      exp_posted0   = expect_cxl_from_chi(chi_req_data);
      chi_req_valid = 1'b1;
      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;

      // posted packet 1: WRITE partial
      @(posedge clk);
      chi_req_data  = pack_chi_write(CHI_WR_OP_PTL, 8'hB2, 16'h0004, 8'h01, 8'h40, 8'h00);
      exp_posted1   = expect_cxl_from_chi(chi_req_data);
      chi_req_valid = 1'b1;
      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;

      // NP packet 0: READ (arrives after posted; arbiter already locked to posted)
      @(posedge clk);
      chi_req_data  = pack_chi_read(CHI_RD_OP_NOSNP, 8'hA1, 16'h1000, 8'h04, 8'h10, 8'h00);
      exp_np0       = expect_cxl_from_chi(chi_req_data);
      chi_req_valid = 1'b1;
      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;

      // NP packet 1: ATOMIC
      @(posedge clk);
      chi_req_data  = pack_chi_atomic(4'h0, 8'hA2, 16'h0002, 8'h01, 8'h20, 8'h00);
      exp_np1       = expect_cxl_from_chi(chi_req_data);
      chi_req_valid = 1'b1;
      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;

      // Release sink — posted FIFO has priority so posted drains first.
      @(posedge clk);
      cxl_tx_ready = 1'b1;

      wait (cxl_tx_valid);
      if (cxl_tx_data !== exp_posted0) begin
        $display("FAIL: ordering[0] want posted WR=%h got=%h", exp_posted0, cxl_tx_data); $finish(1);
      end
      @(posedge cxl_clk); #1;

      wait (cxl_tx_valid);
      if (cxl_tx_data !== exp_posted1) begin
        $display("FAIL: ordering[1] want posted WRPTL=%h got=%h", exp_posted1, cxl_tx_data); $finish(1);
      end
      @(posedge cxl_clk); #1;

      wait (cxl_tx_valid);
      if (cxl_tx_data !== exp_np0) begin
        $display("FAIL: ordering[2] want np RD=%h got=%h", exp_np0, cxl_tx_data); $finish(1);
      end
      @(posedge cxl_clk); #1;

      wait (cxl_tx_valid);
      if (cxl_tx_data !== exp_np1) begin
        $display("FAIL: ordering[3] want np ATOMIC=%h got=%h", exp_np1, cxl_tx_data); $finish(1);
      end
      @(posedge cxl_clk); #1;
    end

    // --- Smoke 4: link_up gating ---
    begin : blk_link_up
      @(posedge clk);
      link_up = 1'b0;
      repeat (4) @(posedge clk);

      chi_req_valid = 1'b1;
      chi_req_data  = pack_chi_read(CHI_RD_OP_NOSNP, 8'hdd, 16'h5000, 8'h04, 8'h50, 8'h00);
      if (chi_req_ready !== 1'b0) begin
        $display("FAIL: link_up_gate: chi_req_ready must be 0 when bridge is closed"); $finish(1);
      end
      chi_req_valid = 1'b0;

      @(posedge clk);
      if (!drain_done) begin
        $display("FAIL: link_up_gate: drain_done not asserted after FIFOs empty"); $finish(1);
      end

      link_up = 1'b1;
      repeat (4) @(posedge clk);
      $display("PASS smoke link_up_gating");
    end

    // --- Smoke 4.5: granular opcodes (MEMRDS / MEMWRPTL) ---
    begin : blk_granular_ops
      reg [W-1:0] test_pkt;
      reg [W-1:0] exp_pkt;

      // ReadOnce -> MEMRDS (snooped/shared read)
      @(posedge clk);
      test_pkt = pack_chi_read(CHI_RD_OP_ONCE, 8'hD1, 16'h7000, 8'h04, 8'h71, 8'h00);
      exp_pkt  = expect_cxl_from_chi(test_pkt);
      chi_req_data = test_pkt; chi_req_valid = 1'b1; cxl_tx_ready = 1'b1;
      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;
      wait (cxl_tx_valid);
      if (cxl_tx_data !== exp_pkt) begin
        $display("FAIL: granular MEMRDS exp=%h got=%h", exp_pkt, cxl_tx_data); $finish(1);
      end
      @(posedge cxl_clk); #1;

      // WriteUnique -> MEMWR
      @(posedge clk);
      test_pkt = pack_chi_write(CHI_WR_OP_UNIQUE, 8'hD2, 16'h8000, 8'h04, 8'h72, 8'h00);
      exp_pkt  = expect_cxl_from_chi(test_pkt);
      chi_req_data = test_pkt; chi_req_valid = 1'b1;
      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;
      wait (cxl_tx_valid);
      if (cxl_tx_data !== exp_pkt) begin
        $display("FAIL: granular MEMWR(unique) exp=%h got=%h", exp_pkt, cxl_tx_data); $finish(1);
      end
      @(posedge cxl_clk); #1;

      // WriteNoSnpPtl -> MEMWRPTL
      @(posedge clk);
      test_pkt = pack_chi_write(CHI_WR_OP_PTL, 8'hD3, 16'h9000, 8'h04, 8'h73, 8'h00);
      exp_pkt  = expect_cxl_from_chi(test_pkt);
      chi_req_data = test_pkt; chi_req_valid = 1'b1;
      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;
      wait (cxl_tx_valid);
      if (cxl_tx_data !== exp_pkt) begin
        $display("FAIL: granular MEMWRPTL exp=%h got=%h", exp_pkt, cxl_tx_data); $finish(1);
      end
      @(posedge cxl_clk); #1;

      $display("PASS smoke granular_opcodes");
    end

    // --- Smoke 5: error injection (link-channel bit flip) ---
    begin : blk_err_inj
      reg [W-1:0] inj_pkt;
      reg [W-1:0] expected_clean;

      inj_pkt        = pack_chi_read(CHI_RD_OP_NOSNP, 8'hee, 16'h6000, 8'h04, 8'h60, 8'h00);
      expected_clean = expect_cxl_from_chi(inj_pkt);

      @(posedge clk);
      err_inj_en    = 1'b1;
      repeat (4) @(posedge clk);
      chi_req_data  = inj_pkt;
      chi_req_valid = 1'b1;
      cxl_tx_ready  = 1'b1;

      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;
      err_inj_en    = 1'b0;

      wait (cxl_tx_valid);
      if (cxl_tx_data !== {expected_clean[W-1:1], ~expected_clean[0]}) begin
        $display("FAIL: err_inj: expected checksum bit 0 flipped exp=%h got=%h",
                 {expected_clean[W-1:1], ~expected_clean[0]}, cxl_tx_data);
        $finish(1);
      end
      $display("PASS smoke error_injection");
    end

    // --- Smoke 6: clock ratio 2:1 (cxl_clk faster: 200 MHz) ---
    begin : blk_ratio_2_1
      $display("INFO: clock ratio 2:1  clk=100MHz cxl_clk=200MHz");
      cxl_clk_half = 2.5;
      do_reset();
      req_posted_gold_wr = 0; req_posted_gold_rd = 0;
      req_np_gold_wr     = 0; req_np_gold_rd     = 0;
      rsp_gold_wr        = 0; rsp_gold_rd        = 0;

      @(posedge clk);
      chi_req_data  = pack_chi_read(CHI_RD_OP_ONCE, 8'hA0, 16'h1234, 8'h04, 8'h10, 8'h00);
      chi_req_valid = 1'b1; cxl_tx_ready = 1'b1;
      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;
      wait (cxl_tx_valid); @(posedge cxl_clk);
      if (cxl_tx_data !== expect_cxl_from_chi(pack_chi_read(CHI_RD_OP_ONCE, 8'hA0, 16'h1234, 8'h04, 8'h10, 8'h00))) begin
        $display("FAIL: ratio_2_1 req got=%h", cxl_tx_data); $finish(1);
      end

      begin : b21_rsp
        reg [W-1:0] rpkt;
        rpkt = pack_cxl_drs(CXL_RSP_OK, 8'hA0, 16'h0400, 8'h04, 8'h10, 8'hf5, 8'h00);
        rpkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(rpkt);
        @(posedge cxl_clk);
        cxl_rx_data = rpkt; cxl_rx_valid = 1'b1; chi_rsp_ready = 1'b1;
        @(posedge cxl_clk); while (!(cxl_rx_valid && cxl_rx_ready)) @(posedge cxl_clk);
        cxl_rx_valid = 1'b0;
        wait (chi_rsp_valid); @(posedge clk);
        if (chi_rsp_data !== expect_chi_from_cxl(rpkt)) begin
          $display("FAIL: ratio_2_1 rsp got=%h", chi_rsp_data); $finish(1);
        end
      end
      $display("PASS smoke ratio_2_1");
    end

    // --- Smoke 7: clock ratio 1:3 (cxl_clk slower: ~67 MHz) ---
    begin : blk_ratio_1_3
      $display("INFO: clock ratio 1:3  clk=100MHz cxl_clk=~67MHz");
      cxl_clk_half = 7.5;
      do_reset();
      req_posted_gold_wr = 0; req_posted_gold_rd = 0;
      req_np_gold_wr     = 0; req_np_gold_rd     = 0;
      rsp_gold_wr        = 0; rsp_gold_rd        = 0;

      @(posedge clk);
      chi_req_data  = pack_chi_write(CHI_WR_OP_NOSNP, 8'hB0, 16'h5678, 8'h02, 8'h20, 8'h00);
      chi_req_valid = 1'b1; cxl_tx_ready = 1'b1;
      @(posedge clk); while (!(chi_req_valid && chi_req_ready)) @(posedge clk);
      chi_req_valid = 1'b0;
      wait (cxl_tx_valid); @(posedge cxl_clk);
      if (cxl_tx_data !== expect_cxl_from_chi(pack_chi_write(CHI_WR_OP_NOSNP, 8'hB0, 16'h5678, 8'h02, 8'h20, 8'h00))) begin
        $display("FAIL: ratio_1_3 req got=%h", cxl_tx_data); $finish(1);
      end

      begin : b13_rsp
        reg [W-1:0] rpkt;
        rpkt = pack_cxl_ndr(CXL_RSP_OK, 8'hB0, 16'h0200, 8'h02, 8'h20, 8'h18, 8'h00);
        rpkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(rpkt);
        @(posedge cxl_clk);
        cxl_rx_data = rpkt; cxl_rx_valid = 1'b1; chi_rsp_ready = 1'b1;
        @(posedge cxl_clk); while (!(cxl_rx_valid && cxl_rx_ready)) @(posedge cxl_clk);
        cxl_rx_valid = 1'b0;
        wait (chi_rsp_valid); @(posedge clk);
        if (chi_rsp_data !== expect_chi_from_cxl(rpkt)) begin
          $display("FAIL: ratio_1_3 rsp got=%h", chi_rsp_data); $finish(1);
        end
      end
      $display("PASS smoke ratio_1_3");
    end

    // Reset back to 1:1 for the stress run
    $display("INFO: returning to clock ratio 1:1 for stress");
    cxl_clk_half = 5.0;
    do_reset();
    req_posted_gold_wr = 0; req_posted_gold_rd = 0;
    req_np_gold_wr     = 0; req_np_gold_rd     = 0;
    rsp_gold_wr        = 0; rsp_gold_rd        = 0;

    // --- Stress: concurrent traffic + random ready ---
    req_sent = 0; rsp_sent = 0; req_rcvd = 0; rsp_rcvd = 0;

    for (cyc = 0; cyc < NUM_CYCLES; cyc = cyc + 1) begin
      @(posedge clk);
      scoreboard_step_clk();

      seed         = rnd32(seed);
      cxl_tx_ready <= (seed % 5) != 0;
      seed         = rnd32(seed);
      chi_rsp_ready <= (seed % 5) != 0;

      // CHI -> CXL source: all request kinds
      if (chi_req_valid && chi_req_ready) begin
        seed = rnd32(seed);
        if ((seed % 4) == 0)
          chi_req_valid <= 1'b0;
        else begin
          chi_req_valid <= 1'b1;
          chi_req_data  <= chi_req_data + 64'h00000000_00001001;
        end
      end else if (!chi_req_valid) begin
        seed = rnd32(seed);
        if ((seed % 3) != 0) begin
          chi_req_valid <= 1'b1;
          case (seed[20:18] % 4)
            3'd0: chi_req_data <= pack_chi_read(seed[4], seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
            3'd1: chi_req_data <= pack_chi_write(seed[5:4], seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
            3'd2: chi_req_data <= pack_chi_atomic(4'h0, seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
            default: chi_req_data <= pack_chi_dataless(4'h0, seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
          endcase
        end
      end

      // CXL -> CHI source: all response kinds
      if (cxl_rx_valid && cxl_rx_ready) begin
        seed = rnd32(seed);
        if ((seed % 5) == 0)
          cxl_rx_valid <= 1'b0;
        else begin
          cxl_rx_valid <= 1'b1;
          cxl_rx_data  <= cxl_rx_data ^ 64'h10000000_00000001;
        end
      end else if (!cxl_rx_valid) begin
        seed = rnd32(seed);
        if ((seed % 4) != 0) begin
          cxl_rx_valid <= 1'b1;
          case (seed[19:18] % 3)
            2'd0: begin
              cxl_rx_data <= pack_cxl_drs(seed[16] ? CXL_RSP_OK : CXL_RSP_ERR,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00);
              cxl_rx_data[PKT_MISC_MSB:PKT_MISC_LSB] <= bridge_checksum(
                pack_cxl_drs(seed[16] ? CXL_RSP_OK : CXL_RSP_ERR,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00));
            end
            2'd1: begin
              cxl_rx_data <= pack_cxl_ndr(seed[16] ? CXL_RSP_OK : CXL_RSP_ERR,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00);
              cxl_rx_data[PKT_MISC_MSB:PKT_MISC_LSB] <= bridge_checksum(
                pack_cxl_ndr(seed[16] ? CXL_RSP_OK : CXL_RSP_ERR,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00));
            end
            default: begin
              cxl_rx_data <= pack_cxl_dbid(seed[16] ? CXL_RSP_ERR : CXL_RSP_OK,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00);
              cxl_rx_data[PKT_MISC_MSB:PKT_MISC_LSB] <= bridge_checksum(
                pack_cxl_dbid(seed[16] ? CXL_RSP_ERR : CXL_RSP_OK,
                              seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                              seed[23:16], seed[7:0], 8'h00));
            end
          endcase
        end
      end
    end

    // Drain
    @(posedge clk);
    scoreboard_step_clk();

    chi_req_valid <= 1'b0;
    cxl_rx_valid  <= 1'b0;
    cxl_tx_ready  <= 1'b1;
    chi_rsp_ready <= 1'b1;

    repeat (FIFO_DEPTH + 64) begin
      @(posedge clk);
      if (chi_rsp_valid && chi_rsp_ready) begin
        if (rsp_gold_rd >= rsp_gold_wr) begin
          $display("FAIL: drain rsp underrun"); $finish(1);
        end
        if (chi_rsp_data !== gold_rsp[rsp_gold_rd]) begin
          $display("FAIL: drain rsp mismatch exp=%h got=%h", gold_rsp[rsp_gold_rd], chi_rsp_data);
          $finish(1);
        end
        rsp_gold_rd = rsp_gold_rd + 1;
        rsp_rcvd    = rsp_rcvd + 1;
      end
    end

    repeat (8) begin
      @(posedge clk);
      scoreboard_step_clk();
    end

    if (req_posted_gold_rd !== req_posted_gold_wr) begin
      $display("FAIL: req posted gold not empty wr=%0d rd=%0d", req_posted_gold_wr, req_posted_gold_rd); $finish(1);
    end
    if (req_np_gold_rd !== req_np_gold_wr) begin
      $display("FAIL: req np gold not empty wr=%0d rd=%0d", req_np_gold_wr, req_np_gold_rd); $finish(1);
    end
    if (req_pending_rd !== req_pending_wr) begin
      $display("FAIL: req pending not empty wr=%0d rd=%0d", req_pending_wr, req_pending_rd); $finish(1);
    end
    if (rsp_gold_rd !== rsp_gold_wr) begin
      $display("FAIL: rsp gold not empty wr=%0d rd=%0d", rsp_gold_wr, rsp_gold_rd); $finish(1);
    end
    if (cxl_tx_valid) begin
      $display("FAIL: cxl_tx still valid after drain"); $finish(1);
    end
    if (chi_rsp_valid) begin
      $display("FAIL: chi_rsp still valid after drain"); $finish(1);
    end
    if (req_sent !== req_rcvd) begin
      $display("FAIL: req sent=%0d rcvd=%0d", req_sent, req_rcvd); $finish(1);
    end
    if (rsp_sent !== rsp_rcvd) begin
      $display("FAIL: rsp sent=%0d rcvd=%0d", rsp_sent, rsp_rcvd); $finish(1);
    end

    p1_req_sent = req_sent;
    p1_rsp_sent = rsp_sent;
    $display("PASS stress req_beats=%0d rsp_beats=%0d", p1_req_sent, p1_rsp_sent);

    if (!$test$plusargs("stress"))
      $finish(0);

    // --- Heavy stress: longer run, sinks ready ~20% ---
    req_sent = 0; rsp_sent = 0; req_rcvd = 0; rsp_rcvd = 0;
    seed     = 32'hC0FFEE01;

    for (cyc = 0; cyc < NUM_STRESS_HEAVY; cyc = cyc + 1) begin
      @(posedge clk);
      scoreboard_step_clk();

      seed         = rnd32(seed);
      cxl_tx_ready <= (seed % 10) < 2;
      seed         = rnd32(seed);
      chi_rsp_ready <= (seed % 10) < 2;

      if (chi_req_valid && chi_req_ready) begin
        seed = rnd32(seed);
        if ((seed % 4) == 0)
          chi_req_valid <= 1'b0;
        else begin
          chi_req_valid <= 1'b1;
          chi_req_data  <= chi_req_data + 64'h00000000_00001001;
        end
      end else if (!chi_req_valid) begin
        seed = rnd32(seed);
        if ((seed % 3) != 0) begin
          chi_req_valid <= 1'b1;
          case (seed[20:18] % 4)
            3'd0: chi_req_data <= pack_chi_write(seed[5:4], seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
            3'd1: chi_req_data <= pack_chi_dataless(4'h0, seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
            3'd2: chi_req_data <= pack_chi_read(seed[4], seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
            default: chi_req_data <= pack_chi_atomic(4'h0, seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
          endcase
        end
      end

      if (cxl_rx_valid && cxl_rx_ready) begin
        seed = rnd32(seed);
        if ((seed % 5) == 0)
          cxl_rx_valid <= 1'b0;
        else begin
          cxl_rx_valid <= 1'b1;
          cxl_rx_data  <= cxl_rx_data ^ 64'h10000000_00000001;
        end
      end else if (!cxl_rx_valid) begin
        seed = rnd32(seed);
        if ((seed % 4) != 0) begin
          cxl_rx_valid <= 1'b1;
          case (seed[19:18] % 3)
            2'd0: begin
              cxl_rx_data <= pack_cxl_drs(seed[16] ? CXL_RSP_OK : CXL_RSP_ERR,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00);
              cxl_rx_data[PKT_MISC_MSB:PKT_MISC_LSB] <= bridge_checksum(
                pack_cxl_drs(seed[16] ? CXL_RSP_OK : CXL_RSP_ERR,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00));
            end
            2'd1: begin
              cxl_rx_data <= pack_cxl_ndr(seed[16] ? CXL_RSP_OK : CXL_RSP_ERR,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00);
              cxl_rx_data[PKT_MISC_MSB:PKT_MISC_LSB] <= bridge_checksum(
                pack_cxl_ndr(seed[16] ? CXL_RSP_OK : CXL_RSP_ERR,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00));
            end
            default: begin
              cxl_rx_data <= pack_cxl_dbid(seed[16] ? CXL_RSP_ERR : CXL_RSP_OK,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00);
              cxl_rx_data[PKT_MISC_MSB:PKT_MISC_LSB] <= bridge_checksum(
                pack_cxl_dbid(seed[16] ? CXL_RSP_ERR : CXL_RSP_OK,
                              seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                              seed[23:16], seed[7:0], 8'h00));
            end
          endcase
        end
      end
    end

    @(posedge clk);
    scoreboard_step_clk();

    chi_req_valid <= 1'b0;
    cxl_rx_valid  <= 1'b0;
    cxl_tx_ready  <= 1'b1;
    chi_rsp_ready <= 1'b1;

    repeat (FIFO_DEPTH + 128) begin
      @(posedge clk);
      if (chi_rsp_valid && chi_rsp_ready) begin
        if (rsp_gold_rd >= rsp_gold_wr) begin
          $display("FAIL: heavy drain rsp underrun"); $finish(1);
        end
        if (chi_rsp_data !== gold_rsp[rsp_gold_rd]) begin
          $display("FAIL: heavy drain rsp mismatch exp=%h got=%h", gold_rsp[rsp_gold_rd], chi_rsp_data);
          $finish(1);
        end
        rsp_gold_rd = rsp_gold_rd + 1;
        rsp_rcvd    = rsp_rcvd + 1;
      end
    end

    repeat (8) begin
      @(posedge clk);
      scoreboard_step_clk();
    end

    if (req_posted_gold_rd !== req_posted_gold_wr) begin
      $display("FAIL: heavy req posted gold not empty wr=%0d rd=%0d", req_posted_gold_wr, req_posted_gold_rd); $finish(1);
    end
    if (req_np_gold_rd !== req_np_gold_wr) begin
      $display("FAIL: heavy req np gold not empty wr=%0d rd=%0d", req_np_gold_wr, req_np_gold_rd); $finish(1);
    end
    if (req_pending_rd !== req_pending_wr) begin
      $display("FAIL: heavy req pending not empty wr=%0d rd=%0d", req_pending_wr, req_pending_rd); $finish(1);
    end
    if (rsp_gold_rd !== rsp_gold_wr) begin
      $display("FAIL: heavy rsp gold not empty wr=%0d rd=%0d", rsp_gold_wr, rsp_gold_rd); $finish(1);
    end
    if (cxl_tx_valid) begin
      $display("FAIL: heavy cxl_tx still valid after drain"); $finish(1);
    end
    if (chi_rsp_valid) begin
      $display("FAIL: heavy chi_rsp still valid after drain"); $finish(1);
    end
    if (req_sent !== req_rcvd) begin
      $display("FAIL: heavy req sent=%0d rcvd=%0d", req_sent, req_rcvd); $finish(1);
    end
    if (rsp_sent !== rsp_rcvd) begin
      $display("FAIL: heavy rsp sent=%0d rcvd=%0d", rsp_sent, rsp_rcvd); $finish(1);
    end

    $display("PASS stress_heavy req_beats=%0d rsp_beats=%0d (after default stress %0d/%0d)",
             req_sent, rsp_sent, p1_req_sent, p1_rsp_sent);
    $finish(0);
  end

endmodule
