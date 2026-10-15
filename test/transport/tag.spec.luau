--!strict

--[=[
	tag.spec

	The upstream tag (v5.md §4.5): its hash input is the documented layout, it verifies at the
	frame's count and fails at any other, and it changes with any covered byte, the length, the
	lane or the instance count, but not with bytes past `tag.cover`.

	A 16-bit tag collides with probability 2^-16 per comparison, so the properties that expect a
	mismatch run at fixed seeds whose cases have none; every other property runs at random seeds.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local HalfSipHash = require("../../src/wire/halfsiphash")
local Prop = require("../support/prop")
local Tag = require("../../src/transport/tag")

-- Types -------------------------------------------------------------------------------------------

type Case = {
	key: buffer,
	count: number,
	lane: number,
	frame: buffer,
	instanceCount: number,
	cover: number,
}

-- Constants ---------------------------------------------------------------------------------------

const MISMATCH_SEED = 20_261_015

-- Private -----------------------------------------------------------------------------------------

-- A random integer in [0, max], for ranges past `math.random`'s 32 bits.
local function integerUpTo(max: number): number
	return math.floor(math.random() * (max + 1))
end

local function randomBytes(length: number): buffer
	local bytes = buffer.create(length)
	for i = 0, length - 1 do
		buffer.writeu8(bytes, i, math.random(0, 255))
	end

	return bytes
end

local function randomCase(size: number): Case
	return {
		key = randomBytes(8),
		count = integerUpTo(2 ^ 34),
		lane = math.random(0, 1),
		frame = randomBytes(math.random(1, 20 * size)),
		instanceCount = math.random(0, 70_000),
		cover = if math.random() < 0.2 then 0 else math.random(1, 2048),
	}
end

local function tagOf(case: Case): number
	local frame = case.frame
	return Tag.compute(
		case.key,
		case.count,
		case.lane,
		frame,
		buffer.len(frame),
		case.instanceCount,
		case.cover
	)
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["the hash input is count u32le, lane u8, length u32le, instances u16le, covered bytes"] = function()
		Prop.check("tag layout", randomCase, function(case: Case)
			local frame = case.frame
			local length = buffer.len(frame)
			local covered = buffer.readstring(frame, 0, math.min(case.cover, length))
			local prefix = string.pack(
				"<I4BI4I2",
				case.count % 2 ^ 32,
				case.lane,
				length,
				case.instanceCount % 2 ^ 16
			)
			local message = buffer.fromstring(prefix .. covered)
			local low = HalfSipHash.hash(case.key, message, 0, buffer.len(message), 1, 3, 4)
			Check.expectEqual(tagOf(case), low % 0x1_0000, "tag")
		end)
	end,

	["the tag is appended little-endian and read back"] = function()
		Prop.check("tag append", randomCase, function(case: Case)
			local tag = tagOf(case)
			local tagged = Tag.append(case.frame, tag)
			local length = buffer.len(case.frame)
			Check.expectEqual(buffer.len(tagged), length + 2, "length")
			Check.expectEqual(
				buffer.readstring(tagged, 0, length),
				buffer.tostring(case.frame),
				"frame"
			)
			Check.expectEqual(buffer.readu8(tagged, length), tag % 256, "low byte")
			Check.expectEqual(Tag.read(tagged), tag, "read")
		end)
	end,

	["the tag verifies at count e and fails at e - 1 and e + 1 to e + 4"] = function()
		Prop.check("tag counts", randomCase, function(case: Case)
			local tag = tagOf(case)
			for _, offset in { -1, 1, 2, 3, 4 } do
				local other = table.clone(case)
				other.count += offset
				Check.expect(tagOf(other) ~= tag, `count e + {offset}`)
			end
		end, { seed = MISMATCH_SEED })
	end,

	["any changed covered byte, length, lane or instance count changes the tag"] = function()
		Prop.check("tag coverage", randomCase, function(case: Case)
			local tag = tagOf(case)
			local length = buffer.len(case.frame)
			local covered = math.min(case.cover, length)
			if covered > 0 then
				local flipped = table.clone(case)
				flipped.frame = buffer.create(length)
				buffer.copy(flipped.frame, 0, case.frame)
				local at = math.random(0, covered - 1)
				buffer.writeu8(
					flipped.frame,
					at,
					bit32.bxor(buffer.readu8(case.frame, at), bit32.lshift(1, math.random(0, 7)))
				)
				Check.expect(tagOf(flipped) ~= tag, `byte {at}`)
			end

			local longer = table.clone(case)
			longer.frame = buffer.create(length + 1)
			buffer.copy(longer.frame, 0, case.frame)
			Check.expect(tagOf(longer) ~= tag, "length")

			local otherLane = table.clone(case)
			otherLane.lane = 1 - case.lane
			Check.expect(tagOf(otherLane) ~= tag, "lane")

			local moreInstances = table.clone(case)
			moreInstances.instanceCount += 1
			Check.expect(tagOf(moreInstances) ~= tag, "instance count")
		end, { seed = MISMATCH_SEED })
	end,

	["bytes past tag.cover don't change the tag"] = function()
		Prop.check("tag cover", randomCase, function(case: Case)
			local length = buffer.len(case.frame)
			if case.cover >= length then
				return
			end

			local changed = buffer.create(length)
			buffer.copy(changed, 0, case.frame)
			local at = math.random(case.cover, length - 1)
			buffer.writeu8(changed, at, bit32.bxor(buffer.readu8(changed, at), 0xff))
			local other = table.clone(case)
			other.frame = changed
			Check.expectEqual(tagOf(other), tagOf(case), `byte {at}`)
		end)
	end,

	["the count is taken mod 2^32 and the instance count mod 2^16"] = function()
		Prop.check("tag wrap", randomCase, function(case: Case)
			local wrapped = table.clone(case)
			wrapped.count += 2 ^ 32
			wrapped.instanceCount += 2 ^ 16
			Check.expectEqual(tagOf(wrapped), tagOf(case), "tag")
		end)
	end,

	["only the first length bytes of the buffer are read"] = function()
		local key = randomBytes(8)
		local frame = randomBytes(40)
		local prefix = buffer.create(30)
		buffer.copy(prefix, 0, frame, 0, 30)
		Check.expectEqual(
			Tag.compute(key, 7, 1, frame, 30, 0, 1024),
			Tag.compute(key, 7, 1, prefix, 30, 0, 1024),
			"tag"
		)
	end,
}
