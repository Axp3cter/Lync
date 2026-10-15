#!/bin/sh
# Compares opcode streams (operands stripped) of seed-differing generated functions. Usage: sh opcodes.sh BUILD_DIR WORK_DIR
set -e
B=$1; W=$2; P=$(dirname "$0"); mkdir -p "$W"
python3 -I "$P/opcodes_gen.py" "$W"
ops() { "$B/luau-compile" --text -O2 -g0 "$1" | grep -E '^[A-Z]' | awk '{print $1}'; }
for pair in "rec_s0 rec_s7" "tag_c0 tag_c1"; do
	set -- $pair
	ops "$W/$1.luau" > "$W/$1.ops"; ops "$W/$2.luau" > "$W/$2.ops"
	n1=$(wc -l < "$W/$1.ops"); n2=$(wc -l < "$W/$2.ops")
	if cmp -s "$W/$1.ops" "$W/$2.ops"; then same=identical; else same=different; fi
	b1=$("$B/luau-compile" --binary -O2 -g0 "$W/$1.luau" | wc -c); b2=$("$B/luau-compile" --binary -O2 -g0 "$W/$2.luau" | wc -c)
	echo "$1 vs $2: $n1 vs $n2 instructions, opcode sequence $same; bytecode $b1 vs $b2 B (-O2 -g0)"
	"$B/luau-compile" --text -O2 -g0 "$W/$2.luau" | grep -E 'K[0-9]+:|LOADK|FASTCALL2K' | head -4 | sed "s/^/  $2: /"
done
