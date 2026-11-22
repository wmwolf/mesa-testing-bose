#!/usr/bin/env bash
# tests/run_tests.sh — Exercise run_mesa_tests.sh, run_best_commit.sh, and the
# tested-commit log without Slurm, MESA, or MESATestHub.
#
# Stubs in tests/stubs/ stand in for sbatch (runs each job script
# synchronously), module, and mesa_test (fake install/test against a local
# git repository; canned request_work answers). Everything happens under a
# throwaway HOME, so your real ~/.mesa_test is never touched.
#
# Usage: tests/run_tests.sh      (needs bash, git, python3)

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX=$(mktemp -d)
trap 'rm -rf "${SANDBOX}"' EXIT

export HOME="${SANDBOX}/home"
export STUB_STATE="${SANDBOX}/state"
export STUB_UPSTREAM="${SANDBOX}/upstream.git"
export PATH="${REPO}/tests/stubs:${PATH}"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset MESA_WORK_DIR MESA_TMP_DIR MESA_RUN_LOG MESA_MIRROR_DIR MESA_TEST_SUITE_RESOLUTION_FACTOR
mkdir -p "${HOME}" "${STUB_STATE}"
LOG="${HOME}/.mesa_test/tested_commits.csv"

# ── Fake MESA repository: main, a feature branch, an annotated tag ────────────
SRC="${SANDBOX}/src"
git init -q -b main "${SRC}"
git -C "${SRC}" commit -q --allow-empty -m one
git -C "${SRC}" tag -a r1 -m "release 1"
git -C "${SRC}" commit -q --allow-empty -m two
git -C "${SRC}" checkout -q -b feature
git -C "${SRC}" commit -q --allow-empty -m three
git -C "${SRC}" checkout -q main
git clone -q --bare "${SRC}" "${STUB_UPSTREAM}"
git clone -q --mirror "${STUB_UPSTREAM}" "${HOME}/.mesa_test/mirror"
MAIN_SHA=$(git -C "${SRC}" rev-parse main)
FEATURE_SHA=$(git -C "${SRC}" rev-parse feature)
R1_SHA=$(git -C "${SRC}" rev-parse 'r1^{commit}')

# ── Tiny assertion helpers ────────────────────────────────────────────────────
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && sed 's/^/       | /' <<< "$2"; }
check()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected: $3"$'\n'"got:      $2"; fi; }
contains() { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing '$3' in:"$'\n'"$2"; fi; }
lacks()    { if grep -qF -- "$3" <<< "$2"; then bad "$1" "unexpected '$3' in:"$'\n'"$2"; else ok "$1"; fi; }
rows()     { [[ -f "${LOG}" ]] && tail -n +2 "${LOG}" | grep -c . || echo 0; }
field()    { python3 -c 'import csv,sys; r=list(csv.DictReader(open(sys.argv[1]))); print(r[int(sys.argv[2])][sys.argv[3]])' "${LOG}" "$1" "$2"; }
run()      { OUT=$("$@" 2>&1); STATUS=$?; }
reset_state() { rm -rf "${STUB_STATE}"; mkdir -p "${STUB_STATE}"; }

RMT="${REPO}/run_mesa_tests.sh"
RBC="${REPO}/run_best_commit.sh"

echo "== run_log.py canonicalisation"
check "option order doesn't matter" \
    "$(python3 "${REPO}/run_log.py" --log "${LOG}" canon fpe skip-optional converge=0.80)" \
    "$(python3 "${REPO}/run_log.py" --log "${LOG}" canon converge=0.8 skip-optional fpe)"
check "no options canonicalises to empty" "$(python3 "${REPO}/run_log.py" --log "${LOG}" canon)" ""

echo "== run_mesa_tests.sh --dry-run"
run "${RMT}" --dry-run main
check "dry run exits 0" "${STATUS}" 0
contains "dry run resolves branch to SHA" "${OUT}" "Commit: ${MAIN_SHA} (branch main)"
check "dry run writes no log" "$(rows)" 0
check "dry run submits nothing" "$(cat "${STUB_STATE}/sbatch_calls" 2>/dev/null)" ""
run "${RMT}" --dry-run r1
contains "annotated tag resolves to its commit" "${OUT}" "Commit: ${R1_SHA}"
lacks "tag is not recorded as a branch" "${OUT}" "(branch r1)"
run "${RMT}" --dry-run
contains "no version means main" "${OUT}" "Commit: ${MAIN_SHA} (branch main)"

echo "== bad arguments"
run "${RMT}" --frce main
check "unknown option rejected" "${STATUS}" 1
contains "unknown option named" "${OUT}" "unknown option '--frce'"
run "${RMT}" --converge=abc main
check "bad converge factor rejected" "${STATUS}" 1
run "${RMT}" main feature
check "two versions rejected" "${STATUS}" 1
run "${RMT}" --help
contains "--help prints usage" "${OUT}" "--force"

echo "== full run through the stub Slurm chain"
reset_state
run "${RMT}" main
check "run exits 0" "${STATUS}" 0
check "one log row" "$(rows)" 1
check "row has full SHA" "$(field 0 commit_sha)" "${MAIN_SHA}"
check "row has branch" "$(field 0 branch)" "main"
check "row has no options" "$(field 0 options)" ""
contains "started_at is ISO 8601" "$(field 0 started_at)" "T"
contains "cleanup stamped completed_at" "$(field 0 completed_at)" "T"
check "all 3 modules x 2 tests ran" "$(grep -c '^test ' "${STUB_STATE}/tests_run")" 6
contains "resolution factor unset when not converging" "$(cat "${STUB_STATE}/tests_run")" "res=<unset>"
check "worktree cleaned up" "$(ls -d "${HOME}"/.mesa_test/work/mesa_* 2>/dev/null)" ""

echo "== duplicate guard"
reset_state
run "${RMT}" main
check "identical rerun refused (exit 1)" "${STATUS}" 1
contains "refusal names the commit" "${OUT}" "Refusing to re-test commit ${MAIN_SHA}"
contains "refusal names the earlier run" "${OUT}" "run $(field 0 run_id) on main"
contains "refusal says it completed" "${OUT}" "completed $(field 0 completed_at)"
contains "refusal suggests --force" "${OUT}" "--force"
check "refusal adds no row" "$(rows)" 1
check "refusal submits nothing" "$(cat "${STUB_STATE}/sbatch_calls" 2>/dev/null)" ""
run "${RMT}" "${MAIN_SHA}"
check "same commit given as SHA is also refused" "${STATUS}" 1
run "${RMT}" --fpe main
check "different options are allowed" "${STATUS}" 0
contains "fpe reaches the test jobs" "$(cat "${STUB_STATE}/tests_run")" "fpe=t"
run "${RMT}" --skip-optional --fpe main
check "fpe+skip-optional allowed (new set)" "${STATUS}" 0
run "${RMT}" --fpe --skip-optional "${MAIN_SHA}"
check "same set in other order is refused" "${STATUS}" 1
reset_state
run "${RMT}" --force main
check "--force reruns" "${STATUS}" 0
contains "--force says why" "${OUT}" "re-testing because of --force"
check "--force adds a row" "$(rows)" 4
run "${RMT}" main
contains "refusal counts repeated runs" "${OUT}" "(2 runs with this configuration in total)"

echo "== converge"
reset_state
run "${RMT}" --converge=0.50 main
check "converge run exits 0" "${STATUS}" 0
check "converge factor canonicalised in log" "$(field 4 options)" "converge=0.5"
contains "factor reaches the test jobs" "$(cat "${STUB_STATE}/tests_run")" "res=0.50"
run "${RMT}" --converge=0.5 main
check "same factor written differently is refused" "${STATUS}" 1
run "${RMT}" --converge main
check "--converge (default 0.8) is a different config" "${STATUS}" 0
check "default factor recorded" "$(field 5 options)" "converge=0.8"

echo "== failed build leaves completed_at blank"
reset_state
STUB_BUILD_FAIL=1 run "${RMT}" feature
check "build-failure row written" "$(field 6 commit_sha)" "${FEATURE_SHA}"
check "completed_at blank (cleanup never ran)" "$(field 6 completed_at)" ""
check "no tests ran" "$(cat "${STUB_STATE}/tests_run" 2>/dev/null)" ""
run "${RMT}" feature
check "retry of failed build is refused" "${STATUS}" 1
contains "refusal says it never completed" "${OUT}" "not completed (cleanup never ran"

echo "== submission failure rolls back the row"
reset_state
STUB_SBATCH_FAIL=1 run "${RMT}" --fpe feature
check "sbatch failure exits non-zero" "$([[ ${STATUS} -ne 0 ]] && echo yes)" yes
contains "rollback is announced" "${OUT}" "removing run"
check "no row left behind" "$(rows)" 7

echo "== unresolvable version: install job records the SHA"
reset_state
run "${RMT}" "${FEATURE_SHA:0:10}"  # abbreviated SHA: resolved via the mirror
contains "abbreviated SHA resolved via mirror" "${OUT}" "Commit: ${FEATURE_SHA}"
reset_state
# Point only the launch-time lookup at a missing mirror; the install job
# (like the real one) still uses ~/.mesa_test/mirror.
MESA_MIRROR_DIR="${SANDBOX}/no-such-mirror" run "${RMT}" --skip-optional feature
contains "warns that the check is skipped" "${OUT}" "Skipping the duplicate check"
check "install job filled in the SHA" "$(field 7 commit_sha)" "${FEATURE_SHA}"
contains "and cleanup still stamped it" "$(field 7 completed_at)" "T"

echo "== run_best_commit.sh: parsing request_work"
SAMPLE_SHA=cc281a57addd11fd46370c6c1584d2b1fc2734cd
for mode in sample sample_stdout; do
    reset_state
    STUB_REQUEST_WORK=${mode} run "${RBC}" --dry-run
    check "${mode}: exits 0" "${STATUS}" 0
    contains "${mode}: launches with full SHA" "${OUT}" "run_mesa_tests.sh --dry-run --branch=pulse-double-points-composition ${SAMPLE_SHA}"
    lacks "${mode}: use_full_inlists=false does not add --skip-optional" "${OUT}" "--skip-optional"
    lacks "${mode}: no --fpe" "${OUT}" "--fpe"
    contains "${mode}: reaches run_mesa_tests dry run" "${OUT}" "[dry-run] Nothing submitted."
done
for mode in nowork minus3_stdout minus3_exit; do
    reset_state
    STUB_REQUEST_WORK=${mode} run "${RBC}"
    check "${mode}: exits 0" "${STATUS}" 0
    contains "${mode}: friendly message" "${OUT}" "MESATestHub has no work for this computer right now."
    check "${mode}: nothing submitted" "$(cat "${STUB_STATE}/sbatch_calls" 2>/dev/null)" ""
done
reset_state
STUB_REQUEST_WORK=error run "${RBC}"
check "request_work error: non-zero exit" "${STATUS}" 1
contains "request_work error: explained" "${OUT}" "'mesa_test request_work' failed (exit 1)"
STUB_REQUEST_WORK=garbage run "${RBC}"
check "unparseable output: exit 1" "${STATUS}" 1
STUB_REQUEST_WORK=test_scope run "${RBC}"
check "scope=test: fails loudly" "${STATUS}" 1
contains "scope=test: explained" "${OUT}" "only does full build-and-test runs"
STUB_REQUEST_WORK=unknown_flag run "${RBC}"
check "unknown flag: fails loudly" "${STATUS}" 1
contains "unknown flag: named" "${OUT}" "use_gpu"
STUB_REQUEST_WORK=fpe_converge run "${RBC}" --dry-run
contains "fpe + named converge factor mapped" "${OUT}" "--fpe --converge=0.5 --branch="
lacks "use_full_inlists=true adds nothing" "${OUT}" "--skip-optional"
STUB_REQUEST_WORK=converge_nofac run "${RBC}" --dry-run
contains "converge without factor uses default" "${OUT}" "--converge --branch="
check "no sbatch during any of the above" "$(cat "${STUB_STATE}/sbatch_calls" 2>/dev/null)" ""
run "${RBC}" --bogus
check "run_best_commit rejects unknown args" "${STATUS}" 1

echo "== run_best_commit.sh: end to end"
reset_state
export STUB_REQUEST_WORK=real STUB_SHA="${R1_SHA}" STUB_BRANCH=hub-branch
STUB_FLAGS='{ "use_full_inlists": true, "use_fpe": true, "use_converge": false }' run "${RBC}"
check "end-to-end run exits 0" "${STATUS}" 0
check "row SHA from hub" "$(field 8 commit_sha)" "${R1_SHA}"
check "row branch from hub" "$(field 8 branch)" "hub-branch"
check "row options from hub flags" "$(field 8 options)" "fpe"
contains "row completed" "$(field 8 completed_at)" "T"
STUB_FLAGS='{ "use_full_inlists": false, "use_fpe": true, "use_converge": false }' run "${RBC}"
check "hub re-picking a tested config is refused" "${STATUS}" 1
contains "refusal names the run" "${OUT}" "run $(field 8 run_id) on hub-branch"
STUB_FLAGS='{ "use_full_inlists": false, "use_fpe": true, "use_converge": false }' run "${RBC}" --force
check "run_best_commit --force passes through" "${STATUS}" 0
check "forced row added" "$(rows)" 10
unset STUB_REQUEST_WORK STUB_SHA STUB_BRANCH

echo ""
echo "Final log:"
column -s, -t < "${LOG}" 2>/dev/null || cat "${LOG}"
echo ""
echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
