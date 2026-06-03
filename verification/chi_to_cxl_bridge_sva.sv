// Concurrent SystemVerilog Assertions (SVA) for the chi_to_cxl_bridge
// valid/ready stream interfaces. Bound to the DUT (see the `bind` at the bottom)
// and exercised at runtime by Verilator `--assert` via the sim/sim_main.cpp
// stimulus (`make sva`). Icarus is NOT used for this file — its concurrent-SVA
// support is insufficient; the equivalent properties are proved formally in the
// `ifdef FORMAL block of chi_to_cxl_bridge.v (Yosys-supported immediate style).
//
// Protocol contract checked on every valid/ready interface (producer drives
// valid+data, consumer drives ready):
//   * valid, once asserted, holds until the cycle after a handshake;
//   * data is held stable while a transfer is stalled (valid && !ready);
//   * cover goals record that each interface both handshakes and stalls.
//
// Domain map: chi_req / chi_rsp are in the `clk` domain;
//             cxl_tx  / cxl_rx  are in the `cxl_clk` domain.

module chi_to_cxl_bridge_sva #(
  parameter integer WIDTH = 64
) (
  input logic              clk,
  input logic              cxl_clk,
  input logic              rst_n,
  // CHI request ingress (clk)
  input logic              chi_req_valid,
  input logic [WIDTH-1:0]  chi_req_data,
  input logic              chi_req_ready,
  // CXL command egress (cxl_clk)
  input logic              cxl_tx_valid,
  input logic [WIDTH-1:0]  cxl_tx_data,
  input logic              cxl_tx_ready,
  // CXL response ingress (cxl_clk)
  input logic              cxl_rx_valid,
  input logic [WIDTH-1:0]  cxl_rx_data,
  input logic              cxl_rx_ready,
  // CHI response egress (clk)
  input logic              chi_rsp_valid,
  input logic [WIDTH-1:0]  chi_rsp_data,
  input logic              chi_rsp_ready
);

  // ---- CHI request ingress (clk domain) ----
  chi_req_valid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (chi_req_valid && !chi_req_ready) |=> chi_req_valid);
  chi_req_data_stable:  assert property (@(posedge clk) disable iff (!rst_n)
    (chi_req_valid && !chi_req_ready) |=> $stable(chi_req_data));
  chi_req_handshake:    cover  property (@(posedge clk) disable iff (!rst_n)
    chi_req_valid && chi_req_ready);
  chi_req_stall:        cover  property (@(posedge clk) disable iff (!rst_n)
    chi_req_valid && !chi_req_ready);

  // ---- CXL command egress (cxl_clk domain) ----
  cxl_tx_valid_stable: assert property (@(posedge cxl_clk) disable iff (!rst_n)
    (cxl_tx_valid && !cxl_tx_ready) |=> cxl_tx_valid);
  cxl_tx_data_stable:  assert property (@(posedge cxl_clk) disable iff (!rst_n)
    (cxl_tx_valid && !cxl_tx_ready) |=> $stable(cxl_tx_data));
  cxl_tx_handshake:    cover  property (@(posedge cxl_clk) disable iff (!rst_n)
    cxl_tx_valid && cxl_tx_ready);
  cxl_tx_stall:        cover  property (@(posedge cxl_clk) disable iff (!rst_n)
    cxl_tx_valid && !cxl_tx_ready);

  // ---- CXL response ingress (cxl_clk domain) ----
  cxl_rx_valid_stable:  assert property (@(posedge cxl_clk) disable iff (!rst_n)
    (cxl_rx_valid && !cxl_rx_ready) |=> cxl_rx_valid);
  cxl_rx_data_stable:   assert property (@(posedge cxl_clk) disable iff (!rst_n)
    (cxl_rx_valid && !cxl_rx_ready) |=> $stable(cxl_rx_data));
  cxl_rx_handshake:     cover  property (@(posedge cxl_clk) disable iff (!rst_n)
    cxl_rx_valid && cxl_rx_ready);
  cxl_rx_stall:         cover  property (@(posedge cxl_clk) disable iff (!rst_n)
    cxl_rx_valid && !cxl_rx_ready);

  // ---- CHI response egress (clk domain) ----
  chi_rsp_valid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (chi_rsp_valid && !chi_rsp_ready) |=> chi_rsp_valid);
  chi_rsp_data_stable:  assert property (@(posedge clk) disable iff (!rst_n)
    (chi_rsp_valid && !chi_rsp_ready) |=> $stable(chi_rsp_data));
  chi_rsp_handshake:    cover  property (@(posedge clk) disable iff (!rst_n)
    chi_rsp_valid && chi_rsp_ready);
  chi_rsp_stall:        cover  property (@(posedge clk) disable iff (!rst_n)
    chi_rsp_valid && !chi_rsp_ready);

endmodule

// Bind the checker into every chi_to_cxl_bridge instance.
bind chi_to_cxl_bridge chi_to_cxl_bridge_sva #(.WIDTH(WIDTH)) u_sva (.*);
