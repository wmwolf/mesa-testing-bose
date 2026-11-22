#!/usr/bin/env bash
# run_best_commit.sh — Ask MESATestHub which commit and modes this computer
# should test next, then launch run_mesa_tests.sh with them.
#
# Usage:
#   run_best_commit.sh [--force] [--dry-run]
#
#   --force     Passed to run_mesa_tests.sh: test even if this commit was
#               already tested here with the same options.
#   --dry-run   Show what MESATestHub picked and the run_mesa_tests.sh command,
#               and run its duplicate check, without submitting anything.
#   -h, --help  Show this help.
#
# Runs `mesa_test request_work` (read-only: nothing is claimed on the hub),
# then maps its JSON answer onto run_mesa_tests.sh options:
#
#   commit_sha               → version (full SHA)
#   branch                   → --branch=NAME
#   flags.use_fpe            → --fpe
#   flags.use_converge       → --converge=<converge_factor> (or --converge)
#   flags.use_full_inlists   → nothing: full inlists are already the default
#   scope=test / test_case_* → refused: run_mesa_tests.sh only does full
#                              build-and-test runs
#
# The modes MESATestHub may ask for are limited to what this computer offers,
# set by `capabilities` in ~/.mesa_test/config.yml (see `mesa_test setup`).
#
# Exits 0 without testing if MESATestHub has nothing for this computer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
source "${SCRIPT_DIR}/config.sh"

usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

PASSTHROUGH=()
for arg in "$@"; do
    case "${arg}" in
        --force|--dry-run) PASSTHROUGH+=("${arg}") ;;
        -h|--help)         usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument '${arg}'." >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
    esac
done

no_work() {
    echo "MESATestHub has no work for this computer right now. Nothing launched."
    exit 0
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# ── Ask MESATestHub ───────────────────────────────────────────────────────────
# STDERR (mesa_test's "MESATestHub picked ..." line, or its errors) goes
# straight to the terminal; only STDOUT is parsed. If mesa_test isn't already
# on PATH, load the cluster modules for it in a subshell, so they don't leak
# into the environment run_mesa_tests.sh exports to its jobs.
echo "Asking MESATestHub for work..."
set +e
if command -v mesa_test > /dev/null 2>&1; then
    mesa_test request_work > "${WORK_DIR}/request_work.out"
else
    ( load_mesa_env > /dev/null 2>&1 || true
      command -v mesa_test > /dev/null 2>&1 || { echo "ERROR: mesa_test not found, even after load_mesa_env." >&2; exit 127; }
      mesa_test request_work ) > "${WORK_DIR}/request_work.out"
fi
STATUS=$?
set -e

# mesa_test exits 3 (NOTHING_TO_DO_EXIT) with empty STDOUT when there is no
# work. 253 is what a shell sees if something ever exits with -3.
case "${STATUS}" in
    0)      ;;
    3|253)  no_work ;;
    *)
        echo "ERROR: 'mesa_test request_work' failed (exit ${STATUS}). Nothing launched." >&2
        exit "${STATUS}"
        ;;
esac

# ── Map the answer onto run_mesa_tests.sh arguments ───────────────────────────
set +e
python3 "${SCRIPT_DIR}/parse_request_work.py" "${WORK_DIR}/request_work.out" > "${WORK_DIR}/args"
STATUS=$?
set -e
case "${STATUS}" in
    0) ;;
    3) no_work ;;
    *) echo "Nothing launched." >&2; exit 1 ;;
esac

ARGS=()
while IFS= read -r -d '' a; do ARGS+=("${a}"); done < "${WORK_DIR}/args"

CMD=("${SCRIPT_DIR}/run_mesa_tests.sh" "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}" "${ARGS[@]}")
echo "Running: $(printf '%q ' "${CMD[@]}")"
echo ""
exec "${CMD[@]}"
