# Lync v5 — External Research Brief (as of 2026-10-15)

Conventions: every non-obvious claim carries a URL. **[UNVERIFIED]** = community claim / folklore / my inference without a primary source. **[MEASURED]** = I ran it locally (Luau 0.740 CLI on a 2.1 GHz Xeon, or Python zstd 1.5 via `zstandard` 0.25); the scripts are in `.data/docs/probes/landscape/`. **[MEMORY]** = a well-known reference I cite from memory and did not re-fetch this session.

---

## 1. Competitors

### 1.1 Landscape summary

| Lib | Kind | Status (late 2026) | Typing | Notes |
|---|---|---|---|---|
| Blink (1Axen) | IDL → Luau/TS codegen; compiler written in Luau | Active: v0.18.9 committed 2026-09-19 ([repo](https://github.com/1Axen/blink)) | Concrete generated Luau types + optional `.d.ts` | The most active IDL lib. Has its own Studio plugin |
| Zap (red-blox) | IDL → Luau/TS codegen; compiler in Rust | 0.6.x maintenance only (0.6.29, 2026-06-23). The `rewrite` branch has had no commits since 2024-07 ([README](https://github.com/red-blox/zap), [rewrite](https://github.com/red-blox/zap/tree/rewrite)) | Concrete generated types + TS | The "original" IDL. Users call Blink its successor ([thread](https://devforum.roblox.com/t/what-networker-should-i-use/4889485)) |
| ByteNet (ffrostfall) | Runtime schema (combinators) | Low activity: last commit 2025-08-01, wally 0.5.0 ([repo](https://github.com/ffrostfall/ByteNet)) | 0.5 uses **user-defined type functions** + `read` props, so it needs the new solver ([types.luau](https://github.com/ffrostfall/ByteNet/blob/master/src/types.luau)) | Its author points BridgeNet2 users to it |
| Packet (Suphi) | Runtime schema, positional args | v1.7 (2025) ([thread](https://devforum.roblox.com/t/packet-networking-library/3573907)) | Values typed by casts | Many quantized types (f16/f24, 12/15/18-byte CFrames) |
| Warp (imezx) | Dynamic by default, optional schema | Active: 1.1.0-pre8, 2026-10-10 ([repo](https://github.com/imezx/Warp)) | String-keyed events (`Server.Connect("Name", fn)`), weak | **XOR-delta streams** to exploit engine zstd (see §1.6) |
| Squash (Data-Oriented-House) | SerDes toolkit, not a network lib | Last commit 2026-01-03 ([repo](https://github.com/Data-Oriented-House/Squash)) | Per-codec generics | Best public measurements of the remote wire format |
| Red (red-blox) | Runtime, single remote | Dead: last commit 2024-02 ("remove unreliable batching") ([repo](https://github.com/red-blox/Red)) | Basic | Mostly of historical interest |
| BridgeNet2 | RemoteEvent wrapper | Deprecated: README says "I strongly recommend you use ByteNet" ([repo](https://github.com/ffrostfall/BridgeNet2)) | Basic | Cut 7 header bytes per call by funnelling |
| QuickNet | Runtime schema, RemoteEvent-mirroring API | New in 2026 (v0.3.4) ([thread](https://devforum.roblox.com/t/quicknet-v034-up-to-10x-faster-than-remoteevents-drop-in-networking-library/4624342)) | "Type-safe" claimed | Fastest in its own benchmark (see §1.7) |
| Jolt | Runtime, 16-bit hashed channel names, Heartbeat flush | v1.1.0 (~late 2025) ([thread](https://devforum.roblox.com/t/jolt-a-high-performance-type-safe-and-developer-friendly-networking-library-for-roblox/4095212)) **[UNVERIFIED details]** | Claimed | |
| NetRay Compile | IDL compiler (v0.1.1, 2026-07) | Replaces the abandoned NetRay ([forum listing](https://devforum.roblox.com/c/resources/community-resources/74)) **[UNVERIFIED body]** | Generated | |
| Pigeon | Named channels, middleware, rooms, staged tables | 2026-07/08 ([thread](https://devforum.roblox.com/t/pigeon-next-gen-networking-module/4760807)) | `--!strict` | Not buffer-schema; middleware-centric |
| Packeteer | Schema "defined using Luau types" | Early MVP ([thread](https://devforum.roblox.com/t/packeteer-a-simple-yet-powerful-type-safe-networking-library/4739399)) **[UNVERIFIED]** | | |
| flamework-binary-serializer | **TS transformer** that generates a serializer from a TS type | 0.7.0, 2025-10 ([npm](https://www.npmjs.com/package/@rbxts/flamework-binary-serializer), [repo](https://github.com/Fireboltofdeath/flamework-binary-serializer)) | Best TS story of any lib | Prior art for a compile-time TS path (§5.4) |

### 1.2 Blink (IDL)

Syntax, quoted from [types](https://github.com/1Axen/blink/blob/main/docs/pages/language/4-types.mdx) and [events](https://github.com/1Axen/blink/blob/main/docs/pages/language/5-events.mdx):
```
option Typescript = true
type Health = u8(0..100)
type Username = string(3..20)?
map Map<K, V> = {[K]: V}
enum MouseEvent = "Type" { Move { Delta: vector, Position: vector }, Click { Button: enum { Left, Right, Middle }, Position: vector } }
type MyCFrame = CFrame<i16, f16>
type VectorU8 = vector<u8>
type Player = Instance(Player)
export struct MyInterface = { field: u8 }      -- exports Read/Write for ECS replication
event MyEvent { From: Server, Type: Reliable, Call: SingleAsync, Data: (u8, u16, u32) }
function MyFunction { Yield: Coroutine, Data: f64, Return: f64 }
scope ExampleScope { ... }                      -- namespaces; imports also supported
```
- **Call modes:** `SingleSync | ManySync | SingleAsync | ManyAsync | Polling` (`Event.Iter()`). The docs warn that yielding or erroring in Sync handlers causes "undefined and sometimes game-breaking behaviour" ([events](https://github.com/1Axen/blink/blob/main/docs/pages/language/5-events.mdx)).
- **Options** ([options](https://github.com/1Axen/blink/blob/main/docs/pages/language/1-options.mdx)): `Casing`, `TypesOutput`, `Typescript`, `UsePolling`, `FutureLibrary`/`PromiseLibrary`, `WriteValidations` (off by default and primitives only), `ManualReplication` (exposes `StepReplication`), `RemoteScope` (prefixes remote names for packages).
- **Mechanics** ([Templates](https://github.com/1Axen/blink/blob/main/src/Templates/Server.luau), [Generator](https://github.com/1Axen/blink/blob/main/src/Generator/init.luau)):
  - One reliable and one unreliable remote. Reliable events are batched per player and flushed on `RunService.Heartbeat`.
  - Unreliable events are **fired immediately, one remote call per fire**, with no batching.
  - Instances travel as a **side array next to the buffer** (`Reliable:FireClient(Player, Buffer, Send.Instances)`). The buffer holds a cursor into that array ([Prefabs.luau](https://github.com/1Axen/blink/blob/main/src/Generator/Prefabs.luau)).
  - A non-optional instance that arrives nil is a deserialization error that drops the rest of the batch ([types doc](https://github.com/1Axen/blink/blob/main/docs/pages/language/4-types.mdx)).
- **Open issues show the gaps** ([issues](https://github.com/1Axen/blink/issues)):
  - #101 non-deterministic ids (derived from the compile timestamp)
  - #104 fixed-point/quantized numerals
  - #105 `@bitpack` for bools and small unions
  - #108 compile-time payload-size analysis against the unreliable limit
  - #107 invoke timeout and cancel-on-leave
  - #102 error policy for invalid incoming data
  - #45 "Server DOS attack via large buffer input"
  - #12 "Plugin lags with larger config files"
- **Benchmarks** ([Benchmarks.md](https://github.com/1Axen/blink/blob/main/benchmark/Benchmarks.md), 2025-04-30; 1000 fires per frame of identical data):
  - Entities: Roblox 16 FPS, Blink 42, Zap 39, ByteNet 32.
  - Booleans: Blink 97, Zap 52, ByteNet 35.
  - Kbps is roughly 42 for all buffer libs against roughly 560,000 for raw Roblox. That gap mostly measures **engine compression of repeated data** (§2.2), not codec quality.

### 1.3 Zap (IDL)

Syntax ([events](https://github.com/red-blox/zap/blob/0.6.x/docs/config/events.md), [types](https://github.com/red-blox/zap/blob/0.6.x/docs/config/types.md)):
```
event MyEvent = { from: Server, type: Reliable, call: ManyAsync, data: (Foo: boolean, Bar: u32, Baz: string.utf8) }
type RoundStatus = enum { Starting, Playing, Intermission }    -- becomes "Starting" | "Playing" | "Intermission"
map { [string]: u8 }   set { string }   u8[10..20]   string.binary(3..20)   Instance.BasePart   AlignedCFrame   vector(u8, f32)
```
- **Distinctive features:**
  - Named tuple params.
  - `string.utf8` vs `string.binary`.
  - `AlignedCFrame`: the 24 axis-aligned rotations sent as a 1-byte enum.
  - CFrame rotation sent as axis-angle and orthonormalized.
  - Runtime-checked OR-unions since 0.6.20.
  - `unknown` type.
  - `tooling` output: a standalone deserializer for profilers. Its format is shared with [PacketProfiler](https://github.com/red-blox/zap/blob/0.6.x/docs/usage/tooling.md).
  - `include_profile_labels` adds MicroProfiler labels.
  - `disable_fire_all` option.
- **Flush:** Zap flushes on Heartbeat at about 61 Hz. The docs warn that firing remotes above 60 Hz "can cause the server to have incredibly high network response times … servers essentially crash" (Jan 2024 note) ([options](https://github.com/red-blox/zap/blob/0.6.x/docs/config/options.md)).
- **Open issues** ([issues](https://github.com/red-blox/zap/issues)):
  - #225 the generated module needs sharding for large games, forcing a fork. This is a Luau register/local/constant-limit problem for single-file codegen.
  - #219 mediate throughput so the server can process all events.
  - #216 `Player` leak if Fire is called after PlayerRemoving.
  - #211 namespaces cannot see global types.
  - #67 24/40/48/56/64-bit integers.

### 1.4 ByteNet / Packet / QuickNet (runtime-schema family)

- **ByteNet 0.4 syntax** ([docs](https://ffrostfall.github.io/ByteNet/)):
  ```lua
  ByteNet.defineNamespace("example", function() return {
      vectorStringMap = ByteNet.definePacket({ value = ByteNet.dataTypes.map(ByteNet.dataTypes.vec3(), ByteNet.dataTypes.string()) }) } end)
  packets.vectorStringMap.sendToAll({...})
  ```
  - 0.5 (repo) renames to `define_packet`, `t.struct`, and so on. It types values through `export type function ValueFromDataType(data_type: type) return data_type:readproperty(types.singleton("__T")) end` with a phantom `read __T: T` field ([types.luau](https://github.com/ffrostfall/ByteNet/blob/master/src/types.luau)).
  - Complaints:
    - Map keys and values must be fixed types, and mixed tables are unsupported.
    - Packet-ID attribute names are limited to 100 characters.
    - CFrame bugs.
    - Batched unreliable sends exceeded the limit; the author's answer was "I plan on adding fragmenting automatically".
    - Sources: ([thread p4](https://devforum.roblox.com/t/bytenet-advanced-networking-library-w-buffer-serialization-strict-luau-absurd-optimization-and-rbxts-support-043/2733365?page=4)).
- **Packet syntax** ([thread](https://devforum.roblox.com/t/packet-networking-library/3573907)):
  ```lua
  Packet("PacketName", Packet.NumberS8, Packet.Vector3F32, Packet.Instance)
  Packet("Dictionary", {Key = Packet.NumberF32, AnotherKey = Packet.String})
  Packet("PacketName", Packet.NumberF16, Packet.String):Response(Packet.Boolean8)
  Packet("OptionalString", Packet.Any :: string?)
  ```
  - Features:
    - Per-heartbeat inbound data cap ("DDoS protection").
    - `ResponseTimeout`, default 10 s.
    - 16- and 24-bit floats.
    - 12/15/18-byte CFrames, compared with ByteNet's 24.
    - Strings at 1–8 bits per character.
  - Complaints ([p8](https://devforum.roblox.com/t/packet-networking-library/3573907?page=8)):
    - The default buffer type has a 255-byte cap (1-byte length).
    - "firing the same packet twice in a frame … drop ALL packets".
    - A reported vulnerability let clients resume server coroutines waiting on responses (fixed in 1.7).
- **QuickNet syntax:**
  ```lua
  QuickNet:register("SomeFunctionName", data.Color3, data.Vector3F32):Response(data.Boolean)
  QuickNet:register("SomeEvent4", {health = data.NumberU8, ...})
  ```
  - The usage API mirrors RemoteEvent (`event1:FireServer`, `.OnServerEvent:Connect`).
  - Claims: "60+ data types", batching "with action routing", rate limiting, and a "fast path".
  - Critique in replies: mirroring the RemoteEvent API "doesn't solve … duplicated endpoint declarations across client and server" ([thread](https://devforum.roblox.com/t/quicknet-v034-up-to-10x-faster-than-remoteevents-drop-in-networking-library/4624342)).

### 1.5 Warp, Squash, Red, BridgeNet2

- **Warp 1.1:**
  - Schema API: `Buffer.Schema.struct({ LongInteger = Buffer.Schema.u64 })` plus `custom_datatype(name, obj, writer, reader)`.
  - Types include f16 `vector3`, `cframe` (f32 position plus f16 rotation), `udim2`, `colorsequence`, `tweeninfo`, `font`, and more ([buffer.md](https://github.com/imezx/Warp/blob/master/docs/api/1.1/buffer.md)).
  - Events are string-named: `Server.Connect("ServerNotify", fn)` ([server.md](https://github.com/imezx/Warp/blob/master/docs/api/1.1/server.md)).
  - Flushes on `PostSimulation`. Uses Luau `const` ([Xor.luau](https://github.com/imezx/Warp/blob/master/src/Util/Xor.luau)).
- **Squash:**
  - Cursor API: `Squash.u8().ser(cursor, 243)`, `Squash.boolean().ser(cursor, true, false, ...)`.
  - Its value for us is the **wire-format reverse engineering** in §2.1 ([how.md](https://github.com/Data-Oriented-House/Squash/blob/main/docs/how.md)).
- **Red:** "single remote event with identifiers … obfuscates network data" ([repo](https://github.com/red-blox/Red)).
- **BridgeNet2:** "cuts out header data from RemoteEvent calls by 7 bytes" ([repo](https://github.com/ffrostfall/BridgeNet2)).

### 1.6 Notable 2026 idea: Warp's XOR-delta

[Xor.luau](https://github.com/imezx/Warp/blob/master/src/Util/Xor.luau) keeps the previous outgoing buffer per player and per direction.
- It sends either `KEYFRAME` (full) or `DELTA` (bytewise XOR against the previous frame) with an 8-bit sequence number.
- It sends a keyframe every 1 s (`KEYFRAME_INTERVAL = 1`). On a sequence gap it drops the stream until the next keyframe.
- Rationale: unchanged bytes become zeros, which the engine's zstd crushes.
- This is only sound on the **reliable, ordered** channel. Any loss or reorder breaks the chain, hence the keyframes.
- It is a cheap, schema-agnostic "delta vs previous" that leans entirely on engine compression.

### 1.7 Third-party benchmark that includes the current Lync

The QuickNet thread (2026-05) benchmarks 1000 fires per frame for 10 s and reports FPS / Kbps ([thread](https://devforum.roblox.com/t/quicknet-v034-up-to-10x-faster-than-remoteevents-drop-in-networking-library/4624342)):

| Library | Entities | Booleans | Strings | Numbers | Dictionary | Vector3 |
|---|---|---|---|---|---|---|
| Lync | 14.8 / 39.3 | 23.1 / 11.1 | 19.6 / **319.4** | 11.3 / **122.4** | 6.2 / **116.3** | 24.6 / **138.4** |
| Blink | 24.9 / 39.7 | 42.7 / 20.7 | 30.5 / 102.3 | 44.6 / 64.8 | 28.2 / 58.5 | 147 / 74.5 |
| Zap | 24.5 / 39.6 | 28.4 / 20.7 | 24.7 / 120.4 | 33.4 / 64.1 | 28.2 / 58.3 | 59.4 / 72.5 |
| QuickNet | 34.5 / 39.7 | 97.7 / 10.0 | 57.3 / 103.8 | 97.0 / 65.6 | 53.7 / 62.7 | 190.9 / 74.6 |

- **Takeaway:** in someone else's public benchmark, current Lync is the slowest of the buffer libs and uses about 2–3× the Kbps on strings, numbers, dictionaries and Vector3.
- Booleans are already bit-packed: 11 Kbps, against 20 for byte-per-bool libs.
- Caveat: identical data every frame means compression dominates Kbps.
- Call-response bench: Packet, Jolt, Zap and Blink crashed. Lync and ByteNet were "N/A".

### 1.8 Community sentiment (what people praise / hate)

- **Praised:**
  - Blink: "more active", scopes and imports ([thread, 2026-09](https://devforum.roblox.com/t/what-networker-should-i-use/4889485)).
  - Runtime libs: "don't have to regenerate code after changes", built-in rate limiting, familiar remote API ([same](https://devforum.roblox.com/t/what-networker-should-i-use/4889485)).
  - Packet: table support, rich quantized types ([p8](https://devforum.roblox.com/t/packet-networking-library/3573907?page=8)).
  - Oversized-packet dropping as built-in protection ([same thread](https://devforum.roblox.com/t/what-networker-should-i-use/4889485)).
- **Hated / complaints:**
  - Codegen friction: regenerate, the plugin lags on big configs ([Blink #12](https://github.com/1Axen/blink/issues)), and Zap's single giant generated file ([Zap #225](https://github.com/red-blox/zap/issues)).
  - Benchmarks on "unrealistic scenarios" ([thread](https://devforum.roblox.com/t/best-network-library/3667044)).
  - "you can do far better than any one size fits all public networking lib", with one user citing about 700 kb/s on Blink against 45 kb/s custom ([thread](https://devforum.roblox.com/t/what-networker-should-i-use/4889485)).
  - A persistent "libraries are bloat" troll faction ([Pigeon thread](https://devforum.roblox.com/t/pigeon-next-gen-networking-module/4760807)).
  - Security holes: Packet coroutine resume, Blink DOS #45.
  - Silent drops over the unreliable limit.

---

## 2. Roblox networking facts

### 2.1 Per-call overhead and wire format

- **Wire format** (reverse-engineered by Squash, [binary.md](https://github.com/Data-Oriented-House/Squash/blob/main/docs/RemoteEvents/binary.md)):
  - Each RemoteEvent call is a record: subtype `0x0701` (2 B), remote id (3 B), "enigma" `0x000b` (2 B), direction id (1 B), plus 5 B of "user info" client→server, then an argument count (1 B) and arguments.
  - Multiple calls in a short window are **merged into one 0x83 packet with a 0x00 delimiter**.
  - Strings, arg counts and the like use VLQ lengths.
- **Measured cost** ([benchmarks.md](https://github.com/Data-Oriented-House/Squash/blob/main/docs/RemoteEvents/benchmarks.md)):
  - An empty `()` fire at 60 Hz costs about 0.69 KB/s above baseline, which is about **11–12 B per call**.
  - A number costs 9 B (1 B tag + f64). A boolean costs about 2 B.
  - Every *separate argument* costs a type tag.
- **Forum figures** **[UNVERIFIED]**: 9 B (S→C) and 14 B (C→S) overhead per reliable call ([ByteNet thread](https://devforum.roblox.com/t/bytenet-advanced-networking-library-w-buffer-serialization-strict-luau-absurd-optimization-and-rbxts-support-043/2733365?page=4)). Per-type costs: Vector3 about 13 B, instance ref 6 B ([URE thread p10](https://devforum.roblox.com/t/introducing-unreliableremoteevents/2724155?page=10)).
- **Implication:** one call per player per frame carrying `(buffer, instances?)` is optimal. Never pass multiple top-level args.

### 2.2 Does Roblox compress remote payloads? Effectively yes, for buffers, but undocumented

- **Docs:** no Creator doc mentions remote compression ([remote events guide](https://create.roblox.com/docs/scripting/events/remote), [buffer](https://create.roblox.com/docs/reference/engine/libraries/buffer)).
- **Strong circumstantial evidence:**
  1. Blink's bench: 1000 × 600 B identical payloads per frame show up as about 42 Kbps ([Benchmarks.md](https://github.com/1Axen/blink/blob/main/benchmark/Benchmarks.md)).
  2. An unreliable test sent 10,000 B of repeated data, while random data hit the limit ([doc issue](https://devforum.roblox.com/t/incorrect-size-of-data-being-sent-limit-specified-when-using-unreliableremoteevent/3048788)).
  3. Pyseph (2023): "buffers are compressed past a certain size" with "an unknown limit" ([URE p10](https://devforum.roblox.com/t/introducing-unreliableremoteevents/2724155?page=10)).
  4. PacketProfiler v3 (2026-09) states "Remote buffer sizes account for Roblox's transparent Zstandard compression" ([README](https://github.com/Pyseph/PacketProfiler)). Its size counter models this as: buffers **≥ 100 bytes** are estimated with `EncodingService:CompressBuffer(buf, Zstd, 0)`, smaller ones are raw ([BufferSize.luau](https://github.com/Pyseph/RemotePacketSizeCounter/blob/main/src/BufferSize.luau)).
- **Still [UNVERIFIED]:** the exact threshold, level (forum guess "around level 3": [thread](https://devforum.roblox.com/t/high-performance-networking-let-engine-handle-it-or-use-custom-entropy-coder/4633845)), and whether compression is per-buffer or per-packet. The modelling treats it as **per buffer value**.
- **EncodingService** (released 2025-11-07, staff WheretIB, [thread](https://devforum.roblox.com/t/a-method-to-directly-compress-a-buffer/3261716)):
  - `CompressBuffer(input, Enum.CompressionAlgorithm.Zstd, level=1)`, `DecompressBuffer`, `GetDecompressedBufferSize`, `ComputeBufferHash` (Blake2b/Blake3/Md5/Sha1/Sha256), Base64.
  - These are thread-safe, i.e. callable from Parallel Luau (API dump 0.741 via the `luau.py api` tool).
  - **No dictionary parameter.**
- **Simulation [MEASURED, Python zstd, each frame compressed independently, 60 entities × 300 ticks]:**

  | Encoding | Raw B/frame | zstd-3 | zstd + trained dict |
  |---|---|---|---|
  | aligned f32 | 1020 | 998 | 744 |
  | aligned quantized u16 | 660 | 669 | 619 |
  | bit-packed quantized | 533 | 543 | 547 |
  | **byte-aligned delta (zigzag varint)** | 360 | **191** | 190 |
  | **bit-packed delta + dirty mask** | **177** | 186 | 183 |

  - **Single-frame zstd does almost nothing on quantized snapshot data, and bit-packing makes it slightly worse** (frame header overhead).
  - **Byte-aligned deltas + engine zstd ≈ hand bit-packed deltas** (191 vs 177 B), at a fraction of the Luau CPU cost.
- **Event-stream simulation [MEASURED]** (mixed inventory/damage/sfx events, strings from a 70-item vocabulary):

  | Encoding | Raw B/frame | zstd-3 | zstd + dict |
  |---|---|---|---|
  | inline strings | 184 | 134 | 64 |
  | **interned ids** | **49** | 55 | 50 |

  Static interning beats engine zstd by about 2.7×. An offline dictionary would close most of the gap, but the engine gives us no dictionary hook.

### 2.3 Limits, budgets, rates, ordering

- **UnreliableRemoteEvent:**
  - Payload limit **1000 bytes** (raised from 900 on 2025-03-12, staff LittleWing1122, [announcement](https://devforum.roblox.com/t/introducing-unreliableremoteevents/2724155)). The docs say Roblox "may drop" messages whose payload exceeds 1,000 bytes ([guide](https://create.roblox.com/docs/scripting/events/remote)).
  - Whether the limit applies pre- or post-compression is **[UNVERIFIED]**. Evidence suggests post-compression ([thread](https://devforum.roblox.com/t/incorrect-size-of-data-being-sent-limit-specified-when-using-unreliableremoteevent/3048788)).
  - "No ordering guarantee between UnreliableRemoteEvents and anything else". They are "not currently prioritized over other traffic". Events with no listener are discarded, not queued ([announcement](https://devforum.roblox.com/t/introducing-unreliableremoteevents/2724155)).
- **Reliable RemoteEvent:**
  - Ordered, but there is no relation to property replication.
  - "Remote events aren't synchronized with the shared timeline". A dev reports they are off by about 40–50 ms against physics under Server Authority, and Roblox is "looking at … a time-locked event API" ([full-release thread, 2026-07-09](https://devforum.roblox.com/t/full-release-ship-fair-and-competitive-games-with-server-authority/4727993)).
- **Bandwidth budget:**
  - There is **no current official per-player figure**. The old Dev Hub "50 KB/s per player" text was removed. Threads say it is soft and was exceeded in practice ([thread](https://devforum.roblox.com/t/does-the-50kbps-data-limit-only-apply-to-remote-events-or-also-server-side-object-creation/580567)) **[UNVERIFIED]**.
  - Official perf docs only say: replicate on change, throttle input-driven sends, and send less. The relevant MicroProfiler scopes are `ProcessPackets` (receive) and "Allocate Bandwidth and Run Senders" (send) ([improve](https://create.roblox.com/docs/performance-optimization/improve)).
- **Send timing:**
  - Officially undocumented. Old staff statement: replication steps target 30 Hz and queue if they can't fit ([thread](https://devforum.roblox.com/t/calling-remotes-right-before-network-replication/149120)).
  - Folklore: 20 Hz send, 60 Hz step **[UNVERIFIED]**.
  - Libraries flush on Heartbeat/PostSimulation, so remotes fired there go out in that frame's network job.
  - Zap's warning about >60 Hz fire rates crashing servers ([options](https://github.com/red-blox/zap/blob/0.6.x/docs/config/options.md)) argues for **one flush per frame, capped at 60 Hz**.
- **Instances:**
  - Cannot be put in buffers.
  - Values not visible to the receiver arrive as nil ([guide](https://create.roblox.com/docs/scripting/events/remote)).
  - Every buffer lib passes them as a second remote argument (an array) and stores an index in the buffer (Blink `SendInstances`, flamework-binary-serializer "blobs" [README](https://github.com/Fireboltofdeath/flamework-binary-serializer)). Streaming makes nil common, so the field must be optional or carry a policy.
- **Buffers:** max 1 GiB. Identity is not preserved (copied). A buffer can't be used from multiple Actors ([buffer docs](https://create.roblox.com/docs/reference/engine/libraries/buffer)).
- **Parallel Luau:** `RemoteEvent:FireClient` is `Unsafe`, so sending must be serial. `EncodingService` and `buffer` work are Safe (API dump via `luau.py api`).

### 2.4 Roblox's 2025–2026 landscape changes

- **Server Authority:**
  - Timeline: Early Access → Studio Beta → Client Beta (publishable, 2026-04-30) → **Full Release 2026-07-09**, opt-in ([full release](https://devforum.roblox.com/t/full-release-ship-fair-and-competitive-games-with-server-authority/4727993), [client beta](https://devforum.roblox.com/t/client-beta-publish-test-your-server-authoritative-experiences/4606949)).
  - It requires NextGenerationReplication (beta), the Input Action System, Deferred signals, StreamingEnabled and UseFixedSimulation.
  - Prediction, rollback and resimulation are built in. Predicted code runs via `RunService:BindToSimulation(fn, StepFrequency=Hz30, priority)`.
  - Under Server Authority, "Input Actions … [are] the only way to send data from Client → Server that the server accepts" ([deep dive, 2026-05-08](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565)). **This matters:** in SA games, client→server gameplay input bypasses remotes.
  - Server-side rewind (lag-compensated hits) is not built in yet ("you can implement this yourself").
  - Misprediction thresholds quantize positions at 0.1 studs.
- **Studio network simulation** (2026-06-02): inbound/outbound latency, jitter, and loss capped at 0.5%, on client→server traffic only. Bandwidth caps are "planned". Scriptable via `NetworkSettings` (`Inbound/OutboundNetworkMinDelayMs`, `…JitterMs`, `…LossPercent`) ([announcement](https://devforum.roblox.com/t/expanding-network-simulation-in-studio/4665487)).
- **MicroProfiler Network plugin** (2025-08-25): traffic graphs and an events window, in dumps only. There is no per-remote byte breakdown and **no script/plugin API** ([announcement](https://devforum.roblox.com/t/announcing-new-microprofiler-features-for-network-profiling/3899251)).
- **EncodingService** (2025-11): see §2.2.

---

## 3. Luau capabilities (codecs and typing)

### 3.1 Library features

- **`buffer.readbits/writebits`:**
  - Status: "Implemented" ([RFC](https://github.com/luau-lang/rfcs/blob/master/docs/function-buffer-bits.md)). Documented on Roblox ([buffer docs](https://create.roblox.com/docs/reference/engine/libraries/buffer)). Added in 2025 ([Luau 2025 runtime recap](https://luau.org/news/2025-12-19-luau-recap-runtime-2025)).
  - Semantics: 0–32 bits, LSB-first little-endian, unsigned.
  - **[MEASURED]** in 0.740 they are **not lowered by native codegen**:
    - `writebits` 10-bit costs 21.6 ns/item native vs 35.6 interpreted.
    - A manual `bit32` accumulator + `writeu32` costs **6.7 ns native** vs 35.4 interpreted.
    - For hot paths, a hand-rolled accumulator beats `readbits/writebits` about 3× when native. They tie when interpreted.
- **`vector`:** a native value type with a library. Native codegen lowers `vector.dot` and FMA for lerp. Load-store propagation now covers buffers ([recap](https://luau.org/news/2025-12-19-luau-recap-runtime-2025)). `Vector3` *is* `vector` on Roblox: no allocation, unlike CFrame/Color3 userdata (Luau skill reference, Roblox perf notes).
- **`const`:**
  - Status: RFC "Implemented" ([RFC](https://github.com/luau-lang/rfcs/blob/master/docs/const-keyword.md)).
  - Live in Roblox Studio and game without flags since about March–April 2026. There was no announcement; it was found by users ([thread 2026-04](https://devforum.roblox.com/t/feedback-on-variables/4590572), [2026-06](https://devforum.roblox.com/t/constants-are-added-to-luau/4680305)).
  - `if local`/`if const` is in Studio beta as of 2026-10 ([announcement](https://devforum.roblox.com/t/beta-if-local-statements-and-expressions/4918297)).
- **`integer` (64-bit, `42i`) and `export local/const/function`:**
  - Both are implemented in the Luau 0.740 CLI behind flags (I verified that `123i` works in the CLI) ([RFC](https://github.com/luau-lang/rfcs/blob/master/docs/type-long-integer.md), [export RFC](https://github.com/luau-lang/rfcs/blob/master/docs/export-keyword.md)).
  - **Not confirmed live on Roblox.** A 2026 bug thread reports export syntax was pulled from the grammar ([thread](https://devforum.roblox.com/t/exported-functions-and-variables-no-longer-supported-by-luau-grammar/4831433)).
  - Do not depend on either yet. The future `buffer.readinteger` would make u64/i64 fields cheap.
- **`string.pack/unpack`:** available ([RFC](https://github.com/luau-lang/rfcs/blob/master/docs/function-string-pack-unpack.md)), but slower than buffers for our use.
- **`loadstring`:** server-only, gated by `ServerScriptService.LoadStringEnabled` (NotScriptable, so a place setting). Never on clients (API dump; [LuaGlobals docs](https://create.roblox.com/docs/reference/engine/globals/LuaGlobals) **[MEMORY]**). **Runtime codegen via loadstring is therefore not a viable universal strategy.** Codegen must be offline or closure-composition.
- **Parallel Luau:** `require` is not allowed in the parallel phase. Buffers can't be shared across Actors. Remote firing is serial-only. Possible parallel work: per-player encode or compress into fresh buffers, then `task.synchronize()` to fire (Luau skill reference, Roblox; [buffer docs](https://create.roblox.com/docs/reference/engine/libraries/buffer)).

### 3.2 Native codegen

- **Scope:** native codegen is **server and Studio-plugin only. Clients run the interpreter**. The docs say "server-side scripts … can be compiled directly into the machine code" ([creator-docs native-code-gen.md](https://github.com/Roblox/creator-docs/blob/main/content/en-us/luau/native-code-gen.md)). There was "not available on the clients yet" in 2024 ([update](https://devforum.roblox.com/t/luau-native-code-generation-preview-update/2961746)) and an open feature request in 2025 ([request](https://devforum.roblox.com/t/enable-native-for-clients/3170510)). I found nothing in 2026 changing this.
- **Limits:** there is a per-game native code size budget (`debug.dumpcodesize()`). Annotated `buffer`/`number`/`vector` parameters avoid guards. Gains come from arithmetic and buffer loops ([docs](https://github.com/Roblox/creator-docs/blob/main/content/en-us/luau/native-code-gen.md)).
- **[MEASURED] ns per item, 1000-item frame (interpreter / native):**

  | Operation | Interpreter | Native |
  |---|---|---|
  | `writeu16` | 23.5 | 4.8 |
  | `readu16` | 14.9 | 2.9 |
  | LEB128 write | 81 | 17 |
  | LEB128 read | 81 | 12 |
  | static-Huffman LUT decode (manual bit window) | 52.7 | 12.2 |
  | static-Huffman LUT decode via `readbits` | 58.5 | 44.6 |
  | rANS 12-bit decode | 79 | 25 |
  | rANS 12-bit encode | 89 | 28 |
  | LZ4-style greedy match search, per byte | 54 | 29 |

  - **Design consequence:** the *client* decode path is always interpreted, at about 15–80 ns per field op on desktop and probably 3–5× slower on low-end mobile **[UNVERIFIED multiplier]**.
  - A 2 KB frame decoded with an entropy coder is about 0.1–0.2 ms per frame on desktop interpreter. That is affordable but not free.

### 3.3 Type system

- **New solver status:**
  - **General Release ~2025-11-20** for nocheck/nonstrict scripts. **`--!strict` scripts stay on the old solver unless `Workspace.UseNewLuauTypeSolver = Enabled`**. As of Feb 2026, strict users were "not migrated yet" ([GA thread](https://devforum.roblox.com/t/general-release-luau%E2%80%99s-new-type-solver/4084991)).
  - luau-lsp still defaults `luau-lsp.fflags.enableNewSolver = false` ([package.json](https://github.com/JohnnyMorganz/luau-lsp/blob/main/editors/code/package.json)).
- **User-defined type functions** ([RFC](https://github.com/luau-lang/rfcs/blob/master/docs/user-defined-type-functions.md)):
  - They run in a sandboxed VM at analysis time. They can inspect tables, unions, singletons and functions, and build new types (`types.newtable`, `setproperty`, `unionof`).
  - They cannot see runtime values or outer locals, and return exactly one type (no type packs).
  - Follow-up RFCs: generics in type functions, `thread`/`buffer` support, the `extern` tag ([rfcs/docs](https://github.com/luau-lang/rfcs/tree/master/docs)).
  - **[MEASURED]** in luau-analyze 0.740 (new solver), a type function mapping `struct2({x = u8, name = str})` to `Codec<{x: number, name: string}>` works and rejects wrong field types.
  - The **old solver rejects it entirely** ("read keyword is illegal", "This syntax is not supported", "Unknown type 'Infer'").
- **Consequence:**
  - A runtime-schema library whose payload types depend on type functions gives *no or broken types* to strict-mode Roblox users not opted into the new solver, and to default luau-lsp.
  - Generated code with concrete type aliases works on both solvers. **This is the strongest argument for an offline compiler.**
- **Other features:**
  - Explicit type instantiation `f<<T>>()` is implemented ([RFC](https://github.com/luau-lang/rfcs/blob/master/docs/explicit-type-parameter-instantiation.md)).
  - `read`/`write` property modifiers ([RFC](https://github.com/luau-lang/rfcs/blob/master/docs/property-readonly.md)).
  - Classes RFC exists, gated off ([RFC](https://github.com/luau-lang/rfcs/blob/master/docs/syntax-classes.md)).

---

## 4. Compression techniques — what pays at Luau speeds for 50–2000 B frames

Grounding: per-call overhead is about 11 B (§2.1). Engine zstd is applied to buffers of roughly 100 B and up (§2.2, unverified). Client decode is interpreted (§3.2).

| Technique | Verdict | Why |
|---|---|---|
| Schema-driven fixed widths (u8/u16/i16, f16/f24) | **Always** | Free, and it is the baseline of every competitor |
| Range-bounded ints `u8(0..100)` and quantized floats `f32(-1024..1024, 0.01)` (fixed-point) | **Always; first-class in the schema** | Blink has been asked for this (#104). Gaffer gets position 96→50 bits this way ([snapshot compression](https://gafferongames.com/post/snapshot_compression/)) |
| Bit packing of bools, optionals, small enums, presence masks | **Yes, for headers and masks; selectively for fields** | Bools at 1 bit (FBS `Packed<T>` [README](https://github.com/Fireboltofdeath/flamework-binary-serializer)). But a bit-packed payload is incompressible by engine zstd (§2.2 sim), and `readbits` is slow. Pack *masks and tags* into a byte-aligned prefix and keep bulk fields byte-aligned |
| Zigzag + varint (LEB128) | **Yes, for lengths, ids and deltas** | Standard ([protobuf encoding](https://protobuf.dev/programming-guides/encoding/) **[MEMORY]**). 12–17 ns native, about 80 ns interpreted per value. A prefix-length varint (first byte gives length, SQLite4-style **[MEMORY]**) avoids the per-byte loop and is better for the interpreted client |
| Smallest-three quaternions | **Yes, for rotation-heavy state** | 29 bits (2+3×9) vs 128 ([Gaffer](https://gafferongames.com/post/snapshot_compression/)). Packet ships 12/15/18-B CFrames ([thread](https://devforum.roblox.com/t/packet-networking-library/3573907)). Zap's axis-aligned CFrame uses 1 B ([types](https://github.com/red-blox/zap/blob/0.6.x/docs/config/types.md)) |
| Octahedral unit vectors (oct16/oct24) | **Yes, as a `direction` type** | Best quality per bit for normals and look vectors ([Cigolle et al., JCGT 2014](https://jcgt.org/published/0003/02/01/) **[MEMORY]**). Cheap math |
| Yaw-only angle as u8/u16 | **Yes** | Most characters only need yaw |
| Delta against acknowledged baseline + per-field dirty masks | **Yes, the single biggest win for replicated state** | Quake 3 keeps 32 snapshots per client, deltas against the last acked one, and falls back to a full update ([Sanglard](https://fabiensanglard.net/quake3/network.php)). Gaffer: unchanged entity = 1 bit ([snapshot compression](https://gafferongames.com/post/snapshot_compression/), [state sync](https://gafferongames.com/post/state_synchronization/)). On Roblox the **reliable** channel is ordered, so "delta vs last sent" needs no acks there. Acked baselines are only needed for state over **unreliable** |
| XOR/subtract delta vs previous frame + engine zstd (Warp) | **Yes, as a cheap generic mode for reliable state streams** | My sim: byte-aligned delta + zstd ≈ 191 B vs 177 B for a hand bit-packed delta. Near-zero Luau CPU |
| String interning / static dictionaries | **Yes; a high-value compile-time feature** | Sim: 184 B inline → 49 B interned, vs 134 B with zstd. Schema `enum`s cover static vocabularies. A per-session runtime intern table (send string once, then id) covers dynamic ones, but it needs reliable ordering |
| Static Huffman with offline-trained tables | **Niche; possibly for unreliable payloads under 100 B, where the engine doesn't compress** | Quake 3 did exactly this: `msg_hData[256]` byte frequencies "from an actual game" seed its Huffman trees ([msg.c](https://github.com/ioquake/ioq3/blob/main/code/qcommon/msg.c)). Decode costs about 12 ns/sym native, 53 interpreted. Gains on already-quantized fields are small |
| rANS/tANS with precomputed tables | **Optional plugin, not core** | A forum user saw rANS with profiled tables beat zstd-L1 by about 100 B on a 1000-B packet ([thread](https://devforum.roblox.com/t/high-performance-networking-let-engine-handle-it-or-use-custom-entropy-coder/4633845)). Cost is 25–90 ns/sym, and it double-compresses with engine zstd. Theory: [Duda 2013](https://arxiv.org/abs/1311.2540), [Giesen rANS notes](https://fgiesen.wordpress.com/2014/02/02/rans-notes/) **[MEMORY]** |
| Arithmetic/range coding (adaptive) | **No** | Interpreter cost is about 2× rANS, and adaptive models need per-symbol state |
| LZ-family in Luau | **No** | 30–55 ns/byte just for match search. Engine zstd already does LZ and entropy coding for buffers of roughly 100 B and up |
| `EncodingService:CompressBuffer` explicitly | **Rarely** | Only to measure or estimate in dev tools, or for unreliable payloads that must fit 1000 B *before* send if the limit turns out to be pre-compression **[UNVERIFIED]**. Otherwise the engine does it for free |

**Where an offline compile/training step genuinely pays off:**
1. **String and enum vocabularies:** find literal strings in traffic or code and promote them to ids. This is the biggest measured win.
2. **Per-field range and precision inference** from recorded traffic, emitted as schema *suggestions* rather than silent changes. It finds `u32` fields that only ever hold 0..300.
3. **Field ordering and grouping** so that rarely-changing fields cluster, which improves dirty-mask efficiency and zstd matches.
4. **Optional static Huffman/rANS tables for small (<100 B) unreliable packets**, where engine compression doesn't apply. Make it opt-in, keyed by schema hash.
5. **Payload-size proofs:** compute worst-case encoded size per event at compile time. Reject unreliable events that can exceed 1000 B, or auto-route them to reliable/fragmented sends (Blink #108).

---

## 5. Tooling / extension ecosystem

### 5.1 Studio plugins

- **Network stats access:**
  - Plugins can read only aggregate `Stats.DataSendKbps/DataReceiveKbps/PhysicsSend/ReceiveKbps` (API dump).
  - There is no per-remote engine API. The MicroProfiler network view has no API ([announcement](https://devforum.roblox.com/t/announcing-new-microprofiler-features-for-network-profiling/3899251)).
  - Per-remote insight therefore comes from **library-side instrumentation**.
- **PacketProfiler v3** (2026-09) is the de-facto inspector ([repo](https://github.com/Pyseph/PacketProfiler)):
  - Public `RegisterLayer({Id, Name, Start = function(ctx) ctx.Emit({Name, Size, Data, Metadata}) end})` for custom libraries.
  - Bridges in-game to the plugin via `PluginConnectionService`.
  - Accepts Zap's tooling-deserializer format ([zap tooling](https://github.com/red-blox/zap/blob/0.6.x/docs/usage/tooling.md)).
  - Estimates zstd size.
- **Other plugin hooks:**
  - `ScriptEditorService:RegisterScriptAnalysisCallback` / `RegisterAutocompleteCallback` (PluginSecurity) let a Studio plugin add diagnostics and autocomplete in the built-in editor. Usable for schema-aware hints without luau-lsp (API dump).
  - `ScriptEditorService:UpdateSourceAsync` lets a plugin write generated code (Blink's plugin does this; it needs script-injection permission, [Blink plugin doc](https://github.com/1Axen/blink/blob/main/docs/pages/getting-started/4-plugin.mdx)).
- **Network simulation** via `NetworkSettings` properties (client→server only; [announcement](https://devforum.roblox.com/t/expanding-network-simulation-in-studio/4665487)). A Lync test harness can script latency and loss scenarios.
- **Profiling labels:** `debug.profilebegin/profileend` labels show in MicroProfiler and ScriptProfiler ([ScriptProfiler](https://devforum.roblox.com/t/scriptprofiler-full-release/2025360)). Zap already has `include_profile_labels`.
- **Studio Script Sync:** native file↔Studio sync, now beta ([announcement](https://devforum.roblox.com/t/studio-script-sync-now-in-beta/4065468), [docs](https://create.roblox.com/docs/scripting/sync)). It lowers the barrier for file-based codegen for non-Rojo users.

### 5.2 luau-lsp

- **Source-transform plugins:** an experimental feature since about 1.65 (2026-04). Luau scripts return `{ transformSource = function(source, context) return edits end }` and run before type checking, with position mapping preserved. Settings are `luau-lsp.plugins.enabled/paths/timeoutMs/fileSystem.enabled` ([Plugin README](https://github.com/JohnnyMorganz/luau-lsp/blob/main/src/Plugin/README.md), [CHANGELOG](https://github.com/JohnnyMorganz/luau-lsp/blob/main/CHANGELOG.md)). **A Lync luau-lsp plugin could inject concrete types for schemas at edit time without a build step.** It is experimental and the API "subject to change".
- Also: definition files, a Studio companion plugin, the latest version 1.70.1 (2026-09-27), and the new solver off by default ([package.json](https://github.com/JohnnyMorganz/luau-lsp/blob/main/editors/code/package.json)).

### 5.3 Toolchain state (latest tags checked 2026-10-15 via `git ls-remote`)

| Tool | Status |
|---|---|
| Rojo | v7.7.1 ([repo](https://github.com/rojo-rbx/rojo)) |
| Rokit | v1.2.0; now lists `luau-lang/lute` as a well-known tool ([repo](https://github.com/rojo-rbx/rokit)) |
| Wally | 0.4.0-alpha.1, active again in Oct 2026 ([repo](https://github.com/UpliftGames/wally)) |
| pesde | v0.7.4 ([repo](https://github.com/pesde-pkg/pesde)). Blink ships a `pesde.toml` |
| darklua | v0.19.0, bundling respects the closest `.luaurc` ([repo](https://github.com/seaofvoices/darklua)) |
| Lune | v0.11.0 ([repo](https://github.com/lune-org/lune)) |
| **Lute** | **1.0 released** (nightlies v1.0.1, Oct 2026), Roblox's official general-purpose Luau runtime. Its `std` is meant to be shared with Roblox runtimes ([repo](https://github.com/luau-lang/lute)). The natural host for a Luau-written Lync compiler/CLI |

Blink proves the "compiler written in Luau, runs in CLI *and* Studio plugin" model ([repo](https://github.com/1Axen/blink)).

### 5.4 roblox-ts

- **Transformer plugins:**
  - roblox-ts 3.0.0 (npm latest, 2024-09-12) loads `compilerOptions.plugins[].transform` from tsconfig and runs them before emit ([getPluginConfigs.ts](https://github.com/roblox-ts/roblox-ts/blob/master/src/Project/transformers/getPluginConfigs.ts), [compileFiles.ts](https://github.com/roblox-ts/roblox-ts/blob/master/src/Project/functions/compileFiles.ts)).
  - **Compile-time codegen from TS types is proven:** flamework-binary-serializer turns `interface Data { u8: DataType.u8; vector: Vector3; union: {...}|{...}; packed: DataType.Packed<T> }` into a serializer via the Flamework transformer ([README](https://github.com/Fireboltofdeath/flamework-binary-serializer)). Serio does the same ([listing](https://awesome.ecosyste.ms/projects/github.com%2Fr-unic%2Fserio)).
  - Drawback: a dependency on Flamework's transformer, and transformer setup friction.
- **Blink and Zap** emit `.d.ts` beside the Luau output (Blink `option Typescript`, Zap `typescript`, `typescript_max_tuple_length`, `typescript_enum`) ([Blink opts](https://github.com/1Axen/blink/blob/main/docs/pages/language/1-options.mdx), [Zap opts](https://github.com/red-blox/zap/blob/0.6.x/docs/config/options.md)).

### 5.5 State replication neighbours

These are not buffer libraries but compete for the "replicated state" feature:
- Replica ([repo](https://github.com/headjoe3/Replica)).
- Charm with its sync module ([charm](https://github.com/littensy/charm)) **[UNVERIFIED details]**.
- Pigeon `StagedTable` ([thread](https://devforum.roblox.com/t/pigeon-next-gen-networking-module/4760807)).

---

## 6. Implications for Lync v5 (opinionated)

1. **One schema, two front-ends, one IR.**
   - Accept (a) a Luau-embedded runtime schema DSL and (b) an optional offline compiler that reads the *same* schema module (run under Lute/Lune or a Studio plugin) and emits specialized Luau + `.d.ts`.
   - The runtime path gives "no regenerate" DX, which users praise in QuickNet ([thread](https://devforum.roblox.com/t/what-networker-should-i-use/4889485)).
   - The compiled path gives concrete types on *both* Luau solvers plus straight-line codecs.
   - Do not invent a separate IDL file format. Blink and Zap own that niche, and their pain points (regen, plugin lag, giant generated files) are exactly what an embedded DSL avoids.
2. **Typing strategy:**
   - Runtime path: phantom `read __T: T` plus type functions for the new solver.
   - Old solver and default luau-lsp, which reject type functions (§3.3): **ship a compiled `types` artifact** and document `UseNewLuauTypeSolver`.
   - Never let payload types silently degrade to `any`. Fail loudly in docs and lint.
3. **Generated code must shard** per namespace or module (Zap #225) and use deterministic, content-hashed ids (Blink #101). That lets ids be stable across builds and mismatches be detected at handshake via a schema hash (`EncodingService:ComputeBufferHash`).
4. **Frame model:**
   - One reliable `FireClient(player, buffer, instances?)` per player per frame. Flush in PostSimulation/Heartbeat, capped at 60 Hz (Zap warning).
   - Never use multiple top-level args (each costs a tag and VLQ; §2.1).
   - Unreliable traffic is *batched* too (Blink doesn't), split at **≤ 1000 B with a configurable safety margin**. Single unreliable messages that could exceed the limit are refused at schema-compile time.
5. **Design for engine zstd instead of fighting it:**
   - Keep bulk payloads **byte-aligned**.
   - Put bit-packed bools, optionals and enum tags into compact header/mask bytes.
   - Prefer byte-aligned deltas over bit-level deltas on reliable streams.
   - My sim shows byte-aligned delta + zstd ≈ a hand bit-packed delta at far lower CPU. Bit-packing bulk data actively defeats the engine compressor.
6. **First-class quantization types:**
   - `f16/f24`, fixed-point `num(min, max, step)` and bounded ints.
   - `angle8/16`, `direction` (octahedral), `quat` (smallest-three 29/39/48-bit presets), `CFrame<pos, rot>` presets including axis-aligned.
   - These are the features open Blink and Zap issues ask for (#104, #105, #67).
7. **Replicated state = delta + dirty masks, with two transports:**
   - Reliable: delta vs last-sent, since ordering makes acks unnecessary. Warp's XOR-delta with periodic keyframes is a zero-schema fallback.
   - Unreliable: delta vs last-*acked* baseline with a ring of N snapshots, falling back to a full state when no baseline exists (Quake 3 / Gaffer).
   - Expose the reliable mode as the default and the acked mode as opt-in.
8. **String interning is a core feature, not a plugin:**
   - Schema enums for static vocabularies.
   - A per-connection reliable intern table for dynamic strings (send once, then id).
   - Measured at about 3.7× smaller than inline, and still about 2.7× smaller than inline + zstd (§2.2).
9. **Entropy coding (static Huffman/rANS with offline-trained tables) belongs in an optional codec plugin, not the core.**
   - Target small unreliable packets under about 100 B, which the engine likely doesn't compress.
   - Gate it on measured wins. Decode runs interpreted on clients.
10. **Write the client decoder for the interpreter:**
    - Specialized straight-line reads, no closures per field, no `readbits` in loops.
    - Use a manual `bit32` window for bit sections; `readbits` is 3× slower than hand-rolled when native and no faster interpreted.
    - Native codegen is server-only, so `@native` the server encoders and benchmark the client path with codegen *off*.
11. **Instances:**
    - Side-array by index (the universal approach).
    - Explicit per-field nil policy (`Instance?`, `Instance!` that drops only *that message*, not the batch, which is Blink's flaw).
    - Optional "flush before destroy" helper (Zap's `SendEvents` advice).
12. **Security defaults on:**
    - Per-player inbound byte and message budgets per frame.
    - Max decoded lengths derived from the schema.
    - NaN/inf rejection.
    - Bounded query concurrency per player, with timeouts and cancel-on-leave.
    - An error *policy* hook instead of throwing in the receive loop.
    - Basis: Packet and Blink vulnerabilities, Blink #45/#102/#107.
13. **Queries:** request ids in a u16 ring, server-side timeout, cancel on PlayerRemoving (fixes Zap #216-class leaks), and never `InvokeClient`.
14. **Middleware/codec plugin API at the IR level**, with hooks at three points:
    - per-field codec registration (`custom_datatype`-style, like Warp)
    - per-message middleware (inspect, transform, drop; like Pigeon)
    - per-frame transforms (compression or encryption experiments)

    Keep the hot path middleware-free when no middleware is registered: compile it out, don't branch per message.
15. **Tooling:**
    - Ship a PacketProfiler `RegisterLayer` adapter and a Zap-compatible tooling deserializer, so Lync traffic shows *decoded and per-message* in the de-facto inspector on day one.
    - Add opt-in MicroProfiler labels.
    - Publish a CLI under Lute/Rokit that does `check` (schema lint, worst-case sizes), `gen` (Luau + d.ts), `train` (string/enum/range suggestions and optional entropy tables from recorded traffic) and `bench`.
16. **Editor integration without a build step:** experiment with a luau-lsp source-transform plugin, and a Studio `ScriptEditorService` analysis callback, that surface schema-derived types and diagnostics. Both are experimental, so treat them as accelerators, not foundations.
17. **TypeScript:**
    - Generate `.d.ts` from the same IR (parity with Blink and Zap).
    - Offer an optional roblox-ts transformer that compiles TS-type-declared schemas, following flamework-binary-serializer.
    - Don't force Flamework.
18. **Benchmark honestly and publicly:**
    - Random-per-frame data, not identical data (identical data measures engine zstd).
    - Report both encoded bytes and estimated post-zstd bytes (`EncodingService` estimate at level 0–3).
    - Report interpreted and native CPU.
    - Lync currently trails in the most-cited third-party table (§1.7). v5 must win there on strings, numbers and Vector3 or the DevForum narrative won't move.
19. **Watch Server Authority:**
    - In SA games, gameplay input goes through InputAction rather than remotes, and remotes aren't on the simulation timeline.
    - Plan an optional tick-stamped message mode, since a time-locked engine event API is under consideration.
    - Keep Lync's role as the *data/event* layer rather than competing with engine prediction.
20. **Avoid unshipped language features** (`integer`, `export`, `class`) in runtime code until Roblox confirms them. `const` and `readbits` are safe now.
