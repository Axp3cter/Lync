--!strict

--[=[
	Endpoints

	Names where the receiver listens and what it answers, so that the harness that runs in Studio
	and the scripts that run the receiver agree on them.

	Every value equals the one in `scripts/project/Endpoints.luau`, which the scripts read. The two
	files are separate because a place built for Studio holds the harness and nothing of the
	scripts.

	This module holds data only: it requires no module and touches no engine service.
]=]


-- Module ------------------------------------------------------------------------------------------

local Endpoints = {}


-- Public ------------------------------------------------------------------------------------------

--- The address that the receiver listens on.
Endpoints.ADDRESS = table.freeze({
	host = "127.0.0.1",
	port = 34874,
})


--- The path of each request that the receiver answers.
Endpoints.ROUTE = table.freeze({
	ping    = "/ping",
	options = "/options",
	report  = "/report",
})


return table.freeze(Endpoints)
