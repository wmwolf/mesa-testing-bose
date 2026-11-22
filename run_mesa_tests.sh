#!/usr/bin/env bash
# run_mesa_tests.sh — Top-level entry point for MESA automated testing.
#
# Submits an install job and, if it succeeds, a launcher job that spawns
# array jobs for all three MESA modules (star, astero, binary).
#
# Usage:
#   run_mesa_tests.sh [options] [version]
#
#   --skip-optional   Skip optional inlists in all test cases by setting
#                     MESA_SKIP_OPTIONAL=t in each test job's environment.
#   --fpe             Enable floating point exception checks by setting
#                     MESA_FPE_CHECKS_ON=t. Affects both compilation and
#                     test runs. Off by default; any value set by the mesa
#                     module or your login environment is suppressed.
#   --converge[=F]    Convergence run: set MESA_TEST_SUITE_RESOLUTION_FACTOR=F
#                     for the test jobs (default F=0.8, mesa_test's default).
#                     Off by default; any value in your login environment is
#                     suppressed.
#   --branch=NAME     Record NAME as the branch in the tested-commit log.
#                     Only needed when version is a SHA; branch names given
#                     as version are recorded automatically.
#   --force           Run even if this commit was already tested with the
#                     same options (see "Tested-commit log" below).
#   --dry-run         Resolve the commit, run the duplicate check, and print
#                     what would be submitted, without submitting jobs or
#                     writing the log.
#   -h, --help        Show this help.
#   version           A git commit SHA, branch name, or tag. If omitted,
#                     mesa_test will test HEAD of MESA's main branch.
#
# Tested-commit log:
#   Each launch adds a row to MESA_RUN_LOG (default
#   ~/.mesa_test/tested_commits.csv; see README.md for the columns), and
#   cleanup_mesa.sh fills in its completion time. Before launching, the log
#   is checked: a run with the same commit SHA and the same set of options
#   (in any order) is refused unless --force is given. Branch names are
#   resolved to a SHA via the mesa_test mirror; if that fails, the check is
#   skipped with a warning and install_mesa.sh records the SHA it built.
#
# Example:
#   run_mesa_tests.sh                            # full tests, HEAD of main
#   run_mesa_tests.sh main                       # full tests, explicit branch
#   run_mesa_tests.sh --skip-optional main       # skip optional inlists
#   run_mesa_tests.sh --fpe main                 # enable FPE checks
#   run_mesa_tests.sh --fpe --skip-optional main # both flags
#   run_mesa_tests.sh --converge=0.5 main        # convergence run
#   run_mesa_tests.sh r24.08.1                   # a release tag
#   run_mesa_tests.sh --force main               # re-test a tested commit
#
# To let MESATestHub pick the commit and modes, use run_best_commit.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
source "${SCRIPT_DIR}/config.sh"

usage() {
    # Print the header comment above (everything up to the first non-comment).
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

VERSION=""
SKIP_OPTIONAL=""
FPE_CHECKS=""
CONVERGE=""
BRANCH=""
FORCE=""
DRY_RUN=""

for arg in "$@"; do
    case "${arg}" in
        --skip-optional) SKIP_OPTIONAL="t" ;;
        --fpe)           FPE_CHECKS="t"    ;;
        --converge)      CONVERGE="${DEFAULT_CONVERGE_FACTOR}" ;;
        --converge=*)    CONVERGE="${arg#--converge=}" ;;
        --branch=*)      BRANCH="${arg#--branch=}" ;;
        --force)         FORCE="t"   ;;
        --dry-run)       DRY_RUN="t" ;;
        -h|--help)       usage; exit 0 ;;
        -*)
            echo "ERROR: unknown option '${arg}'." >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
        *)
            if [[ -n "${VERSION}" ]]; then
                echo "ERROR: more than one version given ('${VERSION}' and '${arg}')." >&2
                exit 1
            fi
            VERSION="${arg}"
            ;;
    esac
done

if [[ -n "${CONVERGE}" && ! "${CONVERGE}" =~ ^([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]]; then
    echo "ERROR: --converge factor must be a positive number, got '${CONVERGE}'." >&2
    exit 1
fi

export MESA_SKIP_OPTIONAL="${SKIP_OPTIONAL}"
export MESA_FPE_CHECKS_ON="${FPE_CHECKS}"
export MESA_TEST_SUITE_RESOLUTION_FACTOR="${CONVERGE}"

[[ -n "${SKIP_OPTIONAL}" ]] && echo "Optional inlists will be skipped (MESA_SKIP_OPTIONAL=t)"
[[ -n "${FPE_CHECKS}"    ]] && echo "FPE checks enabled (MESA_FPE_CHECKS_ON=t)"
[[ -n "${CONVERGE}"      ]] && echo "Convergence run (MESA_TEST_SUITE_RESOLUTION_FACTOR=${CONVERGE})"

# ── Resolve the commit SHA ────────────────────────────────────────────────────
# Needed up front for the duplicate check. A full SHA is taken as-is; branch
# and tag names are looked up on the mirror's origin (falling back to the
# mirror's own refs, which also resolves abbreviated SHAs). install_mesa.sh
# records the SHA it actually built, so a wrong or missing guess here only
# affects the duplicate check, never the log's final record.
COMMIT_SHA=""
REF="${VERSION:-main}"

if [[ "${REF}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    COMMIT_SHA="${REF,,}"
elif [[ -d "${MESA_MIRROR_DIR}" ]]; then
    REMOTE_REFS=$(timeout 60 git -C "${MESA_MIRROR_DIR}" ls-remote origin \
        "refs/heads/${REF}" "refs/tags/${REF}" "refs/tags/${REF}^{}" 2>/dev/null || true)
    # Prefer a branch, then a peeled (annotated) tag, then a lightweight tag.
    for want in "refs/heads/${REF}" "refs/tags/${REF}^{}" "refs/tags/${REF}"; do
        COMMIT_SHA=$(awk -v w="${want}" '$2 == w { print $1; exit }' <<< "${REMOTE_REFS}")
        if [[ -n "${COMMIT_SHA}" ]]; then
            [[ "${want}" == refs/heads/* && -z "${BRANCH}" ]] && BRANCH="${REF}"
            break
        fi
    done
    if [[ -z "${COMMIT_SHA}" ]]; then
        COMMIT_SHA=$(git -C "${MESA_MIRROR_DIR}" rev-parse --verify --quiet "${REF}^{commit}" 2>/dev/null || true)
    fi
fi

if [[ -n "${COMMIT_SHA}" ]]; then
    echo "Commit: ${COMMIT_SHA}${BRANCH:+ (branch ${BRANCH})}"
else
    echo "WARNING: could not resolve '${REF}' to a commit SHA (mirror: ${MESA_MIRROR_DIR})." >&2
    echo "         Skipping the duplicate check; install_mesa.sh will record the SHA it builds." >&2
    # mesa_test builds main when no version is given, so that much is known.
    [[ -z "${VERSION}" && -z "${BRANCH}" ]] && BRANCH="main"
fi

# ── Duplicate check against the tested-commit log ─────────────────────────────
OPTION_TOKENS=()
[[ -n "${SKIP_OPTIONAL}" ]] && OPTION_TOKENS+=("skip-optional")
[[ -n "${FPE_CHECKS}"    ]] && OPTION_TOKENS+=("fpe")
[[ -n "${CONVERGE}"      ]] && OPTION_TOKENS+=("converge=${CONVERGE}")
OPTIONS=$(run_log canon "${OPTION_TOKENS[@]+"${OPTION_TOKENS[@]}"}")
OPTIONS_LABEL="${OPTIONS:-none (default full suite)}"

if [[ -n "${COMMIT_SHA}" ]]; then
    set +e
    DUPLICATE=$(run_log find-duplicate --sha "${COMMIT_SHA}" --options "${OPTIONS}")
    DUP_STATUS=$?
    set -e
    if [[ ${DUP_STATUS} -eq 0 ]]; then
        declare -A PREV=()
        while IFS='=' read -r key value; do PREV["${key}"]="${value}"; done <<< "${DUPLICATE}"
        if [[ -n "${PREV[completed_at]}" ]]; then
            PREV_DONE="completed ${PREV[completed_at]}"
        else
            PREV_DONE="not completed (cleanup never ran: the build failed, a job was cancelled, or it is still running)"
        fi
        if [[ -n "${FORCE}" ]]; then
            echo "NOTE: commit ${COMMIT_SHA:0:8} with options [${OPTIONS_LABEL}] was already tested" \
                 "(run ${PREV[run_id]}, started ${PREV[started_at]}); re-testing because of --force."
        else
            {
                echo ""
                echo "Refusing to re-test commit ${COMMIT_SHA} with options [${OPTIONS_LABEL}]."
                echo "An identical run is already in ${MESA_RUN_LOG}:"
                echo "  run ${PREV[run_id]}${PREV[branch]:+ on ${PREV[branch]}}"
                echo "  started ${PREV[started_at]}, ${PREV_DONE}"
                [[ "${PREV[count]}" -gt 1 ]] && echo "  (${PREV[count]} runs with this configuration in total)"
                echo ""
                echo "Pass --force to test it again anyway."
            } >&2
            exit 1
        fi
    elif [[ ${DUP_STATUS} -ne 1 ]]; then
        echo "ERROR: could not read the tested-commit log ${MESA_RUN_LOG}." >&2
        exit 1
    fi
fi

# ── Dry run: report and stop before touching anything ─────────────────────────
if [[ -n "${DRY_RUN}" ]]; then
    echo ""
    echo "[dry-run] Would add to ${MESA_RUN_LOG}:"
    echo "  commit_sha=${COMMIT_SHA:-<resolved by install job>}  branch=${BRANCH:-<none>}  options=[${OPTIONS_LABEL}]"
    echo "[dry-run] Would submit: install_mesa.sh (version: ${VERSION:-HEAD})" \
         "→ launch_tests.sh → module arrays → cleanup_mesa.sh"
    echo "[dry-run] Nothing submitted."
    exit 0
fi

# ── Ensure tmp directory exists on shared storage ─────────────────────────────
mkdir -p "${MESA_TMP_DIR}"

# ── Record the run in the tested-commit log ───────────────────────────────────
# The row is written before submitting, because the install job may update it.
# If the install job never gets submitted, the row is removed again so that a
# failed submission doesn't block a retry.
MESA_RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
export MESA_RUN_ID MESA_RUN_LOG
run_log add --run-id "${MESA_RUN_ID}" --started "$(date -Iseconds)" \
    --sha "${COMMIT_SHA}" --branch "${BRANCH}" --options "${OPTIONS}"
echo "Logged run ${MESA_RUN_ID} in ${MESA_RUN_LOG}"

INSTALL_SUBMITTED=""
remove_unsubmitted_row() {
    if [[ -z "${INSTALL_SUBMITTED}" ]]; then
        echo "Install job was not submitted; removing run ${MESA_RUN_ID} from the log." >&2
        run_log delete --run-id "${MESA_RUN_ID}" || true
    fi
}
trap remove_unsubmitted_row EXIT

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
    --export=ALL,VERSION="${VERSION}",STATUS_FILE="${STATUS_FILE}",MESA_FPE_CHECKS_ON="${MESA_FPE_CHECKS_ON}",MESA_RUN_ID="${MESA_RUN_ID}",MESA_RUN_LOG="${MESA_RUN_LOG}" \
    "${SCRIPT_DIR}/install_mesa.sh")
INSTALL_SUBMITTED="t"

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
    --export=ALL,STATUS_FILE="${STATUS_FILE}",MESA_SKIP_OPTIONAL="${MESA_SKIP_OPTIONAL}",MESA_FPE_CHECKS_ON="${MESA_FPE_CHECKS_ON}",MESA_TEST_SUITE_RESOLUTION_FACTOR="${MESA_TEST_SUITE_RESOLUTION_FACTOR}",MESA_RUN_ID="${MESA_RUN_ID}",MESA_RUN_LOG="${MESA_RUN_LOG}" \
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
