--!strict
-- Probe: a build-time generator for Lync, run by Lute 1.0.0 over a Rojo project.
-- Usage: lute run gen.luau <projectDir> <seed> <outDir>
-- It reads sourcemap.json, evaluates each namespace module with a recording stand-in for Lync,
-- emits one generated shard per namespace (seeded field order, ids and tag constants), a manifest
-- with SHA-256 hashes, and a static report over client scripts. Codecs are byte-aligned stand-ins,
-- not the v5 bit-packed wire; the probe tests the pipeline, determinism and bytecode shape only.

local fs = require("@std/fs")
local json = require("@std/json")
local luau = require("@std/luau")
local syntax = require("@std/syntax")
local query = require("@std/syntax/query")
local crypto = require("@lute/crypto")

local args = { ... }
local projectDir = assert(args[2], "projectDir")
local seed = assert(tonumber(args[3]), "seed")
local outDir = assert(args[4], "outDir")

local function hex(b: buffer): string
	local parts = table.create(buffer.len(b))
	for i = 0, buffer.len(b) - 1 do
		parts[i + 1] = string.format("%02x", buffer.readu8(b, i))
	end
	return table.concat(parts)
end

local function sha256(s: string): string
	return hex(crypto.digest(crypto.hash.sha256, s))
end

-- xorshift32 over bit32: the same code runs in Lute, a Studio plugin and the runtime, so a seed gives
-- the same permutation on every host. Roblox's Random is not used: its algorithm is not documented.
local function rng(s: number): () -> number
	local state = bit32.bxor(s, 0x9E3779B9)
	if state == 0 then
		state = 1
	end
	return function(): number
		state = bit32.bxor(state, bit32.lshift(state, 13))
		state = bit32.bxor(state, bit32.rshift(state, 17))
		state = bit32.bxor(state, bit32.lshift(state, 5))
		return state
	end
end

-- Fisher-Yates; seed 0 is the identity so seed-0 builds are canonical and golden-stable.
local function permute<T>(list: { T }, s: number, salt: string): { T }
	local out = table.clone(list)
	if s == 0 then
		return out
	end
	local saltValue = 0
	for i = 1, #salt do
		saltValue = bit32.bxor(bit32.lrotate(saltValue, 5), string.byte(salt, i))
	end
	local next = rng(bit32.bxor(s, saltValue))
	for i = #out, 2, -1 do
		local j = next() % i + 1
		out[i], out[j] = out[j], out[i]
	end
	return out
end

-- Recording stand-in for Lync: declarations become plain descriptors.
local function recorder()
	local Lync = {}
	local function codec(kind: string, ...: any)
		return { kind = kind, args = { ... } }
	end
	Lync.integer = function(...) return codec("integer", ...) end
	Lync.number = function(...) return codec("number", ...) end
	Lync.vector3 = function(...) return codec("vector3", ...) end
	Lync.string = function(...) return codec("string", ...) end
	Lync.array = function(...) return codec("array", ...) end
	local Definition = {}
	Definition.__index = Definition
	function Definition.unreliable(self)
		self.lane = "u"
		return self
	end
	Lync.event = function(schema)
		return setmetatable({ form = "event", lane = "r", schema = schema }, Definition)
	end
	Lync.request = function(schema, reply)
		return setmetatable({ form = "request", lane = "r", schema = schema, reply = reply }, Definition)
	end
	Lync.namespace = function(defs)
		return defs
	end
	return Lync
end

-- Walk the Rojo sourcemap into a flat list of scripts with their instance paths.
type Script = { path: string, className: string, file: string }
local scripts: { Script } = {}
local function walk(node: any, prefix: string)
	local here = if prefix == "" then node.name else prefix .. "." .. node.name
	if node.filePaths and string.match(node.className, "Script$") then
		for _, file in node.filePaths do
			if string.match(file, "%.luau$") then
				table.insert(scripts, { path = here, className = node.className, file = file })
			end
		end
	end
	for _, child in node.children or {} do
		walk(child, here)
	end
end
local sourcemap = json.deserialize(fs.readFileToString(projectDir .. "/sourcemap.json")) :: any
walk(sourcemap, "")
table.sort(scripts, function(a, b)
	return a.path < b.path
end)

-- Byte width of a stand-in codec, and the write and read lines for one field.
local function width(c: any): number
	if c.kind == "integer" then
		local span = c.args[2] - c.args[1]
		return if span < 2 ^ 8 then 1 elseif span < 2 ^ 16 then 2 elseif span < 2 ^ 32 then 4 else 8
	elseif c.kind == "number" then
		local steps = (c.args[2] - c.args[1]) / c.args[3]
		return if steps < 2 ^ 8 then 1 else 2
	elseif c.kind == "vector3" then
		return 12
	end
	return 0
end

local function sortedKeys(t: { [string]: any }): { string }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys) -- Luau table iteration order is unspecified; every emitted order starts sorted
	return keys
end

local function emitWrite(lines: { string }, name: string, c: any, where: string)
	local w = width(c)
	if c.kind == "integer" then
		local fn = if w == 1 then "writeu8" elseif w == 2 then "writeu16" elseif w == 4 then "writeu32" else "writef64"
		table.insert(lines, `\tif typeof(v.{name}) ~= "number" then error("[Lync] {where}.{name} must be a number", 3) end`)
		table.insert(lines, `\tbuffer.{fn}(b, o, v.{name} - {c.args[1]}); o += {w}`)
	elseif c.kind == "number" then
		local fn = if w == 1 then "writeu8" else "writeu16"
		table.insert(lines, `\tbuffer.{fn}(b, o, math.round((v.{name} - {c.args[1]}) / {c.args[3]})); o += {w}`)
	elseif c.kind == "vector3" then
		for i, axis in { "x", "y", "z" } do
			table.insert(lines, `\tbuffer.writei32(b, o + {(i - 1) * 4}, math.round(v.{name}.{axis} / {c.args[3]}))`)
		end
		table.insert(lines, "\to += 12")
	elseif c.kind == "array" then
		table.insert(lines, `\tbuffer.writeu8(b, o, #v.{name}); o += 1`)
		table.insert(lines, `\tfor _, s in v.{name} do buffer.writeu8(b, o, #s); buffer.writestring(b, o + 1, s); o += 1 + #s end`)
	end
end

-- Per-build constants: a definition id permutation, a field order per record and four tag constants.
local manifest = { seed = seed, namespaces = {}, files = {} }
fs.createDirectory(outDir, { makeParents = true })
local nsScripts = {}
for _, s in scripts do
	if s.className == "ModuleScript" then
		local src = fs.readFileToString(projectDir .. "/" .. s.file)
		if string.find(src, "Lync.namespace(", 1, true) then
			table.insert(nsScripts, s)
		end
	end
end

local analysisNames: { [string]: { string } } = {}
for _, s in nsScripts do
	local src = fs.readFileToString(projectDir .. "/" .. s.file)
	local env = setmetatable({ require = function() return recorder() end }, { __index = _G })
	local defs = luau.load(luau.compile(src), "=" .. s.path, env)()
	local names = sortedKeys(defs)
	analysisNames[s.path] = names
	local order = permute(names, seed, s.path .. "#ids")
	local ids = {}
	for id, name in order do
		ids[name] = id - 1
	end
	local next = rng(bit32.bxor(seed, 0x51A7))
	local tagConstants = if seed == 0 then { 0x736f6d65, 0x646f7261, 0x6c796765, 0x74656462 } else { next(), next(), next(), next() }
	local lines = {
		`-- Generated by the Lync probe generator. Do not edit.`,
		`-- schema {s.file}; seed {seed}`,
		"--!strict",
		"--!optimize 2",
		"local M = {}",
		`M.TAG = \{ {table.concat(tagConstants, ", ")} \}`,
	}
	local srcLines = string.split(src, "\n")
	for _, name in names do
		local def = defs[name]
		local where = `{s.path}.{name}`
		local line = 0
		for i, text in srcLines do
			if string.find(text, "%f[%w]" .. name .. "%s*=") then
				line = i
				break
			end
		end
		table.insert(lines, `-- {where} ({def.form}, lane {def.lane}) from {s.file}:{line}`)
		table.insert(lines, `M.{name} = \{ id = {ids[name]} \}`)
		table.insert(lines, `function M.{name}.write(b: buffer, o: number, v: any): number`)
		if def.schema then
			local fields = permute(sortedKeys(def.schema), seed, where)
			for _, field in fields do
				emitWrite(lines, field, def.schema[field], where)
			end
		end
		table.insert(lines, "\treturn o")
		table.insert(lines, "end")
	end
	table.insert(lines, "return M")
	local text = table.concat(lines, "\n") .. "\n"
	local outName = s.path .. ".gen.luau"
	fs.writeStringToFile(outDir .. "/" .. outName, text)
	manifest.files[outName] = sha256(text)
	manifest.namespaces[s.path] = { ids = ids, schemaSha256 = sha256(src) }
end

-- Static report over scripts: definitions client code fires, dynamic access, raw remotes, remote creation.
local report = { clientFires = {}, dynamicAccess = {}, rawRemoteCalls = {}, remoteCreation = {} }
for _, s in scripts do
	local src = fs.readFileToString(projectDir .. "/" .. s.file)
	local isClient = s.className == "LocalScript" or string.match(s.file, "%.client%.luau$") ~= nil
	local parsed = syntax.parse(src)
	query.findAllFromRoot(parsed, function(n: any)
		return if n.kind == "expr" and n.tag == "call" then n else nil
	end):forEach(function(call: any)
		local f = call.func
		local line = call.location.beginLine
		if call.self and f.tag == "indexname" then
			local method = f.index.text
			if (method == "fire" or method == "invoke") and isClient then
				if f.expression.tag == "indexname" then
					table.insert(report.clientFires, `{f.expression.index.text} ({s.path}:{line})`)
				elseif f.expression.tag == "index" then
					table.insert(report.dynamicAccess, `{s.path}:{line}`)
				end
			elseif method == "FireServer" or method == "InvokeServer" or method == "FireClient" or method == "FireAllClients" then
				table.insert(report.rawRemoteCalls, `{method} at {s.path}:{line}`)
			end
		elseif f.tag == "indexname" and f.index.text == "new" and f.expression.tag == "global" and f.expression.name.text == "Instance" then
			local a = call.arguments[1]
			local arg = a and (a.node or a)
			local tok = if arg and arg.tag == "string" then (arg.token or arg.value) else nil -- Lute 1.0.0 names it token
			local text = if type(tok) == "table" then tok.text else tok
			if text and string.find(text, "Remote", 1, true) then
				table.insert(report.remoteCreation, `{text} at {s.path}:{line}`)
			end
		end
	end)
end
for _, list in report do
	table.sort(list)
end
manifest.report = report
local manifestText = json.serialize(manifest, true)
fs.writeStringToFile(outDir .. "/manifest.json", manifestText)
print(`seed {seed}: manifest sha256 {sha256(manifestText)}`)
for name, digest in manifest.files do
	print(`  {name} {digest}`)
end
print("  client fires: " .. table.concat(report.clientFires, ", "))
print("  dynamic access: " .. table.concat(report.dynamicAccess, ", "))
print("  raw remote calls: " .. table.concat(report.rawRemoteCalls, ", "))
print("  remote creation: " .. table.concat(report.remoteCreation, ", "))
