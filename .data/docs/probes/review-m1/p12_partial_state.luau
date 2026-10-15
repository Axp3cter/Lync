--!nocheck
-- m1-plan §2.1: the public encoders "reset the writer to its state at entry ... so a refused value
-- never leaves partial bits behind". Two gaps: (1) a raise that is not a refusal (a t.convert or
-- t.custom encode function that errors, or the rotation encoder's `internal`) leaves the bits it
-- wrote; (2) the chunk's instance list is never rolled back, so a refused message's instances stay
-- listed and the chunk later fails rule 9 at the receiver. Run: lune run p12_partial_state.luau
local P = require("./prelude")
local Bits, Run, Rows = P.Bits, P.Run, P.Rows
local t = P.Lync.types

-- (1) A convert whose encode raises, after a field that has already been written.
local codec = P.plan(P.Lync, {
	a = t.int(0, 255),
	b = t.convert(t.int(0, 9), function(v) return v end, function(v)
		if v == "boom" then error("game code error") end
		return v
	end),
})
local w = Bits.writer()
local ok, err = pcall(Rows.encodeValue, w, codec, { a = 7, b = "boom" }, { list = {}, index = {} }, "p.e:fire")
print(string.format("(1) encode raised (%s); writer bit after the raise: %d (was 0)", tostring(not ok), w.bit))

-- (2) One chunk, two messages; the first is refused after listing an instance.
local rowCodec = P.plan(P.Lync, { a = t.instance(), z = t.int(0, 3) })
local p, q = Instance.new("Part"), Instance.new("Model")
local instances = { list = {}, index = {} }
local cw = Bits.writer()
local first = { a = p, z = 9 } -- refused: slot out of range
Run.collect(rowCodec, { first }, 1, instances)
print("(2) after collecting the refused message, list =", #instances.list)
local refused = not pcall(Run.encode, cw, rowCodec, { first }, 1, instances, "p.e:fire")
local second = { a = q, z = 1 }
Run.collect(rowCodec, { second }, 1, instances)
Run.encode(cw, rowCodec, { second }, 1, instances, "p.e:fire")
local out = {}
local reader = Bits.reader(Bits.finish(cw))
local rule = Run.decode(reader, rowCodec, 1, instances.list, out)
print(string.format("    first refused: %s; chunk list now %d entries; receiver's rule for the honest second message: %d", tostring(refused), #instances.list, rule))
