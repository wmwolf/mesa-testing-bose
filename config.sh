#!/usr/bin/env bash
# config.sh — Shared configuration for MESA Slurm test scripts.
# Source this file; do not execute it directly.
#
# You can override any variable by setting it in the environment before
# sourcing, e.g.:
#   export MESA_WORK_DIR=/scratch/myuser/mesa_builds
#   source config.sh

# ── Slurm settings ────────────────────────────────────────────────────────────
SLURM_PARTITION="${SLURM_PARTITION:-week}"

# ── Resource allocations ──────────────────────────────────────────────────────
INSTALL_CPUS=12
INSTALL_MEM="16G"
INSTALL_TIME="8:00:00"

TEST_CPUS=12
TEST_MEM="18G"
TEST_TIME="12:00:00"

# Minimal resources for the test-launcher job (just issues sbatch calls)
LAUNCHER_CPUS=1
LAUNCHER_MEM="512M"
LAUNCHER_TIME="0:10:00"

# Minimal resources for the cleanup job (just rm -rf on the worktree)
CLEANUP_CPUS=1
CLEANUP_MEM="512M"
CLEANUP_TIME="0:30:00"

# ── MESA modules to test ──────────────────────────────────────────────────────
MESA_MODULES=(star astero binary)

# ── Work directory ────────────────────────────────────────────────────────────
# mesa_test install uses this as the root; each build gets a unique subdirectory.
MESA_WORK_DIR="${MESA_WORK_DIR:-${HOME}/.mesa_test/work}"

# Temporary directory for status files and top-level job logs.
# Must be on shared storage so compute nodes can read files written by the
# login node (or other compute nodes). Never use /tmp or ~/tmp here —
# /tmp is node-local, and ~ is not expanded by tools like mktemp.
MESA_TMP_DIR="${MESA_TMP_DIR:-${MESA_WORK_DIR}/.tmp}"

# ── Environment setup ─────────────────────────────────────────────────────────
# Call this at the top of any script that invokes mesa_test or runs MESA tests.
# Loads required modules and scrubs variables that are useful for interactive
# work but harmful for automated testing.
load_mesa_env() {
    module load git/2.54.0
    module load ruby/3.4.2
    module load mesa
    # The mesa module sets MESA_CACHES_DIR to a shared path, which is useful
    # for research but bad for automated testing (cache bloat). Always unset it.
    unset MESA_CACHES_DIR
}
export -f load_mesa_env
