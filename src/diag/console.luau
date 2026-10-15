--!strict

--[=[
	Console

	Prints facts as console lines (v5.md §7.4): a code's first occurrence in a window prints one
	line at once, and a summary at the window's close if more occurred, so at most 2 lines per
	code per window, whatever the number of players.

	A line's text is constant per code, `[Lync] <code>: {count} in {seconds} s, {players}
	players, {definitions} definitions`; the numbers, at most 8 `UserId`s and at most 8
	definition names travel in the context, so no value a client chose enters the text
	(diagnostics §1.5, §5.6). The summary counts every occurrence of the window, the first
	included.

	A client prints only its local facts. Windows are `os.clock()` seconds, `observe.window` long.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Codes = require("./codes")
local Host = require("../host/host")

-- Module ------------------------------------------------------------------------------------------

local Console = {}

-- Types -------------------------------------------------------------------------------------------

type Window = {
	openedAt: number,
	closesAt: number,
	count: number,
	players: { [Player]: true },
	playerCount: number,
	userIds: { number },
	definitions: { [string]: true },
	definitionCount: number,
	definitionNames: { string },
}

--- One side's console.
export type State = {
	host: Host.Host,
	isClient: boolean,
	isEnabled: boolean,
	window: number,
	windowByCode: { [Codes.Code]: Window },
}

-- Constants ---------------------------------------------------------------------------------------

const DEFAULT_WINDOW = 30
const MAX_LISTED = 8

-- The facts a client prints: its own sends and scheduling, never what it received.
const LOCAL_REASONS: { [Codes.Code]: true } = {
	sendDropped = true,
	missedFlush = true,
	remotesMissing = true,
}
table.freeze(LOCAL_REASONS)

const TEMPLATE_BY_CODE: { [Codes.Code]: string } = {}
for code, family in Codes.family do
	if family == "fact" then
		TEMPLATE_BY_CODE[code] =
			`[Lync] {code}: \{count} in \{seconds} s, \{players} players, \{definitions} definitions`
	end
end
table.freeze(TEMPLATE_BY_CODE)

-- Private -----------------------------------------------------------------------------------------

local function note(window: Window, player: Player?, definition: string?)
	if player ~= nil and window.players[player] == nil then
		window.players[player] = true
		window.playerCount += 1
		if #window.userIds < MAX_LISTED then
			table.insert(window.userIds, player.UserId)
		end
	end

	if definition ~= nil and window.definitions[definition] == nil then
		window.definitions[definition] = true
		window.definitionCount += 1
		if #window.definitionNames < MAX_LISTED then
			table.insert(window.definitionNames, definition)
		end
	end
end

local function printLine(s: State, code: Codes.Code, window: Window, count: number, seconds: number)
	s.host.warn(TEMPLATE_BY_CODE[code], {
		count = count,
		seconds = seconds,
		players = window.playerCount,
		definitions = window.definitionCount,
		userIds = table.freeze(table.clone(window.userIds)),
		definitionNames = table.freeze(table.clone(window.definitionNames)),
	})
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a console, enabled, with the default 30 s window.

	@param  host the side's host, which prints the lines
	@return the console
]=]
function Console.new(host: Host.Host): State
	return {
		host = host,
		isClient = host.side == "client",
		isEnabled = true,
		window = DEFAULT_WINDOW,
		windowByCode = {},
	}
end

--[=[
	Sets the window length for windows opened from now on (`observe.window`).

	@param s      the console
	@param window seconds
]=]
function Console.configure(s: State, window: number)
	s.window = window
end

--[=[
	Turns printing on or off (`console`, a server option). Windows open when it is turned off
	close without a summary.

	@param s       the console
	@param enabled whether lines are printed
]=]
function Console.enable(s: State, enabled: boolean)
	s.isEnabled = enabled
	if not enabled then
		table.clear(s.windowByCode)
	end
end

--[=[
	Counts one occurrence of a fact, printing a line if it opens its code's window.

	@param s          the console
	@param reason     the fact's code
	@param player     the player it concerns, if any
	@param definition the definition it concerns, if any
	@param now        `os.clock()`
]=]
function Console.fact(
	s: State,
	reason: Codes.Code,
	player: Player?,
	definition: string?,
	now: number
)
	if not s.isEnabled or (s.isClient and LOCAL_REASONS[reason] == nil) then
		return
	end

	local window = s.windowByCode[reason]
	if window ~= nil then
		window.count += 1
		note(window, player, definition)
		return
	end

	local opened: Window = {
		openedAt = now,
		closesAt = now + s.window,
		count = 1,
		players = {},
		playerCount = 0,
		userIds = {},
		definitions = {},
		definitionCount = 0,
		definitionNames = {},
	}
	note(opened, player, definition)
	s.windowByCode[reason] = opened
	printLine(s, reason, opened, 1, 0)
end

--[=[
	Closes the windows that have ended, printing a summary for each in which more than the first
	occurrence happened.

	@param s   the console
	@param now `os.clock()`
]=]
function Console.sweep(s: State, now: number)
	for code, window in s.windowByCode do
		if now < window.closesAt then
			continue
		end

		s.windowByCode[code] = nil
		if window.count > 1 then
			printLine(s, code, window, window.count, window.closesAt - window.openedAt)
		end
	end
end

return table.freeze(Console)
