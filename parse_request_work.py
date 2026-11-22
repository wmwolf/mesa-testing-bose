#!/usr/bin/env python3
"""parse_request_work.py -- turn `mesa_test request_work` output into
run_mesa_tests.sh arguments.

Usage: parse_request_work.py FILE

FILE holds the STDOUT of `mesa_test request_work`. On success, prints the
arguments for run_mesa_tests.sh to STDOUT, NUL-separated, and exits 0.
Exits 3 if the output says there is no work, and 1 (with a message on STDERR)
if it can't be parsed or asks for something run_mesa_tests.sh can't do.

The parsing is deliberately forgiving about *format*: mesa_test (2.0) prints
pure JSON on STDOUT and its "MESATestHub picked ..." line on STDERR, but any
text before the JSON object is skipped, and empty output or a bare "-3" is
taken to mean "no work". It is strict about *content*: anything it doesn't
know how to map is an error rather than silently dropped.

Field mapping (mirrors mesa_test's own dispatch_run_modes):
  commit_sha                      -> positional version (full SHA)
  branch                          -> --branch=NAME (recorded in the log)
  flags.use_fpe = true            -> --fpe
  flags.use_converge = true       -> --converge=<converge_factor>, or
                                     --converge (factor 0.8) if none named
  flags.use_full_inlists          -> no argument. run_mesa_tests.sh already
                                     runs every inlist unless --skip-optional
                                     is given, and as in mesa_test a request
                                     only ever adds modes: false means "not
                                     required", not "skip optional inlists".
  scope = "build"                 -> a full build-and-test run
  scope = "test", test_case_*     -> error: run_mesa_tests.sh can't run a
                                     single test on an existing build.
"""

import json
import re
import sys

NO_WORK = 3
KNOWN_FLAGS = ("use_full_inlists", "use_fpe", "use_converge")


def fail(msg):
    sys.stderr.write("ERROR: %s\n" % msg)
    sys.exit(1)


def find_record(text):
    """First JSON object in text, skipping any leading non-JSON lines."""
    decoder = json.JSONDecoder()
    pos = text.find("{")
    while pos != -1:
        try:
            obj, _ = decoder.raw_decode(text, pos)
            if isinstance(obj, dict):
                return obj
        except ValueError:
            pass
        pos = text.find("{", pos + 1)
    return None


def main():
    if len(sys.argv) != 2:
        fail("usage: parse_request_work.py FILE")
    with open(sys.argv[1]) as f:
        text = f.read()

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines or lines == ["-3"] or lines[-1] == "-3":
        return NO_WORK

    rec = find_record(text)
    if rec is None:
        if text.strip() in ("null", "{}"):
            return NO_WORK
        fail("no JSON object found in `mesa_test request_work` output:\n%s" % text)
    if not rec:
        return NO_WORK

    scope = rec.get("scope") or "build"
    if scope != "build":
        fail("MESATestHub asked for scope '%s' (module %s, test %s), but "
             "run_mesa_tests.sh only does full build-and-test runs."
             % (scope, rec.get("test_case_module"), rec.get("test_case_name")))
    if rec.get("test_case_module") or rec.get("test_case_name"):
        fail("MESATestHub asked for a single test case (%s/%s), but "
             "run_mesa_tests.sh always runs every test case."
             % (rec.get("test_case_module"), rec.get("test_case_name")))

    sha = rec.get("commit_sha")
    if not isinstance(sha, str) or not re.match(r"^[0-9a-fA-F]{40}$", sha):
        fail("commit_sha is missing or not a full 40-character SHA: %r" % (sha,))

    flags = rec.get("flags") or {}
    if not isinstance(flags, dict):
        fail("flags is not an object: %r" % (flags,))
    unknown = sorted(k for k, v in flags.items() if k not in KNOWN_FLAGS and v)
    if unknown:
        fail("MESATestHub asked for mode(s) run_mesa_tests.sh doesn't know: %s"
             % ", ".join(unknown))

    args = []
    if flags.get("use_fpe"):
        args.append("--fpe")

    factor = rec.get("converge_factor")
    if flags.get("use_converge"):
        if factor is None:
            args.append("--converge")
        else:
            try:
                value = float(factor)
            except (TypeError, ValueError):
                value = 0.0
            if value <= 0:
                fail("converge_factor is not a positive number: %r" % (factor,))
            args.append("--converge=%s" % format(value, "g"))
    elif factor is not None:
        sys.stderr.write("WARNING: ignoring converge_factor=%s because "
                         "use_converge is false.\n" % factor)

    branch = rec.get("branch")
    if isinstance(branch, str) and branch:
        args.append("--branch=%s" % branch)

    args.append(sha.lower())
    sys.stdout.write("\0".join(args) + "\0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
