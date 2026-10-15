--!strict

--[=[
	World

	The simulated engine as a whole: one virtual clock, one network and one roster, and the seams
	records that Lync takes as the second argument of `Lync.server` and `Lync.client`.

	The server view and every client view run in one DataModel and one Luau thread, which is how
	code on the client gets covered. Nothing is sent or received until the test moves time with
	`advance`, so a test sees each step of an exchange.

	A seams record is the record the spec describes: `transport`, `clock` and `roster`, and no other
	field. The server has one record and each player in the game has one, the same record every time
	it is asked for, so views taken with it share one instance, and the instances of two records
	share no state.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Network      = require("./Network")
local RandomSource = require("./RandomSource")
local Recorder     = require("./Recorder")
local Roster       = require("./Roster")
local Timeline     = require("./Timeline")


-- Module ------------------------------------------------------------------------------------------

local World   = {}
World.__index = World


-- Types -------------------------------------------------------------------------------------------

--[=[
	The seams of one endpoint, as `Lync.server` and `Lync.client` take them.

	@field transport the lanes of this endpoint: the server's, or the client's of one player
	@field clock     the virtual clock, which every endpoint of the world shares
	@field roster    the players of the world, which every endpoint of the world shares
]=]
export type Seams = {
	read transport: Network.Transport<Roster.Player>,
	read clock:     Timeline.Clock,
	read roster:    Roster.Seam,
}


--[=[
	What `new` needs to build a world.

	@field seed  the seed of the world, a whole number from 0 to 4294967295, which `fates` draw from
	@field plan  chooses the fate of each frame; when `fates` is nil too, every frame is perfect
	@field fates draws each frame's fate, in the order they are sent, from a source seeded `seed`
]=]
export type Options = {
	read seed:  number,
	read plan:  Network.Plan?,
	read fates: RandomSource.Generator<Network.Fate>?,
}


type Fields = {
	read _timeline:       Timeline.Timeline,
	read _network:        Network.Network<Roster.Player>,
	read _roster:         Roster.Roster,
	read _server:         Seams,
	read _clientByPlayer: { [Roster.Player]: Seams },
}


--- The simulated engine: a clock, a network and a roster.
export type World = setmetatable<Fields, typeof(World)>


-- Private -----------------------------------------------------------------------------------------

local function drawnPlan(
	source: RandomSource.RandomSource,
	fates:  RandomSource.Generator<Network.Fate>
): Network.Plan
	return function(
		lane:      Network.LaneName,
		direction: Network.Direction,
		ordinal:   number
	): Network.Fate
		return fates(source)
	end
end


local function planFrom(options: Options): Network.Plan
	local plan = options.plan
	if plan ~= nil then
		return plan
	end

	local fates = options.fates
	if fates ~= nil then
		return drawnPlan(RandomSource.new(options.seed), fates)
	end

	return Network.perfectPlan
end


local function seamsOf(
	transport: Network.Transport<Roster.Player>,
	timeline:  Timeline.Timeline,
	roster:    Roster.Roster
): Seams
	return table.freeze({
		transport = transport,
		clock     = timeline:clock(),
		roster    = roster:seam(),
	})
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a world at virtual time 0 with nobody in the game.

	@param  options the seed, and how the fate of each frame is chosen
	@return a world in which nothing has been sent
	@error  when `options.seed` is not a whole number from 0 to 4294967295
	@error  when `options` gives both a plan and fates
]=]
function World.new(options: Options): World
	if not RandomSource.isWord(options.seed) then
		local requirement = `a whole number from 0 to {RandomSource.MAX_WORD}`
		error(`options.seed must be {requirement}, got {options.seed}`, 2)
	end

	if
		options.plan ~= nil
		and options.fates ~= nil
	then
		error("options must give a plan or fates, got both", 2)
	end

	local timeline = Timeline.new()
	local roster   = Roster.new()
	local network  = Network.new<<Roster.Player>>(timeline, planFrom(options))

	return setmetatable({
		_timeline       = timeline,
		_network        = network,
		_roster         = roster,
		_server         = seamsOf(network:server(), timeline, roster),
		_clientByPlayer = {},
	}, World)
end


--[=[
	Moves virtual time forward and delivers what falls due on the way.

	@param duration how far to move, in seconds
	@error when `duration` is not a finite number of 0 or more
	@error whatever a callback or a listener throws, unchanged
]=]
function World.advance(self: World, duration: number): ()
	if not Timeline.isDuration(duration) then
		error(`duration must be a finite number of 0 or more, got {duration}`, 2)
	end

	self._timeline:advance(duration)
end


--[=[
	Returns the seams of the client of a player.

	@param  player the player the client belongs to, who must be in the game
	@return the seams record of that endpoint, the same record on every call while the player stays
	@error  when `player` is not in the game
]=]
function World.client(self: World, player: Roster.Player): Seams
	if not self._roster:isInGame(player) then
		error(`player must be in the game, got {player.Name}`, 2)
	end

	local existing = self._clientByPlayer[player]
	if existing ~= nil then
		return existing
	end

	local seams = seamsOf(self._network:client(player), self._timeline, self._roster)

	self._clientByPlayer[player] = seams

	return seams
end


--[=[
	Claims every uncaught error whose message matches `pattern` for the test that is running, so
	that the error does not fail the test.

	A test that breaks a listener on purpose claims the error it expects here. An error that no
	test claimed fails the test that was running when it happened.

	@param pattern the Lua pattern that the claimed errors' messages match, not empty
	@error when `pattern` is empty or is not a Lua pattern
	@error when no recorder is recording, which is when no runner is running a test
]=]
function World.expectFault(self: World, pattern: string): ()
	if pattern == "" then
		error('pattern must not be empty, got ""', 2)
	end

	if not Recorder.isPattern(pattern) then
		error(`pattern must be a valid Lua pattern, got "{pattern}"`, 2)
	end

	local recorder = Recorder.current()
	if recorder == nil then
		error("expectFault must be called while a test runs, got no recorder recording", 2)
	end

	recorder:claimFault(pattern)
end


--[=[
	Makes a stand-in player join the game, and fires `added` with the player.

	@param  name   the name of the player, not empty and not any player's in the game
	@param  userId the id of the player, a whole number that is not any player's in the game
	@return the new player
	@error  when `name` is empty or taken, or `userId` is not a whole number or is taken
]=]
function World.join(self: World, name: string, userId: number): Roster.Player
	local problem = self._roster:problemWithJoin(name, userId)
	if problem ~= nil then
		error(problem, 2)
	end

	return self._roster:join(name, userId)
end


--[=[
	Makes a player leave the game: fires `removing`, removes the player, and drops the player's
	connection, so that frames on the way to or from the player are lost.

	@param player the player who leaves, who must be in the game
	@error when `player` is not in the game
]=]
function World.leave(self: World, player: Roster.Player): ()
	if not self._roster:isInGame(player) then
		error(`player must be in the game, got {player.Name}`, 2)
	end

	self._roster:leave(player)
	self._network:detach(player)
	self._clientByPlayer[player] = nil
end


--[=[
	Returns the network, to read its tallies and its trace.

	@return the network of this world
]=]
function World.network(self: World): Network.Network<Roster.Player>
	return self._network
end


--[=[
	Returns the virtual time.

	@return seconds since the world was created
]=]
function World.now(self: World): number
	return self._timeline:now()
end


--[=[
	Returns the seams of the server.

	@return the seams record of the server, the same record on every call
]=]
function World.server(self: World): Seams
	return self._server
end


return table.freeze(World)
