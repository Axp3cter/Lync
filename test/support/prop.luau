--!strict

--[=[
	Prop

	Property tests. Run i reseeds `math.random` with the base seed + i - 1, so a failure replays
	with `LYNC_SEED=<seed> lune run test/run.luau <filter>`; it is shrunk by regenerating it at
	halved sizes down to 1.
]=]

-- Imports -----------------------------------------------------------------------------------------

local process = require("@lune/process")

-- Module ------------------------------------------------------------------------------------------

local Prop = {}

-- Private -----------------------------------------------------------------------------------------

local function describe(value: any): string
	if typeof(value) ~= "table" then
		return tostring(value)
	end

	local parts = {}
	for _, element in value do
		table.insert(parts, describe(element))
	end

	return `\{{table.concat(parts, ", ")}}`
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Runs `test` on generated values at sizes growing from 1 to 100, and fails with the smallest
	failing value it finds.

	@param name     the property, named in the failure
	@param generate makes a value of the given size with `math.random`
	@param test     raises when the property fails for its value
	@param options  `runs` (200 when nil) and `seed` (`LYNC_SEED`, else the time, when nil)
	@error when a run fails, with the base seed, the run, and the smallest failing size and value
]=]
function Prop.check(
	name: string,
	generate: (size: number) -> any,
	test: (value: any) -> (),
	options: { runs: number?, seed: number? }?
)
	local runs = if options ~= nil and options.runs ~= nil then options.runs else 200
	local givenSeed = if options ~= nil then options.seed else nil
	local baseSeed = givenSeed or tonumber(process.env.LYNC_SEED) or os.time()

	for run = 1, runs do
		local failure = nil
		local size = 1 + (run - 1) * 99 // math.max(runs - 1, 1)
		while size >= 1 do
			math.randomseed(baseSeed + run - 1)
			local value = generate(size)
			local ok, message = pcall(test, value)
			if ok and failure == nil then
				break
			end

			if not ok then
				failure = `size {size}) failed on {describe(value)}: {message}`
			end
			size //= 2
		end

		if failure ~= nil then
			error(`{name}: LYNC_SEED={baseSeed} (run {run}, {failure}`, 2)
		end
	end
end

return table.freeze(Prop)
