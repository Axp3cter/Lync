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
- [x] 3. Cost and saving
- [x] 4. What it protects and what it doesn't
- [x] 5. Facts, counters, codes and options
- [x] 6. Text for `v5.md` §4 and the golden vectors
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

## 3. Cost and saving (measured)

### 3.1 Bytes on the docs' traffic models

Per recipient, string-carrying values only, in Lync's bit layout (lengths in the bit section, bytes in the tail),
with each model's formatted strings sent as structured fields (compression §5's templates) on both sides, so the
columns isolate interning. Interned includes every definition, the strings chunk's framing (§1.3: 5 bits for
namespace 0's segment entry and the chunk's `ns`, EG0 per table, 3.5 bits mean alignment, +2 bits in an events-only
frame) and frame 0, the join's catch-up (`strings_model.out`, verified).

| Model (fields interned) | inline B/s | interned B/s, small `maxEntries` | interned B/s, `maxEntries` 4096 | table after the run |
|---|---|---|---|---|
| shooter 20 Hz, 30 players, `kill { killer, victim }` broadcast, `t.string(20)` | 51.86 | 6.82 (64: w 6), −86.8% | 10.68, −79.4% | 30 entries, 294 B |
| mmo 20 Hz, `name` in catch-up adds, `t.string(20)` | 24.18 (17.69 after the join) | 5.04 (64), −79.1% (2.44 after) | 7.52, −68.9% (4.16 after) | 35 entries, 295 B |
| tycoon 10 Hz, 5 min: record `label`, `purchase.item`, `notify { item, level }` in `t.string(32)`; chat inline | 80.48 | 22.54 (256: w 8), −72.0% | 25.76, −68.0% | 121 entries, 1,009 B |

- **Cross-check with compression §5** (byte-aligned LEB128 lengths and ids, frame 0 excluded): mmo inline 18.5 B/s
  against 17.69 here (5-bit lengths), per-connection interning 4.5 against 2.44–4.16 here; the shooter's whole
  formatted line interned was 67.4 B/s and templates 9.6, against structured references 6.82–10.68 here.
- **The join** (mmo frame 0, 121 adds naming 29 distinct names): 973.6 B inline, 390.9 B interned at w 6, 503.4 B at
  w 12. A definition costs w + L_t bits more than the literal it replaces, so a value seen once costs more interned
  (tycoon frame 0: 10.8 → 14.3 B); interning pays from the second sending of a value to the same player.
- **Random ids against creation order.** Single rows: equal (both u(w)). Column blocks: the join's id column of 121
  adds costs 709 bits in creation order and 735 random at `maxEntries` 64, 1,461 random at 4096
  (`strings_model.out`): random ids cost +26 bits per such catch-up at 64 and +752 bits (94 B) at 4096. The price of
  §4.2's privacy is set by `maxEntries`, which the developer chooses.
- **Server egress:** the kill feed saves 45.03 B/s × 30 = 1.35 KB/s at 30 viewers (w 6).
- **Fixed cost:** none for a frame without definitions, none for a namespace without tables. Seed-0 golden frames and
  the schema hash of every schema without a table are unchanged (§6).

### 3.2 CPU (`strings_cost.out`, medians of 11 rounds, range over 3 runs; native / interpreted, ns)

| Operation | Native | Interpreted |
|---|---|---|
| server encode, plain `t.string(20)`: length + tail copy | 34.6–37.2 | 101–105 |
| server encode, reference (map lookup, one recipient's bit test, 13 bits) | 25.4–27.0 | 127–128 |
| each further (value, recipient) bit test | 5.6–6.0 | 23.3–23.7 |
| entry creation (random free id, two map writes), over a map miss | ≈ 150–170 (255–277 − 101–111) | ≈ 290–360 (407–483 − 115–121) |
| server decode upstream: literal / reference with the bit check | 73.7–80.5 / 20.0–21.6 | 117–123 / 86.9–92.8 |
| client decode: literal / reference | 76.0–80.3 / 32.5–35.8 | 130–138 / 79.9–83.5 |
| client decode of one definition (3 checks, 2 map writes) / `readstring` alone | 247–310 / 55–67 | 303–353 / 71–85 |

- **Tag.** A reference also shrinks the tagged frame: a 20-byte value as 13 bits saves 19.4 B of cover, at 28.5–37.2
  ns per covered byte on the client interpreted and 4.0 ns per byte on the server native (`v5.md` §7.5 `tag.cover`):
  550–720 ns client and 78 ns server per value sent upstream, more than every table operation above (derived).
- **Kill feed, 4.95 values/s, server native:** with the holder-count skip (broadcast to every welcomed player, all
  holding) 4.95 × 25–27 = 0.13 µs/s, against 0.18 µs/s inline; without it 4.95 × (26 + 30 × 5.8) = 1.0 µs/s at 30
  viewers and 3.0 µs/s at 100; 30 creations once, 4.8 µs. Client: 0.25 µs/s saved on references (4.95 × ≈ 50 ns
  interpreted), 30 definitions once, ≈ 7.5 µs per connection.
- **Interpreted servers** (scripts not marked native): a reference costs 127 against 101–105 ns plain, +25 ns per
  value, before the tag's per-byte saving.
- **Not measured:** the leave scan (one pass over ⌈`maxEntries`/8⌉ bytes and a decrement per set bit, once per
  connection end), Roblox's `Random:NextInteger` (the CLI has none; the probe's xorshift stands in), devices.

### 3.3 Memory (`strings_cost.out`, R33's `r33_intern.out`)

- **Per live entry, server:** 64 B (string → id and id → string maps, 32 B each measured at 1,024 entries), plus the
  string itself when the table alone keeps it alive (length + ≈ 25 B: 45 B measured for 20 B; 0 when game state holds
  it, Luau strings being interned).
- **Per table, server:** 4 B × `maxEntries` (free-id list u16, measured 8,192 B at 4,096; holder counts u16, derived),
  plus per player one bitset of ⌈`maxEntries`/8⌉ B (a 512 B buffer measured 1,024 B of heap).
- **Per held entry, client:** 32 B (id → string as a hash, random ids) + 32 B for the reverse map when a client-sent
  field uses the table + the string (length + ≈ 25 B; the table keeps it alive). A `table.create(maxEntries)` array
  costs 16 B per slot whatever the fill (65,536 B at 4,096), smaller only above half full.
- **Worked:** kill feed, `maxEntries` 64, 30 entries, 30 players: ≈ 3.2 KB per server plus 30 bitsets of 8 B; 2,964 B
  per client. Bound at `maxEntries` 4,096 with the default `maxBytes` 4,096 × 20 = 81,920 B: 462,848 B per server table
  + 1,024 B per player (565 KB at 100 players); 446,464 B per client. The bound is the developer's two numbers;
  nothing in it is per message or chosen by a client (§4.1).

### 3.4 Interaction with the budgets

- **Inbound bytes** (`inbound.*.bytes`, `v5.md` §7.5): references shrink upstream frames, so more values fit one
  budget; the CPU bound stays an upper bound, since a reference is a leaf decoding in 20.0–21.6 ns native (bit check
  included), under p(L)'s 133 ns per leaf, and it removes per-byte work (tag, string read).
- **Elements** (§4.8): a reference or literal is one value, not an element, so W, `inbound.elements` and
  `elementsTooMany` don't change. Each table's definition count in a strings chunk is a count and is charged to the
  client's per-frame allowance and to `elementsSent`, so the 2^22 split rule (§4.1) covers it.
- **Downstream:** `state.budget` charges every byte sent, strings chunks included; the kill feed's 45 B/s is 0.28% of
  the 16,000 B/s default. Join holds hold literals (§1.3), so both holds' byte and element charges stay exact.

## 4. What it protects and what it doesn't

### 4.1 Server memory a client can choose (R33's point)

- **Upstream references pin nothing.** A reference names an entry the server created from its own sends; decoding it
  allocates nothing (the delivered string is the server's) and stores nothing. Per player the server keeps one
  bitset of fixed size, ⌈`maxEntries`/8⌉ B, whatever the client sends (verified in the design: §1.4, §2).
- **Where a client does reach table contents:** only through game code that relays client text into an interned
  downstream field (a typed pet name broadcast to everyone, say). Then each distinct relayed value can become an
  entry. Bound: the table's caps, shared by the server, not per player; reclaimed when no connected player holds the
  entries. The most such a client can cause is a full table, after which new values travel as literals for every
  recipient: bytes return toward inline, at most inline + 1 bit per value, and `stringLiteralsFull` counts it. Which
  fields carry client-originated text is the developer's knowledge: such fields are left unmarked (compression §5
  called them transient).
- **Protects nothing.** Interning is compression. It hides no string from its recipient (a definition is the literal
  it replaces) and adds no integrity measure.

### 4.2 What a client learns from tables

- **Content:** exactly the values of messages sent to it, the same bytes inline would carry. Definitions reach a
  viewer only for references in chunks it receives (§1.3), so visibility classes, interest, scoped events and
  withheld fields (`v5-collections.md` §8–§10) withhold the definitions with the values.
- **Co-recipients:** nothing, under §1.2's choice: a shared chunk's bits are one encoding whatever each recipient
  holds, and a viewer's strings chunk depends only on its own bits. Option (c) would have leaked who among a cell
  chunk's recipients lacked an entry.
- **Ids carry nothing about others** (derived). Ids are drawn uniformly among free ids, and frees depend on which
  players hold entries, never on id labels. So the process is unchanged by any relabelling of the ids a viewer V
  doesn't hold, and given V's held set H the id of the next definition V receives is uniform over the
  `maxEntries` − |H| ids outside H, whether the entry is new or old, and whatever the number of live entries. V can't
  tell how many entries exist, whether a value was sent to anyone before, or when. With creation-order ids, an id's
  value would give the count of entries created before it, and gaps the number created for others.
- **One bit about others: fullness.** A literal outside the join hold means the table was at a cap when the value was
  sent: other players' traffic filled it. V learns that the table is full at that moment (and, from a later
  definition of a new value, that it has room again). Nothing else.
- **Colluding clients** see the same id for the same value; they could compare the values themselves.
- **Decoys** (`v5-integrity.md` §8): a decoy's interned values go through the same path as a real record's, so its
  references and definitions look like a real record's to its viewer; entries made only for decoys are held only by
  their viewer and reclaimed when it leaves.
- **Sealed and canary fields** are outside the mechanism (`internPlacement`, `canaryInterned`, §1.1).
- **What the server learns** from upstream references is which entries the client holds, which it already knows.

### 4.3 How it fails on an unmodified client

- A `maxEntries` or `maxBytes` below the game's live vocabulary: values beyond it travel as literals
  (`stringLiteralsFull`); nothing breaks.
- A Lync bug that refuses one reliable frame on a client: that frame's definitions are lost and later references to
  them make later frames fail rule 2 too, counted in `refusedFrames` and `REPORT`, whose fact
  `reportedRefusedFrames` already lists "a Lync bug" as its only cause (`v5-integrity.md` §10).
- A modified client sending references to entries it wasn't sent: `malformed` rule 2, frame dropped (§2); a modified
  encoder that sends literals only: accepted, more bytes.

## 5. Facts, counters, codes and options

### 5.1 Facts

No new fact. One existing row gains clauses (`v5.md` §7.3); the trigger is exact and the evidence unchanged:

| Reason | Exact trigger (new clauses) | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `malformed`, rule 2 | an upstream interned value with `entry` 1 whose `id` is ≥ `maxEntries`, or whose bit in the sender's bitset for that table is 0 | frame dropped | `lane`, `rule` | none: the server sets a player's bit when it commits the definition to that player's stream, before the client can receive it, never clears it during the connection, and reclaims an id only when no connected player's bit is set |

- **Downstream refusals** (a client's decoder applying §6's clauses) are counted in the client's `refusedFrames` and
  delivered through `REPORT` as `reportedRefusedFrames`, unchanged: known cause "a Lync bug".
- **Considered, not adopted: a fact for an upstream literal of a value the sender holds.** Its trigger needs the
  definition's downstream frame number per (player, entry), 4 B each, and the receipt `rcv` to know the client had
  decoded it; `rcv`'s upward extension after a 256-frame stall would then make the fact for an unmodified client, and
  unreliable frames have no receipt at all. It would identify an encoder other than Lync's, which the keyed tag
  already prices (a raw sender needs the key), and canonical decode accepts both forms by design.

### 5.2 Counters (`Lync.counters`, `v5.md` §7.4; qualifier `<namespace>.<table>`, a new qualifier kind)

| Counter | Side | Kind | Counted at | Reads as |
|---|---|---|---|---|
| `stringEntries`, `stringBytes` | server | level, server-wide | each creation and reclamation | live entries and their bytes, against `maxEntries` and `maxBytes` |
| `stringDefinitions` | server | count | each definition written to a player's strings chunk | bytes spent defining; per player with `player` |
| `stringLiteralsFull` | server | count | each value sent literal because the table was at a cap | a cap below the live vocabulary |
| `stringLiteralsHeld` | server | count | each value encoded literal in the server's join hold | the join's literal cost |
| `stringEntriesFreed` | server | count | each reclamation | churn of the vocabulary |
| `stringReferencesReceived` | server | count | each upstream reference decoded (§6.1 step 4) | how much clients reference |
| `stringEntriesHeld` | client | level | each definition decoded | the client's table size |

Cost: 8.1–8.7 ns native per increment (`v5.md` §7.4's measured figure); one more number per table in a snapshot.

### 5.3 Declaration codes (registered in `v5.md` §7.1)

| Code | Family | Trigger |
|---|---|---|
| `internPlacement` | declaration | `:intern` on a codec other than `t.string`, inside the `data` of an unreliable server-sent event, or inside a sealed event's `data` (§1.1) |
| `internTable` | declaration | `:intern(x)` where `x` is not a `Lync.strings` entry of the same schema |
| `stringsUnused` | declaration | a `Lync.strings` entry that no codec of the schema marks (its L_t and default `maxBytes` would be undefined) |
| `canaryInterned` | caller (exists) | `:canary()` on an interned field (`v5-integrity.md` §9) |

`Lync.strings`'s option errors are `unknownOption`, `missingOption` (`maxEntries`) and `paramRange`, as for every
schema constructor (`v5.md` §7.1); `Lync.strings` joins the list of schema entries `notADefinition` accepts.

### 5.4 Options

`Lync.strings({ … })`, in the shared schema (both ends need them: the id width, and rule 2's limits), hashed:

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `maxEntries` | integer | entries | 1–65,536 (chosen: ids fit the u16 free list and holder counts; the per-player bitset is 8 KB at the top) | required: the game's live vocabulary, which no input in the docs fixes | w = ⌈log2 `maxEntries`⌉ bits per reference and per definition; random ids cost column bits that grow with w (§3.1); server 4 B per id plus ⌈`maxEntries`/8⌉ B per player; 64 B per live entry on the server, 32–64 B per held entry on a client (§3.3) |
| `maxBytes` | integer | B | 1 to `maxEntries` × m (m: the largest `maxBytes` of the `t.string` codecs marked with the table) | `maxEntries` × m, derived: the largest sum `maxEntries` entries of those codecs can reach, so it never binds before `maxEntries` | at most `maxBytes` + ≈ 25 B per entry of string storage on each end (§3.3) |

| Method | Allowed on (else) | Effect | Client type | Wire |
|---|---|---|---|---|
| `:intern(table)` | a `t.string`, outside unreliable server events and sealed events (`internPlacement`) | values may travel as references into `table`; the server's values enter it | `string` | `entry:u1`, then `id:u(w)` or the plain `t.string` form (§1.3) |

No `Lync.configure` option: what enters is the declaration's rule, the literal/reference choice is the reference
encoder's fixed rule, and a run-time switch would be a second way to declare the same thing (`v5.md` principle 4).

## 6. Text for `v5.md` §4 and the golden vectors

Proposed wording for the wire unit; every value is derived above or a stated protocol choice.

- **§4.1 grammar.** Add to the chunk lines:
  ```
  strings chunk := ns:EG0 { count:EG0 { id:u(w_t) length:u(L_t) } }   -- one list per table of namespace ns
  value of an interned field := entry:u1 ( 1: id:u(w_t) | 0: the field's plain t.string encoding )
  ```
  and to **Segments**: "Namespace 0's state segment holds strings chunks (§4.11), one per namespace, in ascending
  `ns`; it precedes every other state segment, so a definition precedes every reference in its frame."
- **§4.2 Encode once.** Add: "Shared chunks carry interned values as references or literals, never definitions;
  definitions go in each recipient's strings chunk. Frames are identical across recipients only when their
  definition lists are equal, decided from the lists."
- **§4.3 Flattening.** Add: "an interned `t.string`: as `t.union` of { literal: the `t.string`'s columns; entry: an
  id column on [0, `maxEntries` − 1] }." **Free choices:** add "literal or reference for an interned value".
- **New §4.11 String tables** (or inside §4.2): §1.2's ownership and random ids, §1.3's who-gets-which-definition,
  splits, the `WELCOME`-frame rule and the unreliable decision, §1.4's caps, reclamation and survival, §2's upstream
  rule. About 40 lines.
- **§4.7 Schema hash.** Codec type 27 `intern`: the table's name `str`, then the codec (a wrapper, like type 26).
  Schema entries gain kind 4 (strings table), serialized as name `str`, kind u8 4, `maxEntries` `num`, `maxBytes`
  `num` (resolved), with no `from`, lane or option list: the kind fixes the layout, so no other definition's bytes
  change and G6 stands (verified: S0 below; G6 is unchanged because it declares no table).
- **§4.8 rules.**
  - Rule 2 gains: "a string reference whose id is ≥ `maxEntries`, or names an entry not sent to this player
    (upstream) or not held (downstream); a strings chunk count above `maxEntries`; a definition of an id ≥
    `maxEntries`, of an id already held, of a value another held entry of the table has, or bringing the table's held
    bytes past `maxBytes`."
  - Rule 5 gains: "definition ids not strictly ascending within a table's list".
  - Rule 6 gains: "a strings chunk whose every count is 0; strings chunks not in ascending `ns`, or two for one
    namespace".
  - Rule 7 gains: "a strings chunk for a namespace not welcomed when it is decoded, or declaring no table".
  - Rule 9 gains: "a definition that no later chunk of its frame references" (the encoder places definitions in the
    part of their first reference, §1.3, so this holds across splits).
- **§4.9 protocol constants.** "Interned value: `entry:u1`, id u(⌈log2 `maxEntries`⌉)"; "strings chunk: namespace 0's
  state segment; per table, in name order, `count:EG0` then id u(w_t) and length u(⌈log2(m_t + 1)⌉)". Runtime
  constants: "entry ids: uniform among free ids (server `Random`)"; "reclamation: at holder count 0, applied at the
  start of a flush".
- **§4.10 golden vectors** (`golden_strings.out`; fixture namespace `feed`, index 1, identity build and permutation:
  `names = Lync.strings({ maxEntries = 64 })` (w 6, m 20, `maxBytes` 1,280), `kill` server event with `killer`,
  `victim` = `t.string(20):intern(names)`, `taunt` client event with `to` = the same; entry ids pinned by the test
  seam: "Builderman" 5, "Zippy" 17; key `00 … 07`, `tag.cover` 1024, count 0, `caller` 0). Unverified until a
  milestone build reproduces them, as draft 3.6's changed vectors are.

| # | What | Bytes (hex) |
|---|---|---|
| S0 | `feed`'s serialization, then hash | `01 04 00 66 65 65 64 03 00 04 00 6b 69 6c 6c 01 02 01 01 17 02 00 06 00 6b 69 6c 6c 65 72 1b 05 00 6e 61 6d 65 73 08 00 00 00 00 00 00 34 40 00 00 06 00 76 69 63 74 69 6d 1b 05 00 6e 61 6d 65 73 08 00 00 00 00 00 00 34 40 00 00 00 00 00 00 00 00 00 00 01 00 00 05 00 6e 61 6d 65 73 04 00 00 00 00 00 00 50 40 00 00 00 00 00 00 94 40 05 00 74 61 75 6e 74 01 01 01 01 17 01 00 02 00 74 6f 1b 05 00 6e 61 6d 65 73 08 00 00 00 00 00 00 34 40 00 00 00 00 00 00 00 00 00 00 01 00 00`; `c4 7f 89 18 f9 cf 43 66` |
| S1 | down reliable, tick unchanged: `kill:fire(Lync.all, { killer = "Builderman", victim = "Zippy" })` to a client holding neither: strings chunk (ids 5, 17), then the run of two references | `b4 34 72 a1 a2 02 17 23 5a 69 70 70 79 42 75 69 6c 64 65 72 6d 61 6e` |
| S1b | the same to a client holding both: no state segment | `4a 03 17 23` |
| S2 | up reliable, `rcv` 1: `taunt:fire({ to = "Zippy" })`, a reference to 17 | `04 48 8f 00 1e 04 77 de` |
| S3 | the same with `to = "Nobody"`, held by no entry: a literal | `04 48 33 4e 6f 62 6f 64 79 6d 34 fd 6e` |

S1 (23 B) against S1b (4 B) is a definition's one-time cost against its steady state; S1 inline would be 20 B.

- **Needs elsewhere** (one line each): `v5.md` §3.3 methods table gains `:intern(table)` (§5.4); §3.4 gains
  `Lync.strings` as a schema entry and its option rows; §5.3 states that held sends of interned fields are encoded
  with literals (§1.3); §7.1 registers `internPlacement`, `internTable`, `stringsUnused`; §7.4 gains §5.2's counters
  and the `<namespace>.<table>` qualifier; `v5-extensions.md`'s pointer to `v5.md` §4 then holds; `v5-checks.md` §9
  gains that a sealed event's `data` takes no `:intern`; `v5-tooling.md` `report.md` may list each table's caps and
  `stringLiteralsFull` sizing advice (tooling's decision).
