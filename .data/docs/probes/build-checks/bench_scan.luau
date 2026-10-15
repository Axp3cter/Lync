--!nocheck
-- Throughput of lex + scan (token-level dynamicAccess and creation-site checks) under the Luau CLI.
-- Run from a directory holding lex.luau, scan.luau and corpus.luau (written by corpus_module.py):
--   luau -O2 bench_scan.luau            (interpreted)     luau -O2 --codegen bench_scan.luau   (native)
local corpus = require("./corpus")
local lex = require("./lex")
local scan = require("./scan")
local scripts, bytes = {}, 0
for i, src in corpus do
	-- every 50th script requires the shard and indexes it with a computed key, as in scale_place.luau
	if i % 50 == 0 then src = "local Net = require(game.ReplicatedStorage.Shared.Net.client)\nlocal k = 'x'\nNet[k]:fire()\n" .. src end
	scripts[i] = { path = "S" .. i, name = "S" .. i, source = src, client = true, lync = false }
	bytes += #src
end
local best, bestLex = math.huge, math.huge
for _ = 1, 5 do
	local t0 = os.clock()
	for _, s in scripts do lex(s.source) end
	bestLex = math.min(bestLex, os.clock() - t0)
	local t1 = os.clock()
	local f = scan(scripts, { client = "Net" })
	best = math.min(best, os.clock() - t1)
	assert(#f >= 1)
end
print(string.format("scripts=%d bytes=%d lex: %.1f ms (%.1f MB/s)  lex+scan: %.1f ms (%.1f MB/s)", #scripts, bytes,
	bestLex * 1e3, bytes / bestLex / 1e6, best * 1e3, bytes / best / 1e6))
