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

- [ ] 0. Bottom line
- [x] 1. U5a `foreignRemotes`
- [ ] 2. U5b `dynamicAccess`, and how it and the reachability rule agree
- [ ] 3. U6a Shard drift: what is hashed, the checks, where they run
- [ ] 4. U6b A code hash in `HELLO`
- [ ] Implications

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
| Studio plugin, play test | the same walk in the play-test server DataModel once Lync has started | run-time creations by any route: non-literal `Instance.new`, `:Clone()`, legacy chat's `DefaultChatSystemChatEvents` | instances created later than the walk; services the plugin cannot read | **unverified**: that a plugin's code runs in the play-test server DataModel and can walk it there |

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
  admin systems (reported: they create their remotes at run time);
- the legacy Lua chat system's forked runner, which creates `DefaultChatSystemChatEvents` and its remotes at run
  time (reported; TextChatService needs none);
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
  userdata per instance. The Rust host walking `rbx_dom_weak` directly is expected to be cheaper; unmeasured.
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
