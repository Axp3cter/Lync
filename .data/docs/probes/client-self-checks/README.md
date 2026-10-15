# Probes for research/client-self-checks.md and research/security-tooling.md §2

Run from this directory. `luau` and `luau-compile` were built from `.data/projects/luau` with CMake
(`-DCMAKE_BUILD_TYPE=RelWithDebInfo`, targets `Luau.Repl.CLI`, `Luau.Compile.CLI`) outside the repo.

| Probe | Command | Output |
|---|---|---|
| debug.info semantics | `luau -O1 info.luau`, `luau -O2 info.luau` (uses `lyncstub.luau`) | `info.out` |
| per-call costs (debug.info, traceback, os.clock, pcall, U1 dispatch) | `luau -O2 cost.luau`, `-O1` (uses `bench.luau`, `walkstub.luau`) | `cost.out` |
| os.clock repeats | `luau -O2 clockstep.luau` | `clockstep.out` |
| getfenv deoptimisation of the caller | `luau -O2 deopt.luau` (uses `deoptmod.luau`) | `deopt.out` |
| U1 capture sketch | luau skill `check --roblox capture.luau`; `luau-compile --text -O2 capture.luau` | `capture.out` |
| U2 tag variants | `python3 -I gen_tag.py` (writes `tag_*.luau`), then `luau -O2 tagvariants.luau`, `luau -O2 --codegen tagvariants.luau` | `tagvariants.out` |
| U2 bytecode and sizes | `luau-compile --text -O2` / `--binary -O2 -g0` on `tag_*.luau` | `bytecode.out` |
| U2 whole-tag avalanche | `python3 -I avalanche.py 300 30 1` | `avalanche.out` |
| U2 round-level diffusion | `python3 -I diffusion.py 400 40 2` | `diffusion.out` |
| API dump members | `python3 -I dump_members.py <dump.json> Class[.Member]…`; `python3 -I probe_members.py <dump.json>` | `probe_members.out` |

The dump is the luau skill's cached Roblox API 0.741.19 (`roblox-api-04caa58c2583.json`).
