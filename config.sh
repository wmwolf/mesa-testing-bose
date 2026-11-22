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

# ── Tested-commit log ─────────────────────────────────────────────────────────
# CSV with one row per run_mesa_tests.sh launch (see README.md). Machine-local
# state, kept next to mesa_test's own config and mirror rather than in this
# repository or under MESA_WORK_DIR (which may live on purgeable scratch).
# Must be on storage the compute nodes can write: cleanup_mesa.sh fills in the
# completion time from a compute node.
MESA_RUN_LOG="${MESA_RUN_LOG:-${HOME}/.mesa_test/tested_commits.csv}"

# Local mirror of the MESA repository that mesa_test maintains. Used to resolve
# branch names to commit SHAs before launching.
MESA_MIRROR_DIR="${MESA_MIRROR_DIR:-${HOME}/.mesa_test/mirror}"

# Resolution factor for --converge when none is given (mesa_test's default).
DEFAULT_CONVERGE_FACTOR="0.8"

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

# ── Tested-commit log helper ──────────────────────────────────────────────────
# Thin wrapper around run_log.py (see that file for subcommands). Requires
# SCRIPT_DIR to point at this repository, as every script here arranges.
run_log() {
    python3 "${SCRIPT_DIR}/run_log.py" --log "${MESA_RUN_LOG}" "$@"
}
