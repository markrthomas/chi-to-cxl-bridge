# Random regression (Swarm B)

Seeded random CHI traffic through the existing pyuvm env on Verilator (cocotb 1.9). The
checker is the existing `BridgeScoreboard` (`verification/pyuvm/env.py`, gold model
`verification/common/models/bridge_model.py`): no new checker lives here.

Files: `rr.py` (build/run/triage/replay), `rr_test.py` (stimulus), `sim.mk` (cocotb build),
`corpus.json` (replay entries + backlog), `runs/` (git-ignored output), `build/` (sim build).

## Contract
- `make rr-build` - compile the Verilator model once (`build/sim_build`).
- `make rr N=<jobs> JOBS=<parallel> [SEED=<base>]` - job i uses seed `SEED+i` (defaults N=20 JOBS=2 SEED=1).
  Builds first (serial, no-op if current), then writes `runs/<UTC>/results.jsonl`:
  `{"job","seed","config","status","signature","log","repro"}`; prints
  `rr run: <dir> seed_base=<s> jobs=<N> fail=<F>`; exit non-zero iff F > 0.
- `make rr-triage RUN=<dir>` - clusters FAILs by normalised signature (numbers/hex masked): one line per
  cluster with count, first seeds and a repro command. No RUN = latest run.
- `make rr-replay` - reruns every `corpus.json` entry; `"fixed": true` entries must PASS (the gate).
  Entry fields: `id`, `seed`, `fixed`, optional `note` and knob overrides (`profile`,`bp`,`gap`,`n`).

## Knobs (all derived from the seed by `rr.knobs(seed)`, so the seed alone reproduces a job)
| knob | values | effect |
|---|---|---|
| `profile` | mix, read, write, burst | read/write ratio (50/15/85/50 % writes); burst = mostly max-length bursts |
| `bp` | 0, 20, 50, 80 | % of cycles CXL req/rwd ready and CHI rsp/comp ready are low |
| `gap` | 0, 2, 8 | max random idle clk cycles between requests |
| `n` | 20..60 | number of transactions (distinct random TxnIDs, random 64B-aligned addr, random 512-bit write data, burst 1..MAX_BEATS, random opcode) |

Determinism: all draws come from `random.Random(seed)`; two runs of seed 37 gave an identical scoreboard line
and sim time. Env `RR_TIMEOUT` (default 300 s) bounds a job; a hang is signature `TIMEOUT (hang)`.
Single repro: run the `repro` command from `results.jsonl` (cocotb log on stdout).

## Teeth (verified at bootstrap)
Mutation: flip one RwD data bit in `translate_chi_wr_to_cxl` (`src/chi_to_cxl_bridge.v`) -> `make rr N=20`:
20/20 FAIL, one cluster `write #N beat N: M2S RwD Data mismatch`. Restored -> `make rr N=10` fail=0.

## Stimulus backlog (also in corpus.json `backlog`)
- B1 randomized CXL responder latency / out-of-order S2M completion
- B2 random link_up / reset mid-traffic (needs scoreboard to model drops)
- B3 CHI snoop traffic interleaved (extend scoreboard with snoop path)
- B4 random WrData timing/interleave across writes
- B5 TxnID reuse after completion (>256 txns, tag-pool wrap)
- B6 error/CRC injection (blocked on Phase 5.1 RTL, owner-held)
- B7 randomize WrData byte-enable/poison (extend model + check together)

Rule: extend the golden model/scoreboard and the stimulus together; keep existing seeds' behaviour bit-identical.
