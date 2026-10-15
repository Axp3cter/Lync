# Lync v5: compiler outputs and tools (milestones 3 and 6)

Draft 3, 2026-10-15. Part of the v5 design (`v5.md`). Milestone 3 builds §1–§4 on the Lune host; milestone 6 the
Rust/mlua host, `diff`, `replay`, the plugin's inspector and the profiler adapter.

## 1. Outputs

For a given schema, build seed and planner version, the compiler always produces the same files
`[client-security-build §2.2]`:

| Output | Format | Consumer |
|---|---|---|
| client shard, server shard per namespace | Luau, readable, MIT header; each definition commented with its schema line | the game |
| type declarations | `.d.ts`; JSDoc names each definition's schema line | roblox-ts |
| `manifest.json` | JSON: definitions with `schemaPath:line`, seed, hashes, ids, worst-case sizes, reachability | CI, the server shard, the inspector, `lync explain` |
| `report.md` | Markdown rendered from the manifest | developers |

There is no debug map: the planner reproduces any layout from schema, build seed and server permutation seed, which
the inspector and `lync replay` take from the shard or a captured `HELLO` and `WELCOME`.

## 2. `lync.toml`

TOML with a published JSON Schema, read the same way by the CLI and the plugin `[client-security-build §5]`. Studio-only
projects keep the same text in a plugin-managed `StringValue` in ServerStorage.

```toml
#:schema https://lync.dev/schema/lync.toml.json
format = 1

[build]
seed = 0                        # integer 0–2^32−1, or "release" for a fresh seed per CI release (v5-integrity.md §2)

[[namespace]]
schema = "src/shared/Net/schema.luau"
client = "src/shared/Net/client"
server = "src/server/Net"
dts = "types/net.d.ts"          # optional

[rotate]
fields = true                   # effective only with a nonzero seed
tag = true

[types]
solver = "old"                  # "old" | "new": with "new", runtime-path use is not reported as solverOff

[check]
rawRemotes = "warn"             # "off" | "warn" | "error": client code touching RemoteEvents directly
reachability = true             # v5-integrity.md §3

[output]
manifest = "build/lync-manifest.json"
report = "build/lync-report.md"
```

The vendored TOML parser uses no `const`, whose availability in Studio scripts is unverified.

## 3. Build diagnostics

- **One structure, the LSP `Diagnostic`** `[diagnostics §6.1]`: `range`, `severity`, `code` (the registry code of
  `v5.md` §7.1), `codeDescription.href` (`https://lync.dev/codes/<code>`), `message`, `source = "lync"`,
  `relatedInformation`, and `data` holding the value path. Positions come from the line each schema constructor
  records; columns by searching that line for the option key or codec name.
- **Renderings**, `--format`:
  - `human` (default): `error[unknownOption]: arena.chat has no option "rtae"`, the `-->` location, the source line
    with a caret, `= help:` when there is exactly one fix, and `run lync explain <code>` once per distinct code;
  - `json`: JSON Lines, one Diagnostic plus `uri` per line (it streams under `watch`);
  - `github`: `::error file=…,line=…,col=…,title=lync <code>::<message>`, plus the human report in
    `$GITHUB_STEP_SUMMARY`, since Actions shows at most 10 annotations per step.
  SARIF waits until a user asks.
- **Severity by effect:** `error` writes no outputs; `warning` writes them. Declaration and `staleShard` codes are
  errors; `[check]` entries set the rest by name.
- **Exit codes:** 0 no errors; 1 errors (including stale shards in `check`); 2 usage or configuration
  (`configInvalid`); 3 internal error, printed with a request to file an issue.

## 4. Hosts

- **CLI:** `lync build`, `lync watch`, `lync check`, `lync explain <code>` (milestone 3); `lync diff <old> <new>`
  (breaking wire changes) and `lync replay <capture>` (milestone 6). `watch` is in milestone 3 because, outside
  Studio-only projects, it is the only regenerate-on-edit path. The shipped host is a Rust binary on mlua, installed
  with rokit; Lune is the fallback and first host; Lute 1.0 is not ready `[client-security-build §1.2]`.
- **Studio plugin** (milestone 6): the same diagnostics through
  `ScriptEditorService:RegisterScriptAnalysisCallback`, with `code` and `href`, plus `staleShard` on shards; the
  network inspector; a "Prepare release" action that writes a fresh build seed. It regenerates on schema edit only
  when the configuration lives in its `StringValue`; with a filesystem `lync.toml`, `lync watch` is the one writer.
  No plugin can hook publish or save `[client-security-build §1.4]`.
- **CI:** `lync check --format github` fails on stale shards, errors and type tests; release builds use
  `seed = "release"` and publish through Open Cloud `[client-security-build §1.8]`.

## 5. Inspector and profiler (milestone 6)

- **Studio inspector:** bytes per definition and per player from `Lync.counters()` polled at 4 Hz, facts from the
  observer, live decoded frames, capture and replay.
- **PacketProfiler adapter:** registers Lync as a traffic layer `[landscape §5]`.
- **MicroProfiler labels** with `profile = true` (`v5.md` §7.5).

## 6. Repo tooling

Never shipped: StyLua and selene with a Lync `std` file; Moonwave; Markdown guides and the code registry
`docs/codes/`; GitHub Actions; Python for simulations and capture analysis.
