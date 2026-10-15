# Build checks: foreign remotes, dynamic access, shard drift and a code hash in `HELLO` (U5, U6)

Researcher findings, 2026-10-15. **Decision it feeds:** whether and how v5 adopts items U5 and U6 of
`research/security-refusals.md` §4, which the research described (`research/client-security-build.md` §4.1–§4.3,
cited CSB) but the design never decided. The exact rule, where it runs, output, false positives and cost of each.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs or the design say so.
**reported**: a third party says so. **unverified**: inference, or nothing found.

**Tools.** Lune 0.11.0 and Rojo 7.7.1 (official Linux release binaries, in scratch, not committed); Luau 0.742
built from `.data/projects/luau` (CMake Release, scratch build); the luau skill's API dump 0.741.19; creator-docs
at the commit cached by `security-tooling.md` (cited by file). Machine: Xeon 2.1 GHz, 4 cores, shared, timings
pinned to one core (`taskset -c 3`). CLI timings show scale only.

**Probes** (`.data/docs/probes/build-checks/`, all reproduced by `run.sh`):
- `lex.luau`: a token-level Luau lexer of the kind the core carries (CSB §1.1);
- `scan.luau`: the shared scan: namespace bindings, `dynamicAccess` (3 kinds), and remote creation sites;
- `fixture_place.luau` → `check.luau` → `check_fixture.out`: a 41-instance place with every case marked EXPECT or
  CLEAN in its source;
- `scale_place.luau` → `scale.out`: places of 10k, 100k and 500k instances, sources cycled from 217 real Luau files;
- `bench_scan.luau`, `corpus_module.py` → `bench_scan.out`: lex and scan throughput under Luau 0.742;
- `rojo-fixture/`, `make_rbxm.luau` → `rojo_sourcemap.out`: what `rojo sourcemap` and `rojo build` expose;
- `scan_files.luau` → `real_creation.out`: the creation-site scan over Knit's Comm and Cmdr (fetched to scratch);
- `drift.luau` → `drift.out`: the shard self-digest, the drift cases it separates, SHA-256 cost.

## Checklist

- [x] 0. Bottom line
- [x] 1. U5a `foreignRemotes`
- [x] 2. U5b `dynamicAccess`, and how it and the reachability rule agree
- [x] 3. U6a Shard drift: what is hashed, the checks, where they run
- [x] 4. U6b A code hash in `HELLO`
- [x] Implications

## 0. Bottom line

1. **`foreignRemotes`: adopt.** It lists every remote outside Lync's two (`ReplicatedStorage.Lync.Reliable` and
   `.Unreliable`). Sources: the instance tree (place, Rojo sourcemap with non-scripts, or the plugin's DataModel)
   and `Instance.new("<class>")` sites in scripts. Evidence is `origin`, `network` and `replicates`; the
   Diagnostic defaults to `"warn"`, and `check.knownRemotes` quiets reviewed entries. The tree half costs about
   3 µs per instance after reading the place (Lune: 1.36 s in all, scan included, for 100k instances and 7.4 MB of
   source). Helper-made remotes (Cmdr) are seen only as non-literal sites, or by a play-test walk (§1).
2. **`dynamicAccess` and reachability are one predicate:** a namespace is incomplete if and only if a
   `dynamicAccess` is reported in it. The predicate adds iteration and unfollowed hand-offs to today's non-literal
   index. It follows aliases, fields, returns and arguments by name. Verified on a fixture with 10 sites: today's
   rule covers the 5 computed indexes (one only if it follows a parameter, which it doesn't specify). It misses the
   3 iterations, and by design it leaves the 2 unfollowed hand-offs complete. The cost is the detector on top of shared lexing: 11–12 MB/s
   interpreted, about 20 MB/s native, under Luau 0.742 (§2).
3. **Drift: adopt three build codes beside `staleShard`:** `editedShard` (a self-digest on line 1, CRLF-normalised),
   `unpairedShard` and `staleManifest`. Only a build or plugin can see a hand edit, since game code can't read
   `Source`. SHA-256 runs at about 0.04 ms per 64 KB shard (§3).
4. **Code hash in `HELLO`: don't add it to protocol v1.** At the default release seed an unmodified client
   always sends the expected value. Where it could differ, the build already reports `unpairedShard`. A modified
   client sends what it likes. If it is built anyway: 4 B per `HELLO`, a non-refusing fact `codeDiffers`, never a
   `schemaMismatch` reason. `weaveHash` is different: it refuses, because site tables change decoding (§4).

## 1. U5a `foreignRemotes`

### 1.1 What it protects, and what it does not

Lync's inbound pipeline (`v5.md` §6.1: shape, budgets, tag, strict decode, `limit`, validators) and every fact of
§7.3 cover exactly two instances: `ReplicatedStorage.Lync.Reliable` (`RemoteEvent`) and
`ReplicatedStorage.Lync.Unreliable` (`UnreliableRemoteEvent`), which the server creates on first use (`v5.md` §4.1,
documented). Every other remote in the place is an entry point into server code that Lync neither budgets nor
decodes nor reports on. `rawRemote` (`v5-tooling.md` §3) finds the *calls* (`:FireServer(` …) in scanned scripts;
`foreignRemotes` finds the *instances*: the attack surface a modified client can fire whether or not any script
calls it, which is what a developer needs when moving a game onto Lync or auditing a package.

It prevents nothing and judges nothing: it is an inventory with exact evidence. It does not cover engine entry
points that are not remotes (`ClickDetector`, `ProximityPrompt`, `Tool` activation, physics ownership); the
report says so in one line.

### 1.2 The rule

Two sources, one list.

1. **Tree entries.** Every instance whose `ClassName` is `RemoteEvent`, `UnreliableRemoteEvent` or `RemoteFunction`
   (and, with `check.foreignBindables`, `BindableEvent` or `BindableFunction`) anywhere in the place, except an
   instance at exactly `ReplicatedStorage.Lync.Reliable` of class `RemoteEvent` or `ReplicatedStorage.Lync.Unreliable`
   of class `UnreliableRemoteEvent`. A same-named instance of another class is listed (and would collide with Lync's
   own creation at run time).
2. **Creation sites.** In every script (client and server; the scan is the same lexer pass as reachability and
   `rawRemote`), each call `Instance.new("<class>")` whose first argument is one string literal naming one of those
   classes (kind 2), and each `Instance.new(<expr>)` whose argument is not a string literal (kind 3, class
   unknown to the build). Scripts in Lync's own package are skipped: the subtree of any `ModuleScript` whose first
   line is Lync's runtime header (`-- Lync <version> runtime`), so the runtime's own `Instance.new("RemoteEvent")`
   is never listed.

Evidence per entry, numbers and paths only: `class`, `instance` (path; for a tree entry) or `uri`/`range` (for a
creation site), `origin` (1 tree, 2 literal creation, 3 non-literal creation), `network` (1 for the three remote
classes, 0 for bindables), `replicates` (1 when the entry's top-level service replicates to clients, 0 for
`ServerScriptService` and `ServerStorage`).

Bindables are off by default because they are not network entry points: a client can fire only its own client-side
bindables, which reach client listeners, never the server (a modified client firing game signals is the **signal**
capability class, `generation-methods.md` header). Listing them is useful only for an audit of client-local
surface.

**Verified on the fixture** (`check_fixture.out`): Lync's pre-created pair is skipped; listed are
`ReplicatedStorage.Remotes.LegacyShop` and `.GetProfile`, a `RemoteEvent` inside a `Tool` in `Workspace`, a
`RemoteFunction` in `ServerStorage` (`replicates=0`), and, with bindables, one replicated and one server-only
bindable; creation sites `Instance.new("RemoteEvent")`/`("RemoteFunction")` in a forked chat runner and a
framework module (kind 2), and `Instance.new(className)` (kind 3); the Lync package's own two creations are not
listed.

**Verified on real packages** (`real_creation.out`): Knit's Comm (`Sleitnick/RbxUtil`, `RemoteSignal.luau:35`,
`init.luau:46`) creates from literals, so all three are found with their class. Cmdr (`evaera/Cmdr`,
`Cmdr/init.luau:24`) creates through a helper, `Instance.new(className)`, called with `"RemoteEvent"` and
`"RemoteFunction"` at lines 139–140: the scan reports one kind-3 site and cannot name the classes. Only the
play-test inventory (§1.3) sees what such helpers create.

### 1.3 Where it runs

| Host | Input | Sees | Misses | Status |
|---|---|---|---|---|
| CLI, Rojo project | `rojo sourcemap --include-non-scripts` (`{name, className, filePaths, children}`) plus the script files | every Rojo-managed instance, including the contents of `.rbxm` and `.model.json` files, with the containing file as the diagnostic's `uri` | content that lives only in the published place (maps, Toolbox models edited in Studio), and a sourcemap generated without `--include-non-scripts` (the default, and luau-lsp's usual setup, lists scripts only) | verified, `rojo_sourcemap.out`: the `RemoteEvent` in a `.model.json`, the `UnreliableRemoteEvent` child in another and the `RemoteEvent` inside an `.rbxm` Tool all appear; the scripts-only sourcemap omits all three |
| CLI over a built place | `lync check --place game.rbxl` (rbx-dom: `rbx_binary` in the Rust host, `@lune/roblox` in Lune) | everything in the file | instances Rojo doesn't build (as above), unless the place is downloaded | verified, `check.luau` over `rojo build` output and over generated places |
| Studio plugin, edit | `game:GetDescendants()` on the edit DataModel | the place as it will be published, Studio-only content included | run-time creations | API verified (dump: `GetDescendants` security None); Studio cost unmeasured |
| Studio plugin, play test | the same walk in the play-test server DataModel once Lync has started | run-time creations by any route: non-literal `Instance.new`, `:Clone()`, legacy chat's remotes | instances created later than the walk; services the plugin cannot read | **unverified**: that a plugin's code runs in the play-test server DataModel and can walk it there |

`ScriptEditorService:RegisterScriptAnalysisCallback` attaches diagnostics to scripts only (PluginSecurity, verified
dump), so the plugin shows tree entries (instances, not scripts) in its own widget; creation sites appear in the
script editor as Diagnostics.

### 1.4 Output

- **Manifest**: `foreignRemotes: [{ class, instance | uri+range, origin, network, replicates }]`, sorted by path,
  always written when the check runs; `report.md` renders it as one table.
- **Diagnostics**: one LSP Diagnostic per entry, code `foreignRemote` (singular, like `rawRemote`), severity from
  `check.foreignRemotes`, `data` = the evidence above. Tree entries from a sourcemap get the file's `uri` and range
  0:0; entries with no file (place-only content) get the place file's `uri` and `data.instance`. Example, in the
  `human` rendering's style (`v5-tooling.md` §3):
  `warning[foreignRemote]: ReplicatedStorage.Remotes.LegacyShop is a RemoteEvent outside Lync; its traffic is not budgeted, tagged or decoded by Lync`.
- **Entries named in `check.knownRemotes`** stay in the manifest and get no Diagnostic, so after one review the
  build warns only on *new* entry points. GitHub's limit of 10 annotations per step is already handled by the
  `github` renderer's step summary (`v5-tooling.md` §3).

### 1.5 Known causes in an unmodified game

Every entry is a real remote or a real creation site; none is a mistake by itself:
- the game's own remotes, from before Lync or kept on purpose;
- frameworks and packages that create remotes at run time: Knit/Comm (literal, kind 2), Cmdr (non-literal, kind 3),
  both verified in source; admin systems likely do the same (unverified);
- the legacy chat system: its scripts are inserted into the `Chat` service and "communication between server and
  clients is handled automatically using RemoteEvents" (documented,
  [legacy chat system](https://create.roblox.com/docs/chat/legacy/legacy-chat-system)). Those remotes exist only at
  run time, so a static build sees at most the creation sites in forked copies of its scripts;
- Toolbox models and gear that carry a remote inside a `Tool` or model (verified as a case in the fixture);
- remotes in `ServerStorage` that game code clones or moves into a replicated container (listed with `replicates=0`).

**Imprecision, both ways.**
- Over-listing: remotes that never leave `ServerStorage`; creation sites in dead code; a kind-3 site whose helper
  only ever creates non-remote classes.
- Under-listing in a static build: class names built at run time (kind 3 says so); clones from instances outside
  the place; assets inserted at run time (`InsertService:LoadAsset`); and, through the sourcemap, anything Rojo
  doesn't manage.

### 1.6 Cost

Build only; zero at run time and on the wire. Measured with Lune 0.11.0 over generated places (`scale.out`,
median of 3; the scan column covers all three script checks' shared lexing and is §2's cost too):

| Instances | Scripts, source | deserialize | walk (`GetDescendants`) | classify (inventory, collect sources) | lex + scan | total |
|---|---|---|---|---|---|---|
| 10,003 | 199, 1.41 MB | 53.6 ms (5.4 µs/instance) | 13.3 ms (1.3 µs) | 11.7 ms (1.2 µs) | 98.3 ms (14.3 MB/s) | 182 ms |
| 100,003 | 983, 7.43 MB | 474 ms (4.7 µs) | 169 ms (1.7 µs) | 121 ms (1.2 µs) | 580 ms (12.8 MB/s) | 1.36 s |
| 500,003 | 2,608, 19.8 MB | 2.75 s (5.5 µs; 5.43 s cold) | 1.17 s (2.3 µs) | 578 ms (1.2 µs) | 2.86 s (6.9 MB/s) | 7.36 s |

- The tree half costs about 3 µs per instance after deserialisation in Lune; Lune's `GetDescendants` builds a
  userdata per instance (inferred, not profiled). The Rust host walking `rbx_dom_weak` directly is expected to be cheaper; unmeasured.
- The sourcemap path parses one JSON file instead of the place; unmeasured, smaller.
- Developer cost: one review of the list, then optionally `check.knownRemotes`.

### 1.7 Least work for game developers

Nothing to enable: `lync check` and `lync build` run the creation-site scan with the scripts they already lex, and
the tree half whenever a sourcemap with non-scripts or `--place` is available. CI adds `--place game.rbxl` after
`rojo build`. Studio-only users get it from the plugin with no setup. To quiet known entries:
`check.knownRemotes = ["ReplicatedStorage.Remotes.LegacyShop"]`.

### 1.8 Options

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `check.foreignRemotes` | `"off"` \| `"warn"` \| `"error"` | — | — | `"warn"` | the tree walk, about 3 µs per instance in Lune after reading the place; `"off"` skips the walk and the manifest list (creation sites cost nothing extra: the lexing is shared) |
| `check.foreignBindables` | boolean | — | — | `false` | adds `BindableEvent` and `BindableFunction` entries (`network` 0); no extra walk |
| `check.knownRemotes` | array of instance paths | — | exact paths; `*` matches one path segment | `[]` | none; listed entries keep their manifest row and lose their Diagnostic |

## 2. U5b `dynamicAccess`, and how it and the reachability rule agree

### 2.1 What it is for

Three build products need a namespace to be *complete*, meaning every client use of a definition names it in the
text:
- inferred reachability (`unreachable`, `declared` 0; `v5-integrity.md` §3);
- the caller probe's per-definition source lists (§4 there: "skipped … for incomplete namespaces");
- weaving's closure (`codecs-in-scripts.md` §4.2).

A use that reaches a definition without naming it breaks all three. Missing one has a cost: an unmodified client
fires a definition the build inferred unreachable, and the server reports `unreachable` with no listed cause.
Over-reporting one has a cost too: inference is off for that namespace, and Lync loses the signal. `dynamicAccess`
is the build diagnostic that names each such use, so the developer sees why a namespace is incomplete and where.

### 2.2 One predicate, two outputs

**Agreement rule: a namespace is incomplete if and only if the scan reports at least one `dynamicAccess` in it.**
The reachability inference, the probe's source lists and weave closure read the same set of sites, computed once.
The diagnostic's severity setting never changes the set: `check.dynamicAccess = "off"` hides the Diagnostics, and
the namespace stays incomplete.

**The gap** (`codecs-in-scripts.md` §4.2, reasoned there; verified here). `v5-integrity.md` §3 (lines 77–79) makes a
namespace incomplete "only when its shard value is indexed with a non-literal expression". Iteration names no
definition and is not an index, so `for name, def in Net do def:fire(x) end` leaves the namespace complete, every
definition fired only that way is inferred unreachable, and an unmodified client produces `unreachable` with no
listed cause. The same holds for any value handed to code that iterates or indexes it under another name. The
fixture shows both (§2.4).

**Proposed text for `v5-integrity.md` §3**, replacing "A namespace is incomplete … are not escapes":

> A namespace is incomplete, and nothing is inferred for it, when the scan finds a dynamic access of one of its
> namespace values (each reported as `dynamicAccess`): (1) an index whose key is not one string literal;
> (2) iteration: the subject of a generic `for … in`, or the argument of `pairs`, `ipairs` or `next`; (3) a hand-off
> the scan cannot follow by name: an argument to a function with no definition in the scanned code, an entry of a
> table constructor without a name, or a store under a computed key. A namespace value is the result of
> `require` or `TS.import` of the client shard, and anything one is assigned to: a local, a field (`self.net = Net`
> makes every `.net` read a namespace value), the return value of a module (its requirers' results are namespace
> values) and the parameter at that position of every function of that name in the scanned code. Aliases, field
> stores, returns and arguments to such functions are therefore followed, not escapes.

The rule keeps the design's over-approximation: following is by name, not by scope, so it can only add namespace
values, never lose one. That direction can only add `dynamicAccess` sites: it turns inference off more often, and
never yields an `unreachable` an unmodified client can produce.

### 2.3 The rule in detail (token level, the core's lexer)

- **Scope:** exactly the reachability scan set: scripts in replicating containers, `Packages/`, every `LocalScript`
  and every `Script` with `RunContext = Client` wherever stored, and `check.clientRoots`. Server-only scripts are not
  scanned: a server loop over its own view (auto-wiring handlers) fires nothing a client sends. Verified: the
  fixture's `ServerScriptService.AutoWire` iterates the namespace and gets no finding.
- **Binding sources:** `require(E)` and `TS.import(script, …)` whose static path names the client shard. The prototype
  matches the last name or string in the argument against the shard's instance name (`client`); the shipped rule
  should match the full path suffix through the sourcemap or the place, because `client` is a common module name
  and another package's `client` module would become a namespace value (a false-positive source, §2.5).
- **Kinds** (`data.kind`): 1 index with a non-literal key (`Net[name]`, `alias[key]`, `self.net[which]`); 2 iteration
  (`in Net`, `in pairs(Net)`, `in next, Net`, `next(Net)`); 3 hand-off not followed (`Framework.register(Net)` with
  no `register` defined in scan, `{ Net }`, `t[k] = Net`).
- **Not dynamic:** `Net.chat`, `Net:method()`, `Net["chat"]` (one string literal), `local a = Net`, `local a: T = Net`,
  `Net :: any`, `typeof(Net)`, `print(Net)`; `assert`, `table.freeze` and `table.clone` pass the value through as an
  alias.
- **Fixed point:** following adds names, so the scan repeats until no name is added. It converged in 3 rounds on the
  fixture and 2 on the generated places (`check_fixture.out`, `scale.out`).

### 2.4 Verified on the fixture (`check_fixture.out`)

| Script | Case | Finding |
|---|---|---|
| `Client.Direct` | direct use, alias, typed alias, cast, `Net["chat"]`, `typeof(Net)` | none |
| `Client.Computed` | `Net[name]:fire(v)`; `local alias = Net; alias[key]:fire()` | kind 1 at 4:2 and 8:1 |
| `Client.Iterate` | `for … in Net`, `in pairs(Net)`, `in next, Net` | kind 2 at 2:18, 3:24, 4:24 (all missed by today's rule) |
| `Services.NetRef` → `Services.Hud` | a module `return Net`; its requirer stores it in `self.net`; `self.net.chat:fire()` and `self.net[which]:fire()` | kind 1 at 10:7 only |
| `Services.Router` | `wire(Net, …)` into a local function that does `ns[n]:fire()`; `Framework.register(Net)`; `{ Net }` | kind 1 at 4:3 (inside `wire`; today's rule counts it only if it follows the parameter), kind 3 at 8:20 and 9:20 (today: not escapes) |
| `Client.TsClient` | roblox-ts `TS.import(script, …, "client")`, then `Net[k]` | kind 1 at 4:1 |
| `ServerScriptService.AutoWire` | server loop over the namespace | none (not in scope) |

### 2.5 Output, and causes in an unmodified game

- **Diagnostic** `dynamicAccess`, range at the namespace token, `data = { namespace, kind, binding }`, severity from
  `check.dynamicAccess`; example:
  `warning[dynamicAccess]: Net[name] indexes namespace arena with a computed key; nothing is inferred for arena`.
- **Manifest**: per namespace `reachability = { status = "incomplete", sites = [{ uri, line, col, kind }] }`, or
  `"complete"`; the server shard gets only the status and the lists (or none).
- **Causes in an unmodified game** (every site is real code; whether it fires anything is what the build can't
  tell):
  - generic helpers that send by name: `send(name, value)` doing `Net[name]:fire(value)`;
  - client loops that connect every downstream event, for logging, say: kind 2 even though they fire nothing,
    because the scan doesn't read the loop body;
  - frameworks that register the namespace with package code the scan has no definition for (kind 3);
  - **over-approximation of following** (false positives in the sense of extra sites): a namespace passed to
    `X.new(Net)` binds the first parameter of *every* function named `new` in client code, so `config[key]` inside an
    unrelated `Foo.new(config)` reports kind 1. Token-level following has no scopes, so a shadowing local with the
    same name as a namespace value is followed too. The CLI with Luau's parser (`codecs-in-scripts.md` §2) can
    qualify callees by module (`M.new` where `M` is a resolved `require`) and remove most of these; the plugin keeps
    the token rule.
- **Residual misses** (causes of `unreachable` the predicate still can't see, to list in the fact's known causes):
  code outside the scan (as today); a shard obtained through a `require` whose argument the scan can't resolve
  (`require(modules[name])`) *and* then iterated or computed-indexed, since its result is never a namespace value.

### 2.6 Cost

Build only; zero at run time. The scan reuses the lexing that reachability and `rawRemote` already need, so its
marginal cost is the detector.

| Host | Lex only | Lex + detector | Source |
|---|---|---|---|
| Luau 0.742 CLI, interpreted (`-O2`) | 16.5–17.5 MB/s | 11.0–12.3 MB/s | `bench_scan.out`, 217 real files, 1.65 MB, best of 5, 3 runs |
| Luau 0.742 CLI, native (`--codegen`) | 22.6–28.2 MB/s | 19.4–20.1 MB/s | same |
| Lune 0.11.0 inside `check.luau` | — | 14.3 MB/s (1.4 MB), 12.8 MB/s (7.4 MB), 6.9 MB/s (19.8 MB) | `scale.out` |

So the detector adds about 40–55 ms per 1.65 MB interpreted, about 30–50 % of the lexing it shares. Each extra round
re-walks the tokens (2–3 rounds measured). A Studio plugin runs the same Luau; its speed there is unmeasured.

### 2.7 Least work, and options

Nothing to enable: it runs whenever `check.reachability` is true or weaving runs. A developer who wants inference
for a namespace replaces each reported site with named access (`Net.chat`), or adds a definition the scan can
follow; the Diagnostic names the line. There is no per-site suppression comment. Suppressing a site would bring back
exactly the `unreachable` false positive the predicate exists to prevent; if the developer prefers no inference, the
existing `check.reachability = false` already says so.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `check.dynamicAccess` | `"off"` \| `"warn"` \| `"error"` | — | — | `"warn"` | none beyond the shared scan; severity of the Diagnostics only, never whether the namespace is incomplete |

## 3. U6a Shard drift: what is hashed, the checks, where they run

### 3.1 Why only a build check can see it

A hand edit to a shard changes behaviour without changing any identity the runtime compares. If someone edits a
range in the client shard's encoder, the client then writes bytes the server's decoder reads differently. The
server reports `malformed`, or delivers wrong values when the edit keeps the frame canonical. `HELLO` still
matches, because the seed and schema-hash constants were not touched. The runtime cannot catch this:
- game code cannot read `Source` (capability `PluginOrOpenCloud`, verified in CSB §1.4 and `security-tooling.md` §1);
- `Script:GetHash` is LocalUserSecurity (verified, `security-tooling.md` §1);
- no engine API hashes a running script.

So drift is caught where sources are readable: the CLI over files or a place, and the Studio plugin.

### 3.2 What is hashed, and what is not

**The shard digest.** SHA-256 over every byte of the shard file after its first line, with CRLF normalised to LF
first. Line 1 is a comment that mirrors the shard's identity and carries the digest:

```
-- Lync 5.0.0 | arena | client | build 3735928559 | schema 0123456789abcdef | code 9f2c…(64 hex)
```

Line 1 is excluded only because it holds the digest. The identity the runtime reads lives in the body as code and
is therefore covered: generator version, build seed (or M1's `buildId`), seed-0 schema hash, schema path,
namespace. Verified (`drift.out`): editing only line 1 is not detected, and that is acceptable. The pair check and
`staleShard` read the body's constants, never the comment. A namespace split into parts (`maxShardBytes`, CSB §2.1)
has one digest per part file.

| Hashed (in the digest) | Not hashed |
|---|---|
| the shipped client or server shard body: rotated field order and tag constants, identity constants, generator version, error strings | line 1 |
| | `.d.ts`: types change no behaviour |
| | `manifest.json`, `report.md` |
| | M1's private `rotationSeed`: it is in the manifest only and reaches the digest only through the code it shapes, which ships anyway |
| | `weaveHash`: the identity of the woven site table (`codecs-in-scripts.md` §7.3); woven game scripts are not shards. If the weaver rewrites the built shard (`weave.dropClosed`), it is a Lync writer and rewrites line 1 with the new digest |

**"Core hash", two meanings.** CSB's manifest field `"core": "sha256:…"` (CSB §4.1, §4.4) is the digest of the
*compiler core* that generated the build (generator identity). The brief for this unit defines the core hash as
the digest of the *client shard's generated code*. They serve different ends. The manifest keeps the generator
identity (`lync` version plus core digest) for reproducibility. Each shard keeps its own code digest for drift.
§4 treats the second as a `HELLO` field.

**Build id against rotation seed** (`generation-methods.md` M1). With M1, the public `buildId` (u32, drawn per run)
takes the seed's place in the shard body, line 1, the manifest and `HELLO`. The pair check (§3.3) compares
`buildId`. `rotationSeed` (64 bits, OS entropy) is written only to `manifest.json`. Without M1, read "build seed"
for `buildId` throughout.

### 3.3 The checks

| Code | Exact trigger | Evidence | Severity | Known causes with no tampering |
|---|---|---|---|---|
| `staleShard` (exists, `v5.md` §3.2) | the shard's seed-0 schema hash differs from the live schema's | `side` | error (fixed) | schema edited and not rebuilt |
| `editedShard` (new) | the recomputed digest differs from the digest on line 1 | `side`, `part` | `lync check`: error (fixed); `lync build`: reported as a warning naming the file, then the shard is overwritten | a hand edit; a formatter run over generated files (StyLua, editor format-on-save); a darklua pass over shards (CSB §1.5 allows one); a merge resolved by hand; Team Create "Merge From Server" on a drafted shard. Not a CRLF checkout (normalised; verified) |
| `unpairedShard` (new) | a namespace's client and server shards carry different build seeds (`buildId`), generator versions or schema hashes in their bodies | `clientBuild`, `serverBuild`, `generatorDiffers` (0/1) | error (fixed) | one side committed and not the other (Team Create Drafts mode commits per script, documented `projects/collaboration.md` "Commit drafts"); a partial checkout; a plugin write refused for one script (Script Injection denial, `UpdateSourceAsync` rejection); a stale copy of a shard left in a place Rojo only partly manages |
| `staleManifest` (new) | `manifest.json` records digests or a build seed other than the shards' | `side` | warning (fixed) | the manifest not kept with the shards (not committed, or from another CI run). It matters to `lync replay`, the inspector and `lync diff`, and under M1 the rotation seed exists only there |

**Regenerate and compare (CI).** When the manifest is present, `lync check` can also regenerate every shard at the
recorded seed with the same generator and compare digests. This is CSB §4.1's reproducibility rule. It catches an
edit that also rewrote line 1, which takes intent, and reports it as `editedShard` with `regenerated` 1. Its cost is
one generation run (planner and codegen, measured in milestone 3).

**Verified** (`drift.luau` → `drift.out`, over the woven `Weapon` sample from `probes/codecs-in-scripts/`; for brevity the
probe reads the pair's identity from line 1, where the shipped check reads the body's constants):

| Case | Result |
|---|---|
| as built | clean |
| CRLF checkout (`core.autocrlf`) | clean (normalised) |
| one constant edited (`255` → `256`) | `editedShard client` |
| reformatted (tabs to 4 spaces) | `editedShard client` |
| server shard from another run | `unpairedShard client build 3735928559, server build 42` |
| line 1 edited only | clean (see §3.2) |

### 3.4 Where it runs; Studio; the no-build path

- **CLI over files:** `lync check` reads the shard paths from `lync.toml` and the manifest, and `lync build` checks
  before it overwrites. `lync check --place game.rbxl` finds shards by instance path through rbx-dom. That also catches
  copies outside Rojo's management.
- **Studio plugin:** it reads `Source` (plugins may) and hashes with
  `EncodingService:ComputeStringHash(source, Enum.HashAlgorithm.Sha256)`. That method has security None and is
  thread-safe (verified, dump), and it returns the binary digest as a string (documented,
  `EncodingService.yaml`), which the plugin hex-encodes. The plugin runs the check on open, on
  `TextDocumentDidChange` of a shard and in "Prepare release". Results show as script-analysis Diagnostics on the
  shard.
- **Studio play tests:** the checks are edit-time, so play tests run what the place holds. `staleShard` still throws
  at `require` in Studio (`v5.md` §3.2). `editedShard` has no run-time counterpart (§3.1). An `unpairedShard`
  with differing seeds shows at run time as `schemaMismatch` (`seedDiffers` 1) on every join.
- **No-build path:** no shards and no manifest, so nothing to check. `lync check` on a project with no outputs reports
  none of these codes.

### 3.5 Cost

Zero at run time and on the wire. Build: SHA-256 through Lune's `serde.hash` (Rust) runs at 0.9–1.4 GB/s, about
0.04 ms per 64 KB shard and 4.5 ms per 6.4 MB (`drift.out`). CRLF normalisation by `string.gsub` costs 0.6–0.9 ms per
64 KB; the Rust host normalises in its own code, unmeasured and cheaper. `EncodingService` speed in Studio is
unmeasured. Developer: never edit shards, and keep generated folders out of formatters (`.styluaignore`, darklua's
input set).

**Options:** none. The four codes have fixed severities, like `staleShard` (`v5-tooling.md` §3: "Declaration and
`staleShard` codes are errors"). Each is a mismatch between artefacts of one build. No setting makes one correct.

## 4. U6b A code hash in `HELLO`

### 4.1 The mechanism, if built

- **Field:** `codeHash` u32 in `HELLO`, after the schema hash. It is the low 32 bits of the client shard's digest
  (§3.2), embedded by the build as a constant in the shard body; the runtime path sends 0.
- **Self-reference:** the digest cannot cover a constant that holds it, so with this field lines 1–2 are excluded
  (line 2 is `local CODE = 0x…`).
- **Server side:** the server shard carries the value it expects.
- **Wire:** +32 bits per `HELLO`, so 4 B per namespace per connection (3 namespaces: 12 B per join). Protocol
  version 2; golden vector G7 (`HELLO`, `v5.md` §4.10) changes.
- **Runtime cost:** one constant read on the client and one compare per `HELLO` on the server: nothing measurable.

### 4.2 What it would observe

| Case | Default `build.seed = "release"` | Fixed seed (an integer; 0 in tests, or pinned for stable diffs) | Seen without it |
|---|---|---|---|
| client and server shards in one place from different runs | refused already: `schemaMismatch`, `seedDiffers` 1 (equal seeds by chance: 2^−32) | differs when the two outputs differ (another generator version, other codegen options) | `unpairedShard` at build (§3.3) |
| a hand-edited client shard | **not seen**: the edit leaves the constant alone | not seen | `editedShard` at build |
| a client running an older place version | impossible for an unmodified client: a server runs one place version until it shuts down or is restarted (documented, `projects/update-games.md`), and its clients get their scripts from it by replication (inferred; no doc states it in one sentence) | same | — |
| runtime-path client against a generated server | refused already (`seedDiffers`: the runtime path runs at seed 0) | at seed 0: 0 against the server's value, although the two paths share the wire by design (`v5.md` §3.2) | — |
| a modified client | sends any value: the constant is in its own memory and in every captured `HELLO` | same | — |

So, in the default configuration, an unmodified client's `codeHash` always equals the server's expectation. The
one exception is a place that itself holds unpaired shards, and then the seeds differ and the client is already
refused. With a fixed seed, the field separates outputs of different generators. Their wire is the same unless the
planner's layout changed. Layout is what the protocol version exists for: `v5.md` §4.9 versions every "protocol
constant" (one that "changes bytes or what a decoder accepts") by the version in `HELLO`. The design should say
explicitly that a planner change which alters any frame for some (schema, seed) is such a change, and that the
golden set enforces it. Then a code hash adds no wire safety.

Against a modified client it prices almost nothing: only a tool that carries its own copy of another build's client
shard under a fixed seed, or one that drives Lync's runtime path against a seed-0 generated game. A tool that
requires the game's own shard sends the right value, and any tool can replay a captured one; the value is not a
secret.

### 4.3 The server fact, if built

It must not be a `schemaMismatch` reason. That fact's action is `MISMATCH`, which drops sends (`v5.md` §4.6, §7.3), and
a refusal would break the seed-0 interop the design promises between the runtime path and generated shards. It would
also refuse clients whose wire is compatible. It would be a fact of its own, delivered:

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `codeDiffers` | a `HELLO` that matches version, seed and schema hash, whose `codeHash` differs from the server shard's expected value | none (welcomed) | `noShard` (1 when the client sent 0), `reported` (the client-stated u32, as `hashLow` is in `schemaMismatch`) | the place holds unpaired client and server shards built at one fixed seed (the build reports `unpairedShard`); client game code using `Lync.client(schema)` instead of the shard in a generated game (`noShard` 1) |

Compare `schemaMismatch` (`v5.md` §7.3, line 1087): `version`, `seedDiffers`, `hashLow`, `hashHigh`, `unknownName`.
All of those mean "the wire may differ". `codeDiffers` would mean "the wire is the same, and the code is not".

### 4.4 Studio play tests and the no-build path

- **Studio play tests:** server and client run copies of one edit DataModel, so `codeHash` always matches. The one
  exception is a place holding unpaired shards, which the plugin already reports at edit time (§3.4). The field
  would only repeat the build diagnostic.
- **No-build path:** the client sends 0.
  - A runtime-path server has no shard and no expectation, so it ignores the field.
  - A generated server at seed 0 sees `noShard` 1.
  - A generated server with a release seed has already refused the client (`seedDiffers`).

### 4.5 Contrast with `weaveHash`

`weaveHash` (`codecs-in-scripts.md` §7.3) is a different kind of field. The woven site table assigns wire ids, so
two different site tables decode the same frame differently. It therefore belongs among the refusing checks
(`schemaMismatch` evidence `weaveDiffers`), and it is required before any site id ships. `codeHash` changes no byte
a decoder reads.

**Options:** none in either case. If the field is built it is protocol, not a knob (`v5.md` §4.9).

## Implications

1. Adopt `foreignRemotes` as an inventory with exact evidence (`origin`, `network`, `replicates`), default `"warn"`, with `check.knownRemotes` so only new entry points warn (§1.2, §1.4, §1.8).
2. Own exactly two instances, `ReplicatedStorage.Lync.Reliable` and `.Unreliable` of their two classes, and skip Lync's package by its runtime header; list everything else (§1.2).
3. Leave bindables out by default (`check.foreignBindables = false`): they are not network entry points (§1.2).
4. In the CLI, prefer `--place` after `rojo build` in CI; read `rojo sourcemap --include-non-scripts` when there is no place, and say in the docs that a scripts-only sourcemap hides remotes (§1.3, `rojo_sourcemap.out`).
5. Report `Instance.new(<non-literal>)` as its own origin (3) rather than guessing classes; Cmdr is the real example (§1.2, `real_creation.out`).
6. Verify in Studio that a plugin can walk the play-test server DataModel; if it can, add the play-test inventory, the only view of helper-made remotes (§1.3).
7. Make `dynamicAccess` and incompleteness one predicate, computed once, read by reachability, the caller probe's source lists and weave closure (§2.2).
8. Replace `v5-integrity.md` §3's "only when … indexed with a non-literal expression … not escapes" with the §2.2 text: index, iteration, unfollowed hand-off; follow aliases, fields, returns and same-named function parameters (§2.2, §2.4).
9. Scan only the reachability scan set for `dynamicAccess`; server loops over their own view are out of scope (§2.3).
10. Match binding sources by the shard's full path suffix, not its leaf name (`client` is common), and qualify callees by module where the CLI has the parser (§2.3, §2.5).
11. No per-site suppression for `dynamicAccess`; `check.dynamicAccess` sets severity only, and `check.reachability = false` remains the opt-out (§2.7).
12. Add `editedShard`, `unpairedShard` and `staleManifest` with fixed severities, using a line-1 SHA-256 self-digest over LF-normalised bytes, and keep identity constants in the body (§3.2, §3.3, `drift.out`).
13. Keep the generator identity (CSB's "core" digest) in the manifest for reproducibility, and per-shard code digests for drift; don't call both "core hash" (§3.2).
14. Under M1, the pair check compares the public `buildId`; `rotationSeed` stays in the manifest only, so `staleManifest` matters for `lync replay` (§3.2, §3.3).
15. Don't put a code hash in `HELLO` v1; instead state in `v5.md` §4.9 that any planner change altering a frame for some (schema, seed) bumps the protocol version, enforced by the golden set (§4.2).
16. If a code hash is added anyway, make it the non-refusing fact `codeDiffers`, never a `schemaMismatch` reason; keep refusals for `weaveHash`, which changes decoding (§4.3, §4.5).
17. Add to `unreachable`'s known causes the residual miss: a shard reached through an unresolved `require` and then iterated or indexed (§2.5).
