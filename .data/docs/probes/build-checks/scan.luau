--!strict
-- Prototype of the core's script scan for two build checks (research/build-checks.md):
--   * dynamicAccess: uses of a client namespace value that reach definitions without naming them. Exactly the
--     uses that make a namespace incomplete for reachability (v5-integrity.md §3), so one predicate feeds both.
--   * foreignRemotes, creation sites: Instance.new of a remote or bindable class in a script.
-- Token level only (lex.luau). Usage: scan(scripts, leaves) where scripts = { {path, source, client: boolean,
-- lync: boolean} } and leaves = { [shardInstanceName]: namespaceName }.
local lex = require("./lex")

local CREATED = { RemoteEvent = 1, UnreliableRemoteEvent = 1, RemoteFunction = 1, BindableEvent = 1, BindableFunction = 1 }
-- callees that only inspect a value: passing a namespace to them is not an escape
local INSPECT = { typeof = true, type = true, tostring = true, print = true, warn = true, rawequal = true }
-- callees that return their argument: the result is an alias
local IDENTITY = { assert = true, freeze = true, clone = true }
local ITER = { pairs = true, ipairs = true, next = true }

export type Finding = { check: string, path: string, line: number, col: number, kind: number, detail: string }

local function scan(scripts: { any }, leaves: { [string]: string })
	local findings: { Finding } = {}
	local toks = {}
	for i, s in scripts do
		toks[i] = lex(s.source)
	end

	-- function definitions by name across scanned client scripts: name -> { {script, params, isMethod} }
	local defs: { [string]: { any } } = {}
	for si, s in scripts do
		if not s.client or s.lync then continue end
		local t = toks[si]
		local k, x = t.kind, t.text
		for i = 1, t.n do
			if k[i] == "n" and x[i] == "function" then
				-- function NAME( | function A.B.NAME( | function A:NAME(
				local j, name, isMethod = i + 1, nil, false
				while k[j] == "n" do
					name = x[j]
					if x[j + 1] == "." or x[j + 1] == ":" then
						isMethod = x[j + 1] == ":"
						j += 2
					else
						j += 1
						break
					end
				end
				if not name then -- anonymous: NAME = function( | local NAME = function(
					if x[i - 1] == "=" and k[i - 2] == "n" then name = x[i - 2] end
					j = i + 1
				end
				if name and x[j] == "(" then
					local params = {}
					j += 1
					while x[j] ~= ")" and j <= t.n do
						if k[j] == "n" then table.insert(params, x[j]) end
						j += 1
						if x[j] == ":" then -- skip a type annotation up to , or )
							local depth = 0
							while j <= t.n and not (depth == 0 and (x[j] == "," or x[j] == ")")) do
								if x[j] == "(" or x[j] == "{" then depth += 1 elseif x[j] == ")" or x[j] == "}" then depth -= 1 end
								j += 1
							end
						end
						if x[j] == "," then j += 1 end
					end
					defs[name] = defs[name] or {}
					table.insert(defs[name], { si = si, params = params, isMethod = isMethod })
				end
			end
		end
	end

	-- binding state per script: vars (local names), and global field names (any `.f` read)
	local vars: { { [string]: string } } = {} -- script -> name -> namespace
	local fields: { [string]: string } = {} -- field name -> namespace
	local modules: { [string]: string } = {} -- module instance name -> namespace (it returns a binding)
	for si in scripts do vars[si] = {} end
	local reported: { [string]: boolean } = {}

	local function report(s, t, i, kind, detail)
		local key = s.path .. ":" .. t.line[i] .. ":" .. t.col[i] .. ":" .. kind
		if reported[key] then return end
		reported[key] = true
		table.insert(findings, { check = "dynamicAccess", path = s.path, line = t.line[i], col = t.col[i], kind = kind, detail = detail })
	end

	-- matching close bracket for an opener at i
	local function closeOf(t, i)
		local x, depth = t.text, 0
		for j = i, t.n do
			local c = x[j]
			if c == "(" or c == "[" or c == "{" then depth += 1
			elseif c == ")" or c == "]" or c == "}" then
				depth -= 1
				if depth == 0 then return j end
			end
		end
		return t.n
	end

	-- the namespace a require( ... ) / TS.import( ... ) argument list names, by its last name or string
	local function requiredNamespace(t, open): string?
		local close = closeOf(t, open)
		local last
		for j = open + 1, close - 1 do
			if t.kind[j] == "s" or (t.kind[j] == "n" and t.text[j - 1] == ".") then last = t.text[j] end
		end
		return if last then (leaves[last] or modules[last]) else nil
	end

	-- record an alias target for the value at expression start `e` (token index of the first token of the value)
	local function bindTarget(si, t, e, ns): boolean
		local x, k = t.text, t.kind
		if x[e - 1] ~= "=" then return false end
		local j = e - 2
		-- skip a type annotation `local a: T = ...`
		local p = j
		while p > 0 and x[p] ~= "local" and x[p] ~= "\n" and not (k[p] == "p" and (x[p] == ";" or x[p] == ")")) and e - p < 12 do
			if x[p] == ":" and k[p - 1] == "n" and x[p - 2] == "local" then j = p - 1 break end
			p -= 1
		end
		if k[j] ~= "n" then return false end
		local name = x[j]
		if x[j - 1] == "." then
			if not fields[name] then fields[name] = ns return true end
		elseif x[j - 1] == "{" or (x[j - 1] == "," and k[j] == "n") then
			if not fields[name] then fields[name] = ns return true end
		elseif not vars[si][name] then
			vars[si][name] = ns
			return true
		end
		return false
	end

	local changed = true
	local rounds = 0
	while changed do
		changed = false
		rounds += 1
		for si, s in scripts do
			if not s.client or s.lync then continue end
			local t = toks[si]
			local k, x = t.kind, t.text
			-- open-bracket stack, to know whether a `name =` sits in a table constructor
			for i = 1, t.n do
				-- binding sources: require(...) and TS.import(...)
				if k[i] == "n" and (x[i] == "require" or (x[i] == "import" and x[i - 1] == "." and x[i - 2] == "TS")) and x[i + 1] == "(" then
					local ns = requiredNamespace(t, i + 1)
					if ns then
						local startTok = if x[i] == "import" then i - 2 else i
						if bindTarget(si, t, startTok, ns) then changed = true end
						if x[startTok - 1] == "return" and not modules[s.name] then
							modules[s.name] = ns
							changed = true
						end
					end
				end
				-- a binding reference: a local name (not a field), or a field read `.f` of a binding field
				local ns
				if k[i] == "n" then
					local prev = x[i - 1]
					if prev ~= "." and prev ~= ":" and vars[si][x[i]] and x[i - 1] ~= "local" and x[i - 1] ~= "function" then
						ns = vars[si][x[i]]
					elseif prev == "." and fields[x[i]] then
						ns = fields[x[i]]
					end
				end
				if not ns then continue end
				local name = x[i]
				-- start of the reference expression (for `a.b.f`, the first name)
				local e = i
				while x[e - 1] == "." and k[e - 2] == "n" do e -= 2 end
				local nxt = x[i + 1]
				if nxt == "[" then
					local close = closeOf(t, i + 1)
					if not (close == i + 3 and k[i + 2] == "s") then
						report(s, t, i, 1, name .. "[…]")
					end
				elseif x[e - 1] == "in" or (x[e - 1] == "(" and ITER[x[e - 2]]) or (x[e - 1] == "," and x[e - 2] == "next" and x[e - 3] == "in") then
					report(s, t, i, 2, "iterate " .. name)
				elseif x[e - 1] == "return" and nxt ~= "." and nxt ~= ":" and nxt ~= "(" then
					if not modules[s.name] then modules[s.name] = ns changed = true end
				elseif x[e - 1] == "=" and nxt ~= "." and nxt ~= ":" and nxt ~= "(" and nxt ~= "[" then
					if bindTarget(si, t, e, ns) then changed = true end
				elseif (x[e - 1] == "(" or x[e - 1] == ",") and nxt ~= "." and nxt ~= ":" and nxt ~= "[" then
					-- argument position: walk back to the call's opening parenthesis
					local depth, j, pos = 0, e - 1, 1
					while j > 0 do
						local c = x[j]
						if c == ")" or c == "]" or c == "}" then depth += 1
						elseif c == "(" or c == "[" or c == "{" then
							if depth == 0 then break end
							depth -= 1
						elseif c == "," and depth == 0 then pos += 1 end
						j -= 1
					end
					if x[j] == "(" and k[j - 1] == "n" then
						local callee = x[j - 1]
						local viaColon = x[j - 2] == ":"
						if INSPECT[callee] or callee == "require" then
							-- nothing
						elseif IDENTITY[callee] then
							local cs = j - 1
							while x[cs - 1] == "." and k[cs - 2] == "n" do cs -= 2 end
							if bindTarget(si, t, cs, ns) then changed = true end
						elseif defs[callee] then
							for _, d in defs[callee] do
								local p = pos + (if viaColon and not d.isMethod then 1 elseif d.isMethod and not viaColon then -1 else 0)
								local param = d.params[p]
								if param and not vars[d.si][param] then
									vars[d.si][param] = ns
									changed = true
								end
							end
						else
							report(s, t, i, 3, "passed to " .. callee .. "()")
						end
					elseif x[j] == "{" then
						-- positional table entry {Net}: stored where the scan cannot follow it by name
						report(s, t, i, 3, "stored in a table constructor")
					end
				elseif x[e - 1] == "=" and x[e - 2] == "]" then
					report(s, t, i, 3, "stored under a computed key")
				end
			end
		end
	end

	-- creation sites: Instance.new("Class"), and Instance.new(non-literal)
	for si, s in scripts do
		if s.lync then continue end
		local t = toks[si]
		local k, x = t.kind, t.text
		for i = 1, t.n - 3 do
			if x[i] == "Instance" and x[i + 1] == "." and x[i + 2] == "new" and x[i + 3] == "(" then
				if k[i + 4] == "s" then
					if CREATED[x[i + 4]] then
						table.insert(findings, { check = "foreignRemotes", path = s.path, line = t.line[i], col = t.col[i], kind = 2, detail = x[i + 4] })
					end
				else
					table.insert(findings, { check = "foreignRemotes", path = s.path, line = t.line[i], col = t.col[i], kind = 3, detail = "Instance.new(<non-literal>)" })
				end
			end
		end
	end
	local tokens = 0
	for _, t in toks do tokens += t.n end
	return findings, { rounds = rounds, tokens = tokens, modules = modules, fields = fields }
end

return scan
