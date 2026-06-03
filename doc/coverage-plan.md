# chi_to_cxl_bridge — Coverage Plan

The bridge is verified at three complementary coverage levels. This document
describes each and lists the **functional** coverage model (PyVSC) in detail.

| Level | Tool | Target | Where |
|:---|:---|:---|:---|
| Code (line/toggle) | Verilator `--coverage` | ≥ 80% line (currently 100%) | `make coverage` (`sim/sim_main.cpp`) |
| Functional | PyVSC (`vsc`) via cocotb | 100% of the model below | `make cocotb` (`verification/cocotb/`) |
| Formal | SymbiYosys `cover` | reachability of key states | `make formal` (`verification/formal/`) |

Functional coverage answers "did we exercise every protocol-relevant scenario?",
which line coverage cannot: e.g. each opcode mapping, each completion status, and
the CRC-good vs CRC-bad path per response kind.

## Functional coverage model (PyVSC)

Implemented in `verification/cocotb/coverage.py`, sampled from the gold-checked
cocotb transactions in `verification/cocotb/test_chi_to_cxl_bridge.py`.

### ReqCoverage — CHI request → CXL.mem M2S translation

Sampled once per accepted CHI request.

| Coverpoint | Bins | Intent |
|:---|:---|:---|
| `cp_req_kind` | READ, WRITE, ATOMIC, DATALESS | every CHI request class is issued |
| `cp_cxl_op` | MEMRD, MEMRDS, MEMWR, MEMWRPTL, MEMINV | every translated CXL.mem M2S opcode is produced |
| `cp_route` | non-posted, posted | both FIFO-routing classes are exercised |

`cp_cxl_op` implicitly covers the opcode sub-decode: READ→MEMRD vs ReadOnce→MEMRDS,
and WRITE→MEMWR vs WriteNoSnpPtl→MEMWRPTL; ATOMIC and DATALESS both→MEMINV.

### RspCoverage — CXL.mem S2M response → CHI response translation

Sampled once per accepted CXL.mem S2M flit.

| Coverpoint | Bins | Intent |
|:---|:---|:---|
| `cp_rsp_kind` | DRS, NDR, DBID | every S2M response kind is received |
| `cp_status` | OK, ERR | both completion statuses are carried through |
| `cp_crc` | bad, good | both the clean and corrupted link-CRC paths fire |
| `cp_chi_rsp` | COMPDATA, COMP, DBIDRESP, INVALID | every translated CHI response kind is produced |
| `cr_kind_crc` | cross(`cp_rsp_kind`, `cp_crc`) | each S2M kind seen with **both** good and bad CRC (6 combos) |

The `cr_kind_crc` cross is the key functional goal: it proves the CRC integrity
check (and its INVALID-completion fallback) is exercised independently for the
data, no-data, and DBID response kinds.

## Closure strategy

- **Directed tests** issue one of each request kind/opcode and each response
  kind, sanity-checking the gold model.
- **`test_random_soak`** drives 120 randomized, gold-checked transactions for
  breadth (random opcodes, statuses, and ~25% CRC corruption).
- **`test_coverage_closure`** deterministically drives the specific corner
  combinations (every S2M kind × {good, bad CRC} × {OK, ERR}) so the model
  reaches 100% regardless of the random seed.
- **`test_coverage_report`** prints the report, writes the UCIS XML DB
  (`cov.xml`), and gates on `COV_GOAL` (default 100%).

## Not yet modeled (roadmap — see PLAN.md)

- Backpressure / FIFO-occupancy coverage (req/rsp stall depth, near-full credit
  states) — currently exercised functionally but not in a covergroup.
- Clock-ratio coverage in cocotb (kept at 1:1 here; ratios are covered by the
  directed TB and the async_fifo proof).
- Cross of `cp_req_kind` × `cp_route` (partially reachable by construction —
  only WRITE is posted — so left out of the gated model).
