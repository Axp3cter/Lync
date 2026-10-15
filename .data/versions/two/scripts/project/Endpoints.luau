--!strict

--[=[
	Endpoints

	Names where the receiver listens and what it answers, so that the scripts and the harness that
	runs in Studio agree on them.

	The receiver listens on the local machine only, and its port is clear of rojo's 34872 and of the
	34873 that the bench project serves on.

	This module holds data only: it requires no module and touches no file.
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
