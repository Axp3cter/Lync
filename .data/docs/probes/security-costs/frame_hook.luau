--!strict
-- Claim 12 (R39): an unused per-frame transform hook slot (a nil-checked function field on the frame path) against
-- none (research/landscape.md implication 14 asks that an unused hook cost nothing; the design has no such hook).
-- The frame path here is the end of a flush: finish the frame (write a 4-byte length) and hand it to the
-- transport. Cases per frame:
--   none                 : no hook (what a build emits when no transform is declared; baseline)
--   nil-checked field    : if config.transform then frame = config.transform(frame) end, config a table
--   nil-checked upvalue  : the same through a local upvalue rebound when the hook is set
--   default identity     : a hook slot bound at start to an identity function and always called (the seam style
--                          of v5.md §8)
--   plus, for scale, one HalfSipHash-1-3 tag over a 100 B frame (hsip.tag13u4), the per-frame work around it
-- Run: luau -O2 frame_hook.luau ; luau -O2 --codegen frame_hook.luau
local H = require("./harness")
local S = require("./hsip")

local frame = buffer.create(104)
local sent = 0
local function transport(b: buffer)
	sent += buffer.readu8(b, 0)
end
local config: { transform: ((buffer) -> buffer)? } = { transform = nil }
local transform: ((buffer) -> buffer)? = nil
local function identity(b: buffer): buffer return b end
local seam: (buffer) -> buffer = identity

local N = 3000000
H.compare("end of one flush (per frame)", N, {
	{ name = "none", fn = function(n)
		for i = 1, n do
			buffer.writeu32(frame, 100, i)
			transport(frame)
		end
		return sent
	end },
	{ name = "nil-checked table field", fn = function(n)
		for i = 1, n do
			buffer.writeu32(frame, 100, i)
			local f = frame
			local t = config.transform
			if t then f = t(f) end
			transport(f)
		end
		return sent
	end },
	{ name = "nil-checked upvalue", fn = function(n)
		for i = 1, n do
			buffer.writeu32(frame, 100, i)
			local f = frame
			if transform then f = transform(f) end
			transport(f)
		end
		return sent
	end },
	{ name = "default identity, always called", fn = function(n)
		for i = 1, n do
			buffer.writeu32(frame, 100, i)
			transport(seam(frame))
		end
		return sent
	end },
	{ name = "for scale: tag a 100 B frame", fn = function(n)
		local s = 0
		for i = 1, n do
			buffer.writeu32(frame, 100, i)
			s = bit32.bxor(s, S.tag13u4(1, 2, frame, 100, 16384, i, 0, 0))
			transport(frame)
		end
		return s
	end },
})
print("sink", H.sink)
