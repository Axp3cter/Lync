--!strict

--[=[
	Counters

	Totals that replace per-frame events (v5.md §7.4, diagnostics §5.3): an increment is an array
	write, and a snapshot is built only when asked for.

	A counter is named once and then used by slot. Names are a field, or a field and a qualifier
	after the first dot:
	- `messagesSent.<definition>`, and likewise `messagesReceived`, `bytesSent`, `bytesReceived`,
	  per definition (`messagesSent.arena.chat`);
	- `facts.<reason>`, uncapped, per reason;
	- `rowsDeferred`, `validatorErrors`, `validatorRejections`, `lateAnswers`, `heldBytes`, and on
	  a client `unresolvedMessages`.

	A snapshot holds the four message totals, `facts` by reason, and every other counter by name,
	the five above always; without a player it adds `definitions`, the message counters per
	definition. A player's counters are totals for that player, never per definition.
]=]

-- Module ------------------------------------------------------------------------------------------

local Counters = {}

-- Types -------------------------------------------------------------------------------------------

--- One side's counters.
export type State = {
	names: { string },
	fields: { string },
	qualifiers: { string },
	slotByName: { [string]: number },
	totals: { number },
	valuesByPlayer: { [Player]: { number } },
}

-- Constants ---------------------------------------------------------------------------------------

const MESSAGE_FIELDS: { [string]: true } = {
	messagesSent = true,
	messagesReceived = true,
	bytesSent = true,
	bytesReceived = true,
}
table.freeze(MESSAGE_FIELDS)

const FACTS_FIELD = "facts"

const ALWAYS_SHOWN = table.freeze({
	"rowsDeferred",
	"validatorErrors",
	"validatorRejections",
	"lateAnswers",
	"heldBytes",
})

const NO_VALUES: { number } = table.freeze({})

-- Private -----------------------------------------------------------------------------------------

local function zeroMessages(): { [string]: number }
	return {
		messagesSent = 0,
		messagesReceived = 0,
		bytesSent = 0,
		bytesReceived = 0,
	}
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a side's counters, with none named.

	@return the counters
]=]
function Counters.new(): State
	return {
		names = {},
		fields = {},
		qualifiers = {},
		slotByName = {},
		totals = {},
		valuesByPlayer = {},
	}
end

--[=[
	Adds `n` to a counter, in the totals and, with a player, in that player's.

	@param s      the counters
	@param slot   the counter's slot
	@param player the player it concerns, if any
	@param n      the amount; negative for a gauge such as `heldBytes`
]=]
function Counters.add(s: State, slot: number, player: Player?, n: number)
	s.totals[slot] += n
	if player == nil then
		return
	end

	local values = s.valuesByPlayer[player]
	if values == nil then
		values = table.create(#s.names, 0)
		s.valuesByPlayer[player] = values
	end

	values[slot] = (values[slot] or 0) + n
end

--[=[
	Frees a player's counters; the totals keep what it added.

	@param s      the counters
	@param player the player, usually one leaving
]=]
function Counters.forget(s: State, player: Player)
	s.valuesByPlayer[player] = nil
end

--[=[
	The slot of a counter, naming it on first use. Called at plan or join time, never per message.

	@param  s    the counters
	@param  name the counter's name, as the module block describes
	@return its slot, the same for the same name
]=]
function Counters.slot(s: State, name: string): number
	local existing = s.slotByName[name]
	if existing ~= nil then
		return existing
	end

	local field, qualifier = string.match(name, "^([^.]+)%.(.+)$")
	local slot = #s.names + 1
	s.names[slot] = name
	s.fields[slot] = field or name
	s.qualifiers[slot] = qualifier or ""
	s.totals[slot] = 0
	s.slotByName[name] = slot

	return slot
end

--[=[
	A frozen snapshot of the counters, as the module block describes.

	@param  s      the counters
	@param  player the player whose totals to give; nil for the whole side, per definition
	@return the snapshot
]=]
function Counters.snapshot(s: State, player: Player?): { [string]: any }
	local values = if player == nil then s.totals else s.valuesByPlayer[player] or NO_VALUES
	local snapshot: { [string]: any } = zeroMessages()
	local facts: { [string]: number } = {}
	local definitions: { [string]: { [string]: number } } = {}
	for _, name in ALWAYS_SHOWN do
		snapshot[name] = 0
	end

	for slot, name in s.names do
		local n = values[slot] or 0
		local field = s.fields[slot]
		local qualifier = s.qualifiers[slot]
		if field == FACTS_FIELD then
			facts[qualifier] = n
		elseif MESSAGE_FIELDS[field] then
			snapshot[field] += n
			local messages = definitions[qualifier] or zeroMessages()
			messages[field] = n
			definitions[qualifier] = messages
		else
			snapshot[name] = n
		end
	end

	snapshot.facts = table.freeze(facts)
	if player == nil then
		for _, messages in definitions do
			table.freeze(messages)
		end
		snapshot.definitions = table.freeze(definitions)
	end

	return table.freeze(snapshot)
end

return table.freeze(Counters)
