--!nocheck
-- t.array(t.optional(c)) in a column block: Columns.write concatenates every row's elements with
-- table.move(value, 1, #value, #elements + 1, elements). Once one row ends a run of elements with
-- a nil, `#elements` is any border, so the next row's elements overwrite earlier ones.
-- Run: lune run p3_array_holes.luau
local P = require("./prelude")
local Bits, Run = P.Bits, P.Run
local t = P.Lync.types

local codec = P.plan(P.Lync, t.array(t.optional(t.int(0, 9)), 9))

local function roundTrip(values)
	local w = Bits.writer()
	Run.encode(w, codec, values, #values, { list = {}, index = {} }, "p.e:fire")
	local out = {}
	local rule = Run.decode(Bits.reader(Bits.finish(w)), codec, #values, {}, out)
	return rule, out
end

local function show(array)
	local parts = {}
	for i = 1, 6 do
		parts[i] = tostring(array[i])
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- Each row's own length is unambiguous (its last element is present); three rows make a column block.
local rows = {
	{ 1, nil, 3 },
	{ 4, 5, 6 },
	{ 7, 8, 9 },
}
for i, row in rows do
	print(string.format("row %d: #row = %d", i, #row))
end
local rule, out = roundTrip(rows)
print("rule", rule)
for i = 1, 3 do
	print(string.format("row %d: sent %s, decoded %s", i, show(rows[i]), show(out[i] or {})))
end

-- The same rows built by assignment, as game code often builds arrays.
local built = {}
for i = 1, 3 do
	local row = {}
	row[1] = i
	row[3] = i + 2
	built[i] = row
end
for i, row in built do
	print(string.format("built row %d: #row = %d (sent as %d elements)", i, #row, #row))
end

-- Rows whose last element is present, so each row's length is unambiguous to its sender.
local cases = {
	{ { nil, nil, 3 }, { 4, 5, 6 }, { 7, 8, 9 } },
	{ { nil, 2 }, { 4 }, { 7 } },
}
math.randomseed(7)
for _ = 1, 200 do
	local rowsCase = {}
	for r = 1, 3 do
		local length = math.random(1, 5)
		local row = table.create(length)
		for i = 1, length do
			if i == length or math.random() < 0.6 then
				row[i] = math.random(0, 9)
			end
		end
		rowsCase[r] = row
	end
	table.insert(cases, rowsCase)
end

local wrong = 0
local firstWrong = nil
for _, case in cases do
	local ok, ruleOrErr, decoded = pcall(roundTrip, case)
	local same = ok and ruleOrErr == 0
	if same then
		for r = 1, 3 do
			for i = 1, 5 do
				if decoded[r][i] ~= case[r][i] then
					same = false
				end
			end
		end
	end
	if not same then
		wrong += 1
		firstWrong = firstWrong or { case, ok, ruleOrErr, decoded }
	end
end
print(string.format("%d of %d three-row runs decode to something other than what was sent", wrong, #cases))
if firstWrong then
	local case, ok, ruleOrErr, decoded = table.unpack(firstWrong)
	for r = 1, 3 do
		print(string.format("  row %d: #=%d sent %s, decoded %s", r, #case[r], show(case[r]), if ok and decoded then show(decoded[r] or {}) else tostring(ruleOrErr)))
	end
end
