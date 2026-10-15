--!strict

--[=[
	Determinism

	Prints one hash per math operation over a fixed set of inputs, so runs on different platforms can
	be compared line by line: equal hashes mean bit-identical results for every input.

	NaN results are counted separately and hashed as one canonical value, so a line differs only when
	a numeric result differs.
]=]


-- Constants ---------------------------------------------------------------------------------------

const SMALL_STEP = 0.0137
const WIDE_STEP  = 104729.123
const HUGE_BASE  = 1e15
const TINY_STEP  = 1e-300


-- State -------------------------------------------------------------------------------------------

local scratch = buffer.create(8)


-- Private -----------------------------------------------------------------------------------------

local function inputsOf(): { number }
	local values = {}
	for i = -2000, 2000 do
		table.insert(values, i * SMALL_STEP)
	end

	for i = 1, 200 do
		table.insert(values, i * WIDE_STEP)
	end

	for i = 1, 100 do
		table.insert(values, HUGE_BASE + i * 7.77)
	end

	for i = 1, 100 do
		table.insert(values, i * TINY_STEP)
	end

	return values
end


local function mixed(hash: number, value: number): number
	if value ~= value then
		return bit32.bxor(bit32.lrotate(hash, 3), 0x7FF80000)
	end

	buffer.writef64(scratch, 0, value)
	local low  = buffer.readu32(scratch, 0)
	local high = buffer.readu32(scratch, 4)
	hash       = bit32.bxor(bit32.lrotate(hash, 7), low)

	return bit32.bxor(bit32.lrotate(hash, 13), high)
end


local function report(name: string, results: { number }): ()
	local hash     = 0
	local nanCount = 0
	for _, value in results do
		if value ~= value then
			nanCount += 1
		end

		hash = mixed(hash, value)
	end

	print(`{name} {string.format("%08x", hash)} nan={nanCount}`)
end


local function unary(name: string, operation: (number) -> number, inputs: { number }): ()
	local results = table.create(#inputs) :: { number }
	for i, value in inputs do
		results[i] = operation(value)
	end

	report(name, results)
end


local function binary(
	name:      string,
	operation: (number, number) -> number,
	inputs:    { number }
): ()
	local count   = #inputs
	local results = table.create(count) :: { number }
	for i, value in inputs do
		local other = inputs[count - i + 1]
		results[i]  = operation(value, other)
	end

	report(name, results)
end


-- Main --------------------------------------------------------------------------------------------

local inputs = inputsOf()

print(`inputs {#inputs}`)

unary("sin", math.sin, inputs)
unary("cos", math.cos, inputs)
unary("tan", math.tan, inputs)
unary("asin", math.asin, inputs)
unary("acos", math.acos, inputs)
unary("atan", math.atan, inputs)
unary("exp", math.exp, inputs)
unary("log", function(value: number): number
	return math.log(value)
end, inputs)
unary("log10", math.log10, inputs)
unary("sqrt", math.sqrt, inputs)
unary("sinh", math.sinh, inputs)
unary("cosh", math.cosh, inputs)
unary("tanh", math.tanh, inputs)
binary("atan2", math.atan2, inputs)
binary("pow", math.pow, inputs)
binary("fmod", math.fmod, inputs)
binary("noise", function(a: number, b: number): number
	return math.noise(a, b)
end, inputs)
binary("divide", function(a: number, b: number): number
	return a / b
end, inputs)
binary("multiplyAdd", function(a: number, b: number): number
	return a * b + 0.1
end, inputs)
