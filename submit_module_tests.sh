#!/usr/bin/env bash
# submit_module_tests.sh — Submit a Slurm array job for all tests in one
# MESA module.
#
# Usage:
#   submit_module_tests.sh <mesa_test_dir> <module>
#
#   mesa_test_dir  Absolute path to a per-commit MESA worktree.
#   module         One of: star, astero, binary
#
# Prints the submitted Slurm job ID to stdout on success.
# Exits non-zero if the test suite directory is missing or has no tests.
#
# This script can be called interactively from a login node, from another
# batch script, or from launch_tests.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# ── Argument handling ─────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
    echo "Usage: $(basename "$0") <mesa_test_dir> <module>" >&2
    exit 1
fi

MESA_TEST_DIR="${1}"
MODULE="${2}"

# Validate module name
if [[ ! " ${MESA_MODULES[*]} " =~ " ${MODULE} " ]]; then
    echo "ERROR: '${MODULE}' is not a recognised module. Expected one of: ${MESA_MODULES[*]}" >&2
    exit 1
fi

# ── Locate the test suite ─────────────────────────────────────────────────────
SUITE_DIR="${MESA_TEST_DIR}/${MODULE}/test_suite"

if [[ ! -d "${SUITE_DIR}" ]]; then
    echo "ERROR: test suite directory not found: ${SUITE_DIR}" >&2
    exit 1
fi

if [[ ! -x "${SUITE_DIR}/count_tests" ]]; then
    echo "ERROR: count_tests script not found or not executable in ${SUITE_DIR}" >&2
    exit 1
fi

NTESTS=$(cd "${SUITE_DIR}" && ./count_tests)

if [[ -z "${NTESTS}" || "${NTESTS}" -lt 1 ]]; then
    echo "WARNING: no tests found for module '${MODULE}' in ${SUITE_DIR}" >&2
    exit 0
fi

echo "Submitting ${NTESTS} test(s) for module '${MODULE}'" >&2

# ── Ensure log directory exists ───────────────────────────────────────────────
LOG_DIR="${MESA_TEST_DIR}/logs"
mkdir -p "${LOG_DIR}"

# ── Submit array job ──────────────────────────────────────────────────────────
JOB_ID=$(sbatch --parsable \
    --partition="${SLURM_PARTITION}" \
    --nodes=1 \
    --ntasks-per-node="${TEST_CPUS}" \
    --mem="${TEST_MEM}" \
    --time="${TEST_TIME}" \
    --job-name="mesa_${MODULE}" \
    --output="${LOG_DIR}/${MODULE}-%a.log" \
    --error="${LOG_DIR}/${MODULE}-%a.log" \
    --array="1-${NTESTS}" \
    --export=ALL,SCRIPT_DIR="${SCRIPT_DIR}",MESA_TEST_DIR="${MESA_TEST_DIR}",MODULE="${MODULE}",OMP_NUM_THREADS="${TEST_CPUS}",MESA_SKIP_OPTIONAL="${MESA_SKIP_OPTIONAL:-}",MESA_FPE_CHECKS_ON="${MESA_FPE_CHECKS_ON:-}" \
    "${SCRIPT_DIR}/run_module_test_job.sh")

echo "${JOB_ID}"
