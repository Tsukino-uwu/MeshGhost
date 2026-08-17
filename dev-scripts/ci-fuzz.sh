#!/usr/bin/env bash
# Run one fuzz target for CI, and fail only on a real finding.
#
# Usage: dev-scripts/ci-fuzz.sh <package> <FuzzTarget> <fuzztime>
#
# WHY THIS EXISTS. `go test -fuzz` can exit non-zero with nothing but
#
#     --- FAIL: FuzzX (45.09s)
#         context deadline exceeded
#
# when its own -fuzztime elapses while workers are still mid-execution. No input
# crashed, nothing is written to testdata, and the same target passes on the next
# run -- it is the engine reporting its own stop signal as a failure. Seen on CI
# 2026-08-17: 45s, 3.98M executions, 273 new interesting inputs, no failing input,
# and the identical target passed locally at the same -fuzztime.
#
# Left alone, that turns a green pipeline into an occasionally-red one for a reason
# that means nothing -- and a build that is red for no reason is worse than no build,
# because it trains everyone to stop reading it. CLAUDE.md's rule is to go and look
# at what CI did with a push; that rule only survives if a red run is always worth
# looking at.
#
# WHAT IT DOES NOT DO: swallow real failures. A genuine find always leaves evidence,
# and both forms are checked for explicitly below --
#
#   * "Failing input written to testdata/..." -- a new crasher, and the file it names
#     is what gets committed as a regression case.
#   * "failure while testing seed corpus entry" -- an already-committed reproducer
#     (or seed) failing, which is a regression in exactly the case a previous find
#     was pinned against.
#
# Anything else non-zero -- a build error, a panic in the harness, a plain test
# failure -- is still a failure. Only the bare deadline is forgiven, and it is
# reported as a warning so it stays visible rather than silent.
set -uo pipefail

pkg=${1:?usage: ci-fuzz.sh <package> <FuzzTarget> <fuzztime>}
target=${2:?usage: ci-fuzz.sh <package> <FuzzTarget> <fuzztime>}
fuzztime=${3:?usage: ci-fuzz.sh <package> <FuzzTarget> <fuzztime>}

# -run=XXX so the package's ordinary tests do not run again here; the test job has
# already run them under -race.
out=$(go test "$pkg" -run=XXX -fuzz="$target" -fuzztime="$fuzztime" 2>&1)
code=$?
printf '%s\n' "$out"

if [ "$code" -eq 0 ]; then
  exit 0
fi

if printf '%s' "$out" | grep -qE "Failing input written to|failure while testing seed corpus entry"; then
  echo "::error::$target found a real failing input -- download the fuzz-failure-corpus artifact and commit it under testdata/fuzz/$target/"
  exit 1
fi

if printf '%s' "$out" | grep -q "context deadline exceeded"; then
  echo "::warning::$target hit its own -fuzztime ($fuzztime) with no failing input; treating as a pass (see dev-scripts/ci-fuzz.sh)"
  exit 0
fi

echo "::error::$target failed for a reason other than its time limit"
exit "$code"
