# field-typing: runtime-path `field(path)` typing at 10+ paths

Question: can the runtime (no-build) path type `Net.<def>:field(path)` exactly for definitions with 10 or more
field paths (`reviews/v5-3.6-core-api.md` D1, `probes/review-3.6-core-api/nested_typefn.luau`)?

Tools: luau-analyze 0.740 (the luau skill's pinned toolchain, `~/.cache/luau-skill`), `--solver=old|new`;
tsc 6.0.2 `--strict`. Luau source read: `.data/projects/luau`. Re-run: `python3 -I gen.py` writes every probe; `run.sh LUAU_ANALYZE [LUAU_ANALYZE_FINT] > run.out 2>&1` runs
them all (`run.out` is the decisive output cited below). `LUAU_ANALYZE_FINT` is built by `build_fint.sh` from
`.data/projects/luau` (`fint_main.cpp` only lets FInt/DFInt flags be set from `LUAU_FINT`; the analyzer is unchanged).
`summarize.py` reads one probe's diagnostics: too-complex count, errors on the correct calls (want none), EXPECT
lines not rejected (want none).

Probe schema at N paths (`gen.py`): leaves `f1..f(N-3)` (vector/string/number) plus `hit: { part: number, at: vector }?`,
so N paths counted as `nested_typefn` counts them. Every probe has the same calls: `local h2 = <f2>` (inferred type
read with `--annotate`), three correct `derive` calls (`f3`, `hit.at`, the last leaf), an exact-type assignment of
`f2`'s handle, then four EXPECT lines: `f2`'s handle assigned to a number handle, a wrong `fn` return on `hit.part`,
the unknown path `nope`, and `policy = "dorp"`.

## Checklist

- [x] 1. The limit is a fixed count of overloads or of type-function reductions; name the constant and file that sets it.
- [x] 2. A runtime-path form gives exact handle types at 10, 32, 128 paths on the new solver (forms a–e; correct
      call typed, wrong path and wrong option rejected).
- [x] 3. The same form type-checks on the old solver (or its fallback type is stated exactly).
- [x] 4. roblox-ts: the `.d.ts` equivalent of the chosen form under `tsc --strict`, 10/32/128 paths.
- [x] 5. Type-check time of the chosen form at 128 paths on both solvers.

## Results

### 1. The limit is a fixed count of overloads or of type-function reductions — **false**

It is neither. It is the normalizer's fuel, `FInt::LuauNormalizerInitialFuel = 3000`
(`.data/projects/luau/Analysis/src/Normalize.cpp:21`, used at `:4211`, exhausted at `:4226`). The thing that burns it is
union-saturation of overloads, `Normalizer::unionSaturatedFunctions` (`Normalize.cpp:3486`, its own comment: "the
union-saturation of a function with N overloads may have 2^N overloads"), called for every pair of overloads with
differing return types in `intersectFunctionsWithFunction` (`:3604`). When the fuel runs out, `normalize` returns null.
`TypeChecker2::visit(AstType*)` → `checkForTypeFunctionInhabitance` → `isErrorSuppressing`
(`TypeChecker2.cpp:3389`, `:549`) then reports `NormalizationTooComplex`, whose text is "Code is too complex to
typecheck!" (`Error.cpp:637`). It is reported at the annotation (`overloads_9.luau(4,29)`, `base_overloads_10.luau(39,22)`
= `FieldOf<Shot>`) or at the expression whose type it is (`e_consumer_128.luau(5,11)`, `Lync.define(...)`). The
type-function step limit (`DFInt::LuauTypeFamilyGraphReductionMaximumSteps = 1'000'000`, `TypeFunction.cpp:25`) does
not take part. No solver option sets either limit: the CLI's `--fflags=` takes only booleans (`CLI/src/Flags.cpp`), and
whether luau-lsp or Studio can override an FInt was not checked.

Evidence (`run.out`, claim 1 block; probes `limit/H_N.luau` = the review's overload shape, `limit/plain_N.luau` =
plain return types):

```
H      6:0 7:0 8:0 9:1 10:1 ...                                  (pinned 0.740: 8 clean, 9 too complex)
src build, LuauNormalizerInitialFuel=3000   H   ... 8:0 9:1 ...  (source build reproduces 0.740)
src build, LuauNormalizerInitialFuel=6000   H   ... 9:0 10:1 ...
src build, LuauNormalizerInitialFuel=30000  H   ... 12:0 13:1 ...
src build, LuauNormalizerInitialFuel=300000 H   ... 15:0 16:1
src build, LuauTypeFamilyGraphReductionMaximumSteps=1e9, fuel 3000, H: 8:0 9:1 10:1
src build, fuel=3000/6000/12000   base_overloads_10: 1 / 1 / 0
```

Each 10x of fuel buys about 3.3 overloads (log2 10), which fits a 2^N cost. The threshold depends on the shape of the
overloads, not only their count. The type-function handles need more fuel at 10 paths (12000) than plain `H<T>`
overloads do. With a distinct generic per overload (form e below) the cost drops to about N² (threshold 53/54).
Tool: luau-analyze 0.740 (pinned) and a Release build of `.data/projects/luau`. That tree has no version stamp, and its
flag list differs from the 0.740 binary's (`strings` diff), but at the default fuel it gives the same 8/9 threshold.

### 2. A runtime-path form gives exact handle types at 10, 32 and 128 paths on the new solver — **true** (forms b and a2; not `:field("path")` without explicit instantiation)

luau-analyze 0.740 `--solver=new`, `run.out` "claims 2-3" and "inferred type" blocks:

| form | probe | 10 | 32 | 128 | verdict |
|---|---|---|---|---|---|
| baseline: type function → intersection of overloads | `base_overloads_N` | too complex | too complex | too complex | calls stay checked, diagnostic at `FieldOf<Shot>` |
| (a) one function `<P>(self, path: P) -> FieldAt<Shot, P>` | `a_generic_N` | fails | fails | fails | P is inferred `string`: "'FieldAt' type function errored at runtime: … the path must be a string literal" on every correct call; `h2 : user` |
| (a') `<P>(self, path: P) -> index<FieldsOf<Shot>, P>` | `a_index_N` | fails | fails | fails | "Property 'string' does not exist on type …" on every correct call (as `index_field`) |
| (a2) (a) called as `v:field<<"f2">>("f2")` | `a_explicit_N` | exact | exact | exact | correct calls clean, all 4 rejected; `h2 : {derive:(any,{fn:()->(string?),policy:'drop'\|'deliver'})->()}` |
| (b) table of handles `fields: FieldsOf<Shot>`, `v.fields.f3`, `v.fields["hit.at"]` | `b_table_N` | exact | exact | exact | correct calls clean, all 4 rejected (`Key 'nope' not found in table …`, `Expected … '"deliver" \| "drop"', but got '"dorp"'`); `h2` as above |
| (b) as a library: `Lync.define<S>(schema: S): View<S>` in `b_lib.luau` | `b_consumer_128` | | | exact | same, no diagnostic in either module |
| (c) per-level overloads, `v:field("hit"):field("at")` | `c_nested_N` | clean (8 top keys) | too complex | too complex | a level with 9 or more keys hits the same limit |
| (d) `(self, path: keyof<…>) -> index<FieldsOf<Shot>, keyof<…>>` | `d_union_N` | fails | fails | fails | not exact: `h2` is the union of every handle; "Cannot call a value of the union type" on correct calls |
| (e) the overloads, each with its own unused generic `G<i>` | `e_phantom_N`, `limit/e_phantom_53/54` | exact | exact | too complex | `unionSaturatedFunctions` returns nullopt when the generics differ (`Normalize.cpp`), so no 2^N, but the pairwise checks still cost about N² fuel: 53 clean, 54 too complex; `e_consumer_128` (library layout) too complex at the `define` call |
| (f) no type function: codec values carry `Handle<T>`, `fields` is the schema table (generic S) | `f_codec_N` | exact | exact | exact | leaves exact (`h2 : Handle<string>`); a record has no handle of its own (`hit` is `{ at: Handle<vector>, part: Handle<number> }`), paths nest (`v.fields.hit.at`) instead of dotted, and the optional is not in the type |

The form that keeps `Net.<def>:field("path")` with plain literals has no exact version at 128 paths on 0.740: overloads
blow the fuel (baseline, c, e above 53), and a generic widens the literal (a, a'). The exact forms change the call
syntax. (b) reads `Net.<def>.fields.<name>` / `.fields["a.b"]`. (a2) uses explicit instantiation `<<…>>`, which parses
and works in the 0.740 CLI; whether Roblox enables that syntax was not checked. A probe defect was fixed in (f), not
the result: its exactness lines first used `{ derive: (any, …) }`, and the new solver accepts a `Handle<string>` there
because `any` in the parameter suppresses the error. They now use `Handle<string>` / `Handle<number>`.

### 3. The same form type-checks on the old solver — **false** for (b), (a2), (e) (every type-function form); the fallback is stated

`--solver=old` (`run.out`) on the declaring module: `TypeError: This syntax is not supported` at `type function`, and
`TypeError: Unknown type 'FieldsOf'` (or `'FieldOf'`, `'FieldAt'`) at its use. With the library layout these land in
Lync's module (`b_lib.luau(3,1)`, `b_lib.luau(36,33)`). Under `--!nocheck` (`b_lib_nocheck.luau`) those two go away,
but both solvers then lint `UnknownGlobal: Unknown global 'types'` in the type function body. The game's script sees
`v : View<Shot>`, and every handle is the error type (`--annotate`: `local h2:Unifiable<Error>=v.fields.f2`). So all
four EXPECT lines pass unchecked (`EXPECT lines not rejected: [12, 13, 14, 15]` for `b_consumer_128` and
`b_consumer_nocheck_128`), and nothing is reported in the game's script. Only (f) is exact on both solvers at 10/32/128
(`f_codec_N --solver=old`: correct calls clean, all 4 rejected, `h2 : Handle<string>`), with the gaps listed in claim 2.

### 4. roblox-ts: the `.d.ts` equivalent under `tsc --strict`, 10/32/128 paths — **true**

tsc 6.0.2 `--ignoreConfig --strict --noEmit` (`run.out` "claim 4"). There are three forms, and in each the correct
lines are clean and exactly the four EXPECT lines error at 10, 32 and 128:
- `ts/table_N.ts` (the form-b equivalent, runtime path): `View<S>.fields: { readonly [P in Paths<S>]: Handle<At<S, P>> }`
  with template-literal `Paths`/`At` over the schema type. Errors: `TS2322 'Handle<string>' is not assignable to
  'Handle<number>'`, `TS2322 'Vector3' is not assignable to 'number'`, `TS2339 Property 'nope' does not exist`,
  `TS2322 '"dorp"' is not assignable to '"drop" | "deliver"'`.
- `ts/generic_N.ts`, the runtime-path `field<P extends Paths<S>>(path: P): Handle<At<S, P>>`. TypeScript keeps the
  literal, so `:field("path")` also works here (`TS2345 Argument of type '"nope"' is not assignable to parameter of
  type 'Paths<Shot, "">'`).
- `ts/view_N.d.ts` + `ts/use_N.ts`, one overload per path (the generated-path shape) (`TS2769 No overload matches this
  call`).
A probe defect was fixed, not the result: `Vector3` was first declared module-local in `view_N.d.ts` (`TS2304`). It is
now `declare global`, as roblox-ts has it.

### 5. Type-check time at 128 paths, both solvers — measured (`time.out`, `time_check.py`)

Wall time of one process per run: 1 warm-up and 9 runs (tsc: 5). Median (min–max), with an empty module as the
same-run baseline. Host: Linux 6.18 container, 4 cores, CLI analyzer and tsc (not Studio or luau-lsp; these figures do
not transfer exactly to them).

| probe | new solver | old solver |
|---|---|---|
| `empty.luau` (baseline) | 8.1 ms (7.7–9.8) | 6.8 ms (6.6–7.1) |
| `base_overloads_128` (too complex) | 100.2 ms (87.3–119.0) | 7.8 ms * |
| `b_table_128` (form b) | 18.4 ms (17.1–23.1) | 7.4 ms * |
| `b_consumer_128` (b, library + consumer) | 31.1 ms (28.5–33.1) | 7.9 ms * |
| `a_explicit_128` (form a2) | 21.7 ms (20.8–24.8) | 7.5 ms * |
| `e_phantom_32` (form e) | 31.6 ms (30.4–37.3) | 6.9 ms * |
| `f_codec_128` (form f) | 19.2 ms (17.8–20.4) | 13.6 ms (12.0–17.4) |
| tsc `ts/empty.ts` / `use_128` / `generic_128` / `table_128` | 1454 / 1501 / 1475 / 1443 ms | — |

\* the old solver checks nothing in these (type function unsupported, handles are the error type), so the time is not a
cost of the form. On the new solver, form b at 128 paths costs about 10 ms over the baseline (about 23 ms for library
plus consumer). tsc is dominated by start-up: every form is within the spread of the empty file.
