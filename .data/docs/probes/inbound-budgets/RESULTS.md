# Inbound budgets: server CPU per player, as a derivation

2026-10-15. Prover unit. Settles four claims the design needs before it can derive each inbound budget default
(`design/v5.md` §6.1, §7.5, §4.9; `design/v5-integrity.md`) from a stated input instead of "chosen, unmeasured".
Starting point: `research/refusals-rejudged-1.md` R31 (13.1–17.7 ms/s per player interpreted at the default byte
budgets, from `Run.decode` alone).

## Checklist

- [ ] 1. Server decode CPU per inbound byte, by payload shape (worst admitted shape and the busy model), native and
      interpreted, milestone decoder (`f1fbfd7`) and a generated decoder (`decode_shapes.luau`)
- [ ] 2. The tag's per-frame and per-byte CPU on the same frames; total inbound CPU = decode + tag (`tag_frames.luau`)
- [ ] 3. Per budget (reliable and unreliable `bytes` perSecond and burst; `frames`; `inbound.elements`): formula from
      budget value to worst-case server CPU per player and at 100 players; the busy model's use as a fraction of
      each budget (`derive.py`)
- [ ] 4. Budget values at which worst-case inbound CPU at 100 players is 1%, 5%, 10% of one core native; where the
      defaults fall (`derive.py`)

## Results
