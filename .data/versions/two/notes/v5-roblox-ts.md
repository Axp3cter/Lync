# Lync v5: roblox-ts support

Design for review, dated 2026-10-03, revised after the coordinator's decisions (real objects never mutated, Bun as the
runtime, the name `@axpecter/lync`). It builds on [spec/api.md](../../spec/api.md), [v5-api.md](v5-api.md) §10,
[v5-goals.md](v5-goals.md), [v5-testing.md](v5-testing.md) §3 and v4's `index.d.ts`.

**How to read.** `[S#]` names a source. *Verified here* marks something I ran with Bun 1.3.14 on this machine: a
306-line prototype of the declarations with 92 proof notes in the spec's Declared form, which pass under
tsc 5.5.3 and 5.9.3 against stand-in globals and against the real `@rbxts/types` 1.0.954 and `@rbxts/compiler-types`
3.0.0-types.0; `rbxtsc` 3.0.0 compiling a small project against the declarations; and a Luau microbenchmark. No
package was downloaded: they came from an existing Bun-made install in the sibling project
`Ergo/.data/lab/toolchain/rbxts` (read only; `bun.lock`, `.bunx` shims) and TypeScript 5.9.3 from
`WebstormProjects/Axpecter`. A fresh `bun install` is the one probe not run (§8.1).

## 1. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | How `index.d.ts` is produced | Hand-written at `packaging/npm/index.d.ts`, no generation (§4) |
| 2 | Shape | `declare namespace Lync` for types, an interface for values, `export =`, as in v4 |
| 3 | `size()`, `entries()` (A-139) | The npm entry wraps views, server events, collections and groups in frozen adapters that delegate to the real objects; `src` is untouched (§6.3) |
| 4 | Package | `@axpecter/lync`, continuing its published versions; layout `src/{init.luau, Adapter.luau, index.d.ts, lync/}`; version from `packaging/wally.toml` |
| 5 | Runtime | Bun runs tsc and `rbxtsc` (*verified here*); `setup` runs `bun install --frozen-lockfile`; Bun is pinned by rokit if its asset choice checks out, else by a version check (§7.2) |
| 6 | Proof | `tsc --noEmit` under TypeScript 5.5.3 and 5.9.3 with the real `@rbxts` types; an `rbxtsc` compile gate on the built package |
| 7 | Spec | Changes listed in §8.2 |

## 2. The state of things

| Topic | Finding | Source |
|---|---|---|
| Compiler | roblox-ts 3.0.0 (2024-09-12) pins `typescript` `=5.5.3`; the `next` build of 2026-10-01 pins `=5.9.3`. No 3.1.0 release; `Symbol.iterator` (#1826) is open in that milestone with no branch or pull request | [S1] [S9] |
| TypeScript | 6.0.3 (2026-04-16) is the last JavaScript-based release. 7.0.2 (2026-07-08) is native, has no compiler API (7.1 is expected to) and drops `moduleResolution: node`, which roblox-ts uses. roblox-ts stays on 5.x | [S4] [S12] |
| Type packages | `@rbxts/types` 1.0.956 (2026-09-30; about weekly) generates `Instances` and the `Enum` namespace. `@rbxts/compiler-types` 3.0.0-types.0 replaces the standard lib under `noLib` (`Record`, `Exclude`, `LuaTuple`, `IterableFunction`, `Map`): declarations may use only these globals | [S2] [S3] [S13] |
| Shipping Luau | A `.d.ts` sits beside the Luau file with the same stem; `index.d.ts` pairs with `init.luau`. The compiler strips `.d.ts`, renames `index` to `init`, appends `.luau` (3.0.0 default) | [S7] [S8] |
| Manifests | `main` and `types`. jecs, bytenet, remo and squash ship `src/` with a `.d.ts` inside; jecs and bytenet hold no project file | [S8] [S10] |
| Scopes | Unscoped packages are refused (`noUnscopedModule`). A scope must be in `typeRoots` (`noInvalidModule`) and in the Rojo `node_modules` folder under `rbxts_include` (`noRojoData`) | [S6] [S8] |
| Calling convention | A method signature compiles to a colon call; a function-typed property, a `this: void` call signature or a namespace function to a dot call. Mixing both in one type is `noMixedTypeCall`; method shorthand where a callback property is expected is `expectedFunctionGotMethod` (*verified here*) | [S5] |
| Other bans | `noAny`, `noIterableIteration` (`for of` needs an array, `Map`, `Set` or `IterableFunction`), `noCommentDirectives` (`@ts-expect-error`) | [S5] [S8] |
| Peer libraries | bytenet: hand-written, a `ByteNetType<T>` brand, both sides' methods on one type. remo: hand-written builders, unique-symbol brands splitting server and client remotes. Flamework: `createEvent<Server, Client>()`, a macro. Zap: a `typescript` option generates `.d.ts` beside generated Luau | [S10] |

Luau libraries with a fixed API hand-write the `.d.ts`; only generators generate it. Lync's API is fixed, and it needs
remo's side-splitting brands.

## 3. Mapping the typed API

### 3.1 Rules for every declaration

1. Every function on `Lync` has `this: void` (dot call). Every codec, definition, view, signal and connection member is
   a method (colon call), as in Luau.
2. A callback a user writes inside an object literal (`convert`'s `decode` and `encode`, seam functions) is a
   function-typed property, so an arrow matches; method shorthand there is a compile error in roblox-ts.
3. Public types never contain `any`; failures resolve to `never` or `unknown`.
4. Only compiler-types globals are used; the stub run under `noLib` would have failed on any other.
5. No TypeScript 5-only syntax (no `const` type parameters, no `satisfies`); it passes on 5.5.3 and 5.9.3.
6. Hidden brands use the rbxts convention, `/** @hidden */ readonly _nominal_x`. `Group` is nominal.

### 3.2 The mapping

| Lync | TypeScript |
|---|---|
| Leaf codec value and call (A-17) | `Codec<T>` for the bare value, intersected with call signatures: `Lync.integer(0, 255)` |
| Record of codecs (A-37) | An object type from `Infer<S>`; an optional codec gives an optional property |
| `union` (A-42) | `{ kind: "hit" } & fields`, flattened. `NoKind<V>` rejects a `kind` field in a variant (A-180 at compile time) |
| `oneOf`, `flags` (A-40, A-41) | `oneOf<N extends Record<string, true>>` returns `keyof N & string`; `flags` returns `{ [K in keyof N]: boolean }`; both refuse an empty or `false` set |
| `optional`, `latest`, `partition` (A-44 to A-49) | Separate interfaces `Codec`, `OptionalCodec`, `LatestField`, `PartitionField`; the illegal orders simply have no method |
| Partition eligibility (A-47) | Only boolean, integer, string, `oneOf` and enum codecs have `partition()` |
| `array`, `map` | `T[]` and `Map<K, V>` (a roblox-ts `Map` is a plain Lua table); optional elements refused by `NotOptional<S>` (A-169, A-173) |
| `instance` (A-30, A-31) | `Codec<Instance \| undefined>` intersected with `{ [K in keyof Instances]: Codec<Instances[K] \| undefined> }` |
| `enum` (A-32) | A mapped type over `Exclude<keyof typeof Enum, "GetEnums">`; the item type is `ReturnType<(typeof Enum)[K]["GetEnumItems"]>[number]`, the `Enum.Material` union |
| `convert` (A-43) | `Codec<U>`, `decode` and `encode` as function-typed properties, `U` inferred from `decode` |
| Events (A-51 to A-58) | `Event`, `LossyEvent`, `TimedEvent`, `TimedLossyEvent`, one interface per state, so `unreliable()` then `latest()` is a missing property (A-56). No payload means `void`, so `fire(Lync.all)` compiles |
| Collections (A-84 to A-110) | `Collection<R, K>`; `K` is read from the one `PartitionField` (`never` when none, so `show` cannot be called) |
| Views (A-4) | `ServerView<D>` and `ClientView<D>` map the namespace through the phantom `Declared<S, C>` fields. Client types lack `validate`, `limit`, `show`, `hide`, `update`, `clear` |
| Requests, `validate`, `limit` (A-64 to A-83) | `Request<Q, R>`: `invoke` returns `Result<R>`, `handle` takes `(value, player) => R`. `validate` and `limit(rate, burst?)` exist on the server types only; a validator returns `string \| undefined` |
| `Result`, `Signal` | `Result<T, E extends string = "Timeout" \| …>` discriminated on `ok` (A-158); `Signal<[id: number, record: R]>` with `connect` |
| Seams (A-10 to A-13) | Typed as written: functions are properties, signals are methods, so a `RBXScriptSignal` passes unchanged (*verified here*) |
| `observe`, `metrics`, `configure`, `flush`, `check` | `ObservedEvent` (F-60 to F-66), `Metrics` (F-76), `Settings` (A-117), `flush(namespace?, budget?)`, `check(schema, value): Result<Infer<S>, string>` |

### 3.3 The core, abridged

```ts
declare namespace Lync {
	interface Brand<T> { /** @hidden */ readonly _nominal_codec: T }
	interface Codec<T> extends Brand<T> { optional(): OptionalCodec<T>; latest(rate?: number): LatestField<T> }
	interface PartitionableCodec<T> extends Codec<T> { partition(): PartitionField<T> }
	interface OptionalCodec<T> extends Brand<T | undefined> { latest(rate?: number): LatestField<T | undefined> }
	type Infer<S> = S extends Brand<infer T> ? T : S extends object ? RecordOf<S> : never;

	interface Declared<S, C> { readonly _nominal_server: S; readonly _nominal_client: C }
	interface ServerEvent<T> { fire(recipients: Recipients, value: T): void; /* connect, validate, limit, trace */ }
	interface ClientEvent<T> { fire(value: T): void; /* connect, trace */ }
	interface ServerCollection<R, K> {
		[id: number]: Readonly<R> | undefined;
		show(key: K, recipients: Recipients): void; /* update, hide, clear, signals, trace */
		size(): number; entries(): IterableFunction<LuaTuple<[id: number, record: Readonly<R>]>>;
	}
	interface ClientCollection<R> { readonly [id: number]: Readonly<R> | undefined; /* signals, trace, size, entries */ }
	type ServerView<D> = { readonly [K in keyof D]: D[K] extends Declared<infer S, unknown> ? S : never };
}
// event<S extends Brand<unknown> | CollectionSchema>(this: void, schema: S & Marked<S>): Event<Infer<S>>
```

`Marked<S>` is the TypeScript form of A-69: a marker at the top level of an event or request schema prints
`Type 'LatestField<Vector3>' is not assignable to type '… & Message<"latest marks a collection field; …">'`. A marker
nested in a record gets the generic message that names `LatestField`.

### 3.4 Collections and the numeric index write

This closes the open item in v5-api §10 on how roblox-ts compiles `collection[id] = record`.

- **Types.** `[id: number]: Readonly<R> | undefined` gives the server the write (A-84), the removal (`c[id] = undefined`
  or `delete c[id]`, A-85) and the frozen read (A-98, A-153). On the client it is `readonly`: a write or `delete` is
  TS2542 (A-97). A string key is TS7015.
- **Offset.** roblox-ts adds `+ 1` to an index only when the receiver is definitely an array: a tuple, `Array`,
  `ReadonlyArray`, or anything for which `typeChecker.isArrayLikeType` holds, which TypeScript defines as an array or a
  type assignable to `readonly any[]`. Reads, writes and `delete` share `addOneIfArrayType` [S5]. A collection is an
  interface with a numeric index signature and a few methods, so it is not array-like. *Verified here*: `rbxtsc`
  3.0.0 emitted `server.fighters[0] = {…}`, `local record = server.fighters[0]` and, for `delete`,
  `server.fighters[0] = nil`, with no `+ 1`. Two guards keep it so: a type test
  (`[ServerCollection<…>] extends [ReadonlyArray<any>] ? false : true`) and the compile gate (§7.4).
- **Iteration.** `#c` is `size()` and `for id, record in c` is `for (const [id, record] of c.entries())`, emitted as
  `for id, fighter in server.fighters:entries() do` (*verified here*). The collection has no `[Symbol.iterator]`, so
  `for (const x of c)` is TS2488.

### 3.5 What cannot be typed as well as in Luau, and what is better

| Item | Gap | Workaround |
|---|---|---|
| Custom error text (A-69) | Only top-level markers get a sentence; the rest is tsc's generic message | `Marked<S>` |
| `Lync.enum`, `Lync.instance` keys | Taken from the user's `@rbxts/types`, not the pinned dump (A-34, A-36). A name newer than the pin type-checks, then throws at module load (A-35) | Accept: loud and immediate |
| Iteration and length | No `#`, no `for in`; `Signal<A...>` becomes one tuple parameter | `size()`, `entries()` from the adapter |
| Yielding | `invoke` yields and TypeScript cannot say so (nor can Luau) | JSDoc `@yields`; call in a thread; no `Promise` wrapper |
| Snapshot depth | `Readonly<R>` is shallow, as A-153 says | Revisit if A-100's freeze is deep |
| Ranges, quantization, codec kinds | Every number is `number`; `Codec<Vector3>` is both `vector3` and `direction` | As in Luau |
| `update(id, { title: undefined })` | Compiles and changes nothing (*verified here*) | As in Luau's `{ title = nil }`; `Lync.none` clears |
| Extra fields through a variable | Excess-property checks apply to fresh literals only (*verified here*) | As in Luau; the decoder refuses unknown fields (A-37) |

Better than Luau, at compile time: `partition()` only on eligible codecs, no `kind` in a variant, no empty or `false`
name set, no optional array element.

## 4. Producing `index.d.ts`

**Recommendation: hand-written in `packaging/npm/index.d.ts`, with no generator.**

- The surface is a state machine of about 40 interfaces and a dozen conditional and mapped types. The Luau source
  expresses it with type functions, which no translator can read; `luau2ts` and `rbx-tsx` turn them into `any`
  [v5-research §4].
- The only data `generate` pins, enum and class names, is already in the user's `@rbxts/types`, so the declarations
  derive it. A list from the pin would match the runtime exactly, but the failure it prevents is loud (A-35).
- v4's file drifted because nothing compared it (v4-inventory §2.8, defect 18). The check is the proofs of §7 plus
  `Equal<keyof typeof Lync, …A-116's 36 names>` and the exact member lists of A-136 and A-138 (*verified here*).
- Closed sets both languages state (`reason`, `condition`, `cause`, F-67) are copied by hand and pinned by `Equal`
  tests in both suites; a spec edit fails both until both are updated.

## 5. The Declared claims

### 5.1 How each mistake becomes a compile error

*Verified here* on tsc 5.5.3 and 5.9.3. Codes are tsc's.

| Claim | Mistake | What rejects it | Diagnostic |
|---|---|---|---|
| A-128 | Wrong value type | `fire(recipients, value: T)`, `invoke(player, value: Q)` and the collection index take types computed by `Infer` from the schema; record writes are also checked for missing and unknown fields | TS2345, TS2322, TS2353, TS2741 |
| A-129 | Reply of the wrong type | `handle(handler: (value: Q, player: Player) => R)` checks the return against `R` | TS2322 |
| A-130 | Key outside the partition field | `show(key: K, …)`, `hide(key: K)`; `K` comes from the single `PartitionField<T>`, `never` when none | TS2345 |
| A-131 | Client fires with recipients | `ClientEvent.fire(value: T)` has one parameter | TS2554 |
| A-132 | Undeclared or missing flag | `flags` returns `{ [K in keyof N]: boolean }`; a fresh literal is checked both ways | TS2353, TS2741 |
| A-133 | Undeclared `oneOf` string | `oneOf` returns `keyof N & string`; `N extends Record<string, true>` keeps keys literal | TS2345, TS2322 |
| A-134 | Name not in `Lync.enum` | A mapped type over the installed `Enum` namespace: a typo is a missing property with a suggestion | TS2551 |
| A-139 | `size()`, `entries()` | Declared on `ServerCollection`, `ClientCollection` and `Group`; the collection has no iterator | none; TS2488 for `for of c` |
| A-165 | All of A-128 to A-134 | The rows above | |

### 5.2 A proof gap in A-139

tsc proves the declaration says `size()` exists, not that the entry provides it (a nil method call in a live game). A-139
is therefore proved three ways: the types by tsc, the
emitted `c:size()` and `c:entries()` by the compile gate (§7.4), and the behaviour by Tested claims on the adapter (§8.2).

## 6. The npm package

### 6.1 Name and version

- **`@axpecter/lync`**, continuing the maintainer's published line: 1.3.0 to 3.1.3 (latest 2026-08-29); v4's 4.0.3 is not
  on npm, so 5.0.0 follows without a clash. Wally spells the author `axp3cter`, npm `axpecter`; the README shows both.
  [S11]
- **Version.** `packaging/wally.toml` stays the only source. `packaging/npm/package.json` has no `version`; `package`
  reads it with `Versions.read()` (SemVer, which npm also uses) and writes it into the built manifest. A pre-release
  such as `5.1.0-rc.1` prints `--tag next`, because npm otherwise makes it `latest`.

### 6.2 Layout, built by `package` from the release variant

```
build/packages/npm/
	package.json     template + version; "main": "src/init.luau", "types": "src/index.d.ts", "files": ["src"]
	LICENSE
	README.md        install, the two setup edits, an example
	src/
		init.luau    return adapt(require("@self/lync")), after darklua's release rules
		Adapter.luau packaging/npm/Adapter.luau: exports adapt(Lync), requires nothing
		index.d.ts   packaging/npm/index.d.ts, byte for byte
		lync/        build/release/src: its init.luau is the Luau entry
```

`package.json` also carries `peerDependencies` on `@rbxts/types` (floor: the oldest version the suite passes, measured)
and `@rbxts/compiler-types` (`^3.0.0-types.0`), `license`, `repository` and `publishConfig.access`.

- **No project file.** A game's own Rojo project maps the folder and roblox-ts computes the path from it, as for jecs and
  bytenet. The emitted import is `TS.import(script, …, "node_modules", "@axpecter", "lync", "src")` (*verified here*).
- **A checked file list.** `package` runs `bun pm pack --dry-run` and fails if the list differs from the five expected
  entries. The 3.0.2 upload to this name held 342 files and 3.3 MB [S11], and a version cannot be replaced. On a probe
  package the command lists files offline and honours `files`. Publishing is by hand (`bun publish --access public`,
  or `npm publish`); I did not run `publish`.
- **Consumer setup**, the README's two edits: `"node_modules/@axpecter"` in `typeRoots`, and
  `"@axpecter": { "$path": "node_modules/@axpecter" }` beside `@rbxts` in the Rojo `rbxts_include.node_modules` folder.
  The compiler diagnoses either omission. The minimum is roblox-ts 3.0.0, which emits `.luau` by default; older
  compilers are untested.

### 6.3 The adapter

**Nothing real is mutated.** `src` keeps freezing views, collections and groups. `adapt(Lync)` returns a frozen copy of
the `Lync` table with `server`, `client`, `group` and `except` replaced; every other member is the Luau entry's own.

| Real object | What the npm entry hands out | Mechanism |
|---|---|---|
| View (A-4) | A frozen view, built once per real view and cached in a weak-keyed table | The real function returns one view per namespace and seams (A-6, A-145, A-146), so the adapted one is stable too |
| Collection (it has `added`) | A frozen table with raw `size`, `entries`, forwarders for the methods, the real signal objects, and a metatable whose `__index` and `__newindex` are the real collection **as tables** | An id read or write is one table hop into the real metamethods, with the real object as `self`; a client write throws the real error (A-150) |
| Server event (it has `fire` and `limit`) | A frozen table of forwarders | `fire` swaps an adapted group for the real one |
| Group | A frozen table with `add`, `remove`, `has`, `size`, `entries`, registered adapter-to-real in a weak map | `entries` snapshots the ids, then reads one record per step |
| `except`, collection `show` | Forwarders | The same swap, then the real call |
| Everything else | The real object | Client events, requests, signals, connections, records, `Lync.all`, `Lync.none` |

The kinds are told apart by the member sets that A-136 to A-138 fix. A group is a recipient in three places (A-59, A-89,
A-112), which are the three swap sites.

**Identity (`===`).**

| Expression | Result |
|---|---|
| `server(ns) === server(ns)`, and `view.fighters === view.fighters` | True: the adapted view holds its adapters |
| `Lync.group() === Lync.group()` | False, as in Luau (A-114) |
| An adapter against the real object | False; the real objects are unreachable from the npm entry |
| A record, signal, connection or request read twice | True, and the real one: they pass through |
| After `Lync.stop()` | A new real view gives a new adapted view (A-152); old adapters point at the ended instance, as the real objects do |
| Luau requiring the inner `lync` module | Gets real objects of the same instance; they are not `===` the TypeScript adapters and must not be exchanged with them |

**Cost.** Measured with Lute 1.0.0 (Luau 0.740, interpreter) here: 2 million operations, median of 7, a stand-in collection with
the spec's metamethod shape. Indicative only; `bench/micro` gets the real rows.

| Operation | Real | Adapted | Note |
|---|---|---|---|
| Read by id | 37 ns | 40 ns | Table hop; function forwarding would cost 61 ns |
| Write by id | 35 ns | 41 ns | Table hop; function forwarding 59 ns |
| Server `fire` | 20 ns | 43 ns with a group, 65 ns on a lookup miss | One call and one weak-table lookup; a `typeof(...) == "table"` guard would skip it for a `Player` (not measured) |

Method calls and `size()` add one call; `entries()` is O(n) once per call (an id snapshot, so removals during a loop are
safe); client events, requests, signals and records add nothing; creation is once per real view.

**Typing.** The declarations describe the adapters, because the npm entry never exposes a real object: `ServerEvent`,
`ServerCollection`, `ClientCollection` and `Group` are the adapter types, so nothing in the declarations changes shape.
`Group` gains the hidden brand `_nominal_group`, so only a group from `Lync.group()` compiles; a structural fake is
rejected (*verified here*).

**Tests.** `adapt` takes `Lync` as an argument, so the Test variant builds `Adapter.luau` and a suite calls
`adapt(Lync)` on the test variant's entry, with the claims of §8.2.

## 7. The type-test runner

### 7.1 Pins and where they live

| What | Pin | Why |
|---|---|---|
| `bun` | `1.3.14` (tested; latest is 1.4.2) | Runs `tsc.js` and `rbxtsc` directly (*verified here*) |
| `typescript` | `5.5.3` | What every roblox-ts 3.0.0 user type-checks with |
| `typescript-next` | `npm:typescript@5.9.3` | The `next` compiler's pin; a second install by alias |
| `@rbxts/types` | `1.0.956` | Latest; run here at 1.0.954 |
| `@rbxts/compiler-types` | `3.0.0-types.0` | The only 3.x release |
| `roblox-ts` | `3.0.0` | The compile gate |

No TypeScript 6 or 7 run: roblox-ts cannot use them.

```jsonc
// test/types/ts/package.json  (private, exact versions; bun.lock beside it, committed)
{ "private": true, "packageManager": "bun@1.3.14",
  "devDependencies": { "typescript": "5.5.3", "typescript-next": "npm:typescript@5.9.3", "roblox-ts": "3.0.0",
	"@rbxts/types": "1.0.956", "@rbxts/compiler-types": "3.0.0-types.0" } }
```

```jsonc
// test/types/ts/tsconfig.json: the roblox-ts template's options plus the mapping to the source declaration
{ "compilerOptions": { "target": "ESNext", "module": "commonjs", "moduleResolution": "Node", "moduleDetection": "force",
	"noLib": true, "strict": true, "allowSyntheticDefaultImports": true, "downlevelIteration": true,
	"noEmit": true, "skipLibCheck": false,
	"typeRoots": ["../../../build/typescript/node_modules/@rbxts"],
	"baseUrl": ".", "paths": { "@axpecter/lync": ["../../../packaging/npm/index.d.ts"] } },
  "include": ["*.ts"] }
```

**`skipLibCheck` stays false, and foreign errors are ignored.** `index.d.ts` is a declaration file, so `true` would hide
errors in it. But `@rbxts/types` 1.0.954 reports 14 diagnostics of its own under tsc 5.5.3 and 18 under 5.9.3
(TS2344, an unknown `CollectionHandle`, TS2536 on `Steps`) (*verified here*). The runner ignores diagnostics whose file
is under `node_modules`, prints how many, and treats every other file as ours.

### 7.2 Setup, the pin for Bun, and the manifests

- **Manifests stay out of the install.** `test/types/ts/` holds `package.json`, `bun.lock` (text lockfile), `tsconfig.json`
  and the `.ts` files. `node_modules` lives in the git-ignored `build/typescript/`: inside `test/`, thousands of files
  (including `roblox-ts/include/*.lua`) would sit under the folder the Test variant runs darklua over, Rojo syncs and
  `Citations` walks. The Test variant therefore skips `test/types/`, and `Citations.listCitingFiles` skips `node_modules`.
- **`setup`** gains a last step in `Toolchain.install`: copy the manifest and lock to `build/typescript/`, run
  `bun install --frozen-lockfile --ignore-scripts --cwd build/typescript` (flags in 1.3.14's help), and write a stamp
  holding the lock's sha256, skipping when it matches, as `fetchUnlessCurrent` does. If `bun` is missing it fails with one
  line, and `judge` reports `Incomplete` rather than skipping the Declared claims.
- **Pinning Bun.** It is not in `rokit.toml`. Rokit's extractor takes the best-scoring file named `bun.exe` anywhere in an
  archive [S14], so Bun's nested `bun-windows-x64/bun.exe` extracts and `oven-sh/bun@1.3.14` is a valid spec. The release
  holds `bun-windows-x64.zip` (38.4 MB), a `-baseline` build and `-profile` builds (about 160 MB) [S15]; which one rokit
  selects is unverified and needs one throwaway `rokit add`. Pin by rokit if it picks the plain build; otherwise `setup`
  compares `bun --version` with the `packageManager` field above and fails with the install hint. Today Bun is at
  `~/.bun/bin`, off the shell `PATH`; CI uses `oven-sh/setup-bun` at the same version.

### 7.3 The runner and the notes

`scripts/project/DeclaredTests.luau`, beside `TypeTests.luau`, runs
`bun build/typescript/node_modules/<compiler>/lib/tsc.js -p test/types/ts/tsconfig.json --pretty false` once per pinned
compiler (*verified here*) and parses `file(line,col): error TSnnnn: text`. `Citations.luau` already reads
`// proves <id>;` from `.ts` files and keeps only `proves` there; the runner adds the sentence after the semicolon.

| Luau note | TypeScript note |
|---|---|
| `-- proves A-n; the checker must report an error on the next line` | `// proves A-n; tsc must report an error on the next line` |
| `-- infers A-n; the checker must report no error on the next line` | `// proves A-n; tsc must report no error on the next line` |

- The verb stays `proves`, the only one `Citations` accepts in `.ts`; the sentence says error or no error, and any
  other is a problem.
- `infers` binds the value to an annotated variable so a wrong type is an error. TypeScript assignment is covariant, so
  use `const _x: Equal<typeof x, Expected> = true`, with the identity form
  `(<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2)`; mutual assignability passes for `any`.
- A marked statement fits on one line, since tsc may report a multi-line statement on any of its lines.
- Match rules, as for Luau (H-129): every diagnostic is on an error-marked line, every error-marked line has one, no
  clean-marked line has one; `index.d.ts`, unmarked lines and config errors (TS5xxx) are problems. Every compiler must
  agree.
- No `@ts-expect-error`: roblox-ts refuses comment directives, so v4's `Rejections.ts` could not be compiled by it.

```ts
// A-128: a wrong value type (cites A-165 until the split)
// proves A-165; tsc must report an error on the next line
server.chat.fire(Lync.all, 5);
// proves A-165; tsc must report no error on the next line
server.chat.fire(Lync.all, "hello");
```

Files: `Mistakes.ts`, `Inference.ts`, `Collections.ts` (index write, `size`, `entries`, the array-like guard),
`Members.ts` (A-116, A-135 to A-138) and `Compile.ts` (no negative line). A plain comment above a note is ignored.

### 7.4 The compile gate

tsc cannot see roblox-ts's own diagnostics or the emitted Luau, and a wrong calling convention reaches a live game. So
`claims` also compiles `Compile.ts`, ported from v4's `Gate.luau`: a throwaway **game** project in git-ignored
`build/gate/` with a Rojo project mapping `rbxts_include.node_modules` for `@rbxts` and `@axpecter`, a junction
`node_modules/@rbxts` to the install (the compiler requires `typeRoots` to contain exactly that path), and
`node_modules/@axpecter/lync` pointing at `build/packages/npm`. It runs
`bun build/typescript/node_modules/roblox-ts/out/CLI/cli.js -p build/gate --type game --noInclude` (*verified here*,
exit 0, 76 ms for the file) and fails on any diagnostic, then reads the emitted Luau for dot calls (`Lync.string(`),
colon calls (`:fire(`, `:handle(`, `:size()`, `:entries()`), a write, a read and a `delete` at id `0` with no `+ 1`
and `delete` as `= nil`, and the import ending in `"lync", "src"`. Because the gate uses the built package, `claims`
builds it first.

## 8. Open decisions and spec changes

### 8.1 Decisions

| # | Decision | Recommendation |
|---|---|---|
| 1 | **Needs your approval:** a fresh `bun install`, the one probe not run, since downloads need your explicit approval and an agent message cannot give it. From registry.npmjs.org: `typescript` 5.5.3 (21.9 MB unpacked) and 5.9.3 (23.6 MB), `roblox-ts` 3.0.0 (0.8 MB) with dependencies (33 MB in all in the Ergo install), `@rbxts/types` 1.0.956 (5.2 MB), `@rbxts/compiler-types` 3.0.0-types.0 (0.06 MB); a rokit probe adds `bun-windows-x64.zip` (38.4 MB) | Approve; it settles the lockfile, the `npm:` alias and the Bun pin |
| 2 | Pin Bun by rokit or by version check (§7.2) | Rokit if the asset choice is right |
| 3 | TypeScript matrix | 5.5.3 and 5.9.3; drop 5.5.3 when roblox-ts 3.1.0 ships on 5.9 |
| 4 | The `@rbxts/types` floor and peer range | Measure the oldest passing version; run `latest` before each release |
| 5 | Compile gate in `claims` | Yes: the only proof of calling conventions and the index write |
| 6 | Test variant skips `test/types/`; `Citations` skips `node_modules` | Yes (§7.2) |
| 7 | `size()`/`entries()` against a future `Symbol.iterator` | Keep both (A-139) |
| 8 | A `Promise` wrapper for `invoke`; deep-readonly snapshots; deprecating 1.x to 3.x on npm | No; shallow until A-100 states the freeze depth; the maintainer's call |

### 8.2 Spec changes, for the agent that writes them

Ids are the next free numbers from A-194 in this order; the writer assigns them.

**Declared.** A-165 becomes `Withdrawn.` and keeps its id. Seven claims replace it, each of the form "In a TypeScript
project, `index.d.ts` must reject <mistake> as a type error.", with these mistakes, in order (the Luau claim each
mirrors): a value of the wrong type for a schema in `fire`, `invoke` and collection writes (A-128); a handler that
returns a value of the wrong type for the reply schema (A-129); a key that is not a value of the partition field's codec
in `show` and `hide` (A-130); a client calling `fire` with recipients (A-131); a flag that `flags` does not declare
(A-132); a string that `oneOf` does not declare (A-133); a name that is not in `Lync.enum` (A-134).

In `spec/README.md` the Declared row's "Suits" becomes "A-139 and the seven claims that replace A-165". TypeScript notes
cite the new ids. A-139 stays Declared.

**Tested**, one statement each, by suites that call `adapt(Lync)` on the test variant:

1. The npm entry's `size()` on a collection or a group must return the number that `#` gives on the object it wraps.
2. The npm entry's `entries()` on a collection must give a generic `for` the ids and records that `for in` gives on the
   collection it wraps, and on a group the players.
3. The npm entry's `server` and `client` must return the same view for the same arguments for which `Lync.server` and
   `Lync.client` return the same view, and that view must hold the same collection and group on every read.
4. A group made by the npm entry's `group` must be accepted wherever a group is a recipient: in a server event's `fire`,
   in a collection's `show` and in `except`.
5. The npm entry's collections must delegate every member of A-138, and its server events every member of A-136, to the
   objects they wrap, with the same results and the same errors.
6. The npm entry's views, collections, server events and groups must be frozen tables.
7. The npm entry must hand out every other member of `Lync`, and every request, client event, signal and connection, as
   the same objects the Luau entry gives.

## Sources

- [S1] https://registry.npmjs.org/roblox-ts (read 2026-10-03: dist-tags, `typescript` pins)
- [S2] https://registry.npmjs.org/@rbxts%2Ftypes; https://unpkg.com/@rbxts/types@1.0.956/include/generated/enums.d.ts
- [S3] https://registry.npmjs.org/@rbxts%2Fcompiler-types; unpkg `@rbxts/compiler-types@3.0.0-types.0/types/typeUtils.d.ts`
- [S4] https://registry.npmjs.org/typescript (7.0.2 has no `main`); https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/
- [S5] roblox-ts v3.0.0, https://github.com/roblox-ts/roblox-ts/blob/v3.0.0/src/: `TSTransformer/util/` `isMethod.ts`,
  `validateMethodAssignment.ts`, `addOneIfArrayType.ts`, `types.ts`; `nodes/transformWritable.ts`; `Shared/diagnostics.ts`
- [S6] https://github.com/roblox-ts/roblox-ts/blob/master/src/TSTransformer/util/createImportExpression.ts
- [S7] https://cdn.jsdelivr.net/npm/@roblox-ts/path-translator@1.1.0/out/PathTranslator.js
- [S8] https://roblox-ts.com/docs/guides/using-existing-luau, /guides/typescript-packages/, /guides/syncing-with-rojo
- [S9] https://github.com/roblox-ts/roblox-ts/releases/tag/v3.0.0; issue #1826; PR #3104
- [S10] unpkg: `@rbxts/bytenet@0.4.3-tsprev4`, `@rbxts/remo@1.5.3`, `@flamework/networking@1.3.2`; Zap docs
  (github.com/red-blox/zap, docs/config/options.md); registry manifests of jecs and squash
- [S11] https://registry.npmjs.org/@axpecter%2Flync
- [S12] https://github.com/roblox-ts/create-roblox-ts/blob/master/templates/game/tsconfig.json
- [S13] unpkg `@rbxts/compiler-types@3.0.0-types.0/types/core.d.ts`, `Iterable.d.ts`
- [S14] https://github.com/rojo-rbx/rokit/blob/main/lib/sources/extraction.rs
- [S15] https://api.github.com/repos/oven-sh/bun/releases/tags/bun-v1.3.14 (asset names and sizes)
