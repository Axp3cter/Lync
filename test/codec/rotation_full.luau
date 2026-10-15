--!strict

--[=[
	rotation_full

	Lune script for the full `t.rotation` checks of v5.md §3.3 (decision "quantizers are
	idempotent"), too slow for the default suite, from the repo root:

	- `lune run test/codec/rotation_full.luau exhaustive <bits> [part] [parts]`: every code at
	  `bits` (the codes whose first kept component is `part` modulo `parts`, to split the work);
	- `lune run test/codec/rotation_full.luau random <count> [seed]`: `count` random rotations,
	  at widths 9 to 15 in turn;
	- `lune run test/codec/rotation_full.luau error [samples] [seed] [first]`: the worst-case error
	  search, per width from 7 to 15, of the canonical encoding (or with `first`, of the first
	  encoding, as before draft 3.2).

	For each code it checks that the decoder refuses it or that encoding its decoding gives it
	back, that every encoder output is canonical, and it counts how many re-encodings the encoder
	took: a fixed point or a 2-cycle within 4 steps, or a failure.
]=]

-- Imports -----------------------------------------------------------------------------------------

local process = require("@lune/process")
local roblox = require("@lune/roblox")

-- The codecs need Roblox datatypes as globals, as `test/run.luau` provides them.
local environment = getfenv(0)
environment.Vector3 = roblox.Vector3
environment.CFrame = roblox.CFrame
environment.Color3 = roblox.Color3

local Leaves = require("../../src/codec/leaves")
local Quant = require("../../src/wire/quant")

-- Types -------------------------------------------------------------------------------------------

--[=[
	What a run found.

	@field codes       how many codes or rotations were checked
	@field accepted    how many codes the decoder accepts
	@field refused     how many codes the decoder refuses
	@field stepCounts  how many encodings took each number of re-encodings, at index steps
	@field failures    descriptions of every failed check, the first 20 kept
	@field failedCount how many checks failed
]=]
type Tally = {
	codes: number,
	accepted: number,
	refused: number,
	stepCounts: { number },
	failures: { string },
	failedCount: number,
}

-- Constants ---------------------------------------------------------------------------------------

const MAX_STEPS = 4
const MAX_FAILURES_KEPT = 20

--- How many of the worst samples the error search climbs from, and for how many steps.
const CLIMBS = 100
const CLIMB_STEPS = 1500

-- State -------------------------------------------------------------------------------------------

--- Whether the error search measures the first encoding instead of the canonical one.
local isFirstEncoding = false

-- Private -----------------------------------------------------------------------------------------

local function newTally(): Tally
	return {
		codes = 0,
		accepted = 0,
		refused = 0,
		stepCounts = table.create(MAX_STEPS, 0),
		failures = {},
		failedCount = 0,
	}
end

local function fail(tally: Tally, description: string)
	tally.failedCount += 1
	if #tally.failures < MAX_FAILURES_KEPT then
		table.insert(tally.failures, description)
	end
end

-- Encodes with the fewest re-encodings that succeed; nil after `MAX_STEPS`.
local function encoded(value: CFrame, bits: number): (number?, { number })
	for steps = 1, MAX_STEPS do
		local ok, flag, index, a, b, c = pcall(Leaves.rotationCodes, value, bits, steps)
		if ok then
			return steps, { flag, index, a, b, c }
		end
	end

	return nil, {}
end

local function checkEncoding(tally: Tally, value: CFrame, bits: number, label: string): { number }?
	local steps, codes = encoded(value, bits)
	if steps == nil then
		fail(tally, `{label}: no fixed point or 2-cycle within {MAX_STEPS} steps`)
		return nil
	end

	tally.stepCounts[steps] += 1
	if not Leaves.canonicalRotation(codes[1], codes[2], codes[3], codes[4], codes[5], bits) then
		fail(tally, `{label}: encoder output {table.concat(codes, ",")} is not canonical`)
	end

	return codes
end

local function checkCode(tally: Tally, codes: { number }, bits: number)
	tally.codes += 1
	local label = `{bits} bits, code {table.concat(codes, ",")}`
	local decoded =
		Leaves.rotationOf(codes[1], codes[2], codes[3], codes[4], codes[5], bits, 0, 0, 0)
	local isCanonical =
		Leaves.canonicalRotation(codes[1], codes[2], codes[3], codes[4], codes[5], bits)
	if decoded == nil then
		tally.refused += 1
		if isCanonical then
			fail(tally, `{label}: does not decode but is accepted`)
		end
		return
	end

	if isCanonical then
		tally.accepted += 1
	else
		tally.refused += 1
	end

	local reencoded = checkEncoding(tally, decoded, bits, label)
	if
		reencoded ~= nil
		and isCanonical
		and table.concat(reencoded, ",") ~= table.concat(codes, ",")
	then
		fail(tally, `{label}: accepted but re-encodes to {table.concat(reencoded, ",")}`)
	end
end

local function randomQuaternion(): (number, number, number, number)
	local u1, u2, u3 = math.random(), math.random() * 2 * math.pi, math.random() * 2 * math.pi
	local a, b = math.sqrt(1 - u1), math.sqrt(u1)

	return a * math.sin(u2), a * math.cos(u2), b * math.sin(u3), b * math.cos(u3)
end

local function report(tally: Tally)
	print(`codes {tally.codes}, accepted {tally.accepted}, refused {tally.refused}`)
	print(`encodings by re-encodings 1..{MAX_STEPS}: {table.concat(tally.stepCounts, " ")}`)
	print(`failures {tally.failedCount}`)
	for _, failure in tally.failures do
		print(`  {failure}`)
	end
end

local function runExhaustive(bits: number, part: number, parts: number)
	local tally = newTally()
	if part == 0 then
		for index = 0, 23 do
			checkCode(tally, { 1, index, 0, 0, 0 }, bits)
		end
	end

	local maxCode = 2 ^ bits - 1
	for dropped = 0, 3 do
		for a = part, maxCode, parts do
			for b = 0, maxCode do
				for c = 0, maxCode do
					checkCode(tally, { 0, dropped, a, b, c }, bits)
				end
			end
		end
	end
	report(tally)
end

local function runRandom(count: number, seed: number)
	math.randomseed(seed)
	local tally = newTally()
	for i = 1, count do
		local bits = 9 + (i - 1) % 7
		local x, y, z, w = randomQuaternion()
		local value = CFrame.new(0, 0, 0, x, y, z, w)
		tally.codes += 1
		local codes = checkEncoding(tally, value, bits, `{bits} bits, rotation {x} {y} {z} {w}`)
		if codes ~= nil then
			local decoded =
				Leaves.rotationOf(codes[1], codes[2], codes[3], codes[4], codes[5], bits, 0, 0, 0)
			local _, again = encoded(decoded :: CFrame, bits)
			if table.concat(again, ",") ~= table.concat(codes, ",") then
				fail(
					tally,
					`{bits} bits: {table.concat(codes, ",")} re-encodes to {table.concat(again, ",")}`
				)
			end
		end
	end
	report(tally)
end

-- The angle between two unit quaternions, in degrees, precise for small angles.
local function degreesBetween(
	x1: number,
	y1: number,
	z1: number,
	w1: number,
	x2: number,
	y2: number,
	z2: number,
	w2: number
): number
	local sign = if x1 * x2 + y1 * y2 + z1 * z2 + w1 * w2 < 0 then -1 else 1
	local dx, dy, dz, dw = x1 - sign * x2, y1 - sign * y2, z1 - sign * z2, w1 - sign * w2
	local chord = math.sqrt(dx * dx + dy * dy + dz * dz + dw * dw)

	return math.deg(4 * math.asin(math.min(1, chord / 2)))
end

local function errorOf(x: number, y: number, z: number, w: number, bits: number): number
	local length = math.sqrt(x * x + y * y + z * z + w * w)
	x, y, z, w = x / length, y / length, z / length, w / length
	local flag, index, a, b, c
	if isFirstEncoding then
		local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = CFrame.new(0, 0, 0, x, y, z, w)
			:GetComponents()
		flag, index, a, b, c = Quant.rotation(r00, r01, r02, r10, r11, r12, r20, r21, r22, bits)
	else
		flag, index, a, b, c = Leaves.rotationCodes(CFrame.new(0, 0, 0, x, y, z, w), bits)
	end
	local dx, dy, dz, dw = Quant.unrotation(flag :: number, index, a, b, c, bits)

	return degreesBetween(x, y, z, w, dx :: number, dy, dz, dw)
end

-- Random sampling, then hill climbing from the worst samples with shrinking perturbations.
local function worstError(bits: number, samples: number): number
	local candidates: { { number } } = {}
	for i = 1, samples do
		local x, y, z, w = randomQuaternion()
		if i % 2 == 0 then
			-- Half the samples sit near a tie of the two largest components, where the encoder
			-- re-encodes.
			local components = { x, y, z, w }
			local order = { 1, 2, 3, 4 }
			table.sort(order, function(left, right)
				return math.abs(components[left]) > math.abs(components[right])
			end)
			local first, second = order[1], order[2]
			local magnitude = (math.abs(components[first]) + math.abs(components[second])) / 2
			local jitter = (math.random() - 0.5) * 4 / (2 ^ bits - 1)
			components[first] = math.sign(components[first]) * magnitude
			components[second] = math.sign(components[second]) * (magnitude + jitter)
			x, y, z, w = components[1], components[2], components[3], components[4]
		end
		table.insert(candidates, { errorOf(x, y, z, w, bits), x, y, z, w })
	end
	table.sort(candidates, function(left, right)
		return left[1] > right[1]
	end)

	local worst = candidates[1][1]
	local binWidth = math.sqrt(2) / (2 ^ bits - 1)
	for i = 1, math.min(CLIMBS, #candidates) do
		local best = candidates[i]
		local scale = binWidth
		for _ = 1, CLIMB_STEPS do
			local x = best[2] + (math.random() - 0.5) * scale
			local y = best[3] + (math.random() - 0.5) * scale
			local z = best[4] + (math.random() - 0.5) * scale
			local w = best[5] + (math.random() - 0.5) * scale
			local candidateError = errorOf(x, y, z, w, bits)
			if candidateError > best[1] then
				local length = math.sqrt(x * x + y * y + z * z + w * w)
				best = { candidateError, x / length, y / length, z / length, w / length }
			else
				scale *= 0.995
			end
		end
		worst = math.max(worst, best[1])
	end

	return worst
end

-- The encoder's result depends only on its first code q0, so the worst error is, over every q0,
-- the farthest rotation whose first code is q0 from the decoding of the result. Each q0's cell is
-- the box of its kept components' codes ± 1/2, where the dropped component stays the largest;
-- the box's corners inside the cell bound the search.
-- Returns the worst error over the corners of q0's cell, against the decoding of the encoder's
-- result for q0, or 0 when q0 does not decode.
local function cellError(bits: number, dropped: number, a: number, b: number, c: number): number
	local maxCode = 2 ^ bits - 1
	local decoded = Leaves.rotationOf(0, dropped, a, b, c, bits, 0, 0, 0)
	if decoded == nil then
		return 0
	end

	local flag, index, fa, fb, fc = Leaves.rotationCodes(decoded, bits)
	local tx, ty, tz, tw = Quant.unrotation(flag :: number, index, fa, fb, fc, bits)
	local codes = { a, b, c }
	local corner = table.create(3, 0)
	local worst = 0
	for mask = 0, 7 do
		local squares = 0
		local largest = 0
		for k = 1, 3 do
			local offset = if bit32.btest(mask, bit32.lshift(1, k - 1)) then 0.5 else -0.5
			local component = (2 * (codes[k] + offset) / maxCode - 1) / math.sqrt(2)
			corner[k] = component
			squares += component * component
			largest = math.max(largest, math.abs(component))
		end

		local droppedComponent = math.sqrt(math.max(0, 1 - squares))
		if squares > 1 or droppedComponent < largest then
			continue
		end

		local q = table.create(4, 0)
		local j = 1
		for k = 0, 3 do
			if k == dropped then
				q[k + 1] = droppedComponent
			else
				q[k + 1] = corner[j]
				j += 1
			end
		end
		worst = math.max(worst, degreesBetween(q[1], q[2], q[3], q[4], tx :: number, ty, tz, tw))
	end

	return worst
end

-- The encoder's result depends only on its first code q0, so the worst error is, over every q0,
-- the farthest rotation whose first code is q0 from the decoding of the result. Each q0's cell is
-- the box of its kept components' codes ± 1/2 where the dropped component stays the largest, and
-- its corners inside the cell bound the search.
local function worstCellError(bits: number, part: number, parts: number): number
	local maxCode = 2 ^ bits - 1
	local worst = 0
	for dropped = 0, 3 do
		for a = part, maxCode, parts do
			for b = 0, maxCode do
				for c = 0, maxCode do
					worst = math.max(worst, cellError(bits, dropped, a, b, c))
				end
			end
		end
	end

	return worst
end

-- The worst errors come from first codes that the encoder moves, where a kept component is about
-- as large as the dropped one; this samples such codes at random.
local function worstTieError(bits: number, samples: number): number
	local maxCode = 2 ^ bits - 1
	local worst = 0
	for _ = 1, samples do
		local codes = { math.random(0, maxCode), math.random(0, maxCode), 0 }
		local squares = 0
		for k = 1, 2 do
			local component = (2 * codes[k] / maxCode - 1) / math.sqrt(2)
			squares += component * component
		end
		if squares > 0.5 then
			continue
		end

		local tie = math.sqrt((1 - squares) / 2) * (if math.random() < 0.5 then -1 else 1)
		local tieCode = math.floor((tie * math.sqrt(2) + 1) / 2 * maxCode + 0.5)
		codes[3] = math.clamp(tieCode + math.random(-2, 2), 0, maxCode)

		local order = math.random(0, 2)
		local a, b, c = codes[1 + order], codes[1 + (order + 1) % 3], codes[1 + (order + 2) % 3]
		worst = math.max(worst, cellError(bits, math.random(0, 3), a, b, c))
	end

	return worst
end

-- Main --------------------------------------------------------------------------------------------

local mode = process.args[1]
if mode == "exhaustive" then
	runExhaustive(
		tonumber(process.args[2]) or 7,
		tonumber(process.args[3]) or 0,
		tonumber(process.args[4]) or 1
	)
elseif mode == "random" then
	runRandom(tonumber(process.args[2]) or 1_000_000, tonumber(process.args[3]) or 1)
elseif mode == "error" then
	math.randomseed(tonumber(process.args[3]) or 1)
	isFirstEncoding = process.args[4] == "first"
	local samples = tonumber(process.args[2]) or 200_000
	for bits = 7, 15 do
		print(string.format("%2d bits: worst %.4f°", bits, worstError(bits, samples)))
	end
elseif mode == "cells" then
	local bits = tonumber(process.args[2]) or 7
	local part = tonumber(process.args[3]) or 0
	local parts = tonumber(process.args[4]) or 1
	print(
		string.format("%2d bits: worst cell corner %.4f°", bits, worstCellError(bits, part, parts))
	)
elseif mode == "ties" then
	math.randomseed(tonumber(process.args[3]) or 1)
	local samples = tonumber(process.args[2]) or 1_000_000
	for bits = 7, 15 do
		print(string.format("%2d bits: worst tie cell %.4f°", bits, worstTieError(bits, samples)))
	end
else
	print(
		"usage: rotation_full.luau exhaustive <bits> [part] [parts] | random <count> [seed] | error [samples] [seed] [first]"
	)
end
