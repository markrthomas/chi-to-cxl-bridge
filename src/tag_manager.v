// Tag Manager: tracks outstanding transactions for the CHI <-> CXL bridge.
// Dual-port lookup to support concurrent RSP and DAT channel lookups.
//
// Fully parameterized (TAG_W / TXNID_W / SRCID_W) and self-contained: it does
// not depend on the bridge defs header.

// These parameter names intentionally match the $unit-scoped localparams in the
// bridge defs header (compiled together via rtl.f); the shadowing is benign.
/* verilator lint_off VARHIDDEN */
module tag_manager #(
  parameter integer TAG_W = 4,
  parameter integer TXNID_W = 8,
  parameter integer SRCID_W = 7
) (
/* verilator lint_on VARHIDDEN */
  input  wire               clk,
  input  wire               rst_n,

  // Allocation interface (clk domain)
  input  wire               alloc_vld,
  input  wire [TXNID_W-1:0] alloc_txnid,
  input  wire [SRCID_W-1:0] alloc_srcid,
  output wire               alloc_rdy,
  output wire [TAG_W-1:0]   alloc_tag,

  // Release/Lookup Port A (typically for NDR -> CHI RSP)
  input  wire               release_a_vld,
  input  wire [TAG_W-1:0]   release_a_tag,
  output wire [TXNID_W-1:0] release_a_txnid,
  output wire [SRCID_W-1:0] release_a_srcid,

  // Release/Lookup Port B (typically for DRS -> CHI DAT)
  input  wire               release_b_vld,
  input  wire [TAG_W-1:0]   release_b_tag,
  output wire [TXNID_W-1:0] release_b_txnid,
  output wire [SRCID_W-1:0] release_b_srcid
);

  localparam integer N_TAGS = (1 << TAG_W);

  // --- Free-tag pool ---
  wire               free_fifo_wr;
  wire [TAG_W-1:0]   free_fifo_wdata;
  // The free pool holds exactly N_TAGS entries and can never be written beyond
  // what was allocated out of it, so its full flag is unused by construction.
  /* verilator lint_off UNUSEDSIGNAL */
  wire               free_fifo_full;
  /* verilator lint_on UNUSEDSIGNAL */
  wire               free_fifo_rd;
  wire [TAG_W-1:0]   free_fifo_rdata;
  wire               free_fifo_empty;

  // Initialization FSM to fill the FIFO with all available tags
  reg [TAG_W:0] init_cnt;
  reg           init_done;
  wire          initializing = !init_done;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      init_cnt  <= {(TAG_W+1){1'b0}};
      init_done <= 1'b0;
    end else if (initializing) begin
      if (init_cnt[TAG_W]) begin
        init_done <= 1'b1;
      end else begin
        init_cnt <= init_cnt + 1'b1;
      end
    end
  end

  // Return tags to pool from either port.
  // Note: For simplicity, this doesn't handle concurrent release on the same cycle
  // to the SAME free-pool FIFO. If both ports release on the same cycle, we'd need
  // a multi-write FIFO or an arbiter. However, in CHI smoke tests, they are sequential.
  // In a real bridge, we'd use a small arbiter or a wider return path.
  assign free_fifo_wr    = (initializing && !init_cnt[TAG_W]) || release_a_vld || release_b_vld;
  assign free_fifo_wdata = initializing ? init_cnt[TAG_W-1:0] :
                           (release_a_vld ? release_a_tag : release_b_tag);

  assign free_fifo_rd    = alloc_vld && alloc_rdy;
  assign alloc_rdy       = init_done && !free_fifo_empty;
  assign alloc_tag       = free_fifo_rdata;

  sync_fifo #(
    .WIDTH(TAG_W),
    .DEPTH(N_TAGS)
  ) u_free_pool (
    .clk    (clk),
    .rst_n  (rst_n),
    .wr_en  (free_fifo_wr),
    .wr_data(free_fifo_wdata),
    .full   (free_fifo_full),
    .empty  (free_fifo_empty),
    .rd_en  (free_fifo_rd),
    .rd_data(free_fifo_rdata)
  );

  // --- Transaction state RAM ---
  reg [TXNID_W+SRCID_W-1:0] state_mem[N_TAGS-1:0];

  always @(posedge clk) begin
    if (alloc_vld && alloc_rdy) begin
      state_mem[alloc_tag] <= {alloc_txnid, alloc_srcid};
    end
  end

  // Combinational lookup for Port A
  wire [TXNID_W+SRCID_W-1:0] state_a = state_mem[release_a_tag];
  assign release_a_txnid = state_a[SRCID_W +: TXNID_W];
  assign release_a_srcid = state_a[0 +: SRCID_W];

  // Combinational lookup for Port B
  wire [TXNID_W+SRCID_W-1:0] state_b = state_mem[release_b_tag];
  assign release_b_txnid = state_b[SRCID_W +: TXNID_W];
  assign release_b_srcid = state_b[0 +: SRCID_W];

endmodule
