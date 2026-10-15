--!strict
-- A token-level Luau lexer of the kind the compiler core would carry (client-security-build.md §1.1): it runs
-- unchanged in the CLI host (mlua, Lune) and in a Studio plugin. It only has to separate names, strings, numbers
-- and punctuation correctly and skip comments; it does not parse.
-- Token arrays: kind[i] ("n" name, "s" string, "#" number, "p" punctuation, "i" interpolated string start),
-- text[i] (name, punctuation or the string's decoded body for plain escapes), line[i], col[i].

export type Tokens = { kind: { string }, text: { string }, line: { number }, col: { number }, n: number }

local function lex(src: string): Tokens
	local kind, text, lines, cols = {}, {}, {}, {}
	local n = 0
	local i, len = 1, #src
	local line, lineStart = 1, 1
	local byte, sub, find = string.byte, string.sub, string.find

	local function push(k: string, t: string, at: number)
		n += 1
		kind[n] = k
		text[n] = t
		lines[n] = line
		cols[n] = at - lineStart + 1
	end

	-- counts newlines in [a, b] and moves line/lineStart
	local function advanceLines(a: number, b: number)
		local p = a
		while true do
			local q = find(src, "\n", p, true)
			if not q or q > b then
				break
			end
			line += 1
			lineStart = q + 1
			p = q + 1
		end
	end

	-- long bracket [=*[ at position i; returns the end index of the closing bracket, or len
	local function longBracket(at: number): number?
		local s, e, eq = find(src, "^%[(=*)%[", at)
		if not s then
			return nil
		end
		local close = "]" .. eq .. "]"
		local c = find(src, close, (e :: number) + 1, true)
		return if c then c + #close - 1 else len
	end

	while i <= len do
		local c = byte(src, i)
		if c == 10 then
			line += 1
			i += 1
			lineStart = i
		elseif c == 32 or c == 9 or c == 13 then
			i += 1
		elseif c == 45 and byte(src, i + 1) == 45 then -- comment
			local e = longBracket(i + 2)
			if e then
				advanceLines(i, e)
				i = e + 1
			else
				local q = find(src, "\n", i, true)
				i = if q then q else len + 1
			end
		elseif (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or c == 95 then
			local s, e = find(src, "^[%w_]+", i)
			push("n", sub(src, s :: number, e :: number), i)
			i = (e :: number) + 1
		elseif c >= 48 and c <= 57 or (c == 46 and (byte(src, i + 1) or 0) >= 48 and (byte(src, i + 1) or 0) <= 57) then
			local _, e = find(src, "^[%w_%.]+", i)
			-- exponent sign (1e+5)
			while byte(src, (e :: number)) == 101 or byte(src, (e :: number)) == 69 do
				local s2, e2 = find(src, "^[%+%-][%w_%.]+", (e :: number) + 1)
				if not s2 then
					break
				end
				e = e2
			end
			push("#", sub(src, i, e :: number), i)
			i = (e :: number) + 1
		elseif c == 34 or c == 39 or c == 96 then -- " ' `
			local q = c
			local j = i + 1
			local buf = {}
			local plain = true
			while j <= len do
				local d = byte(src, j)
				if d == 92 then -- backslash: keep the next byte, note non-plain
					plain = false
					if byte(src, j + 1) == 10 then
						line += 1
						lineStart = j + 2
					end
					j += 2
				elseif d == q then
					break
				elseif d == 10 and q ~= 96 then
					break -- unterminated: stop at the line end
				elseif q == 96 and d == 123 then -- `{` in an interpolated string: treat as non-literal
					plain = false
					j += 1
				else
					if d == 10 then
						line += 1
						lineStart = j + 1
					end
					table.insert(buf, string.char(d))
					j += 1
				end
			end
			push(if q == 96 and not plain then "i" else "s", if plain then table.concat(buf) else "\0", i)
			i = j + 1
		elseif c == 91 then -- [ : long string or punctuation
			local e = longBracket(i)
			if e then
				local body = sub(src, i, e)
				local open = find(body, "[", 2, true) :: number
				push("s", sub(body, open + 1, #body - open), i)
				advanceLines(i, e)
				i = e + 1
			else
				push("p", "[", i)
				i += 1
			end
		else
			local three = sub(src, i, i + 2)
			if three == "..." or three == "..=" or three == "//=" then
				push("p", three, i)
				i += 3
			else
				local two = sub(src, i, i + 1)
				if two == "==" or two == "~=" or two == "<=" or two == ">=" or two == ".." or two == "::" or two == "->"
					or two == "+=" or two == "-=" or two == "*=" or two == "/=" or two == "%=" or two == "^=" or two == "//" then
					push("p", two, i)
					i += 2
				else
					push("p", string.char(c), i)
					i += 1
				end
			end
		end
	end
	return { kind = kind, text = text, line = lines, col = cols, n = n }
end

return lex
