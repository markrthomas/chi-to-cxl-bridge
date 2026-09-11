# chi_to_cxl_bridge — Plan

## Current state (Phase 0 — scaffold landed)

The repository is bootstrapped to the workspace DV standard (see
`../DV_STANDARDS.md`), mirroring the structure of `cxl_lpddr5x_bridge`.

Implemented and green locally:

- [x] RTL datapath: CHI request → CXL.mem M2S translation, CXL.mem S2M → CHI
      response translation, posted/non-posted classification, posted-priority
      egress arbiter with command lock.
- [x] Dual-clock CDC: Gray-coded `async_fifo` ×3, `cdc_sync`, `reset_sync`,
      `credit_pulse_sync` (CRC-error counter crossing) — reused verbatim from the
      proven workspace library.
- [x] Occupancy-based per-class credit flow control (Posted / Non-Posted / Response).
- [x] Reset-drain link gate (`DOWN → UP → DRAIN → DOWN`).
- [x] CRC-8/CCITT integrity check; bad-CRC / unknown response → CHI RespErr.
- [x] `make lint` — Verilator `--lint-only -Wall`, clean.
- [x] `make sim` / `make stress` — Icarus directed + self-checking scoreboard,
      clock ratios 1:1 / 2:1 / 1:3, all kinds, ordering, link gating, error
      injection. PASS.
- [x] `make coverage` — Verilator `--coverage-line` on the pyuvm run, scored by
      `tools/coverage_report.py`, **~87%** line coverage (80% floor gated).
- [x] `make sva` — bound SVA checker (`verification/uvm/sv/chi_to_cxl_sva.sv`)
      verified under the pyuvm round-trip (Verilator `--assert`): M2S/CHI
      handshake stability, RSP legal-opcode, and the no-phantom-Req guard. PASS.
- [x] `make formal` — SymbiYosys: `credit_counter`, `reset_drain`, `async_fifo`
      proven (bmc + cover + unbounded `prove`/k-induction); `chi_to_cxl_bridge`
      top checked (bmc depth 24 + cover).
- [x] `make pyuvm` / `make fcov` — PyUVM-on-cocotb tier aligned with
      `../ucie2-pipe7-bridge/dv/pyuvm`: env + scoreboard cross-checking round-trip
      identity and request translation against the Python gold model
      (`verification/common/models/bridge_model.py`); directed + randomized tests;
      **100%** functional coverage via `cocotb_coverage`.
- [x] `make synth` — Yosys synthesis smoke, no inferred latches.
- [x] CI workflow (`.github/workflows/ci.yml`): regress / pyuvm / fcov / coverage
      / sva / formal / synth / verible(advisory).

## Phase 1 — close formal on the bridge top

- [ ] Port the shadow-register + assume-guarantee composition used in
      `cxl_lpddr5x_bridge.sby` so the integrated `chi_to_cxl_bridge` top closes an
      unbounded `prove` (currently bmc + cover only). The FORMAL block in
      `chi_to_cxl_bridge.v` already mirrors the proven egress-stability and
      arbiter-lock invariants; the FIFO occupancy guarantee is discharged by the
      standalone `async_fifo` `prove`.
- [ ] Add per-module `prove` task to `chi_to_cxl_bridge.sby` and gate it in CI.

## Phase 2 — functional coverage (now PyUVM-on-cocotb)

- [x] PyUVM tier under `verification/pyuvm/` (aligned with
      `../ucie2-pipe7-bridge/dv/pyuvm`): agent (CHI driver + CXL responder +
      response monitor), sequence library, env + cross-check scoreboard, and
      `test_smoke` / `test_roundtrip` / `test_random` / `test_fcov`.
      Functional coverage via `cocotb_coverage` (`coverage_model.py`), 100% of
      the loopback-reachable set. See [coverage-plan.md](coverage-plan.md).
      (Replaces the earlier PyVSC bench, which the structured-flit refactor and a
      missing `pyvsc` dependency had left dead.)
- [ ] Add a backpressure / FIFO-occupancy covergroup (req/rsp stall depth,
      near-full credit states) — exercised today but not yet a gated covergroup.
- [ ] Constrained-random stimulus with per-transaction randomization objects for
      closed-loop coverage-driven generation.

## Phase 3 — protocol fidelity

- [x] Replace the compact 64-bit packet with a structured CHI flit model
      (separate REQ / RSP / DAT field groups, real TxnID / DBID handshake).
- [x] Model CXL.mem flit framing (M2S Req vs RwD with data, S2M DRS header+data).
- [x] Multi-transaction tracking via `tag_manager` (free-tag pool + per-tag
      state), write-data buffering, and the CHI **DBIDResp** handshake for writes
      (Phase 3b/3c). Egress qualifier fixed so a write awaiting its data can no
      longer drive a phantom M2S Req (found by the pyuvm scoreboard + guarded by
      the bound SVA).
- [ ] Add the CHI SNP channel + a minimal snoop-response path (optional, for a
      coherent HN-side bridge).
- [ ] Multi-beat data payload transport across the async FIFOs.

## Phase 4 — UVM bench (commercial sim)

- [ ] Optional `verification/uvm/` (Xcelium) scoreboard + functional coverage,
      kept out of the OSS CI gate, matching the workspace convention.

## Notes

- Infrastructure modules (`async_fifo`, `cdc_sync`, `reset_sync`,
  `credit_counter`, `credit_pulse_sync`, `reset_drain`) are byte-identical to the
  proven copies in `cxl_lpddr5x_bridge`; keep them in sync if the upstream copies
  change.
- `verification/uvm/sv/` holds the boundary interface bundle (`chi_to_cxl_if.sv`)
  and the bound SVA checker (`chi_to_cxl_sva.sv`), mirroring
  `../ucie2-pipe7-bridge/dv/uvm/sv`. The SVA is checked today under the pyuvm run
  (`make sva`); a full SV-UVM tb on the interface is Phase 4.
- `tools/coverage_report.py` (line-coverage scorer) and `tools/trace_compare.py`
  (per-cycle trace diff) are shared with, and adapted from,
  `../ucie2-pipe7-bridge/tools`.
