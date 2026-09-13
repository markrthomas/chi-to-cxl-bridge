# chi_to_cxl_bridge — Coverage Plan

The bridge is verified at complementary coverage levels, aligned with the DV
environment in `../ucie2-pipe7-bridge`. This document describes each and lists the
**functional** coverage model in detail.

| Level | Tool | Target | Where |
|:---|:---|:---|:---|
| Round-trip / translation | PyUVM scoreboard vs Python gold model | every driven read/write cross-checked | `make pyuvm` (`verification/pyuvm/`) |
| Functional | `cocotb_coverage` | 100% of the model below | `make fcov` (`verification/pyuvm/test_fcov.py`) |
| Code (line/branch) | Verilator `--coverage-line` | ≥ 80% line (currently ~87%) | `make coverage` (scored by `tools/coverage_report.py`) |
| Formal | SymbiYosys `cover` | reachability of key states | `make formal` (`verification/formal/`) |

Functional coverage answers "did we exercise every protocol-relevant scenario?",
which line coverage cannot: e.g. each CHI REQ opcode, each translated CXL.mem
MemOpcode, and each CHI response kind.

## Functional coverage model (`cocotb_coverage`)

Implemented in `verification/common/models/coverage_model.py`, sampled by the
observers in `verification/pyuvm/test_fcov.py` reading the DUT boundary. Every bin
is reachable from the directed round-trip stimulus with the CXL responder
loopback, so the honest target is 100% of the set.

| Coverpoint | Bins | Intent |
|:---|:---|:---|
| `bridge.chi.req_opcode` | ReadNoSnp, ReadOnce, WriteNoSnpFull, WriteNoSnpPtl, WriteUniqueFull | every CHI REQ opcode is issued |
| `bridge.chi.req_kind` | read, write | both request classes exercised |
| `bridge.cxl.m2s_memop` | MemRd, MemRdData, MemWr, MemWrPtl | every translated CXL.mem M2S opcode is produced |
| `bridge.chi.rsp_opcode` | DBIDResp, Comp | both CHI RSP-channel opcodes seen |
| `bridge.chi.compdata` | seen | a CHI CompData beat is returned on a read |
| `bridge.chi.snp_opcode` | SnpOnce, SnpShared, SnpUnique | every host snoop opcode is issued (`test_snoop.py`) |

`bridge.cxl.m2s_memop` implicitly covers the opcode sub-decode: ReadNoSnp→MemRd
vs ReadOnce→MemRdData, and WriteNoSnpPtl→MemWrPtl vs the other writes→MemWr.

### Backpressure / FIFO-occupancy covergroup (`make fcov`, `test_backpressure.py`)

A separate covergroup (`BP_POINTS`, its own 100% gate so it does not perturb the
functional set) driven by the dedicated stall stimulus. Each bin fires on the
first occurrence of an observable backpressure condition:

| Coverpoint | Condition |
|:---|:---|
| `bridge.bp.req_stall` | `chi_req_valid & !chi_req_ready` (credit/FIFO full) |
| `bridge.bp.wrdata_stall` | `chi_wr_data_valid & !chi_wr_data_ready` (write-data FIFO full) |
| `bridge.bp.tx_req_stall` | M2S Req presented but the link is not ready |
| `bridge.bp.tx_rwd_stall` | M2S RwD presented but the link is not ready |
| `bridge.bp.ndr_stall` | S2M NDR held off by a full response FIFO |
| `bridge.bp.drs_stall` | S2M DRS held off by a full response FIFO |
| `bridge.bp.req_fifo_full` | a request FIFO reached its credit/depth limit |

## Round-trip / translation cross-check (PyUVM scoreboard)

`verification/pyuvm/env.py` drains four analysis streams per run and checks, against
the independent gold model in `verification/common/models/bridge_model.py`:

1. **round-trip identity** — every driven read gets a CompData with the matching
   TxnID and the expected read data; every driven write gets a Comp with the
   matching TxnID.
2. **request translation** — the DUT's M2S Req/RwD stream (per channel, in order)
   matches the model's translation of the driven CHI requests (MemOpcode, Addr,
   and write Data).

## Bound SVA (`make sva`)

`verification/uvm/sv/chi_to_cxl_sva.sv` binds a checker into the bridge and is
verified under the round-trip run (Verilator `--assert`): M2S/CHI handshake
stability, a legal-opcode guard on the CHI RSP channel, and a **no-phantom-Req**
property (M2S Req MemOpcode ∈ {MemRd, MemRdData}) — the per-cycle guard for the
egress qualifier fix.

## Closure strategy

- **`test_roundtrip`** issues each read/write opcode with the CXL responder
  loopback, and the scoreboard gold-checks every transfer. It alone reaches 100%
  of the functional bin set.
- **`test_random`** drives 24 randomized, gold-checked transactions (distinct
  TxnIDs) for breadth.
- **`test_fcov`** samples the functional model and gates on 100%.

## Not yet modeled (roadmap — see PLAN.md)

- Clock-ratio coverage in the pyuvm tier (kept at 2:3 here; ratios are covered by
  the directed TB and the async_fifo proof).
- Error-injection / RespErr paths — the structured-flit CRC integrity path is not
  re-plumbed yet (`err_inj_en` is idle), so the error-status bins are deferred.
