# CHI to CXL Bridge — Design Specification

> Experimental RTL. The protocol model is a compact 64-bit abstraction, not a
> full AMBA CHI or CXL.mem wire encoding. See [README](../README.md#known-limits).

## 1. Scope

`chi_to_cxl_bridge` connects an AMBA CHI request port (a Request Node / RN-F or an
interconnect egress port) to a CXL.mem link. It accepts CHI requests, translates
each into a single CXL.mem M2S flit, crosses the two asynchronous clock domains,
and reconstructs CXL.mem S2M responses into CHI response flits.

It does **not** implement CHI coherency (the SNP channel), multi-beat data
payload transport, or full flit framing — these are tracked in
[PLAN.md](PLAN.md).

## 2. Interfaces

All stream ports use a `valid` / `ready` handshake: the producer drives
`valid` + `data`, the consumer drives `ready`; a beat transfers when both are
high. `valid` holds and `data` is stable while a transfer is stalled.

| Port group | Dir | Domain | Signals |
|:---|:---|:---|:---|
| CHI request ingress | in | `clk` | `chi_req_valid/data/ready` |
| CXL command egress | out | `cxl_clk` | `cxl_tx_valid/data/ready` |
| CXL response ingress | in | `cxl_clk` | `cxl_rx_valid/data/ready` |
| CHI response egress | out | `clk` | `chi_rsp_valid/data/ready` |
| Control | in | async | `link_up`, `err_inj_en`, `rst_n` |
| Status | out | `clk` | `drain_done`, `crc_err_cnt`, `drain_cnt`, `max_occ_req`, `max_occ_rsp` |

`rst_n` is a single active-low asynchronous reset, synchronized per domain by
`reset_sync` (async assert, sync deassert).

### Parameters

| Parameter | Default | Meaning |
|:---|:---|:---|
| `WIDTH` | 64 | Packet width (must be 64 for the typed model). |
| `FIFO_DEPTH` | 8 | Per-path async FIFO depth (power of two, ≥ 4). |
| `POSTED_CREDITS` | 8 | Credit pool for the posted (write) request path. |
| `NP_CREDITS` | 8 | Credit pool for the non-posted request path. |
| `RSP_CREDITS` | 8 | Credit pool for the response path. |

## 3. Packet format

A fixed 64-bit format is shared in both directions (see
`src/chi_to_cxl_bridge_defs.vh`):

```
 63   60 59   56 55      48 47           32 31    24 23    16 15     8 7      0
+-------+-------+----------+---------------+--------+--------+--------+--------+
| KIND  | CODE  |   TAG    |   ADDR/BCNT   |  LEN   |   ID   |  AUX   |  MISC  |
+-------+-------+----------+---------------+--------+--------+--------+--------+
```

- **KIND** — request/response kind (CHI or CXL).
- **CODE** — opcode / command sub-op / completion status.
- **TAG** — CHI TxnID / CXL Tag, correlates request and response.
- **ADDR/BCNT** — 16-bit address (carried through unchanged) / byte count.
- **LEN** — burst length / data size.
- **ID** — CHI SrcID / CXL requester or completer ID.
- **AUX** — snoop / order / cache-state attributes.
- **MISC** — CRC-8/CCITT checksum over header bytes `[63:8]`.

## 4. Translation

### 4.1 CHI request → CXL.mem M2S (request path)

| CHI KIND | CHI CODE | CXL CODE | Class |
|:---|:---|:---|:---|
| `READ` | `NOSNP` | `MEMRD` | non-posted |
| `READ` | `ONCE` | `MEMRDS` | non-posted |
| `WRITE` | `NOSNP` / `UNIQUE` | `MEMWR` | posted |
| `WRITE` | `PTL` | `MEMWRPTL` | posted |
| `ATOMIC` | — | `MEMINV` | non-posted |
| `DATALESS` | — | `MEMINV` | non-posted |
| (other) | — | `ERROR` flit | — |

The output flit's CRC byte is computed over the translated header. With
`err_inj_en` asserted, the LSB (CRC bit 0) is flipped to model a link-channel bit
error that the downstream CRC check must catch.

### 4.2 CXL.mem S2M → CHI response (response path)

| CXL KIND | CRC | CHI KIND |
|:---|:---|:---|
| `DRS` (MemData) | ok | `CompData` |
| `NDR` (Cmp) | ok | `Comp` |
| `DBID` | ok | `DBIDResp` |
| any | bad / unknown | `INVALID` (RespErr) |

The completion **status** (`OK` / `ERR`) is carried through in CODE; a CRC
mismatch is counted in `crc_err_cnt` (crossed `cxl_clk → clk` via
`credit_pulse_sync`) and forces an `INVALID` response.

## 5. Flow control & arbitration

- **Credits** are derived from each async FIFO's write-domain occupancy: ingress
  is gated while `occupancy ≥ credits`, so occupancy can never exceed the credit
  pool (proven invariant). No credit-return pulse path exists to drop across the
  CDC boundary.
- **Egress arbiter** (cxl_clk): posted-priority. When both request FIFOs hold
  data, the posted (write) FIFO drains first. The selection is **locked** while a
  beat is in flight (`valid && !ready`) so the chosen flit completes before
  re-arbitration.

## 6. Link state (reset-drain FSM)

```
        link_up                 !link_up                all_empty
 DOWN ───────────▶ UP ───────────────────▶ DRAIN ───────────────▶ DOWN
```

- `open` (ingress enable) is high only in `UP`.
- `drain_done` is high when the FSM is in `DOWN`/`DRAIN` and all FIFOs are empty.
- On link-down the bridge stops accepting new requests and drains in-flight flits
  before declaring `drain_done`; `drain_cnt` counts link-down events.

## 7. Verification

| Flow | Tool | What |
|:---|:---|:---|
| Lint | Verilator `--lint-only -Wall` | all RTL modules |
| Directed + stress | Icarus | self-checking scoreboard, clock ratios 1:1/2:1/1:3, every kind, ordering, link gating, error injection |
| Coverage | Verilator `--coverage` + lcov | 100% line (80% floor gated) |
| Interface SVA | Verilator `--assert` | valid-hold + data-stability + handshake/stall cover on all 4 ports |
| Formal | SymbiYosys (smtbmc) | `credit_counter` / `reset_drain` / `async_fifo` proven (bmc + cover + unbounded prove); bridge top bmc depth 24 + cover |
| Synthesis | Yosys | latch / area smoke |

See [PLAN.md](PLAN.md) for the roadmap (close bridge-top `prove`, add cocotb
bench, raise protocol fidelity).
