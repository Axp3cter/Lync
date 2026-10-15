# Lync v5: first-party extensions (milestone 7)

Draft 3.6, 2026-10-15. Part of the v5 design (`v5.md`); changes from draft 3.5 are in `v5-3.6-changes-checks.md`.
Each extension is opt-in, plugs into the seams of `v5.md` §8, and lists what it takes from the core.

Draft 3.6 moved the rest of this file into the core, where it is specified in full: `interest`, `rewind` and
interpolation in `v5-collections.md`; checks, claims, telemetry and sealed delivery in `v5-checks.md`; upstream
string references (`strings`) in `v5.md` §4, the wire unit's. Two extensions remain. No draft 3.6 research covers
them, so each lists what is fixed and, for each value still open, what decides it.

## `acked`

- **What it does.** Codes the `:newest()` rows of one collection as predictions against each viewer's acked
  baselines, using Unity's guarded linear predictor, with values taken from a shared per-tick history: 2.3–2.8x fewer
  bytes than the core's absolute rows on the shooter models (`v5-collections.md` §5). It replaces the core's
  encode-once absolute rows for that collection, so rows become per viewer.
- **Takes from the core:** the notify ring and acks (`v5-collections.md` §6), the scheduler seam (`v5.md` §8).
- **Open:** where it is declared (a collection option in the shared schema, since the client must predict too, and
  so hashed), the history length, the predictor's guard, and the per-viewer encode cost at 100 viewers. Decided by a
  research unit with a probe on the four game models; nothing in the core waits on it.

## `inputs`

- **What it does.** Client input streams over the unreliable lane: each frame carries every input since the last
  acked one, delta-coded (1 bit when unchanged), up to a declared number of copies; the upstream unreliable seq is
  the input index, and the server adds its newest received index to downstream unreliable headers; a server jitter
  buffer of a declared depth in state ticks plays inputs out `[state-sync §4.1]`. Since-ack redundancy matched the
  best fixed copy count at the byte cost of two copies in the research's simulation, and copies help only up to the
  buffer's depth.
- **Takes from the core:** the upstream unreliable seq (`v5.md` §4.4), the downstream unreliable header
  (`v5.md` §4.1).
- **Open:** the copy cap (the research names 32, after Quake 3's `MAX_PACKET_USERCMDS`), the jitter-buffer depth
  and whether the server sets it from its own jitter estimate, as it sets the interpolation delay
  (`v5-collections.md` §11.1), and the header field's width. Decided by a research unit with the research's loss
  models on Lync's tick rates.
- **Name.** `inputs` is unrelated to the `:input()` codec marker (`v5-checks.md` §7.1), which only records that a
  free-form leaf is an input.
