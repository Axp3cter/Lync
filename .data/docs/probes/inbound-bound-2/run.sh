#!/bin/sh
# Reproduces the inbound-bound-2 probes with Luau 0.742 built from .data/projects/luau (Release).
# Usage: sh run.sh BUILD_DIR WORK_DIR [step ...]   steps: setup build gen decode tag gate derive (default: all)
#   BUILD_DIR holds the luau binary; WORK_DIR is scratch outside the repo. The milestone build (git f1fbfd7, src/)
#   is exported into WORK_DIR twice, never into the repo:
#   - WORK_DIR/src, the timed copy. Patches, each listed here, none on a path it times except as stated:
#       inbound.luau: decodeUp, decodingOf, process exposed as Inbound._decodeUp/_decodingOf/_process (the
#         inbound-budgets probe's sed; no behaviour change); instanceCountOf's `typeof(value) ~= "Instance"` reads
#         "table" (the CLI has no Instance; the stand-ins are tables; same builtin and compare per entry);
#       codec/{leaves,rows,columns}.luau: `Vector3.new(` -> `vector.create(` (Roblox's Vector3 is the native
#         vector), and CFrame/Color3 bound to rbx.luau's "fast" stand-ins;
#       plan/dsl.luau: `typeof` bound to rbx.luau's (plan time only: `typeof(items) == "Enum"`).
#   - WORK_DIR/srcA, the frame builder's copy: codec and dsl modules see rbx.luau's "build" stand-ins and typeof.
# Each timing probe runs 3 times interpreted (-O2) and 3 times native (-O2 --codegen) into <probe>.out here.
set -e
B=$1; W=$2; shift 2
P=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$P" rev-parse --show-toplevel)
STEPS="${*:-setup build gen decode tag gate derive}"
mkdir -p "$W"

has() { case " $STEPS " in *" $1 "*) return 0;; esac; return 1; }

if has setup; then
	rm -rf "$W/src" "$W/srcA"
	git -C "$REPO" archive f1fbfd7 src | tar -x -C "$W"
	cp -r "$W/src" "$W/srcA"
	# timed copy
	I="$W/src/session/inbound.luau"
	sed -i 's/^return table.freeze(Inbound)$/Inbound._decodeUp = decodeUp\nInbound._decodingOf = decodingOf\nInbound._process = process\nInbound._instanceCountOf = instanceCountOf\nreturn table.freeze(Inbound)/' "$I"
	sed -i 's/typeof(value) ~= "Instance" then/typeof(value) ~= "table" then/' "$I"
	grep -q "Inbound._decodeUp = decodeUp" "$I"
	grep -q 'typeof(value) ~= "table" then' "$I"
	for f in codec/leaves codec/rows codec/columns; do
		sed -i 's/Vector3\.new(/vector.create(/g' "$W/src/$f.luau"
		sed -i '1a local __R = require("../../rbx_fast"); local CFrame, Color3 = __R.CFrame, __R.Color3' "$W/src/$f.luau"
		sed -i '1a local __R = require("../../rbx_build"); local CFrame, Color3, Vector3, typeof = __R.CFrame, __R.Color3, __R.Vector3, __R.typeof' "$W/srcA/$f.luau"
	done
	sed -i '1a local __R = require("../../rbx_fast"); local typeof = __R.typeof' "$W/src/plan/dsl.luau"
	sed -i '1a local __R = require("../../rbx_build"); local typeof = __R.typeof' "$W/srcA/plan/dsl.luau"
	printf 'return require("./rbx")("fast")\n' > "$W/rbx_fast.luau"
	printf 'return require("./rbx")("build")\n' > "$W/rbx_build.luau"
	cp "$P"/*.luau "$W/"
	cp "$REPO/.data/docs/probes/security-costs/hsip.luau" "$W/"
fi

if has build; then
	(cd "$W" && "$B/luau" -O2 build_frames.luau > frames_data.luau)
fi

if has gen; then
	rm -rf "$W/gdefs"; mkdir -p "$W/gdefs"; (cd "$W" && "$B/luau" -O2 gen.luau | awk '/^--@@FILE /{f=$2; next} {print > f}')
fi

timed() {
	p=$1
	: > "$P/$p.out"
	for run in 1 2 3; do
		echo "== $p, interpreted (luau 0.742 -O2), run $run" >> "$P/$p.out"
		(cd "$W" && "$B/luau" -O2 "$p.luau") >> "$P/$p.out" 2>&1
		echo "== $p, native (luau 0.742 -O2 --codegen), run $run" >> "$P/$p.out"
		(cd "$W" && "$B/luau" -O2 --codegen "$p.luau") >> "$P/$p.out" 2>&1
	done
}

has decode && timed decode_cost
has tag && timed tag_cost
has gate && {
	: > "$P/gate.out"
	for bound in v36 new; do
		echo "== gate, bound $bound, native (luau 0.742 -O2 --codegen)" >> "$P/gate.out"
		(cd "$W" && "$B/luau" -O2 --codegen gate.luau -a "$bound" >> "$P/gate.out" 2>&1; echo "exit $?" >> "$P/gate.out")
	done
}
has derive && python3 -I "$P/derive.py" > "$P/derive.out"
exit 0
