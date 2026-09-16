// Negative-test fixture for the structural CDC check (tools/cdc_check.py).
// Contains a DELIBERATE unsynchronized clk<->cxl_clk crossing: `b` (clk domain)
// samples `a` (cxl_clk domain) with no synchronizer. `make -C verification/cdc
// selftest` asserts the checker FLAGS this, so the CDC gate can never silently
// become vacuous. Not part of the design; never included in a build.
module bad_cdc_fixture (
  input  wire clk,
  input  wire cxl_clk,
  input  wire rst_n,
  input  wire d,
  output reg  y
);
  reg a;   // cxl_clk domain
  always @(posedge cxl_clk or negedge rst_n)
    if (!rst_n) a <= 1'b0; else a <= d;

  reg b;   // clk domain reads the cxl_clk register `a` directly -- BAD CDC
  always @(posedge clk or negedge rst_n)
    if (!rst_n) b <= 1'b0; else b <= a;

  always @(posedge clk or negedge rst_n)
    if (!rst_n) y <= 1'b0; else y <= b;
endmodule
