#!/bin/sh
# result_arms.luau of probes/review-3.6-core-api with the naming review's 3.6 names. Usage: run.sh LUAU_ANALYZE (0.740).
A=$1; cd "$(dirname "$0")"
{ for s in old new; do echo "== result_arms_renamed.luau --solver=$s (luau-analyze 0.740)"; "$A" --solver=$s result_arms_renamed.luau; done; } > run.out 2>&1
{ echo "== result_arms_renamed.ts tsc --strict"; tsc --version; tsc --ignoreConfig --strict --noEmit result_arms_renamed.ts; } >> run.out 2>&1
