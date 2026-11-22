#!/usr/bin/env python3
"""run_log.py -- maintain the tested-commit CSV (MESA_RUN_LOG in config.sh).

One row per run_mesa_tests.sh launch. Columns:

  started_at    When run_mesa_tests.sh launched the run (ISO 8601, local time).
  commit_sha    Full 40-character SHA. Filled at launch when it can be
                resolved; install_mesa.sh corrects it after checkout.
  branch        Branch name, if known (blank for bare SHAs and tags).
  completed_at  When cleanup_mesa.sh ran. Blank if cleanup never ran (build
                failed, a submission failed, or the run is still in flight).
  options       Run modes, canonicalised: space-separated, sorted, e.g.
                "converge=0.8 fpe". Blank means the default full test suite.
  run_id        Unique ID tying the Slurm jobs of one run to its row.

Writes take a lock (LOG.lock) and replace the file atomically, so the login
node and compute nodes can update it concurrently. Kept to the Python 3.6
standard library so it runs with a cluster's system python3.

Subcommands (all take --log PATH):
  canon OPTION...                        print the canonical options string
  find-duplicate --sha SHA --options S   print the latest matching row as
                                         KEY=VALUE lines; exit 1 if none
  add --run-id ID --started T --sha SHA --branch B --options S
  set --run-id ID FIELD VALUE            set one field of an existing row
  get --run-id ID FIELD                  print one field of a row
  delete --run-id ID                     remove a row
"""

import argparse
import csv
import fcntl
import os
import sys
import tempfile
from contextlib import contextmanager

FIELDS = ["started_at", "commit_sha", "branch", "completed_at", "options", "run_id"]


def die(msg):
    sys.stderr.write("run_log.py: %s\n" % msg)
    sys.exit(2)


def canonical_options(tokens):
    """Sorted, de-duplicated, whitespace-joined run modes.

    Order never matters, and converge factors are compared numerically
    ("converge=0.80" == "converge=0.8").
    """
    out = set()
    for tok in " ".join(tokens).split():
        if tok.startswith("converge="):
            value = tok.split("=", 1)[1]
            try:
                value = format(float(value), "g")
            except ValueError:
                die("bad converge factor in option %r" % tok)
            tok = "converge=" + value
        out.add(tok)
    return " ".join(sorted(out))


@contextmanager
def locked(path):
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    with open(path + ".lock", "a") as lock:
        # lockf (POSIX record locks) rather than flock: it is the variant that
        # works across NFS clients, which is how compute nodes see $HOME.
        fcntl.lockf(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.lockf(lock, fcntl.LOCK_UN)


def read_rows(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != FIELDS:
            die("%s has unexpected columns %s (expected %s)"
                % (path, reader.fieldnames, FIELDS))
        return list(reader)


def write_rows(path, rows):
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tested_commits.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=FIELDS)
            writer.writeheader()
            writer.writerows(rows)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def find_row(rows, run_id):
    for row in rows:
        if row["run_id"] == run_id:
            return row
    die("no row with run_id %r" % run_id)


def main():
    p = argparse.ArgumentParser(description="Maintain the tested-commit CSV.")
    p.add_argument("--log", required=True)
    sub = p.add_subparsers(dest="cmd")

    s = sub.add_parser("canon")
    s.add_argument("tokens", nargs="*")

    s = sub.add_parser("find-duplicate")
    s.add_argument("--sha", required=True)
    s.add_argument("--options", default="")

    s = sub.add_parser("add")
    for name in ("--run-id", "--started", "--sha"):
        s.add_argument(name, required=True)
    s.add_argument("--branch", default="")
    s.add_argument("--options", default="")

    s = sub.add_parser("set")
    s.add_argument("--run-id", required=True)
    s.add_argument("field", choices=FIELDS[:-1])
    s.add_argument("value")

    s = sub.add_parser("get")
    s.add_argument("--run-id", required=True)
    s.add_argument("field", choices=FIELDS)

    s = sub.add_parser("delete")
    s.add_argument("--run-id", required=True)

    a = p.parse_args()
    if a.cmd is None:
        p.error("a subcommand is required")

    if a.cmd == "canon":
        print(canonical_options(a.tokens))
        return 0

    if a.cmd in ("find-duplicate", "get"):
        rows = read_rows(a.log)
        if a.cmd == "get":
            print(find_row(rows, a.run_id)[a.field])
            return 0
        want = canonical_options([a.options])
        matches = [r for r in rows
                   if r["commit_sha"] == a.sha
                   and canonical_options([r["options"]]) == want]
        if not matches:
            return 1
        for key in FIELDS:
            print("%s=%s" % (key, matches[-1][key]))
        print("count=%d" % len(matches))
        return 0

    with locked(a.log):
        rows = read_rows(a.log)
        if a.cmd == "add":
            if any(r["run_id"] == a.run_id for r in rows):
                die("run_id %r already exists" % a.run_id)
            rows.append({"started_at": a.started, "commit_sha": a.sha,
                         "branch": a.branch, "completed_at": "",
                         "options": canonical_options([a.options]),
                         "run_id": a.run_id})
        elif a.cmd == "set":
            find_row(rows, a.run_id)[a.field] = a.value
        elif a.cmd == "delete":
            find_row(rows, a.run_id)
            rows = [r for r in rows if r["run_id"] != a.run_id]
        write_rows(a.log, rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
