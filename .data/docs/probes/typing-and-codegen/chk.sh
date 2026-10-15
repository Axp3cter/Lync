#!/bin/sh
# usage: chk.sh FILE...  -> new-solver check via the luau skill
S=/root/.claude/skills/synced/5aee9b45-b73f-41b3-b2f4-6ea0c7eb3b7d_78784dc2-944e-4738-85b1-1264b7c1237e/luau
python3 $S/scripts/luau.py check "$@"
