// Synchronous FIFO: same clock for read and write. DEPTH must be a power of 2.
// First-word fall-through: rd_data is combinational from mem[rd_ptr]; empty/full
// are registered-path stable after each posedge.

module sync_fifo #(
  parameter integer WIDTH = 64,
  parameter integer DEPTH = 8
) (
  input  wire                  clk,
  input  wire                  rst_n,
  input  wire                  wr_en,
  input  wire [WIDTH-1:0]      wr_data,
  output wire                  full,
  output wire                  empty,
  input  wire                  rd_en,
  output wire [WIDTH-1:0]      rd_data
);

  generate
    if (DEPTH < 1 || (DEPTH & (DEPTH - 1)) != 0) begin : gen_depth_check
      initial $fatal(1, "sync_fifo: DEPTH must be a power of 2 and >= 1");
    end
  endgenerate

  localparam integer ADDR_W = $clog2(DEPTH);
  // Sized depth for comparisons (avoids tool-specific width mismatch on count).
  localparam [ADDR_W:0] DEPTH_CNT = DEPTH[ADDR_W:0];

  reg [WIDTH-1:0] mem[0:DEPTH-1];
  reg [ADDR_W-1:0] wr_ptr;
  reg [ADDR_W-1:0] rd_ptr;
  reg [ADDR_W:0] count;

  assign full  = (count == DEPTH_CNT);
  assign empty = (count == {(ADDR_W + 1) {1'b0}});
  assign rd_data = mem[rd_ptr];

  wire wr = wr_en && !full;
  wire rd = rd_en && !empty;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= {ADDR_W{1'b0}};
      rd_ptr <= {ADDR_W{1'b0}};
      count  <= {(ADDR_W + 1) {1'b0}};
    end else begin
      if (wr)
        mem[wr_ptr] <= wr_data;
      if (wr && !rd)
        count <= count + 1'b1;
      else if (rd && !wr)
        count <= count - 1'b1;
      if (wr)
        wr_ptr <= wr_ptr + 1'b1;
      if (rd)
        rd_ptr <= rd_ptr + 1'b1;
    end
  end

`ifdef FORMAL
  // BMC must not start from physically impossible register values (unconstrained init).
  initial begin
    assume (count <= DEPTH_CNT);
    assume (wr_ptr < DEPTH);
    assume (rd_ptr < DEPTH);
  end

  // Assume-guarantee occupancy invariant (mirrors async_fifo's FIFO_OCC_CHECK):
  // ASSERTED and proven k-inductive in the standalone sync_fifo proof
  // (FIFO_FORMAL_STANDALONE), and ASSUMED when instantiated inside an integrated
  // top -- otherwise the top's k-induction is free to seed this black-box FIFO in
  // an unreachable over-full state and spuriously fail a bounds assert.
`ifdef FIFO_FORMAL_STANDALONE
  `define SFIFO_OCC_CHECK assert
`else
  `define SFIFO_OCC_CHECK assume
`endif
  always_ff @(posedge clk) begin
    if (rst_n === 1'b1) begin
      `SFIFO_OCC_CHECK (count <= DEPTH_CNT);
      `SFIFO_OCC_CHECK (count >= {(ADDR_W + 1) {1'b0}});
    end
  end

`ifdef FIFO_FORMAL_STANDALONE
  // Reachability (cover mode): show FIFO can fill, drain partially, and do same-cycle wr+rd.
  // Guarded to the standalone proof environment (cf. async_fifo): these are
  // unit-level reachability checks and must not become cover obligations for an
  // integrated top-level proof, where the enclosing logic bounds how these
  // FIFOs can be driven. The safety asserts above stay active in integration.
  always_ff @(posedge clk) begin
    if (rst_n === 1'b1) begin
      cover (full);
      cover (wr && rd);
      cover ((count > {(ADDR_W + 1) {1'b0}}) && (count < DEPTH_CNT));
    end
  end
`endif
`endif

endmodule
