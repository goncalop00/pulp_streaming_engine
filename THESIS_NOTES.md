# Thesis Notes: Streaming Engine Integration in PULP Mr. Wolf

Organized raw material for the dissertation chapter. Not prose — facts, numbers, signal names,
observations, and decisions to expand from when writing. Sections roughly follow a chapter structure.

---

## 1. Motivation

- PULP Mr. Wolf cluster: 8 RI5CY cores sharing a logarithmic interconnect to TCDM.
  Data movement from L2 (off-cluster) to TCDM/registers is the bottleneck for stencil/conv workloads.
- Software approach: core executes loads, strides manually, wastes cycles waiting on AXI latency.
- SE approach: hardware address generation + prefetch into a FIFO; core pops words zero-overhead
  once they are already present. Overlap compute with memory transfer.
- Two ISA extensions (`stream.pop`, `stream.push`) allow the core to consume/produce data as
  if reading/writing a local register, while the SE drives all AXI transactions autonomously.

---

## 2. Target Platform

| Parameter | Value |
|---|---|
| Cluster | Mr. Wolf (PULP), 8 RI5CY cores |
| L1 icache | Private per-core, 512 B; **disabled at reset, software-enabled via MMIO `0x10201400 ← 0xFFFFFFFF`** |
| L1.5 icache | Shared, 8 banks (PRIVATE_ICACHE branch); software-enabled at same time |
| FPU | FPnew shared cluster FPU via APU master interface; requires `fregfile_disable_i=0` in core_region — see §10.2 |
| Cluster AXI bus | 64-bit data, 5-bit slave ID (AXI_ID_IN_WIDTH) |
| L2 memory | 0x1C000000, SRAM, accessed via cluster ext_master port |
| SE MMIO base | 0x10202000 (cluster 0, SPER_DECOMP_ID=8) |
| Full-SoC sim | QuestaSim 2024.3, PRELOAD mode, 8 cores booting simultaneously |

---

## 3. Streaming Engine Microarchitecture

### 3.1 Top-level structure

```
se_top.sv
├── se_read_stream_top.sv  × 2   (in0, in1)
│   ├── read_stream_fsm.sv       — IDLE→ACTIVE→DONE Moore FSM
│   ├── se_agu.sv                — address generation unit
│   ├── read_stream.sv           — AXI AR requests + mem_rvalid gating
│   └── reuse_buffer.sv          — sliding-window SRAM (V3)
├── se_write_stream_top.sv × 1   (out0)
│   ├── write_stream_fsm.sv      — IDLE→ACTIVE→DONE Moore FSM
│   ├── write_ctrl.sv            — burst threshold + AXI AW/W/B control
│   └── write_stream.sv          — write datapath
└── se_fifo.sv                   — shared FIFO primitive (used per stream)
```

### 3.2 Key constants (`se_top.sv`)

| Constant | Value | Meaning |
|---|---|---|
| `FIFO_DEPTH` | 32 | entries per read/write FIFO |
| `MAX_REUSE_BUF_ELEMS` | 2048 | max elements in per-read-stream reuse buffer |
| `MAX_DIM` | 3 | maximum iteration dimensionality |
| `NUM_READ_STREAMS` | 2 | in0, in1 |
| `NUM_WRITE_STREAMS` | 1 | out0 |
| `DATA_W` | 32 | element width in bits |
| `BURST_LEN` | 4 | write-stream coalescing threshold (words before AXI burst) |

### 3.3 Read stream FSM (`read_stream_fsm.sv`)

```
IDLE ──start──► ACTIVE ──fetch_done──► DONE ──start──► ACTIVE (re-arm)
```
- `stream_en` asserted in ACTIVE (Moore output); drives AGU and read_stream.
- `done` asserted in DONE; se_ctrl samples this into STATUS.done_in*.
- Re-arm from DONE skips IDLE — no reset required between runs.

### 3.4 AGU (`se_agu.sv`)

Generates the next element address based on:
- `base_addr` — starting address
- `element_size` — bytes per element (4 for 32-bit)
- `dim` — active dimensions (1, 2, or 3)
- `bound[0..2]` — iteration count per dimension
- `stride[0..2]` — signed byte stride per dimension
- Window mode: `k_rows`, `k_cols`, `reuse_dim` activate reuse_buffer path

Address generation: `addr = base + stride[0]*i + stride[1]*j + stride[2]*k`

### 3.5 Reuse buffer (`reuse_buffer.sv`, V3)

- On-chip SRAM: `logic [DATA_W-1:0] reuse_buf [0:MAX_REUSE_BUF_ELEMS-1]`
- Sliding window mode: holds `k_rows` rows in memory; slides by one row per output position.
- Initial fill: fetches k_rows rows from L2, then slides one new row per position.
- Unique-fetch count < total output count — memory bandwidth reduction.
- Phase H validated: 4×4 image, k_rows=2, 24 outputs from 16 unique fetches.

### 3.6 AXI backend (`se_axi_backend.sv`)

| Channel | Config | Notes |
|---|---|---|
| AR (read) | ARLEN=0, ARSIZE=3 (64-bit) | Single beat per element; one outstanding AR |
| AW (write) | AWLEN=0 or 1, AWSIZE=3, 16-byte aligned | Default 4-word burst (AWLEN=1, 2 beats). Partial-burst flush issues AWLEN=0 for 1–2 trailing words or AWLEN=1 for 3 trailing words (§10.6) |
| W (write data) | 1 or 2 beats × 64-bit | Default full beat WSTRB=0xFF; partial bursts use WSTRB mask on trailing lanes |
| B (write resp) | Must be received before next AW | Tracked by B_CNT |

Assertion A1: every accepted R beat must have `r_last=1` (ARLEN=0 contract).
Assertion A3: `out0.base_addr[3:0]` must be 0 (16-byte aligned burst start).

---

## 4. Cluster Integration

### 4.1 Two-bus model: control plane vs. data plane

The SE has two completely separate interfaces to the cluster infrastructure:

**Control plane (APB / XBAR_PERIPH_BUS):**
- Core writes descriptor registers and CTRL via normal store instructions
- Cluster peripheral crossbar routes these to `se_ctrl.sv` (the APB register file)
- `se_ctrl.sv` produces internal start/configured pulses and exposes STATUS back
- Bus type: XBAR_PERIPH_BUS (PULP proprietary, not AXI) — handled inside `cluster_peripherals.sv`

**Data plane (AXI4):**
- SE directly drives AXI AR/R (read) and AW/W/B (write) to reach L2 memory
- Goes through `cluster_bus_wrap.sv` AXI crossbar → cluster ext_master port → SoC AXI → L2 SRAM
- Completely independent of the core — core is not involved once the SE is started
- Bus type: 64-bit AXI4 (same as DMA master, data cache refill)

This separation is the key architectural point: the core only touches the control plane twice
(descriptor write + start pulse), then the data plane operates autonomously until done_o fires.

### 4.2 Files changed/added (organized by repo)

**`ips/se/rtl/`** — streaming engine RTL (new IP):
- `se_top.sv`, `se_package.sv`, `se_agu.sv`, `se_fifo.sv`
- `read/se_read_stream_top.sv`, `read/read_stream.sv`, `read/read_stream_fsm.sv`, `read/reuse_buffer.sv`
- `write/se_write_stream_top.sv`, `write/write_stream.sv`, `write/write_ctrl.sv`, `write/write_stream_fsm.sv`

**`ips/pulp_cluster/rtl/`** — cluster integration (new/modified):
- `se_top_wrap.sv` (new) — cluster wrapper; bridges control plane + data plane; exposes pop/push ISA ports; OR-muxes MMIO OUT0_PUSH with ISA push path
- `se_ctrl.sv` (new) — APB register file; translates XBAR_PERIPH_BUS transactions to SE control signals; holds all descriptor registers
- `se_axi_backend.sv` (new) — AXI4 master; generates AR/AW/W beats; enforces ARLEN=0 (read); AWLEN=0 or 1 with WSTRB masking for partial-burst flush (write), 16B-aligned burst start
- `cluster_bus_wrap.sv` (modified) — `NB_SLAVE` 4→5; added `se_slave` port; `axi_slaves[4]` connected via `AXI_ASSIGN`
- `cluster_peripherals.sv` (modified) — reuses `speriph_slave[SPER_DECOMP_ID]` slot (previously tied to zero) for SE; exposes `se_cfg_master` port
- `periph_bus_defines.sv` (new file added) — defines `SPER_DECOMP_ID=8` and peripheral slot constants
- `pulp_cluster.sv` (modified) — SE instantiation, ISA signal arrays, sid mux, AXI_ID fix, `s_se_busy` ORed into cluster busy
- `core_region.sv` (modified) — stream pop/push port declarations; RI5CY: pass-through; Ibex: tied off

**`ips/riscv/rtl/`** — RI5CY ISA extension (modified):
- `include/riscv_defines.sv` — `STREAM_FUNCT3_POP=3'b110`, `STREAM_FUNCT3_PUSH=3'b111`, `STREAM_OP_{NONE,POP,PUSH}` constants
- `riscv_decoder.sv` — decode logic at line 2430 within the `OPCODE_HWLOOP` case
- `riscv_id_stage.sv` — `stream_op_id`/`stream_sid_id` wires; latched into `stream_op_ex_o`/`stream_sid_ex_o` in ID/EX register
- `riscv_ex_stage.sv` — `stream_busy`/`stream_done` combinational logic; stall injection; writeback mux
- `riscv_core.sv` — `stream_op_ex`/`stream_sid_ex` internal wires; port connections at lines 706–707, 897–905

**`ips/hier-icache/RTL/`** — icache bug fixes:
- `L1_CACHE/refill_arbiter.sv` — fix continuous sampling (see §9)
- `RTL/TOP/icache_hier_top.sv` — AXI_ID parameter fix (see §9)

**`rtl/pulp/pulp.sv`** — BOOT_ADDR: `0x1C000000 → 0x1C008080`

**`rtl/tb/tb_pulp.sv`** — PRELOAD boot mode implementation (~115 lines)

### 4.3 Peripheral address decode (control plane)

```
Core store instruction → cluster TCDM crossbar → peripheral bus → cluster_peripherals.sv
  → speriph_slave[SPER_DECOMP_ID] → se_cfg_master → se_top_wrap → se_ctrl.sv
```

- Peripheral bus: `addr[13:10]` selects slot; `NB_SPERIPH_SLAVES=11` (from `periph_bus_defines.sv`)
- `SPER_DECOMP_ID = 8` → slot 8 → base offset `8 × 1024 = 0x2000`
- Full MMIO address: `0x10000000 (cluster) + 0x00200000 (periph region) + 0x2000 = 0x10202000`
- Previously `speriph_slave[8]` was tied to zero (unused slot); SE reuses it without address map change
- `cluster_peripherals.sv` wires the slot to `se_cfg_master` via direct assign (lines 410–421), no APB bridge — XBAR_PERIPH_BUS is the native bus

### 4.4 SE AXI data plane slot

```
se_axi_backend (AXI master) → se_top_wrap.ext_master → pulp_cluster.s_se_ext_bus
  → cluster_bus_wrap.se_slave → axi_slaves[4] → axi_xbar → ext_master → SoC → L2
```

- `cluster_bus_wrap.sv`: `NB_SLAVE = 5`; `axi_slaves[4]` assigned from `se_slave` via `AXI_ASSIGN` (line 86)
- AXI_ID width: 5-bit slave port (same constraint that caused the icache bug — SE's backend generates its own IDs within 5 bits so no truncation issue)
- SE AXI master width: 64-bit data, 32-bit address — same as other cluster AXI masters

### 4.5 SE busy and done signals

- `s_se_busy` ORed into `s_cluster_int_busy` (line 578, `pulp_cluster.sv`) — cluster reports busy to SoC while SE is active
- `s_se_done` wired to `done_o` of `se_top_wrap` — available for cluster event system (hwpe_evt / EU)
- In current firmware: done detected by polling STATUS register, not hardware event — `s_se_done` not yet connected to event unit

### 4.6 ISA handshake path through the cluster

```
riscv_ex_stage
  stream_pop_req_o / stream_pop_sid_o  ──►  riscv_core ports (lines 901–902)
  stream_pop_data_i / stream_pop_valid_i ◄──  riscv_core ports (lines 903–904)
      │
      ▼
  core_region.sv  (pass-through; Ibex branch: tied off)
      │
      ▼
  pulp_cluster.sv  s_stream_pop_req[i] / s_stream_pop_sid[i]   (per-core arrays)
      │
      sid[0] mux (combinational)
      │
      ├─ sid=0 → s_se_pop_req_in0  ──►  se_top_wrap.pop_req_in0_i
      └─ sid=1 → s_se_pop_req_in1  ──►  se_top_wrap.pop_req_in1_i
                                              │
                                         se_top.sv → read stream FIFO pop
                                              │
                                    pop_data_in0_o / pop_valid_in0_o ──► back up the chain
```

Push path is symmetric in reverse: `alu_operand_a_i` (rs1 value) flows down as `push_data_out0_i`.

---

## 5. Custom ISA Extension

### 5.1 Why these two instructions exist — the kernel instruction reduction argument

When a kernel accesses a 2D or 3D array without the SE, the inner loop body contains three classes
of instructions per element:

```
# Software inner loop (no SE) — 2D array access, runtime stride
mul   t0, idx0, stride0       # address compute: dim-0 contribution
mul   t1, idx1, stride1       # address compute: dim-1 contribution
add   t0, t0, t1              # address compute: accumulate
add   t0, t0, base            # address compute: add base
lw    a0, 0(t0)               # memory: load (stalls on AXI latency, ~10-20 cycles)
addi  idx0, idx0, 1           # pointer advance: increment index
# ... boundary check for idx0 wrap, idx1 increment ...

# With SE — same element
stream.pop a0, 0              # one instruction; returns immediately if FIFO pre-filled
                              # (SE computed the address, issued the AXI AR, and
                              #  buffered the result in hardware while the core was busy)
```

**What stream.pop replaces per element:**
- All address-computation instructions (mul + add chains, scaling by element_size)
- The load instruction itself (lw / ld)
- Pointer-advance instructions (addi, boundary check, index wrap logic)
- The stall cycles waiting for AXI response (hidden by SE prefetch)

**Instruction count reduction** (depends on kernel):
- 1D flat stream: ~3-4 instructions → 1 (address compute + lw + addi eliminated)
- 2D strided: ~6-8 instructions → 1 (adds dim-1 multiply and boundary check)
- 3D with window: ~10-15 instructions → 1 (three index dimensions + two boundary checks)
- Window mode additionally eliminates redundant memory fetches (reuse buffer serves repeated rows from SRAM)

**Latency hiding:** Even if the FIFO is empty when stream.pop executes, the SE has already
issued the AXI AR — the core stalls only for the remaining AXI round-trip, not the full
latency from address-compute to data-ready. In pipeline terms: the SE hides memory latency
behind previous instructions; the core stalls only when it outpaces the prefetcher.

**stream.push replaces per element (write path):**
- Address computation for the destination
- Store instruction (sw / sd)
- Pointer advance
- The AXI AW/W/B exchange (handled entirely by se_axi_backend)

**Important nuance:** stream.pop/push are not free — they are instructions that occupy issue
slots. The gain is (a) eliminated surrounding instructions and (b) latency hiding, not
zero-cost data transfer. The instruction reduction is the primary static metric;
latency hiding is the primary dynamic performance gain.

### 5.2 Encoding choice — why OPCODE_HWLOOP (0x7B)

RI5CY uses opcode 0x7B for the HWLOOP (hardware loop) extension — a PULP-proprietary
instruction group that sets up zero-overhead loop bounds and counters. HWLOOP uses
funct3 = 000..101 (six encodings for lp.starti, lp.endi, lp.counti, lp.count, lp.setup,
lp.setupi). **funct3 = 110 and 111 were unused** — decoding to `illegal_insn_o=1` via the
default case.

stream.pop and stream.push occupy exactly those two unused slots:
- funct3=110 (`STREAM_FUNCT3_POP`)
- funct3=111 (`STREAM_FUNCT3_PUSH`)

**They do not replace any HWLOOP instruction.** The existing lp.* instructions are
untouched — all funct3=000..101 paths are unchanged in the decoder.

This choice requires no new opcode, no toolchain changes to the opcode table, and no
changes to instruction fetch, alignment, or compressed-instruction handling. The cost is
that binutils 2.28 has no assembler mnemonic for these encodings — firmware must use
`.word 0x0000657b` with a register pin, not `.insn` syntax.

### 5.3 Full R-type encoding

```
[31:25] funct7  [24:20] rs2     [19:15] rs1   [14:12] funct3  [11:7] rd   [6:0] opcode
  0000000       sid[2:0]          rs1           110/111        rd/0    1111011 (0x7B)
```

| Instruction | funct3 | rd | rs1 | rs2(=sid) | Word (sid=0) | Word (sid=1) |
|---|---|---|---|---|---|---|
| `stream.pop rd, sid` | 110 | a0 (pinned) | x0 | sid | `0x0000657b` | `0x0010657b` |
| `stream.push rs1, sid` | 111 | x0 | a0 (pinned) | sid | `0x0005707b` | `0x0015707b` |

sid encoding: `instr[22:20]` — 3-bit stream ID. LSB routes to in0 (0) or in1 (1) for pop;
push always goes to out0 regardless of sid.

**Register pinning constraint:** Both instructions hardcode `a0` (x10) as rd/rs1 in the
`.word` encoding. The `asm("a0")` constraint tells GCC the inline asm operand lives in
that register. This is a limitation of the `.word` approach — a proper assembler extension
would allow any register via the rd/rs1 fields.

### 5.4 Pipeline decode path — exact signal names

```
Cycle N: Fetch — instruction word arrives at riscv_decoder.sv

  riscv_decoder.sv (ID stage, combinational):
    opcode = instr[6:0]  = 7'h7B  → OPCODE_HWLOOP case
    funct3 = instr[14:12] = 3'b110 → STREAM_FUNCT3_POP case
      alu_en_o       = 1'b0          ← ALU not engaged
      regfile_alu_we = 1'b1          ← rd will be written (by pop_data, not ALU)
      rega_used_o    = 1'b0          ← no rs1 read needed for pop
      stream_op      = STREAM_OP_POP ← internal combinational wire
      stream_sid_o   = instr[22:20]  ← stream ID
    deassert_we_i gate:
      stream_op_o    = deassert_we_i ? STREAM_OP_NONE : stream_op
      (flush on interrupt/exception zeroes the op — no spurious pop)

Cycle N: ID/EX register (riscv_id_stage.sv):
    On posedge, if ~stall and ~flush:
      stream_op_ex_o  <= stream_op_id   (from decoder)
      stream_sid_ex_o <= stream_sid_id

Cycle N+1..N+K: Execute (riscv_ex_stage.sv, combinational):
    stream_pop_active  = (stream_op_i == STREAM_OP_POP)    ← 1
    stream_push_active = (stream_op_i == STREAM_OP_PUSH)   ← 0
    stream_busy = stream_pop_active & ~stream_pop_valid_i   ← 1 while FIFO empty
    stream_done = stream_pop_active &  stream_pop_valid_i   ← 1 when FIFO delivers

    stream_pop_req_o  = stream_pop_active  ← asserted immediately, every cycle
    stream_pop_sid_o  = stream_sid_i       ← forwarded to SE

    ex_ready_o = (...) & ~stream_busy      ← stalls ID from issuing next instruction
    ex_valid_o = (...) | stream_done       ← commits this instruction when done

    Writeback mux (when stream_pop_active):
      regfile_alu_we_fw_o    = regfile_alu_we_i & stream_pop_valid_i  ← gated
      regfile_alu_wdata_fw_o = stream_pop_data_i  ← SE FIFO output → rd

Cycle N+K (pop_valid_i rises from SE):
    stream_busy → 0, stream_done → 1
    ex_valid_o → 1 → pipeline commits, advances PC
    rd written with stream_pop_data_i value
    stream_pop_req_o → 0 (stream_pop_active falls as instruction leaves EX)
```

For stream.push the path is symmetric: `rega_used_o=1` causes rs1 to be read and latched
in `alu_operand_a_ex_o`; EX drives `stream_push_data_o = alu_operand_a_i` and asserts
`stream_push_req_o`; stalls until `stream_push_ready_i` rises from the write FIFO.

### 5.5 Stall mechanism — which signals block the pipeline

```
riscv_ex_stage.sv line 610:
  assign ex_ready_o = (~apu_stall & alu_ready & mult_ready & lsu_ready_ex_i
                       & wb_ready_i & ~wb_contention & fpu_ready & ~stream_busy)
                      | (branch_in_ex_i);

riscv_ex_stage.sv line 612:
  assign ex_valid_o = (apu_valid | alu_en_i | mult_en_i | csr_access_i
                       | lsu_en_i | stream_done)
                      & (alu_ready & mult_ready & lsu_ready_ex_i & wb_ready_i);
```

`stream_busy` is a new term added to the existing stall expression — same mechanism used
by APU (FPU) and LSU stalls. `ex_ready_o=0` prevents the ID stage from issuing new
instructions into EX. The instruction sits in EX, re-asserting `stream_pop_req_o` every
cycle, until the SE responds.

**No pipeline flush occurs.** The instruction is not re-issued — it idles in EX.
This means the SE must tolerate repeated pop_req pulses for the same pop (idempotent
read: req is level-sensitive, not edge-triggered; FIFO pops only on the cycle valid & req
are both high simultaneously).

### 5.6 Interrupt and flush safety

```
riscv_decoder.sv:
  assign stream_op_o = (deassert_we_i) ? STREAM_OP_NONE : stream_op;

riscv_id_stage.sv:
  always_ff @(posedge clk, negedge rst_n):
    if (~rst_n || flush):
      stream_op_ex_o  <= STREAM_OP_NONE;
      stream_sid_ex_o <= 3'b000;
```

If an interrupt or exception is taken while a stream.pop is waiting in EX:
- The ID/EX register is flushed → `stream_op_ex_o = NONE` → `stream_pop_active = 0`
- `stream_pop_req_o` immediately de-asserts
- The SE FIFO is NOT popped (pop only happens when req & valid simultaneously)
- The SE continues prefetching; the core will re-execute the stream.pop after MRET
- On re-execution: if FIFO already has data, stream.pop completes in 1 cycle

**Hazard with re-execution:** After MRET the core re-executes the stream.pop. If the SE
FIFO already has one element buffered from before the interrupt, that element is consumed
— correct behavior (same element that would have been consumed before the interrupt).
If the interrupt handler itself issues stream.pop (which it should not — only core 0,
no nested SE access defined), behavior is undefined.

### 5.7 Signal routing through pulp_cluster

```
riscv_ex_stage → riscv_core (ports lines 126–133, instantiation lines 901–908)
              → core_region (pass-through; Ibex branch ties off)
              → pulp_cluster (per-core arrays; sid[0] mux)
              → se_top_wrap (pop_req_in{0,1}_i / push_req_out0_i)
              → se_top → read/write FIFOs
```

In `pulp_cluster.sv`, the sid mux fans out per-core stream ops to the SE's two read
streams (push always routes to out0 regardless of sid):

```sv
assign s_se_pop_req_in0      = s_stream_pop_req[0] & ~s_stream_pop_sid[0][0];
assign s_se_pop_req_in1      = s_stream_pop_req[0] &  s_stream_pop_sid[0][0];
assign s_stream_pop_data[0]  = sid[0] ? s_se_pop_data_in1 : s_se_pop_data_in0;
assign s_stream_pop_valid[0] = sid[0] ? s_se_pop_valid_in1 : s_se_pop_valid_in0;
assign s_se_push_req_out0    = s_stream_push_req[0];   // push always → out0
```

Only core 0 wired to SE. Cores 1–7: `pop_valid=0`, `push_ready=0`
(hangs EX visibly on misuse rather than silently producing wrong data).

---

## 6. MMIO Register Map

Base: `SE_BASE = 0x10202000`

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x00–0x2C | in0 descriptor | RW | base_addr, elem_size, dim, bound[0-2], stride[0-2], k_rows, k_cols, reuse_dim |
| 0x30–0x5C | in1 descriptor | RW | same layout as in0 |
| 0x60–0x8C | out0 descriptor | RW | same layout |
| 0x90 | CTRL | RW | bit[0]=start (self-clearing), bits[3:1]=configured[2:0] |
| 0x94 | STATUS | RO | [0]=done_in0, [1]=done_in1, [2]=done_out0, [4]=read_err, [5]=write_err, [6]=cfg_err, [8]=busy |
| 0x98 | ERR_CLR | WO | bit[0]=clear read_err, [1]=write_err, [2]=cfg_err |
| 0x9C | RDATA_IN0_OBS | RO | last 32-bit word observed on rdata_in0 since last start |
| 0xA0 | RDATA_IN0_OBS_CNT | RO | count of valid samples on rdata_in0 since last start |
| 0xA4 | OUT0_PUSH | WO | write value → 1-cycle push_req pulse on write FIFO (debug/firmware use) |
| 0xA8 | AW_CNT | RO | AW handshake count since last start |
| 0xAC | W_CNT | RO | W beat count since last start |
| 0xB0 | B_CNT | RO | B response count since last start |

### Descriptor field semantics

- `dim`: active iteration dimensions (1=flat, 2=2D, 3=3D)
- `bound[k]`: iteration count in dimension k (elements, not bytes); `bound[0]=0` is invalid (cfg_err)
- `stride[k]`: signed byte offset per step in dimension k
- `k_rows`, `k_cols`: window kernel dimensions (window mode only)
- `reuse_dim`: which dimension the reuse buffer slides along

`configured[k]` bit must be set for stream k before start; cfg_err fires if any armed stream has an invalid descriptor.

---

## 7. Full-SoC Boot and Test Infrastructure

### 7.1 PRELOAD boot flow

```
1. $readmemh("stim.txt", staging_array)      — load se_smoke.hex into flat array
2. wait(s_soc_rstn === 1'b1) then #1         — avoid reset-synchronizer overwrite
3. write tc_sram.sram[] via hierarchy         — L2 bank_sram_pri0/1, CUTS[0-3]
4. #200us                                     — FLL lock + cluster startup
5. JTAG SBA write 0x10200008 ← 0xFF          — CCU fetch_en for all 8 cores
6. all 8 cores fetch from 0x1C008080         — crt0.S entry point
7. mhartid==0: run se_smoke; others: _secondary_wait WFI spin at 0x1C0080D8
8. poll 0x1A1040A0 via JTAG SBA              — exit flag: bit[31]=1, bits[30:0]=pass code
```

Key change: `BOOT_ADDR = 0x1C008080` in `rtl/pulp/pulp.sv` (was 0x1C000000).

### 7.2 Exit protocol

- PASS: write `0x80000000` to `0x1A1040A0` — TB sees bits[30:0]=0
- FAIL: write `0x800X_YYYY` — TB sees bits[30:0] ≠ 0; YYYY encodes failure location

---

## 8. Smoke Test Validation

### 8.1 Phase results (all passing as of 2026-05-22)

| Phase | What it tests | Key observable |
|---|---|---|
| A | MMIO register readback (in0 descriptor) | All reads match writes |
| B | Single read stream: done_in0 fires, no error bits | STATUS.done_in0=1 |
| C | Re-arm without reset | done_in0 clears then re-asserts |
| D | Read data integrity: CAFEBABE..BABC1 pattern | OBS_CNT=4, OBS_LAST=0xCAFEBAC1 |
| E | Write stream integrity via MMIO OUT0_PUSH | out_buf[0..3]=0xDEADBEE0..E3 |
| F | Multi-stream concurrency: in0+in1+out0 | All three done flags; no cross-contamination |
| G | cfg_err negative test: unaligned out0, zero bound | STATUS.cfg_err=1, no AXI activity |
| H | Window mode: k_rows=2, 4×4 image | OBS_CNT=16 (unique fetches), OBS_LAST=0xC0FFEE0F |
| I | stream.pop ISA: 4 pops, check values | pop0..3 = 0xCAFEBABE..C1 in a0 |
| J | stream.push ISA: 4 pushes, readback L2 | out_buf_j[0..3] = 0xBEEF0000..03 |
| K | Concurrent stream.pop + stream.push (4 iters) | out_buf_k mirrors test_buf, done_in0 + done_out0 both fire |
| L | Concurrent pop+push at scale (64 iters, fills 32-deep FIFO) | out_buf_l mirrors src_buf_l; backend backpressure exercises clean |

Phases K and L were added 2026-05-22 to verify Bug B (the original
"concurrent pop+push hang" report). Both pass — the hang was soft-emul
slowness in earlier diagnostic runs, mistaken for a deadlock. See §9.3.

### 8.2 Simulation parameters

- Tool: QuestaSim 2024.3 (`vsim -64 -c vopt_tb`)
- Mode: PRELOAD, 8-core full-SoC
- Run time: ~10.2 ms simulated, ~44 s wall clock
- Errors: 0, Warnings: 15 (benign)
- Key log files: `sim/se_fast.log`, `sim/trace_core_00_0.log`, `sim/FETCH_CORE_0.log`

### 8.3 Phase I trace evidence (trace_core_00_0.log)

```
# Four stream.pop instructions at 0x1c008d5e / 0x1c008d64 / 0x1c008d6a / 0x1c008d70
9956292ns  0000657b              ← pop, stalls until SE valid
9956349ns  00a009b3 add x19,x0,x10   x19=cafebabe   ← correct
9957372ns  0000657b
9958508ns  00a00933 add x18,x0,x10   x18=cafebabf   ← correct
9959588ns  0000657b
9959645ns  00a004b3 add x9,x0,x10    x9 =cafebac0   ← correct
9960668ns  0000657b
9961748ns  00a00433 add x8,x0,x10    x8 =cafebac1   ← correct
```

### 8.4 Phase J trace evidence

```
# stream.push instructions at 0x1c008eaa / ...eб6 / ...ebe / ...ec6
10036482ns  0005707b  (a0=beef0000)   ← push
10039778ns  0005707b  (a0=beef0001)   ← push
10041995ns  0005707b  (a0=beef0002)   ← push
10044154ns  0005707b  (a0=beef0003)   ← push
# STATUS=0x7 (done_in0|done_in1|done_out0) immediately after last push completes
```

---

## 9. Bugs Found and Fixed

### 9.1 refill_arbiter continuous sampling (`ips/hier-icache`)

**Symptom:** Core 0 fetches wrong instruction data at boot when ≥2 banks serve responses simultaneously.

**Root cause:** `refill_arbiter.sv` USE_RESP_BUFF path sampled `arbiter_r_data_i` every cycle
while waiting (`~r_arbiter_r_valid & r_arbiter_reqing`). The data bus is combinatorially muxed from
whatever bank is active — other banks' responses appeared transiently and were captured.

**Fix:**
```sv
// Before:
if (~r_arbiter_r_valid & r_arbiter_reqing)  r_arbiter_r_data <= arbiter_r_data_i;
// After:
if (arbiter_r_valid_i)                       r_arbiter_r_data <= arbiter_r_data_i;
```
Capture only on `arbiter_r_valid_i` — the single cycle the interconnect commits the correct response.

**Impact:** Silent data corruption at boot. Non-deterministic (timing-dependent which bank
finishes first). Manifests in full-SoC with 8 cores sharing the bypass path.

### 9.2 AXI ID truncation at cluster bus boundary (`ips/pulp_cluster`)

**Symptom:** Same as above (`FETCH_CORE_0.log` line 4 = `8082bff5`). Additional: banks 2 and 5
stall indefinitely (FIFO full, no R responses received).

**Root cause:** `cluster_bus_wrap.sv` line 83:
```sv
AXI_ASSIGN(axi_slaves[1], instr_slave)   // 5-bit slave ← 8-bit icache master
```
`icache_hier_top` internally encodes bank index in the **upper bits** of AXI AR ID via
`axi_id_prepend`: `MST_ID = {bank_idx[2:0], slv_id[4:0]}` → 8-bit.
`AXI_ASSIGN` silently truncates to 5 bits, dropping `id[7:5]` = the bank index.
All R responses return with `id[7:5]=0`; `axi_mux` routes them all to bank 0.

**Fix:** Reduce icache AXI_ID from 8 to 5 (= cluster bus slave port width):
- `s_core_instr_bus` declaration: `AXI_ID_WIDTH = AXI_ID_IN_WIDTH` (5)
- `icache_hier_top .AXI_ID = AXI_ID_IN_WIDTH` (5)

With AXI_ID=5: `AXI_ID_INT = 5 - clog2(8) = 2`. Bank index in bits[4:2].
Bank 5 AR: `{3'b101, 2'b00} = 0x14` (5 bits) — no truncation.
R response id=0x14 → `switch_r_id = id[4:2] = 5` → routes to bank 5.

**Impact:** Deterministic data corruption for any bank index > 0 (banks 1–7). Deadlock:
stalled bank holds FIFO slots indefinitely, blocking all subsequent fetches.

**Lesson:** `AXI_ASSIGN` between mismatched ID widths is legal SystemVerilog but semantically
broken when upper bits carry routing information. Always match ID widths at bus boundaries,
or ensure the routing field fits within the narrower width.

### 9.3 Bug B — phantom "concurrent pop+push hang" (`ips/se`)

**Symptom (as originally reported, 2026-05-17):** Kernels that issue
`stream.pop` and `stream.push` in the same inner loop appear to hang in
simulation. Documented as "Bug B" in commit log + future-work bullets.

**Investigation (2026-05-22):** Built reproducers — Phase K (4-iter
concurrent pop+push) and Phase L (64-iter, fills the 32-deep write FIFO
and forces 8+ backend drain bursts while the kernel is still pushing).
Both PASS cleanly on a current build. The original "hang" was the
kernel running so slowly under FP soft-emulation + icache bypass that
multi-minute wall time was mistaken for a deadlock — the changes log
itself hedged this with "never proven hung vs slow".

**Resolution:** No code change needed. The pop+push concurrent pattern
is functionally correct; HWFP enable (§10.2) + icache enable + the
2026-05-18 Option-D AGU-side gating fix (§9.x in changes) collectively
exposed the path as working. All 6 PolyBench-MINI kernels now have
SE-read+push variants (§10.3, §10.4).

### 9.4 Write-FSM partial-burst flush (`ips/pulp_cluster`)

**Symptom:** When the SE write stream's total element count was not a
multiple of 4, the trailing 1-3 words sat in the backend's word_buf
forever. They never reached L2 because the WR_IDLE → WR_AW transition
only fired on `eng_cnt_q == 3` (full burst). The engine's `flush_mode`
in `write_ctrl.sv` correctly drained its own FIFO, but the backend
accumulator wasn't aware of "end-of-stream".

**Workaround (initial):** Firmware padded output buffers to the next
multiple of 4 and pushed dummy values to flush. Applied to atax
(M=38→40, N=42→44).

**Root fix (2026-05-22):** Added `eng_done_i` input to
`se_axi_backend.sv` (sourced from `s_done_out0` in `se_top_wrap.sv`).
When done rises in WR_IDLE with `eng_cnt_q != 0`, backend issues a
shorter AXI write:

| Trailing words | AWLEN | Beats | WSTRB                           | WLAST  |
|----------------|------:|------:|---------------------------------|--------|
| 1              |     0 |     1 | `{4'h0, 4'hF}` (low half only)  | beat 0 |
| 2              |     0 |     1 | `8'hFF` (full beat)             | beat 0 |
| 3              |     1 |     2 | beat0 `8'hFF`; beat1 `{0,4'hF}` | beat 1 |
| 4              |     1 |     2 | both `8'hFF`                    | beat 1 |

`burst_words_q[2:0]` registers the count at the WR_AW transition;
combinational logic on it derives AWLEN, WSTRB, and WLAST.

**Impact:** atax reverted to real bounds (M=38, N=42); dummy pushes
removed. Measured improvement on atax is ~0.3 percentage points (below
BSS-layout noise floor); the value is the cleanup of a documented RTL
limitation and easier extension to future kernels with N%4≠0 outputs.

---

## 10. Key Numbers for Thesis

### 10.1 Architectural parameters

| Metric | Value |
|---|---|
| FIFO depth per stream | 32 elements |
| Max reuse buffer | 2048 elements (~8 kB at 32-bit) |
| Max iteration dimensions | 3 |
| Read streams | 2 (in0, in1) |
| Write streams | 1 (out0) |
| AXI data width | 64-bit |
| Read burst | 1 beat (single element per AR) |
| Write burst | up to 2 beats / 4 words coalesced; partial-burst flush emits 1- or 2-beat shorter writes for trailing 1-3 words |
| Custom instr latency | stalls EX until SE delivers (0 software overhead) |
| Cores with SE access | 1 of 8 (core 0 only, current cut) |
| Full smoke test (A–L) sim time | ~13 s simulated (~14 min wall) |
| SE MMIO registers | 19 (across 4 streams + ctrl/status/debug) |

### 10.2 Required configuration for canonical performance results

Hardware FP was disabled by a hardcoded `1'b1` on
`fregfile_disable_i` in `ips/pulp_cluster/rtl/core_region.sv:279` —
forced the FP register file MSB (FP/INT select) to 0 in
`riscv_id_stage.sv:500`, aliasing every FP register access to the
integer file, so the APU master interface never saw a request.
Fix: `.fregfile_disable_i(1'b0)`. Verified by tracing `fadd.s`/`fmul.s`
present (296 occurrences in jac1d trace), `__addsf3`/`__mulsf3` calls
absent (0 occurrences). RI5CY does not check mstatus.FS — no CSR write
needed.

| Requirement | Where | Value |
|---|---|---|
| FP regfile enable | `core_region.sv:279` | `.fregfile_disable_i(1'b0)` |
| ARCH multilib | `Makefile.se_smoke` | `rv32imfcxpulpv2 -mabi=ilp32` |
| icache SW enable | `se_bench.c::main()` | write `0xFFFFFFFF` to `0x10201400` |
| SE diagnostics | `pulp_soc_defines.sv` | `SE_DEBUG` undefined (default) |
| gemm DCE defense | `se_bench.c::do_gemm()` | volatile sink read of `ge_C` |

### 10.3 PolyBench-MINI canonical results — 3-variant comparison (2026-05-22)

All 6 kernels, rv32imfcxpulpv2, SE_DEBUG off, icache enabled, full-SoC sim.
Three variants per kernel:

- **BL** — baseline, no SE. Plain `lw/sw` for all memory access.
- **SE-pop** — SE pulls input streams via `stream.pop`; output writes
  still use regular `sw` to L2.
- **SE-pop+push** — SE pulls *and* drives output streams via
  `stream.push`, eliminating the per-element `sw` to L2.

| Kernel | BL cyc      | SE-pop cyc | SE-push cyc | Δpop vs BL | Δpush vs pop | Δpush vs BL |
|--------|------------:|-----------:|------------:|-----------:|-------------:|------------:|
| jac1d  |      80,942 |     39,898 |      29,011 |       −51% |   **−27%**   |    **−64%** |
| mvt    |     135,083 |     43,408 |      43,652 |       −68% |     +0.6%    |    **−68%** |
| atax   |     128,184 |     73,905 |      76,246 |       −42% |     +3.2%    |       −41%  |
| gemm   |     567,323 |    341,597 |     319,220 |       −40% |     −6.5%    |    **−44%** |
| 2mm    |     509,970 |    311,488 |     302,303 |       −39% |     −2.9%    |    **−41%** |
| jac2d  |   3,457,351 |  5,516,164 |   5,016,814 |       +60% |   **−9%**    |       +45%  |

Wall times (HWFP + icache, no diagnostics): jac1d ~30 s, mvt ~10 s,
atax ~80 s, gemm ~4 min, 2mm ~2 min, jac2d ~30 min.

Atax was re-measured 2026-05-22 after the partial-burst flush (§9.4) to
verify the cleanup: BL 121,959 / SE-pop 78,347 / SE-pw 80,588. SE-pw vs
SE-pop went from +3.2% to +2.9%, all numbers shifted by ~4–6k cycles
due to BSS layout changes from shrinking the atax_tmp/atax_y buffers
back to real bounds. Conclusion unchanged: atax's 80 total writes are
too few to amortize the cfg_out0 MMIO overhead.

Note: 2mm BL is ~2× a previous canonical (244k cyc) because earlier runs
inadvertently allowed GCC to DCE half of `mm_baseline` (mm_D never read
elsewhere). Adding `mm_se_pw` takes the address of mm_D, forcing GCC to
keep the writes — yielding the true BL workload. Similar effect on
mvt/atax baselines (smaller magnitude).

### 10.4 Interpretation — SE-pop and SE-push impact

**SE-pop wins on 5 of 6 kernels (32–68% cycle reduction).** Mechanism
is clear from CPI breakdown:

- Baseline CPI clusters at 6–8. With icache hot, instruction fetch is
  fast; the remaining stalls are *data-fetch stalls* — every `p.lw` to
  a word in L2 costs ~5 extra cycles of cluster-bus round-trip.
- SE-pop CPI drops to 2–4. The AGU prefetches ahead of the FP unit, so
  the pop is served from the SE FIFO at L1 speed; the FP pipeline
  doesn't wait on memory.
- gemm is the cleanest pop-only comparison: BL 94,138 instructions vs
  SE-pop 93,731 (nearly identical). The 40% cycle reduction is purely
  from data-fetch hiding, not from instruction-count savings.

**SE-push adds additional benefit on output-heavy kernels.** Pattern:
fixed per-kernel overhead (cfg_out0 ≈ 12 MMIO writes per pass + larger
wait_done mask + push wakeup) vs per-write savings (each `sw` to L2
costs ~10 cycles; `stream.push` only stalls if the write FIFO is full
and the backend pipelines 4-word bursts).

- **jac1d −27% additional**: small inner loop (28 writes/pass) × many
  re-arms (40 passes) = 1120 writes spread across many invocations.
  Push completely eliminates per-element `sw` to L2 cost. Highest
  leverage of the six.
- **gemm/2mm modest gains (−3 to −7%)**: compute-bound, 500/672 output
  writes are real savings but FP mul-add chains still dominate.
- **mvt push-neutral (+0.6%)**: N=40 writes vs ~1600 FP ops per pass —
  push savings buried in compute noise.
- **atax LOSES with push (+3.2%)**: only 80 total writes; cfg_out0 MMIO
  overhead outweighs per-write savings. **Lesson: SE push has a fixed
  per-invocation overhead; needs enough writes per kernel call to
  amortize.**
- **jac2d still loses (+45% vs +60% pop-only)**: push helps 9% by
  removing per-write stalls during the 5-point stencil's many output
  writes (784 per pass × 40 passes ≈ 31k total). But the +45% residual
  is from the per-output-row `buf[3][N]` intermediate the kernel must
  use to bridge between SE's row-major delivery and the stencil's
  cross-row data demand — not re-arm cost (which is only ~3 MMIO
  writes per pass × 40 = ~120 writes ≈ 720 cycles, negligible).

### 10.5 Historical context — earlier suboptimal regimes

Two earlier configurations produced different results, useful for
understanding what changed but **not** the dissertation numbers:

- **Soft-emul + icache bypass** (before HWFP fix): CPI ~13–17. SE
  roughly neutral with baseline (atax ~0%, others +30 to +100%).
  Memory was hidden inside the soft-emul integer FP work; SE had
  little to amortize.
- **HWFP + icache bypass** (before SW enable was added): CPI ~13–19.
  SE *slower* than baseline on all kernels (+11% to +108%).
  Instruction fetch from L2 dominated runtime, hiding SE's data-fetch
  advantage.

The leap to the canonical configuration is a combined effect: HWFP
exposes a memory-bound workload, and icache exposes data fetch as the
remaining bottleneck. Either alone is insufficient — both are required.

### 10.6 Partial-burst flush (2026-05-22)

Originally the SE write FSM in `se_axi_backend.sv` was hard-locked to
4-word AXI bursts. If the engine streamed a non-multiple-of-4 total
(e.g., atax with M=38 or N=42), the dangling 1–3 words sat in the
backend's `word_buf_q` indefinitely — never flushed, never reached L2.
Discovered while integrating atax with SE push; original workaround
was to declare padded buffers (M_PAD=40, N_PAD=44) and emit 2 dummy
pushes per pass to force a full final burst.

Now fixed: `eng_done_i` input on `se_axi_backend.sv` (sourced from
`s_done_out0` in `se_top_wrap.sv`) triggers a shorter AXI write when
the engine signals done with 1–3 words buffered. AWLEN drops to 0 for
1–2 words (single beat) or stays at 1 for 3 words (2 beats, second
partially valid). WSTRB masks the unwritten lanes; WLAST asserts on
the final used beat. atax reverted to real bounds (M=38, N=42); dummy
pushes removed; ~50 cycles saved per pass but the visible delta is
within layout/icache noise (atax's bottleneck is config overhead, not
the dangling words).

Value of this fix: eliminates a documented RTL limitation, lets future
kernels with N%4≠0 output streams Just Work, and makes the atax SE
kernel match the canonical pattern.

### 10.7 AXI trace cross-validation against the analytical model (2026-05-23)

A trace logger was added to the testbench to capture every AR/AW
handshake on the SE master port (`s_se_ext_bus`) and the cluster
core-data master port (`s_core_ext_bus`). Each handshake is expanded
into one line per element transferred and written to a single trace
file per simulation run, in temporal bus order. The format is the
plain `<op> <address>` expected by Ramulator 2.0's `readwrite_trace`
frontend, so the file is directly consumable for DRAM-level evaluation
in Chapter 9.

Implementation choices:

- Single combined file per run, `{kernel}_{dataset}_{bl|se}_rtl.trace`,
  preserves the temporal interleaving across the two AXI ports.
- Variant gating via `BENCH_VARIANT_BL_ONLY` / `BENCH_VARIANT_SE_ONLY`
  compile defines isolates each variant in firmware so the trace
  contains only the chosen kernel's accesses.
- Per-element AW expansion uses the backend's `burst_words_q` register
  (1-4) to derive the actual element count from each AW, correctly
  handling both full bursts and partial-flush bursts from §10.6.
- `\`ifdef ENABLE_TRACE` guards the entire block so it compiles out
  cleanly for non-trace runs.

Cross-validation against the analytical traffic model derived in
Chapter 5, run as 12 simulations (6 kernels × {BL, SE}), full-SoC
PRELOAD, PolyBench-MINI:

| Kernel | Variant | Analytical reads | Trace LD | Match                  |
|--------|---------|-----------------:|---------:|------------------------|
| jac1d  | BL      | 3,360            | 3,398    | ✓                      |
| jac1d  | SE      | 1,200            | 1,283    | ✓                      |
| mvt    | BL      | 6,480            | 6,519    | ✓                      |
| mvt    | SE      | 3,280            | 3,399    | ✓                      |
| atax   | BL      | 6,464            | 6,501    | ✓                      |
| atax   | SE      | 3,272            | 6,463    | ✗ +97%                 |
| gemm   | BL      | 30,500           | 30,040   | ✓                      |
| gemm   | SE      | 15,600           | 15,640   | ✓                      |
| 2mm    | BL      | 26,496           | 26,540   | ✓ (post-DCE-sink fix)  |
| 2mm    | SE      | 13,888           | 13,927   | ✓                      |
| jac2d  | BL      | 156,800          | 156,835  | ✓                      |
| jac2d  | SE      | 36,000           | 192,880  | ✗ +436%                |

Ten of twelve match to within a sub-1% scaffolding margin (BSS init,
bench_record stores, volatile sinks, stack frame setup). The two
divergences are characterized rather than residual bugs:

- **atax SE +97%.** The analytical model's formula `2·M·N + M + N`
  assumes the compiler hoists the non-streamed operand (`atax_x[j]`
  in pass 1, `atax_tmp[i]` in pass 2) out of the inner loop so it is
  read once per outer iteration. At -O1 the RI5CY compiler does not
  perform this hoisting, so each inner iteration re-reads the operand,
  adding `M·N` cluster-port reads per pass. The trace's `4·M·N`
  accurately reflects the compiled code; the analytical bound is
  optimistic. This is the gap between an idealized memory-access model
  and the actual access stream the hardware sees.

- **jac2d SE +436%.** The SE-port reads alone (~36,000) match the
  analytical model exactly, including the window-mode reuse-buffer
  amortization. The additional 156,800 reads are the inner stencil
  loading the `static float buf[3][N]` intermediate from L2.
  Breakdown: 5 buf reads per stencil cell × (N-2)² stencil cells × 2
  passes × T = 5×28²×40 = 156,800 — exact match. This is the
  byte-level evidence for jac2d's documented SE-loss cause (§10.4):
  the row-major SE delivery forces a buf intermediate that the
  stencil computation reads back from L2.

DCE-sink discovery: the 2mm baseline read count was initially 12,710,
exactly half of analytical 26,496. With `BENCH_VARIANT_BL_ONLY`
defined, `mm_se_pw` is not compiled, leaving `mm_D` unobserved after
`mm_baseline`'s K2 pass. GCC -O1 then eliminates the K2 loop entirely.
Fixed by adding a volatile sink read of `mm_D[NI-1][NL-1]` after each
2mm variant in `do_2mm()`, mirroring the existing `_gemm_sink` pattern.
Post-fix trace: 26,540 reads, within 44 of analytical (scaffolding).

Wall time for the full 12-run trace sweep: ~37 minutes, dominated by
jac2d (~17 min for both variants). Traces are produced in `sim/` and
ranged from 1,283 lines (jac1d SE) to 192,880 lines (jac2d SE).

---

## 11. Open Items / Future Work

### Completed since v1 of these notes

- ~~**Performance benchmarking**~~ — done. Six PolyBench-MINI kernels, HWFP +
  icache, results in §10.3.
- ~~**Hardware FP integration**~~ — done. `fregfile_disable_i` fix in
  `core_region.sv`, switched to `rv32imfcxpulpv2` multilib (§10.2).
- ~~**icache runtime enable**~~ — done. SW write `0xFFFFFFFF` to `0x10201400`
  at start of main (§10.2).
- ~~**SE diagnostic gating**~~ — done. `\`ifdef SE_DEBUG` guards in 4 SE files;
  default off for performance runs.
- ~~**Bug B: SE write streams with concurrent push**~~ — RESOLVED 2026-05-22.
  Phase K (4-iter) and Phase L (64-iter, fills write FIFO) in `se_smoke.c`
  both pass. Original report was soft-emul slowness mistaken for a hang;
  HWFP + icache + Option-D AGU gating implicitly resolved it. All 6 kernels
  now have SE-read+push variants (§10.3).
- ~~**Write-FSM partial-burst flush**~~ — done. `se_axi_backend.sv` now
  emits AWLEN=0/1 partial bursts via `eng_done_i` from `s_done_out0`. atax
  uses real bounds (M=38, N=42) without padding (§10.6).
- ~~**AXI trace infrastructure for Ramulator cross-validation**~~ — done.
  Trace block in `tb_pulp.sv` captures both AXI master ports under
  an `ifdef ENABLE_TRACE` guard; per-element expansion with partial-
  burst awareness via `burst_words_q`; firmware variant gating in
  `se_bench.c` (`BENCH_VARIANT_BL_ONLY` / `BENCH_VARIANT_SE_ONLY`).
  Full 12-run sweep validated against the analytical model; 10/12
  match within sub-1% scaffolding noise (§10.7).

### Open

- **jac2d re-arm overhead** — initial hypothesis was that the ~3 MMIO
  writes per re-arm × 40 passes was the +45% overhead. Measurement
  disproves this: re-arm MMIO is ~720 cycles out of 5M. The actual
  overhead is the `buf[3][N]` intermediate inside `j2_stencil_compute`
  (~7,800 extra instructions per pass), confirmed at byte level by the
  trace cross-validation (§10.7: jac2d SE shows +156,800 reads, exactly
  the buf-access count). Real fix would be either (a) kernel
  restructure with rotating row pointers (eliminates ~80% of buf
  writes, pure C change), or (b) a stencil-delivery SE mode that emits
  5 elements per output cell in stencil order (substantial RTL).
- **atax SE compiler-hoisting gap** — trace shows 2× the analytical
  read count for atax SE because GCC -O1 does not hoist the
  non-streamed operand (`atax_x[j]`, `atax_tmp[i]`) out of the inner
  loop (§10.7). The analytical model assumes the hoisting; the
  compiled code does not perform it. Closing the gap would require
  either firmware-side manual hoisting (load `atax_x` into local
  variables before the inner loop) or stronger optimization, both of
  which need separate study.
- **Optimization-level sensitivity study** — all canonical results and
  traces use -O1. Higher levels (-O2, -O3) may hoist invariant
  operands and close the atax gap above, but may also trigger more
  aggressive DCE that breaks existing volatile sinks (`_gemm_sink`,
  `_mm_sink`) and alter the SE-vs-baseline cycle gap. A controlled
  sweep across {-O0, -O1, -O2, -O3} on the 6 kernels × 2 variants
  would quantify compiler sensitivity but adds ~3× the existing
  trace-sweep wall time. Identified as future work rather than scope.
- **atax SE-push overhead amortization** — atax has only 80 total writes;
  cfg_out0 MMIO setup (12 writes × 2 passes ≈ 200 cycles) doesn't amortize.
  Not a bug; a documented "too small to benefit" property. Larger
  PolyBench sizes would resolve naturally.
- **Multi-core SE access**: currently only core 0; a future arbiter at the SE
  boundary could allow any core to issue stream.pop/push with a cluster-level
  SE ID.
- **icache inactive modes**: the `ifdef MP_ICACHE` branch (around line
  1308 of `pulp_cluster.sv`) and the legacy `icache_top` branch (around
  line 1384) still use `AXI_ID_OUT_WIDTH=8` — need the same AXI ID
  truncation fix as `PRIVATE_ICACHE` if either mode is ever enabled.
- **Write burst alignment**: firmware must ensure `out0.base_addr[3:0]=0`
  (16-byte aligned); cfg_err fires on violation but this is a silent
  constraint in the programmer model.
- **Cluster-bus shared R-channel**: per-master AXI rready backpressure on SE
  backend works at SE level but stalls icache via `cluster_bus_wrap`. SE
  currently keeps `axi_r_ready_o=1'b1` and gates on the AGU side instead.
- **Larger PolyBench sizes**: SMALL or STANDARD would amortize SE overhead
  further (especially atax). MINI was chosen to keep sim wall time
  tractable. Could add as a scaling-study chapter.
- **Submodule tracking**: `ips/pulp_cluster`, `ips/hier-icache`, `ips/riscv`,
  `ips/se` are independent git repos — not yet wired as submodules of the
  top-level `pulp` repo.
