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
4. **The executor surface is enumerated by exact name (§9).** Every client measure must survive these:
   - full read and write of bytecode, constants and upvalues;
   - in-place hooks;
   - packet hooks below Luau;
   - control of thread identity;
   - firing Lync's own signals;
   - `getgc` scans.

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
