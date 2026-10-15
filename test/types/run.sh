#!/bin/sh
# Typing proofs (m1-plan.md §4.5, v5.md §10 item 1).
#
# Runs each test/types/<name>.luau through the analyzers its proof needs and diffs the output, paths
# made relative to the repo root, against <name>.expected. A crash (exit code 139) fails the proof
# whatever the output. Run from the repo root:
#
#   sh test/types/run.sh            check every proof
#   sh test/types/run.sh --update   rewrite the expected files from the current output
#
# The tools default to the pinned luau skill cache; LUAU_ANALYZE, LUAU_LSP and ROBLOX_DEFS override.

set -u

LUAU_ANALYZE=${LUAU_ANALYZE:-$HOME/.cache/luau-skill/luau-0.740-linux-x86_64/luau-analyze}
LUAU_LSP=${LUAU_LSP:-$HOME/.cache/luau-skill/luau-lsp-1.70.1-linux-x86_64/luau-lsp}
ROBLOX_DEFS=${ROBLOX_DEFS:-$HOME/.cache/luau-skill/roblox-defs-2857efa82454.luau}

ROOT=$(pwd)
PROOFS=test/types
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

is_update=0
if [ "${1:-}" = "--update" ]; then
	is_update=1
fi

# luau-analyze has no Roblox definitions, so it runs only where the proof needs it: the typo
# schema must give a diagnostic and no crash on both analyzers.
tools_of() {
	case "$1" in
		typo | typo_schema) echo "analyze lsp-new lsp-old" ;;
		*) echo "lsp-new lsp-old" ;;
	esac
}

run_tool() {
	case "$1" in
		analyze) "$LUAU_ANALYZE" --solver=new "$2" ;;
		lsp-new) "$LUAU_LSP" analyze --platform=roblox --flag:LuauSolverV2=true \
			--definitions=@roblox="$ROBLOX_DEFS" "$2" ;;
		lsp-old) "$LUAU_LSP" analyze --platform=roblox --flag:LuauSolverV2=false \
			--definitions=@roblox="$ROBLOX_DEFS" "$2" ;;
	esac
}

failed=0
for file in "$PROOFS"/*.luau; do
	name=$(basename "$file" .luau)
	actual="$SCRATCH/$name.actual"
	: > "$actual"

	for tool in $(tools_of "$name"); do
		run_tool "$tool" "$file" > "$SCRATCH/raw" 2>&1
		code=$?
		if [ "$code" -eq 139 ]; then
			echo "FAIL $name: $tool crashed (exit 139)"
			failed=1
		fi

		echo "== $tool (exit $code)" >> "$actual"
		grep -v '^\[INFO\]' "$SCRATCH/raw" | sed -e "s#$ROOT/##g" -e 's#^\./##' >> "$actual"
	done

	expected="$PROOFS/$name.expected"
	if [ "$is_update" -eq 1 ]; then
		cp "$actual" "$expected"
		echo "updated $name"
	elif diff -u "$expected" "$actual" > "$SCRATCH/diff" 2>&1; then
		echo "PASS $name"
	else
		echo "FAIL $name: output differs from $expected"
		cat "$SCRATCH/diff"
		failed=1
	fi
done

exit "$failed"
