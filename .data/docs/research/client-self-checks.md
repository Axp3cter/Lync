# Client self-checks: three measures the docs never decided (U1, U2, U7)

Researcher findings, 2026-10-15. Re-judges items U1, U2 and U7 of `research/security-refusals.md` §4 for the
design pass. Each item states how it works in Lync, what it prices (capability classes of
`research/client-security.md` §1.2, named as in `research/security-tooling.md` §9), what it doesn't, its measured
cost, how it fails on an unmodified client, and its options where it adds any. No verdicts on players; every fact
proposed here has an exact trigger and evidence, and Lync takes no action beyond dropping malformed input.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs. **reported**: third party.
**unverified**: my inference or not yet measured.

**Runs.** Luau source in `.data/projects/luau` (stated by the lead as 0.742; the tree carries no version string),
built with CMake as `luau` and `luau-compile`, run interpreted (`-O2`, and `-O1` where noted) because clients run no
native code; `--codegen` only for server-side figures. Intel Xeon 2.1 GHz, 4 cores, shared machine; best of 7
batches minus an empty loop. Roblox devices are slower by an unmeasured factor. Type checks used the luau skill
(luau-lsp 1.70.1, Roblox definitions). Probes and outputs: `.data/docs/probes/client-self-checks/`. Engine facts on
the client side: `research/security-tooling.md` §2.

**The milestone build** (`f1fbfd7`, in git history) is the reference for "what Lync does today":
`f1fbfd7:src/host/roblox.luau`, `src/transport/tag.luau`, `src/wire/halfsiphash.luau`.

## Checklist

- [x] U1: capture `FireServer` once and call the captured function
- [ ] U2: per-build variation of the tag function beyond its two constants
- [ ] U7: `debug.info` caller information folded into the tag
- [ ] Implications

---

## U1. Capture `FireServer` once, call the captured function

**Today.** The milestone build calls the method by name on every send:
`(remotes.reliable :: RemoteEvent):FireServer(frame, instances)` (`f1fbfd7:src/host/roblox.luau` line 165, and
167 for the unreliable remote). That compiles to `NAMECALL … ['FireServer']` + `CALL`, which goes through the
remote's `__namecall` metamethod. So the docs' open question ("whether the runtime already does this",
`security-refusals.md` U1) has the answer **no** (verified, source).

**Mechanism.** When the client transport finds each remote, it reads the method once and keeps it:
`fireReliable = reliable.FireServer` and `fireUnreliable = unreliable.FireServer`. Every send then calls
`fireReliable(reliable, frame, instances)`. This compiles to one `GETTABLEKS … ['FireServer']` per remote at
capture and a plain `CALL` per send, with no `NAMECALL` (`probes/client-self-checks/capture.luau`,
`capture.out`). It type-checks clean under the new solver with Roblox definitions (verified, `capture.out`). The
capture happens when the remote is found, not when the shard loads, since the client waits for
`ReplicatedStorage.Lync` (v5.md §4.1). It is one implementation line in the transport, with no API, wire or
option change.

**What it prices.**
- *Hooking functions and metamethods*, in its `__namecall` form only. A spy that hooks the remote's
  `__namecall` and filters on `getnamecallmethod()` sees calls made with `:FireServer(...)`, and never sees a
  plain call of a captured function. This is SimpleSpy v3's default mode and one of Hydroxide's two hooks
  (verified by reading their sources, `client-security.md` §1.3). Such a spy then shows no Lync traffic, where
  today it shows opaque buffers.

**What it does not price.**
- *Hooking functions*, in place: `hookfunction(remote.FireServer, …)` "replaces func with hook globally", so the
  captured reference is the hooked function (`rawequal` stays true). SimpleSpy's optional mode and Hydroxide's
  second hook use this (documented and verified by reading, `client-security.md` §1.2–§1.3).
- *Hooking metamethods before Lync loads*: executors can run before game scripts (`client-security.md` §1.1). A
  hooked `__index` in place at capture time hands Lync whatever it returns.
- *Packet-level send and receive hooks* (Cobalt on executors with `raknet`) and *reading the client's own code*:
  untouched.
- API drivers and extractors: untouched; they go through Lync, not around it.

**An engine fact that bears on it (unverified on Roblox).** The Luau source has a direct userdata method path: at
load, every `NAMECALL` whose method name has an atom is rewritten to `NAMECALLUDATA` (`VM/src/lvmload.cpp` lines
684–702). When the host has registered a direct namecall handler for that userdata tag
(`lua_registeruserdatadirectaccess`, `VM/src/lapi.cpp` line 2093), the VM calls that C handler directly with a
copy of `__namecall` taken at registration, without calling the metatable's current `__namecall` closure
(`VM/src/lvmexecute.cpp`, `LOP_NAMECALLUDATA`, from line 3560); without a handler it falls back to `NAMECALL`.
Whether Roblox registers this for `Instance`, and what it does to `__namecall` spies, I could not establish. If it
does, U1's difference from today may shrink. Game code can't install a `__namecall` hook on an `Instance`, so this
can't be observed from a game script; it stays unverified.

**Cost** (verified, `cost.out`, CLI stand-in: a userdata whose `__namecall` is a C function).

| Form | `-O2` | `-O1` |
|---|---|---|
| `proxy:FireServer(frame)` (`NAMECALL`, today) | 45.1 ns | 43.0 ns |
| `proxy.FireServer(proxy, frame)` (index on every call) | 69.1 ns | 66.5 ns |
| `captured(proxy, frame)` (U1) | 44.0 ns | 34.6 ns |

The captured call costs the same or up to 8 ns less in the VM's dispatch. The engine's own work inside
`FireServer` is unmeasured (v5.md §10) and identical either way. Zero bytes, no options, no maintenance beyond the
line. Developer cost: none.

**Failure on an unmodified client.** U1 is not a check, so it produces no fact and no false fact. Its failure
modes are functional:
- capturing before the remote exists (the capture must follow the remote watch);
- a remote replaced after capture: whether the engine returns one function per class or per instance is
  unverified, so the transport captures again whenever it finds a new remote and passes that remote as `self`.

Neither changes any wire byte.
