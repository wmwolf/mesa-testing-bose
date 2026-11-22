# mesa-testing-bose

Scripts for running MESA's test suite on a Slurm cluster with
[`mesa_test`](https://github.com/MESAHub/mesa_test) and reporting the results
to [MESATestHub](https://testhub.mesastar.org).

## Pipeline

```
run_mesa_tests.sh (login node)
  └─ install_mesa.sh         Slurm job: mesa_test install + submit --empty
       └─ launch_tests.sh    Slurm job (afterok): one array job per module
            ├─ submit_module_tests.sh → run_module_test_job.sh   (star, astero, binary)
            └─ cleanup_mesa.sh   Slurm job (afterany on all arrays): remove the worktree
```

Settings (partition, resources, work directory, log location) live in
`config.sh`; any of the `${VAR:-default}` settings can be overridden from the
environment.

## Running tests

### Let MESATestHub choose: `run_best_commit.sh`

```bash
./run_best_commit.sh             # ask the hub, then launch run_mesa_tests.sh
./run_best_commit.sh --dry-run   # show the pick and the command; submit nothing
./run_best_commit.sh --force     # launch even if this config was already tested here
```

It runs `mesa_test request_work` (read-only; nothing is claimed), maps the
answer onto `run_mesa_tests.sh` options, and runs it:

| `request_work` field                 | `run_mesa_tests.sh` argument                         |
|--------------------------------------|------------------------------------------------------|
| `commit_sha`                         | version (full SHA)                                   |
| `branch`                             | `--branch=NAME` (recorded in the log)                |
| `flags.use_fpe: true`                | `--fpe`                                              |
| `flags.use_converge: true`           | `--converge=<converge_factor>`, or `--converge` (0.8) if no factor |
| `flags.use_full_inlists`             | nothing: every inlist already runs by default        |
| `scope: "test"`, `test_case_*` set   | refused with an error (see below)                    |

Notes:

- `use_full_inlists: false` does **not** add `--skip-optional`. As in
  `mesa_test` itself, a hub request only ever *adds* modes; `false` means
  "not required".
- `scope: "test"` (run one test case on a commit already built) has no
  equivalent here, because this pipeline always builds a fresh worktree, runs
  every test case, and then deletes it. `run_best_commit.sh` only asks for
  `scope: "build"`, so this should not come up; if it does, the script stops
  with an error instead of guessing. Unknown flags set to `true` are refused
  the same way.
- When there is no work, `mesa_test request_work` exits with status 3 and
  prints nothing on STDOUT. `run_best_commit.sh` then prints a short message
  and exits 0. It also treats a printed `-3`, empty output, or exit status
  253 (what a shell sees for `exit -3`) as "no work".
- Which modes the hub may ask for depends on the `capabilities` in
  `~/.mesa_test/config.yml` (set with `mesa_test setup`). `run_mesa_tests.sh`
  supports FPE, convergence, and full-inlist runs.
- Requires `python3` (3.3+) to parse the JSON.

### Choose yourself: `run_mesa_tests.sh`

```bash
./run_mesa_tests.sh                            # full tests, HEAD of main
./run_mesa_tests.sh main                       # explicit branch
./run_mesa_tests.sh --skip-optional main       # skip optional inlists
./run_mesa_tests.sh --fpe main                 # FPE checks (compile + run)
./run_mesa_tests.sh --converge=0.5 main        # convergence run
./run_mesa_tests.sh r24.08.1                   # a release tag
./run_mesa_tests.sh --dry-run main             # resolve + duplicate check only
./run_mesa_tests.sh --force main               # re-test a tested configuration
./run_mesa_tests.sh --help
```

`--converge` without a factor uses 0.8, `mesa_test`'s default. As with
`--fpe`, a `MESA_TEST_SUITE_RESOLUTION_FACTOR` already set in your login
environment is ignored, so the log always records what actually ran.

## Tested-commit log

Every launch adds a row to `~/.mesa_test/tested_commits.csv` (override with
`MESA_RUN_LOG`):

| column         | meaning |
|----------------|---------|
| `started_at`   | When `run_mesa_tests.sh` launched the run (ISO 8601, local time). |
| `commit_sha`   | Full SHA. Resolved at launch when possible; `install_mesa.sh` overwrites it with the commit it actually checked out. |
| `branch`       | Branch, if known (from a branch-name version, `--branch=`, or the hub). Blank for tags and bare SHAs. |
| `completed_at` | When `cleanup_mesa.sh` ran, i.e. after every module array finished. **Blank** if cleanup never ran: the build failed (so the launcher was cancelled), a job was cancelled, or the run is still in flight. |
| `options`      | Run modes, sorted and space-separated: some of `converge=F`, `fpe`, `skip-optional`. Blank means the default full suite. |
| `run_id`       | Unique ID passed down to the Slurm jobs so they can update the right row. |

Example:

```csv
started_at,commit_sha,branch,completed_at,options,run_id
2026-11-22T13:27:16-06:00,cc281a57addd11fd46370c6c1584d2b1fc2734cd,pulse-double-points-composition,2026-11-22T21:04:51-06:00,,20261122T132716-48213
2026-11-22T13:40:02-06:00,cc281a57addd11fd46370c6c1584d2b1fc2734cd,pulse-double-points-composition,,converge=0.5 fpe,20261122T134002-49120
```

**Duplicate guard.** Before submitting, `run_mesa_tests.sh` looks for an
earlier row with the same `commit_sha` and the same set of options (order
doesn't matter, and `0.50` equals `0.5`). If it finds one, it refuses, names
that run, says whether it completed, and exits 1. Pass `--force` to run
anyway; the new run gets its own row. Runs that never completed (e.g. a
failed build) also count, so retrying a broken build needs `--force`.

Branch and tag names are resolved to a SHA with `git ls-remote` against the
`mesa_test` mirror's origin, falling back to the mirror's own refs (which
also resolves abbreviated SHAs). If that fails, the check is skipped with a
warning and the install job fills in the SHA.

**Where the file lives.** The log is per-machine state, so it lives next to
`mesa_test`'s own config and mirror in `~/.mesa_test/`, outside this
repository. It is not under `MESA_WORK_DIR`, which may be purgeable scratch.
It must be on storage the compute nodes can write, because `cleanup_mesa.sh`
writes the completion time from a compute node. Writes are locked
(`tested_commits.csv.lock`) and atomic, so concurrent jobs are safe.
`.gitignore` excludes the file anyway, in case `MESA_RUN_LOG` is ever pointed
into the checkout.

The log is plain CSV; edit or delete rows by hand to forget a run.
`run_log.py` (used by the scripts) can also do it:

```bash
python3 run_log.py --log ~/.mesa_test/tested_commits.csv delete --run-id 20261122T132716-48213
```

## Testing the scripts

```bash
tests/run_tests.sh
```

This runs the whole pipeline against stub `sbatch`, `module`, and `mesa_test`
commands (in `tests/stubs/`) under a throwaway `$HOME`. The stub `sbatch` runs
each job immediately and honours `--export` and `afterok` dependencies. No
Slurm, MESA, or network is needed, and your real `~/.mesa_test` is never
touched.
