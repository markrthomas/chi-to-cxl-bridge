// Simulation-only checks for chi_to_cxl_bridge egress ready/valid stability.
// cxl_tx_* checks run on cxl_clk; chi_rsp_* checks run on clk.

module chi_to_cxl_bridge_chk #(
  parameter integer WIDTH = 64
) (
  input wire                  clk,
  input wire                  cxl_clk,
  input wire                  rst_n,
  input wire                  cxl_tx_valid,
  input wire [WIDTH-1:0]      cxl_tx_data,
  input wire                  cxl_tx_ready,
  input wire                  chi_rsp_valid,
  input wire [WIDTH-1:0]      chi_rsp_data,
  input wire                  chi_rsp_ready
);

  // CXL command egress checks — sample on cxl_clk
  reg                 prev_tv, prev_tr;
  reg [WIDTH-1:0]     prev_td;

  always @(posedge cxl_clk or negedge rst_n) begin
    if (!rst_n) begin
      prev_tv <= 1'b0;
      prev_tr <= 1'b0;
      prev_td <= {WIDTH{1'b0}};
    end else begin
      if (prev_tv && !prev_tr) begin
        if (!cxl_tx_valid) begin
          $display("ASSERT: cxl_tx_valid dropped while sink not ready");
          $finish(1);
        end
        if (cxl_tx_data !== prev_td) begin
          $display("ASSERT: cxl_tx_data changed while valid && !ready");
          $finish(1);
        end
      end
      prev_tv <= cxl_tx_valid;
      prev_tr <= cxl_tx_ready;
      prev_td <= cxl_tx_data;
    end
  end

  // CHI response egress checks — sample on clk
  reg                 prev_rv, prev_rr;
  reg [WIDTH-1:0]     prev_rd;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev_rv <= 1'b0;
      prev_rr <= 1'b0;
      prev_rd <= {WIDTH{1'b0}};
    end else begin
      if (prev_rv && !prev_rr) begin
        if (!chi_rsp_valid) begin
          $display("ASSERT: chi_rsp_valid dropped while sink not ready");
          $finish(1);
        end
        if (chi_rsp_data !== prev_rd) begin
          $display("ASSERT: chi_rsp_data changed while valid && !ready");
          $finish(1);
        end
      end
      prev_rv <= chi_rsp_valid;
      prev_rr <= chi_rsp_ready;
      prev_rd <= chi_rsp_data;
    end
  end

endmodule
