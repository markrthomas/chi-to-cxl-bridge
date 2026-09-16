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
- [x] `make formal` — SymbiYosys: `credit_counter`, `reset_drain`, `async_fifo`,
      `sync_fifo` proven (bmc + cover + unbounded `prove`/k-induction); the
      `chi_to_cxl_bridge` top now also closes an unbounded `prove` (bmc depth 24 +
      cover + k-induction), using a data-width abstraction (`FORMAL_SMALL_DATA`)
      so the wide-datapath SMT proof is tractable.
- [x] `make pyuvm` / `make fcov` — PyUVM-on-cocotb tier aligned with
      `../ucie2-pipe7-bridge/dv/pyuvm`: env + scoreboard cross-checking round-trip
      identity and request translation against the Python gold model
      (`verification/common/models/bridge_model.py`); directed + randomized tests;
      **100%** functional coverage via `cocotb_coverage`.
- [x] `make synth` — Yosys synthesis smoke, no inferred latches.
- [x] CI workflow (`.github/workflows/ci.yml`): regress / pyuvm / fcov / coverage
      / sva / formal / synth / verible(advisory).

## Phase 1 — close formal on the bridge top  ✅

- [x] The integrated `chi_to_cxl_bridge` top closes an unbounded `prove`
      (k-induction), added as a `prove` task in `chi_to_cxl_bridge.sby`.
      Getting there required three changes:
  - **Decouple the M2S egress arbiter.** CXL.mem Req (reads) and RwD (writes) are
    independent message classes, but a legacy shared arbiter (`arb_locked_r` /
    `arb_sel_*`) coupled them. It made egress-Req `valid` depend on `arb_sel_final`
    (and, transiently, on FIFO *contents*), which both allowed a phantom Req and
    was not k-inductive. Each channel now presents its own source FIFO head
    (`valid = source non-empty`), so a stalled beat is never popped and holds
    stable — the reference's proven structure. This also removed the phantom-Req
    class of bug at the source (superseding the earlier qualifier patch).
  - **`sync_fifo` assume-guarantee** (mirrors `async_fifo`): occupancy invariant
    ASSERTED + proven k-inductive standalone (`sync_fifo.sby`, `-DFIFO_FORMAL_STANDALONE`),
    ASSUMED in integration.
  - **Data-width abstraction** (`FORMAL_SMALL_DATA`): the properties are
    width-independent, so the bridge `.sby` shrinks the 512-bit beat to keep the
    unbounded SMT proof within memory; sim / coverage / SVA / synth keep 512.
- [x] `prove` gated in CI via the `formal` job (runs the full `make formal`).
- [x] Full-width unbounded `prove` (no data abstraction). The same
      width-independent safety properties now also close at the FULL 512-bit
      datapath width — `chi_to_cxl_bridge_fullwidth.sby` drops `FORMAL_SMALL_DATA`
      and switches the engine to `smtbmc bitwuzla`, which keeps the wide FIFO
      memories as SMT arrays instead of bit-blasting them (the default engine's
      blasting is what OOMed at 512 bits). bmc depth 24 + unbounded prove, both
      pass by k-induction (~2 min each). Run by `make formal-fullwidth` and the
      dedicated `formal-fullwidth` CI job; kept out of the lean primary `formal`
      gate. (The engine change made it tractable even on a small machine, so no
      special high-memory runner was ultimately needed.)

## Phase 2 — functional coverage (now PyUVM-on-cocotb)

- [x] PyUVM tier under `verification/pyuvm/` (aligned with
      `../ucie2-pipe7-bridge/dv/pyuvm`): agent (CHI driver + CXL responder +
      response monitor), sequence library, env + cross-check scoreboard, and
      `test_smoke` / `test_roundtrip` / `test_random` / `test_fcov`.
      Functional coverage via `cocotb_coverage` (`coverage_model.py`), 100% of
      the loopback-reachable set. See [coverage-plan.md](coverage-plan.md).
      (Replaces the earlier PyVSC bench, which the structured-flit refactor and a
      missing `pyvsc` dependency had left dead.)
- [x] Backpressure / FIFO-occupancy covergroup (`test_backpressure.py` +
      `coverage_model.BP_POINTS`): 7 stall / near-full / credit-exhaustion bins,
      driven by dedicated stall stimulus, 100%-gated under `make fcov`.
- [x] Constrained-random stimulus: `seq_lib.chi_seq_lib.ChiReqRandom` is a
      `cocotb_coverage.crv.Randomized` object (constrained opcode + 64B-aligned
      address) that `RandomSeq` / `test_random` draw from, replacing the ad-hoc
      `random`-module builders. (cocotb_coverage is therefore a core pyuvm-tier
      dependency now, not fcov-only.)
- [x] Closed-loop coverage-driven generation. `seq_lib.CoverageDrivenSeq` reads
      the LIVE `cocotb_coverage` DB before each transaction and soft-biases the
      `ChiReqRandom` crv (via `randomize_with` numeric-weight constraints) toward
      the request opcode / burst-length bins still uncovered — every other point
      is downstream of those, so this closes the whole generation-reachable set.
      `test_cov_driven` proves purely random stimulus + coverage feedback (no
      directed round-trip) reaches **100%** in the theoretical-minimum **5**
      transactions, and it is gated under `make fcov`. Coverage-DB query helpers
      live in `coverage_model.uncovered_opcodes()` / `uncovered_beats()`.

## Phase 3 — protocol fidelity

- [x] Replace the compact 64-bit packet with a structured CHI flit model
      (separate REQ / RSP / DAT field groups, real TxnID / DBID handshake).
- [x] Model CXL.mem flit framing (M2S Req vs RwD with data, S2M DRS header+data).
- [x] Multi-transaction tracking via `tag_manager` (free-tag pool + per-tag
      state), write-data buffering, and the CHI **DBIDResp** handshake for writes
      (Phase 3b/3c). Egress qualifier fixed so a write awaiting its data can no
      longer drive a phantom M2S Req (found by the pyuvm scoreboard + guarded by
      the bound SVA).
- [x] CHI SNP channel + minimal snoop-response path: a host-side SNP request
      input and a SnpResp output. The CXL.mem device is memory-only (no cached
      copy), so the bridge answers every snoop directly with SnpResp, final state
      Invalid, via a 2-deep skid FIFO (clk-domain only — no CXL crossing). Covered
      by `test_snoop.py` (gold-checked SnpResp_I, `snp_opcode` covergroup 100%),
      the bound SVA (`a_snp_resp_stable`, `a_snp_resp_is_snpresp_i`), and the
      formal SnpResp egress valid/data-stability shadow.
- [x] Multi-beat data payload transport with a **runtime-variable burst length**
      (1..`MAX_BEATS`) carried per transaction. The CHI request `SIZE` field maps
      (via `chi_req_beats`) to a beat count placed in `CXL_REQ.LEN` (reads) and
      `CXL_RWD.LEN` (writes). A write streams its `LEN` RwD beats out of the write
      buffer with a cxl-domain beat counter (`rwd_beat_q`) that pops the command
      only on the last beat; a read returns `LEN` DRS→CompData beats with a
      clk-domain counter (`drs_beat_q`) that frees the tag only on the last beat.
      The tag manager stores the burst length per tag (`LEN_W`). Verified across
      all tiers: directed multi-beat scenario (`tb_chi_to_cxl_bridge.v`), pyuvm
      `test_multibeat` + high-volume interleaved `test_multibeat_stress` (78 mixed
      bursts self-throttling through the 16-tag pool) + randomized `size` in
      `RandomSeq`, the `req_beats` covergroup (100% under `make fcov`), the bound
      SVA, and the unbounded formal `prove`. The write-egress beat counter carries
      **proven** invariants in the unbounded prove (`rwd_beat_q < rwd_len` and
      `req_posted_r_empty -> rwd_beat_q == 0`, k-inductive because `chi_req_beats`
      is structurally ≥1 for every SIZE encoding — so the command pops exactly
      once per burst); the read side proves no tag is freed without a returning
      DRS beat. (The read-side count relation depends on the unconstrained
      tag-manager RAM, and a full-burst cover needs a chain deeper than the cover
      engine runs tractably, so both are discharged by BMC + the pyuvm / SVA /
      directed multi-beat runs instead.)

## Phase 4 — SV-UVM bench

- [x] `verification/uvm/sv/`: a single-package SV-UVM env
      (`chi_to_cxl_uvm_pkg.sv`) on the `chi_to_cxl_if` bundle — CHI driver
      (req + DBIDResp-gated WrData), CXL responder (M2S accept + S2M DRS/NDR),
      response monitor, and a scoreboard doing the same round-trip + translation
      cross-check as the pyuvm tier, plus the bound SVA under `--assert`. Driven
      by `chi_roundtrip_test` from `tb_chi_to_cxl.sv`.
- [x] `verification/uvm/vlt/Makefile` (aligned with the reference): `lint`
      elaborate-only (RAM-safe, ~280 MB — runs locally + in the `uvm-lint` CI job,
      which fetches the Accellera UVM fixture from a Verilator sparse checkout)
      and `run` (`--binary`, gated on `UVM_HOME`). The env **elaborates clean**
      with OSS Verilator 5.047.
- [x] `make run` (`--binary`) **passes**: the scoreboard reports
      "PASS: 7 requests round-trip + translation OK" (0 UVM_ERROR). Getting there
      needed two testbench fixes: (a) the S2M responder drives valid and HOLDS it
      across clock edges until ready is sampled (an earlier set-valid-and-pop in
      one delta collapsed the beat so the bridge never saw it); and (b) stimulus
      waits for bring-up (tag-pool init + bridge-open) before the first request,
      so it is not stalled with an unstable `chi_req_ready` during reset. The run
      is heavy (UVM PCH build), so it stays OUT of the OSS CI gate — the
      `uvm-lint` elaborate is the gate; `run` is a large-runner / local check.
- [ ] Commercial-sim (Xcelium/VCS) reuse of the same SV sources — later.

# Roadmap v2 (Phases 5–8) — post-functional hardening

Phases 0–4 delivered a functionally complete, multi-tier-verified bridge (sim +
pyuvm + fcov + line-coverage + SVA + full-width formal + SV-UVM). Roadmap v2
takes it toward a robust, characterized, feature-complete, implementation-ready
IP. The four workstreams are **error robustness**, **performance**, **new
protocol features**, and **implementation signoff**.

## Sequencing rationale (why this order is efficient)

The ordering is chosen so each phase's work is done once, on the right version of
the RTL, and reused downstream:

1. **Front-load the cheap, RTL-shape-independent checkers.** A structural
   **CDC-lint** gate is added first (Phase 5.0): it is fast, needs no new RTL, and
   catches clock-crossing mistakes before feature work multiplies the crossings.
2. **Build + verify error handling before adding features** (Phase 5). The
   structured-flit refactor left the error paths stubbed (`err_inj_en` idle, no
   flit CRC, `RESPERR` hardwired `OK`, `crc_err_cnt` never incremented), so the
   error surface must be *built*, then locked down by DV, *before* new features
   add more error paths to it.
3. **Stand up performance/observability measurement early** (Phase 6) so there is
   a **baseline** before any feature changes the datapath, and the same harness
   re-measures each later change. (It also fixes the latent `max_occ_rsp` probe,
   which is reset but never updated today.)
4. **Add new protocol features after** the error DV and perf baseline exist
   (Phase 7): every new feature is then verified against a strong error/coverage
   suite and its perf impact is quantified with the Phase 6 harness.
5. **Signoff last** (Phase 8), on the final feature-complete RTL, so timing/area/
   power and full CDC analysis are not invalidated by later RTL churn.

**Shared infrastructure built once, reused across phases:** an *instrumented*
pyuvm env extension — per-transaction timestamps (latency), egress/ingress beat
counters (throughput), FIFO-occupancy probes, and pluggable error injectors on
both interfaces — underpins both the fault-injection tier (Phase 5) and the perf
harness (Phase 6), and is extended (not rewritten) for the new features (Phase 7).
Each phase lands as 1–3 PRs and keeps **every** existing gate green at each step
(the established discipline: lint / regress / pyuvm / fcov / coverage / sva /
formal / formal-fullwidth / synth / uvm-lint / verible).

## Phase 5 — error robustness & fault-injection campaign

Build out and then exhaustively verify the error-handling paths.

- [x] **5.0 CDC-lint gate (early checker).** `make cdc` (`verification/cdc/`)
      builds a flattened Yosys JSON netlist with the sanctioned CDC primitives
      (`async_fifo`, `cdc_sync`, `reset_sync`, `credit_pulse_sync`) kept as
      blackboxes, and `tools/cdc_check.py` proves the structural property: no
      register's data/enable/reset cone reaches a register (or RAM read) in the
      other clock domain except through one of those primitives — i.e. every
      crossing uses a vetted synchronizer and inline crossings are rejected. A
      `selftest` asserts the checker FLAGS a known-bad crossing
      (`bad_cdc_fixture.v`) so the gate can never go vacuous. New `cdc` CI job;
      a permanent guard for the feature work that follows. (Scope: it trusts the
      primitives' internal correctness, which the standalone async_fifo/cdc_sync
      formal proofs already cover.)
- [ ] **5.1 Re-plumb flit integrity.** Add a CRC/parity field to the CHI/CXL flit
      maps (defs), generate it on ingress and check it on egress, and drive the
      dead `err_inj_en` injector to corrupt a flit so the checker fires. Increment
      the (currently dead) `crc_err_cnt`.
- [ ] **5.2 Error responses.** Map detected errors to CHI `RESPERR` (`RespErr`/
      `DataErr`): bad CRC, unknown/illegal CXL response opcode, and DRS/RwD
      **poison** → poisoned CompData / `RespErr`. Replace the hardwired
      `CHI_RESPERR_OK` with real error propagation. Handle a response with an
      unknown/stale tag (no matching outstanding request) as a dropped/flagged
      event rather than a silent mis-route.
- [ ] **5.3 Fault-injection test tier.** A `verification/pyuvm/test_faults.py`
      (+ `FaultSeq`) driving each error class through the instrumented env, with
      a gold-model reference for the expected `RESPERR`/poison and a `error`
      covergroup (`coverage_model`) gated to 100% (CRC-err, poison-in/out,
      illegal-opcode, unknown-tag, link-down-mid-transaction, FIFO-overflow-guard).
- [ ] **5.4 Error SVA + formal.** Bound SVA assertions (RESPERR only on a real
      error; never on a clean path) under `--assert`, and formal safety properties
      (a corrupted/poisoned beat always yields an error response; an error never
      corrupts an unrelated transaction) added to the `prove` task.

## Phase 6 — performance & observability characterization

Quantify throughput, latency and buffering; give the IP real signoff numbers.

- [ ] **6.1 Fix + extend observability.** Make `max_occ_rsp` actually track the
      response-side occupancy (today it is reset but never updated); expose
      per-class in-flight counts and a cumulative transaction counter as
      status outputs for the harness to sample.
- [ ] **6.2 Perf harness.** An instrumented pyuvm test
      (`verification/pyuvm/test_perf.py`) that tags each request with an issue
      timestamp and each response with a completion timestamp, and reports
      **sustained throughput** (txn/1000-cyc, beats/cyc), **latency**
      (min/mean/p99, read vs write), **credit/occupancy efficiency**, and
      **backpressure stall %** — emitted as a `perf.json` + a Markdown table
      artifact (mirroring the `fcov`/coverage report tooling in `tools/`).
- [ ] **6.3 Parameter sweeps.** Sweep `FIFO_DEPTH` / `POSTED_CREDITS` /
      `NP_CREDITS` and the clk:cxl_clk ratio; produce a small perf table showing
      the knee (where more buffering stops helping) to guide default sizing. A
      non-gating `perf` CI job publishes the report as a build artifact.

## Phase 7 — new protocol features

Extend functionality/fidelity on the now-hardened, characterized base. Each
sub-item is independently scoped, implemented, and rolled through **all** DV
tiers (gold model, coverage, fault-injection, perf re-measure, SVA, formal).

- [ ] **7.1 QoS / ordering-aware egress.** Carry the CHI `QoS` field through the
      bridge and make the M2S egress QoS-aware (priority among ready requests),
      preserving per-address ordering guarantees; add ordering + QoS covergroups
      and an SVA/formal no-reorder-within-address property. (Scope note: pick
      strict-priority vs weighted before building.)
- [ ] **7.2 Additional CXL.mem opcodes.** Add `MemSpecRd` (speculative read) and
      `MemInv`/`MemInvNT` handling, and the CHI opcodes that map to them, with
      gold-model translations and coverage bins.
- [ ] **7.3 Atomics (stretch).** CHI atomic ops (`AtomicStore`/`AtomicLoad`/
      `AtomicSwap`/`AtomicCompare`) mapped to the CXL.mem BI/atomic flow, if the
      target device model supports it — scoped after 7.1/7.2 land.

## Phase 8 — implementation signoff

Take the final, feature-complete RTL to physical readiness (open-tool flow).

- [ ] **8.1 Timing constraints.** Author an SDC (`constraints/chi_to_cxl.sdc`):
      the two async clocks + false-path/max-delay across the CDC boundaries,
      I/O delays, and a target period per domain.
- [ ] **8.2 Gate-level synthesis to a PDK.** Extend the Yosys flow to map to an
      open standard-cell library (Nangate45 or Sky130 HD), and run **OpenSTA**
      for setup/hold at the SDC constraints — report Fmax, WNS/TNS, and cell
      area/count. A `synth-pnr`/`sta` CI job publishes the reports.
- [ ] **8.3 CDC signoff.** Promote the Phase 5.0 CDC-lint to a full structural
      CDC signoff report (all crossings classified, synchronizer depth checked,
      no unsynchronized multi-bit crossings outside the Gray-coded FIFOs).
- [ ] **8.4 Power estimate (stretch).** A switching-activity-driven power
      estimate from a representative perf run, for a rough mW/GBps figure.

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
