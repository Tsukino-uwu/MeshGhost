#!/usr/bin/env bash
# Run one fuzz target for CI, and fail only on a real finding.
#
# Usage: dev-scripts/ci-fuzz.sh <package> <FuzzTarget> <fuzztime>
#
# `go test -fuzz` can exit non-zero with only "context deadline exceeded" when its own -fuzztime elapses
# mid-execution, with no failing input. That bare deadline is forgiven, as a warning; anything else non-zero fails.
set -uo pipefail

pkg=${1:?usage: ci-fuzz.sh <package> <FuzzTarget> <fuzztime>}
target=${2:?usage: ci-fuzz.sh <package> <FuzzTarget> <fuzztime>}
fuzztime=${3:?usage: ci-fuzz.sh <package> <FuzzTarget> <fuzztime>}

# -run=XXX: the race job has already run the package's ordinary tests.
out=$(go test "$pkg" -run=XXX -fuzz="$target" -fuzztime="$fuzztime" 2>&1)
code=$?
printf '%s\n' "$out"

# -fuzz takes a regexp and go test exits 0 on a non-match, so a renamed target would pass without running; checked
# before the exit-0 branch.
if printf '%s' "$out" | grep -q "no fuzz tests to fuzz"; then
  echo "::error::$target matched no fuzz target in $pkg -- the name is a regexp and a non-match is a WARNING to go test, so this step was passing without running anything. Fix the name or delete the step."
  exit 1
fi

if [ "$code" -eq 0 ]; then
  exit 0
fi

# A real find: a new crasher written to testdata, or a committed seed corpus entry failing.
if printf '%s' "$out" | grep -qE "Failing input written to|failure while testing seed corpus entry"; then
  echo "::error::$target found a real failing input -- download that shard's fuzz-failure-corpus-<shard> artifact and commit it under testdata/fuzz/$target/"
  exit 1
fi

if printf '%s' "$out" | grep -q "context deadline exceeded"; then
  echo "::warning::$target hit its own -fuzztime ($fuzztime) with no failing input; treating as a pass (see dev-scripts/ci-fuzz.sh)"
  exit 0
fi

echo "::error::$target failed for a reason other than its time limit"
exit "$code"
