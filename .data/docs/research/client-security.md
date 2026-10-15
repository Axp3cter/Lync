# Client-side security for Lync v5: runtime, wire and signals

> **Superseded in part (author decision, 2026-10-15):** Lync reports facts only. The Suspicion model below (weights, scores, decay, quiet mitigation) is rejected; the design keeps the exact triggers and evidence as factual events and leaves all policy to the developer.

Researcher brief, 2026-10-15. Scope: what a typed buffer networking library can do on the client and on the
wire to raise the cost of exploiting, detect tampering, break public scripts and feed the server signals, without
false positives or performance or debuggability loss. The server-side hard guarantees (per-player byte and frame
budgets before decode, strict canonical decode, server-only limits and validation) are assumed and not re-argued.

Owned here: attacker model, platform facts, WIRE INTEGRITY (tag, replay window, consistency, shuffling, traps,
direction), TIMING, ENVIRONMENT, the server-side signal model. Design-level anti-cheat (interest management, decoy
design, intent protocols, lag compensation, telemetry) is in `briefs/anticheat-design.md`. Not owned here (second
researcher): build-time and whole-project transformation (polymorphic builds, darklua/Rojo/sourcemap pipelines,
scattering checks into game scripts) and the configuration surface design. Each recommended measure below lists its **knobs** (what is set,
unit, range, default, cost) so the surface can be designed from them.

Labels: **verified** (I ran it or read the source), **documented** (official docs or the executor's own docs),
**reported** (third party), **unverified**. No executor was run; executor behaviour comes from the Potassium skill
(live-verified by its authors 2026-07-31 on v2.3.5) and from source of public tools. Luau runs used the pinned
toolchain: `luau 0.740`, Intel Xeon 2.1 GHz, Linux. Probe files: `.data/docs/probes/client-security/*.luau`; zstd script and its output:
`.data/docs/probes/client-security/zmask.py`, `zmask.out` (run `python3 -I zmask.py <dir holding zstandard>`).

---

## 0. Bottom line

1. Anything the honest client can do, code injected into that client can do by calling the honest client's code.
   The cheapest real attack on a typed library is `require(ReplicatedStorage.Net).Def.send({...})`, observed in
   the wild against ByteNet in 2026 (§1.4). No wire measure touches it.
2. Client measures therefore buy three things only: (a) they force attacks up from the wire to the API, which kills
   replayers, hand-built packets and copy-paste scripts written against another server or build; (b) they catch
   sloppy tooling with high-confidence signals; (c) they carry facts the server can check (clock, ack, sequence).
3. Lync's unique lever: it *is* the data path. A check fused into the frame (a keyed tag over an implicit sequence
   counter) cannot be removed by killing a script, unlike every standalone LocalScript anti-cheat; it must be
   patched, and patching shows up on the server as a broken sequence.
4. Every client check that answers "is this function hooked?" from Luau is defeated by documented executor APIs
   (`newcclosure`, in-place `hookfunction`, `setstackhidden`, `debug.setinfo`, `setthreadidentity`). Most also
   have false-positive histories. They belong in a game's anti-cheat, if anywhere, not in a networking library.
5. Because Lync is open source and shared by many games, any client measure identical across games invites one
   universal bypass. Per-server variation makes wire-level work per-server; it does nothing for API-level attacks.
6. The strongest signals are server-side and need no secrets: wrong-direction ids, trap definitions, sequence
   breaks, clock-rate divergence, acks of frames never sent, rates beyond the declared flush cadence.

---

## 1. Attacker model (October 2026)

### 1.1 Who is attacking, on what platform

Executor tracker snapshot (WEAO API `weao.xyz/api/status/exploits`, fetched 2026-10-15, **reported**, the tracker
is run by an executor-adjacent community; "detected" means bans or banwaves are known, not that the tool stops):

| Platform | Luau executors (in-process, run scripts) | sUNC | Externals (memory read/write, no Luau) |
|---|---|---|---|
| Windows | Potassium 2.5.2, Wave, Volt, Seliware, SirHurt, Synapse Z, Madium, Cosmic, Real, Isaeva, Velocity, Volcano (96–100 %), Solara 59 %, Xeno 40 % | mostly 100 % | Matcha, Photon, DX9WARE V2, Matrix Hub, Ronin, Serotonin, Melatonin, Severe, Lumen, Axis, Madius |
| Android | Delta (100 %), Codex (96 %), Vega X (98 %) | | |
| iOS | Delta (98 %) | | |
| macOS | MacSploit, Opiumware (100 %), both listed "not detected" | | |

- All 14 Windows Luau executors are flagged "detected" by the tracker, yet are updated and sold (Potassium:
  "$22.99 Lifetime", "kernel-level injection", "Last banwave: June 1st"). Hyperion on Windows raises ban risk; it
  does not stop injection. **reported**
- 13 of the 31 expose a `raknet` library (packet send/receive hooks below Luau). **reported** (tracker field
  `raknet: true`), **documented** for Potassium (`raknet.add_send_hook`, `add_receive_hook`, `send`).
- Externals never run Luau; they read and write process memory (ESP, aim, walk-speed floats). A networking
  library sees them only through behaviour (§4, §6).
- Roblox restricted emulators for non-creators on 2025-08-07 ("Players without creator permissions will be kicked
  if detected on an emulator"), and limited client FFlags to an allowlist on 2025-09-29. **documented**
  ([emulators](https://devforum.roblox.com/t/an-update-on-using-third-party-emulators/3867040),
  [FFlag allowlist](https://devforum.roblox.com/t/allowlist-for-local-client-configuration-via-fast-flags/3966569))
- Executors can be injected on the Roblox home screen and auto-execute before the game's LocalScripts run
  ([DevForum 2026-08-31](https://devforum.roblox.com/t/potassium-detection/4842452), **reported**). Any
  "capture a baseline at startup, compare later" check can be poisoned before it captures.

### 1.2 Executor capabilities that matter to a buffer library

Source: Potassium skill (v2.3.5 live enumeration, 250 globals) and sUNC docs
([docs.sunc.io](https://docs.sunc.io/), page dated 2026-09-26). **documented**

| Capability | What it gives the attacker against Lync |
|---|---|
| `require` of any ModuleScript, `getloadedmodules`, `getsenv(script)` | The shared schema module and Lync's client API. Calling `send` produces perfectly valid frames: correct ids, layout, sequence, tag. The schema module also documents the protocol. |
| `getgc`, `filtergc("function"/"table", {Keys=…, Name=…})`, `getreg` | Finds Lync's internal tables, closures, buffers and session state by shape, even if no module exposes them. |
| `debug.getupvalues/setupvalue`, `getconstants/setconstant`, `getprotos/getproto(active)`, `getstack/setstack` | Read the session key, seed, sequence counter; rewrite them; patch constants (e.g. a limit) inside Lync's closures. Works on all Lua closures (`newcclosure` wrappers hide only the wrapper's upvalues). |
| `hookfunction` (L→L, L→C, C→C, in place, "Replaces func with hook globally") | Wrap Lync's `send`, encoder, tag function, or Roblox's `FireServer`. In-place: `rawequal(original, captured)` stays true after hooking. |
| `hookmetamethod(game, "__namecall", …)`, `getnamecallmethod`, `checkcaller` | Remote spies. sUNC: hookmetamethod "essentially uses hookfunction to hook specific metamethods", so it is also in place. `checkcaller` lets a hook pass game calls through untouched. |
| `newcclosure(f, name)` | Hook reports `iscclosure`, `debug.info` source `"[C]"`, line `-1`, chosen name (Potassium: "verified live: `debug.info(newcclosure(f, "MyC"), "n")` returns `"MyC"`"). sUNC requires its errors to "appear as C closure errors". |
| `setstackhidden(f, true)`, `debug.setinfo/setname`, `loadstring(src, chunkname)` | Hide frames from `debug.traceback` and stack walks; rename functions; give executor chunks any source name, e.g. a game script's path. |
| `setthreadidentity`, `setthreadcaps`, `getthreadidentity` | Executor threads run at identity 8 with full capabilities (`getthreadcaps()` → 8); they can drop to 2 to look like a game thread. |
| `getconnections(remote.OnClientEvent)` → `Fire/Disable/Disconnect`, `firesignal` | Disable Lync's listener; inject fake server→client frames into the client; replay inbound frames. |
| `getrawmetatable`, `setreadonly/makewriteable`, `setrawmetatable` | Bypass `__metatable` locks and `table.freeze`. |
| `decompile(script or function)`, `getscriptbytecode`, `dumpbytecode(f)`, `getfunctionhash` | Read all client code including Lync (open source anyway) and any build-time variation. `getfunctionhash` fingerprints functions across sessions. |
| `getactors`, `run_on_actor`, `getactorthreads` | Reach code isolated in Actors (separate VMs). |
| `raknet.add_send_hook(packet:SetData/Block)`, `raknet.send` | Read, modify, drop or inject packets below Luau. A packet-level spy adds no Luau-visible cost and trips no Luau hook detector. |
| `setfpscap(0)`, `setfflag` | Change frame rate beyond the 240 Hz user setting; change engine behaviour. |
| `request`, `WebSocket`, filesystem | Export captured traffic, fetch per-game scripts, share keys between machines. |
| `setsafeenv(script, bool)` | Mark a script's environment safe or unsafe, which controls Luau's import and fast-call paths (§2.2). |

### 1.3 What remote spies actually do

- **SimpleSpy v3** (source, last commit 2022-09-03, **verified by reading**): two modes. Default hooks
  `__namecall` with a `newcclosure` and filters `getnamecallmethod()` in `FireServer/fireServer/InvokeServer/
  invokeServer`; optional mode `hookfunction(remoteEvent.FireServer, newFireServer)`. It generates replay code
  (`v2s(remote) .. ":FireServer(unpack(args))"`). `getcallingscript` is off by default "because detection".
- **Hydroxide** (source, 2024-02-24, **verified by reading**): hooks `__namecall` and also `hookFunction` on
  `Instance.new("RemoteEvent").FireServer` etc. It filters by `instance.ClassName` in `{RemoteEvent,
  RemoteFunction, BindableEvent, BindableFunction}`, so **UnreliableRemoteEvent traffic is invisible to it**.
- **Cobalt** (2025–2026, source repo not reachable; listing **reported**): incoming and outgoing, block and
  replay, "Actors support" even without `run_on_actor` "provided `setfflag` and `getfflag` are available",
  "UnreliableRemoteEvent Support". Potassium's changelog says `raknet` hooks return their callback so wrappers
  like "Cobalt Spy" can unregister, i.e. Cobalt uses packet-level hooks on executors that have them.
- Consequence for Lync: capturing `FireServer` once and calling it as a plain function hides Lync traffic from
  `__namecall` spies only. `hookfunction` mode and `raknet` see it. A spy shows Lync frames as opaque buffers; the
  shared schema tells a reader how to decode them.

### 1.4 Attack classes against a buffer library

| # | Attack | Typical tool | What stops it |
|---|---|---|---|
| A0 | Raw sender: fires Lync's remote with arbitrary args, sizes, rates | any executor | Server: exactly one buffer arg, budgets, strict decode |
| A1 | Replayer: records frames, resends them | Cobalt, SimpleSpy replay | Keyed tag over implicit sequence (reliable lane), replay window (unreliable lane) |
| A2 | Static forger: hand-builds frames from the public format, reused across servers/builds | public scripts | Per-server id permutation and field order; keyed tag |
| A3 | Extractor: reads key/seed/counter with `getgc`/`getupvalues`, builds valid frames | competent scripter | Nothing on the client; tag forces counter patching, which the server sees as a broken sequence if done wrong |
| A4 | API driver: calls `Net.Def.send(...)` from executor code | anyone; [2026-06 ByteNet example](https://devforum.roblox.com/t/help-needed-for-a-exploitsecurity-vulnerability/4710343) | Server authority only; weak client signals (identity oracle, caller source) catch naive scripts |
| A5 | Hooker: hooks Lync or engine functions to rewrite values after checks | competent scripter | Server authority only |
| A6 | Disabler / injector of inbound frames: `getconnections`, `firesignal` | any executor | Client-only effect; inbound sequence detects injected server→client frames |
| A7 | Packet-level: `raknet` send hooks, malformed engine packets | 13 executors | Below Lync. Engine crashers in 2026 ([4917779](https://devforum.roblox.com/t/my-game-servers-is-crashing-exploiters-using-library-raknet-for-destroying-my-game/4917779), "Replicator::OnReceive packet 27: Read past end") are Roblox's to fix |
| A8 | External: memory read/write, no Luau | Matcha, Severe, … | Behavioural signals; information hiding (send less) |

The 2026-06 ByteNet thread is the clearest field evidence for A4: the exploiter wrote
`local Netwok = require(game.ReplicatedStorage.Network)` then `Netwok.Dialog.OptionPicked.send({ActionId=...})`.
A competing library's 2026-09 pitch claims the opposite ("Exploiters don't use your client code - they write
packets by hand", [BlinkBlox](https://devforum.roblox.com/t/blinkblox-buffer-networking-that-checks-everything-a-client-sends/4898948)).
Both happen; A4 is easier and survives every wire change.

**Economics of a shared library.** A measure identical in every Lync game gets one universal bypass, published
once. Examples: one `setthreadidentity(2)` defeats an identity oracle everywhere; one `getgc` shape query finds the
session state everywhere. Per-server variation changes only work that operates on bytes (A1, A2).

---

## 2. Platform defences and Luau facts

### 2.1 Roblox platform

- **Hyperion** (Windows, since 2023): detection and banwaves, not prevention (§1.1). Android and iOS executors
  exist and are maintained; a 2024 DevForum post says Android lacked Hyperion and bans there come from Luau-level
  detections ([3169978 p2](https://devforum.roblox.com/t/universal-executor-detection-mac-windows-android/3169978?page=2),
  **reported**). Whether Hyperion ships on macOS: **unverified**; Mac executors are listed undetected.
- **Client code is bytecode** and is decompiled routinely (Potassium has an integrated decompiler, `decompile`
  accepts functions since build `90f2fddd`, 2026-07-08; parameter names come back `UNNAMED_<addr>`, so local names
  are not shipped). **documented**. `ServerScriptService.LoadStringEnabled` is `NotScriptable`, server only; clients
  have no `loadstring`, so the client runtime cannot generate code (**verified** via API dump 0.741). Code variation
  therefore needs a build step (other researcher).
- **Identities**: game Scripts and LocalScripts run at 2, ModuleScripts at their requirer's identity, CoreScripts
  higher ([explainer](https://devforum.roblox.com/t/a-current-explanation-of-normal-identities-and-security-tags/219471),
  **reported**). Executor threads run at 8 (Potassium `getthreadcaps()` "Returned `8`"). Members tagged
  `RobloxScriptSecurity` fail from identity 2 with "lacking capability" errors.
- **Server Authority** full release 2026-07-09: `Workspace.AuthorityMode = Server` turns on
  `NextGenerationReplication`, `PlayerScriptsUseInputActionSystem`, deferred signals, streaming, fixed simulation;
  "automatically rejects invalid client movements". Known issue: "Remote events aren't synchronized with the
  shared timeline". **documented** ([release](https://devforum.roblox.com/t/full-release-ship-fair-and-competitive-games-with-server-authority/4727993)).
  It removes movement and physics cheats from the remote-event problem; game RPCs (Lync) still carry
  client-chosen values, and InputActions are themselves client-driven.
- **Official guidance** (rewritten 2025-09-26, [docs](https://create.roblox.com/docs/scripting/security/security-tactics),
  repo `Roblox/creator-docs` `scripting/security/*.md`, **documented**): "Try to never ban based on client-side
  detections"; "implement a suspicion score … Severe actions … only after multiple, varied detections"; honeypot
  remotes give "a very high-confidence signal"; direction checks ("If an exploiter attempts to fire a server →
  client remote from the client, this serves as a reliable detection method"); "Action Cadence" heuristic; a
  consequence ladder (silent logging → quiet mitigation → restrictions → visible enforcement); "Delay visible
  consequences". A 2025-09 reply notes "several UBs that developers were using to detect exploits were removed".
- **Remote guarantees** (docs `scripting/events/remote.md`, **documented**): RemoteEvents are "reliable and
  ordered … including across different RemoteEvent instances", per connection and direction; excess client events
  are delayed, not dropped. UnreliableRemoteEvents guarantee neither; payloads over 1000 B are dropped. Client →
  server throttle "approximately 500 requests per second, per client", shared per remote type.
- **Frame rate**: honest PCs can run up to 240 Hz via the Maximum Framerate setting (2024-05-30); the old
  FPS-unlock FFlag is not on the 2025 allowlist. `setfpscap(0)` (executor) removes the cap. **documented**
- **Clocks**: a Roblox engineer's 2023 reply (ContextLost, not staff-flagged on the forum, **reported**):
  `tick()` is monotonic from a startup offset; `GetServerTimeNow` is "like tick() … with constant synchronization
  and smoothing", it "will slightly slow or speed up time to maintain synchronization"; `os.time`/`DateTime` read
  system time with "no guarantee of any kind of accuracy or sanity" on clients
  ([1909687](https://devforum.roblox.com/t/workspacegetservertimenow-documentation-incorrect-and-datetimenow-needs-more-information/1909687)).
- `Player:GetNetworkPing()` exists, security None, thread-safe (**verified**, API dump 0.741).

### 2.2 Luau facts (verified unless marked)

- `debug.info(f, "s")` is `"[C]"`, `"l"` is `-1`, for `print`, `string.byte`, `buffer.readu8`, `pcall`.
  `debug.info(f, "a")` returns `0, true` for C functions **and for any vararg Lua function** (`function(...)`), so
  an arity check cannot tell a vararg hook from a C function. (`.data/docs/probes/client-security/info.luau`)
- Error position prefix: `pcall(string.rep)` gives `missing argument #1 to 'rep' (string expected)`; the same
  call made inside a Lua function gives `./info.luau:13: missing argument …`. A plain Lua hook in front of a C
  function therefore leaks its chunk name into error text. sUNC requires `newcclosure` to suppress this, and
  Potassium "improved `newcclosure` error handling" on 2026-06-02.
- `getfenv` clears the "safe environment" flag of whatever environment it returns, including the environment of
  another function at a stack level: `luaB_getfenv` ends with `lua_setsafeenv(L, -1, false)`
  (`VM/src/lbaselib.cpp`, luau-lang master, read 2026-10-15). With the flag cleared, `GETIMPORT` re-resolves globals
  and every `FASTCALL` falls back to a normal call (`lvmexecute.cpp`: `if (!ttisnil(kv) && cl->env->safeenv)` and
  `if (cl->env->safeenv) { … f(L, …) }`). Stack-walking `getfenv(i)` checks therefore slow down every script they
  touch, game scripts included. One 2025 detector even used this slowdown to detect an executor (AWP), which shows
  how large it is.
- **Fast calls bypass in-place hooks of builtins.** `buffer.readu32`, `bit32.bxor`, `typeof` compile to
  `FASTCALL` (`remarks`); the VM calls the builtin's C entry from `luauF_table` by builtin id, not the closure
  object. So `hookfunction(buffer.writeu8, …)` cannot see or alter Lync's encoding while Lync's environment is
  safe (source-verified; not run against an executor). `os.clock` is **not** a fast call (`GETIMPORT` + `CALL`),
  so a hooked `os.clock` is seen. An attacker can clear safety (`setsafeenv`) to force the slow path.
- Builtin libraries are frozen (`table.isfrozen(string)`, `buffer`, `_G` all `true` in the CLI; Roblox sandboxes
  the same way). Executors unfreeze with `setreadonly`/`makewriteable`, and in-place hooks never write the table.
- `table.freeze`, `__metatable`, `newproxy`, closures and native codegen protect nothing from an executor:
  `getrawmetatable`, `setreadonly`, `getupvalues`, `hookfunction` act below them. Native code changes speed only.
- Costs on the pinned VM (`.data/docs/probes/client-security/cost.luau`, 200k iterations): `debug.info(2, "s")` 57 ns; with a cache lookup
  72 ns; a three-deep `debug.info` walk 184 ns; a successful `pcall` 30 ns; a `pcall` whose callee errors
  2.2–3.3 µs (error string construction dominates); a Lua forwarding hook adds ~9 ns to a 32 ns C call.
  Roblox devices will be slower, phones several times slower (**unverified** factor).

---


## 3. Wire integrity

Baseline is the draft v5 wire (`.data/versions/two/spec/wire.md`, `limits.md`): a frame is a 3-bit padding count
and bit-packed blocks (W-5, W-6); a block header is a same-namespace bit, a 4-bit slot and a `bits(n - 1)` id
(W-12); latest events carry an 8-bit per-definition sequence (W-61, L-15); timestamped blocks a 16-bit ms stamp
(W-57, L-16); the handshake lane `h` carries HELLO and VERDICT (W-179, W-82). The reliable lane has no frame
counter on the wire. The facts every measure below leans on:

- `r` is reliable and ordered "including across different RemoteEvent instances"; `u` is neither and drops
  payloads over 1000 B. **documented** (§2.1). So an implicit counter works on `r` and cannot work on `u`.
- Remote events "encode and compress certain object types, such as buffers" (creator-docs
  `UnreliableRemoteEvent.yaml`, read 2026-10-15). **documented**. Anything that whitens frame bytes forfeits that
  compression (§3.7).
- A client holds its sends until its namespace is accepted (A-8), so no data frame precedes the handshake.
- `Random.new()` with no seed "uses a seed from an internal entropy source" (creator-docs `Random.yaml`,
  2026-10-15). **documented**. Its algorithm is not, so nothing relies on client and server `Random` agreeing.

The secret in every measure is held by the client it protects against. None of them authenticates a client; they
detect traffic that did not come out of Lync's own encoder and flush, and they make byte-level tooling per-session.

### 3.1 Keyed tag over the implicit reliable-lane counter (recommend, core)

**Mechanism.**
- *Key exchange.* At a connection's first accept the server draws a 64-bit key `K` (two `NextInteger(0, 2^32 - 1)`
  from an entropy-seeded `Random.new()`) and sends one SESSION message on `h`, before the VERDICT that admits the
  first namespace: `u8 type, u8 epoch, u8 flags (tag width, shuffle mode), u16 cover/64, u32 shuffle seed, 8 B K`
  = 17 B, once per connection. Cross-remote ordering puts it ahead of any server data on `r`. Keys are per
  connection, not per namespace, because one `r` frame mixes namespaces.
- *Counter.* `c` counts upstream `r` calls of that connection from 0. It is never sent. The client advances `c`
  *before* `FireServer` and keeps it advanced if the call raises (F-40), so a lost call shows as a gap of 1,
  never as a rewind.
- *Tag.* `tag = trunc_b(PRF_K("r" ‖ epoch ‖ c ‖ frameLength ‖ instanceArgCount ‖ first min(len, cover) bytes))`,
  appended as the last `b/8` bytes of the frame, outside the bit stream, so W-5 padding is unchanged and the
  receiver strips it before decoding. The lane letter separates domains so an `r` frame never verifies on `u`.
  Instance arguments are references and cannot be hashed; binding their count stops add/remove edits only.
- *PRF.* HalfSipHash (32-bit ARX: add, rotate, xor; all `bit32` builtins are fast calls, §2.2), reference
  [veorq/SipHash](https://github.com/veorq/SipHash) `halfsiphash.c`. The Linux kernel warns its 64-bit key is
  "easily brute-forcable" and allows it only where outputs are never transmitted
  ([kernel siphash doc](https://www.kernel.org/doc/html/latest/security/siphash.html), **documented**). That
  warning protects a secret from observers; here the only party that sees tags already holds `K`, a new key is
  drawn per connection, and an offline search would buy the attacker what `getupvalues` gives in one call. Default
  1-3 rounds (the kernel's hsiphash choice); 2-4 as an option at about twice the per-byte cost.
- *Server check.* Verify at the expected `e`. On failure try `e + 1 … e + L` (lookahead). A match at `e + j`
  accepts the frame, sets `e = e + j + 1` and reports `FrameGap(j)`. No match drops the frame, reports
  `TagMismatch` and leaves `e` unchanged, so an injected frame never desynchronises the honest stream.
- *Desync recovery.* `desyncAfter` consecutive failures with no valid frame between them means the stream, not a
  frame, is wrong. The server sends REKEY on `h` (`u8 type, u8 epoch + 1, 8 B K'` = 10 B); the client switches key
  and resets `c` when it handles REKEY and answers REKEY-ACK on `h` (2 B) before its next `r` call. The server
  switches at the ACK; cross-remote ordering makes that cut exact. One `Desync` report, at most one rekey per
  `rekeyInterval`, after which failures stay `TagMismatch`. Forcing rekeys gains an attacker nothing: `K'` lands in
  his client like `K`.

**What it catches.** A0 raw senders and A7 packet injectors without `K` (every frame fails); A1 replays (tag bound
to an old `c`); A2 static forgeries; edits made below Lync's encoder by `hookfunction` on `FireServer`, `raknet`
`SetData` or a spy's edit-and-resend, inside `cover`; in-process *blocking* of a Lync call (Cobalt-style block)
as a counter gap. **Robustness:** an attacker who calls Lync's send API (A4) or hooks above the encoder (A5)
produces valid tags. One who reads `K` and `c` from Lync's upvalues (A3) can forge, but must keep `c` in lockstep
with Lync's own sends; any interleaving error is a `TagMismatch` or `FrameGap`. Verdict: high-confidence,
narrow-coverage, unremovable by killing a script (§0.3).

**Tag width.** 16 bits: a keyless forger is accepted with probability 2^-16 per frame and every rejection is
reported, so online search costs ~65 000 flags. 32 bits only matters if acceptance were treated as
authentication, which it must not be.

**Wire bytes.** +2 B per upstream `r` frame (16-bit tag), +17 B once per connection, +12 B per rekey. At 60
reliable frames/s that is 120 B/s per player upstream. The per-call engine overhead of a RemoteEvent is not
documented (**unverified**), so the relative cost on tiny frames cannot be stated; the frame payload grows by 2 B.

**verified (milestone build, f1fbfd7):** HalfSipHash-1-3 with a 4-byte output takes 1.8–3.5 µs per 64 B interpreted and 0.26–0.42 µs native,
and 22–24 µs and 3.1–3.7 µs per 1024 B: about 23 ns per covered byte interpreted and 3 ns native
(`probes/build/results/579015b.json`, `c91960e.json`). The estimate below holds for interpreted code; native is
faster than estimated.

**CPU (estimate, not measured).** Interpreted Luau on the reference Xeon, from §2.2 call costs and ~15 builtin
ops per 32-bit word for one SipRound: HalfSipHash-1-3 ≈ 0.2–0.3 µs fixed plus 13–23 ns per covered byte; 2-4 rounds
roughly double the per-byte term. A 64 B frame ≈ 1–1.5 µs, a 1 KB frame ≈ 15–25 µs. Server, 100 players × 60
frames/s × 150 B average: ≈ 1–2 % of one core interpreted; counter-only (`cover = 0`) ≈ 0.2 %. Native codegen,
where enabled, should cut the per-byte term several-fold (**unverified**). Clients pay for their own frames only:
on a phone 3–5× slower, ≈ 0.5–1 ms per second of play.

**False-positive sources.**
| Source | Effect | Handling |
|---|---|---|
| Packet loss, reordering | none: `r` is reliable and ordered | — |
| `FireServer` raises | gap of 1 | `FrameGap`, weight weak |
| Rejoin | new Player, new connection, new `K` | none needed |
| Teleport, soft-shutdown migration | new server, new handshake | none needed |
| Engine reconnect that keeps the Player | **unverified** whether it exists or replays calls | desync → REKEY, one weak `Desync` |
| Studio Play Solo / Team Test | same path; one process | tests pin `K` and seed through the seams (A-10) |
| A Lync bug (tag or counter) | burst of mismatches | desync path; weights; never-kick defaults (§6) |

**Handshake change.** SESSION (server → client, 17 B), REKEY (10 B), REKEY-ACK (2 B) on `h`; protocol version
bump; the layout rule of W-198 extends to the new message type byte.

**Downstream tags (server → client): refuse.** They detect frames injected into the client by `firesignal` or
`getconnections` (A6), but the only consumer of that verdict is client code the attacker controls, and they cost
the server one PRF per recipient per frame even where a section is shared (W-71).

### 3.2 Replay window on the unreliable lane (recommend, core, with the tag)

**Mechanism.** Every upstream `u` frame carries an explicit `q`-bit sequence at the start of its bit stream and
the same trailing tag as §3.1, computed over the *extended* sequence (implicit high bits). The receiver extends
`q` bits to the value nearest its highest accepted sequence, verifies the tag, and on failure retries the two
neighbouring extensions (±2^q) before reporting, which costs two PRFs on the failure path only. The window is the
IPsec anti-replay bitmap ([RFC 4303 §3.4.3](https://www.rfc-editor.org/rfc/rfc4303#section-3.4.3): window of at
least 32, 64 recommended; [RFC 6479](https://www.rfc-editor.org/rfc/rfc6479) for a shift-free bitmap): newer than
the highest → slide and accept; inside the window and unseen → accept; inside and seen → `Duplicate`, drop; older
than the window → `TooOld`, drop. Without the tag the window catches only byte-identical replays, since the
sequence field can be edited; ship both or neither.

**Width of `q`.** Unreliable calls per client can exceed the frame rate, because a flush cuts at the 985-byte cap
(L-7): 4 calls × 240 Hz ≈ 1000/s worst case. The extension is right while reordering stays under half the space:
`q = 8` gives 128 calls (0.13 s at 1000/s), `q = 12` gives 2048 calls (2 s), and the neighbour retry triples that.
Default 12. Roblox's actual unreliable reorder depth is **unverified**; this margin is a guess against it.

**What it catches.** Replayers that re-fire captured `u` frames (Cobalt supports UnreliableRemoteEvent, §1.3);
packet-level duplication by `raknet` hooks. **Robustness:** same as §3.1: an attacker who sends through Lync
defeats it; one who has `K` must also allocate sequences that Lync does not use.

**Wire bytes.** `q` + tag = 12 bits + 16 bits ≈ 3.5 B per upstream `u` frame; the L-7 payload cap drops by 4 B
(to `981 - 6 * I`). Offset: with a frame-level sequence the per-definition latest sequence (W-61, 8 bits per
latest block) becomes redundant upstream, since "newer frame wins" orders every latest block in it. That is the
wire designer's call; it makes the window free for frames with two or more latest blocks. Demoted latest messages
on `r` (W-62) would then need the frame sequence carried in-block.

**CPU (estimate).** Tag as §3.1 over ≤ 981 B; bitmap update ≈ 20–50 ns per frame.

**False positives.** Loss: none, gaps are legal. Reordering within the window: none. Reordering beyond it:
`TooOld`, counted, never reported. Network duplication: whether Roblox's transport ever delivers an unreliable
datagram twice is **unverified**; a duplicate's content was already delivered, so dropping it is harmless and it
is reported only as a rate (`replayNoise`: above 2 % of frames and at least 20 in 60 s). Rejoin and migration
reset the window with the connection.

### 3.3 Ack and sequence consistency (recommend the free checks; no new bytes)

The draft has no acks: `r` gives reliability, latest state settles by a reliable resend (W-74), and the only
values a client echoes are request ids. Checks available now:

| Check | Honest explanation | Verdict |
|---|---|---|
| C1 response whose id the server never issued to that player for that definition | none | `UnknownReply`, certain |
| C2 response for an id pending → normal; resolved or timed out within the last 2048 allocations | late reply after `Timeout` | `Stale`, count only (F-32) |
| C3 a second response for an id already answered | none: a handler replies once (A-81) | `UnknownReply`, certain |
| C4 client request reusing a pending id (W-207) | none | already `Malformed`; feeds §6 |
| C5 upstream latest sequence out of window (W-147) | reordering | count only |

C1 and C3 need the server to remember "issued within the last 2048 allocations, answered or not" per player and
request definition: a 4096-bit ring, 512 B per player per server-invoked request definition (estimate), extending
the quarantine W-79 already keeps. **Robustness:** these catch hand-forgers and fuzzers only; an API driver answers
through Lync's handler, which is consistent by construction. If acks are added later (delta baselines, unreliable
reliability), each ack is a server-checkable claim: acking a sequence never sent, or acking faster than half the
measured RTT, is impossible honestly; out-of-order acks within a window are honest.

### 3.4 Per-server and per-session shuffling (recommend ids per server; fields opt-in)

**Mechanism.** The SESSION seed `s` (32 bits) and each namespace's hash seed a small PRNG written in Lync
(xorshift or PCG over `bit32`), never `Random`, whose algorithm is undocumented and may differ between a client and
server on different engine builds mid-rollout. A Fisher–Yates permutation of `0 … n - 1` replaces the identity map
from id to definition (W-13). Optionally the same PRNG permutes each record's field order (W-39, W-48).

**Size cost.** Ids: exactly zero, a permutation keeps `bits(n - 1)`. Field order: zero except alignment, since
string and buffer bytes start on a byte boundary (W-35), so a moved string field can gain or lose up to 7 padding
bits per message. Enum and `oneOf` indices: zero bits, but a permutation can turn DELTA and RUNS columns (W-51,
W-52) into PACKED for values that move in natural order (bounded by W-139, ≤ 2 bits per column worse than PACKED);
do not permute them.

**CPU.** Zero per frame: the decode table is already an index; it is built once. Building it ≈ 50 ns per definition
(estimate), 50 µs for 1000 definitions, per namespace per server; per player in session mode.

**Scope.** Per server keeps W-71 (one section's bits identical for every recipient), so downstream encoding stays
encode-once. Per session breaks W-71 downstream, so session mode should apply to upstream ids only: one decode
table per player per namespace on the server (≈ n slots each; 200 definitions × 100 players ≈ 20 000 slots).

**What it breaks.** Public scripts that hard-code frame bytes; hand-written encoders built from the published
format; frames captured in another server or session and replayed here (they decode as other definitions, and
fail the tag anyway); one "universal Lync packet builder" that works in every game. **What it does not:** A3/A4
use Lync's own encoder, which applies the permutation for them. One `getgc` query for the permutation table,
published once, defeats it in every Lync game. With the tag on, shuffling adds protection only against an
attacker who has `K` but uses a static encoder: small. It stays on by default because it costs nothing at run time
and removes copy-paste byte scripts as a class.

**FP and debuggability.** None from the network. Golden vectors such as W-190 (`08 01 68 69`) need the identity
map: seed 0 through the seams means identity, and tests also run random seeds to catch permutation bugs. Traces
print decoded values (F-87), so they are unaffected; any raw byte dump Lync emits must name the seed.

**Handshake change.** The 4-byte seed inside SESSION.

### 3.5 Trap definitions (recommend the API and the free structural traps)

**Declared traps.** The game declares an ordinary definition in the shared schema and marks it on the server only
(`server.AdminGrant:trap()`), so the schema module, which a reader can `require`, shows nothing special. Honest
client code never fires it. Any arrival is reported `Trap`, certain, and the block is dropped. Roblox's docs call a
honeypot remote "a very high-confidence signal" (§6.4). This is the only wire-level measure that catches A4 API
drivers, because they browse the schema module and call tempting names (§1.4). Cost: zero bytes per frame; the
trap takes an id, which adds one id bit to every block of that namespace when `n - 1` crosses a power of two.
Which names to plant and where is design work covered in `briefs/anticheat-design.md`.
**Robustness:** an attacker who fires only definitions the honest client fires, learned by reading client game
code, never trips it. **FP:** a developer's own test code or the Studio command bar firing it, or the definition
later used for real. In Studio Lync reports it and prints one loud line naming the trap.

**Structural traps (free).** Every decode refusal of a client frame is impossible for an unmodified client whose
schema hash matched: an id ≥ n (W-194), a block for an unadmitted slot (W-189, since clients hold sends until accept),
nonzero padding (W-94), a non-canonical class code (W-107), an out-of-range index (W-54), a union index ≥ v
(W-129), a non-ascending map key (W-131). They already drop and count as `Malformed` or `OutOfBounds` (F-27, F-28);
§6 turns them into suspicion. Exclude W-124 (an enum value the running server engine lacks: engine-version skew
during a rollout) and W-126 (instance class), whose honest causes are engine-side. Unused ids when n is not a
power of two already act as ghost ids; adding more buys nothing.
**Robustness:** anyone who encodes through Lync passes. Honest FP source: Lync encoder/decoder disagreement bugs,
which is why these weigh less than declared traps.

### 3.6 Wrong-direction and wrong-lane checks (recommend, core)

**Direction.** In the draft events are bidirectional (A-59). Add a direction to the declaration (client → server,
server → client, both) and include it in the definition hash (W-184), so version skew is a handshake mismatch and
never a runtime flag. The client view of a server → client definition has no `fire`, so honest code cannot
send one; the server receiving such a block reports `WrongDirection`, certain. Roblox's docs call this "a
reliable detection method since legitimate gameplay would never trigger communication in the wrong direction"
(§6.4). Collections (server → client only) and responses to never-issued ids (§3.3) are the same class already.
**Lane.** A block of a reliable-only definition (reliable event, request, response, collection section) inside a
`u` frame is never produced honestly, since demotion only moves `u` → `r` (W-62): `WrongLane`, certain.
**Cost.** Zero bytes; one comparison on the definition the decoder already looked up.
**Alternative.** Per-direction id spaces save id bits (each direction indexes only its own definitions). Wrong-
direction sends then decode as invalid ids, still caught as `Malformed`, but the evidence loses the definition
name. A wire-format trade for the format owner; either keeps a signal.
**Robustness:** defeated by an attacker who only fires what the honest client may fire. **FP:** none from the
network, rejoin, migration or Studio.

### 3.7 Measures refused at the wire

- **Whitening or XOR-masking frames.** zstd level 3 over masked versus plain frames
  (`.data/docs/probes/client-security/zmask.out`): 1024 B input-like frames 637 → 1034 B (+62 %), chat-like 355 →
  1034 B (+191 %), 4096 B chat-like 1104 → 4106 B (+272 %); a byte permutation of ids costs 0–3 % on input-like
  frames. **verified** (zstd 0.25 Python binding, synthetic frames). Remote buffers are compressed by the engine
  (documented), though its codec is not documented, so the exact loss is **unverified**; the direction is not. Masking
  adds nothing against A3/A4, since the mask lives in the same client.

---

## 4. Timing

All three signals are measured where the attacker cannot reach: server arrival times (`os.clock` on the server)
and the server's own records. Client-supplied numbers enter only as claims to check. Two documented clock facts
carry the analysis (creator-docs `Workspace.yaml` and `os.yaml`, read 2026-10-15): `GetServerTimeNow` "is
monotonic; its value will never decrease" and "moves at the same rate as the local clock to within 0.6%";
`os.clock` is "not affected by adjustments to the system clock". DevForum guidance on speed hacks agrees the
server must not trust client time ([210733](https://devforum.roblox.com/t/how-to-prevent-speed-hacking/210733),
updated June 2024: "exploits can still mess with the time values", **reported**).

### T1. Client clock rate versus server clock (opt-in)

**What.** Timestamped blocks already carry `floor(GetServerTimeNow() * 1000) mod 2^16` (W-57). Lync adds a 16-bit
beacon of the same clock to at most one upstream frame per `clockBeacon` seconds when no timestamped block is in
it. The server unwraps each stamp (W-58) and records `o = arrival − stamp`, which is one-way delay plus clock error.

**Why it carries a signal.** Because `GetServerTimeNow` cannot slew more than 0.6 % away from the local clock and
never steps back, a client whose local clock is accelerated (timer hooks, Cheat-Engine-style speed hacks,
`setfpscap` does *not* do this) drifts against the server at ≈ (rate − 1 − 0.006). An honest client drifts at
most 0.6 % while it corrects, plus oscillator error (tens of ppm, **reported** general hardware figure). It also
catches tooling that writes stamps by hand: a forged `sentAt` that wanders.

**Estimator.** Per player: windows of 5 s, keep the *minimum* `o` per window (the lower envelope discards queueing
jitter), fit a slope over the last 12 windows (60 s) with Theil–Sen (robust to spikes). Report `ClockRate` when
the slope exceeds `clockRateThreshold` (3 %) in `clockConfirm` (3) consecutive fits, i.e. 3 minutes sustained.
Never from one sample.

**Noise, low-end mobile versus PC.** Envelope noise: wired PC ~1–5 ms, cellular 10–50 ms with spikes into
hundreds (**reported**, general network behaviour, not measured on Roblox). Slope error of a 60 s fit over 12
minima spaced 5 s is σ / (5 s × √(12 × 143 / 12)) ≈ σ / 60 s, i.e. 0.03–0.08 % for σ = 20–50 ms: an order of magnitude under the documented
0.6 %, so the 3 % threshold is set by the clock contract, not by device class. The same threshold serves both.

**False positives and handling.**
| Source | Shape | Handling |
|---|---|---|
| Join warm-up (time sync settling) | large offset, short | ignore the first 30 s |
| Device sleep or app in background (mobile) | client clock falls behind, then catches up at ≤ 0.6 % | arrival gap > 2 s resets the estimator; only *fast* clocks (positive slope) weigh; slow ones are reported weight 0 |
| Server hitch | all players shift at once | if more than half the players' windows move the same way, discard that window for everyone |
| Network route change | step in envelope, not a slope | Theil–Sen ignores a single step |

**Robustness.** Client data: an attacker who keeps Lync's stamps on an unaccelerated clock, or patches the stamp,
defeats it. Coverage is narrow: most Roblox speed cheats change WalkSpeed or CFrame, which Server Authority or
position checks catch, not this. Precision is high. **Cost:** 2 B per beacon (2 B/s at the default), O(1) per
beacon, one 12-point fit per 5 s per player.

### T2. Cadence versus frame boundaries (core, counters only)

**Facts.** An honest Lync client flushes once per client frame: one `r` call and up to a few `u` calls. Honest
frame rates reach 240 Hz through the Maximum Framerate setting; fps unlockers exist; `Lync.flush()` lets game code
flush more often than once per frame. The server sees arrival times only, quantised to its own frame step (~16 ms)
and bunched by the network, so single intervals carry nothing; counts over windows do.

**Signals.**
- *Declared-rate violation.* A definition with a declared send rate (`:latest(rate)`, A-54; collection latest
  rate, A-163) is limited by the client's own Lync. The server runs a token bucket at that rate with burst =
  `rate × cadenceJitter + 2`. Excess sustained over `cadenceWindow` (10 s) reports `RateExceeded`, weak. Honest
  explanations: a clock 0.6 % fast (inside the burst), network bunching (inside the burst). It catches patched
  limiters and raw senders, and correlates with T1.
- *Calls per second above any plausible frame rate.* > 250 `r` calls/s sustained 10 s: reported with weight 0
  (information), because fps unlockers and manual flushes are honest.
- Interval regularity of player actions ("Action Cadence" in Roblox's guidance) is gameplay-level; see
  `briefs/anticheat-design.md`.

**Noise.** Mobile runs at 30–60 Hz, which only lowers cadence; no false-positive direction. Server step and network
bunching are absorbed by the burst term. **Robustness:** an API driver is rate-limited by Lync itself, so this only
catches tools that bypass or patch the limiter. **Cost:** zero wire; one bucket per player per rated definition
(the A-67 bucket structure).

### T3. Reply latency versus measured RTT (core instrument, rare signal)

**Facts.** `Player:GetNetworkPing()` "Returns the round-trip, isolated network latency … It doesn't involve data
deserialization or processing" (creator-docs `Player.yaml`, 2026-10-15, **documented**). For a server → client
request, Lync knows send and response arrival on the server clock.

**Signal.** `processing = roundTrip − ping`. A reply cannot beat the network: `roundTrip < earlyReplyFactor ×
minPing(10 s)` (0.5) means the client answered before it could have received the request, i.e. pre-sent a
response for a predicted 12-bit request id. Report `EarlyReply`, strong, after 3 such replies among the last 20.
Honest causes: `GetNetworkPing` is smoothed and can lag a sudden improvement; the factor 0.5 and the 3-of-20 rule
absorb that. It rarely fires, because forging a reply is pointless when the attacker can answer through Lync.

**More useful as an instrument.** Expose `roundTrip` and `ping` on server-side results so game code can study
processing-time distributions for human-gated prompts (bots answer in one frame every time). That analysis is
game policy. **Noise:** mobile ping spikes of 100–500 ms inflate `processing`, never shrink `roundTrip` below the
network, so the impossible-side check stays safe on any device. **Cost:** one clock read per request; zero wire.

---

## 5. Environment checks: belong to the game, not to Lync

**Confirmed.** Every client check of the form "is this function hooked, is this thread foreign, was this caller
injected" is defeated by documented executor features (§1.2): `newcclosure` makes a Lua hook report `"[C]"`, line
`-1` and any name; `hookfunction` and `hookmetamethod` hook in place so `rawequal` stays true; `setstackhidden` and
`debug.setinfo` clean stack walks; `setthreadidentity(2)` passes identity probes; `getconnections` disables the
checker; auto-execute before game scripts poisons baselines (§1.1). Sources: sUNC docs and Potassium docs (§1.2),
**documented**. Field evidence: Adonis, the most widely deployed admin system, ships its client anti-exploit off by
default (`AllowClientAntiExploit = false`) under "IF YOU EXPERIENCE ISSUES WITH FALSE POSITIVES/RANDOM
KICKING/CRASHING DISABLE ALL OF THESE SETTINGS!", and its hook checks are `debug.info(f, "s") ~= "[C]"`, `"l" ~= -1`,
`"a" ~= 0` (`Loader/Config/Settings/AntiExploit.luau`, `MainModule/Client/Core/Anti.luau`, commit of 2026-10-14,
**verified by reading**), which `newcclosure` satisfies and which a vararg Lua function also partly satisfies
(§2.2). Roblox: "Try to never ban based on client-side detections, as exploiters can easily bypass them" (§6.4).
Two library-specific reasons add to this: a check identical in every Lync game gets one universal bypass (§1.4), and
stack-walking `getfenv` checks deoptimise the game's own scripts (§2.2).

**What Lync can report cheaply and safely.** Everything worth reporting is measured on the server from wire facts
(§3, §4): tag failures, gaps, desyncs, replays, traps, wrong direction and lane, decode refusals, clock rate,
cadence, early replies. None depends on the client telling the truth. Client-measured candidates, all refused:

| Candidate | Cost | Why refused |
|---|---|---|
| Caller identity of `send` (pcall a protected member) | 2–3 µs per probe (error path, §2.2) | `setthreadidentity` defeats it; Studio command bar runs at a different identity (FP) |
| Caller source of `send` (`debug.info(level, "s")`, 57 ns) | cheap | `loadstring(src, chunkname)` names chunks anything; modules called from many places |
| Client-side decode failures of inbound frames (A6 injection) | free | reported by the attacker's own client: suppressible and forgeable |

Lync's obligation to a game's anti-cheat is negative: never touch `getfenv`/`setfenv` (keeps fast calls and the
game's safe environment), never hook globals, never require identity above 2, so a game's own checks keep a clean
baseline.

---

## 6. Server-side signal model

### 6.1 The typed event

One new observer kind beside the draft's closed set (F-60), delivered through `Lync.observe` and the same
window and cap machinery (L-18, L-19, F-68).

```luau
export type SuspicionReason =
	"Trap" | "WrongDirection" | "WrongLane" | "TagMismatch" | "UnknownReply" | "HandshakeAbuse"   -- certain
	| "Malformed" | "OutOfBounds" | "Replay" | "ClockRate" | "EarlyReply"                         -- strong
	| "FrameGap" | "Desync" | "RateExceeded"                                                      -- weak
export type Suspicion = {
	kind: "Suspicion",
	player: Player,
	reason: SuspicionReason,
	confidence: "Certain" | "Strong" | "Weak",
	weight: number,            -- configured weight of this reason
	namespace: string?,        -- server-side names only; nil when the frame never reached a block
	definition: string?,
	count: number,             -- occurrences this event stands for (1, or the window's total)
	first: number, last: number, -- server os.clock of first and last occurrence
	evidence: Evidence,        -- frozen; numbers and server-side names only, never client bytes
	score: number,             -- player's decayed score after this event
}
```

| Reason | Evidence fields | Confidence | Honest cause |
|---|---|---|---|
| Trap | definition | certain | developer firing it (Studio prints) |
| WrongDirection | definition, lane | certain | none (direction is in the hash) |
| WrongLane | definition, lane | certain | none |
| TagMismatch | lane, expected counter, frame bytes | certain (isolated) | Lync bug → becomes `Desync` |
| UnknownReply | definition, id | certain | none |
| HandshakeAbuse | hellos, distinct hashes | certain | none: a client cannot change its hash (W-208) |
| Malformed / OutOfBounds | definition, path, rule id (W-…) | strong | encoder/decoder bug; W-124 and W-126 excluded |
| Replay | duplicates, frames, window | strong | transport duplication (rate-gated) |
| ClockRate | slope, windows, offset | strong | none above 3 % sustained (§4 T1) |
| EarlyReply | definition, roundTrip, ping, hits | strong | smoothed ping lag (3-of-20 rule) |
| FrameGap | skipped | weak | `FireServer` raised |
| Desync | failures, epoch | weak | unknown engine reconnect behaviour |
| RateExceeded | definition, rate, observed | weak | none beyond burst, but limits can be misdeclared |

Bytes from the client never appear in evidence: an attacker must not be able to inject text into the game's logs
or analytics. Names come from the server's own schema; numbers are bounded.

### 6.2 Aggregation and rate limiting

An attacker can produce ~500 failing calls per second per remote type (§2.1), so every failure costs O(1) and
output is bounded:
- Key = (player, reason, definition). The first occurrence in a window emits immediately (so a game can log the
  first trap hit at once); later ones in the same 30 s window are counted and emitted as one event with `count` at
  window close (F-68 shape).
- Per player: at most `perPlayerEvents` (16) events per window, then one `Suppressed`.
- Per server: at most `serverEvents` (256) per window across all players, then one `Suppressed`; counting continues.
- Score: `score = Σ weight × min(count, 10)` per window, decayed with half-life `scoreHalfLife` (600 s). The cap of
  10 per key per window stops one noisy reason from dominating; Roblox's guidance asks for "multiple, varied
  detections" (§6.4), so diversity across reasons, not volume of one, should raise the score. `Lync.suspicion(player)`
  returns `{ score, byReason }` for pull-style review; state is released when the player leaves (A-161).
- Console: in Studio, one line per key per window; in live servers, one aggregate line per window ("N players
  flagged: trap 2, wrongDirection 1"), off with the console setting (F-90).

### 6.3 How game code subscribes

```luau
Lync.observe(function(event)
	if event.kind ~= "Suspicion" then return end
	Telemetry.log(event.player.UserId, event.reason, event.count, event.evidence)
	if event.score >= 40 and event.confidence == "Certain" then
		Moderation.queueReview(event.player)   -- the game's ladder, not Lync's
	end
end)
```

TypeScript: `Suspicion` as a discriminated union on `reason`, so `evidence` narrows per reason.

### 6.4 Defaults: never kick, never ban, never tell the client

Lync's only action is the one it already takes for bad input: drop the offending frame or block (keep the frame on
`FrameGap`; keep everything on `ClockRate`, `RateExceeded`'s report-only path, and `EarlyReply`). It never kicks,
bans, throttles beyond declared limits, or sends any reply that tells the client it was flagged. This follows Roblox's
security guidance (rewritten 2025-09-26, `scripting/security/server-side-detection.md`, read at creator-docs commit
of 2026-10-14, [docs](https://create.roblox.com/docs/scripting/security/server-side-detection), **documented**):
"Try to never ban based on client-side detections"; "Be proportional and reversible. Assume false positives can
happen"; "implement a suspicion score … Severe actions like kicking or banning should only occur after multiple,
varied detections"; the consequence ladder "Silent logging → Quiet mitigation → Temporary restrictions → Visible
enforcement"; "Delay visible consequences to avoid teaching exploiters exactly what triggered detection". The same
page suggests kicking on a honeypot hit; that is a game's choice, which the subscription above makes one line.

---

## 7. Knobs per measure

Server-side unless marked; the server sends the client what it needs in SESSION. CPU figures are estimates (§3.1).

| Measure | Name | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|---|
| Tag | `tagBits` | integer | bits | 0, 16, 32 | 16 | `tagBits/8` B per upstream frame |
| Tag | `tagCoverBytes` | integer | bytes | 0 – 1048576 | 1024 | ~13–23 ns per covered byte, server and client |
| Tag | `tagRounds` | enum | — | "1-3", "2-4" | "1-3" | 2-4 ≈ 2× per-byte cost |
| Tag | `tagLookahead` | integer | frames | 0 – 16 | 4 | ≤ L extra PRFs, failure path only |
| Tag | `desyncAfter` | integer | frames | 2 – 64 | 8 | — |
| Tag | `rekeyInterval` | number | s | 10 – 600 | 60 | 12 B per rekey |
| Replay | `replaySeqBits` | integer | bits | 8 – 16 | 12 | bits per upstream `u` frame |
| Replay | `replayWindow` | integer | frames | 32, 64, 128, 256 | 64 | one bitmap per player |
| Replay | `replayNoise` | number | fraction of frames | 0 – 1 | 0.02 (and ≥ 20 per 60 s) | — |
| Consistency | `replyMemory` | integer | allocations | 0, 2048 | 2048 | 512 B per player per server-invoked request |
| Shuffle | `shuffleIds` | enum | — | "off", "server", "session" | "server" | 4 B once; session: one table per player |
| Shuffle | `shuffleFields` | boolean | — | — | false | ≤ 7 bits per string field per message |
| Shuffle | `shuffleSeed` (seams, tests) | integer? | — | 0 – 2^32−1 | nil (random); 0 = identity | — |
| Trap | `definition:trap()` | server view method | — | — | none declared | an id slot |
| Direction | declaration direction | enum, in hash | — | "toServer", "toClient", "both" | "both" | zero |
| Direction | `directionCheck` | boolean | — | — | true | zero |
| Clock rate | `clockBeacon` | number | s | 0 (off), 0.5 – 10 | 0 (off) | 2 B per beacon |
| Clock rate | `clockRateThreshold` | number | fraction | 0.01 – 0.5 | 0.03 | — |
| Clock rate | `clockWindow` | number | s | 30 – 600 | 60 | one fit per 5 s |
| Clock rate | `clockConfirm` | integer | fits | 1 – 10 | 3 | — |
| Clock rate | `clockWarmup` | number | s | 0 – 120 | 30 | — |
| Cadence | `cadenceJitter` | number | s | 0.25 – 5 | 1 | — |
| Cadence | `cadenceWindow` | number | s | 2 – 60 | 10 | one bucket per rated definition |
| Early reply | `earlyReplyFactor` | number | fraction of min ping | 0 – 1 (0 = off) | 0.5 | one clock read |
| Signals | `weights` | map reason → number | points | ≥ 0 | certain 10, strong 4, weak 1, info 0 | — |
| Signals | `scoreHalfLife` | number | s | 60 – 86400 | 600 | — |
| Signals | `perPlayerEvents` | integer | events/window | 1 – 64 | 16 | — |
| Signals | `serverEvents` | integer | events/window | 16 – 4096 | 256 | — |

---

## 8. Implications

Ranked; each line: rationale, then its honest limit.

**Core, on by default**
1. Wrong-direction and wrong-lane checks with direction in the hash (§3.6): zero bytes, certain, endorsed by
   Roblox's docs. Limit: catches only senders of what an honest client never sends.
2. Client decode refusals become suspicion, minus W-124/W-126 (§3.5): already computed, free. Limit: anything
   encoded by Lync passes; Lync's own bugs are the FP source, hence "strong", not "certain".
3. The `Suspicion` event, bounded aggregation, decayed score, never-kick defaults (§6): turns every check into a
   signal the game can act on. Limit: a score is evidence for the game's ladder, never a verdict.
4. 16-bit keyed tag over the implicit `r` counter, cover 1024 B, lookahead 4, rekey on desync (§3.1): the one
   check fused into the data path; catches raw senders, replays, packet injection, below-encoder edits and blocked
   calls. Limit: an attacker who calls Lync's API, or reads `K` and keeps the counter in step, defeats it.
5. 12-bit sequence plus tag plus 64-frame window on upstream `u` (§3.2): closes replay on the lane that carries
   inputs. Limit: same as 4; ~3.5 B per `u` frame, partly repaid by dropping per-definition latest sequences.
6. Free consistency checks C1–C5 (§3.3): impossible replies are certain at no wire cost. Limit: catches fuzzers
   and hand-forgers only.
7. Declared-rate cadence check, weak (§4 T2): free, uses declarations that already exist. Limit: API drivers are
   throttled by Lync itself and never trip it.
8. Early-reply check and `roundTrip`/`ping` on results (§4 T3): free instrument. Limit: rarely fires; the real use
   is game-side analysis.
9. Per-server id shuffling (§3.4): zero run-time cost, kills byte-literal public scripts. Limit: one shared
   `getgc` query or any use of Lync's encoder defeats it everywhere.
10. The server-only `:trap()` API (§3.5): the only wire measure that catches API drivers browsing the schema.
    Limit: does nothing until the game declares traps; careful attackers fire only what honest code fires.

**Opt-in**
11. Clock-rate beacon (§4 T1): high precision, 2 B/s, but narrow coverage (clock-accelerating tools and forged
    stamps); off until a game wants it.
12. Per-session upstream shuffling and field-order shuffling (§3.4): marginal gain over 4 and 9, costs server
    memory or a few padding bits.
13. 32-bit tags and full 1 MB cover: only for games that hash large uploads; doubles tag bytes or scales CPU.

**Refuse**
14. Client environment, hook, identity and caller-source checks (§5): defeated by documented executor APIs, FP
    history, universal bypass across Lync games; they belong to a game's own anti-cheat.
15. Downstream tags and client-side replay windows (§3.1): protect only the attacker's own client view.
16. Frame whitening or XOR masking (§3.7): forfeits engine buffer compression (+62 % to +272 % measured with zstd)
    and stops nothing above the wire.
17. Any automatic kick, ban, throttle or client-visible rejection (§6.4): contradicts Roblox's guidance and turns
    library bugs into player harm.
