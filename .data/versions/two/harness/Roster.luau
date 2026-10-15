--!strict

--[=[
	Roster

	The players of the simulated engine: stand-in players that join and leave, and the record that
	Lync takes as its `roster` seam.

	A stand-in player is a frozen table with a `Name` and a `UserId` and nothing else, since Lync
	reads nothing more of a player. Every join makes a new table, so a player who leaves and joins
	again is a different value with the same name and id, as in the engine.

	Like `PlayersService.PlayerRemoving`, `removing` fires while the player is still in the game, so
	a listener still finds the player in `players()`.

	The seam is a record of plain functions and signals, called as `roster.players()`.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Signal = require("./Signal")


-- Module ------------------------------------------------------------------------------------------

local Roster   = {}
Roster.__index = Roster


-- Types -------------------------------------------------------------------------------------------

--[=[
	A stand-in player.

	@field Name   the name of the player, which no other player in the game has
	@field UserId the id of the player, which no other player in the game has
]=]
export type Player = {
	read Name:   string,
	read UserId: number,
}


--[=[
	The record that Lync takes as its `roster` seam.

	@field players  lists the players in the game, in the order they joined
	@field added    fires a player when the player has joined
	@field removing fires a player when the player is about to leave
	@field isPlayer tells whether a value is a player of this roster, one who has left included
]=]
export type Seam = {
	read players:  () -> { Player },
	read added:    Signal.Signal<Player>,
	read removing: Signal.Signal<Player>,
	read isPlayer: (value: unknown) -> boolean,
}


type Fields = {
	read _players:  { Player },
	read _standIns: { [unknown]: true },
	read _added:    Signal.Signal<Player>,
	read _removing: Signal.Signal<Player>,

	_seam:          Seam?,
}


--- The players in a simulated game.
export type Roster = setmetatable<Fields, typeof(Roster)>


-- Private -----------------------------------------------------------------------------------------

local function problemWithJoin(self: Roster, name: string, userId: number): string?
	if name == "" then
		return 'name must not be empty, got ""'
	end

	if
		not math.isfinite(userId)
		or math.floor(userId) ~= userId
	then
		return `userId must be a whole number, got {userId}`
	end

	for _, player in self._players do
		if player.Name == name then
			return `name must differ from every player in the game, got "{name}"`
		end

		if player.UserId == userId then
			return `userId must differ from every player in the game, got {userId}`
		end
	end

	return nil
end


local function players(self: Roster): { Player }
	return table.clone(self._players)
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a roster with no players.

	@return a roster that nobody has joined
]=]
function Roster.new(): Roster
	return setmetatable({
		_players  = {},
		_standIns = {},
		_added    = Signal.new(),
		_removing = Signal.new(),

		_seam     = nil,
	}, Roster)
end


--[=[
	Tells whether a player is in the game.

	@param  player the player to look for
	@return true from the moment `added` fires until `leave` has removed the player
]=]
function Roster.isInGame(self: Roster, player: Player): boolean
	return table.find(self._players, player) ~= nil
end


--[=[
	Makes a stand-in player join, and fires `added` with it.

	@param  name   the name of the player, not empty and not any player's in the game
	@param  userId the id of the player, a whole number that is not any player's in the game
	@return the new player
	@error  when `name` is empty or taken, or `userId` is not a whole number or is taken
]=]
function Roster.join(self: Roster, name: string, userId: number): Player
	local problem = problemWithJoin(self, name, userId)
	if problem ~= nil then
		error(problem, 2)
	end

	local player: Player = table.freeze({
		Name   = name,
		UserId = userId,
	})

	table.insert(self._players, player)
	self._standIns[player] = true
	self._added:fire(player)

	return player
end


--[=[
	Makes a player leave: fires `removing` with the player, and then removes the player.

	@param player the player to remove, who must be in the game
	@error when `player` is not in the game
]=]
function Roster.leave(self: Roster, player: Player): ()
	if table.find(self._players, player) == nil then
		error(`player must be in the game, got {player.Name}`, 2)
	end

	self._removing:fire(player)

	-- A listener may have changed the list, so the position is looked up again.
	local position = assert(table.find(self._players, player), "a leaving player must stay listed")
	table.remove(self._players, position)
end


--[=[
	Lists the players in the game.

	@return a copy of the list, in the order the players joined
]=]
function Roster.players(self: Roster): { Player }
	return players(self)
end


--[=[
	Tells why a player could not join now.

	@param  name   the name the player would have
	@param  userId the id the player would have
	@return what `join` would throw, in the words of its message, nil when the player could join
]=]
function Roster.problemWithJoin(self: Roster, name: string, userId: number): string?
	return problemWithJoin(self, name, userId)
end


--[=[
	Returns the record that Lync takes as its `roster` seam.

	@return the same frozen record on every call, whose members work on this roster
]=]
function Roster.seam(self: Roster): Seam
	local existing = self._seam
	if existing ~= nil then
		return existing
	end

	local seam: Seam = table.freeze({
		players  = function(): { Player }
			return players(self)
		end,
		added    = self._added,
		removing = self._removing,
		isPlayer = function(value: unknown): boolean
			return self._standIns[value] ~= nil
		end,
	})

	self._seam = seam

	return seam
end


return table.freeze(Roster)
