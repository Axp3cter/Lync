# security-tooling probe sources

Verified against these pinned sources on 2026-10-15. All reproducible; nothing downloaded is committed.

## Roblox API dump
- Roblox API 0.741.19 (tracker fcd6994), via the luau skill cache
  (`~/.cache/luau-skill/roblox-api-04caa58c2583.json`).
- Queried with a small reader (membership name, MemberType, Security, Tags, Capabilities, ThreadSafety).
- Enums: `HashAlgorithm` = Blake2b 0, Blake3 1, Md5 2, Sha1 3, Sha256 4. `CompressionAlgorithm` = Zstd 0.

## Roblox creator-docs
- github.com/Roblox/creator-docs @ efe8741 (2026-10-15), sparse checkout of reference/engine, cloud,
  cloud-services, production, projects. OpenAPI: content/en-us/reference/cloud/openapi.json.

## Reference sources in .data/projects (read in place)
- luau b971a80 (0.740): VM/src/lbaselib.cpp (getfenv/setfenv clear safeenv), Compiler/include/Luau/Compiler.h
  (CompileOptions fields), VM/src/ldblib.cpp (debug.info letters).
- lute e969ff7 (1.0.0): definitions/{crypto,luau,vm,net,process,fs}.luau; lute/luau/src/luau.cpp
  (compile optimizationlevel/debuglevel/coveragelevel; typeofModule); lute/std/libs/syntax/{query,visitor,printer}.luau;
  definitions/syntax/cst.luau (Span line/column).
- darklua 0.19.0: src/rules/mod.rs (33 rule names), src/generator/mod.rs (Dense/Readable), convert_require rojo_sourcemap.
- rojo 7.7.1: src/cli/build.rs (rbxm/rbxl/rbxmx/rbxlx output, --watch), Cargo.toml rbx_* deps.
- luau-lsp 1.70.1: src/AnalyzeCli.cpp (--annotate, --sourcemap, --formatter gnu), src/main.cpp (require-graph, --output-format json/dot, since 1.55.0).
- roblox-ts 3.0.0.

## crates.io (versions, fetched 2026-10-15)
mlua 0.12.2; luau0-src 0.22.0+luau740; rbx_binary 3.0.1; rbx_xml 3.0.1; rbx_dom_weak 4.2.0;
rbx_reflection_database 3.0.1+roblox-741; blake3 1.8.7; siphasher 1.0.4; sha2 0.11.1; getrandom 0.4.3;
lune-roblox 0.4.0; notify 8.2.0; full_moon 3.0.0; darklua 0.19.0.
mlua API (read from vendored source ~/.cargo/registry mlua-0.12.2): Compiler::set_optimization_level/
set_debug_level/set_type_info_level/set_coverage_level/set_mutable_globals/set_vector_ctor; Lua::sandbox(bool),
create_buffer, set_compiler; Chunk::set_environment/set_mode/set_name. rbx_binary::{from_reader,to_writer};
rbx_dom_weak::{WeakDom, InstanceBuilder::with_property/with_child, Instance.properties: UstrMap<Variant>}.

## Potassium executor skill
potassium-api skill, build 145f189a (2026-07-28), re-verified live v2.3.5 on 2026-07-31.

## luau instrument checks (luau 0.740)
- `typeof(buffer.create(4))` -> "buffer".
- `debug.info(print,"s")` -> "[C]", `"l"` -> -1; `debug.info(varargLuaFn,"a")` -> 0, true.
