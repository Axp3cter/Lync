--!strict

--[=[
	Build

	Declares the build flags that darklua injects into Lync's source.

	Source reads each flag as a plain global, and darklua replaces every read with the flag's value.

	Only the checker reads this file: it is never required, built or shipped.

	Every darklua configuration injects both flags. A flag that a configuration left out would still
	pass the checker and be nil at runtime.
]=]


-- Constants ---------------------------------------------------------------------------------------

--- True in the test variant, which keeps development checks, and false in every other variant.
declare IS_DEVELOPMENT: boolean


--[=[
	The package version in a run given it, and the configuration's default, such as "0.0.0-test",
	in any other.

	darklua reads it from the environment variable LYNC_VERSION, which keeps the project's name
	because every project in a shell shares its variables.
]=]
declare VERSION: string
