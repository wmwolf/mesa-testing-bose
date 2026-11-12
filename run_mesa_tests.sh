#!/usr/bin/env bash
# run_mesa_tests.sh — Top-level entry point for MESA automated testing.
#
# Submits an install job and, if it succeeds, a launcher job that spawns
# array jobs for all three MESA modules (star, astero, binary).
#
# Usage:
#   run_mesa_tests.sh [--skip-optional] [--fpe] [version]
#
#   --skip-optional   Skip optional inlists in all test cases by setting
#                     MESA_SKIP_OPTIONAL=t in each test job's environment.
#   --fpe             Enable floating point exception checks by setting
#                     MESA_FPE_CHECKS_ON=t. Affects both compilation and
#                     test runs. Off by default; any value set by the mesa
#                     module or your login environment is suppressed.
#   version           A git commit SHA or branch name. If omitted,
#                     mesa_test will test HEAD of MESA's main branch.
#
# Example:
#   run_mesa_tests.sh                            # full tests, HEAD of main
#   run_mesa_tests.sh main                       # full tests, explicit branch
#   run_mesa_tests.sh --skip-optional main       # skip optional inlists
#   run_mesa_tests.sh --fpe main                 # enable FPE checks
#   run_mesa_tests.sh --fpe --skip-optional main # both flags
#   run_mesa_tests.sh r24.08.1                   # a release tag

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
source "${SCRIPT_DIR}/config.sh"

VERSION=""
SKIP_OPTIONAL=""
FPE_CHECKS=""

for arg in "$@"; do
    case "${arg}" in
        --skip-optional) SKIP_OPTIONAL="t" ;;
        --fpe)           FPE_CHECKS="t"    ;;
        *)               VERSION="${arg}"   ;;
    esac
done

export MESA_SKIP_OPTIONAL="${SKIP_OPTIONAL}"
export MESA_FPE_CHECKS_ON="${FPE_CHECKS}"

[[ -n "${SKIP_OPTIONAL}" ]] && echo "Optional inlists will be skipped (MESA_SKIP_OPTIONAL=t)"
[[ -n "${FPE_CHECKS}"    ]] && echo "FPE checks enabled (MESA_FPE_CHECKS_ON=t)"

# ── Ensure tmp directory exists on shared storage ─────────────────────────────
mkdir -p "${MESA_TMP_DIR}"

# ── Status file ───────────────────────────────────────────────────────────────
# The install job writes the MESA_TEST_DIR path here on success.
# The launcher job reads it to know which installation to test.
# A unique name avoids collisions if multiple runs are in flight.
STATUS_FILE=$(mktemp "${MESA_TMP_DIR}/mesa_install_XXXXXX.status")
echo "Status file: ${STATUS_FILE}"

# ── Version label for log file names ─────────────────────────────────────────
VERSION_LABEL="${VERSION:-HEAD}"

# ── Submit install job ────────────────────────────────────────────────────────
INSTALL_LOG="${MESA_TMP_DIR}/mesa_install_${VERSION_LABEL}.log"

echo "Submitting install job (version: ${VERSION_LABEL})..."
INSTALL_JOB_ID=$(sbatch --parsable \
    --partition="${SLURM_PARTITION}" \
    --nodes=1 \
    --ntasks-per-node="${INSTALL_CPUS}" \
    --mem="${INSTALL_MEM}" \
    --time="${INSTALL_TIME}" \
    --job-name="mesa_install" \
    --output="${INSTALL_LOG}" \
    --error="${INSTALL_LOG}" \
    --export=ALL,VERSION="${VERSION}",STATUS_FILE="${STATUS_FILE}",MESA_FPE_CHECKS_ON="${MESA_FPE_CHECKS_ON}" \
    "${SCRIPT_DIR}/install_mesa.sh")

echo "Install job submitted: ${INSTALL_JOB_ID}"
echo "  Log: ${INSTALL_LOG}"

# ── Submit launcher job (depends on install success) ─────────────────────────
# --dependency=afterok means this job only runs if the install job exits 0.
# If the build fails (exit 1), Slurm cancels this job automatically.
LAUNCH_LOG="${MESA_TMP_DIR}/mesa_launch_${VERSION_LABEL}.log"

echo "Submitting test launcher job (depends on install job ${INSTALL_JOB_ID})..."
LAUNCH_JOB_ID=$(sbatch --parsable \
    --partition="${SLURM_PARTITION}" \
    --nodes=1 \
    --ntasks-per-node="${LAUNCHER_CPUS}" \
    --mem="${LAUNCHER_MEM}" \
    --time="${LAUNCHER_TIME}" \
    --job-name="mesa_launch" \
    --output="${LAUNCH_LOG}" \
    --error="${LAUNCH_LOG}" \
    --dependency="afterok:${INSTALL_JOB_ID}" \
    --export=ALL,STATUS_FILE="${STATUS_FILE}",MESA_SKIP_OPTIONAL="${MESA_SKIP_OPTIONAL}",MESA_FPE_CHECKS_ON="${MESA_FPE_CHECKS_ON}" \
    "${SCRIPT_DIR}/launch_tests.sh")

echo "Launcher job submitted: ${LAUNCH_JOB_ID}"
echo "  Log: ${LAUNCH_LOG}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Pipeline submitted:"
echo "  [${INSTALL_JOB_ID}] mesa_install  →  [${LAUNCH_JOB_ID}] mesa_launch  →  [array jobs]"
echo ""
echo "Monitor with:"
echo "  squeue -j ${INSTALL_JOB_ID},${LAUNCH_JOB_ID}"
echo "  squeue -u \$(whoami)"
echo ""
echo "Install log (after job runs):"
echo "  ${INSTALL_LOG}"
