--!strict

--[=[
	run

	Lune script that runs every `*.spec.luau` under `test/`, from the repo root:
	`lune run test/run.luau [filter]`.

	A spec file returns a table of named test functions; each runs in its own `pcall`. With a
	filter, only tests whose "path name" (the spec's path under `test/`, a space, the test's name)
	contains the filter as plain text run.

	Two environment variables steer the specs:
	- `LYNC_SEED=<n>` replays property tests from a reported seed (`support/prop.luau`).
	- `LYNC_FULL=1` runs the long random checks at full counts, such as 10^6 random directions per
	  width in `wire/quant.spec.luau`; by default they run 10^4 per width.

	Lune exposes Roblox datatypes only through `@lune/roblox`, so they are copied into the global
	environment before any spec is required, which makes them globals for every module required
	afterwards (m1-plan.md §1). This is the only file that uses `getfenv`.
]=]

-- Imports -----------------------------------------------------------------------------------------

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

-- Types -------------------------------------------------------------------------------------------

type Spec = { [string]: () -> () }

-- Constants ---------------------------------------------------------------------------------------

const TEST_ROOT = "test"

-- Private -----------------------------------------------------------------------------------------

local function injectRobloxGlobals()
	local environment = getfenv(0)
	environment.Vector3 = roblox.Vector3
	environment.CFrame = roblox.CFrame
	environment.Color3 = roblox.Color3
	environment.Instance = roblox.Instance
	environment.Enum = roblox.Enum
end

local function collectSpecs(directory: string, into: { string })
	local names = fs.readDir(directory)
	table.sort(names)
	for _, name in names do
		local path = `{directory}/{name}`
		if fs.isDir(path) then
			collectSpecs(path, into)
			continue
		end

		if string.sub(name, -#".spec.luau") == ".spec.luau" then
			table.insert(into, path)
		end
	end
end

local function namesOf(spec: Spec): { string }
	local names = {}
	for name in spec do
		table.insert(names, name)
	end
	table.sort(names)

	return names
end

-- Main --------------------------------------------------------------------------------------------

injectRobloxGlobals()

local filter = process.args[1] or ""
local paths = {}
collectSpecs(TEST_ROOT, paths)

local passedCount = 0
local failures = {}
for _, path in paths do
	local relativePath = string.sub(path, #TEST_ROOT + 2)
	local modulePath = `./{string.sub(relativePath, 1, -#".luau" - 1)}`
	local loaded, spec = pcall(function(): Spec
		return require(modulePath) :: any
	end)
	if not loaded then
		table.insert(failures, `FAIL {relativePath} (loading)\n    {tostring(spec)}`)
		continue
	end

	for _, name in namesOf(spec) do
		local fullName = `{relativePath} {name}`
		if string.find(fullName, filter, 1, true) == nil then
			continue
		end

		local ok, result = pcall(spec[name])
		if ok then
			passedCount += 1
		else
			table.insert(failures, `FAIL {fullName}\n    {tostring(result)}`)
		end
	end
end

for _, failure in failures do
	print(failure)
end
print(`{passedCount} passed, {#failures} failed`)

if #failures > 0 then
	process.exit(1)
end
