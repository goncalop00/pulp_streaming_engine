#!/bin/bash
# run_trace_sweep.sh — generate AXI traces across PolyBench kernel ×
# variant × dataset matrix for Ramulator 2.0 cross-validation.
#
# Produces sim/{kernel}_{dataset}_{bl|se}_rtl.trace files. Each run
# compiles the firmware with kernel + dataset + variant-gating defines
# so only the chosen variant of the chosen kernel at the chosen size
# runs, then traces the AXI master ports.
#
# Prerequisites (one-time, until cleaned):
#   cd sim
#   make clean && make lib && \
#       make build TRACE_DEFINES=+define+ENABLE_TRACE && \
#       make opt
#
# Usage:
#   ./run_trace_sweep.sh                         # all kernels, MINI, both variants
#   ./run_trace_sweep.sh KERNELS DATASETS VARIANTS
#   ./run_trace_sweep.sh gemm SMALL              # gemm SMALL, both variants
#   ./run_trace_sweep.sh "jac1d jac2d" "SMALL MEDIUM" se
#
# Environment overrides:
#   KERNELS, DATASETS, VARIANTS, RISCV
#
# Notes on L2 fit at non-MINI sizes (Mr. Wolf has 512 KB L2):
#   gemm, atax, mvt, 2mm: only MINI and SMALL fit
#   jacobi-1d: MINI, SMALL, MEDIUM, LARGE all fit
#   jacobi-2d: MINI, SMALL, MEDIUM fit (MEDIUM is tight at ~492 KB)
# The firmware build will fail at link time if the chosen size exceeds
# the linker-script L2 region.

set -e

RISCV=${RISCV:-/home/g/tools/pulp-riscv}
KERNELS=${KERNELS:-"jac1d mvt atax gemm 2mm jac2d"}
DATASETS=${DATASETS:-"MINI"}
VARIANTS=${VARIANTS:-"bl se"}

# Positional overrides
if [ -n "$1" ]; then KERNELS="$1"; fi
if [ -n "$2" ]; then DATASETS="$2"; fi
if [ -n "$3" ]; then VARIANTS="$3"; fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW_DIR="$REPO_ROOT/ips/riscv/tb/core"
SIM_DIR="$REPO_ROOT/sim"
LOG_DIR="$SIM_DIR/trace_logs"
mkdir -p "$LOG_DIR"

start_total=$SECONDS
for kernel in $KERNELS; do
    for dataset in $DATASETS; do
        for variant in $VARIANTS; do
            tag="${kernel}_${dataset}_${variant}"
            log="$LOG_DIR/${tag}.log"
            start=$SECONDS
            echo "=== [$tag] starting ==="
            set +e
            (
                cd "$FW_DIR"
                RISCV="$RISCV" make -f Makefile.se_smoke \
                    APP=se_bench \
                    KERNEL="$kernel" \
                    DATASET="$dataset" \
                    VARIANT="$variant" \
                    clean_smoke all sim_trace
            ) >"$log" 2>&1
            rc=$?
            set -e
            elapsed=$((SECONDS - start))
            trace="$SIM_DIR/${tag}_rtl.trace"
            if [ $rc -ne 0 ]; then
                echo "=== [$tag] BUILD/SIM FAILED in ${elapsed}s (rc=$rc) — see $log ==="
            elif [ -f "$trace" ]; then
                ld=$(grep -c '^LD ' "$trace" 2>/dev/null || echo 0)
                st=$(grep -c '^ST ' "$trace" 2>/dev/null || echo 0)
                printf "=== [%s] done in %ds — LD=%s ST=%s ===\n" \
                    "$tag" "$elapsed" "$ld" "$st"
            else
                echo "=== [$tag] no trace file produced in ${elapsed}s — see $log ==="
            fi
        done
    done
done

total=$((SECONDS - start_total))
echo
echo "Sweep complete in ${total}s. Trace files:"
ls -la "$SIM_DIR"/*_rtl.trace 2>/dev/null | sort
