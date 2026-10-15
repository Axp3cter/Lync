# Sources for research/security-tooling.md

All checks ran 2026-10-15. Nothing fetched or downloaded is kept in the repo; working copies were in the session
scratchpad.

## Roblox API dump
- Roblox API 0.741.19 (tracker fcd6994), the luau skill's cached dump (`roblox-api-04caa58c2583.json`).
- Read with a short Python reader printing, per member: signature, `Security`, `Tags`, `Capabilities`,
  `ThreadSafety`. Enums read the same way.
- Enum values used: `HashAlgorithm` Blake2b 0, Blake3 1, Md5 2, Sha1 3, Sha256 4; `CompressionAlgorithm` Zstd 0.
- Publish/save search: every member named `*Publish*`, `*Save*`, `*Upload*`, `*Commit*` whose security is not
  RobloxScriptSecurity was listed; none is a publish or save hook (see the findings file, §3).

## Roblox creator-docs
- github.com/Roblox/creator-docs at commit efe8741 (2026-10-15), sparse checkout.
- Engine class pages: `content/en-us/reference/engine/classes/*.yaml`.
- Guides: `cloud/guides/{instance,configs,secrets-store,usage-place-publishing,usage-assets,usage-messaging}.md`,
  `cloud/reference/rate-limits.md`, `cloud-services/{http-service,secrets,cross-server-messaging}.md`,
  `cloud-services/memory-stores/index.md`, `production/configs.md`, `scripting/events/remote.md`.
- Open Cloud endpoints, scopes and rate limits: `content/en-us/reference/cloud/openapi.json`
  (`x-roblox-scopes`, `x-roblox-rate-limits`, component schemas `LuauExecutionSessionTask*`).

## Reference sources in `.data/projects/`
- luau b971a80: `VM/src/lbaselib.cpp` lines 135 and 144 (`lua_setsafeenv(L, -1, false)` in getfenv/setfenv);
  `Compiler/include/Luau/Compiler.h` (`CompileOptions`).
- lute e969ff7: `definitions/{crypto,luau,vm,fs,process}.luau`, `definitions/net/*.luau`,
  `definitions/syntax/{parser,cst}.luau`; `lute/luau/src/luau.cpp` (compile options at line 48, `typeofModule`
  at 107); `lute/crypto/src/crypto.cpp` (OpenSSL EVP digests, libsodium secretbox and `crypto_pwhash`);
  `lute/std/libs/syntax/{query,visitor,printer}.luau`.
- darklua 0.19.0: `src/rules/*` (32 rule-name constants plus the bundler's), `src/cli/process.rs` (input path,
  formats `dense`/`readable`/`retain_lines`, watch), `Cargo.toml` (full_moon 2.2.0).
- rojo 7.7.1: `src/cli/{build,sourcemap,upload}.rs`; `Cargo.toml` (rbx_binary 3.0.1, rbx_xml 3.0.1,
  rbx_dom_weak 4.2.0).
- luau-lsp 1.70.1: `src/AnalyzeCli.cpp` (`--annotate`), `src/main.cpp` (`--formatter` default|plain|gnu,
  `require-graph --output-format json|dot`), `CHANGELOG.md` (require-graph CLI in 1.55.0).

## Rust crates
- Versions from the crates.io API: mlua 0.12.2, luau0-src 0.22.0+luau740, rbx_binary 3.0.1, rbx_xml 3.0.1,
  rbx_dom_weak 4.2.0, rbx_reflection_database 3.0.1+roblox-741, lune-roblox 0.4.0, blake3 1.8.7, sha2 0.11.1,
  siphasher 1.0.4, getrandom 0.4.3, rand_core 0.10.1, notify 8.2.0, full_moon 3.0.0.
- APIs read from the published sources (cargo registry copies):
  - mlua `src/chunk.rs` lines 258–390: `Compiler` setters; line 398: `compile`; lines 520–565: `Chunk` setters.
  - mlua `src/state.rs`: `sandbox` (680), `set_compiler` (1309), `create_buffer` (1415).
  - mlua `Cargo.toml`: features `luau`, `luau-jit`, `luau-vector4`.
  - rbx_binary `src/lib.rs` lines 84 and 90: `from_reader`, `to_writer`.
  - rbx_dom_weak `src/dom.rs` and `src/instance.rs`.

## Lune
- Lune docs, api-reference pages `serde`, `luau` and `roblox` (lune-org.github.io), read 2026-10-15.

## Python packages
- PyPI JSON: zstandard 0.25.0 (BSD-3-Clause), jsonschema 4.26.0 (MIT), hypothesis 6.169.4 (MPL-2.0),
  atheris 3.1.0 (uploaded 2026-06-17), numpy 2.5.4.
- Web searches for a Python Luau-bytecode parser and a Python rbxl/rbxm parser found neither.

## Executor
- potassium-api skill: build 145f189a (2026-07-28), API re-verified live on v2.3.5 (2026-07-31).

## luau instrument runs (luau 0.740)
- `typeof(buffer.create(4))` gives `buffer`.
- `debug.info(print, "s")` gives `[C]`, and `"l"` gives `-1`; `debug.info(function(...) end, "a")` gives `0 true`.
- `table.isfrozen(buffer)`, `(bit32)` and `(os)` are all `true`.
- Bytecode of a function calling `os.clock()`, `bit32.bxor(x, 5)` and `buffer.writeu8`: `os.clock` compiles to
  `GETIMPORT` + `CALLFB`, `bit32.bxor` to `FASTCALL2K`, and `buffer.writeu8` to `FASTCALL3`.
