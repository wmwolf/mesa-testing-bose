#!/usr/bin/env bash
# run_module_test_job.sh — Slurm array job script for a single MESA test case.
#
# Do not invoke directly. Submit via submit_module_tests.sh, which sets the
# array range and passes the required environment variables.
#
# Required environment variables (set via --export by submit_module_tests.sh):
#   MESA_TEST_DIR      Path to the per-commit MESA worktree
#   MODULE             The MESA module being tested (star, astero, or binary)
#   OMP_NUM_THREADS    Number of OpenMP threads (should match --ntasks-per-node)
#
# The Slurm array index ($SLURM_ARRAY_TASK_ID) determines which test to run.
#
# Note on MESA_DIR: `module load mesa` sets MESA_DIR to the system MESA
# installation. We use MESA_TEST_DIR to avoid any collision with that variable.

#SBATCH --nodes=1
#SBATCH --no-requeue

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
source "${SCRIPT_DIR}/config.sh"

: "${MESA_TEST_DIR:?MESA_TEST_DIR must be set (passed via --export)}"
: "${MODULE:?MODULE must be set (passed via --export)}"

# Save MESA_TEST_DIR before loading modules; load_mesa_env runs
# `module load mesa` which sets MESA_DIR to the system installation.
_MESA_TEST_DIR="${MESA_TEST_DIR}"

load_mesa_env

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-${TEST_CPUS}}"

echo "Running test ${SLURM_ARRAY_TASK_ID} for module '${MODULE}' from ${_MESA_TEST_DIR}"

mesa_test test "${SLURM_ARRAY_TASK_ID}" \
    --module="${MODULE}" \
    --mesadir="${_MESA_TEST_DIR}"
