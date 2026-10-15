# `strings`: downstream string tables and upstream references

Researcher findings, 2026-10-15. **Decision it feeds:** the full specification of the `strings` mechanism, so the
wire unit can put it in `v5.md` §4 (`design/v5-3.6-changes-wire.md` entries 32 and 34 held it: R33 form A
references "entries of downstream tables the server sent", and no design file defines those tables;
`design/v5-extensions.md` points `strings` to `v5.md` §4, which holds none of it). Inputs read in full:
`research/refusals-rejudged-1.md` R33, `research/compression.md`, `design/v5.md` §3.3, §3.4, §4.1–§4.10, §5, §6.1,
§7.3–§7.5, `design/v5-collections.md`, `design/v5-3.6-changes-wire.md`, `research/security-refusals.md` R33.

**Labels.** **verified**: I ran it or read the source/design text. **documented**: the design or official docs say
so. **reported**: a third party says so. **unverified**: inference, or nothing found. Design statements I propose
are marked **proposed**; each says what decides it.

**Tools.** Luau 0.742 built from `.data/projects/luau` (scratch build), `-O2` interpreted (clients) and
`-O2 --codegen` (servers); same shared 2.1 GHz Xeon as the earlier probes, CLI timings show scale only. The traffic
models are `probes/compression/traffic.py`, unchanged (same seeds and lengths as `sim_strings.py`).

**Probes** (`.data/docs/probes/strings/`, all by `sh run.sh BUILD_DIR`, Luau probes 3 runs per mode):
- `strings_cost.luau` → `strings_cost.out`: server encode, entry creation, upstream decode, client decode of
  references and definitions, heap per entry, bitset and free list;
- `strings_model.py` → `strings_model.out` (`python3 -B`, no caches): bytes per second per recipient on the shooter,
  mmo and tycoon models, inline against interned, with the framing of §1.3 charged; the join catch-up's id column;
- `golden_strings.luau` → `golden_strings.out`: the schema serialization and four frames under the proposed grammar
  (helpers copied from `probes/design-3.6/golden_wire.luau`).

## Checklist

- [x] 1. Downstream tables
- [x] 2. Upstream references
- [ ] 3. Cost and saving
- [ ] 4. What it protects and what it doesn't
- [ ] 5. Facts, counters, codes and options
- [ ] 6. Text for `v5.md` §4 and the golden vectors
- [ ] Implications

---

## 1. Downstream tables

### 1.1 Which strings enter a table: the developer's declaration

**Proposed.** Lync can't tell which strings repeat (compression §5: interning whole formatted strings filled the
tycoon's table with 975 entries in 5 minutes; templates fixed it), so which fields intern is declared, and every
value of a declared field enters, by one rule with no judgement:
- **A table** is a schema entry: `names = Lync.strings({ maxEntries = 64 })` beside the definitions. It belongs to
  its namespace (the unit of schema, hash and `HELLO`), so two namespaces never share one.
- **A field** joins it with the codec method `t.string(20):intern(names)`, the only way a value enters. Any set of
  fields of the namespace may share one table (a kill feed's `killer` and `victim`, a record's `name`, a chat
  sender), so scope per field, per definition, per collection or per namespace is the developer's grouping.
- **Which values:** every value the server sends in an interned field becomes an entry the first time it is sent,
  while the table has room (§1.4). Nothing is counted or guessed: no "second sight", no frequency.
- **Placement** (declaration error `internPlacement` otherwise): on a `t.string` only (a `t.buffer` entry would need
  a copy per decode, since buffers are mutable and Luau strings are not); anywhere a `t.string` may stand (record
  fields, optionals, arrays, map keys and values, union variants, a collection `key`, under `:claim()`/`:input()`
  and `t.convert`), except: in the `data` of an unreliable server-sent event (§1.3, "Unreliable lane"), and in a
  sealed event's `data` (the seal hides the payload, so a definition inside it would reach the client only at the
  reveal, while the server would already count the entry as held; and at the default `sealed.hideLength = true`
  the payload is padded to its worst case, so a reference saves no byte, `v5-checks.md` §9). A table no codec
  marks is `stringsUnused`; `:intern(x)` with `x` not an entry of the same schema is `internTable`. A server-view
  `:canary()` on an interned field already throws `canaryInterned` (`v5-integrity.md` §9, verified in the text).
- **Client type** stays `string`; generated types don't change.

### 1.2 Decision: who owns a table

- **Problem.** Downstream chunks are encoded once and copied to every recipient (`v5.md` §4.2), so a value's bits in
  a shared chunk can't depend on the recipient. A table that numbers entries per recipient breaks that; a table
  shared across recipients must not tell one recipient what another was sent.
- **Options:**
  - (a) **Per viewer** (compression §5's per-connection table): exact, but a chunk carrying an interned value is
    no longer one encoding: per-viewer encodes, and no `FireAllClients` (`v5.md` §4.2). Server memory 64 B per
    entry per viewer (two maps, §3.3): 57.6 KB for the kill feed's 30 names at 30 viewers, against 1.9 KB shared.
  - (b) **Per audience** (R33's wording, "the order the server first sent each to this player"): undefined for
    event targets (any player list) and for cell chunks, whose recipients change with every viewer's block
    (`v5-collections.md` §8.4).
  - (c) **One table per server, definitions inside the shared chunk** (a value is "define k" when some recipient
    lacks k): one encoding per chunk, but a recipient that holds k and reads "define k" learns that some
    co-recipient lacks it. A cell chunk's recipients are the viewers whose block covers the cell, so that bit tells
    a viewer that another viewer has just come near: the information interest exists to withhold (verified by the
    grammar: `v5-collections.md` §8.4 makes the cell chunk's recipient set exactly that).
  - (d) **One table per server, definitions in each viewer's own strings chunk**: shared chunks carry only
    references (or literals, §1.4); each recipient that lacks an entry gets its definition in a per-viewer chunk
    placed before every chunk that uses it.
- **Choice: (d), with entry ids drawn at random among free ids.** Shared chunks stay one encoding whatever each
  recipient holds, so they say nothing about co-recipients; the per-viewer part is exactly the definitions a viewer
  lacks, which it would otherwise have received as literals. Ids are random, as collection slots are
  (`v5-collections.md` §2), because sequential ids would tell each viewer how many entries the server created for
  others (§4.2 derives that random ids tell it nothing).
- **Owner.** The server, per (server, namespace, table): one id → string map, one string → id map, a free-id list
  and a holder count per id; per (player, table) one bitset of the ids committed to that player (§1.4).

### 1.3 How entries are added and announced on the wire

- **A value of an interned field** (both directions): `entry:u1`; 1: `id:u(w)`, w = ⌈log2 `maxEntries`⌉; 0: the
  plain `t.string` encoding (length u(⌈log2(maxBytes + 1)⌉), bytes in the tail). A literal costs 1 bit more than
  today's `t.string`; a reference 1 + w bits. Single rows only use this form; in column blocks the field flattens as
  a two-variant `t.union` (variant 0 literal: its length column, bytes to the tail; variant 1 entry: its id column on
  [0, `maxEntries` − 1]), so `v5.md` §4.3's union rule and residuals apply unchanged.
- **Definitions** travel downstream only, in **strings chunks**, carried by namespace 0's state segment. Namespace
  0 is control and has no collections, so `segs(state)` never names it today; ascending namespace order then puts
  it before every other state chunk, and all state chunks precede runs (`v5.md` §4.1), so a definition always
  precedes every reference in its frame. Frames and namespaces without definitions pay nothing.
  ```
  strings chunk := ns:EG0 { count:EG0, then count × { id:u(w_t) length:u(L_t) } }   -- one list per table of ns,
                                                                                   -- in table index order
  ```
  w_t = ⌈log2 `maxEntries`⌉ of table t; L_t = ⌈log2(m_t + 1)⌉ with m_t the largest `maxBytes` among the `t.string`
  codecs marked with t; bytes in the tail (general rule, `v5.md` §4.2). Tables are numbered from 0 in name order
  within the namespace. One strings chunk per namespace per frame, chunks in ascending `ns`, ids strictly ascending
  within a list.
- **Who gets which definition.** At each flush, for every chunk the server encodes and every recipient r of it
  (its recipient set is known before encoding: targets, partition members, the viewers whose block covers a cell,
  `v5-collections.md` §3, §8.4): for each interned value s, if s is no entry and the table has room, create it
  (random free id); if s is an entry and r's bit for it is 0, append the definition to r's strings chunk for this
  flush and set the bit. The shared chunk writes `entry 1, id`. When the chunk goes to every player welcomed for the
  namespace and the entry's holder count equals their number, the per-recipient tests are skipped (exact: bits are
  set only for welcomed players).
- **Encode-once and `FireAllClients`.** A strings chunk is encoded once per distinct definition list in a flush (a
  new kill-feed name sent to everyone gives one list). Frames stay identical for every recipient when their
  definition lists are equal; that is decided from the lists, never by comparing buffers (`v5.md` §4.2's rule,
  extended). A recipient with a different list (a recent joiner) makes that flush per player, as catch-up and
  canary copies already do.
- **Splits.** Each part of a split frame carries the definitions for the references in that part, in its own
  strings chunk; the first part referencing an entry carries it (the bit is set then, so later parts reference it).
- **The `WELCOME` frame.** A namespace's chunks can't precede its `WELCOME` (rule 7: "a chunk for a namespace not
  welcomed when it is decoded"), and the `WELCOME` is a run, after every state chunk, so the frame carrying a
  player's `WELCOME` for N can carry no definition for N. Rule: the server's join hold (`v5.md` §5.3) encodes held
  messages of N with literals at hold time, so the 32,768 B charge stays the exact encoded size; and a player whose
  `WELCOME` for N goes in this flush is not a recipient of N's shared chunks of this flush: what they carry for it
  joins its hold, released after the `WELCOME` in the same frame. From the next frame, references.
- **Literal or reference is the encoder's choice**, as column mode is (`v5.md` §4.3, §4.8): both decode. The
  reference encoder writes a literal exactly when the value is no entry and the table is at a cap, or the message is
  held (above).
- **Decision: unreliable lane.** An unreliable server event can't carry references. An unreliable frame can arrive
  before the reliable frame holding the definition, so a reference is exact only for an entry the server knows the
  client decoded. The only signal is the upstream receipt `rcv` (`v5.md` §4.1), which a client 256 frames behind
  (a 4.3 s stall at 60 frames/s) extends upward and so reads as received early: the client would then refuse an
  unreliable frame, a new known cause of `refusedFrames`/`reportedRefusedFrames` for an unmodified client. State-frame
  acks say nothing about the reliable lane. So `:intern` inside an unreliable server event is `internPlacement`, not
  a silent literal. Cost: such events keep inline strings; none of the four models has one (`traffic.py`: strings
  are kill feed, names on enter, tycoon labels/notifications/purchases, chat, all reliable). Client-sent unreliable
  events may carry references (§2): the client only references what it holds.

### 1.4 Limits, lifetime, and what survives what

- **Caps** (shared schema, hashed, so both ends know them): `maxEntries` (ids) and `maxBytes` (sum of live entries'
  lengths). A value is created as an entry only when live entries < `maxEntries` and live bytes + its length ≤
  `maxBytes`; otherwise it travels as a literal (counter `stringLiteralsFull`, §5). Nothing else changes at a cap:
  no fact, no refusal.
- **No eviction of a held entry; reclamation when no connected player holds it.** Each id has a holder count: +1 when
  a player's bit is set, −1 for each set bit when that player's connection ends (a scan of its bitset). At 0 the id
  returns to the free list and its string leaves both maps. Exact: a client references only ids it holds, every
  held id has its bit set, and bits are never cleared during a connection, so no frame from a connected player can
  name a reclaimed id; a reused id reaches only players whose bit for it is 0, who never held the old value. No
  message is sent. Leaves are applied at the start of a flush, so no encode in progress holds a reclaimed id.
  Without reclamation a long server fills its table with departed players' names (at 3 new names a minute, 64
  entries fill in 11 min, chosen churn); with it, live entries are bounded by what connected players hold.
- **Why not LRU or explicit eviction.** Evicting an entry a client holds needs the client to stop referencing it
  before the server reuses the id; a reference sent before the client learned of the eviction would resolve to the
  new string, a wrong value delivered. That needs an acknowledgement per eviction; append-only also beat LRU-64 on
  the Zipf item names (101 against 160 B/s, compression §5).
- **Survival.** Reliable downstream is ordered and lossless for the connection (`v5.md` §4.1), so loss and reorder
  don't touch tables; client-sent references in lost or reordered unreliable frames change no table state. `REKEY`
  doesn't touch tables (they don't depend on key or count). Respawn changes nothing (Lync holds no per-character
  state). A join is a new connection: empty bitset, empty client table, definitions as references need them, with
  the `WELCOME`-frame rule above; a rejoin is another connection. A staged namespace's tables exist from its release
  (`v5-collections.md` §13.2). An audience or interest change doesn't clear a viewer's bit: it still holds the entry.
- **How a client knows an entry is valid.** It stores an entry when it decodes a definition in a reliable frame its
  decoder accepts (frames are refused whole, `v5.md` §4.8, so a refused frame stores none). The entry keeps its
  value for the connection. A reference is valid exactly when the client holds its id. Client checks (rule 2,
  §6): a reference to an id it doesn't hold; a definition of an id it holds, of an id ≥ `maxEntries`, of a value
  another held entry of the table has, or that brings its held bytes past `maxBytes`. An unmodified server can
  produce none: it sends a definition only to a player whose bit is 0, the player's held set is a subset of the
  live entries (each value once, bytes ≤ `maxBytes`), and the definition precedes every reference on an ordered
  lane. A refused reliable frame (a Lync bug) loses its definitions, so later references fail too: the divergence
  `v5.md` §4.8 already states for refused reliable frames.

## 2. Upstream references (R33 form A, made exact)

- **Wire form** (verified in `golden_strings.out` S2, S3): the value form of §1.3, `entry:u1`, then `id:u(w)` or the
  literal. No `table` field: R33's `table:EG0` numbered per-audience tables, and here the field names its table, so
  it would carry nothing; R33's `id:EG0` becomes u(w), fixed by the shared `maxEntries`, which the decoder needs
  anyway for rule 2. A 20-byte value in `t.string(20)` goes from 5 + 160 bits to 1 + w (7 bits at `maxEntries` 64,
  13 at 4096); a literal pays 1 bit more. The server's id is sent, not a per-player index: the server's per-player
  state is then its bitset, which downstream already needs, rather than a second per-player list.
- **When a client may reference an entry:** as soon as it holds it, i.e. it has decoded the definition (§1.4). No
  ack is needed: the server set the player's bit when it committed the definition to that player's stream, before
  the client could receive it (R33's argument, which holds because bits are never cleared during a connection and
  reclamation needs every holder gone). On both lanes: an upstream unreliable frame references only what the
  client already decoded. Before the namespace's `WELCOME` a client holds nothing, so its join hold (`v5.md` §5.3)
  holds literals and its charge stays exact.
- **The reference encoder** sends a reference whenever it holds the value (a string → id map per table with any
  client-sent interned field; omitted otherwise), else the literal. Both forms decode, so the choice is the
  encoder's (R33); an encoder that never references pays only bytes.
- **What the server checks** (§6.1 step 4, decode): `id` ≥ `maxEntries` → `malformed` rule 2 (a code past its
  maximum); `id` whose bit in the sender's bitset is 0 → `malformed` rule 2 (new clause: "a string reference to an
  entry not sent to this player"). The value delivered is the server's own string for that id, so step 5 and 6 see
  a `string` like any other: `canaryEchoed` matching (`v5-integrity.md` §9) runs on the resolved value at today's
  cost; map key order (rule 5) compares resolved values; checks, validators and `limit` are unchanged.
- **What an unmodified client can never trigger:** either clause. It encodes ids from its own held set, which is a
  subset of its set bits; offsets, where `v5-integrity.md` §2 applies them to bounded codes, are inverted before the
  check like any bounded code (`v5.md` §4.8 rule 2). So the `malformed` row's known causes don't change.
- **Not adopted here: form B** (client-originated tables; R33): still no upstream traffic model with repeated
  client strings, so no default for its cap can be derived. Nothing in this design blocks it; it would add a second
  definition direction and is a separate decision.
