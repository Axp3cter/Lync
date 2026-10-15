#!/bin/sh
# R10: which renames change shipped bytecode. Usage: sh r10_names.sh BUILD_DIR WORK_DIR
# locals: every local and parameter renamed (what darklua rename_variables does by default);
# functions: local function names renamed too (include_functions = true);
# fields: a table key renamed (no darklua rule does this; game code indexes these names).
set -e
B=$1; W=$2; P=$(cd "$(dirname "$0")" && pwd); mkdir -p "$W"
sed -e 's/\boffset\b/a/g; s/\bcursor\b/b/g; s/\btarget\b/c/g; s/\bdamage\b/d/g; s/\bspread\b/e/g; s/\borigin\b/f/g; s/\bout\b/g/g' "$P/r10_base.luau" > "$W/locals.luau"
sed -e 's/\bencodeHit\b/h/g; s/\bpackShot\b/i/g' "$W/locals.luau" > "$W/functions.luau"
sed -e 's/Codec\.hit/Codec.x1/g' "$P/r10_base.luau" > "$W/fields.luau"
cp "$P/r10_base.luau" "$W/base.luau"
for g in 0 1 2; do
	for v in base locals functions fields; do "$B/luau-compile" --binary -O2 -g$g "$W/$v.luau" > "$W/$v.g$g.bc"; done
	for v in locals functions fields; do
		if cmp -s "$W/base.g$g.bc" "$W/$v.g$g.bc"; then r=identical; else r=differs; fi
		echo "-g$g $v: $r ($(wc -c < "$W/base.g$g.bc") B vs $(wc -c < "$W/$v.g$g.bc") B)"
	done
	for v in base functions; do printf '%s' "-g$g $v strings in bytecode: "; strings -n 3 "$W/$v.g$g.bc" | tr '\n' ' '; echo; done
done
for v in base locals functions; do printf '%s' "debug.info n at -O2 -g1, $v: "; "$B/luau" -O2 -g1 "$W/$v.luau"; done
