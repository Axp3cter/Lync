--!strict

--[=[
	Paths

	Names every repository path that the scripts use, each relative to the repository root.

	A path is written once, here, and every other script reads it by name, so a renamed file or
	folder is one edit.

	The scripts must start in the repository root, which the entry script confirms.

	Paths are text separated by "/", which Windows accepts, so they read the same on every machine.

	This module holds data only: it requires no module and touches no file.
]=]


-- Module ------------------------------------------------------------------------------------------

local Paths = {}


-- Public ------------------------------------------------------------------------------------------

--- The folders at the repository root: the code that is built, then the folders around it.
Paths.FOLDER = table.freeze({
	source      = "src",
	test        = "test",
	bench       = "bench",
	harness     = "harness",

	build       = "build",
	darklua     = ".darklua",
	definitions = "definitions",
	packaging   = "packaging",
	scripts     = "scripts",
	spec        = "spec",
})


--- The folders inside the test folder that the scripts name.
Paths.TEST = table.freeze({
	types = `{Paths.FOLDER.test}/types`,
})


--- The folders under the git-ignored `build` folder: the variants', then packages and reports.
Paths.OUTPUT = table.freeze({
	test     = `{Paths.FOLDER.build}/test`,
	bench    = `{Paths.FOLDER.build}/bench`,
	release  = `{Paths.FOLDER.build}/release`,
	bundle   = `{Paths.FOLDER.build}/bundle`,

	packages = `{Paths.FOLDER.build}/packages`,
	reports  = `{Paths.FOLDER.build}/reports`,
})


--- The darklua configuration of each variant.
Paths.DARKLUA = table.freeze({
	test    = `{Paths.FOLDER.darklua}/test.json5`,
	bench   = `{Paths.FOLDER.darklua}/bench.json5`,
	release = `{Paths.FOLDER.darklua}/release.json5`,
	bundle  = `{Paths.FOLDER.darklua}/bundle.json5`,
})


--- The Rojo project of each variant, then the one the package is published from.
Paths.ROJO = table.freeze({
	test    = "default.project.json",
	bench   = "bench.project.json",
	release = "release.project.json",

	package = `{Paths.FOLDER.packaging}/default.project.json`,
})


--[=[
	The definition files that the type checker loads.

	`roblox` is fetched at setup from the pin that `Paths.PIN.roblox` holds, and Git ignores it.
]=]
Paths.DEFINITIONS = table.freeze({
	build  = `{Paths.FOLDER.definitions}/Build.d.luau`,

	roblox = `{Paths.FOLDER.definitions}/Roblox.d.luau`,
})


--- The pin that setup fetches each downloaded file in the definitions folder from.
Paths.PIN = table.freeze({
	roblox  = `{Paths.FOLDER.definitions}/Roblox.pin.json`,
	apiDump = `{Paths.FOLDER.definitions}/ApiDump.pin.json`,
})


--- The manifest of the pinned tools, then the manifest of the package.
Paths.MANIFEST = table.freeze({
	rokit = "rokit.toml",
	wally = `{Paths.FOLDER.packaging}/wally.toml`,
})


--- The Luau configuration at the repository root.
Paths.LUAURC = ".luaurc"


--[=[
	The files that the scripts name: the one that the bundle variant writes, the library's entry
	module that it starts from, the index of the spec, and the Roblox API dump that generation reads
	for enum item values.

	`apiDump` is fetched at setup from the pin that `Paths.PIN.apiDump` holds, and Git ignores it.
]=]
Paths.FILE = table.freeze({
	bundle     = `{Paths.OUTPUT.bundle}/Lync.luau`,
	entry      = `{Paths.FOLDER.source}/init.luau`,

	specReadme = `{Paths.FOLDER.spec}/README.md`,

	apiDump    = `{Paths.FOLDER.definitions}/ApiDump.json`,
})


return table.freeze(Paths)
