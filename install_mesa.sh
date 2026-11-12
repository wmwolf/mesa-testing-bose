#!/usr/bin/env bash
# install_mesa.sh — Slurm batch job: check out and build MESA, report the
# build result to testhub, then signal success or failure via exit code.
#
# Do not invoke directly. Submit via run_mesa_tests.sh, which sets the
# required environment variables.
#
# Required environment variables (set via --export when submitting):
#   STATUS_FILE    Path to a file where the MESA_TEST_DIR will be written on
#                  a successful build. Read later by launch_tests.sh.
#
# Optional environment variables:
#   VERSION        A git commit SHA or branch name to test. If unset or empty,
#                  mesa_test defaults to the HEAD of MESA's main branch.
#
# Exit codes:
#   0   Build succeeded; MESA_TEST_DIR written to STATUS_FILE.
#   1   Build failed; STATUS_FILE is not written. The --dependency=afterok
#       on launch_tests.sh will prevent tests from being submitted.
#
# Note on MESA_DIR: `module load mesa` sets MESA_DIR to the system MESA
# installation. We deliberately use MESA_TEST_DIR for the per-commit worktree
# to avoid any collision with that variable.

#SBATCH --nodes=1
#SBATCH --no-requeue
#SBATCH --job-name=mesa_install

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
source "${SCRIPT_DIR}/config.sh"

: "${STATUS_FILE:?STATUS_FILE must be set (passed via --export)}"

load_mesa_env
# After load_mesa_env, MESA_DIR is set to the system MESA installation by the
# mesa module. We do not touch it. All per-commit paths use MESA_TEST_DIR.

export OMP_NUM_THREADS="${INSTALL_CPUS}"

# ── Create a temporary build directory ───────────────────────────────────────
# We use mktemp to guarantee uniqueness across concurrent runs. After a
# successful build we resolve the commit SHA and rename to mesa_<sha8> for
# human-readable identification.
mkdir -p "${MESA_WORK_DIR}"
MESA_TEST_DIR=$(mktemp -d "${MESA_WORK_DIR}/mesa_XXXXXX")
echo "Temporary build directory: ${MESA_TEST_DIR}"
mkdir -p "${MESA_TEST_DIR}/logs"

# ── Install MESA ──────────────────────────────────────────────────────────────
echo "Pruning stale git worktree registrations..."
git -C "${HOME}/.mesa_test/mirror" worktree prune
if [[ -n "${VERSION:-}" ]]; then
    echo "Installing MESA at version/branch: ${VERSION}"
    mesa_test install --mesadir="${MESA_TEST_DIR}" "${VERSION}"
else
    echo "Installing MESA at HEAD of main"
    mesa_test install --mesadir="${MESA_TEST_DIR}"
fi

# ── Report build result to testhub ───────────────────────────────────────────
# submit --empty must always run regardless of build outcome so that testhub
# receives a report. It always exits 0, so we check build.log ourselves.
mesa_test submit --empty --mesadir="${MESA_TEST_DIR}"

# ── Check whether the build actually succeeded ────────────────────────────────
BUILD_LOG="${MESA_TEST_DIR}/build.log"

if ! grep -q "MESA installation was successful" "${BUILD_LOG}"; then
    echo "ERROR: MESA build failed. See ${BUILD_LOG} for details." >&2
    exit 1
fi

echo "Build succeeded."

# ── Rename directory to include commit SHA ────────────────────────────────────
# Resolve the SHA from the checked-out repo. This works whether VERSION was a
# branch name, a tag, an abbreviated SHA, or empty (HEAD of main).
COMMIT_SHA=$(cd "${MESA_TEST_DIR}" && git rev-parse HEAD)
SHORT_SHA="${COMMIT_SHA:0:8}"
NAMED_DIR="${MESA_WORK_DIR}/mesa_${SHORT_SHA}"

# Guard against a collision from a previous run that didn't clean up.
if [[ -d "${NAMED_DIR}" ]]; then
    echo "WARNING: ${NAMED_DIR} already exists (leftover from a previous run?)." >&2
    NAMED_DIR="${MESA_WORK_DIR}/mesa_${SHORT_SHA}_$(date +%s)"
    echo "Using ${NAMED_DIR} instead." >&2
fi

mv "${MESA_TEST_DIR}" "${NAMED_DIR}"
MESA_TEST_DIR="${NAMED_DIR}"
echo "Worktree renamed to: ${MESA_TEST_DIR}  (commit ${COMMIT_SHA})"

# ── Write the install path for the launcher job ───────────────────────────────
echo "${MESA_TEST_DIR}" > "${STATUS_FILE}"
echo "Wrote install path to ${STATUS_FILE}"
