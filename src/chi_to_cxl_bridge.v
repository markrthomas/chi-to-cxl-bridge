// CHI <-> CXL bridge (digital-only RTL).
//
// Upstream (host) side runs on `clk` (an AMBA CHI request/response interface);
// the downstream CXL.mem link runs on `cxl_clk`.  The two domains are decoupled
// by dual-clock async FIFOs.
//
// Phase 3a: Structured flits (REQ, RwD, NDR, DRS) with 512-bit data beats.

`include "chi_to_cxl_bridge_defs.vh"

module chi_to_cxl_bridge #(
  parameter integer FIFO_DEPTH     = 8,
  parameter integer POSTED_CREDITS = 8,
  parameter integer NP_CREDITS     = 8
) (
  input  wire                  clk,
  input  wire                  cxl_clk,    // CXL.mem link-channel domain clock
  input  wire                  rst_n,
  // CHI -> CXL  (clk domain in, cxl_clk domain out)
  input  wire                  chi_req_valid,
  input  wire [CHI_REQ_W-1:0]  chi_req_data,
  output wire                  chi_req_ready,

  input  wire                  chi_wr_data_valid,
  input  wire [CHI_DAT_W-1:0]  chi_wr_data,
  output wire                  chi_wr_data_ready,

  output wire                  cxl_tx_req_valid,
  output wire [CXL_REQ_W-1:0]  cxl_tx_req_data,
  input  wire                  cxl_tx_req_ready,

  output wire                  cxl_tx_rwd_valid,
  output wire [CXL_RWD_W-1:0]  cxl_tx_rwd_data,
  input  wire                  cxl_tx_rwd_ready,

  // CXL -> CHI  (cxl_clk domain in, clk domain out)
  input  wire                  cxl_rx_ndr_valid,
  input  wire [CXL_NDR_W-1:0]  cxl_rx_ndr_data,
  output wire                  cxl_rx_ndr_ready,

  input  wire                  cxl_rx_drs_valid,
  input  wire [CXL_DRS_W-1:0]  cxl_rx_drs_data,
  output wire                  cxl_rx_drs_ready,

  output wire                  chi_rsp_valid,
  output wire [CHI_RSP_W-1:0]  chi_rsp_data,
  input  wire                  chi_rsp_ready,

  output wire                  chi_comp_data_valid,
  output wire [CHI_DAT_W-1:0]  chi_comp_data,
  input  wire                  chi_comp_data_ready,

  // Link readiness and error injection
  input  wire                  link_up,
  input  wire                  err_inj_en,
  output wire                  drain_done,
  // Status counters (clk domain)
  output reg  [15:0]           crc_err_cnt,
  output reg  [15:0]           drain_cnt,
  output reg  [7:0]            max_occ_req,
  output reg  [7:0]            max_occ_rsp
);

  // --- Reset synchronization ---
  wire clk_rst_n;
  wire cxl_rst_n;

  reset_sync #(.STAGES(2)) u_clk_rst_sync (
    .clk(clk), .async_rst_n(rst_n), .sync_rst_n(clk_rst_n)
  );
  reset_sync #(.STAGES(2)) u_cxl_rst_sync (
    .clk(cxl_clk), .async_rst_n(rst_n), .sync_rst_n(cxl_rst_n)
  );

  // --- CDC for external control signals ---
  wire link_up_clk;

  cdc_sync #(.STAGES(2)) u_link_up_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(link_up), .q(link_up_clk)
  );

  // --- Request ordering classification ---
  // Posted: writes (fire-and-forget on the CHI side).
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic is_posted;
    input [CHI_REQ_W-1:0] pkt;
    begin
      is_posted = is_chi_write(pkt[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // --- Translation: CHI request -> CXL.mem M2S flit ---

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic [CXL_REQ_W-1:0] translate_chi_req_to_cxl;
    input [CHI_REQ_W-1:0] chi_pkt;
    input [TAG_W-1:0]     tag;
    reg [CXL_REQ_W-1:0] cxl_req;
    begin
      case (chi_pkt[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W])
        CHI_REQ_READNOSNP: cxl_req[CXL_REQ_MEMOP_LSB +: CXL_REQ_MEMOP_W] = CXL_MEMRD;
        CHI_REQ_READONCE:  cxl_req[CXL_REQ_MEMOP_LSB +: CXL_REQ_MEMOP_W] = CXL_MEMRDDATA;
        default:           cxl_req[CXL_REQ_MEMOP_LSB +: CXL_REQ_MEMOP_W] = CXL_MEMINV;
      endcase

      cxl_req[CXL_REQ_SNPTYPE_LSB +: CXL_REQ_SNPTYPE_W] = 3'h0;
      cxl_req[CXL_REQ_METAFLD_LSB +: CXL_REQ_METAFLD_W] = 2'h0;
      cxl_req[CXL_REQ_METAVAL_LSB +: CXL_REQ_METAVAL_W] = 2'h0;
      cxl_req[CXL_REQ_TAG_LSB     +: CXL_REQ_TAG_W]     = tag;
      cxl_req[CXL_REQ_ADDR_LSB    +: CXL_REQ_ADDR_W]    = chi_pkt[CHI_REQ_ADDR_LSB +: CHI_REQ_ADDR_W];
      cxl_req[CXL_REQ_TC_LSB      +: CXL_REQ_TC_W]      = 2'h0;
      translate_chi_req_to_cxl = cxl_req;
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic [CXL_RWD_W-1:0] translate_chi_wr_to_cxl;
    input [CHI_REQ_W-1:0] chi_req;
    input [CHI_DAT_W-1:0] chi_dat;
    input [TAG_W-1:0]     tag;
    reg [CXL_RWD_W-1:0] cxl_rwd;
    begin
      case (chi_req[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W])
        CHI_REQ_WRITENOSNPPTL: cxl_rwd[CXL_RWD_MEMOP_LSB +: CXL_RWD_MEMOP_W] = CXL_MEMWRPTL;
        default:               cxl_rwd[CXL_RWD_MEMOP_LSB +: CXL_RWD_MEMOP_W] = CXL_MEMWR;
      endcase

      cxl_rwd[CXL_RWD_TAG_LSB     +: CXL_RWD_TAG_W]     = tag;
      cxl_rwd[CXL_RWD_ADDR_LSB    +: CXL_RWD_ADDR_W]    = chi_req[CHI_REQ_ADDR_LSB +: CHI_REQ_ADDR_W];
      cxl_rwd[CXL_RWD_METAFLD_LSB +: CXL_RWD_METAFLD_W] = 2'h0;
      cxl_rwd[CXL_RWD_METAVAL_LSB +: CXL_RWD_METAVAL_W] = 2'h0;
      cxl_rwd[CXL_RWD_POISON_LSB  +: CXL_RWD_POISON_W]  = chi_dat[CHI_DAT_POISON_LSB +: CHI_DAT_POISON_W];
      cxl_rwd[CXL_RWD_BE_LSB      +: CXL_RWD_BE_W]      = chi_dat[CHI_DAT_BE_LSB +: CHI_DAT_BE_W];
      cxl_rwd[CXL_RWD_DATA_LSB    +: CXL_RWD_DATA_W]    = chi_dat[CHI_DAT_DATA_LSB +: CHI_DAT_DATA_W];
      translate_chi_wr_to_cxl = cxl_rwd;
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // --- Translation: CXL.mem S2M response -> CHI response flit ---

  function automatic [CHI_RSP_W-1:0] translate_cxl_ndr_to_chi;
    input [CXL_NDR_W-1:0] cxl_ndr;
    reg [CHI_RSP_W-1:0] chi_rsp;
    begin
      chi_rsp[CHI_RSP_RESPERR_LSB +: CHI_RSP_RESPERR_W] = CHI_RESPERR_OK;
      chi_rsp[CHI_RSP_DBID_LSB    +: CHI_RSP_DBID_W]    = cxl_ndr[CXL_NDR_TAG_LSB +: CXL_NDR_TAG_W];
      chi_rsp[CHI_RSP_TXNID_LSB   +: CHI_RSP_TXNID_W]   = 8'h0;
      chi_rsp[CHI_RSP_OPCODE_LSB  +: CHI_RSP_OPCODE_W]  = CHI_RSP_COMP;
      chi_rsp[CHI_RSP_SRCID_LSB   +: CHI_RSP_SRCID_W]   = 7'h0;
      translate_cxl_ndr_to_chi = chi_rsp;
    end
  endfunction

  function automatic [CHI_DAT_W-1:0] translate_cxl_drs_to_chi;
    input [CXL_DRS_W-1:0] cxl_drs;
    reg [CHI_DAT_W-1:0] chi_dat;
    begin
      chi_dat[CHI_DAT_DATA_LSB    +: CHI_DAT_DATA_W]    = cxl_drs[CXL_DRS_DATA_LSB +: CXL_DRS_DATA_W];
      chi_dat[CHI_DAT_BE_LSB      +: CHI_DAT_BE_W]      = {BE_W{1'b1}};
      chi_dat[CHI_DAT_POISON_LSB  +: CHI_DAT_POISON_W]  = cxl_drs[CXL_DRS_POISON_LSB +: CXL_DRS_POISON_W];
      chi_dat[CHI_DAT_DATAID_LSB  +: CHI_DAT_DATAID_W]  = 4'h0;
      chi_dat[CHI_DAT_RESPERR_LSB +: CHI_DAT_RESPERR_W] = CHI_RESPERR_OK;
      chi_dat[CHI_DAT_RESP_LSB    +: CHI_DAT_RESP_W]    = CHI_CACHE_I;
      chi_dat[CHI_DAT_TXNID_LSB   +: CHI_DAT_TXNID_W]   = {4'h0, cxl_drs[CXL_DRS_TAG_LSB +: CXL_DRS_TAG_W]};
      chi_dat[CHI_DAT_OPCODE_LSB  +: CHI_DAT_OPCODE_W]  = CHI_DAT_COMPDATA;
      translate_cxl_drs_to_chi = chi_dat;
    end
  endfunction

  // --- Internal signals ---

  wire req_posted_w_full;
  wire req_posted_r_empty;
  wire req_np_w_full;
  wire req_np_r_empty;
  wire rsp_ndr_w_full;
  wire rsp_ndr_r_empty;
  wire rsp_drs_w_full;
  wire rsp_drs_r_empty;

  wire [CHI_REQ_W-1:0] req_posted_rd_data;
  wire [CHI_REQ_W-1:0] req_np_rd_data;
  wire [CHI_RSP_W-1:0] rsp_ndr_rd_data;
  wire [CHI_DAT_W-1:0] rsp_drs_rd_data;

  wire req_posted_r_empty_clk;
  wire req_np_r_empty_clk;
  cdc_sync #(.STAGES(2)) u_p_empty_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(req_posted_r_empty), .q(req_posted_r_empty_clk)
  );
  cdc_sync #(.STAGES(2)) u_np_empty_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(req_np_r_empty), .q(req_np_r_empty_clk)
  );

  wire all_empty = req_posted_r_empty_clk && req_np_r_empty_clk && rsp_ndr_r_empty && rsp_drs_r_empty;
  wire bridge_open;
  reset_drain u_reset_drain (
    .clk(clk), .rst_n(clk_rst_n), .link_up(link_up_clk), .all_empty(all_empty), .open(bridge_open), .drain_done(drain_done)
  );

  wire bridge_open_cxl;
  cdc_sync #(.STAGES(2)) u_open_cdc (
    .clk(cxl_clk), .rst_n(cxl_rst_n), .d(bridge_open), .q(bridge_open_cxl)
  );

  wire chi_req_is_posted_w = is_posted(chi_req_data);
  localparam integer OCC_W = $clog2(FIFO_DEPTH) + 1;
  wire [OCC_W-1:0] req_p_occ, req_np_occ, rsp_ndr_occ, rsp_drs_occ;
  localparam [15:0] POSTED_LIM = POSTED_CREDITS[15:0], NP_LIM = NP_CREDITS[15:0];
  wire posted_crd_avail = ({{(16-OCC_W){1'b0}}, req_p_occ} < POSTED_LIM);
  wire np_crd_avail = ({{(16-OCC_W){1'b0}}, req_np_occ} < NP_LIM);

  assign chi_req_ready = bridge_open && (chi_req_is_posted_w ? (!req_posted_w_full && posted_crd_avail) : (!req_np_w_full && np_crd_avail));
  assign chi_wr_data_ready = chi_req_ready && chi_req_valid && chi_req_is_posted_w;
  assign cxl_rx_ndr_ready = bridge_open_cxl && !rsp_ndr_w_full;
  assign cxl_rx_drs_ready = bridge_open_cxl && !rsp_drs_w_full;
  assign chi_rsp_valid = !rsp_ndr_r_empty;
  assign chi_rsp_data = rsp_ndr_rd_data;
  assign chi_comp_data_valid = !rsp_drs_r_empty;
  assign chi_comp_data = rsp_drs_rd_data;

  reg arb_locked_r, arb_sel_posted_r;
  wire arb_sel_now = !req_posted_r_empty;
  wire arb_sel_final = arb_locked_r ? arb_sel_posted_r : arb_sel_now;
  wire [CHI_REQ_W-1:0] arb_rd_data = arb_sel_final ? req_posted_rd_data : req_np_rd_data;
  wire [TAG_W-1:0] txn_tag = arb_rd_data[CHI_REQ_TXNID_LSB +: TAG_W];

  assign cxl_tx_req_valid = (!req_posted_r_empty || !req_np_r_empty) && !is_chi_write(arb_rd_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
  assign cxl_tx_req_data = translate_chi_req_to_cxl(arb_rd_data, txn_tag);
  assign cxl_tx_rwd_valid = (!req_posted_r_empty) && arb_sel_final && is_chi_write(arb_rd_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
  assign cxl_tx_rwd_data = translate_chi_wr_to_cxl(arb_rd_data, chi_wr_data, txn_tag);

  always @(posedge cxl_clk or negedge cxl_rst_n) begin
    if (!cxl_rst_n) begin
      arb_locked_r <= 1'b0; arb_sel_posted_r <= 1'b0;
    end else begin
      if (arb_locked_r) begin
        if (cxl_tx_req_ready || cxl_tx_rwd_ready) arb_locked_r <= 1'b0;
      end else if ((cxl_tx_req_valid && !cxl_tx_req_ready) || (cxl_tx_rwd_valid && !cxl_tx_rwd_ready)) begin
        arb_locked_r <= 1'b1; arb_sel_posted_r <= arb_sel_now;
      end
    end
  end

  wire req_wr = chi_req_valid && chi_req_ready;
  wire req_posted_wr = req_wr && chi_req_is_posted_w;
  wire req_np_wr = req_wr && !chi_req_is_posted_w;
  wire req_posted_rd = (cxl_tx_req_valid && cxl_tx_req_ready && arb_sel_final) || (cxl_tx_rwd_valid && cxl_tx_rwd_ready && arb_sel_final);
  wire req_np_rd = cxl_tx_req_valid && cxl_tx_req_ready && !arb_sel_final;

  async_fifo #(.WIDTH(CHI_REQ_W), .DEPTH(FIFO_DEPTH)) u_req_posted (
    .w_clk(clk), .w_rst_n(clk_rst_n), .w_en(req_posted_wr), .w_data(chi_req_data), .w_full(req_posted_w_full), .w_occupancy(req_p_occ),
    .r_clk(cxl_clk), .r_rst_n(cxl_rst_n), .r_en(req_posted_rd), .r_data(req_posted_rd_data), .r_empty(req_posted_r_empty)
  );
  async_fifo #(.WIDTH(CHI_REQ_W), .DEPTH(FIFO_DEPTH)) u_req_np (
    .w_clk(clk), .w_rst_n(clk_rst_n), .w_en(req_np_wr), .w_data(chi_req_data), .w_full(req_np_w_full), .w_occupancy(req_np_occ),
    .r_clk(cxl_clk), .r_rst_n(cxl_rst_n), .r_en(req_np_rd), .r_data(req_np_rd_data), .r_empty(req_np_r_empty)
  );
  async_fifo #(.WIDTH(CHI_RSP_W), .DEPTH(FIFO_DEPTH)) u_rsp_ndr (
    .w_clk(cxl_clk), .w_rst_n(cxl_rst_n), .w_en(cxl_rx_ndr_valid && cxl_rx_ndr_ready), .w_data(translate_cxl_ndr_to_chi(cxl_rx_ndr_data)), .w_full(rsp_ndr_w_full), .w_occupancy(rsp_ndr_occ),
    .r_clk(clk), .r_rst_n(clk_rst_n), .r_en(chi_rsp_valid && chi_rsp_ready), .r_data(rsp_ndr_rd_data), .r_empty(rsp_ndr_r_empty)
  );
  async_fifo #(.WIDTH(CHI_DAT_W), .DEPTH(FIFO_DEPTH)) u_rsp_drs (
    .w_clk(cxl_clk), .w_rst_n(cxl_rst_n), .w_en(cxl_rx_drs_valid && cxl_rx_drs_ready), .w_data(translate_cxl_drs_to_chi(cxl_rx_drs_data)), .w_full(rsp_drs_w_full), .w_occupancy(rsp_drs_occ),
    .r_clk(clk), .r_rst_n(clk_rst_n), .r_en(chi_comp_data_valid && chi_comp_data_ready), .r_data(rsp_drs_rd_data), .r_empty(rsp_drs_r_empty)
  );

  reg link_up_clk_q;
  always @(posedge clk or negedge clk_rst_n) begin
    if (!clk_rst_n) begin
      crc_err_cnt <= 16'h0000; drain_cnt <= 16'h0000; max_occ_req <= 8'h00; max_occ_rsp <= 8'h00; link_up_clk_q <= 1'b0;
    end else begin
      link_up_clk_q <= link_up_clk;
      if (link_up_clk_q && !link_up_clk && drain_cnt != 16'hFFFF) drain_cnt <= drain_cnt + 1'b1;
      if ({{(8-OCC_W){1'b0}}, req_p_occ} > max_occ_req) max_occ_req <= {{(8-OCC_W){1'b0}}, req_p_occ};
      if ({{(8-OCC_W){1'b0}}, req_np_occ} > max_occ_req) max_occ_req <= {{(8-OCC_W){1'b0}}, req_np_occ};
    end
  end

`ifdef FORMAL
  initial assume (!rst_n);
  always @(*) if (clk_rst_n) begin if (req_posted_wr) assert (posted_crd_avail); if (req_np_wr) assert (np_crd_avail); end
  always @(*) if (!bridge_open) assert (chi_req_ready == 1'b0);
  always @(*) if (chi_req_valid && chi_req_ready) begin if (chi_req_is_posted_w) assert (req_posted_wr && !req_np_wr); else assert (!req_posted_wr && req_np_wr); end
  always_ff @(posedge cxl_clk) if (cxl_rst_n) begin if (cxl_tx_req_valid && cxl_tx_req_ready) begin assert (req_posted_rd == arb_sel_final); assert (req_np_rd == !arb_sel_final); end if (!arb_locked_r && !req_posted_r_empty) assert (arb_sel_final == 1'b1); end
  always @(*) if (cxl_rst_n && arb_locked_r) begin if (arb_sel_posted_r) assert (!req_posted_r_empty); else assert (!req_np_r_empty); end
  always_ff @(posedge clk) if (clk_rst_n && $past(clk_rst_n)) if ($past(chi_req_valid) && !$past(chi_req_ready)) begin assume (chi_req_valid); assume (chi_req_data == $past(chi_req_data)); end
  reg f_to_v_q, f_to_r_q, f_to_vld; reg [CXL_REQ_W-1:0] f_to_d_q;
  always_ff @(posedge cxl_clk or negedge cxl_rst_n) if (!cxl_rst_n) begin f_to_v_q <= 1'b0; f_to_r_q <= 1'b0; f_to_d_q <= {CXL_REQ_W{1'b0}}; f_to_vld <= 1'b0; end else begin f_to_v_q <= cxl_tx_req_valid; f_to_r_q <= cxl_tx_req_ready; f_to_d_q <= cxl_tx_req_data; f_to_vld <= 1'b1; end
  always @(*) if (cxl_rst_n && f_to_vld && f_to_v_q && !f_to_r_q) begin assert (cxl_tx_req_valid); assert (cxl_tx_req_data == f_to_d_q); end
  always_ff @(posedge clk) if (clk_rst_n) begin cover (chi_req_valid && is_chi_read(chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W])); cover (chi_req_valid && is_chi_write(chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W])); cover (drain_done); end
  always @(posedge clk) if (clk_rst_n) begin if (req_posted_wr) assert (!req_posted_w_full); if (req_np_wr) assert (!req_np_w_full); end
  always @(posedge cxl_clk) if (cxl_rst_n) begin if (req_posted_rd) assert (!req_posted_r_empty); if (req_np_rd) assert (!req_np_r_empty); end
  always @(*) if (clk_rst_n) begin assert ({{(16-OCC_W){1'b0}}, req_p_occ} <= POSTED_LIM); assert ({{(16-OCC_W){1'b0}}, req_np_occ} <= NP_LIM); end
`endif

endmodule
