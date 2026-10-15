#!/bin/sh
# Usage: sh bytecode2.sh BUILD_DIR WORK_DIR
set -e
B=$1; W=$2; P=$(dirname "$0"); mkdir -p "$W"
python3 -I "$P/gen_defs2.py" "$W"
for f in enc_plain enc_offset dec_plain dec_offset; do
	a=$("$B/luau-compile" --binary -O2 -g0 "$W/${f}_50.luau" | wc -c); c=$("$B/luau-compile" --binary -O2 -g0 "$W/${f}_200.luau" | wc -c)
	g=$("$B/luau-compile" --binary -O2 -g1 "$W/${f}_200.luau" | wc -c)
	echo "$f: 50 defs $a B, 200 defs $c B (-O2 -g0); marginal $(( (c - a) / 150 )) B per definition; 200 defs at -g1 $g B"
done
