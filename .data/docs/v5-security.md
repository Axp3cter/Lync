# Lync v5: anti-forgery and plugins

The layer that makes forged packets expensive and visible, and the plugin pipeline that carries it.
Status: proposal for review. It builds on [v5-api.md](v5-api.md) (§2 rule 11, §4, §7.1),
[v5-goals.md](v5-goals.md) (Security), [v5-failures.md](v5-failures.md) (§4.3, §6) and
[v5-research.md](v5-research.md) (§1.1, §6).

**The claim that shapes the design.** An executor runs inside the client's Lua state, so nothing on the
client is a guarantee. Client features only raise the price of forging and give the server evidence.
Every hard guarantee is a server check, and §3 stands without §4.

**Not verified here.** No executor was run and no plugin types were probed. **(U)** marks an unverified
claim. Byte figures are arithmetic and CPU figures are guesses until §7 measures them.

## 1. What executors can do

Sources are executor-written documentation and DevForum threads, read through a summarizing fetch (quote
before relying on wording).

| Capability | What the sources say | Source |
|---|---|---|
| `hookfunction`, `hookmetamethod`, `newcclosure`, `checkcaller` | Standard executor functions. `hookmetamethod` wraps its hook in `newcclosure` itself, and `checkcaller` lets a hook tell executor calls from game calls. A hook can watch or rewrite any call, `FireServer` included, and pass game calls through untouched. | [sUNC closures](https://docs.sunc.io/Closures/) |
| `getgc`, `getupvalues`, `setupvalue`, `getstack` | Read and write live closures' upvalues, constants and stack; `getgc` and `filtergc` list and filter live objects. They work on Lua closures, not C closures, so all of Lync's client code is readable and writable. | [debug](https://docs.sunc.io/Debug/), [environment](https://docs.sunc.io/Environment/) |
| `getconnections` | Returns executor-made objects that can run, disable or enable any connected listener. | [signals](https://docs.sunc.io/Signals/) |
| Identity | `getthreadidentity`, `setthreadidentity` and `getcallingscript` are in the standard. | [sUNC](https://docs.sunc.io/) |
| Call-stack checks | Executor functions may show up in game code's `debug.info`. A 2025 detector based on environment leaks drew replies that modern executors already patch it and that `newcclosure` does not hide the stack. A 2023 namecall-protection trick stopped working in update 665. A 2026 remote-spy detector drew "bypassable" replies. No source says `debug.info` results cannot be spoofed, so assume they can **(U)**. | [2025](https://devforum.roblox.com/t/detection-of-almost-any-hookmetamethod-and-getrawmetatable-exploits/3847679), [2023](https://devforum.roblox.com/t/anticheat-methods/2662072), [2022](https://devforum.roblox.com/t/detect-every-function-hooked-by-exploiters-metamethod-hooks-included-with-this-one-simple-trick/1645194), [gist](https://gist.github.com/53845052/0082bffbd5bea8c24f1746f8e686e699) |
| Origin of a call | Developers expect any caller-origin signal to be spoofed once relied on. | [thread](https://devforum.roblox.com/t/trigger-origin-remote-event/4005356) |
| Platform | Hyperion anti-tamper has guarded the 64-bit Windows client since May 2023, which raises the cost of injecting; no source gives a current capability matrix. | [Roblox wiki, via mirror](https://breezewiki.discard.no/roblox/wiki/Hyperion) |
| Official stance | Exploiters control local state and network traffic and can fire remotes at any rate with any arguments. | [security tactics](https://create.roblox.com/docs/scripting/security/security-tactics) |

**Assumption for the rest of this document:** the attacker can read and write all client Lua state and
replace any client function. Lync is open source, so no client logic is secret; only per-session values
and the server's policy are.

## 2. Threat model

Each attacker row includes the one above it.

| # | Attacker | Does | Stopped by | What remains |
|---|---|---|---|---|
| A0 | Raw sender | Fires the Lync remote with any argument, size or rate | Strict decode, budgets (§3) | Nothing gets through |
| A1 | Replayer | Records valid frames with a remote spy and resends them | Replay window, session-bound tag | A fresh tag per frame, which is A3 |
| A2 | Static forger | Writes a packet builder from the public source and format | Per-session ID permutation, keyed tag (§4): the builder must learn the session record on every join | Must run inside the session; a blind frame is flagged `BadTag` |
| A3 | Extractor | Reads the session record with `getgc` or `getupvalues` and builds valid frames | Server authority only | Extraction code per Lync version; every frame is valid |
| A4 | Library driver | Calls the client's own `fire` with chosen values | Server authority; attestation flags it | The hard case: valid frames, hostile values |
| A5 | Hooker | Hooks `FireServer`, `debug.info` or the stamp closure; rewrites bytes after stamping; spoofs attestation | Server authority only | Defeats every client signal |
| A6 | Disabler | Deletes scripts, disables listeners with `getconnections`, spoofs identity | Server authority only | Nothing client-side survives |

**Consequence.** Client features pay off against A0 to A3: copy-paste forgers that work across sessions
and games, which are the mass-produced kind. They also yield evidence. A4 to A6 are bounded by §3 alone,
so §3 is exhaustive and §4 is weighed item by item.

## 3. Server authority

Hard guarantees. None depends on the client behaving.

### 3.1 The inbound path

| # | Step | Level | Cost |
|---|---|---|---|
| 1 | Exactly one argument and it is a `buffer` | frame | O(1) |
| 2 | Budget: per-player token buckets for frames and bytes, from `buffer.len` | frame | O(1) |
| 3 | Integrity: strip trailer, expand sequence number, replay window, tag (§4.4) | frame | O(frame bytes) |
| 4 | Strict decode of the whole frame, all or nothing | frame | O(frame bytes) |
| 5 | `limit` | message | O(1) |
| 6 | `validate` | message | user code |
| 7 | `intent` | message | user code |
| 8 | User plugins | message | user code |
| 9 | `connect` listeners, each in its own thread (failures §4.2) | message | user code |

Frames never inflate or decode before step 3 accepts them, so a decompression bomb costs a hostile
client one budget unit.

### 3.2 Strict decode

Core, not a plugin. The decoder refuses:
- **non-canonical input:** trailing bytes, nonzero padding bits, non-minimal varints. A value has exactly
  one encoding;
- **unchecked sizes:** every count and length is checked against the remaining bytes and the declared
  maximum before anything is allocated;
- **out-of-range values:** NaN and infinity unless the codec allows them (the float policy is still open,
  goals §1), integers outside bounds, enum, `oneOf` and `union` ids out of range;
- **bad sidecars:** an instance sidecar must be consumed exactly, and each instance is class-checked.

**A frame is delivered whole or not at all.** A message cannot be parsed past a malformed one, and a
forged frame must not smuggle a valid message ahead of garbage. So the frame is decoded fully before the
first message is dispatched, and any structural failure drops the frame as `Malformed`. A message refused
by `limit`, `validate`, `intent` or a plugin drops only itself.

### 3.3 Budgets and limits

- **Budget.** `Net:budget({ frames = …, bytes = … })` per player per second, on the server view. An
  over-budget frame is dropped undecoded and reported as `OverBudget`. Nothing disconnects. With the
  budget, worst-case decode CPU per player is bounded by bytes per second times decode cost per byte
  (checked at 100 players in §7). Defaults come from M5; none is stated here.
- **`limit(perSecond)`.** A token bucket per player and definition whose capacity is one second of
  burst. An event declared `:latest(rate)` gets an implicit limit of `2 × rate`, since an honest client
  already throttles itself to `rate`.
- **Requests.** A reply is matched on (player, request id) and unsolicited replies are dropped, so a
  client can only answer its own pending requests. Pending requests per player are capped.

### 3.4 Sequence numbers and the replay window

Every client frame carries a 16-bit sequence number (§4.4); the server expands it to a full counter. The
tag covers the full value, so a wrong expansion fails the tag.

| Lane | State | Accept | Otherwise |
|---|---|---|---|
| Reliable | `next` | verified frame with seq at or above `next`, then `next = seq + 1`. Gaps are fine: frames the budget dropped leave one. | `Replayed` |
| Unreliable | `top`, plus a 64-bit bitmap of seen seqs below it | verified and ahead of `top` (the window slides), or within 64 behind and unseen | `Replayed` if seen, `Stale` if older than the window |

The tag is checked before any state moves, so a forger who fails it cannot slide the window or advance
`next`. Counters start at zero per session. The window size is tuned by M5.

### 3.5 Validate and intent

Both return a reason or `nil`, as in [v5-api.md](v5-api.md) §4. The difference is what a rejection
means.
- **`validate`** is a stateless sanity check on the value. A failure means the value is impossible.
- **`intent`** asks whether this player may do this now, so it reads game state. A failure may be an
  honest race: a swing that arrives after the player died. It runs after `validate` and carries a separate
  reason so punishment can treat the two differently.

```luau
Net.sell:validate(function(item, player)
	return if item == "sword" or item == "shield" then nil else "unknown item"
end)

Net.sell:intent(function(item, player)
	return if inventory[player][item] then nil else "player does not own the item"
end)
```

### 3.6 Punishment is the observer stream

Lync never kicks, bans or throws on its own. It emits typed events through `Lync.observe`
([v5-failures.md](v5-failures.md) §6), and the user acts on them. Additions to the union:
- `Dropped.reason` gains `"Malformed" | "OverBudget" | "BadTag" | "Replayed" | "Stale" | "RateLimited" |
  "Invalid" | "Intent" | "Rejected" | "Trap"`; `Rejected` carries the plugin's name and reason.
- `{ kind: "Suspicion", player, signal, weight }` is for evidence that does not refuse anything:
  attestation, or `Lync.suspect(player, signal, weight)` called from game code or a plugin.

Default weights count only what an honest client does not produce:

| Event | Honest client can cause it | Default weight |
|---|---|---|
| `Malformed`, `BadTag`, `Trap` | No | 10 |
| `OverBudget` | Only a broken client | 3 |
| Attestation flag | Rarely | 3 |
| `Replayed` | Rarely, on a duplicated unreliable frame | 2 |
| `RateLimited`, `Invalid`, `Stale` | Sometimes | 1 |
| `Intent` | Yes, in races | 0 |

An opt-in helper turns events into action, and it does nothing until connected:

```luau
Lync.observe(Lync.escalate({
	window = 60,
	threshold = 20,
	act = function(player, report) player:Kick("unusual traffic") end,
}))
```

## 4. Client cost-raising and detection

No client feature refuses a send because of a signal. Each adds cost for the attacker or evidence for the
server.

| Item | Adds | Wire | CPU | Defeated by | Default |
|---|---|---|---|---|---|
| Session record | The per-session key and seed everything below needs | About 18 B once per join | Composition at join, O(definitions) | Reading it from memory (A3) | On: it is the mechanism |
| ID permutation | Hard-coded and recorded frames stop working across sessions | 0 | 0 per message | A3 | On |
| Field-order variants | The same, at payload level | 0 | Server decodes K layouts | A3 | Off |
| Integrity trailer | Binds a frame to the session, a sequence number and the attestation | +4 B per frame | One mix pass per side | A3, A5 | On, gated by M1 and M3 |
| Caller attestation | Flags a call that does not come from a game script | 0, it rides in the tag | One `debug.info` walk per sampled fire | A5, or a call from a game closure | On, sampled, flag only |
| Honeypots | Catches scripts that fire everything | 0 | 0 | A4 that knows the traps | Off until declared |
| Closure hygiene | Extraction work per Lync version | 0 | 0 | A3 | Always |

### 4.1 Session record, not a session schema

At join the server sends each client a **session record** over a reliable call: format version, a
feature set, a key (two u32) and a seed (two u32). It is never broadcast and never placed in a replicated
Instance or attribute. A send made before the record arrives waits, as sends already do while joining.

This does not reverse [v5-api.md](v5-api.md) §7.1. The schema stays shared: transferring it would cost
typed client code and shared conversions, and hide nothing. Only what varies per session travels, so the
record is about 18 B, not a schema. The key's strength does not matter, because the client holds it. What
matters is that it differs per session and reaches no one else.

### 4.2 Permutation

- **IDs.** A seeded shuffle of the id space, applied when the client's writers are composed, so there is
  no per-message cost. The server keeps a `buffer` of u16 per player (2 B per definition) to invert it.
  IDs keep their width, so a frame's size is unchanged.
- **Client to server only.** The server encodes once per distinct message and sends to every recipient.
  A per-session layout in that direction would force one encode per player. A forger needs the upstream
  format, not the downstream one.
- **Compressibility.** A fixed relabelling repeats exactly as often as the original, so zstd sees the
  same redundancy **(U until M3)**. Within one session the same id is the same byte.
- **Field order** needs a decoder per layout on the server. A per-session shuffle would cost a decoder
  per player and definition and a slower loop instead of composed closures. Offering K shared layouts
  bounds that, but K layouts add few bits next to the ID shuffle. Off by default; `layouts = K` opts in.

### 4.3 Honeypots

`Lync.event(schema):trap()` declares a definition the client view's type hides but its runtime table
holds, under the name the user chose. A user picks tempting names. Honest code cannot call it, because
it is a type error. The server never has a listener, and an arrival is a `Trap` drop at weight 10. The
cost is id space: width grows by one bit only when the count crosses a power of two.

### 4.4 Integrity trailer

Every client frame ends with `seq` (16 bits) then `tag` (16 bits).
- **Tag.** A keyed mix over the frame's u32 words, the full sequence number, the length and the
  attestation bit. Integer-only: a multiplier under 2^21 keeps every product exact in a double, so
  nothing depends on float behaviour (research §2.3). It is not cryptographic and does not claim to be.
  A test checks that a blind observer of many frames cannot cheaply recover the key (avalanche and
  linearity tests); A3 reads the key anyway.
- **Per-frame key = mix(session key, seq).** There is no chain. A rolling chain would make one dropped
  frame (a budget drop, a lost unreliable frame) desync the session for good. The "rolling" property
  comes from the sequence number.
- **Server.** Compute the body mix once, finish it for attestation 0 and 1, and compare. A blind forger
  passes with probability 2 × 2^-16 per frame, and fails loudly with `BadTag` otherwise.
- **Width.** 2 B. Four bytes is an option for games with high-value events.
- **Placement.** The tag covers the exact bytes handed to the remote, so verification precedes any
  decompression or decoding.

### 4.5 Caller attestation

- **Where.** At `fire`, on the caller's thread. That is the only moment the user's stack is visible, and
  the reason the plugin's `message` stage exists on the client (§5.1).
- **How.** Reuse the user-frame walk of [v5-failures.md](v5-failures.md) §4.1. The source of the first
  non-Lync frame is checked against the scripts under the game's services, cached per source string, so
  a repeat call is one table lookup. A foreign source sets the frame's attestation bit.
- **No false positives from style.** A call with no user frame (`task.spawn(event.fire, event, value)`)
  is honest code. It is not flagged.
- **Defeated by** a chunk named like a game script, a call made from a hooked game closure, or a hooked
  `debug.info`. What an executor's chunk reports as its source is executor-specific and cannot be
  measured in Studio **(U)**.
- **Why it rides in the tag.** A separate flag bit can be cleared by anyone who reads the source. Folded
  into the tag, clearing it means computing a valid tag, which is A3's work. The server learns it by trying
  both values.

### 4.6 Closure hygiene

Only practices that are also plain good style (goals: the quality of `src` is never lowered for a tool).
No decoy code and no contortions.
1. Capture engine functions once at load (`FireServer`, `debug.info`, `buffer` functions) and call them as
   plain functions, so a `__namecall` hook never sees the call. Whether an executor also hooks the C
   function is executor-specific **(U)**.
2. The session record lives only in the upvalues of the composed writer and stamp closures: no table
   field, no global, nothing a `filtergc` shape search finds by key name.
3. Nothing public exposes internals. `Lync.metrics` returns counts only, and `trace` prints decoded values.

## 5. Plugins

### 5.1 Model: two stages, three pipelines

| Pipeline | Order |
|---|---|
| Client outbound | `message` at `fire`, on the caller's thread, then encode and batch, then `frame` at flush |
| Server inbound | `frame`, then decode, then `message` |
| Server outbound | `message` once per recipient, then encode and batch, then `frame` |

1. **Plugins never change types.** A plugin accepts, rejects or observes. `connect`, `fire` and `handle`
   see exactly the schema's types, whatever is installed.
2. **Frame bodies are read-only.** In the zstd measurement (research §6) zeros cost 2.8 KB/s and random
   bytes 241.9 KB/s, so a masking plugin would forfeit compression. Per-byte work belongs at the frame
   level and per-message work stays O(1).
3. **Policy stays where it is installed.** Plugins attach to a view, so server plugins live in server
   scripts and never reach clients (rule 11). Client plugins are client code and ship.
4. **Handlers are plain, synchronous and must not yield.** They are protected like validators
   (failures §4.3): a raise drops the message or frame as `CheckRaised`, reported once per plugin per
   window.
5. **`nil` passes and a string rejects** with that reason, as in `validate`.

### 5.2 Writing one

A plugin is a function that installs stages on a definition or a view. There is no registry and no
declaration object.

```luau
-- Flags a player who fires faster than a person can click, without refusing the call.
local function inhuman(definition, minimumGap: number)
	definition:use("inhuman")
		:state(function(player) return { last = 0 } end)
		:inbound(function(value, player, state)
			local now = os.clock()
			if now - state.last < minimumGap then
				Lync.suspect(player, "inhuman", 2)
			end
			state.last = now
			return nil
		end)
end

inhuman(Net.strike, 0.05)
```

| Where | Method | Handler (server) | Handler (client) |
|---|---|---|---|
| Definition | `:inbound(fn)` | `function(value, player, state)` | none |
| Definition | `:outbound(fn)` | `function(value, recipient, state)` | `function(value, state)` |
| View | `:inboundFrame(fn)` | `function(body, player, state)` | none |
| View | `:outboundFrame(fn)` | `function(body, recipient, state)` | `function(body, state)` |
| Either | `:state(fn)` | `function(player)`, returns the state | `function()` |

- A view-level `:inbound` and `:outbound` also exist, for every definition. There `value` is `unknown` and
  the handler receives the definition's name last.
- `state` is created on a player's first message through the plugin, passed as an argument, and freed
  when the player leaves.
- Handlers follow rule 10: payload first, then sender, then state.
- **Types.** `use` returns a builder, and every handler is passed as a function argument, so its
  parameters are inferred (api §9, the verified fact about arguments versus properties). That the
  `state` type reaches later handlers is unverified and needs a probe **(U)**.
- `limit(n)`, `validate(fn)` and `intent(fn)` are sugar for `:inbound` handlers with fixed ranks.

### 5.3 Composition order

1. Stage order is fixed per pipeline (§5.1).
2. Within a stage, built-ins hold fixed ranks and user plugins follow in installation order, view level
   before definition level. Inbound: `budget`, `integrity`, then user frame plugins; `limit`, `validate`,
   `intent`, then user message plugins.
3. Outbound, user plugins run first and `integrity` runs last, so the tag covers the final bytes.
4. The first rejection wins. Later plugins do not run, and the event names the plugin.
5. Trailer fields are appended in rank order and stripped in reverse.

### 5.4 Zero cost when unused

`use` rebuilds one chain at setup: plain closures composed by arity, with no list, no loop and no table
per message. A stage with no handlers is compiled out, so a definition without inbound plugins runs the
same dispatcher as a build without the plugin system. State costs one array read, because the
per-player record is already in hand at frame level. A feature that is switched off is never composed.
M7 checks this against the bench noise threshold.

### 5.5 The built-ins are plugins

| Built-in | Installed as | Side |
|---|---|---|
| `budget` | view `inboundFrame`, rank 1 | server |
| `integrity` | view `outboundFrame` (client, last) and `inboundFrame` (server, rank 2); owns the trailer | both |
| `attest` | view `outbound` on the client; sets the attestation bit that `integrity` reads | client |
| `limit`, `validate`, `intent` | definition `inbound`, ranks 1 to 3 | server |
| `permute` | not a stage: applied when writers and decoders are composed | both |
| `trap` | not a stage: resolved in the decoder's header read | server |

Strict decode is core, and there is no way to switch it off. Frame trailers are not public in 5.0
(§8.9).

**One switch.** `Lync.namespace(definitions, { forgery = "standard" })` is the default and means
`permute`, `integrity` and `attest`. `"off"` turns all three off. The option sits in the shared
namespace because it changes the wire, and the client learns the server's choice from the session
record. Server authority does not depend on it.

### 5.6 Batching and compression

- A message plugin costs once per message. A frame plugin costs once per frame, amortized over the batch.
  Trailer cost is per frame, never per message.
- The client's `message` stage runs inside `fire` and must be cheap. The server's outbound `message`
  stage runs per recipient, so a definition that has one loses encode-once fan-out. Definitions without
  one keep it.
- The `frame` stage sees exactly the bytes handed to the remote. If v5 adds `EncodingService`
  compression (research §1.1), it sits between encode and stamp. The tag covers the compressed bytes,
  and the server verifies, then checks `GetDecompressedBufferSize` against the budget, then inflates.
- Roblox compresses the call after Lync hands it over, so Lync's tag does not interact with it.
  Trailer bytes are pseudo-random, so they cost their full size on the wire. They also count in full
  against the 1000 B unreliable limit, which is measured after compression, so the batcher reserves the
  trailer size from every unreliable frame.

## 6. Wire format impact

Client to server, with `forgery = "standard"`:

```
frame   = message* trailer
message = id' body            id' is permuted and keeps the width of id
trailer = seq:16 tag:16       whole bytes, after the body's padding to a byte boundary
```

Server to client is unchanged.

| Feature | Per frame | Per message | One-time or memory |
|---|---|---|---|
| Strict decode, budget, `limit`, `validate`, `intent`, plugins | 0 | 0 | 0 |
| ID permutation | 0 | 0 | 2 B per definition per player on the server |
| Field-order variants | 0 | 0 | K decoder sets on the server |
| Integrity (seq and tag) | +4 B client to server | 0 | 0 |
| Attestation | 0, one bit inside the tag | 0 | 0 |
| Honeypots | 0 | 0 | id width +1 bit when the id count crosses a power of two |
| Session record | none | none | About 18 B, plus about 9 B of call overhead (research §1.1), once per join |
| Closure hygiene | 0 | 0 | 0 |

**What 4 B per frame means.** A client call already costs about 14 B of overhead, so a tiny frame grows
about 29% and a large one barely. At the most frames a client can send, 60 per second, the trailer is
240 B/s per client. Batching amortizes it, so chatty small frames pay most.

## 7. Studio measurement plan

Each needs a number before the matching default is final. Gates are proposals.

| # | Question | Method | Proposed gate |
|---|---|---|---|
| M1 | Cost of the mix and stamp | `os.clock` over 50, 200 and 1000 B frames, client interpreter and server native, against the cost of encoding the same frame | At most 10% of encode plus flush at 200 B |
| M2 | Cost of attestation, and what a non-game chunk reports as its source | `debug.info` walk at depths 1 to 4; a command-bar chunk as a proxy (not an executor) | Sets the sample rate; at most 2% of `fire` |
| M3 | Wire bytes with the trailer, ID permutation and field order | Same traffic at three settings; the harness's own byte count, `Stats.DataSendKbps` as a sanity check | Permutation within noise of off; trailer within 1 B of +4 B after zstd |
| M4 | Server memory and CPU of per-session state | Join cost at 50, 200 and 500 definitions; ID buffers at 100 players; K layouts; allocation over many iterations | Join under one frame of CPU |
| M5 | Budget defaults and window size | Legitimate scenarios' frames and bytes per second per player, under `NetworkSettings` delay, jitter and 0.5% loss | Zero false `OverBudget`, `Replayed` or `Stale` on honest traffic |
| M6 | Replay window correctness | Fault-injecting transport with loss, duplication and reorder, property tested | Every replay refused; no honest reorder inside the window refused |
| M7 | Zero-cost claim | Bench a definition with no plugins against the build without the plugin system, then 1, 3 and 5 plugins per stage | Equal within the bench noise threshold |
| M8 | Efficacy | An in-process adversary for A0 to A4 on the simulated transport; one test per row of §2 | Every row stops what it claims |

M8 is the only efficacy test possible in Studio. Client-side cost-raisers are measured for cost, not for
how well they stop a real executor. Running third-party executors against the project is out of scope.

## 8. Open decisions

| # | Decision | Recommendation | Whose call |
|---|---|---|---|
| 1 | Ship `forgery = "standard"` on by default | Yes, if M1 and M3 pass. It costs 4 B per client frame and buys deterrence against A0 to A3 only. | The user's: bytes against deterrence |
| 2 | Tag width | 2 B, with 4 B as an option | Mine |
| 3 | Field-order variants | Off; revisit once M3 and M4 are in | Mine |
| 4 | Permute client to server only | Yes; keeps encode-once fan-out | Mine |
| 5 | Whole-frame atomic delivery | Yes (§3.2) | Mine |
| 6 | Ship `Lync.escalate` as an opt-in helper, with no auto-kick | Yes | The user's, since it touches punishment |
| 7 | Default weights | Ship the §3.6 table, tune from playtests | The user's |
| 8 | Attestation sample rate | Start at 1 in 4, set by M2 | Mine |
| 9 | Public frame trailers for user plugins | No, not in 5.0. Built-ins prove the mechanism first; the public stages cover most plugins. | Mine |
| 10 | Honeypots | Off until declared; type-hidden | Mine |
| 11 | Docs call this "anti-forgery", never "anti-cheat", and say A4 to A6 are bounded by server checks alone | Yes | The user's |
| 12 | `Lync.namespace(definitions, options)` and the new methods (`use`, `intent`, `budget`, `suspect`, `escalate`, `trap`) change v5-api §4 and §7, and the event union in failures §6 | Fold in once approved | The user's: the API is theirs |
| 13 | Plugin types need a probe like `ApiTypes.luau` before the API is final | Yes | Mine |
