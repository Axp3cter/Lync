# Probes for research/diagnostics.md

Luau 0.740 CLI (`~/.cache/luau-skill/luau-0.740-linux-x86_64/luau`, from the luau skill), Intel Xeon 2.1 GHz, 2026-10-15.

| File | What it shows | Run |
|---|---|---|
| `levels.luau` | `error` levels and positions at -O1/-O2/native, a `debug.info` walk, table errors, `xpcall(f, debug.traceback)` on a table, coroutine tracebacks | `luau -O1 levels.luau`, `-O2`, `-O2 --codegen` → `levels.*.out` |
| `tableerr.luau` | the idiom `xpcall(f, debug.traceback)` on a table with `__tostring` (LogService:Error's documented shape) | `luau tableerr.luau` |
| `callline.luau` | which line `debug.info(2, "l")` reports for a multi-line constructor call | `luau -O0/1/2 callline.luau` |
| `bench.luau`, `bench2.luau` | hot-path costs: checks, raising, pcall/xpcall, debug.info walks, formatting, counters vs events | `luau -O2 bench.luau`, `-O2 --codegen` → `bench*.out` |
| `ts_codes.js` | TypeScript diagnostic-code bands | `node ts_codes.js <typescript dir>` |
| `v4_counts.sh` | v4 raise sites and prose-matching assertions | `sh .data/docs/probes/diagnostics/v4_counts.sh` from the repo root |
