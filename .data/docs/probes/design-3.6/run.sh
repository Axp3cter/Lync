#!/bin/sh
# Draft 3.6 core-api typing probes. Usage: run.sh LUAU_ANALYZE (0.740) ; tsc 6.0.2 on PATH.
A=$1; cd "$(dirname "$0")"
for f in read_modifier read_consumer overloads_options field_handle result_types; do
  for s in old new; do echo "== $f.luau --solver=$s"; "$A" --solver=$s $f.luau; done
done > typing.out 2>&1
echo "== field_handle.ts tsc --strict" >> typing.out; tsc --version >> typing.out; tsc --ignoreConfig --strict --noEmit field_handle.ts >> typing.out 2>&1
echo "== field_handle_typefn.luau --solver=new (runtime path: a type function builds the overloads)" >> typing.out
"$A" --solver=new field_handle_typefn.luau >> typing.out 2>&1
echo "== result_types.ts tsc --strict" >> typing.out; tsc --ignoreConfig --strict --noEmit result_types.ts >> typing.out 2>&1
