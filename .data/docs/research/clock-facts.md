# Clock and timing facts: beacon window rules (U3), the `BEACON` frame gap, request timing (U4)

Researcher findings, 2026-10-15. Item numbers are from `research/security-refusals.md` §4. Builds on
`research/refusals-rejudged-2.md` R26 (forced `REPORT`) and R37 (`clockFits`, `clockRestarts`, `clockSlope`), and
on `research/server-facts.md` U10 (the path bound shared with `earlyAnswer`); neither is redefined here.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs. **reported**: third party.
**simulated**: a probe's model, whose engine timings are assumptions (marked in each probe header); nothing in a
simulation is measured on Roblox. Design text is cited by file and section.

**Probes** (`probes/clock-facts/`, run by `run.sh` with Luau 0.742 built from `.data/projects/luau`; cost probes
3 runs `-O2` interpreted, the Roblox client case, and 3 runs `-O2 --codegen` native, the server case; CLI timings
on a shared 2.1 GHz Xeon do not transfer exactly to Roblox, `probes/security-costs/RESULTS.md` "Host and tools"):
- `beacon_sim.luau` → `beacon_sim.out`: the §6 estimator per player, 100 players × 3 seeds × 600 s per scenario,
  on `v5.md` §9's default network and one chosen "mobile" model; forced and riding beacons; steps, ramps, modified
  clocks; facts by threshold T, run length F and the split-half rule below.
- `step_response.luau` → `.out`: exact Theil–Sen response to one level shift (no noise).
- `common_mode_sim.luau` → `.out` (the earlier agent's, re-run unchanged): guard, discard and literal window rules.
- `beacon_cost.luau` → `.out`: frame bytes (G4 reproduced first), client and server CPU; `cost.luau` → `.out`
  (re-run): epoch median, guard test, result fields.
- `roundtrip_sim.luau` → `.out`: `roundTrip` of unmodified clients, extended with a latency-drop case.
- `result_types.luau`, `result_types_ts.ts` → `result_types.out`: the result type under both Luau solvers
  (luau-analyze 0.740) and `tsc` 6.0.2 `--strict`.

**Platform facts used** (creator-docs, `main`, read 2026-10-15; **documented**):
- `Workspace:GetServerTimeNow()`: summary "Returns the server's Unix time in seconds"; on a client "the client's
  best approximation of the current time on the server", smoothed so that "It is monotonic" and "It moves at the
  same rate as the local clock to within 0.6%"
  ([Workspace.yaml](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/Workspace.yaml)).
- `os.clock()`: "elapsed time in seconds since an arbitrary baseline with sub-microsecond precision";
  "adjustments to the system clock (such as by the user or NTP) do not cause time to jump"
  ([os.yaml](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/libraries/os.yaml)).
- `Player:GetNetworkPing()`: "the round-trip, isolated network latency of the player in seconds … It doesn't
  involve data deserialization or processing"; on a client, callable only on `LocalPlayer`
  ([Player.yaml](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/Player.yaml)).
  The API dump types it `-> float` (32-bit), security None (**verified**, `api Player.GetNetworkPing`, Roblox
  0.741.19 dump).

## Checklist

- [ ] U3. Clock beacon window rules, slow clocks
- [ ] The `BEACON` frame gap
- [ ] U4. `roundTrip` and `ping` on server request results
- [ ] Implications
