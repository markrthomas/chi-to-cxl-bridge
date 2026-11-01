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

## Agent swarms (repo notes)
The swarm itself is the shared kit described in the block below; this repo's profile is `.claude/swarm.env`
(envs: `sim cocotb pyuvm uvm`; gate: `make check`; RTL in `src/`; no cross-check target). There is no random regression yet:
`RR_STATUS=bootstrap`, so the first Swarm B run builds `make rr-build/rr/rr-triage/rr-replay` under `verification/random/`
(rr-bootstrap skill) and opens a PR for it.

<!-- swarm-kit:begin (managed by markrthomas/dv-swarm-kit sync.sh — edit the kit, not this block) -->
## Agent swarms, run targets and tokens (swarm-kit)

This repo carries the shared **DV swarm kit** (`markrthomas/dv-swarm-kit`, version in `.claude/swarm-kit.version`).
Its repo-specific settings are **`.claude/swarm.env`** (`make swarm-profile` prints them); everything else in the
kit is identical across repos — change it in the kit and re-sync, never fork it here.

- **Swarm A** — end-to-end re-verification: `make swarm` (`docker/swarm-task.md`; swarm-manager + one
  dv-env-tester per `DV_ENVS` entry + infra-agent + dv-runner).
- **Swarm B** — random regression: `make swarm-rr` (`docker/rr-swarm-task.md`; rr-manager + rr-runner / rr-triage /
  rr-debugger / rr-test-author). With `RR_STATUS=bootstrap` it first builds `make rr-build/rr/rr-triage/rr-replay`
  (the `rr-bootstrap` skill), then flips the flag to `present`.
- **Plan-driven swarm** — write `docs/SWARM_PLAN.md` with front-matter `status: ready` and push it to `main`
  (`.github/workflows/plan-swarm.yml` runs `docker/plan-swarm-task.md`; reset to `status: draft` after it lands).
- Model provider: `SWARM_MODEL_PROVIDER=anthropic` (default) or `kimi` (`docker/provider-env.sh`; kimi sends repo
  contents to Moonshot - never for proprietary IP). One-off headless task: `docker/entrypoint.sh agent "<task>"`.
- Status board: `make board`; workers report via `python3 tools/swarm/board.py` (the `board-report` skill).
- Heavy targets (`HEAVY_TARGETS`) run one at a time: `make heavy T=<target>`. Headless Bash is limited to
  `.claude/settings.json`. `make swarm-dry` shows what a swarm run would execute; `make swarm-kit-check` checks drift.

Doctrine (all agents): verify every claim against a real artifact ("no artifact = not verified"); never weaken or skip
a checker to get green; a skip is "not run", not a pass; keep the RTL assertion-free; DUT behaviour changes are the
owner's call (write them up, don't merge them); branches `swarm/<date>-<topic>`; never push to `main`, never force-push.
Return findings as verdict + evidence (file:line / command + 3-10 line excerpt) + next step — no log dumps.

**Where it runs** (same image everywhere: the Dockerfile `tools` stage, plus the repo for `full`):
| where | how | credentials |
|---|---|---|
| GitHub Actions | Actions → **swarm** → Run workflow (task: Swarm A or B) | repo secret `CLAUDE_CODE_OAUTH_TOKEN` |
| Codespaces | open a Codespace (`.devcontainer/`), then `make swarm`, `make swarm-rr` or `make batch` | Codespaces secret `CLAUDE_CODE_OAUTH_TOKEN`; `GITHUB_TOKEN` is injected |
| Railway | batch service built from `railway.toml` (weekly cron); swarm service: start command `docker/entrypoint.sh swarm [--task docker/rr-swarm-task.md]` | service variables `CLAUDE_CODE_OAUTH_TOKEN` (swarm only) and `GITHUB_TOKEN` (fine-grained PAT: this repo, Contents read+write) |

Batch results go to the `metrics-data` branch (`runs/<UTC>-<sha>/`), never to `main`: automatically on Railway
(when `GITHUB_TOKEN` is set), elsewhere only with `PUBLISH_METRICS=1`. Tokens live only in
GitHub/Codespaces/Railway secret stores — never in the repo, the image, a log or a chat.
<!-- swarm-kit:end -->
