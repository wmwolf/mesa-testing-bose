#!/usr/bin/env bash
# cleanup_mesa.sh — Slurm job that removes a MESA worktree after all module
# test array jobs have finished.
#
# This job is submitted by launch_tests.sh with:
#   --dependency=afterany:<star_jid>:<astero_jid>:<binary_jid>
# so it runs once all three arrays reach a terminal state, regardless of
# whether individual tests passed or failed.
#
# Required environment variables (set via --export when submitting):
#   MESA_TEST_DIR   Path to the MESA worktree to remove.
#   STATUS_FILE     Path to the mktemp status file to remove.

#SBATCH --nodes=1
#SBATCH --no-requeue
#SBATCH --job-name=mesa_cleanup

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
source "${SCRIPT_DIR}/config.sh"

: "${MESA_TEST_DIR:?MESA_TEST_DIR must be set (passed via --export)}"
: "${STATUS_FILE:?STATUS_FILE must be set (passed via --export)}"

echo "Cleanup starting for: ${MESA_TEST_DIR}"

# ── Sanity checks before removing anything ────────────────────────────────────
# Refuse to delete something outside the expected work directory to guard
# against a mis-set MESA_TEST_DIR accidentally wiping unrelated data.
if [[ ! -d "${MESA_TEST_DIR}" ]]; then
    echo "WARNING: MESA_TEST_DIR '${MESA_TEST_DIR}' does not exist. Nothing to remove." >&2
    exit 0
fi

REAL_TEST_DIR=$(realpath "${MESA_TEST_DIR}")
REAL_WORK_DIR=$(realpath "${MESA_WORK_DIR}")

if [[ "${REAL_TEST_DIR}" != "${REAL_WORK_DIR}"/* ]]; then
    echo "ERROR: MESA_TEST_DIR '${REAL_TEST_DIR}' is not under MESA_WORK_DIR '${REAL_WORK_DIR}'." >&2
    echo "Refusing to delete a directory outside the expected work tree." >&2
    exit 1
fi

# ── Remove the worktree ───────────────────────────────────────────────────────
echo "Removing worktree: ${REAL_TEST_DIR}"
rm -rf "${REAL_TEST_DIR}"
echo "Worktree removed."

# ── Remove the status file ────────────────────────────────────────────────────
if [[ -f "${STATUS_FILE}" ]]; then
    rm -f "${STATUS_FILE}"
    echo "Status file removed: ${STATUS_FILE}"
fi

echo "Cleanup complete."
