# Dissertation artifact — Streaming Engine for the PULP cluster

This fork is the top-level entry point for the artifacts of the master's
dissertation:

> **Configurable Streaming Engine for RISC-V Systems**
> Gonçalo Pereira — Faculdade de Engenharia da Universidade do Porto (FEUP)

The upstream PULP `README.md` is preserved alongside this file. Read that
one for the platform background; read this one for the dissertation-specific
chain of forks, how to clone-and-build them, and how to reproduce the
reported measurements.

## The six repositories

The dissertation work spans six public Git repositories under
`github.com/goncalop00`. This top-level fork pins the five IP forks at fixed
commits through `ips_list.yml`, so a single clone-and-build sequence
reproduces the exact RTL + firmware tree the dissertation was evaluated on.

| Repository | Branch | Role |
| --- | --- | --- |
| [`pulp_streaming_engine`](https://github.com/goncalop00/pulp_streaming_engine) | `streaming-engine` | This repository. Pins the IPs below via `ips_list.yml`. |
| [`streaming-engine`](https://github.com/goncalop00/streaming-engine) | `main` | The Streaming Engine IP authored for this dissertation. |
| [`pulp_cluster`](https://github.com/goncalop00/pulp_cluster) | `streaming-engine-integration` | Fork of `pulp-platform/pulp_cluster` with the SE cluster integration. |
| [`pulp_soc`](https://github.com/goncalop00/pulp_soc) | `clusterv2` | Fork of `pulp-platform/pulp_soc` with FC stream-port tie-off and SELECTABLE_HARTS overflow fix. |
| [`riscv`](https://github.com/goncalop00/riscv) | `se-integration` | Snapshot of the pre-handover `pulp-platform/riscv` (PULP RI5CY) with the SE-bench firmware. |
| [`hier-icache`](https://github.com/goncalop00/hier-icache) | `axi_node_dep` | Fork of `pulp-platform/hier-icache` with the `refill_arbiter` capture-on-valid fix. |

Each forked IP preserves its original `pulp-platform` URL as the `upstream`
Git remote, so the dissertation-specific delta is visible by direct branch
comparison.

## Clone and build

```bash
git clone https://github.com/goncalop00/pulp_streaming_engine pulp
cd pulp
git checkout streaming-engine
./update-ips    # clones the three forks at the pinned commits
make build
```

## Reproducing the measurements

The dissertation reports two evaluation tiers (Chapter 8, methodology).

**Tier 1 — cycle-accurate RTL.** Cycle and instruction counts on the
integrated Mr. Wolf cluster RTL under QuestaSim. Driven by:

```bash
cd sim
./run_trace_sweep.sh                   # default: 6 kernels, MINI, best variant
KERNELS="gemm 2mm" DATASETS=SMALL VARIANTS=pws ./run_trace_sweep.sh
```

The firmware writes per-kernel benchmark slots to L2; the testbench
`rtl/tb/tb_pulp.sv` reads them back through JTAG-SBA after the firmware exit
and prints `[BENCH]` lines with cycle and instruction counts.

**Tier 2 — DRAM-level Ramulator 2.0.** AXI traces produced in host mode by
the C model, replayed through Ramulator with the canonical DDR4-2400R YAML
configuration. The trace generator is described in Chapter 7 of the
dissertation; the Ramulator configuration template in Chapter 8.

Both flows are deterministic: identical inputs yield identical outputs, and
a single run per cell is the value reported in Chapter 9.

## STRIDE — trace-driven descriptor inference

STRIDE infers Streaming Engine descriptors from an AXI bus trace of the
*baseline* kernel — no source access, no hand-written descriptors — then
re-runs the kernel on the engine from the inferred table, bit-exact. The
inference tool lives in the [`riscv`](https://github.com/goncalop00/riscv)
fork (`tb/core/custom/stride_infer.py`, ported to C as `stride_infer.c`);
this repository adds the testbench support in `rtl/tb/tb_pulp.sv`: the
descriptor-table preload (`+STRIDE_TABLE`) and the in-system trace capture
(`+STRIDE_INSYS`, a stand-in for an on-chip bus monitor). Emitted tables are
committed under `sim/stride/`.

Both flows need a trace-enabled RTL build (`make build
TRACE_DEFINES=+define+ENABLE_TRACE && make opt`). The one-run
self-configuring demo — capture, infer on the cluster core, self-program the
engine, all in a single simulation:

```bash
cd ips/riscv/tb/core
make -f Makefile.se_smoke APP=se_bench clean_smoke
make -f Makefile.se_smoke APP=se_bench KERNEL=gemm DATASET=MINI \
     VARIANT= STRIDE_INSYS=1 TRACE_TAG=bl sim_fast
```

## License

This repository inherits the [Solderpad Hardware License v0.51](http://solderpad.org/licenses/SHL-0.51/)
from upstream `pulp-platform/pulp`. Original author attributions are
preserved in the Git history of every file.
