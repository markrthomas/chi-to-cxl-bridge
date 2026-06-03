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
- [x] `make coverage` — Verilator C++ harness, **100%** line coverage (80% floor).
- [x] `make sva` — concurrent interface SVA on all four valid/ready ports
      (Verilator `--assert`). PASS.
- [x] `make formal` — SymbiYosys: `credit_counter`, `reset_drain`, `async_fifo`
      proven (bmc + cover + unbounded `prove`/k-induction); `chi_to_cxl_bridge`
      top checked (bmc depth 24 + cover).
- [x] `make cocotb` — cocotb + **PyVSC** functional-coverage bench (Icarus VPI):
      covergroups over the request/response opcode maps, completion status, and
      the CRC good/bad cross; gold-checked directed + randomized + closure tests;
      **100%** functional coverage, UCIS XML written to `verification/cocotb/cov.xml`.
- [x] `make synth` — Yosys synthesis smoke, no inferred latches.
- [x] CI workflow (`.github/workflows/ci.yml`): regress / coverage / cocotb / sva
      / formal / synth / verible(advisory).

## Phase 1 — close formal on the bridge top

- [ ] Port the shadow-register + assume-guarantee composition used in
      `cxl_lpddr5x_bridge.sby` so the integrated `chi_to_cxl_bridge` top closes an
      unbounded `prove` (currently bmc + cover only). The FORMAL block in
      `chi_to_cxl_bridge.v` already mirrors the proven egress-stability and
      arbiter-lock invariants; the FIFO occupancy guarantee is discharged by the
      standalone `async_fifo` `prove`.
- [ ] Add per-module `prove` task to `chi_to_cxl_bridge.sby` and gate it in CI.

## Phase 2 — cocotb + PyVSC functional coverage

- [x] Add `verification/cocotb/` (Icarus VPI) with a gold-model scoreboard,
      directed + randomized + closure tests, and **PyVSC** covergroups. Wired to
      `make cocotb` and a CI job (cocotb==1.8.1 + pyvsc). 100% functional coverage.
      See [coverage-plan.md](coverage-plan.md).
- [ ] Add a backpressure / FIFO-occupancy covergroup (req/rsp stall depth,
      near-full credit states) — exercised today but not yet a gated covergroup.
- [ ] Constrained-random stimulus with PyVSC `@vsc.randobj` (replace the ad-hoc
      `random` builders) for closed-loop coverage-driven generation.

## Phase 3 — protocol fidelity

- [ ] Replace the compact 64-bit packet with a structured CHI flit model
      (separate REQ / RSP / DAT field groups, real TxnID / DBID handshake).
- [ ] Model CXL.mem flit framing (M2S Req vs RwD with data, S2M DRS header+data).
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
