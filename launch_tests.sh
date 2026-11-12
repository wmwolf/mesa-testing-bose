#!/usr/bin/env bash
# launch_tests.sh — Lightweight Slurm job that reads the MESA worktree path
# from STATUS_FILE and submits array jobs for all three MESA modules, then
# chains a cleanup job to remove the worktree once all tests finish.
#
# This job is submitted with --dependency=afterok:<install_job_id> by
# run_mesa_tests.sh, so it only runs when the install job exits successfully.
# If the install failed, Slurm cancels this job automatically.
#
# Required environment variables (set via --export when submitting):
#   STATUS_FILE   Path to the file written by install_mesa.sh containing
#                 the MESA_TEST_DIR path.

#SBATCH --nodes=1
#SBATCH --no-requeue
#SBATCH --job-name=mesa_launch

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
source "${SCRIPT_DIR}/config.sh"

: "${STATUS_FILE:?STATUS_FILE must be set (passed via --export)}"

# ── Read the worktree directory ───────────────────────────────────────────────
if [[ ! -f "${STATUS_FILE}" ]]; then
    echo "ERROR: status file not found: ${STATUS_FILE}" >&2
    echo "The install job may have failed or STATUS_FILE was not passed correctly." >&2
    exit 1
fi

MESA_TEST_DIR=$(cat "${STATUS_FILE}")

if [[ -z "${MESA_TEST_DIR}" || ! -d "${MESA_TEST_DIR}" ]]; then
    echo "ERROR: MESA_TEST_DIR '${MESA_TEST_DIR}' from status file does not exist." >&2
    exit 1
fi

echo "Launching tests for MESA worktree at: ${MESA_TEST_DIR}"

# ── Submit array jobs for all modules, collecting job IDs ─────────────────────
MODULE_JOB_IDS=()

for MODULE in "${MESA_MODULES[@]}"; do
    echo ""
    echo "--- Module: ${MODULE} ---"
    JOB_ID=$("${SCRIPT_DIR}/submit_module_tests.sh" "${MESA_TEST_DIR}" "${MODULE}")
    echo "  Submitted job ID: ${JOB_ID}"
    MODULE_JOB_IDS+=("${JOB_ID}")
done

# ── Submit cleanup job, dependent on all three module arrays finishing ─────────
# afterany:J1:J2:J3 fires once ALL listed jobs have reached a terminal state,
# regardless of exit status, so the worktree is removed whether tests pass or fail.
# This is what makes it safe to run multiple commits in parallel: each worktree
# cleans itself up independently.
DEPENDENCY_STR="afterany:${MODULE_JOB_IDS[0]}"
for JID in "${MODULE_JOB_IDS[@]:1}"; do
    DEPENDENCY_STR="${DEPENDENCY_STR}:${JID}"
done

CLEANUP_LOG="${MESA_TEST_DIR}/logs/cleanup.log"

CLEANUP_JOB_ID=$(sbatch --parsable \
    --partition="${SLURM_PARTITION}" \
    --nodes=1 \
    --ntasks-per-node="${CLEANUP_CPUS}" \
    --mem="${CLEANUP_MEM}" \
    --time="${CLEANUP_TIME}" \
    --job-name="mesa_cleanup" \
    --output="${CLEANUP_LOG}" \
    --error="${CLEANUP_LOG}" \
    --dependency="${DEPENDENCY_STR}" \
    --export=ALL,MESA_TEST_DIR="${MESA_TEST_DIR}",STATUS_FILE="${STATUS_FILE}" \
    "${SCRIPT_DIR}/cleanup_mesa.sh")

echo ""
echo "Cleanup job submitted: ${CLEANUP_JOB_ID}"
echo "  Depends on: ${DEPENDENCY_STR}"
echo "  Will remove: ${MESA_TEST_DIR}"
echo ""
echo "All module test arrays submitted."
