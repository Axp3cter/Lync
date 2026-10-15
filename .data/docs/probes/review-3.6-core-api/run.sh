#!/bin/sh
# Review probes for v5.md §0–§3, §5.2 at draft 3.6. Usage: run.sh LUAU_ANALYZE (0.740); tsc 6.0.2 on PATH.
A=$1; cd "$(dirname "$0")"; ./make_overloads.sh
{
for f in overloads_8 overloads_9 overloads_32 overloads_consumer overloads_consumer_fixed field_kind field_kind_fixed result_arms; do
	for s in old new; do echo "== $f.luau --solver=$s"; "$A" --solver=$s $f.luau; done
done
for f in nested_typefn index_field sealed_fire sealed_fire_fixed; do
	echo "== $f.luau --solver=new (runtime path: type functions)"; "$A" --solver=new $f.luau
done
echo "== result_arms.ts tsc --strict"; tsc --version; tsc --ignoreConfig --strict --noEmit result_arms.ts
} > review.out 2>&1
