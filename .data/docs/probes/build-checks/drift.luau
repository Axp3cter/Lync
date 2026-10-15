--!nocheck
-- U6 probe (Lune 0.11.0): the shard self-hash and the drift cases it separates, and SHA-256 cost per shard size.
-- Usage: lune run drift.luau SAMPLE_SOURCE_FILE
-- Header line 1 of a shard (proposed):  -- Lync 5.0.0 | arena | client | build 3735928559 | schema 0123456789abcdef | code <sha256 hex>
-- "code" is SHA-256 of every byte after line 1, with CRLF normalised to LF first.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local function body(text)
	local nl = string.find(text, "\n", 1, true)
	return string.gsub(string.sub(text, nl + 1), "\r\n", "\n")
end
local function header(text)
	return string.match(text, "^[^\n]*")
end
local function field(h, key)
	return string.match(h, "| " .. key .. " (%S+)")
end
local function emit(side, build, schema, src)
	local b = string.gsub(src, "\r\n", "\n")
	local h = string.format("-- Lync 5.0.0 | arena | %s | build %d | schema %s | code %s", side, build, schema,
		serde.hash("sha256", b))
	return h .. "\n" .. b
end

-- the checks, as lync check / the plugin would run them over a pair of shards
local function check(client, server)
	local out = {}
	for _, s in { { "client", client }, { "server", server } } do
		local h = header(s[2])
		if field(h, "code") ~= serde.hash("sha256", body(s[2])) then
			table.insert(out, "editedShard " .. s[1])
		end
	end
	local hc, hs = header(client), header(server)
	if field(hc, "build") ~= field(hs, "build") or field(hc, "schema") ~= field(hs, "schema") then
		table.insert(out, string.format("unpairedShards client build %s, server build %s", field(hc, "build"), field(hs, "build")))
	end
	return if #out == 0 then "clean" else table.concat(out, "; ")
end

local sample = fs.readFile(process.args[1])
local c1 = emit("client", 3735928559, "0123456789abcdef", sample)
local s1 = emit("server", 3735928559, "0123456789abcdef", "return {}\n")
local s2 = emit("server", 42, "0123456789abcdef", "return {}\n")
print("as built:                     " .. check(c1, s1))
print("CRLF checkout (autocrlf):     " .. check((string.gsub(c1, "\n", "\r\n")), s1))
print("one constant hand-edited:     " .. check((string.gsub(c1, "255", "256", 1)), s1))
print("reformatted (tabs to spaces): " .. check((string.gsub(c1, "\t", "    ")), s1))
print("server from another run:      " .. check(c1, s2))
print("header line edited only:      " .. check((string.gsub(c1, "| arena |", "| arena2 |", 1)), s1))

-- cost: SHA-256 through the host (Lune's serde.hash, Rust sha2), best of 20, per size
for _, kb in { 4, 64, 640, 6400 } do
	local s = string.rep(sample, math.ceil(kb * 1024 / #sample)):sub(1, kb * 1024)
	local best = math.huge
	for _ = 1, 20 do
		local t = os.clock()
		serde.hash("sha256", s)
		best = math.min(best, os.clock() - t)
	end
	local bestNorm = math.huge
	for _ = 1, 20 do
		local t = os.clock()
		local _ = string.gsub(s, "\r\n", "\n")
		bestNorm = math.min(bestNorm, os.clock() - t)
	end
	print(string.format("sha256 %5d KB: %8.3f ms (%.0f MB/s); CRLF normalise %8.3f ms", kb, best * 1e3,
		kb / 1024 / best, bestNorm * 1e3))
end
