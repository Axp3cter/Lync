# Lync v5: security tooling and platform API catalogue

Researcher findings, 2026-10-15. What each tool and platform surface can actually do **for Lync's security**, so
the next design pass can build defences on real capabilities. For each surface: a table of API | signature/context |
limits | enables (which defence) | cost | claim mark, then "solutions this makes possible".

Claim marks: **verified** (ran it or read the source), **documented** (official docs/dump say so), **reported**
(third party), **unverified** (inference). Probe sources and exact versions:
`.data/docs/probes/security-tooling/sources.md`. API-dump facts are from Roblox API 0.741.19 (tracker fcd6994);
creator-docs from github.com/Roblox/creator-docs @ efe8741 (2026-10-15); reference sources read in
`.data/projects/`; crate versions from crates.io 2026-10-15.

Framing is the defender's throughout. Capabilities are listed so a defence can be judged against what the platform
offers and what a modified client can do; no bypass steps are given.

---

## 0. Bottom line

1. The server can observe and vary far more than the drafts used. New, verified, zero-to-cheap levers worth a
   design pass: **`ConfigService` live per-build/per-server values** (server-only, real-time, no client read),
   **Open Cloud Luau Execution + Place Publishing + `restartServers`** for a CI that rotates keys and publishes
   per-build shards and forces old servers off, **`EncodingService` native hashing** (Blake3/SHA256/Blake2b,
   security None, thread-safe) usable in the runtime path for the tag and the schema hash, and **`LogService`
   structured logging** (`context` dict) for console lines that never carry client bytes.
2. The plugin can read and write script source and run analysis in Studio, but **cannot gate publish or save**
   (every such member is RobloxScriptSecurity) — verified again. CI (Open Cloud) is the only place a build can be
   forced before a release ships.
3. **Codecs spread into game scripts is mechanically viable** as a *post-build* transform (rojo build → place file
   → mlua/rbx-dom pass, or darklua over built `.luau`), with a source map for errors and call sites found by the
   Luau AST. §10 catalogues the mechanics; the real costs are bytecode size, a line map to maintain, and the
   roblox-ts path staying a typed module.
4. The executor surface is unchanged in kind from the drafts' model but now pinned to exact Potassium v2.3.5
   globals: full bytecode/constant/upvalue read-write, in-place hooks, `raknet` packet hooks, `firesignal`/
   `getconnections`, identity control, `getgc`/`filtergc`, decompiler. Every client measure must survive all of it.

---

## 1. Roblox engine, server side

What the server can use to vary, deliver, observe or verify client code and traffic per player.

| API | Signature / context | Limits | Enables | Cost | Claim |
|---|---|---|---|---|---|
| `RemoteEvent:FireServer/FireClient/FireAllClients`, `.OnServerEvent(player, …)` | capability `RemoteEvent`, sec None | client→server ≈500 req/s **per client, shared across all RemoteEvents**; excess is **delayed, not dropped**, kept in order; reliable and ordered across instances | the one reliable upstream/downstream pair; tag rides here | per-call engine overhead unmeasured (v5.md §10) | documented (RemoteEvent.yaml; dump) |
| `UnreliableRemoteEvent:FireServer/…` | capability `RemoteEvent`, sec None | **payload >1000 B dropped**; same ≈500 req/s shared cap; unordered, unreliable; error names bytes over | unreliable lane; replay window rides here | as above | documented (UnreliableRemoteEvent.yaml) |
| `workspace:GetServerTimeNow()` | capability `Basic`, **thread Safe**, returns double | monotonic; within 0.6% of local clock rate; smoothed | state-tick epoch (§4.5); clock beacon reference (v5-integrity §6) | one call | documented (dump; Workspace.yaml) |
| `Player:GetNetworkPing()` | capability `Players`, **thread Safe**, returns float (seconds, RTT) | smoothed, lags a sudden latency drop; "isolated network latency … no deserialization" | early-answer check (v5-integrity §7) | one call per server ask | documented (dump; Player.yaml) |
| `EncodingService:ComputeBufferHash(input: buffer, algorithm): buffer` | sec **None**, cap None, **thread Safe** | algorithms: Blake2b, Blake3, Md5, Sha1, Sha256; "not a password hash" | schema hash (§4.7) and keyed-tag primitive in a host without HalfSipHash; drift check on built code | native; thread-safe so usable in parallel | documented (dump; EncodingService.yaml) |
| `EncodingService:ComputeStringHash(input: string): string` | sec None, Safe | same algorithms | hashing source text / shards in-engine (Studio drift check) | native | documented |
| `EncodingService:CompressBuffer(input, Zstd, level?): buffer` / `DecompressBuffer` / `GetDecompressedBufferSize` | sec None, Safe | Zstd only; **level −7…22**; `GetDecompressedBufferSize` returns int? | an explicit, measurable compression path (settles v5.md §4.3's "engine zstd is undocumented": Lync can compress a frame itself at a known level instead of relying on the opaque remote compressor) | CPU per level | documented (dump; EncodingService.yaml, CompressBuffer) |
| `EncodingService:Base64Encode/Decode(buffer): buffer` | sec None, Safe | — | capture/telemetry encoding | native | documented |
| `LogService:Warn/Error/Info/Log(message, context: Dictionary?)` | cap `Logging`; structured `context` dict | server-only `Server*Out` events are RobloxScriptSecurity (not reachable) | console lines with numbers in `context`, no client bytes in the template (v5.md §7.4); groups one Error Report row | per call (unmeasured, v5.md §10) | documented (dump; LogService.yaml) |
| `LogService:GetLogHistory(): Array` / `GetLogHistoryAsync` | cap `Logging`; items `{message, messageType, timestamp, context}` | **capped at 512 entries** by default | reading back own output in-process (inspector) | — | documented (LogService.yaml) |
| `ScriptContext.Error(message, stackTrace, script)` [event] | cap `Logging`, sec None | does **not** fire for watchdog timeouts | observing game-code errors; native-report channel fires it (v5.md §7.2) | — | documented (dump; ScriptContext.yaml) |
| `Stats.DataSendKbps`, `DataReceiveKbps`, `HeartbeatTimeMs`, `InstanceCount`, … | sec None, **ReadSafe**, ReadOnly | per-server aggregate, not per-player | inspector traffic view; not a per-player signal | read | documented (dump) |
| `Stats:GetTotalMemoryUsageMb()`, `GetMemoryUsageMbForTag(tag)` | sec None | — | inspector memory | read | documented |
| `RunService.PostSimulation(dt)` / `PreSimulation` / `Heartbeat` | cap `Basic` | server flush point (v5.md §5.1) | the flush/state-tick clock | per frame | documented (dump) |
| `RunService:IsServer()/IsClient()/IsStudio()/IsEdit()` | Safe; `IsEdit` PluginSecurity | — | side selection; Studio-only behaviour | — | documented |
| `ConfigService:GetConfigAsync(): ConfigSnapshot`, `GetConfigForPlayerAsync(player)` | sec None, **server-only** (errors on client); Yields | values ≤100,000 chars (string/JSON); up to 100 conditions/game, 20/key; publish propagates "15 s–1 min" or 15-min gradual | **per-build/per-server runtime policy and secrets-lite delivered from the cloud without a client read**: rotate the caller-probe member, beacon thresholds, budgets, even a non-secret seed, live, per universe | one async fetch + snapshot; snapshots don't auto-update (`UpdateAvailable`/`Refresh`) | documented (dump; ConfigService.yaml; production/configs.md; cloud/guides/configs.md) |
| `ConfigSnapshot:GetValue(key)`, `:GetValueChangedSignal(key)`, `.UpdateAvailable`, `:Refresh()` | cap `Basic` | snapshot is point-in-time | apply new policy between rounds, not mid-match | — | documented |
| `ConfigService:SetTestingValue/ClearTestingValue(key)` | sec None | per-server, this server's lifetime | test integrity thresholds in a live/Studio server | — | documented |
| `HttpService:RequestAsync(options): Dictionary` / `GetAsync` / `PostAsync` | cap `Network`; `GetSecret` Safe | **500 HTTP req/min per server**; Open Cloud subset is a **separate 2500/min per server** bucket; only `x-api-key`+`content-type` headers; x-api-key must be a `Secret`; HTTPS only | export facts/telemetry to the developer's backend; call Open Cloud from in-game (rotate DataStore keys, publishMessage) | network | documented (http-service.md) |
| `HttpService:GetSecret(key): Secret`; `Secret:AddPrefix/AddSuffix` | cap `Network`, Safe | secret store **live servers / Team Create only**, not local playtest or client; ≤1024 chars; 500/game; URL+headers only, not body; wildcard domain | hold a per-game signing key / backend token the client never sees and that can't be printed | — | documented (cloud-services/secrets.md) |
| `MessagingService:PublishAsync(topic, msg)` / `SubscribeAsync(topic, cb)` | cap `ServerCommunication`, Yields | **msg ≤1 KB**; send (600+240×players)/min/server; recv per-topic (40+80×servers)/min; subscriptions 20+8×players; 240 subscribe req/min | cross-server integrity signal sharing (a key seen forged on server A warned to B); low volume only | per publish | documented (MessagingService.yaml) |
| `MemoryStoreService:GetHashMap/GetSortedMap/GetQueue(name)` | cap `DataStore` | quota **64 KB + 1.2 KB×users** game-wide; **1000 + 120×CCU request units/min**; ≈30,000 units/min/partition; per-key 5,000 write / 15,000 read units/min | short-TTL cross-server flags, per-player strike counters shared across servers | request units | documented (cloud-services/memory-stores) |
| `DataStoreService:GetDataStore(name, scope?, options?)`; `:GetRequestBudgetForRequestType(type)` | cap `DataStore` | request budget per `DataStoreRequestType` (GetAsync=0, UpdateAsync=2, …); value size/throughput limits | per-build key storage, per-player persistent integrity history | async | documented (dump; DataStoreRequestType enum) |
| `ServerScriptService` (service), `ServerStorage` (service) | tags NotReplicated; "never replicated to clients" | — | hold server shard, integrity policy, decoy behaviour, canary maps — never shipped | — | documented (dump tags; data-model.md) |
| `ReplicatedStorage`, `ReplicatedFirst` | ReplicatedFirst replicates first, before the rest | client shard lives here; `RemoveDefaultLoadingScreen` sec None | deliver client shard / remotes; `ReplicatedFirst` for earliest client code | — | documented |
| `Player` / `PlayerGui` (tag **PlayerReplicated**) / `PlayerScripts` (NotReplicated, **not server-accessible**, server Scripts don't run there) | `PlayerGui` filled from StarterGui on spawn, "cleared and replaced" on reset unless `ResetOnSpawn=false` | per-player `ScreenGui`/ModuleScript clone reaches only that player; PlayerScripts can't be read/driven by the server | per-player shard variant delivery (refused, cost: join-time dependency, v5-changes) | one instance/player | documented (PlayerGui.yaml, PlayerScripts.yaml) |
| `Script.Source` / `ModuleScript.Source` (ProtectedString) | **capability `PluginOrOpenCloud` for read AND write** | game scripts **cannot read their own or others' source at runtime** | — (blocks manifest self-attestation of client scripts; confirmed) | — | verified (dump) |
| `Script:GetHash(): string` | **sec LocalUserSecurity** | not callable from a live game server (requires local user) | — (cannot hash a running script from game code) | — | verified (dump) |
| `require(instance)` (ModuleScript) | runs at requirer's identity; `require("./Module")` string paths work and don't yield | no `loadstring` on client; `ServerScriptService.LoadStringEnabled` is **NotScriptable, server-only** | shard loading on first use; no runtime code generation on either side | — | documented (host.md; dump) |
| `InsertService:LoadAsset(assetId): Model` (Yields, cap `LoadOwnedAsset`) / `LoadAssetVersion` | server-only; asset must be owned/shared/Roblox; scripts in loaded models **do not auto-run** until parented where execution is allowed | `AssetService:LoadAssetAsync` returns `Sandboxed=true`, script Capabilities off | loading a per-build shard model published by CI by its asset id (alternative to in-place) | async, moderation | documented (InsertService.yaml) + reported (devforum) |
| `Instance.Capabilities: SecurityCapabilities`, `Instance.Sandboxed: bool` | cap `CapabilityControl` | sandbox/capability model for loaded assets | constraining what a loaded shard model may do | — | documented (dump) |
| `ScriptEditorService` | server context: not applicable (PluginSecurity) — Studio/plugin only (§3) | — | — | — | verified (dump) |

**Solutions this makes possible (server):**
- Compress frames explicitly with `EncodingService:CompressBuffer(Zstd, level)` at a chosen level, removing v5.md §4.3's dependence on the engine's undocumented remote compressor; re-judge the bit-pack-vs-zstd trade with a known codec.
- Use `EncodingService:ComputeBufferHash(Sha256/Blake3)` (Safe, native) for the schema hash and as the tag primitive on any host, instead of only the Luau HalfSipHash; the runtime path gains a native hash.
- Deliver integrity policy and non-secret per-build values (caller-probe member, beacon thresholds, seed) through `ConfigService` live, per universe and per round, with no client read and no republish.
- Hold a per-game signing key in the secret store (`GetSecret`) for a server-side-only MAC of anything the server exports (telemetry attribution), never shipped to clients.
- Share forged-key / desync flags across servers via `MessagingService` (≤1 KB) and `MemoryStoreService` counters within quota.
- Store and rotate per-build keys in `DataStoreService`; read them at server start.

---

## 2. Roblox engine, client side (unmodified client)

What Lync's client shard can observe about its own environment cheaply, and the cost.

| API | Signature / context | Limits | Enables | Cost | Claim |
|---|---|---|---|---|---|
| `debug.info(f|level, "s")` | chunk name; `"l"` line; `"n"` name; `"a"` → (numparams, isVararg) | C fn → `"[C]"`, line `-1`; a vararg Lua fn also gives `0, true` for `"a"` | caller-source check (v5-integrity §4): read first non-Lync frame's source, compare to the build's script list | `"s"` ≈57 ns, cached ≈72 ns; 3-deep walk ≈184 ns (ref Xeon; devices slower) | verified (luau run; client-security §2.2) |
| `debug.traceback()` | stack text | executor `setstackhidden`/`debug.setinfo` clean it | not relied on | raise-path cost | documented |
| `pcall(f, …)` on a protected member | identity gate | success ≈30 ns; a callee that errors 2.2–3.3 µs (string build dominates) | caller-identity probe (v5-integrity §4): a member that fails at identity 2, succeeds at 8 | ≤3.3 µs per failing probe | verified (client-security §2.2) |
| `game:GetService(x)` | errors on unknown service from a low identity | — | — | — | documented |
| `Players.LocalPlayer: Player` | cap `Players`, ReadSafe | nil on server | client identity, ping context | read | verified (dump) |
| `script` (self), `getfenv`/`setfenv` | **`getfenv` clears the safe-env flag**, deoptimising every script it touches (GETIMPORT/FASTCALL fall back) | barred from Creator Store; one 2025 detector used the slowdown itself | — (Lync must never use them) | large (deopt) | verified (luau VM/src/lbaselib.cpp: `lua_setsafeenv(L,-1,false)`) |
| `buffer.*` library | `buffer.create/writeu8/readbits/…`; frozen table | fast calls; in-place hooks of a *safe* env can't see them | the codec's bit I/O; the runtime path | native fast call | verified (luau run: `typeof(buffer.create(4))`→`buffer`) |
| `os.clock()` | not affected by system-clock changes; **not a fast call** (GETIMPORT+CALL), so a hooked `os.clock` is seen | monotonic-ish | token-bucket refills; a hooked value is visible to an executor | call | documented (client-security §2.2) |
| `ScriptContext.Error` (client) | cap `Logging` | client reports only its own facts | local fault reporting; never trusted by server | — | documented |

**Solutions this makes possible (client):** the caller-probe (identity via `pcall`, source via `debug.info`) is the only cheap self-observation worth running, and its outputs are client-stated (v5-integrity §4, §10). Every stronger "am I hooked?" test is defeated by the executor surface (§9) and is refused. Lync's obligation is negative: never `getfenv`/`setfenv`, never require identity >2, so the game's own anti-cheat keeps a clean baseline.

---

## 3. Studio plugin API

| API | Signature / context | Limits | Enables | Cost | Claim |
|---|---|---|---|---|---|
| `ScriptEditorService:UpdateSourceAsync(script, callback)` | PluginSecurity, Yields; callback gets old source, may not yield, returns new source or nil to cancel | editor may reject a stale update and re-invoke the callback | write a generated shard into a script safely | per edit | documented (dump; ScriptEditorService docs) |
| `ScriptEditorService:RegisterScriptAnalysisCallback(name, priority, fn)` / `DeregisterScriptAnalysisCallback` | PluginSecurity | editor-time only | surface Lync build diagnostics in Studio (v5-tooling §4) | — | verified (dump) |
| `ScriptEditorService:GetEditorSource(script)`, `FindScriptDocument`, `GetScriptDocuments`, `.TextDocumentDidChange/Open/Close` | PluginSecurity | — | read current source for analysis / regenerate on edit | — | verified (dump) |
| `ScriptDocument:GetText/GetLine/EditTextAsync/MultiEditTextAsync/CloseAsync` | PluginSecurity | `IsCommandBar()` distinguishes command bar | programmatic edits with ranges; a build-copy writer | async | verified (dump) |
| `ScriptEditorService:EditSourceAsyncWithRanges`, `OpenStringValueDocumentAsync`, `StripComments` | **RobloxScriptSecurity** | **not available to plugins** — a StringValue can't be opened in the editor | shapes where Studio keeps `lync.toml` (a StringValue edited in the plugin's own widget) | — | verified (dump) |
| `ChangeHistoryService:TryBeginRecording(name, displayName?)`, `FinishRecording(id, op, opts?)`, `SetWaypoint`, `.OnRecordingFinished` | PluginSecurity | one undo step per generation | wrap generation so it is one undo | — | verified (dump) |
| `Plugin:GetSetting(key)` / `SetSetting(key, value)` | PluginSecurity | **per-user, per-machine; not shared through Team Create** | plugin UI state only — never config | — | verified (dump) |
| `Plugin:CreateToolbar/CreatePluginMenu/CreatePluginAction/CreateDockWidgetPluginGuiAsync` | PluginSecurity | — | the plugin UI ("Prepare release", inspector) | — | verified (dump) |
| `StudioService.ActiveScript`, `:GetUserId()`, `:PromptImportFileAsync` | PluginSecurity | — | which script is open; author id | — | verified (dump) |
| `RunService:IsEdit()` | PluginSecurity | — | edit vs play | — | verified (dump) |
| `AssetService:CreateAssetAsync(object, type, …)` | sec None, cap `AssetCreateUpdate`, Yields | **plugin-only, no prompt**; Model uploads as a **package**; ≤20 MB; `.rbxm`/`.rbxmx`/`.fbx` | plugin publishes a shard model as an asset (per-build model path) | async | documented (dump; usage-assets.md) |
| `AssetService:SavePlaceAsync` / `CreatePlaceAsync` | cap `AssetCreateUpdate` | SavePlace needs API-enabled or Create-made place; **blocked by active Team Create**; overwrites | automation inside Studio (limited) | async | documented (AssetService.yaml) |
| `Plugin:SaveSelectedToRoblox`, `StudioAssetService.OnSaveToRoblox`, `StudioService.OnSaveToRoblox`, `StudioPublishService.*` (OnPublishAttempt, RegisterPublishHold, GamePublishFinished, OnSaveOrPublishPlaceToRoblox, …) | **all RobloxScriptSecurity** | **no third-party publish or save hook exists** (searched every Publish/Save/Upload/Commit member) | — (a plugin cannot gate or react to publish) | — | verified (dump; §0.2) |
| `ScriptContext:EnableCoverage(instance)` / `GetCoverageStats()` | cap **PluginOrOpenCloud** (not game scripts) | coverage must be enabled first | plugin/CI reachability by execution coverage (per-line, per-function hit counts) — a dynamic complement to the static reachability scan | per run | documented (dump; ScriptContext.yaml) |

**Script injection permission:** writing scripts triggers Studio's Script Injection prompt; a denial is remembered (reported, devforum). The plugin must detect denial and explain how to grant it.

**Solutions this makes possible (plugin):**
- Generate shards in Studio with `UpdateSourceAsync` under one `ChangeHistoryService` recording; surface diagnostics via `RegisterScriptAnalysisCallback`; keep `lync.toml` text in a ServerStorage StringValue edited in the plugin's widget (because `OpenStringValueDocumentAsync` is blocked).
- A "Prepare release" action that draws and writes a fresh build seed.
- Dynamic reachability via `EnableCoverage`/`GetCoverageStats` to confirm the static scan (what client code actually fires in a play test).
- **No** publish gate from a plugin: the runtime schema-hash check is the safety net (v5-tooling §4), and CI is the only enforced-before-publish path.

---

## 4. Open Cloud

Base `https://apis.roblox.com`. Auth: `x-api-key` header (API key) or OAuth2. Rate limits are per API-key owner
(user or group) unless noted; response headers `x-ratelimit-limit/remaining/reset`.

| API | Method / path | Scope | Limit | Enables | Claim |
|---|---|---|---|---|---|
| Create Luau Execution task | `POST /cloud/v2/universes/{u}/places/{p}/versions/{v}/luau-execution-session-tasks` (also `/places/{p}/...` for current) | `universe.place.luau-execution-session:write` | **5/min per key owner**; script ≤4 MB, runs ≤5 min; returns JSON ≤4 MB; no physics, scripts don't auto-run; **data-model changes are not persisted**; can call DataStore etc. | run tests in a real server build; validate a shard decodes a golden frame against the published place; compute per-build facts | documented (openapi.json; LuauExecutionSessionTask schema) |
| Luau task logs | `GET …/tasks/{id}/logs` | same read | ≤450 KB logs retained; FLAT or STRUCTURED (messageType) | collect `print`/warn/error from a CI run | documented |
| Luau task binary input | `POST /cloud/v2/universes/{u}/luau-execution-session-task-binary-inputs` | same write | **≤100 MiB**, presigned upload, valid 15 min, reusable; arrives as `taskInput.BinaryInput: buffer` | feed a captured frame corpus to an in-server differential test; `enableBinaryOutput` returns a buffer | documented |
| Place publishing (v1) | `POST /universes/v1/{u}/places/{p}/versions?versionType=Published\|Saved` | `universe-places:write` | **30/min per key owner**; body `.rbxl` (octet-stream) or `.rbxlx` (xml); returns `{versionNumber}`; **does not update EditableImage/Mesh, PartOperation, SurfaceAppearance, BaseWrap** (publish those from Studio) | the only fully automatic build-then-publish path; publish per-build shards | documented (usage-place-publishing.md; openapi) |
| Instance read | `GET /cloud/v2/universes/{u}/places/{p}/instances/{id}` (`:listChildren`) | `universe.place.instance:read` | **45/min**; response ≤500,000 B else 422; Script/LocalScript/ModuleScript only; **collaborative session required**; async Operation polling | read built scripts from the cloud for a drift check | documented (guides/instance.md; openapi) |
| Instance update | `PATCH /cloud/v2/universes/{u}/places/{p}/instances/{id}` | `universe.place.instance:write` | **45/min**; Script source ≤200,000 B after UTF-8; **cannot update scripts open in Studio or in a package** | write a generated shard into a place from CI without a full republish (beta) | documented |
| Restart servers | `POST /cloud/v2/universes/{u}:restartServers` | `universe:write` | **30/min**; defaults to older-version servers, can force all | **force old servers off after a key/seed rotation** so a per-build shard+key pair is universal within minutes | documented (openapi) |
| Server management | `POST /server-management/v1/universes/{u}/restarts`, `:forecast`, `GET …/game-servers`, `…/logs` | `universe:write`/`read` | 100/min | staged restart with impact forecast; read live server logs | documented (openapi) |
| Configs | `PUT/PATCH …/creator-configs-public-api/v1/configs/universes/{u}/repositories/InExperienceConfig/draft[:overwrite]`, `POST …/publish`, `GET …/full`, `…/revisions/{id}/restore` | `universe:read`/`write` | draftHash optimistic concurrency; Immediate or GradualRollout (15 min) | rotate the ConfigService values (§1) from CI, with version history and rollback | documented (guides/configs.md; openapi) |
| Secrets store | `GET/POST …/cloud/v2/universes/{u}/secrets`, `GET …/secrets/public-key`, `PATCH/DELETE …/{id}` | `universe.secret` | LibSodium sealed box + base64; ≤1024 chars; 500/game | rotate the per-game signing key from CI | documented (guides/secrets-store.md) |
| DataStore Open Cloud (v2) | `GET/POST …/data-stores/{id}/entries`, `:increment`, `:listRevisions`, `:snapshot`, `:undelete` | `universe-datastores.*` | per-endpoint limits | rotate/read per-build keys from CI without a game server | documented (openapi) |
| MemoryStore Open Cloud | `…/memory-store/sorted-maps/{id}/items`, `/queues/{id}/items`, `:flush` | DataStore cap | engine quota applies | cross-server integrity state from CI | documented (openapi) |
| Messaging | `POST /cloud/v2/universes/{u}:publishMessage` | `universe-messaging-service:publish` | ≤1 KB (engine parity) | push an out-of-band signal to live servers from CI | documented (openapi) |
| Assets | `POST /assets/v1/assets`, `PATCH /assets/v1/assets/{id}`, `GET …/versions` | `asset:write`/`read` | **120/min**; ≤20 MB; Model→package; `.rbxm`/`.rbxmx`/`.fbx` | upload a per-build shard model | documented (usage-assets.md; openapi) |

In-game Open Cloud calls go through `HttpService` against a **separate 2500/min-per-server** bucket, not the 500/min HTTP bucket (§1).

**Solutions this makes possible (Open Cloud):**
- One CI release: `lync build` (one seed) → `rojo build` `.rbxl` → **Place Publishing** `Published` → **`restartServers`** to retire old servers, so a per-build field order + tag constants + key are universal within a release. (`Saved` for staging.)
- Store the per-build key / seed in a DataStore (or the secret store) and read it at server start; rotate per release from CI.
- Validate before publish: a **Luau Execution task** against the just-published version decodes the golden set (supplied as a ≤100 MiB binary input), fails the release on a byte mismatch.
- Rotate runtime integrity thresholds live with the **Configs** API, with rollback.

---

## 5. Lute

Lute 1.0.0 (`.data/projects/lute` @ e969ff7). Shipping host rejected (v5-tooling §4: no macOS x86_64 release; module-path/CST drift); still fine for repo-internal scripts. Standard library, from the definitions and C++:

| API | Signature | Limits | Enables | Claim |
|---|---|---|---|---|
| `luau.compile(source, {optimizationlevel, debuglevel, coveragelevel}?)` → `Bytecode` | opts read as ints (defaults 1) | not a full host compiler flag set | compile a shard to bytecode for a size/opcode probe | verified (lute/luau/src/luau.cpp:48) |
| `luau.load(bytecode, chunkname, env?)` → `(...)->(...)` | — | — | run generated code in-process for a differential test | verified (definitions/luau.luau) |
| `luau.resolveModule(path, fromchunkname)`, `luau.typeofModule(path): TypePack?` | NoCheck resolver; retains full type graph | type info only, not diagnostics | read a module's inferred types for a reachability/type scan | verified (luau.cpp:107 `typeofModule`) |
| `@std/syntax` `parser.parse(source): CstParseResult`, `parseExpr` | CST nodes carry `location: Span {line, column}` begin/end | **C++ parser, cannot run in Studio**; 1.0 CST field drift (`token` vs `value`) | find call sites (`:fire`/`:invoke` after a view) with positions; CST round-trips for a source-transform | verified (definitions/syntax/{parser,cst}.luau) |
| `@std/syntax` `query.findAllFromRoot(cst, fn)`, `filter/map/replace/forEach`, `visitor.Visitor` | AST query + rewrite with replacements | — | the call-site scan and a built-code transform | verified (lute/std/libs/syntax/{query,visitor}.luau) |
| `@std/syntax` `printer` | prints a (modified) CST back to source | — | emit transformed shards/scripts | verified (printer.luau) |
| `@lute/crypto` `crypto.digest(hash, msg): buffer` | hashes md5/sha1/sha256/sha512/**blake2b256**; `crypto.hash` table | resolves as `@lute/crypto` in 1.0 though docs say `@std/crypto` | schema hash / drift hash in a Lute host | verified (definitions/crypto.luau) |
| `crypto.secretbox.{keygen,seal,open}`, `crypto.password.{hash,verify}` | authenticated encryption; Argon-style password hash | — | per-build key generation; signing a capture | verified (definitions/crypto.luau) |
| `@lute/fs` `open/read/write/close`, `readDir`, `metadata`, **`fs.watch` → WatchHandle/WatchEvent** | handle modes r/w/x/a/+ | — | read a Rojo project; **watch mode** (Lune lacks it) | verified (definitions/fs.luau) |
| `@lute/net` `client.request(url, meta?): Response`, `client.websocket`, `server.serve` | — | — | fetch (dev only); not for shipped code | verified (definitions/net) |
| `@lute/process` `run(args, opts?)`, `system`, `args`, `cwd`, `env`, `execPath`, `exit`, `onSignal` | — | — | drive rojo/darklua from a Lute script | verified (definitions/process.luau) |
| `@lute/vm` `vm.create(path): table` | fresh VM | — | isolate a differential run | verified (definitions/vm.luau) |
| `@std/json`, `batteries/toml.luau` | pure-Luau TOML | `toml.luau` uses `const function`; Studio-parser acceptance unverified | parse `lync.toml` identically in CLI and plugin | documented (client-security-build §5) |

**Solutions this makes possible (Lute):** a repo-internal generator/checker that parses the schema and scripts to the CST, finds call sites with line/column, compiles and runs both shard and candidate inlined code for a byte-exact differential, and hashes outputs — all without a browser or a moving runtime API. Not the shipped host.

---

## 6. Lune and mlua (Rust)

| API | Signature / context | Limits | Enables | Claim |
|---|---|---|---|---|
| **mlua** `Lua::new()` with `luau` feature; `luau0-src 0.22.0+luau740` pins the exact Luau | Rust embed | — | the shipped CLI host (recommended) at a pinned Luau version | documented (crates.io; client-security-build §1.2) |
| mlua `Compiler::new().set_optimization_level(u8).set_debug_level(u8).set_type_info_level(u8).set_coverage_level(u8).set_mutable_globals(…).set_vector_ctor/type(…)` | const setters | — | compile shards to bytecode with controlled opt/debug; a bytecode-size probe for inlining | verified (mlua-0.12.2 src/chunk.rs:258–390) |
| mlua `Lua::set_compiler(Compiler)`, `Chunk::set_environment(Table)/set_mode(ChunkMode)/set_name`, `lua.load(src)` | — | — | run generated code in a controlled env for a differential test | verified (chunk.rs:541–565; state.rs:1309) |
| mlua `Lua::sandbox(true)` | — | — | run user schema code safely in the host | verified (state.rs:680) |
| mlua `Lua::create_buffer(&[u8])`, Luau vectors, bytecode output | buffers and `vector` supported | — | exercise the codec's buffer path natively | verified (state.rs:1415) |
| **Lune** `@lune/luau` `compile`, `load` | Luau 0.740 (changelog) | — | prototype host; differential run | documented (client-security-build §1.2) |
| `@lune/serde` hashing, compression, `decode("toml"/"json")` | — | — | hashing and config parsing in the prototype host | documented |
| `@lune/roblox` read/write `.rbxl`/`.rbxm`, instance manipulation; f32 CFrame as on Roblox | reads/writes place and model files | — | **post-build pass over the place file** (read scripts, rewrite, write back) — the codecs-in-scripts transform (§10) | verified (client-security-build; lune-roblox 0.4.0) |
| **rbx_binary 3.0.1** `from_reader(R) -> WeakDom`, `to_writer(W, &dom, &[Ref])` | binary `.rbxl`/`.rbxm` | — | read/write a built place in Rust | verified (rbx_binary src/lib.rs:84,90) |
| **rbx_dom_weak 4.2.0** `WeakDom`, `root_ref`, `get_by_ref(_mut)`, `descendants`, `insert`, `InstanceBuilder::new/with_property/with_child`; `Instance.properties: UstrMap<Variant>` | Source is a `Variant::String` property | — | find every Script/ModuleScript, read/replace `Source`, add shard instances | verified (rbx_dom_weak src/{dom,instance}.rs) |
| **rbx_xml 3.0.1** | xml `.rbxlx`/`.rbxmx` | — | same for the XML format | documented (crates.io) |
| **blake3 1.8.7** / **sha2 0.11.1** / **siphasher 1.0.4** | Rust hashing | — | per-build key derivation; HalfSipHash reference for the tag; shard hashing | documented (crates.io) |
| **getrandom 0.4.3** / **rand_core 0.10.1** | OS entropy | — | draw a per-build seed / key in CI | documented (crates.io) |
| **notify 8.2.0** | file watcher | — | `lync watch` (Lune has none) | documented (crates.io) |
| **lune-roblox 0.4.0** crate | place/model lib | — | reuse Lune's place logic as a library in the mlua host | documented (crates.io) |

**Solutions this makes possible (Rust/Lune):** the shipped mlua host compiles the pure-Luau compiler core at a pinned Luau, draws per-build seeds/keys with `getrandom`, derives/hashes with blake3/sha2/siphasher, watches with notify, and — for §10 — reads the built `.rbxl` with rbx_binary/rbx_dom_weak, rewrites script `Source`, inserts shard instances, and writes it back, all server-side in CI before Place Publishing.

---

## 7. darklua, luau-lsp, rojo

| API | Signature / context | Limits | Enables | Claim |
|---|---|---|---|---|
| **darklua 0.19.0** — 33 fixed rules: `rename_variables`, `inject_global_value`, `compute_expression`, `convert_index_to_field`, `remove_comments`, `remove_unused_variable`, `group_local_assignment`, `convert_require`, … | CLI/`darklua_core` `Rule` trait; no Luau-scriptable rule | a custom pass needs a **Rust** program against `darklua_core` | per-build transform of **built** code: rename/inline/fold; constant folding of a per-build seed | verified (src/rules/mod.rs) |
| darklua generators `ReadableLuaGenerator` (retain_lines) / `DenseLuaGenerator` | retain_lines keeps line numbers for maps | — | keep a source map, or minify | verified (src/generator/mod.rs) |
| darklua `convert_require` with `rojo_sourcemap` | reads a Rojo sourcemap | — | require rewriting against instance paths | verified (src/rules/convert_require) |
| darklua `rename_variables` options `globals`/`include_functions`/`detect_globals` | **deterministic, no seed**; local/param names not shipped anyway | renaming shipped bytecode buys nothing | — (not a polymorphism lever) | verified (client-security-build §1.5) |
| darklua operates on `.lua`/`.luau` **source files** (parser: full_moon 2.2.0) | not place files | cannot read `.rbxl`/`.rbxm` | runs over built `.luau` before `rojo build`, or over source | verified (Cargo.toml full_moon 2.2.0; src/frontend/resources.rs) |
| **luau-lsp 1.70.1** `luau-lsp analyze [--sourcemap PATH] [--base-luaurc] [--definitions] [--formatter gnu] [--annotate] files…` | CLI; strict check when `--annotate` | plugins are **editor-only, not applied in CI** | type-checked analysis of shards; `--annotate` prints source **with inferred types** (reachability/type scan input) | verified (src/AnalyzeCli.cpp) |
| luau-lsp `require-graph [--sourcemap PATH] [--output-format json\|dot] files…` | since 1.55.0 | — | a dependency graph for reachability (which scripts reach a definition) | verified (src/main.cpp; CHANGELOG 1.55.0) |
| luau-lsp source-transform plugin `transformSource(source, ctx) -> {TextEdit}?` | sandboxed; 5000 ms; "experimental" | **never runs in `analyze`/CI** | optional no-build hover types only | documented (client-security-build §1.6) |
| **rojo 7.7.1** `rojo build <project> -o out.{rbxm,rbxl,rbxmx,rbxlx} [--watch]` | uses rbx_binary 3.0.1, rbx_xml 3.0.1, rbx_dom_weak 4.2.0 | middleware set is a fixed enum; **no transform/hook/plugin** | emit a per-build place/model that CI then transforms (§10) and publishes | verified (src/cli/build.rs; Cargo.toml) |
| rojo `sourcemap [--watch] [--include-non-scripts]` → `{name,className,filePaths,children}` | — | — | map instance paths to developer files for the call-site scan and error maps | verified (src/cli/sourcemap.rs) |
| rojo `upload --api_key --universe_id` → Place Publishing POST | — | — | publish from CI (alternative to raw Open Cloud) | verified (src/cli/upload.rs) |
| rojo `serve`, `syncback` | — | `serve` churns if output isn't change-stable | dev sync; place→files | verified |

**Solutions this makes possible (darklua/luau-lsp/rojo):**
- `rojo build` emits the per-build artefact; a darklua pass (over built `.luau`) or an mlua/rbx-dom pass (over the `.rbxl`) folds the per-build seed and inlines encoders (§10), keeping line numbers with the readable generator.
- luau-lsp `require-graph` and `--annotate` give a type-aware reachability signal to complement Lync's token scan (the token scan stays the portable default; luau-lsp is the precise CI add-on).
- No tool here gates publish or transforms at sync time; transforms run as an explicit CI step on built output.

---

## 8. Python (dev-only)

Never shipped (v5-tooling §6). Useful for probes, fuzzing, frame analysis.

| Tool | Use | State | Claim |
|---|---|---|---|
| `zstandard` (Python binding) | model engine remote compression for the bit-pack-vs-zstd study | used in client-security §3.7 (`zmask.py`) | verified (ran) |
| `jsonschema` 4.26 | validate `lync.toml` against its JSON Schema in CI | used in client-security-build §5.2 | verified (ran) |
| `smol-toml` (Node) / `tomllib` (Py 3.11+) | cross-check TOML parsing parity | used | verified |
| numpy/scipy | Theil–Sen fit for the clock-beacon estimator study; frame-size statistics | standard | documented |
| a Luau bytecode parser | inspect shard bytecode offline | the engine's `luau-compile`/mlua is easier and pinned; a pure-Python parser is optional | unverified (no maintained one confirmed) |
| an rbxl parser (e.g. `rbx-dom` via Rust, or community Python) | read captured place files for analysis | prefer rbx-dom (Rust) which is maintained; Python rbxl parsers are partial | reported |

Run any Python that reads downloaded data with `python3 -I`. License/maintenance: zstandard (BSD), jsonschema (MIT), numpy/scipy (BSD) are all maintained. A maintained **pure-Python** Luau bytecode or rbxl parser was not confirmed; use the Rust/mlua path for those.

**Solutions this makes possible (Python):** compression and estimator simulations, config-schema validation, fuzzing corpora and capture statistics — all CI/dev, never in the shipped artefact.

---

## 9. The executor API (what a defence must survive)

Potassium v2.3.5 (build 145f189a, 2026-07-28), re-verified live 2026-07-31 — the modified-client capability
surface. Defender framing: each row is what a modified client can see or change.

| Capability | Exact API | What it lets a modified client do to Lync | Which defence it bears on | Claim |
|---|---|---|---|---|
| Read bytecode | `getscriptbytecode(script)`, `dumpbytecode(func)`, `getscripthash(script)`, `getfunctionhash(func)` (Lua closures only, SHA384), `decompile(script\|func)` | read the whole client shard, its constants and field order; fingerprint Lync functions across sessions | per-build rotation (prices static tools per release, not per session); tag constants live in the shard as K-constants and are readable | documented (potassium misc-scripts) |
| Read/write constants, upvalues, stack | `debug.getconstant(s)/setconstant`, `getupvalue(s)/setupvalue`, `getproto(s)`, `getstack/setstack` (also as globals) | read the session key, count, permutation, seed from Lync's closures; rewrite a limit or counter in place | the tag: an extractor holding the key must keep the count in lockstep (slips are `tagMismatch`/`frameGap`); permutation is per session; rotation per build | documented (debug-drawing) |
| Hook functions | `hookfunction(func, hook)` (L→L/L→C/C→C, in place, `rawequal` stays true), `restorefunction`, `isfunctionhooked`, `replaceclosure`, `clonefunction`, `newcclosure(f, name?)`, `newlclosure`, `oth.hook` (C-closure target) | wrap Lync's `fire`/encoder/tag fn or `FireServer` to edit values after checks; `newcclosure` makes a hook report `[C]`, line -1, any name | below-encoder edits are caught by the tag within `tag.cover`; hooks above the encoder produce valid tags (server authority only); hook-detection from Luau is refused (`newcclosure`/in-place defeat it) | documented (cache-closures, misc-scripts) |
| Hook metamethods | `hookmetamethod(obj, "__namecall"\|"__index", hook)`, `getnamecallmethod`, `setnamecallmethod`, `checkcaller`, `getrawmetatable`, `setreadonly`/`makewriteable` | remote spy via `__namecall`; `checkcaller` passes game calls through untouched; bypass `table.freeze`/`__metatable` | spies see Lync frames as opaque buffers (shared schema decodes them); freezing protects nothing | documented (metatable) |
| Fire/intercept signals | `firesignal(signal, …)`, `replicatesignal(signal, …)` (replicates to server), `getconnections(signal)` → `Fire/Disable/Disconnect/Enable`, `getconnection`, `cansignalreplicate`, `getsignalarguments` | inject fake inbound frames into the client's own view; disable Lync's listener; replay; `replicatesignal` fakes a client→server event | refused-frame report (prices non-canonical injection into own view, no server cost); server authority for `replicatesignal` | documented (instance-reflection) |
| Packet-level hooks | `raknet.add_send_hook/add_receive_hook` (return the callback as handle), `raknet.send(packet, priority, reliability, channel)`, `raknet.remove_*` | read/modify/drop/inject packets below Luau with no Luau-visible cost; must be enabled in the executor UI; ban risk | the tag over the implicit count (below-encoder edits fail inside cover); replay window on the unreliable lane | documented (raknet-psmsignal) |
| Identity | `getthreadidentity`, `setthreadidentity(2)` (aliases), `getthreadcaps() → 8`, `setthreadcaps`, `isourthread`, `checkcaller`, `getcallingscript` | executor threads run at identity 8 by default; can drop to 2 to look like a game thread | caller-identity probe (naive drivers at 8 report themselves; one `setthreadidentity(2)` defeats it — the probe only prices the naive case) | documented (misc-scripts) |
| Enumerate GC / env | `getgc(includetables?)`, `filtergc(type, {Name=\|Keys=}, returnOne?)`, `getreg`, `getgenv`, `getrenv`, `getsenv(script)`, `getloadedmodules`, `getscripts`, `getrunningscripts`, `getnilinstances`, `getinstances` | find Lync's internal tables/closures/buffers/session state by shape even if unexposed; `require` the shared schema and Lync's API | the API-driver route (`require(Net).x:fire()`): priced only by traps/reachability and the caller probe, never by wire measures | documented (misc-scripts, instance-reflection) |
| Source names / stacks | `setstackhidden`, `debug.setinfo`, `debug.setname`, `loadstring(src, chunkname)` | name an executor chunk any path; hide frames from a stack walk | caller-source check: honest client code has no `loadstring`, so matching chunk names to the build's script list prices the forger per build/definition | documented (cache-closures, debug-drawing) |
| Read replicated state | `getnilinstances`, `getinstances`, reading any replicated value from the DataModel | ESP/radar/bots from replicated Lync records | decoys and canaries (price raw-state readers); information hiding (don't send it) | documented (anticheat-design §1) |
| Parallel / actors | `getactors`, `getactorthreads`, `run_on_actor`, `getdeletedactors` | reach code isolated in Actors (separate VMs) | no Lync measure depends on Actor isolation | documented (websockets-actor) |
| Timing / flags | `setfpscap(0)`, `getfpscap`, `setfflag`/`getfflag` (name without prefix), `getfflagtype` | raise frame rate past the 240 Hz setting; change engine behaviour | cadence is an information-only fact (fps unlockers are honest); clock beacon prices only clock acceleration (fps cap does not slew the clock) | documented (misc-scripts) |
| Crypto / IO | `crypt.hash` (md5/sha*/sha3, **no blake2b**), `crypt.hmac`, `crypt.encrypt/decrypt` (AES), `request`, `WebSocket.connect`, `readfile`/`writefile` | reimplement the tag given the key; export captured traffic; share keys between machines | nothing the server trusts; confirms the key is not a secret once read | documented (console-crypt, misc-scripts) |

**What a defence must survive (summary):** every client secret is held by the client it defends against; every
client self-check runs in a VM the executor fully controls. So the useful measures are (a) server-checkable facts
from the wire (tag, replay, permutation, direction/lane, decode refusals, clock, cadence, early answers), and
(b) measures whose *recurring work* Lync varies per build/server/session (rotation, permutation, key), which the
executor must redo each time. API-driven forging (`require(Net).x:fire()`) is never stopped on the client — only
server authority, traps/reachability and the caller probe price it.

---

## 10. Codecs in game scripts: mechanics

The author considers spreading codecs into the scripts that use them viable, to be made to work in the next pass,
ideally serving two ends at once: faster per-site code **and** codecs harder to isolate than one shared module.
Here are the mechanics it needs, verified, with costs and limits. (Judged refused earlier on developer cost and the
typed-shard decision, not on feasibility — v5-changes part 2; the mechanics below are what a viable form requires.)

**Transform the built output, not the developer's source.** This is the decisive move: it keeps the developer's
files and the typed shard API intact (so no merge conflicts, no `UpdateSourceAsync` races, roblox-ts typings
unchanged) while the shipped scripts carry inlined codecs. Two verified vehicles:

| Mechanic | How | Limits | Cost | Claim |
|---|---|---|---|---|
| Build the place first | `rojo build -o out.rbxl` (or `.rbxlx`) | rojo has **no transform hook** (fixed middleware enum) — the transform is a separate step after build | one build | verified (rojo src/cli/build.rs) |
| Rewrite the `.rbxl` in Rust | `rbx_binary::from_reader` → `WeakDom`; `descendants()` to find Script/LocalScript/ModuleScript; read/replace the `Source` string property (`Variant::String` in `Instance.properties`); `InstanceBuilder` to add shard instances; `to_writer` back | binary or `rbx_xml` for XML; EditableImage/Mesh/PartOperation/SurfaceAppearance/BaseWrap won't survive a cloud republish (publish those from Studio) | one pass over the DOM; no runtime cost | verified (rbx_binary, rbx_dom_weak APIs) — **inference that this specific pass works: unverified end-to-end** |
| Rewrite built `.luau` with darklua | darklua over the built source before packing (`inject_global_value` to fold the seed; a custom `darklua_core` `Rule` in Rust to inline encoders) | darklua reads **source files, not place files**; a custom pass is Rust; `rename_variables` has no seed and is pointless on shipped bytecode | per-build build-time | verified (darklua rules, generators) |
| Lune alternative | `@lune/roblox` reads/writes `.rbxl`/`.rbxm` and manipulates instances in Luau | Lune host only | per build | verified (client-security-build §1.2) |

**Find the call sites.**

| Mechanic | How | Limits | Claim |
|---|---|---|---|
| Luau AST (Lute) | `@std/syntax` `parser.parse` → CST with `location: Span {line, column}`; `query.findAllFromRoot` to select `view.name:fire(`/`:invoke(` nodes; `printer` to emit | **C++ parser, not in Studio**; token-level is enough for `:fire`/`:invoke` after a view, as the reachability scan already does (v5-integrity §3) | verified (lute syntax) |
| Luau AST (mlua) | compile/parse in the Rust host; or a pure-Luau lexer in the core (portable to Studio) | the portable path is the lexer, not the full parser | documented (client-security-build §1.1) |
| Type-aware | luau-lsp `--annotate` (source + inferred types) and `require-graph` resolve aliases and find `FireServer` by type | editor/CLI only, not Studio; CI add-on | verified (luau-lsp) |
| roblox-ts | `.luau`/`.d.ts` ship as written; the optional transformer sees call sites by type in TS | TS sources only | documented (client-security-build §1.7) |

**Map errors and tooling back to the developer's files.** Keep a **line map** generated line → `{schemaFile\|script, line}`. darklua's `ReadableLuaGenerator` (`retain_lines`) preserves line numbers; a hand transform records its own offsets. The map is dev-only (reproducible from schema+seed), as the debug map already is (client-security-build §5.6). Without it, a codec error points into `Weapon:142`, not a shard.

**Studio path (write only to build copies).** A plugin can write scripts with `ScriptEditorService:UpdateSourceAsync` under one `ChangeHistoryService:TryBeginRecording`/`FinishRecording`, but:
- it **cannot gate publish** (all publish/save members are RobloxScriptSecurity — §3), so a Studio inline pass must write to a **copy** the developer publishes, or run at "Prepare release" into a throwaway tree;
- it must survive the Script Injection prompt (denial remembered);
- `OpenStringValueDocumentAsync`/`EditSourceAsyncWithRanges` are blocked, so range edits use `ScriptDocument:EditTextAsync`/`MultiEditTextAsync`.
The clean Studio story is: build copies only; the enforced-before-publish transform is CI (Open Cloud), not Studio.

**roblox-ts typings stay a typed module.** Keep the API surface a typed `.d.ts` module (the typed shard) and inline only the *encoding*, not the API: call sites still call `Net.chat:fire(text)` with full types; the transform replaces the body of `fire`/the encoder at those sites in the built output. roblox-ts needs no transformer for this (the `.d.ts` is unchanged; `.luau` ships verbatim).

**Costs and limits (verified where marked):**
- **Bytecode size.** 50 inlined encoder call sites measured **5.0×** the shared-module bytecode (22,927 B vs 4,587 B; source 16,962 B vs 4,505 B); every client downloads it (verified, client-security-build §3.2).
- **Speed.** A shared call to a straight-line encoder is already a fast path, so inlining saves little at runtime; the gain is removing one call, not changing the codec (the "faster" half is marginal unless the core is table-driven at those sites).
- **Isolation gain.** With per-build rotation, an inlined encoder at each site makes the central queue (still needed for batching) and the `require(Net)` route **per-build** work to locate — but a rotation-aware tool already reads constants from the loaded shard, so the *recurring* work added over rotation alone is small (v5-changes part 2). Executors still read every inlined site with `getgc`/decompile.
- **Maintenance.** A line map per build; a transform step in CI; the `.rbxl` rewrite path is **unverified end-to-end** (the crate APIs exist and are verified; a full place round-trip with script rewrite was not run here).
- **Hard limits.** Open Cloud instance update caps script source at 200,000 B and can't touch scripts open in Studio or in a package; `restartServers` 30/min; publishing is `.rbxl`/`.rbxlx` only.

**Solutions this makes possible:** a CI step after `rojo build` that (a) parses built scripts, (b) inlines each definition's encoder at its call sites with the per-build seed folded in, (c) writes a line map, (d) publishes via Place Publishing and retires old servers — giving per-build, scattered, non-isolated codecs with the typed shard API preserved as the type source. The two purposes coincide only if the core at those sites is otherwise table-driven (then inlining is both faster and scattered); over straight-line shards the win is isolation, not speed.

---

## Implications

Ranked for the next design pass; each line points at the findings above.

1. **Add `EncodingService` as a hashing/compression primitive** (§1): native Sha256/Blake3, thread-safe, usable in the runtime path for the schema hash and the tag, and an explicit Zstd path that removes v5.md §4.3's dependence on the opaque remote compressor. Verified.
2. **Use `ConfigService` for live, server-only integrity policy and non-secret per-build values** (§1, §4-Configs): rotate thresholds/members/seed per universe and per round with rollback, no client read, no republish. Verified; new lever the drafts did not use.
3. **Build the CI release on Open Cloud** (§4): `lync build` → Place Publishing → `restartServers`, keys in DataStore/secret store, a Luau Execution task validating the golden set against the published version before release. Verified; the only enforced-before-publish path.
4. **Keep the keyed tag primitive hostable two ways** (§1, §6): HalfSipHash in Luau and `EncodingService`/`siphasher` natively, so runtime and CI agree.
5. **Codecs-in-scripts is viable as a post-build transform** (§10): transform the built `.rbxl`/`.luau`, not the developer's source; find sites by the Luau AST (Lute/mlua) or a portable lexer; keep a line map; preserve the typed shard for roblox-ts. Real costs: 5.0× bytecode (verified), a maintained line map, an unverified end-to-end place round-trip, and a speed gain only where the core is table-driven. This is the author's two-purpose candidate; its isolation value is real, its speed value marginal over straight-line shards.
6. **Confirm no plugin publish gate; rely on the runtime hash check** (§3): re-verified. Studio inline passes write to build copies only.
7. **`ScriptContext:EnableCoverage` gives dynamic reachability** (§3) to complement the static scan in a play test or a Luau Execution run.
8. **The executor surface is fully enumerated** (§9): every client measure must survive bytecode/constant/upvalue read-write, in-place hooks, `raknet`, `firesignal`, identity control and `getgc`; the measures that pay off are server-checked facts and per-build/-server/-session varied work.
