#!/bin/sh
# Counts in v4 (.data/versions/one) used by research/diagnostics.md. Run from the repo root.
V=.data/versions/one
echo "Log.* raise/print sites outside Log.luau:"; grep -rn 'Log\.\(warn\|error\|refuse\|reject\|drop\|quieted\)(' $V/src | grep -v kernel/Log.luau | wc -l
echo "  of which Log.refuse (error(msg, 0), no position):"; grep -rn 'Log\.refuse(' $V/src | grep -v kernel/Log.luau | wc -l
echo "  of which Log.error (record + error(msg, 0)):"; grep -rn 'Log\.error(' $V/src | grep -v kernel/Log.luau | wc -l
echo "Expect.throws call sites:"; grep -rn 'Expect\.throws(' $V/test | grep -v 'function Expect' | wc -l
echo "Expect.throws closed with a prose substring (end, \"...\"):"; grep -rn 'end, "[^"]*")' $V/test | wc -l
echo "other prose matches on messages (string.find on message/thrown):"; grep -rn 'string.find(\(message\|held\[1\].message\|second.message\|one.message\|tostring(thrown)\)' $V/test | wc -l
