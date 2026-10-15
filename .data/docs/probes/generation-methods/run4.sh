#!/bin/sh
# Reproduces the M15 probe with Luau 0.742 built from .data/projects/luau.
# Usage: sh run4.sh BUILD_DIR
set -e
B=$1; P=$(dirname "$0")
{ echo "== interpreted (luau 0.742 -O2)"; "$B/luau" -O2 "$P/generated_integrity.luau"; echo "== native (--codegen)"; "$B/luau" -O2 --codegen "$P/generated_integrity.luau"; } > "$P/generated_integrity.out"
echo "trap encoder bytecode: see bytecode2.out (enc_plain marginal per definition)" >> "$P/generated_integrity.out"
