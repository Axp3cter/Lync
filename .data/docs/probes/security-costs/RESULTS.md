# Security-measure costs, re-measured

2026-10-15. Settles the performance and size figures the v5 docs use to refuse or narrow security measures, and
measures cheaper implementations a build could generate. Item numbers R1–R40 are from
`research/security-refusals.md`.

**Host and tools.** CLI VM only: Luau 0.742 built from the vendored source (`.data/projects/luau`, Release,
gcc 13.3) with `luau -O2` (interpreted, the Roblox client case) and `luau -O2 --codegen` (native, the Roblox server
case when its scripts are native); Luau 0.740 (the skill's pinned toolchain) for `remarks` and cross-checks;
python-zstandard 0.25.0 (libzstd 1.5.7). Intel Xeon 2.1 GHz, 4 cores, shared machine. **CLI timings do not
transfer exactly to Roblox**: Roblox servers run native code only for scripts marked native, clients are
interpreted, devices (phones especially) are slower, and engine costs (remote calls, `FireAllClients`, capability
errors, compression) cannot be measured here.

**Method.** `harness.luau`: every case of a comparison runs once per round, in order, after a warm-up round; 11
rounds; reported as median ns per iteration with min–max, and the median (range) of the per-round ratio to the
first case, the baseline in the same run. `run.sh` runs each probe 3 times interpreted and 3 times native into
`<probe>.out`. Figures below quote the medians of those runs unless marked otherwise.

## Checklist

- [ ] 1. Runtime field shuffling 2–3x per record write (`field_order.luau`)
- [ ] 2. Masking: +62–272% bytes after zstd; CPU per byte at the tag's rate (`mask_bytes.py`, `mask_cpu.luau`)
- [ ] 3. Downstream tags: a PRF per recipient ≤ 3% of a core; ends `FireAllClients` (`downstream_tag.luau`)
- [ ] 4. Per-session upstream id shuffle: ~20,000-slot decode table (`id_shuffle.luau`)
- [ ] 5. Low-order watermarks: per-viewer encoding cost (`per_viewer.luau` part A)
- [ ] 6. Decoys: per-viewer re-encode and pool slots (`per_viewer.luau` part B)
- [ ] 7. Caller probe on every call ≤ 0.2 ms/s at 60/s (`caller_probe.luau`)
- [ ] 8. `tag.cover` 16,384 default ≤ 0.23 ms/s per player; 0.022 / 0.0035 µs/B (`tag_cover.luau`)
- [ ] 9. Clock beacon: one 66-slope fit per 5 s per player (`clock_fit.luau`)
- [ ] 10. Canary scan up to 256 B: per-offset lookup cost (`canary_scan.luau`)
- [ ] 11. Other figures used to refuse or narrow a measure (`tag_cover.luau`, `per_viewer.luau`, `enum_rotation.luau`, `getfenv_deopt.luau`)
- [ ] 12. R39: an unused per-frame transform hook slot vs none (`frame_hook.luau`)

## Results
