# Lync v5 probe results

Probe directory: `.data/docs/probes/typing-and-codegen/`

Tools (pinned by the luau skill, `~/.cache/luau-skill`):
- Type checks: `luau-analyze 0.740`, new solver (`--solver=new`, the skill's `check`), via `chkfull.sh` (same binary, untruncated output). `SOLVER=old ./chkfull.sh` runs `--solver=old`.
- Cross-checks: `luau-lsp 1.70.1 analyze --platform=roblox --flag:LuauSolverV2=true|false` with the Roblox definitions. T5 and T7 gave the same diagnostics as luau-analyze.
- Runtime and benchmarks: `luau 0.740` CLI on Linux x86_64 (4 cores, idle), `-O2`, interpreted and `--codegen` (native). CLI timings do not carry over exactly to Roblox, where native code runs only for `--!native` scripts or functions on supported servers and clients.

Reveal technique: `local _r: "REVEAL_X" = expr`. The error message prints the inferred type of `expr`. Every type claim below includes the failure cases.

---

## T1: plain-table codecs + `Infer<S>` give exact records. **TRUE** (with 2 caveats)

Probes: `t1_codec.luau`, `t1b_codec_selfmethods.luau`, `t1c_codec_genericmethod.luau`

`Codec<T> = { read _value: T, size: number, write: (self: Codec<T>, …, v: T) -> number, … }`. `Infer` is a recursive type function: a table with `_value` gives that type, and any other table gives a record of `Infer` applied to each field.

```
Infer<typeof(Schema)> =
{ alive: boolean, id: number, inner: { a: number, b: boolean? }, nick: string?,
  pos: { x: number, y: number }, scores: { [string]: number }, tags: {string} }
```
- Nested raw tables, `optional` → `T?` (the key may be omitted in a literal), `array` → `{T}`, `map` → `{[K]: V}`, and nested `struct()` all came out exact. A type function can call itself recursively.
- The checker rejected each of these: a wrong field type, a missing field, a missing nested field, a wrong array element, a wrong map value, a wrong optional type, `string?` read into a `string`, and a wrong nested read.
- Caveat 1: an extra key in a literal (`extra = 1`) was **not** rejected. Exact tables are behind `DebugLuauParseExactTables`, which is off.
- Caveat 2 (re-confirms the earlier finding): adding one generic method `mapped: <U>(self, …) -> Codec<U>` to `Codec` breaks `Infer`. The checker reports "Type functions do not currently support types of the form '*error-type*'" and the record reduces to `never`. Methods typed with `self: Codec<T>` and no generics of their own work fine (t1b).
- Side note: `make<T>(n): Codec<T>` assigned to `local u8: Codec<number> = make(1)` does not take `T` from the annotation. It gives `Codec<unknown>` and an error. Constructors of primitive codecs must return `any` or be cast.

## T2: a tagged-union constructor gives a discriminated union that narrows. **TRUE** when the payload type is fixed; **fails** when inferred through a generic `Codec<T>` parameter

Probes: `t2_tagged.luau`, `t2b_tagged_callbacks.luau`, `t2c_structural_inference.luau`

`tagged({ hit = {target=u8, at=vec}, miss = {reason=str}, none = {} })` uses a `Tagged` type function and produces:
```
{ at: vector, kind: "hit", target: number } | { kind: "miss", reason: string } | { kind: "none" }
```
- In `if v.kind == "hit"`, reading `v.reason` errors with "Key 'reason' not found in table '{ at: vector, kind: "hit", target: number }'", and the reverse case errors too. The `else` branch narrows to `{ kind: "none" }`.
- Literals: `{kind="hit", reason="x"}` is rejected, and so is a bad tag `"hti"`.
- A comparison with a misspelled tag (`v.kind == "hti"`) is **not** reported. This is a known Luau limitation.
- Failure mode: when the handler is passed to a generic function `on<T>(c: Codec<T>, f: (T)->())`, or a definition is built by `packet<T>(c: Codec<T>): Packet<T>`, the union is not inferred:
  - `on<T>`: the reads in the callback leak into `T`, giving `Codec<{ read kind: unknown, read reason: string }>`, and the checker raises a spurious error at the codec argument.
  - `packet(Shot)`: the result is `Packet<unknown>`, silently. A plain `Codec<number>` infers fine.
  - The fix is to never take `T` structurally from `Codec<T>`. Use `<S>(s: S)` plus a type function (see T5).

## T3: exact literal unions. Only the **keyof set form** and **explicit instantiation** are exact; the other forms widen or are unstable

Probes: `t3_enum.luau`, `t3b_enum_infile.luau`, `t3c_explicit_inst.luau`, `t3m/` (across modules)

| form | in the same file | across `require` | verdict |
|---|---|---|---|
| `enum("a","b","c")` with `<T>(...: T)` | looks like `"a"\|"b"\|"c"`, but the type is an unsolved free type that **absorbs later uses**: after `local x: typeof(E._value) = "d"` it becomes `"a"\|"b"\|"c"\|"d"\|"d"\|"d"` and no error is raised | `string` | **widens** |
| `enum<T...>(...: T...)` | `Codec<T...>` is illegal ("Type parameters must come before type pack parameters"); there is no way to union a pack | — | not expressible |
| `enum({"a","b","c"})` with `<T>(list: {T})` | the same free-type behaviour | `string` | **widens** |
| `enum({"a","b","c"})` with `<S>(s: S)` + `Values<S>` type fn | `string` | `string` | **widens** |
| `enum({a="a", b="b"})` with `Values<S>` | `string \| string \| string` | — | **widens** |
| `enum({ a = true, b = true, c = true })` with `Codec<keyof<S>>` | `"a" \| "b" \| "c"`; `"d"` rejected | `"a" \| "b" \| "c"` | **exact** |
| `enum("a","b","c") :: Codec<"a"\|"b"\|"c">` (cast) | exact, but a cast to the wrong list (`Codec<"a"\|"z">` from `("a","b")`) is **accepted** | — | exact but unchecked |
| `local E: Codec<"a"\|"b"\|"c"> = enum("a","b","c")` (annotation) | **error**: under an expected type, `T` is inferred as `string` ("got 'Codec<string>'") | — | does not work |
| `enum("a" :: "a", …)` / `enum({…} :: {"a"\|"b"\|"c"})` | exact | — | exact, verbose |
| `enum<<"a"\|"b"\|"c">>("a","b","c")` (explicit instantiation) | exact; `"d"` rejected; `enum<<"a"\|"b">>("a","z")` rejected | — | **exact and checked** |
| `const A = "a"` then `enum(A, B, C)` | `A` is `string` | — | **widens** (`const` does not keep singletons) |

- Explicit instantiation `f<<T>>()` parses and runs on the 0.740 CLI even with `--fflags=false`, and the old solver parses it too. Whether Roblox enables it is unverified.
- Runtime note for the keyof form: iterating a hash table gives no defined order, so the runtime must sort the names to get stable wire indices.

## T4: `Patch<T>` makes every field optional. **PARTLY TRUE**: wrong value types are rejected, misspelled keys are not

Probes: `t4_patch.luau`, `t4b_patch_strict.luau`

- `Patch<Rec>` with `types.optional` on each property: `{}`, `{hp=5}` and `{name="n", pos={…}}` are accepted, and `{hp="five"}` is rejected ("Expected 'number?', got '"five"'"). The patch is shallow: a nested `pos = {x=1}` still requires `y`.
- **Misspelled keys are accepted** (`{ hpp = 5 }`, `{ hp = 5, nmae = "x" }`). This holds for an annotation, a parameter, `update2<T>(state: T, p: Patch<T>)`, and even a handwritten `{ hp: number?, name: string? }`.
- A working fix (t4b): make the function generic over the literal and check it in the **return type**: `function update<P>(p: P): StrictPatch<P, Rec>`, or the generic method `patch: <P>(self: Store<T>, p: P) -> StrictPatch<P, T>`. The type function walks `p:properties()` and calls `error()`. Results:
  - `'StrictPatch' type function errored at runtime: … unknown field 'hpp' in patch`
  - `… field 'name' has the wrong type`
  - Valid patches pass.
  - Putting the check in the parameter (`p: StrictPatch<P, Rec>`) does not work: `P` cannot be inferred ("Expected this to be unreachable").

## T5: handler inference through a method on a computed definition. **TRUE** for both the type-function definition (A) and `Packet<Payload<S>>` (B); B is more robust. Structural `Packet<T>` from `Codec<T>` (C) **fails silently**

Probes: `t5/lync.luau` (library), `t5/net.luau` (shared schema, no annotations), `t5/use.luau`, `t5/robust.luau`. Cross-module through `require("./net")`, checked with both luau-analyze 0.740 and luau-lsp 1.70.1 `--platform=roblox`.

- A: `packetA<S>(s: S): PacketTF<S, Player>`, with the whole method table built in a type function.
  - `Net.hitA:connect(function(value, player)` gives `value: { crit: boolean?, pos: {x: number, y: number}, target: number }` and `player: { Name: string, UserId: number }`.
  - A wrong `fire` field type is rejected, a missing field is rejected, and a wrong field use inside the handler is rejected.
- B: `packetB<S>(s: S): Packet<Payload<S>>`, where `Packet<T>` is a plain generic alias and the type function computes only `T`.
  - Inference is the same, and the `Player` alias name is kept.
  - It covers the tagged union, `u8`, and `array(str)`.
  - Rejected: a wrong `fire` type, a missing field, `fire("x")` on a number packet, and a handler annotated with the wrong type.
- C: `packetC<T>(c: Codec<T>): Packet<T>`.
  - It works for `u8` and `array(str)`.
  - For `struct(Hit)` and `tagged(…)` it gives `value: unknown`, and **`hitC:fire({target="1", …})` is NOT rejected**. There is no error at the definition.
- Robustness, A vs B:
  - The hover/error type for B is `Packet<{ crit: boolean?, … }>`. For A it is a fully expanded `{ connect: (unknown, (…) -> ()) -> (), fire: (unknown, …) -> () }`.
  - In a typo'd method error (`Key 'conect' not found in table 'Packet<…>'`), B reads better.
  - Under the old solver (T7), B keeps method-name checking and A keeps nothing.
  - A malformed schema reports the type function's own `error()` message at the definition, for both A and B.
- An assigned handler (`local h = function(value, player) … end; Net.hitB:connect(h)`) gets no inferred parameters. The checker then reports a mismatch at `connect`. This confirms the earlier finding.

## T6: side views from one shared schema. **TRUE** for both approaches; messages are readable but expanded

Probes: `t6/lync.luau`, `t6/net.luau`, `t6/server.luau`, `t6/client.luau`

The definition is `Packet<T> = { read _value: T, read _server: ServerPacket<T>, read _client: ClientPacket<T> }`.
- G: `server(schema): SelectSide<S, "_server">`, a type function that only selects the phantom property.
- F: `BuildSide<S, "server", Player>` builds the method types inside the type function.

For both, through `require`:
- The server `connect` gives `value` and `player` exactly. The client `connect` gives `value`.
- Rejected:
  - client-style `SG.hit:fire(payload)` on the server ("Argument count mismatch. Function expects 3 arguments, but only 2 are specified", plus a payload-vs-Player error)
  - a nonexistent `fireServer`
  - server-only `fireAll` on the client
  - server-style `fire(p, payload)` on the client
  - a two-parameter handler on the client
  - a wrong payload

Messages:
- G: `Key 'fireServer' not found in table '{ connect: t1, fire: (t2, { Name: string, UserId: number }, string) -> (), fireAll: (t2, string) -> () } where t1 = … ; t2 = …'`. The alias names `ServerPacket`/`ClientPacket` are **lost** once a type passes through a type function, and the recursive `self` makes the message cyclic.
- F: `Key 'fireAll' not found in table '{ connect: (unknown, ({ note: string, target: number }) -> ()) -> (), fire: (unknown, { note: string, target: number }) -> () }'`. This is flat and somewhat easier to read.

Neither message names "server" or "client". A malformed schema in G shows the raw type-function error unless the function guards it.

## T7: the old solver. **RUNS**; type functions **error in the library file** and degrade **silently to error-type (≈ any)** in the user's file; the user's file is not broken

Probes: `t7/` (library with `--!strict`) and `t7nocheck/` (library with `--!nocheck` and `--!nolint UnknownGlobal`). Run with `luau-analyze 0.740 --solver=old` and `luau-lsp 1.70.1 --flag:LuauSolverV2=false --platform=roblox`; both gave identical results.

- Library file:
  - `TypeError: This syntax is not supported` at each `type function`
  - `read keyword is illegal here` at each `read` property
  - `Unknown type 'Infer'/'Payload'/'PacketTF'` at each use
- User file:
  - Payloads become `*error-type*`, so wrong field reads in handlers, a wrong `fire` payload and a missing field are **all unreported**.
  - `Net.hitB:nonexistent()` is still reported (`Key 'nonexistent' not found in table 'Packet<*error-type*>'`) because B's `Packet<T>` is a plain alias. A keeps nothing.
  - Unrelated errors in the user file are still reported.
- With `--!nocheck` and `--!nolint UnknownGlobal` at the top of the library:
  - The old solver shows **no library diagnostics**, with the same degraded user checking.
  - The new solver still gives **full** checking in the user file.
  - Without `--!nolint`, `--!nocheck` produces `UnknownGlobal 'types'/'Infer'` lints inside type-function bodies.
  - The cost is that the library's own implementation is not type-checked, so it should live in a separate types module.
- Per the skill's host notes (announcement dated 2025-11-20), Roblox `--!strict` scripts run on the old solver unless `Workspace.UseNewLuauTypeSolver` opts in. Re-check before relying on this.

## P1: encode+decode of a 6-field record. Straight-line bit32 is fastest: **~3.2–4.6x faster than closures interpreted, ~4.2x native**; `writebits` is **1.3–1.5x slower interpreted, ~2.1x native**

Probe: `p1_codec_bench.luau`. Raw output: `p1_results.txt`. Settings: 200k encode+decode pairs per sample, 15 samples, variants interleaved, 1 warm-up. Fields are three ranged ints packed into one u32, an f32, a bool (u8), and a 9-char string with a u8 length prefix. All three variants produce identical bytes, and the round trip is asserted. No validation. Decode allocates the output table.

| luau 0.740, -O2 | (a) closures | (b) straight-line bit32 | (c) straight-line writebits | a/b | c/b |
|---|---|---|---|---|---|
| interpreted, rep 1 | 1126 ns | 348 ns | 470 ns | 3.24 | 1.35 |
| interpreted, rep 2 | 1308 ns | 283 ns | 408 ns | 4.62 | 1.44 |
| native `--codegen`, rep 1 | 612 ns | 144 ns | 301 ns | 4.24 | 2.09 |
| native `--codegen`, rep 2 | 583 ns | 138 ns | 288 ns | 4.22 | 2.09 |

- Values are medians. The min/max spread per sample was about ±30%, but the ordering never changed. An earlier -O1 run gave the same ordering (a/b 3.5 interpreted, 4.1 native).
- `buffer.writebits` and `buffer.readbits` exist in 0.740 and compile to `CALLFB` (a builtin call), while `writef32`/`writeu32` compile to `FASTCALL3`. That explains why (c) loses most under native code.

## P2: building the decode output. **The constructor literal is fastest**: `table.clone(template)` + writes is **~2.1x slower interpreted, ~1.6x native**

Probe: `p2_construct_bench.luau`. Raw output: `p2_results.txt`. Settings: 1M constructions per sample, 15 samples, interleaved. GC cost is included.

| luau 0.740, -O2, medians (rep 1 / rep 2) | interpreted | native |
|---|---|---|
| literal `{ a = …, …, name = … }` | 45.8 / 50.3 ns (1.00) | 46.7 / 47.5 ns (1.00) |
| `table.clone(TEMPLATE)` + 6 constant-key writes | 98.7 / 103.7 ns (~2.1x) | 74.9 / 74.3 ns (~1.6x) |
| `{}` + 6 constant-key writes | 104.5 / 118.5 ns (~2.3x) | 115.7 / 118.6 ns (~2.5x) |
| `{}` + 6 dynamic-key writes (data-driven loop) | 249 / 266 ns (~5.3x) | 232 / 234 ns (~4.9x) |
| `table.clone(TEMPLATE)` + 6 dynamic-key writes | 135 / 132 ns (~2.8x) | 116 / 115 ns (~2.5x) |

`table.clone` only pays off over a `{}` that grows as fields are written, as in a data-driven decoder. A generator that emits literals beats both.
