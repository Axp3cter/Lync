--!strict

--[=[
	mutation.spec

	Hostile frames (v5.md §4.8): a frame breaking each rule a frame's bytes can break, rules 2 to
	10, decodes to that rule through `Frame`, `Header`, `Toc`, `Control` and the codec, both
	ways; and seeded random frames, and random mutations of honest ones, decode to a rule and
	never raise. Rule 1 is about the remote call, not its buffer, and belongs to the inbound
	pipeline.

	The fuzz reader's element budget is the server default, 65,536, in both directions: a client's
	is unlimited, and a zero-bit control row with a count near 2^53 would run that long.
]=]

-- Imports -----------------------------------------------------------------------------------------

local process = require("@lune/process")

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Control = require("../../src/transport/control")
local Frame = require("../../src/transport/frame")
local FrameSupport = require("../support/frame")
local Frames = require("./frames")
local Header = require("../../src/transport/header")
local Ints = require("../../src/wire/ints")
local Ir = require("../../src/plan/ir")
local Prop = require("../support/prop")
local Quant = require("../../src/wire/quant")
local Tag = require("../../src/transport/tag")
local Toc = require("../../src/transport/toc")

-- Types -------------------------------------------------------------------------------------------

type Options = { instances: { Instance? }?, budget: number?, firstWelcome: boolean? }

type Direction = { down: boolean, lane: number }

-- Constants ---------------------------------------------------------------------------------------

const ARENA = 1
const PROBE = 2
const CONTROL = 0
const STATE_LIST = 1
const RUN_LIST = 2
const ROWS_LIST = 4
const LANE_RELIABLE = 0
const LANE_UNRELIABLE = 1
const MODE_UNCHANGED = 0

const FUZZ_BUDGET = 65_536
const RUNS = 300
const FULL_RUNS = 20_000

const DIRECTIONS: { Direction } = {
	{ down = true, lane = LANE_RELIABLE },
	{ down = true, lane = LANE_UNRELIABLE },
	{ down = false, lane = LANE_RELIABLE },
	{ down = false, lane = LANE_UNRELIABLE },
}

-- Private -----------------------------------------------------------------------------------------

local function runs(): number
	return if process.env.LYNC_FULL == "1" then FULL_RUNS else RUNS
end

local function namespaces(): { [number]: Ir.Namespace }
	return { [ARENA] = FrameSupport.arena(), [PROBE] = Frames.probe() }
end

local function ruleOf(frame: buffer, down: boolean, lane: number, options: Options?): number
	local given: Options = options or {}
	local rule = Frames.decode(frame, {
		down = down,
		lane = lane,
		namespaces = namespaces(),
		instances = given.instances or {},
		budget = given.budget or math.huge,
		firstWelcome = given.firstWelcome == true,
	})

	return rule
end

local function chunkOf(
	ns: number,
	list: number,
	build: (w: Bits.Writer) -> (),
	instances: { Instance }?
): Frame.Chunk
	local w = Bits.writer()
	build(w)

	return Frame.chunk(ns, list, w, instances or {})
end

-- An upstream frame of the chunks, with a zero tag: the decoder checks no tag.
local function upFrame(lane: number, chunks: { Frame.Chunk }): buffer
	local body = Frame.up(lane, if lane == LANE_UNRELIABLE then 0 else nil, nil, chunks)

	return Tag.append(body, 0)
end

local function downFrame(kind: Frame.Kind, chunks: { Frame.Chunk }): buffer
	return (Frame.down(kind, MODE_UNCHANGED, 0, nil, chunks, 1, #chunks))
end

-- A frame whose bits after the header are written by `build`, untouched by `Frame`.
local function rawFrame(down: boolean, lane: number, build: (w: Bits.Writer) -> ()): buffer
	local w = Bits.writer()
	if down and lane == LANE_RELIABLE then
		Header.writeDownReliable(w, MODE_UNCHANGED, 0)
	elseif down then
		Header.writeDownUnreliable(w, nil, 0)
	else
		Header.writeUp(w, lane, if lane == LANE_UNRELIABLE then 0 else nil, nil)
	end
	build(w)
	Bits.align(w)
	local bytes = Bits.finish(w)

	return if down then bytes else Tag.append(bytes, 0)
end

local function runHeader(
	w: Bits.Writer,
	id: number,
	width: number,
	count: number,
	instanceCount: number?
)
	FrameSupport.writeRunHeader(w, id, width, count, instanceCount)
end

local function chat(w: Bits.Writer, text: string)
	runHeader(w, 1, 2, 1)
	Bits.write(w, 8, #text)
	Bits.writeTail(w, text)
end

local function strike(w: Bits.Writer, xCode: number, yCode: number)
	runHeader(w, 2, 2, 1)
	Bits.write(w, 11, xCode)
	Bits.write(w, 11, yCode)
	Bits.write(w, 40, 4)
end

local function announceRound(w: Bits.Writer, numberCode: number)
	runHeader(w, 0, 1, 1)
	Bits.write(w, 1, 0)
	Bits.write(w, 7, numberCode)
end

-- `probe.point`: a single row of instance indices, after a chunk instance count.
local function point(w: Bits.Writer, instanceCount: number, indices: { number })
	runHeader(w, 0, 2, 1, instanceCount)
	Bits.write(w, 3, #indices)
	for _, index in indices do
		Bits.write(w, Ints.width(instanceCount), index)
	end
end

local function withBit(frame: buffer, bit: number): buffer
	local changed = buffer.create(buffer.len(frame))
	buffer.copy(changed, 0, frame)
	local byte = bit // 8
	buffer.writeu8(
		changed,
		byte,
		bit32.bxor(buffer.readu8(changed, byte), bit32.lshift(1, bit % 8))
	)

	return changed
end

local function resized(frame: buffer, length: number): buffer
	local changed = buffer.create(length)
	buffer.copy(changed, 0, frame, 0, math.min(length, buffer.len(frame)))

	return changed
end

local function randomBytes(length: number): buffer
	local bytes = buffer.create(length)
	for i = 0, length - 1 do
		buffer.writeu8(bytes, i, math.random(0, 255))
	end

	return bytes
end

-- An honest frame for the direction, and its instance array.
local function honestFrame(direction: Direction, size: number): (buffer, { Instance? })
	local chunks = Frames.chunks(direction.down, direction.lane, namespaces(), size)
	if direction.down then
		local kind = if direction.lane == LANE_RELIABLE then "reliable" else "event"
		local frame, instances =
			Frame.down(kind, math.random(0, 2), math.random(0, 2 ^ 20), nil, chunks, 1, #chunks)
		return frame, instances :: any
	end

	local body, instances = Frame.up(direction.lane, math.random(0, 4095), nil, chunks)
	return Tag.append(body, math.random(0, 0xffff)), instances :: any
end

local function mutated(frame: buffer): buffer
	local length = buffer.len(frame)
	local roll = math.random(1, 5)
	if roll == 1 and length > 0 then
		local changed = frame
		for _ = 1, math.random(1, 3) do
			changed = withBit(changed, math.random(0, 8 * length - 1))
		end
		return changed
	elseif roll == 2 then
		return resized(frame, math.random(0, length))
	elseif roll == 3 then
		local appended = resized(frame, length + math.random(1, 8))
		for i = length, buffer.len(appended) - 1 do
			buffer.writeu8(appended, i, math.random(0, 255))
		end
		return appended
	elseif roll == 4 and length > 0 then
		local changed = resized(frame, length)
		buffer.writeu8(changed, math.random(0, length - 1), math.random(0, 255))
		return changed
	end

	local at = math.random(0, length)
	local spliced = buffer.create(length + 1)
	buffer.copy(spliced, 0, frame, 0, at)
	buffer.writeu8(spliced, at, math.random(0, 255))
	buffer.copy(spliced, at + 1, frame, at, length - at)

	return spliced
end

-- Decodes in a protected call: the decoder must return a rule, never raise.
local function expectRule(
	frame: buffer,
	direction: Direction,
	instances: { Instance? },
	firstWelcome: boolean
)
	local options: Options = {
		instances = instances,
		budget = FUZZ_BUDGET,
		firstWelcome = firstWelcome,
	}
	local ok, rule = pcall(ruleOf, frame, direction.down, direction.lane, options)
	Check.expect(ok, `the decoder raised: {rule}`)
	Check.expect(rule == 0 or (rule >= 2 and rule <= 10), `rule {rule}`)
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["honest frames decode with rule 0"] = function()
		local part = Instance.new("Part")
		Check.expectEqual(
			ruleOf(
				upFrame(
					LANE_RELIABLE,
					{ chunkOf(ARENA, RUN_LIST, function(w)
						chat(w, "gg")
					end) }
				),
				false,
				LANE_RELIABLE
			),
			0,
			"chat"
		)
		Check.expectEqual(
			ruleOf(
				upFrame(
					LANE_UNRELIABLE,
					{ chunkOf(ARENA, RUN_LIST, function(w)
						strike(w, 1024, 1024)
					end) }
				),
				false,
				LANE_UNRELIABLE
			),
			0,
			"strike"
		)
		Check.expectEqual(
			ruleOf(
				downFrame(
					"reliable",
					{ chunkOf(ARENA, RUN_LIST, function(w)
						announceRound(w, 98)
					end) }
				),
				true,
				LANE_RELIABLE
			),
			0,
			"announce 99"
		)
		Check.expectEqual(
			ruleOf(
				upFrame(LANE_RELIABLE, {
					chunkOf(PROBE, RUN_LIST, function(w)
						point(w, 1, { 0 })
					end, { part }),
				}),
				false,
				LANE_RELIABLE,
				{ instances = { part } }
			),
			0,
			"point"
		)
	end,

	["rule 2: a count, length or code past its maximum"] = function()
		local longName = upFrame(LANE_RELIABLE, {
			chunkOf(CONTROL, RUN_LIST, function(w)
				Bits.write(w, 3, Control.HELLO)
				Ints.writeEg(w, 0, 0)
				Bits.write(w, 104, 0)
				Bits.write(w, 7, 65)
				Bits.writeTail(w, string.rep("n", 65))
			end),
		})
		Check.expectEqual(ruleOf(longName, false, LANE_RELIABLE), 2, "a 65-byte namespace name")

		local outcome = downFrame("reliable", {
			chunkOf(ARENA, RUN_LIST, function(w)
				runHeader(w, 1, 1, 1)
				FrameSupport.writeAnswerPrefix(w, 0, 0, 3)
			end),
		})
		Check.expectEqual(ruleOf(outcome, true, LANE_RELIABLE), 2, "answer outcome 3")

		local wideNs = rawFrame(false, LANE_RELIABLE, function(w)
			Ints.writeEg(w, 1, 0)
			Bits.write(w, 54, 0)
			Bits.write(w, 1, 1)
			Bits.write(w, 60, 0)
		end)
		Check.expectEqual(ruleOf(wideNs, false, LANE_RELIABLE), 2, "an EG code with z = 54")
	end,

	["rule 3: a value outside its declared range"] = function()
		local round = downFrame(
			"reliable",
			{ chunkOf(ARENA, RUN_LIST, function(w)
				announceRound(w, 99)
			end) }
		)
		Check.expectEqual(ruleOf(round, true, LANE_RELIABLE), 3, "round 100")

		local welcome = downFrame("reliable", {
			chunkOf(CONTROL, RUN_LIST, function(w)
				Control.write(w, Control.WELCOME, {
					{
						index = 1,
						first = {
							epoch = 0,
							stateRate = 5,
							keyLow = 0,
							keyHigh = 0,
							cover = 0,
							permutationSeed = 0,
							probeOneIn = 0,
							probeMaxPerSecond = 0,
							beacon = 0,
						},
					},
				})
			end),
		})
		Check.expectEqual(
			ruleOf(welcome, true, LANE_RELIABLE, { firstWelcome = true }),
			3,
			"stateRate 5"
		)

		local reading = upFrame(LANE_RELIABLE, {
			chunkOf(PROBE, RUN_LIST, function(w)
				runHeader(w, 1, 2, 1)
				Bits.write(w, 32, 0)
				Bits.write(w, 32, 0x7ff8_0000)
			end),
		})
		Check.expectEqual(ruleOf(reading, false, LANE_RELIABLE), 3, "a NaN reading")
	end,

	["rule 4: non-zero padding, or bits and tail that don't meet"] = function()
		local chunk = chunkOf(ARENA, RUN_LIST, function(w)
			announceRound(w, 2)
		end)
		local down = downFrame("reliable", { chunk })
		Check.expectEqual(ruleOf(down, true, LANE_RELIABLE), 0, "honest")
		-- The header and toc take 10 bits, and the chunk 10 bits from byte 2.
		Check.expectEqual(buffer.len(down), 4, "length")
		Check.expectEqual(
			ruleOf(withBit(down, 15), true, LANE_RELIABLE),
			4,
			"padding before a chunk"
		)
		Check.expectEqual(ruleOf(withBit(down, 31), true, LANE_RELIABLE), 4, "final padding")
		Check.expectEqual(ruleOf(resized(down, 3), true, LANE_RELIABLE), 4, "cut short")
		Check.expectEqual(ruleOf(resized(down, 5), true, LANE_RELIABLE), 4, "a byte appended")

		local up = upFrame(
			LANE_RELIABLE,
			{ chunkOf(ARENA, RUN_LIST, function(w)
				chat(w, "gg")
			end) }
		)
		local bodyBytes = buffer.len(up) - 2
		Check.expectEqual(
			ruleOf(withBit(up, 8 * (bodyBytes - 2) - 1), false, LANE_RELIABLE),
			4,
			"up padding"
		)
		Check.expectEqual(
			ruleOf(resized(up, buffer.len(up) - 1), false, LANE_RELIABLE),
			4,
			"up cut short"
		)
		Check.expectEqual(
			ruleOf(resized(up, buffer.len(up) + 1), false, LANE_RELIABLE),
			4,
			"up, a byte appended"
		)
	end,

	["rule 5: map keys not strictly ascending"] = function()
		local function tally(keys: { string }): buffer
			return upFrame(LANE_RELIABLE, {
				chunkOf(PROBE, RUN_LIST, function(w)
					runHeader(w, 2, 2, 1)
					Bits.write(w, 4, #keys)
					for i, key in keys do
						Bits.write(w, 4, #key)
						Bits.writeTail(w, key)
						Bits.write(w, 7, i)
					end
				end),
			})
		end

		Check.expectEqual(ruleOf(tally({ "a", "b" }), false, LANE_RELIABLE), 0, "ascending")
		Check.expectEqual(ruleOf(tally({ "b", "a" }), false, LANE_RELIABLE), 5, "descending")
		Check.expectEqual(ruleOf(tally({ "a", "a" }), false, LANE_RELIABLE), 5, "repeated")
	end,

	["rule 6: a non-canonical toc or direction"] = function()
		local adjacent = rawFrame(false, LANE_RELIABLE, function(w)
			Toc.write(w, { { { ns = ARENA, count = 1 }, { ns = ARENA, count = 1 } } })
			chat(w, "a")
			chat(w, "b")
		end)
		Check.expectEqual(
			ruleOf(adjacent, false, LANE_RELIABLE),
			6,
			"adjacent segments of one namespace"
		)

		local descending = rawFrame(true, LANE_RELIABLE, function(w)
			Toc.write(w, { { { ns = 2, count = 1 }, { ns = 1, count = 1 } }, {}, {} })
		end)
		Check.expectEqual(ruleOf(descending, true, LANE_RELIABLE), 6, "state segments descending")

		local xCode, yCode = 0, 0
		while Quant.directionIsCanonical(xCode, yCode, 11) do
			xCode += 1
		end
		local aim = upFrame(
			LANE_UNRELIABLE,
			{ chunkOf(ARENA, RUN_LIST, function(w)
				strike(w, xCode, yCode)
			end) }
		)
		Check.expectEqual(ruleOf(aim, false, LANE_UNRELIABLE), 6, `aim codes {xCode}, {yCode}`)
	end,

	["rule 7: an id, lane, namespace, control type or list the receiver doesn't allow"] = function()
		local function upRule(lane: number, ns: number, build: (w: Bits.Writer) -> ()): number
			return ruleOf(upFrame(lane, { chunkOf(ns, RUN_LIST, build) }), false, lane)
		end

		Check.expectEqual(
			upRule(LANE_RELIABLE, ARENA, function(w)
				runHeader(w, 3, 2, 1)
			end),
			7,
			"id 3 of 3 up ids"
		)
		Check.expectEqual(
			upRule(LANE_RELIABLE, ARENA, function(w)
				strike(w, 1024, 1024)
			end),
			7,
			"an unreliable event in a reliable frame"
		)
		Check.expectEqual(
			upRule(LANE_UNRELIABLE, ARENA, function(w)
				chat(w, "gg")
			end),
			7,
			"a reliable event in an unreliable frame"
		)
		Check.expectEqual(
			upRule(LANE_UNRELIABLE, ARENA, function(w)
				runHeader(w, 0, 2, 1)
				Bits.write(w, 5, 0)
				Bits.write(w, 1, 0)
			end),
			7,
			"an ask in an unreliable frame"
		)
		Check.expectEqual(
			upRule(LANE_UNRELIABLE, CONTROL, function(w)
				Control.write(w, Control.REKEY_ACK, { true })
			end),
			7,
			"a control chunk in an unreliable frame"
		)
		Check.expectEqual(
			upRule(LANE_RELIABLE, 3, function(w)
				chat(w, "gg")
			end),
			7,
			"a namespace never welcomed"
		)
		Check.expectEqual(
			upRule(LANE_RELIABLE, CONTROL, function(w)
				Control.write(w, Control.WELCOME, { { index = 1 } })
			end),
			7,
			"WELCOME upstream"
		)

		local hello = downFrame("reliable", {
			chunkOf(CONTROL, RUN_LIST, function(w)
				Control.write(w, Control.HELLO, {
					{ version = 1, seed = 0, hashLow = 0, hashHigh = 0, name = "arena" },
				})
			end),
		})
		Check.expectEqual(ruleOf(hello, true, LANE_RELIABLE), 7, "HELLO downstream")

		local state = downFrame(
			"reliable",
			{ chunkOf(ARENA, STATE_LIST, function(w)
				Bits.write(w, 8, 0)
			end) }
		)
		Check.expectEqual(ruleOf(state, true, LANE_RELIABLE), 7, "a state chunk in milestone 2")

		local rows = Frame.down(
			"state",
			MODE_UNCHANGED,
			0,
			1,
			{ chunkOf(ARENA, ROWS_LIST, function(w)
				Bits.write(w, 8, 0)
			end) },
			1,
			1
		)
		Check.expectEqual(ruleOf(rows, true, LANE_UNRELIABLE), 7, "a state frame in milestone 2")
	end,

	["rule 8: a frame over its size"] = function()
		Check.expectEqual(ruleOf(buffer.create(16_385), false, LANE_RELIABLE), 8, "up reliable")
		Check.expectEqual(ruleOf(buffer.create(1001), false, LANE_UNRELIABLE), 8, "up unreliable")
		Check.expectEqual(ruleOf(buffer.create(1001), true, LANE_UNRELIABLE), 8, "down unreliable")
	end,

	["rule 9: instance lists with a repeated, unreferenced or out-of-order entry"] = function()
		local p, q = Instance.new("Part"), Instance.new("Part")
		local function pointRule(
			instanceCount: number,
			indices: { number },
			instances: { Instance? }
		): number
			local frame = upFrame(LANE_RELIABLE, {
				chunkOf(PROBE, RUN_LIST, function(w)
					point(w, instanceCount, indices)
				end),
			})
			return ruleOf(frame, false, LANE_RELIABLE, { instances = instances })
		end

		Check.expectEqual(pointRule(2, { 0, 1 }, { p, q }), 0, "in order")
		Check.expectEqual(pointRule(2, { 0, 1 }, { p, nil }), 0, "an unreplicated entry")
		Check.expectEqual(pointRule(2, { 0, 1 }, { p, p }), 9, "repeated")
		Check.expectEqual(pointRule(2, { 0, 0 }, { p, q }), 9, "unreferenced")
		Check.expectEqual(pointRule(2, { 1, 0 }, { p, q }), 9, "out of order")
		Check.expectEqual(pointRule(1, { 0 }, { p, q }), 9, "an entry past every chunk")
	end,

	["rule 10: counts past the element budget"] = function()
		local frame = upFrame(LANE_RELIABLE, {
			chunkOf(ARENA, RUN_LIST, function(w)
				runHeader(w, 1, 2, 2)
				Bits.write(w, 8, 0)
				Bits.write(w, 8, 0)
			end),
		})
		Check.expectEqual(ruleOf(frame, false, LANE_RELIABLE, { budget = 2 }), 0, "budget 2")
		Check.expectEqual(ruleOf(frame, false, LANE_RELIABLE, { budget = 1 }), 10, "budget 1")

		local mismatches = downFrame("reliable", {
			chunkOf(CONTROL, RUN_LIST, function(w)
				Bits.write(w, 3, Control.MISMATCH)
				Ints.writeEg(w, 2 ^ 40, 0)
			end),
		})
		Check.expectEqual(
			ruleOf(mismatches, true, LANE_RELIABLE, { budget = FUZZ_BUDGET }),
			10,
			"2^40 MISMATCHes"
		)
	end,

	["random frames decode to a rule and never raise"] = function()
		Prop.check("random frames", function(size: number)
			return {
				direction = DIRECTIONS[math.random(1, #DIRECTIONS)],
				frame = randomBytes(math.random(0, 12 * size)),
				firstWelcome = math.random() < 0.5,
			}
		end, function(case: { direction: Direction, frame: buffer, firstWelcome: boolean })
			expectRule(case.frame, case.direction, {}, case.firstWelcome)
		end, { runs = runs() })
	end,

	["mutated honest frames decode to a rule and never raise"] = function()
		Prop.check("mutated frames", function(size: number)
			local direction = DIRECTIONS[math.random(1, #DIRECTIONS)]
			local frame, instances = honestFrame(direction, size)
			return {
				direction = direction,
				frame = frame,
				instances = instances,
				mutation = mutated(frame),
			}
		end, function(case: {
			direction: Direction,
			frame: buffer,
			instances: { Instance? },
			mutation: buffer,
		})
			Check.expectEqual(
				ruleOf(case.frame, case.direction.down, case.direction.lane, {
					instances = case.instances,
				}),
				0,
				"the honest frame"
			)
			expectRule(case.mutation, case.direction, case.instances, math.random() < 0.5)
		end, { runs = runs() })
	end,
}
