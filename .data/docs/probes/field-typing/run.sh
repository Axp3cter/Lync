#!/bin/sh
# field-typing probes. Usage: run.sh LUAU_ANALYZE [LUAU_ANALYZE_FINT] > run.out 2>&1
#   LUAU_ANALYZE: the luau skill's pinned luau-analyze 0.740. tsc 6.0.2 on PATH.
#   LUAU_ANALYZE_FINT (optional, claim 1): built by build_fint.sh from .data/projects/luau.
A=$1; F=$2; cd "$(dirname "$0")"; python3 -I gen.py
echo "== claim 1: plain overloads (limit/), too-complex count per overload count, pinned 0.740 --solver=new"
for shape in H plain; do printf "%-6s" $shape; for n in $(seq 6 16); do printf " %d:%s" $n $("$A" --solver=new limit/${shape}_$n.luau 2>&1 | grep -c "too complex"); done; echo; done
for n in 53 54; do printf "limit/e_phantom_%d: " $n; "$A" --solver=new limit/e_phantom_$n.luau 2>&1 | python3 -I summarize.py limit/e_phantom_$n.luau; done
if [ -n "$F" ]; then
	for fuel in 3000 6000 30000 300000; do for shape in H plain; do printf "src build, LuauNormalizerInitialFuel=%-6s %-6s" $fuel $shape
		for n in $(seq 6 16); do printf " %d:%s" $n $(LUAU_FINT=LuauNormalizerInitialFuel=$fuel "$F" --solver=new limit/${shape}_$n.luau 2>&1 | grep -c "too complex"); done; echo; done; done
	printf "src build, LuauTypeFamilyGraphReductionMaximumSteps=1e9, fuel 3000, H:"
	for n in 8 9 10; do printf " %d:%s" $n $(LUAU_FINT=LuauTypeFamilyGraphReductionMaximumSteps=1000000000 "$F" --solver=new limit/H_$n.luau 2>&1 | grep -c "too complex"); done; echo
	for fuel in 3000 6000 12000; do printf "src build, fuel=%-6s base_overloads_10: %s\n" $fuel $(LUAU_FINT=LuauNormalizerInitialFuel=$fuel "$F" --solver=new base_overloads_10.luau 2>&1 | grep -c "too complex"); done
	for fuel in 3000 30000; do printf "src build, fuel=%-6s e_phantom_128: %s\n" $fuel $(LUAU_FINT=LuauNormalizerInitialFuel=$fuel "$F" --solver=new e_phantom_128.luau 2>&1 | grep -c "too complex"); done
fi
echo "== claims 2-3: summaries (too-complex count; errors on correct calls; EXPECT lines not rejected)"
for f in base_overloads a_generic a_index a_explicit b_table c_nested d_union e_phantom f_codec; do for n in 10 32 128; do for s in new old; do
	printf "%-20s --solver=%s: " ${f}_$n $s; "$A" --solver=$s ${f}_$n.luau 2>&1 | python3 -I summarize.py ${f}_$n.luau | head -4
done; done; done
for f in b_consumer_128 b_consumer_nocheck_128 e_consumer_128; do for s in new old; do
	printf "%-20s --solver=%s: " $f $s; "$A" --solver=$s $f.luau 2>&1 | python3 -I summarize.py $f.luau | head -4
done; done
echo "== inferred type of h2 (--annotate)"
for f in base_overloads_128 a_generic_128 a_explicit_128 b_table_128 b_consumer_128 d_union_128 e_phantom_32 f_codec_128; do for s in new old; do
	printf "%-20s --solver=%s: " $f $s; "$A" --solver=$s --annotate $f.luau 2>/dev/null | grep "^local h2" | cut -c1-220
done; done
echo "== full diagnostics, new solver, one size per form"
for f in base_overloads_10 a_generic_10 a_index_10 b_table_128 c_nested_32 d_union_10 e_phantom_128 b_consumer_128; do
	echo "-- $f"; "$A" --solver=new $f.luau 2>&1 | grep -v LocalUnused | cut -c1-300
done
echo "-- b_table_128 --solver=old"; "$A" --solver=old b_table_128.luau 2>&1 | grep -v LocalUnused | cut -c1-300
echo "== claim 4: tsc --strict"; tsc --version
for n in 10 32 128; do for f in use generic table; do echo "-- ts/${f}_$n.ts"; tsc --ignoreConfig --strict --noEmit ts/${f}_$n.ts 2>&1 | grep -E "^\S+\.ts\(" | cut -c1-200; done; done
echo "== claim 5: time_check.py"; python3 -I time_check.py "$A"
