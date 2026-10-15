# Security tooling: what each surface can do for Lync

Researcher findings, 2026-10-15. This is a catalogue of what each platform and tool surface can do for Lync's
security, so the next design pass builds defences on real capabilities. It feeds `v5-integrity.md`,
`v5-tooling.md` and the refusal log in `v5-changes.md`.

**Labels.** **verified**: I read the source, queried the API dump, or ran the luau instruments. **documented**:
official docs say so. **reported**: a third party says so. **unverified**: my inference.

**Sources** (exact versions and paths: `.data/docs/probes/security-tooling/sources.md`):
- the API dump, Roblox 0.741.19 (cited "dump");
- creator-docs at commit efe8741 (2026-10-15), cited by file;
- the Open Cloud OpenAPI file from the same commit (cited "openapi");
- the reference projects in `.data/projects/`;
- crates.io and PyPI, read 2026-10-15;
- the potassium-api skill (v2.3.5, verified live 2026-07-31).

Rate limits are per minute unless stated otherwise.

---

## 0. Bottom line

1. **Five levers the drafts did not use:**
   - `ConfigService`: server-only values, pushed live with rollback.
   - `EncodingService`: native hashing and Zstd on both sides.
   - A full release pipeline through Open Cloud: publish, `restartServers`, Configs, secrets, Luau Execution.
   - The documented `RemoteEvent` queue: messages wait until a handler connects.
   - Execution coverage (`ScriptContext:EnableCoverage`) as a dynamic reachability check.
2. **Unchanged limits:**
   - No plugin can hook publish or save. Re-checked: every such member is RobloxScriptSecurity.
   - Game scripts cannot read `Source` (capability `PluginOrOpenCloud`) or call `Script:GetHash` (LocalUserSecurity).
   - Clients have no compiler.
3. **Codecs in game scripts can be built as a post-build transform.**
   - It rewrites the built place or the built `.luau` files, never the developer's files.
   - It needs a call-site scan over the Luau syntax tree and a line map back to the developer's code.
   - The typed shard stays the API that roblox-ts and luau-lsp see (§10).
   - Its isolation gain is real. Its speed gain is small over straight-line shards.
4. **Every client measure is judged against the capability classes in `client-security.md` §1.2.** §9 pairs
   each class with the Lync defence that must survive it: reading the client's own state, hooking, firing its own
   signals, packet-level hooks, and identity control.

---

## 1. Roblox engine, server side

| API | Signature / context | Limits | Enables | Cost | Claim |
|---|---|---|---|---|---|
| `RemoteEvent:FireServer/FireClient/FireAllClients`, `.OnServerEvent(player, …)` | capability `RemoteEvent`, security None | ≈500 client→server requests/s per client, shared by every `RemoteEvent`. Excess is processed later, in order, not dropped. Order holds across instances. **A message with no handler connected is queued, in order, until one connects**; the queue has count and memory limits, past which messages are discarded with a `Remote event invocation` error | the reliable lane and its tag. The queue answers v5.md §10's open question: a `WELCOME` sent before the client's listener connects is queued, not lost | per-call engine overhead unmeasured | documented (RemoteEvent.yaml; remote.md, "Delivery guarantees") |
| `UnreliableRemoteEvent:FireServer/FireClient/FireAllClients` | as above | payloads over 1000 B are dropped (Studio logs the overage). No delivery or order guarantee, and no ordering with `RemoteEvent`. **Excess over the throttle is dropped**, and **a message with no handler is discarded** | the unreliable lane; the replay window | as above | documented (UnreliableRemoteEvent.yaml; remote.md) |
| remote payload compression | "encode and compress certain object types, such as buffers" | codec, threshold and level undocumented | — (why v5.md §4.3 bit-packs) | — | documented (UnreliableRemoteEvent.yaml) |
| `Workspace:GetServerTimeNow(): double` | capability `Basic`, thread Safe | monotonic; rate within 0.6% of the local clock | state ticks; the clock beacon's reference | one call | documented (dump; Workspace.yaml) |
| `Player:GetNetworkPing(): float` | capability `Players`, Safe | round-trip "isolated network latency", with no deserialization or processing | the early-answer check | one call per server ask | documented (dump; Player.yaml) |
| `EncodingService:ComputeBufferHash(input: buffer, algorithm: HashAlgorithm): buffer`; `ComputeStringHash(string, algorithm): string` | security None, no capability, **thread Safe**, client and server | Blake2b, Blake3, Md5, Sha1, Sha256; "not for passwords"; **no key parameter** | the schema hash in native code. A native tag candidate: Blake3 or Blake2b over key ‖ message, which resist length extension (Sha256 needs HMAC framing) | native; cost on Roblox devices unmeasured | verified (dump); documented (EncodingService.yaml) |
| `EncodingService:CompressBuffer(input, CompressionAlgorithm.Zstd, level?)`, `DecompressBuffer`, `GetDecompressedBufferSize(...): int?` | security None, Safe | Zstd only, levels −7 to 22 | Lync can compress frame tails itself at a known level, instead of only leaning on the undocumented remote compressor. The remote compressor itself stays undocumented | CPU per level, unmeasured | verified (dump); documented |
| `EncodingService:Base64Encode/Base64Decode(buffer): buffer` | security None, Safe | — | capture and export encoding | native | verified (dump) |
| `LogService:Warn/Error/Info/Output/Log(message, context: Dictionary?)`, `GetLogger(name): Logger` | capability `Logging` | the `ServerMessageOut`/`ServerHttpResultOut` events and `RequestServerOutput` are RobloxScriptSecurity | console lines whose numbers go in `context`, keeping client bytes out of the text. **Whether the Error Report groups rows by template is unverified** (v5.md §10) | per call, unmeasured | verified (dump); documented (LogService.yaml) |
| `LogService:GetLogHistory(): Array` | capability `Logging` | 512 entries by default; entries `{message, messageType, timestamp, context?}` | the in-process inspector | — | documented |
| `LogService:GetLogHistoryAsync(user: User): Array` | capability `Logging`, Yields | **in the dump, not in the docs** | unknown; not designed on until documented | — | verified (dump); behaviour unverified |
| `ScriptContext.Error(message, stackTrace, script)` | capability `Logging`, security None | does not fire for watchdog timeouts | the native-report channel | — | documented (ScriptContext.yaml) |
| `ScriptContext:EnableCoverage(instance)`, `GetCoverageStats(): Array` | capability `PluginOrOpenCloud`, not game scripts | coverage must be enabled first; `GetHits()` returns per-line and per-function hit counts | dynamic reachability (§3, §4) | per run | verified (dump); documented |
| `Stats.DataSendKbps/DataReceiveKbps/HeartbeatTime/…`, `GetTotalMemoryUsageMb()` | security None, ReadSafe | per process, not per player | inspector views only, not a per-player fact | read | verified (dump) |
| `RunService.PostSimulation`, `PreSimulation`, `Heartbeat`; `IsServer`/`IsClient`/`IsStudio` (Safe); `IsEdit` (PluginSecurity) | capability `Basic` | — | the flush point and side selection | per frame | verified (dump) |
| `ConfigService:GetConfigAsync(): ConfigSnapshot`, `GetConfigForPlayerAsync(player)` | security None, Yields; **server only**, errors on a client | string/JSON values ≤100,000 chars; 100 conditions per game, 20 per key; publish reaches servers in about 15 s–1 min, or a 15-minute gradual rollout | **server-only integrity policy pushed live, with no client read**: thresholds, budgets, the caller-probe member, per-round values | one async fetch; snapshots don't auto-update (`UpdateAvailable`, `Refresh`, `GetValueChangedSignal`) | verified (dump); documented (ConfigService.yaml, production/configs.md) |
| `ConfigService:SetTestingValue/ClearTestingValue(key)` | security None | this server's lifetime only | testing integrity thresholds in Studio or one live server | — | documented |
| `HttpService:RequestAsync/GetAsync/PostAsync` | capability `Network`, Yields | 500 requests/min per server; Open Cloud endpoints use a separate 2,500/min per server; the `x-api-key` header must be a `Secret`; HTTPS only | exporting facts to the game's backend; calling Open Cloud from a server | network | documented (cloud-services/http-service.md) |
| `HttpService:GetSecret(key): Secret`; `Secret:AddPrefix/AddSuffix` | capability `Network`, Safe | live servers and collaborative testing only, not clients or local playtests; ≤1,024 chars; 500 secrets per game; usable in URL and headers only, never readable as a string | a backend credential the client never sees (for example, to sign exported facts on the backend). **Not usable as a key in Luau**, since its value can't be read | — | documented (cloud-services/secrets.md) |
| `MessagingService:PublishAsync(topic, message)`, `SubscribeAsync(topic, callback)` | capability `ServerCommunication`, Yields | message ≤1 KiB; topic ≤80 chars; send 600 + 240 × players per server per minute; receive per topic (40 + 80 × servers)/min; 20 + 8 × players subscriptions per server | sharing low-volume integrity state across servers (for example, a player's `desync` history) | per publish | documented (MessagingService.yaml; cloud/guides/usage-messaging.md) |
| `MemoryStoreService:GetHashMap/GetSortedMap/GetQueue(name)` | capability `DataStore` | memory 64 KB + 1.2 KB × users, game-wide; 1,000 + 120 × CCU request units/min; about 30,000 units/min per partition; per-key 5,000 write and 15,000 read units/min | short-lived cross-server counters of facts per player | request units | documented (cloud-services/memory-stores/index.md) |
| `DataStoreService:GetDataStore(name, scope?, options?)`, `GetRequestBudgetForRequestType(type)` | capability `DataStore` | per-request-type budgets | per-build key or seed records read at server start; per-player fact history across sessions | async | verified (dump) |
| `ServerScriptService`, `ServerStorage` | tag NotReplicated | never replicated | the server shard, the policy, decoy behaviours and canary maps never ship to clients | — | verified (dump) |
| `ReplicatedFirst`, `ReplicatedStorage` | services; `ReplicatedFirst:RemoveDefaultLoadingScreen` has security None | — | where the client shard and remotes go | — | verified (dump) |
| `PlayerGui` (tag PlayerReplicated), `PlayerScripts` (NotReplicated) | `PlayerGui` fills from `StarterGui` at first spawn and is reset on respawn when `StarterGui.ResetPlayerGuiOnSpawn` is true (per GUI: `LayerCollector.ResetOnSpawn`); with `CharacterAutoLoads = false` it waits for `LoadCharacterAsync`. The server can't access `PlayerScripts`, and server `Script`s don't run there | per-player instance | per-player variant delivery (refused: join-time dependency, `v5-changes.md`) | one instance per player | verified (dump); documented (PlayerGui.yaml, PlayerScripts.yaml) |
| `Script.Source`, `ModuleScript.Source` | capability `PluginOrOpenCloud` to read and write | game scripts can't read any source | — (rules out self-attestation from game code) | — | verified (dump) |
| `Script:GetHash(): string` | LocalUserSecurity | not callable by game scripts | — | — | verified (dump) |
| `ServerScriptService.LoadStringEnabled` | NotScriptable, NotReplicated | server only; clients have no compiler | — (no run-time code generation reaches a client) | — | verified (dump) |
| `InsertService:LoadAsset(assetId)`, `LoadAssetVersion(versionId)` | capability `LoadOwnedAsset`, Yields | the asset must be created or owned by the game's creator, shared by its owner, or owned by Roblox | loading a CI-uploaded model by id | async | documented (InsertService.yaml) |
| scripts inside a model loaded with `LoadAsset` | — | they run only once parented where scripts execute | a server-chosen shard delivered as a model | — | reported (devforum) |
| `AssetService:LoadAssetAsync(assetId)` | capability `LoadUnownedAsset` | returns a Model with `Sandboxed = true` and no script capabilities by default | — (not a code-delivery path) | — | documented (AssetService.yaml) |
| `Instance.Sandboxed`, `Instance.Capabilities` | capability `CapabilityControl` | — | limiting what loaded content may do | — | verified (dump) |

**What this makes possible (server side):**
- **Reliable control on the first frame.** The documented `RemoteEvent` queue means a server-first `WELCOME` is
  held until the client's listener connects, not lost. That removes v5.md §10's pending item and makes an
  unsolicited `WELCOME` (saving a join round trip) safe on the reliable lane. The queue's limits are undocumented,
  so one control frame fits; bulk data does not.
- **Live server-only policy through `ConfigService`.** Per-round or per-hour values (caller-probe member, beacon
  threshold, budgets) need no republish and are never sent to clients, so they leave nothing for a modified client
  to read.
- **Native hashing and compression through `EncodingService`.** It can serve as the schema-hash primitive. It is
  also a candidate tag primitive: a keyed prefix with Blake3 or Blake2b (the cost on devices must be measured
  against HalfSipHash). And it gives Lync its own Zstd path for byte-tail data, at a level Lync chooses.
- **Per-build keys in a DataStore, written by CI** (§4). Cross-server counters of facts go in MemoryStore or
  MessagingService, within the quotas above.
- **Secrets stay backend credentials.** They are not keys Luau can use.

---

## 2. Roblox engine, client side (an unmodified client)

What Lync's own client shard can observe about its own calls, on a client running the published build. Runs:
Luau source in `.data/projects/luau` built as `luau -O2` and `-O1`, interpreted (clients run no native code),
Intel Xeon 2.1 GHz, shared machine, best of 7 batches; probes and outputs in `.data/docs/probes/client-self-checks/`
(`info`, `cost`, `deopt`, `clockstep` as `.luau`/`.out`; `probe_members.py`/`.out`). Docs are
creator-docs at efe8741 (`reference/engine/libraries/debug.yaml`, `os.yaml`, `globals/RobloxGlobals.yaml`,
`LuaGlobals.yaml`, `classes/{ScriptContext,Players,BaseScript}.yaml`, `enums/RunContext.yaml`,
`scripting/capabilities.md`). Roblox devices are slower than this machine by an unmeasured factor. The last
clause of a row names the `client-security.md` §1.2 capability class (as named in §9) that changes the
observation on a modified client.

| API | Signature and context | Limits | What the client shard can learn about its own calls | Cost (interpreted) | Claim |
|---|---|---|---|---|---|
| `debug.info(level, options)`, `debug.info(thread, level, options)`, `debug.info(fn, options)` | library function, no security or capability tag; `options` holds each of `s l n a f` at most once (`"ss"` raises `invalid argument #2 to 'info' (duplicate option)`, `"x"` `(invalid option)`) | `s` is "the full name of the script the function is defined in" (docs); a C function gives `[C]` and line `-1`; a level past the stack's top returns nothing; a thread's stack ends at its base, so `fire` started by `coroutine.wrap` has no frame outside Lync, and one called through `pcall` sees `[C]` first. At `-O2` a helper inlined into its caller keeps its own `s` and `l` but reports the caller's `n` (`helper` at `-O1`, `outer` at `-O2`), so only `s` and `l` are stable between Studio and live; a multi-line call reports the line where it starts | the source and line of the first frame outside Lync (found by walking until `s` differs, never by a fixed level); `f` names the function at a level, so Lync can tell when its own dispatch is on the stack (a call made from inside a handler Lync is running). Modified client: *naming or hiding code and stack frames*; *hooking* (`newcclosure` frames read `[C]`) | `s` or `sl` at level 1–2: 43–61 ns; `slnf` 79–91 ns; `f` alone 29–35 ns; `debug.info(fn, "s")` 61–68 ns. Walk to the first outside frame: 173–178 ns through 1 Lync frame, 379–385 through 3, 566–589 through 5; with the lookup in a listed-source table, 189–196 ns | verified (`info.out`, `cost.out`); documented (debug.yaml) |
| `debug.traceback(message?, level?)`, `debug.traceback(thread, message?, level?)` | library function, no tag | "a string of undefined format"; "you should **not** parse the return value for specific information such as script names or line numbers" (docs) | nothing Lync can rely on beyond `debug.info`; fact evidence is numbers only (v5.md §7.3), so a stack text could not be carried anyway. Modified client: *naming or hiding code and stack frames* | 219–264 ns at depth 3 | verified (`cost.out`); documented |
| `script` (global) | `LuaSourceContainer`: "the script object that is executing the code"; "not available when executing code from Roblox Studio's command bar" | inside Lync's client shard it is the shard's own ModuleScript, not the caller | only Lync's own instance and location (for example, that the shard sits where the build placed it). Nothing about who called `fire` | a global read | documented (RobloxGlobals.yaml) |
| `BaseScript.RunContext: Enum.RunContext` | `Legacy` 0, `Server` 1, `Client` 2, `Plugin` 3; read security None, ReadSafe. Write: `PluginSecurity` in the dump, `None` on the docs page | only `Script` uses it; a `LocalScript` always runs on the client; a ModuleScript has no `RunContext` | about a caller only if Lync holds the caller's instance, and `debug.info` returns a string. Turning the string back into an instance needs a path lookup (fragile: names may contain dots) or `getfenv(level).script` (next row). At run time it adds nothing to the build's list, whose scan already covers every `Script` with `RunContext = Client` (`v5-integrity.md` §3) | one Instance property read; unmeasured | verified (dump); documented (BaseScript.yaml, RunContext.yaml). Write security: the sources disagree; the dump is read from the engine, so I take `PluginSecurity` |
| `getfenv(level \| fn)` | Lua global, tagged **Deprecated**: "disables script optimizations" | clears the safe-environment flag of the environment it returns (`VM/src/lbaselib.cpp` lines 135 and 144, `lua_setsafeenv(L, -1, false)`), so a `getfenv(2)` made by Lync deoptimises the **caller's** environment for the rest of its life. Naming `getfenv` anywhere in a module turns off that module's imports and fast calls at compile time. The Creator Store bars it (`client-security-build.md` §6.1) | `getfenv(level).script` is the only route from a stack level to the caller's script instance | the call: 39–56 ns. Afterwards an encoder step in the calling chunk (two `bit32` calls, a buffer write and read, `math.floor`) went from 43–52 ns to 168–194 ns, about 3.5–4× | verified (`deopt.out`; source); documented (LuaGlobals.yaml) |
| `pcall` around a read of a member whose security or capability game scripts lack | identity: 32 property reads with read security above None on services every client has (dump): 21 `RobloxScriptSecurity` (for example `RunService.ClientGitHash`, ReadOnly, capability `Basic`; `Workspace.AuthorityMode`), 3 `LocalUserSecurity` (`ScriptContext.ScriptsDisabled`), 3 `PluginSecurity` (`RunService.RunState`), 5 `RobloxSecurity` + NotScriptable (unusable). Capability: members such as `ScriptContext:EnableCoverage` (capability `PluginOrOpenCloud`); a missing capability raises "The current thread cannot call 'GetSecret' (lacking capability Network)" (docs) | game scripts run at identity 2, executor threads at 8 by default (`client-security.md` §2.1, reported/documented). A `LocalUserSecurity` member also succeeds from the Studio command bar, so a `RobloxScriptSecurity` member avoids that Studio cause, if the command bar runs below it (unverified). Which capabilities executor threads hold: unverified. Whether a caught failure writes a client log line: unverified (`v5-integrity.md` §4) | whether the thread that called `fire` has more identity or capability than a game script. Modified client: *thread identity control* | a `pcall` whose callee returns: 25–29 ns; one that raises: 2.0 µs for a Lua `error(string, 0)`, 3.3–3.6 µs for a C argument error (error-string construction dominates). The engine's own failure path is unmeasured | verified (dump, `probe_members.out`; `cost.out`); documented (capabilities.md) |
| `os.clock(): number` | library function | "elapsed time in seconds since an arbitrary baseline with sub-microsecond precision", unaffected by system clock adjustments (docs). It compiles to `GETIMPORT` + call, not a fast call (`probes/security-tooling/sources.md`), so a hook of it is seen | durations of Lync's own work on this client (from `fire` to the flush, or a tag computation). It cannot attest a hook: a Lua forwarding hook adds about 9 ns (`client-security.md` §2.2), below one clock read. Modified client: *clock and frame-rate control*; *hooking* | one read 45–55 ns; consecutive reads always differed, by at least 44–48 ns, which is the read's own cost, so the step is finer than that (Linux; devices unmeasured) | verified (`cost.out`, `clockstep.out`: 0 repeats in 10^6 reads); documented (os.yaml) |
| `tick(): number` | Roblox global | seconds since the Unix epoch on the device clock; "can be off by up to one second and returns inconsistent results across time zones and operating systems" (docs) | nothing Lync relies on; the clock beacon reads `GetServerTimeNow` (`v5-integrity.md` §6). Modified client: *clock and frame-rate control* | unmeasured (not in the CLI) | documented (RobloxGlobals.yaml) |
| `Players.LocalPlayer: Player` | read security None, capability `Players`, ReadSafe, ReadOnly, NotReplicated | "only defined for LocalScripts and ModuleScripts required by them"; nil on the server (docs). When it is first non-nil for code in `ReplicatedFirst`: unverified | its own `Player`, whose `Name` the source check's clone mapping needs: a cloned starter script's full name sits under `Players.<Name>.PlayerScripts` or `.PlayerGui`, and a character script under the character model, named after the player by default (inferred from "full name"). Game code that renames the character breaks that mapping | one property read; read once and kept | verified (dump); documented (Players.yaml) |
| `ScriptContext.Error(message, stackTrace, script)` | event, security None, capability `Logging`. Every other `ScriptContext` member is `RobloxScriptSecurity`, `PluginSecurity`, `LocalUserSecurity` or capability `PluginOrOpenCloud`; `ErrorDetailed`, whose `securityLevel` field would name the erroring thread's identity, is `RobloxScriptSecurity` | fires when a thread ends with an unhandled error; not for watchdog timeouts (docs); `stackTrace` is formatted text. Firing for client scripts on a client: reported practice, not documented | Lync's own uncaught errors, with the script that ran. Nothing about a caller of `fire`, which does not error. Modified client: *naming or hiding code and stack frames* (hidden frames are absent from `stackTrace`); *firing or disabling signal connections* (Lync's connection can be disabled) | one connection; work per error | verified (dump); documented (ScriptContext.yaml) |
| `RunService:IsStudio(): bool` | capability `Basic`, thread Safe | — | whether a known Studio-only cause applies (the command bar at a higher identity, `v5-integrity.md` §10 `reportedIdentity`); a client can't use it to say anything about live players | one call | verified (dump) |

**What this makes possible (client side, about Lync's own calls):**
- **The source check as specified** (`v5-integrity.md` §4): a walk by `s` to the first frame outside Lync,
  then one table lookup, about 0.19 µs per probed call through one Lync frame, 0.6 µs through five. The walk
  must compare sources, not count levels, because inlining differs between `-O1` and `-O2`.
- **A finer list, if wanted:** `l` is stable between `-O1` and `-O2`, so the build could list (source, line)
  pairs. Its false facts are calls written on a line the scan doesn't tie to the definition (an alias such as
  `local x = Net.x` then `x:fire()` on another line), so it needs the type-aware scan (§7).
- **Known false facts of any source check, from the probes:** `fire` passed straight to a scheduler or
  `coroutine.wrap` (no outside frame), or called through `pcall` or another C function (`[C]` first). Lync can
  skip `[C]` frames and report "no outside frame" as its own count rather than as unlisted.
- **The identity probe** with a `RobloxScriptSecurity` read such as `RunService.ClientGitHash`, which also keeps
  the command bar out if the command bar runs below that level (to confirm in Studio).
- **The clone mapping** needs `Players.LocalPlayer.Name`, read once.
- **Nothing about the caller's instance** without `getfenv`, whose cost lands on the game's script (3.5–4× on an
  encoder step). Lync never calls it.
- **Clocks** time Lync's own work only. They attest nothing about hooks.
- **`ScriptContext.Error`** reports Lync's own uncaught errors, which Lync's native reports already surface.

---

## 3. Studio plugin API

| API | Signature / context | Limits | Enables | Cost | Claim |
|---|---|---|---|---|---|
| `ScriptEditorService:UpdateSourceAsync(script, callback)` | PluginSecurity, Yields | the callback receives the old source, may not yield, and returns nil to cancel; a stale update is rejected and the callback re-run | writing generated shards (or build copies, §10) safely | one edit | verified (dump); documented |
| `ScriptEditorService:RegisterScriptAnalysisCallback(name, priority, fn)`, `DeregisterScriptAnalysisCallback` | PluginSecurity | editor-time only | Lync's build diagnostics shown in Studio | — | verified (dump) |
| `ScriptEditorService:GetEditorSource`, `FindScriptDocument`, `GetScriptDocuments`; `.TextDocumentDidChange/DidOpen/DidClose` | PluginSecurity | — | regenerate on schema edit; analysis input | — | verified (dump) |
| `ScriptDocument:GetText/GetLine/EditTextAsync/MultiEditTextAsync/CloseAsync`, `IsCommandBar()` | PluginSecurity | `IsCommandBar` tells the command bar apart | range edits without the blocked APIs | async | verified (dump) |
| `ScriptEditorService:EditSourceAsyncWithRanges`, `OpenStringValueDocumentAsync`, `StripComments` | RobloxScriptSecurity | not available | — (`lync.toml` in a StringValue is edited in the plugin's own widget) | — | verified (dump) |
| `ChangeHistoryService:TryBeginRecording(name, displayName?)`, `FinishRecording(id, op, opts?)`, `SetWaypoint` | PluginSecurity | — | one undo step per generation | — | verified (dump) |
| `Plugin:GetSetting/SetSetting` | PluginSecurity | per user and per machine; not shared through Team Create | plugin UI state only, never configuration | — | verified (dump) |
| `Plugin:SaveSelectedToRoblox`, `PromptSaveSelectionAsync` | PluginSecurity | save a selection as a model or file; not a publish hook | — | — | verified (dump) |
| `StudioPublishService.*` (`OnPublishAttempt`, `RegisterPublishHold`, `GamePublishFinished`, …), `StudioService.OnSaveToRoblox`, `StudioAssetService.OnSaveToRoblox` | **RobloxScriptSecurity** (every member) | **no third-party plugin can hook or gate publish or save** | — (CI is the only gate that runs before release, §4) | — | verified (dump: every member named Publish/Save/Upload/Commit searched) |
| `DataModel:SavePlace(saveFilter?)` | security None; **Deprecated** | — | — | — | verified (dump) |
| `AssetService:CreateAssetAsync(object, assetType, params?)` | capability `AssetCreateUpdate`, Yields | "only in locally loaded plugins", and uploads without a prompt | a local plugin uploading a built shard model | async | verified (dump); documented (AssetService.yaml) |
| `AssetService:SavePlaceAsync(params?)` | capability `AssetCreateUpdate` | only for places made by `CreatePlaceAsync` or with the API enabled; overwrites the place; blocked by an active Team Create session | — (not a build path for normal places) | async | documented |
| `ScriptContext:EnableCoverage(instance)`, `GetCoverageStats()` | capability `PluginOrOpenCloud` | coverage must be enabled first | per-line and per-function hit counts in a play test: a dynamic check on the static reachability scan (`v5-integrity.md` §3) | per run | verified (dump); documented |
| `RunService:IsEdit()` | PluginSecurity | — | tell edit mode from play mode | — | verified (dump) |
| Script Injection permission | Studio prompt when a plugin writes scripts | a denial is remembered | the plugin must detect a denial and explain how to grant it | — | reported (devforum, via `client-security-build.md` §1.4) |

**What this makes possible (plugin):**
- Generate shards with `UpdateSourceAsync`, inside one `ChangeHistoryService` recording, with diagnostics through
  `RegisterScriptAnalysisCallback`.
- Use coverage in a play test to confirm which client-sent definitions client code actually fires, beside the
  static scan.
- Nothing more: there is no publish gate in Studio. The runtime schema-hash check stays the safety net, and only
  CI can guarantee generation before a release.

---

## 4. Open Cloud

Base URL `https://apis.roblox.com`, authenticated with an `x-api-key` header or OAuth 2.0. API-key rate limits are
shared across all keys of one owner (a user or a group). Source for every row: openapi; guide files are named in
the row.

| API | Method and path | Scope | Limits | Enables | Claim |
|---|---|---|---|---|---|
| Luau Execution, create task | `POST /cloud/v2/universes/{u}/places/{p}[/versions/{v}]/luau-execution-session-tasks` | `universe.place.luau-execution-session:write` | **5/min**; script ≤4 MB; runs ≤5 min; return values ≤4 MB as JSON; no physics; place scripts don't auto-run; **data-model changes are not persisted**; cloud APIs such as DataStores do work | in-engine CI tests against an exact place version: decode the golden set, run the differential test, measure server-side costs from v5.md §10 | documented |
| Luau Execution, logs | `GET …/tasks/{id}/logs` | read | ≤450 KB kept; flat or structured (message type) | CI collects `print`/`warn` output | documented |
| Luau Execution, binary input | `POST /cloud/v2/universes/{u}/luau-execution-session-task-binary-inputs` | write | ≤100 MiB; presigned upload; valid 15 min; reusable within the universe; arrives as `BinaryInput: buffer`; `enableBinaryOutput` returns a buffer | feed a corpus of captured frames to a test | documented |
| Place publishing | `POST /universes/v1/{u}/places/{p}/versions?versionType=Published` (or `Saved`) | `universe-places:write` | **30/min**; body `.rbxl` or `.rbxlx`; returns `{versionNumber}`; doesn't update EditableImage, EditableMesh, PartOperation, SurfaceAppearance or BaseWrap | the only path where generation always precedes publish; `Saved` for staging | documented (cloud/guides/usage-place-publishing.md) |
| Restart servers | `POST /cloud/v2/universes/{u}:restartServers` | `universe:write` | **30/min**; by default restarts only servers on older versions; can restart all | retire servers still running the previous build, so a new build's seed and key reach every server | documented |
| Server management | `/server-management/v1/universes/{u}/restarts` (`POST`, `:forecast`), `…/places/{p}/versions/{n}/game-servers`, `…/game-servers/{jobId}/logs` | `universe:write` / `read` | 100/min | staged restarts with an impact forecast; reading live server logs in CI | documented |
| Instance read and update | `GET` / `PATCH /cloud/v2/universes/{u}/places/{p}/instances/{id}`, `:listChildren` | `universe.place.instance:read` / `:write` | 45/min; beta: Script, LocalScript and ModuleScript only; script source ≤200,000 B; responses ≤500,000 B; needs a collaborative session; can't update scripts open in Studio or inside a package; results arrive as an async Operation | a CI drift check that compares the place's scripts with the manifest; writing a shard without a full republish | documented (cloud/guides/instance.md) |
| Configs | `PUT …/repositories/InExperienceConfig/draft:overwrite`, `PATCH …/draft`, `POST …/publish`, `GET …/full`, `…/revisions/{id}/restore` | `universe:read` / `write` | publish **10/min**; `draftHash` for optimistic concurrency; `Immediate` or `GradualRollout` (15 min) | CI rotates the server-only `ConfigService` values, with a version history and rollback | documented (cloud/guides/configs.md) |
| Secrets store | `GET`/`POST /cloud/v2/universes/{u}/secrets`, `GET …/secrets/public-key`, `PATCH`/`DELETE …/secrets/{id}` | `universe.secret:read` / `write` | 120/min; the value is sealed with libsodium to the game's public key | rotate backend credentials from CI | documented (cloud/guides/secrets-store.md) |
| Data stores | `/cloud/v2/universes/{u}/data-stores/{id}/entries[/{entry}]`, `:increment`, `:listRevisions`, `:snapshot` | `universe-datastores.objects:*` | 1,000,000/min nominal, plus the data-store throttling guide's limits | CI writes the per-build key and seed record that servers read at start | documented |
| Memory store | `…/memory-store/sorted-maps/{id}/items`, `…/queues/{id}/items`, `:flush` | `memory-store.*` | engine quotas apply (§1) | cross-server state, readable from CI | documented |
| Messaging | `POST /cloud/v2/universes/{u}:publishMessage` | `universe-messaging-service:publish` | 5,000/min, plus the engine's messaging limits | push a rotation notice to live servers | documented |
| Assets | `POST /assets/v1/assets`, `PATCH /assets/v1/assets/{id}`, `GET …/versions` | `asset:read` / `write` | 120/min; ≤20 MB per upload; Model accepts `.rbxm`/`.rbxmx`/`.fbx`/`.gltf`/`.glb` and uploads as a **package**; `.rbxm` files edited outside Studio "might not upload or function" | uploading a built shard model for `InsertService:LoadAsset`; **whether scripts inside survive the upload is unverified** | documented (cloud/guides/usage-assets.md) |

**What this makes possible (CI):**
- **One release run with one seed.** `lync build` → `rojo build` → Place Publishing (`Published`) →
  `restartServers`. Within minutes every server runs the new build's field order, tag constants and key policy.
  CI writes the build's key or seed record to a data store first.
- **Validation in a real server before release.** A Luau Execution task against the just-published version
  decodes the golden set, sent as a binary input, and fails the release on any byte difference.
- **Live, reversible policy.** Configs publishes server-only integrity values (10/min) with rollback, and no client
  ever receives them.
- **A drift check.** The Instance API reads the published scripts and compares their hashes with the build
  manifest. This attests what was published, not what a client runs.

---

## 5. Lute

Lute 1.0.0 (`.data/projects/lute` at e969ff7). It was rejected as the shipped host (`v5-tooling.md` §4: no macOS
x86_64 release, and module paths and CST fields drift from its own docs). It is still usable for repo-internal
scripts.

| API | Signature | Limits | Enables | Claim |
|---|---|---|---|---|
| `luau.compile(source, {optimizationlevel, debuglevel, coveragelevel}?) → Bytecode` | each option an integer, default 1 | — | compile shards or transformed scripts, to check bytecode size and opcodes | verified (`lute/luau/src/luau.cpp` line 48) |
| `luau.load(bytecode, chunkname, env?)` | — | — | run generated code in-process for differential tests | verified (`definitions/luau.luau`) |
| `luau.typeofModule(path): TypePack?`, `luau.resolveModule(path, from)` | runs the type checker in NoCheck mode, keeping the full type graph | types only, not diagnostics | a type-aware reachability scan | verified (`luau.cpp` line 107) |
| `@std/syntax` `parser.parse(source): CstParseResult`, `parseExpr` | every CST node carries `location: Span` (begin and end line and column) | the parser is C++ and can't run in Studio | finding call sites with exact positions (§10) | verified (`definitions/syntax/{parser,cst}.luau`) |
| `@std/syntax` `query.findAllFromRoot(cst, fn)`, `filter`, `map`, `replace`, `forEach`; `visitor`; `printer` | `replace` returns `Replacements`; `printer` prints the CST back, trivia kept | — | the call-site scan and source-to-source transforms of built code | verified (`lute/std/libs/syntax/*.luau`) |
| `@lute/crypto` `crypto.digest(hash, message): buffer` | `md5`, `sha1`, `sha256`, `sha512`, `blake2b256`, through OpenSSL EVP | 1.0 resolves it as `@lute/crypto`, while the docs say `@std/crypto` | hashing manifests and shards | verified (`definitions/crypto.luau`; `lute/crypto/src/crypto.cpp`) |
| `crypto.secretbox.keygen/seal/open`; `crypto.password.hash/verify` | libsodium `crypto_secretbox` and `crypto_pwhash` | — | key generation in repo scripts | verified (`crypto.cpp`) |
| `@lute/fs` `open/read/write/close`, `readIntoBuffer`, `stat`, `type`, `listdir`, `exists`, `copy`, `move`, `remove`, `mkdir`, `rmdir`, **`watch(path, callback)`** | — | — | reading a Rojo project; watch mode, which Lune lacks | verified (`definitions/fs.luau`) |
| `@lute/process` `run(args, opts?)`, `system`, `args`, `env`, `cwd`, `homedir`, `execPath`, `pid`, `exit`, `onSignal` | — | — | driving rojo and darklua from a script | verified (`definitions/process.luau`) |
| `@lute/net` `client.request`, `client.websocket`, `server.serve` | — | — | dev tooling only | verified (`definitions/net`) |
| `@lute/vm` `vm.create(path)` | a fresh VM | — | isolating a differential run | verified (`definitions/vm.luau`) |
| `batteries/toml.luau` | pure Luau TOML parser | uses `const function`; whether Studio's parser accepts `const` is unverified | one TOML parser shared by the CLI and the plugin | documented (`client-security-build.md` §5.2) |

**What this makes possible:** a repo-internal tool that parses the schema and every script to the CST, finds Lync
call sites with exact positions, rewrites built copies, compiles both the shard and the rewritten code, runs them
side by side for byte equality, and hashes the outputs. The CLI and the plugin still need the core's own pure-Luau
lexer, because the CST parser can't run in Studio.

---

## 6. Lune, mlua and Rust crates

| API | Signature / context | Limits | Enables | Claim |
|---|---|---|---|---|
| mlua 0.12.2, feature `luau` (also `luau-jit`, `luau-vector4`) with luau0-src 0.22.0+luau740 | Rust embedding at a pinned Luau version | — | the shipped CLI host | verified (mlua `Cargo.toml`; crates.io) |
| mlua `Compiler::new().set_optimization_level(u8).set_debug_level(u8).set_type_info_level(u8).set_coverage_level(u8)`, `set_mutable_globals`, `set_vector_ctor/type`, `set_disabled_builtins`; `compile(src) → Vec<u8>` | — | — | compiling shards at fixed settings; measuring bytecode size for §10 | verified (mlua `src/chunk.rs` lines 258–398) |
| mlua `Lua::set_compiler`, `Chunk::set_name/set_environment/set_mode`, `Lua::sandbox(bool)`, `Lua::create_buffer` | — | — | evaluating the user's schema sandboxed; buffer-path codec tests | verified (`state.rs` lines 680, 1309, 1415; `chunk.rs` lines 520–565) |
| Lune `@lune/luau` `compile(source, {optimizationLevel, coverageLevel, debugLevel})`, `load(source, {debugName, environment, injectGlobals, codegenEnabled})` | a custom `environment` deoptimises the chunk and disables codegen | — | the prototype host's differential runs | documented (Lune docs) |
| Lune `@lune/serde` `encode/decode(format, …)`, `compress/decompress(format, s, level?)`, `hash(algorithm, message)`, `hmac(algorithm, message, secret)` | hash: md5, sha1, sha224–512, sha3-224–512, blake3; compress: brotli, gzip, lz4, zlib, zstd | — | hashing, keyed MACs and TOML in the prototype host | documented (Lune docs) |
| Lune `@lune/roblox` `deserializePlace/serializePlace(dataModel, xml?)`, `deserializeModel/serializeModel`, `getReflectionDatabase`, `implementProperty/implementMethod` | operates on file contents (strings), binary by default | — | a post-build pass over a place file in Luau (§10) | documented (Lune docs) |
| rbx_binary 3.0.1 `from_reader(R) → WeakDom`, `to_writer(W, &WeakDom, &[Ref])`; rbx_xml 3.0.1 | binary and XML place/model formats | — | the same pass in Rust inside the mlua host | verified (`rbx_binary/src/lib.rs` lines 84 and 90) |
| rbx_dom_weak 4.2.0 `WeakDom::root_ref/get_by_ref/get_by_ref_mut/descendants/insert`; `InstanceBuilder::new/with_property/with_child`; `Instance.properties: UstrMap<Variant>` | `Source` is a string property | — | finding scripts, replacing `Source`, adding shard instances | verified (`rbx_dom_weak/src/{dom,instance}.rs`) |
| rbx_reflection_database 3.0.1+roblox-741 | class and property data | — | checking that a pass writes properties the engine knows | documented (crates.io) |
| blake3 1.8.7, sha2 0.11.1, siphasher 1.0.4 | hashing | — | shard and manifest hashes; a HalfSipHash reference for the tag's golden vectors | documented (crates.io) |
| getrandom 0.4.3, rand_core 0.10.1 | OS entropy | — | drawing each build's seed in CI | documented (crates.io) |
| notify 8.2.0 | file watching | — | `lync watch` | documented (crates.io) |
| lune-roblox 0.4.0 | Lune's place logic as a library | — | reusing it inside the mlua host | documented (crates.io) |

**What this makes possible:** the shipped Rust host runs the pure-Luau core at a pinned Luau, draws each build's seed
from OS entropy, hashes shards and the manifest, and watches files. For §10 it can also read the built `.rbxl`,
replace script sources and write the file back before Place Publishing, all in CI. The crate APIs are verified; a
full place round trip with script rewriting has not been run (unverified).

---

## 7. darklua, luau-lsp and rojo

| API | Signature / context | Limits | Enables | Claim |
|---|---|---|---|---|
| darklua 0.19.0 `process <input> <output> [--config] [--format dense\|readable\|retain_lines] [--watch]` | reads Lua/Luau **source files or folders**; parser full_moon 2.2.0 | doesn't read `.rbxl`/`.rbxm` | a pass over built `.luau` before `rojo build` | verified (`src/cli/process.rs`; `Cargo.toml`) |
| darklua rules: 32 named rules (for example `inject_global_value`, `compute_expression`, `convert_index_to_field`, `remove_unused_variable`, `convert_require`, `rename_variables`), plus a bundler configured separately | fixed set; no rule scriptable in Luau; a custom rule needs Rust (`darklua_core` `Rule` trait) | `rename_variables` is unseeded, and local names aren't in shipped bytecode, so renaming buys nothing | fold a per-build seed into constants (`inject_global_value` + `compute_expression`); inlining encoders needs a custom Rust rule | verified (`src/rules`; `client-security-build.md` §1.5) |
| darklua format `retain_lines` | keeps line numbers | — | error positions in transformed code still match the input lines | verified (`src/cli/process.rs`) |
| darklua `convert_require` with `rojo_sourcemap` | reads a Rojo sourcemap | — | rewriting requires against instance paths | verified (`src/rules/convert_require`) |
| luau-lsp 1.70.1 `analyze [--sourcemap] [--definitions] [--base-luaurc] [--settings] [--platform standard\|roblox] [--formatter default\|plain\|gnu] [--annotate] files…` | `--annotate` prints the source with inferred types (strict check) | luau-lsp plugins don't run in `analyze` | type-checking shards and transformed scripts in CI; type-aware input to the reachability scan | verified (`src/AnalyzeCli.cpp`, `src/main.cpp`) |
| luau-lsp `require-graph [--sourcemap] [--output-format json\|dot] files…` | CLI since 1.55.0 | — | which scripts can reach the shard: input to reachability and to choosing call sites | verified (`src/main.cpp`; `CHANGELOG.md`) |
| rojo 7.7.1 `build <project> -o out.{rbxm,rbxl,rbxmx,rbxlx}`, `--plugin`, `--watch` | rbx_binary 3.0.1, rbx_xml 3.0.1, rbx_dom_weak 4.2.0 | **no transform hook**; the middleware set is fixed | the built artefact the CI pass transforms and publishes | verified (`src/cli/build.rs`; `Cargo.toml`) |
| rojo `sourcemap [--watch] [--include-non-scripts]` → `{name, className, filePaths, children}` | — | — | maps instances to the developer's files, for the call-site scan and for line maps | verified (`src/cli/sourcemap.rs`) |
| rojo `upload --api_key --universe_id` | posts to Place Publishing | — | publishing from CI | verified (`src/cli/upload.rs`) |

**What this makes possible:** `rojo build` produces each build's artefact. Two places can transform it: darklua over
the built `.luau`, with `retain_lines` keeping positions, or a Rust/Lune pass over the place file. luau-lsp
type-checks the result and its `require-graph` gives a type-aware input to the reachability scan. None of these
tools runs a transform at sync time or gates publish, so the transform is an explicit CI step.

---

## 8. Python (dev only)

Never shipped (`v5-tooling.md` §6). Run with `python3 -I` whenever the script reads downloaded data.

| Package | Use for Lync | Version and licence | Claim |
|---|---|---|---|
| zstandard | model the engine's compression in the bit-packing study (`client-security.md` §3.7, `zmask.py`) | 0.25.0, BSD-3-Clause | verified (PyPI; used in that probe) |
| jsonschema | validate `lync.toml` against its JSON Schema in CI | 4.26.0, MIT | verified (PyPI; used in `client-security-build.md` §5.2) |
| hypothesis | property tests and shrinking for decoder fuzz corpora | 6.169.4, MPL-2.0 | documented (PyPI) |
| atheris | coverage-guided fuzzing of a native decoder build | 3.1.0, last upload 2026-06-17 | documented (PyPI) |
| numpy | capture statistics; offline checks of the clock-beacon estimator | 2.5.4, BSD-3-Clause | documented (PyPI) |
| a Luau bytecode parser | inspecting shard bytecode offline | **none found** (searched PyPI and the web); use `luau-compile` or mlua instead | reported (search) |
| an rbxl/rbxm parser | reading captured or built place files | **no maintained Python parser found**; use rbx_binary/rbx_dom_weak (Rust) or Lune | reported (search) |

**What this makes possible:** simulations, schema validation, and fuzz corpora for the decoders (hypothesis
generates them; atheris drives a native build). Bytecode and place-file work belongs to the Rust or Lune tooling,
not Python.

---

## 9. The modified-client capability surface (what defences must survive)

The capability classes and their sources are in `client-security.md` §1.2 (the executor capability table) and §2.1
(identities and platform). This section only pairs each class with the Lync defence that must still work under it.
It describes no usage.

| Capability class (`client-security.md` §1.2) | What it exposes or changes on that client | Lync defence that must survive it | How the defence holds up |
|---|---|---|---|
| Reading the client's own code: bytecode, constants, decompilation | the whole client shard, including field order and tag constants | per-build rotation (`v5-integrity.md` §2) | a static tool must be rebuilt each release, or written to re-derive the layout from each shard. Rotation is not a secret |
| Reading and writing the client's upvalues, stack and GC objects | the session key, the upstream count, the permutation, and limits held in Lync's closures | keyed tag, per-server permutation, per-session key (v5.md §4.5) | a tool holding the key must keep the count in step with Lync's own sends; slips show as `tagMismatch`/`frameGap`. All three values change per session |
| Requiring client modules and calling Lync's own API | valid frames built by Lync's own encoder | traps and reachability, the caller probe (`v5-integrity.md` §3–§4) | wire measures don't apply. Traps price firing definitions that unmodified code never fires; server checks stay the authority |
| Hooking functions and metamethods | values changed above the encoder; spying on remote calls | server authority; the tag within `tag.cover` for changes made below the encoder | changes above the encoder produce valid tags, so only server checks catch them. Hook-detection checks are refused (`v5-changes.md`) |
| Firing or disabling the client's own signal connections | fake inbound frames injected into the client's own view; a disabled listener | the refused-frame report (`v5-integrity.md` §5) | only that client's own view is affected. A non-canonical injected frame is counted and reported, client-stated |
| Packet-level send and receive hooks (below Luau) | upstream packets read, dropped or edited, with no cost visible to Luau | the keyed tag over the implicit count; the replay window | a frame edited inside the cover fails the tag. A dropped frame shows as a gap |
| Thread identity control (`client-security.md` §2.1) | executor threads run at a higher identity by default and can lower it | the caller-identity probe | catches only tools left at the default identity, and its report is client-stated |
| Naming or hiding code and stack frames | chunk names and stack frames made to look like game code | the caller-source check against the build's per-definition script lists | the check prices a tool per build and per definition. It stays client-stated |
| Clock and frame-rate control | clock acceleration; frame rates above the 240 Hz setting | the clock beacon (`v5-integrity.md` §6); the inbound budgets | the beacon prices clock acceleration only; frame rate alone is not a fact |
| Reading replicated state | everything Lync replicates to that client | decoys, canaries, information hiding | prices raw-state readers; data Lync never sends can't be read |

**What a defence must assume:** every client-held secret is readable by the client it protects against, and every
client self-check runs in a VM that client controls. So the measures that hold are the server-checked facts (tag,
replay window, permutation, decode refusals, clock, budgets, early answers, traps, decoys, canaries) and the
variation Lync applies per build, per server and per session, which makes a modified client redo its work each time.

---

## 10. Codecs in game scripts: mechanics

The author considers this viable: each call site's encoder (and decoder) is emitted into the script that uses
it. Ideally it serves two ends: faster code at each site, and codecs that are harder to isolate than one shard
module. Below are the mechanics it needs and their costs.

**Transform the built output, never the developer's source.** This keeps the developer's files, the typed shard
API and the roblox-ts typings unchanged. It avoids the merge conflicts and `UpdateSourceAsync` races that
`v5-changes.md` held against rewriting source.

| Step | How | Limits | Cost | Claim |
|---|---|---|---|---|
| Build | `rojo build -o place.rbxl` | rojo has no transform hook, so the transform is a separate step | one build | verified (§7) |
| Transform the place file | Rust: `rbx_binary::from_reader` → walk `WeakDom::descendants` for Script/LocalScript/ModuleScript → replace the `Source` property → `to_writer`. Or Lune: `deserializePlace`/`serializePlace` | content Place Publishing doesn't update (EditableImage, EditableMesh, PartOperation, SurfaceAppearance, BaseWrap) still needs a Studio publish | one pass per build; no run-time cost | APIs verified (§6); the end-to-end round trip unverified |
| Or transform built `.luau` | darklua over the built files before packing: `inject_global_value` + `compute_expression` fold the seed; inlining needs a custom Rust `Rule` | darklua reads source files, not place files | per build | verified (§7) |
| Find call sites | Lute: `parser.parse` → `query.findAllFromRoot` for `view.name:fire(` / `:invoke(`, with positions from `Span`. Or the core's pure-Luau lexer, the same rule the reachability scan uses, which also runs in Studio | the Lute parser can't run in Studio; a namespace indexed with a non-literal key is incomplete and is not transformed (`v5-integrity.md` §3) | build time | verified (§5) |
| Type-aware refinement | luau-lsp `require-graph` and `analyze --annotate` resolve aliases and argument types | CI only | build time | verified (§7) |
| roblox-ts | rbxtsc copies `.luau`/`.d.ts` through unchanged and the built Luau is transformed like any other; an optional TS transformer can find call sites by type | TS sources only | — | documented (`client-security-build.md` §1.7) |
| Map back to the developer's files | a line map per build (generated line → script and line), kept dev-only like the debug map; darklua `retain_lines` keeps lines aligned when its pass is used | without it, a codec error points into `Weapon:142`, not the shard | one file per build | documented (`client-security-build.md` §5.6) |
| Studio path | the plugin writes only build copies, with `UpdateSourceAsync` inside one `ChangeHistoryService` recording, or `ScriptDocument:MultiEditTextAsync` for range edits | no plugin publish gate (§3); Script Injection permission needed; `EditSourceAsyncWithRanges` is blocked | per edit | verified (§3) |
| Write without a republish | the Instance API `PATCH` of `Source` | ≤200,000 B per script; 45/min; can't touch scripts open in Studio or inside a package | per script | documented (§4) |

**The typed API stays a module.** Game code still calls `Net.chat:fire(text)` through the typed shard, so Luau
types and the `.d.ts` are unchanged. The transform replaces only the encoding behind each call site, in the built
copy.

**Costs and limits:**
- **Bytecode size.** 50 inlined call sites measured 5.0× the shared-module bytecode (22,927 B against 4,587 B),
  and every client downloads it (verified, `client-security-build.md` §3.2).
- **Speed.** A call into a straight-line shard encoder is already a fast path, so inlining saves about one call
  per message. The speed half of the two ends matters only where the code would otherwise be table-driven, as on
  the runtime path.
- **Isolation.** Per-build codecs spread across call sites make locating the encoders per-build work. The batching
  queue stays central, and a tool that already re-derives rotated constants from client code does little extra
  work (`v5-changes.md` part 2). The added cost to a modified client is real but bounded.
- **Maintenance.** A transform step and a line map per build. One end-to-end place round trip must be proven
  before the design relies on it.

---

## Implications

Ranked for the next design pass. Each line points at its findings.

1. **Use the documented `RemoteEvent` queue.** Send `WELCOME` from the server without waiting for `HELLO`, which
   saves a join round trip, and close that v5.md §10 item. Unreliable messages are discarded with no handler, so
   this applies to the reliable lane only (§1).
2. **Deliver server-only integrity policy through `ConfigService`, rotated from CI with the Configs API.** It is
   live, versioned and never reaches a client (§1, §4).
3. **Build the release on Open Cloud, with one seed per run:** build → publish → `restartServers`. The per-build
   key or seed record is written to a data store first, and a Luau Execution task checks the golden set in a real
   server before release (§4).
4. **Measure `EncodingService` on devices** as a native schema hash and a keyed-prefix tag candidate (Blake3 or
   Blake2b), and as Lync's own Zstd path for byte-tail data. Keep HalfSipHash until the numbers favour a switch
   (§1).
5. **Add execution coverage as a dynamic check on reachability:** play tests in Studio now, and Luau Execution
   once confirmed (unverified) (§3, §4).
6. **Build codecs in game scripts as a CI transform of built output,** keeping the typed shard as the API and a line
   map per build. Prove one end-to-end place round trip first, and weigh 5.0× bytecode against an isolation gain
   that is real but bounded (§10).
7. **CI stays the only enforced pre-release gate.** No plugin publish hook exists, so the runtime schema-hash check
   remains the Studio safety net (§3).
8. **Judge every client measure against the capability classes in §9** (`client-security.md` §1.2): it must work
   when the client reads all its own state, hooks above the encoder and controls its identity.
