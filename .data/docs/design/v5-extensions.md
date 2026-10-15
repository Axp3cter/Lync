# Lync v5: first-party extensions (milestone 7)

Draft 3, 2026-10-15. Part of the v5 design (`v5.md`). Each extension is opt-in, plugs into the seams of `v5.md` §8,
and lists what it took from the core. Before it is built, each is specified to principle 5: every option with type,
unit, range, default and cost, and every fact with an exact trigger.

- **`interest`:** per-viewer relevance with cells and hysteresis, intersecting the audience and never widening it;
  distance priority with an accumulator and a 40-bucket pass (replacing the core's FIFO selector through the
  scheduler seam); ownership (`owner`, an owner boost, owner-only fields); per-field rate caps `:maxHz(hz)` rounded
  to a divisor of `state.rate`; look-ahead reveal. Cells cost about 0.01 ms per pass against 4–7 ms for exact
  membership at 200 players × 10k entities `[state-sync §7, anticheat-design §1]`.
- **`acked`:** `:newest()` rows of one collection predicted with Unity's guarded linear predictor against each
  viewer's acked baselines, values from a shared per-tick history: 2.3–2.8x fewer bytes than absolute rows on the
  shooter models (`v5-collections.md` §5).
- **`inputs`:** client input streams: every input since the last ack, delta-coded, capped at a declared number of
  copies; the upstream unreliable seq doubles as the input index, and the extension adds its newest value to
  downstream unreliable headers; a server jitter buffer of a declared depth in state ticks `[state-sync §4.1]`.
- **`rewind`:** lag-compensated hit verification over rewind rings, keyed by the client's perceived tick from its
  newest ack, never by client-chosen timestamps.
- **`checks`:** declared constraints (`within`, `monotonic`, `maxTotal`) with syntax, units and scope, each with a
  failure policy of `drop` or `clamp`; every failure is reported as the fact `constraint`, with the policy in its
  evidence. The `:claim()` marker declares a client-sent field a claim (unmarked fields are inputs); a definition
  with claim fields must have `validate`, where the claim is checked `[anticheat-design §3.2, §4.2]`.
- **`strings`:** interning and templates, server-to-client only: per-audience tables, intern on second sight, a byte
  cap. Interning cut string bytes 1.8x and templates 6.5x on the tycoon model `[compression §5]`; per-connection
  tables would break shared encoding and pin up to 92 MB upstream `[probes review-redundancy wire_overhead]`.
- **`interpolation`:** the client buffer: delay max(2/rate, 0.1 s) + 2 × jitter, extrapolation capped at 0.25 s
  `[state-sync §6.3]`.
- **`telemetry`:** schema-marked gameplay feature streams exported in batches to the developer's backend. It is not a
  diagnostics exporter; diagnostics export is a documented recipe over `Lync.observe` and `Lync.counters`
  `[diagnostics §5.4]`.
