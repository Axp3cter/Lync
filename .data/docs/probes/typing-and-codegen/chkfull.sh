#!/bin/sh
# full untruncated output: luau-analyze 0.740 (same binary the skill's `check` uses), new solver unless SOLVER=old
B=$HOME/.cache/luau-skill/luau-0.740-linux-x86_64
$B/luau-analyze --solver=${SOLVER:-new} "$@"
echo "exit=$?"
