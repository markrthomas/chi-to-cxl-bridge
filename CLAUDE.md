# chi_to_cxl_bridge — agent guide

A CHI ↔ CXL.mem bridge RTL + multi-tier DV project. This file is the fast restart
pointer for an AI session; **`doc/PLAN.md` is the canonical plan** (its checkboxes
are the source of truth for status).

## Where the work stands
Phases 0–4 (functional bridge, sim + pyuvm + functional coverage + line coverage
+ SVA + full-width formal + SV-UVM) are complete. Roadmap v2 (Phases 5–8) is
underway:
- **Done:** Phase 5.0 — structural CDC gate (`make cdc`).
- **Next (currently HELD by the user):** Phase 5.1 — re-plumb flit integrity
  (add a CRC field to `src/chi_to_cxl_bridge_defs.vh`, generate on ingress + check
  on egress, drive the idle `err_inj_en`, increment the dead `crc_err_cnt`). Then
  5.2 (errors → CHI `RESPERR`/poison — today `RESPERR` is hardwired OK), 5.3
  (fault-injection test tier + error covergroup), 5.4 (error SVA + formal).

See `doc/PLAN.md` "Roadmap v2" for the full Phase 5–8 breakdown and the
sequencing rationale.

## Workflow (please follow)
- Branch off `main`; one logical unit per commit; end commit messages with the
  Co-Authored-By + Claude-Session attribution lines from the session reminder.
- Push, open a PR, wait for **all** CI checks green. The user merges explicitly —
  **do not merge unprompted.** After merge: `git checkout main && git pull` and
  delete the branch.
- Keep **every** gate green at each step.

## Gates / how to run locally
`make lint` · `make sim` / `make stress` (directed, iverilog) · `make pyuvm`
(functional; **use verilator locally — local Icarus is broken**) · `make fcov` ·
`make coverage` · `make sva` · `make formal` · `make formal-fullwidth` (512-bit,
uses `bitwuzla`) · `make cdc` (+ self-test) · `make synth` · `make verible-lint`.

Local-tooling notes:
- pyuvm/fcov runtime is cocotb 1.9.2 on `/usr/bin/python3`; run these under
  **verilator** locally (Icarus clashes with the OSS-CAD python).
- `make verible-lint` needs the Verible binary on PATH; it is **not installed** —
  fetch the pinned release (`VERIBLE_VERSION` in `.github/workflows/ci.yml`) from
  chipsalliance/verible into a scratch dir when you need it locally.
- `uvm-lint` needs `UVM_HOME` (a Verilator UVM fixture) — CI fetches it; not set
  up locally. The `--binary` UVM `run` is memory-heavy; keep it out of the gate.
- CI runs all of the above as jobs (`.github/workflows/ci.yml`): regress, pyuvm,
  fcov, coverage, sva, formal, formal-fullwidth, cdc, synth, uvm-lint, verible.

## Layout
- `src/` — RTL (`chi_to_cxl_bridge.v` top, `_defs.vh` flit maps, `tag_manager.v`,
  CDC primitives: `async_fifo`/`cdc_sync`/`reset_sync`/`credit_pulse_sync`).
- `verification/` — `directed/` (iverilog tb), `pyuvm/` (cocotb+pyuvm env, seqs,
  tests), `uvm/sv/` (SV-UVM + bound SVA + interface), `formal/` (sby), `cdc/`.
- `verification/common/models/` — Python gold model + coverage model.
- `tools/` — coverage scorer, trace compare, `cdc_check.py`.
- `doc/` — `PLAN.md` (roadmap), `design-spec.md`, `coverage-plan.md`.
