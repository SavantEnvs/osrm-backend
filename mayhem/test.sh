#!/usr/bin/env bash
#
# mayhem/test.sh — RUN osrm-backend's own Boost.Test unit suites (built by mayhem/build.sh in
# _build-tests with the project's normal flags). Every test case asserts values (BOOST_CHECK_*), so a
# neutered program fails them; a missing runner or missing summary counts as a failure.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


BIN=_build-tests/unit_tests
TESTS=(util-tests server-tests engine-tests extractor-tests partitioner-tests)
passed=0; failed=0; skipped=0
for t in "${TESTS[@]}"; do
  if [ ! -x "$BIN/$t" ]; then echo "missing runner $BIN/$t (build.sh bug)" >&2; failed=$((failed + 1)); continue; fi
  out=$("$BIN/$t" --report_level=short 2>&1); rc=$?
  echo "$out" | tail -n 8
  total=$(printf '%s\n' "$out" | sed -n 's/^ *\([0-9]*\) test cases\? out of \([0-9]*\) passed.*/\2/p' | tail -n1)
  p=$(printf '%s\n' "$out" | sed -n 's/^ *\([0-9]*\) test cases\? out of \([0-9]*\) passed.*/\1/p' | tail -n1)
  f=$(printf '%s\n' "$out" | sed -n 's/^ *\([0-9]*\) test cases\? out of \([0-9]*\) failed.*/\1/p' | tail -n1)
  s=$(printf '%s\n' "$out" | sed -n 's/^ *\([0-9]*\) test cases\? out of \([0-9]*\) skipped.*/\1/p' | tail -n1)
  if [ -z "$total" ] && [ -z "$f" ]; then echo "$t: no Boost.Test summary (exit $rc)" >&2; failed=$((failed + 1)); continue; fi
  passed=$((passed + ${p:-0})); failed=$((failed + ${f:-0})); skipped=$((skipped + ${s:-0}))
  if [ "$rc" -ne 0 ] && [ -z "$f" ]; then failed=$((failed + 1)); fi
done

emit_ctrf "boost-test" "$passed" "$failed" "$skipped"
