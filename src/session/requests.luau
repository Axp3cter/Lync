--!strict

--[=[
	Requests

	Request slots both ways (v5.md §5.2): 16 per direction per connection, each with a 1-bit
	epoch that starts at 0.

	- **Asking.** `invoke` takes a free slot, or waits for one with its timeout running, then
	  waits for the answer. A timeout frees the slot and flips its epoch, so a late answer is
	  discarded and counted (`lateAnswers`). The caller's thread yields; requests never throw,
	  they return results.
	- **Answering.** An ask for a slot in flight with the other epoch replaces the abandoned one;
	  with the same epoch it is `slotConflict` case 3. A handler runs in its own thread; its
	  wrapper queues the answer when it returns, and a thread found dead and unanswered threw,
	  which the engine reported natively, so it is answered `unanswered`, as is one past the
	  request's timeout. Threads are checked once per step.
]=]

-- Imports -----------------------------------------------------------------------------------------

local State = require("./state")

-- Module ------------------------------------------------------------------------------------------

local Requests = {}

-- Constants ---------------------------------------------------------------------------------------

const TIMEOUT = table.freeze({ ok = false, error = "timeout" })
const REJECTED = table.freeze({ ok = false, error = "rejected" })
const UNANSWERED = table.freeze({ ok = false, error = "unanswered" })
const LEFT = table.freeze({ ok = false, error = "left" })
const SHUTDOWN = table.freeze({ ok = false, error = "shutdown" })

-- A message from Lync's encoders, with or without the position of the frame it was raised at.
const LYNC_MESSAGE = "^.-:%d+: (%[Lync%] .*)$"

-- Private -----------------------------------------------------------------------------------------

local function resume(thread: thread)
	local ok, message = coroutine.resume(thread)
	if not ok then
		error(message, 0)
	end
end

local function wake(rt: State.Runtime, request: State.Request)
	if coroutine.status(request.thread) == "suspended" then
		rt.host.spawn(resume, request.thread)
	end
end

local function freeSlotOf(conn: State.Connection): number?
	for slot = 0, State.SLOT_COUNT - 1 do
		if conn.asking[slot] == nil then
			return slot
		end
	end

	return nil
end

local function take(conn: State.Connection, request: State.Request, slot: number)
	request.slot = slot
	request.epoch = conn.epochs[slot + 1]
	conn.asking[slot] = request
end

-- Frees a request's slot, flipping its epoch when the request gave up on it, and hands it to the
-- oldest request waiting for one.
local function release(
	rt: State.Runtime,
	conn: State.Connection,
	request: State.Request,
	isFlipped: boolean
)
	local slot = request.slot
	if slot < 0 then
		local index = table.find(conn.queued, request)
		if index ~= nil then
			table.remove(conn.queued, index)
		end
		return
	end

	conn.asking[slot] = nil
	if isFlipped then
		conn.epochs[slot + 1] = 1 - conn.epochs[slot + 1]
	end

	local nextRequest = table.remove(conn.queued, 1)
	if nextRequest ~= nil then
		take(conn, nextRequest, slot)
		wake(rt, nextRequest)
	end
end

local function finish(
	rt: State.Runtime,
	conn: State.Connection,
	request: State.Request,
	result: { [string]: any },
	isFlipped: boolean
)
	request.result = result
	release(rt, conn, request, isFlipped)
	wake(rt, request)
end

local function resultOf(outcome: number, value: any): { [string]: any }
	if outcome == State.OUTCOME_REJECTED then
		return REJECTED
	end

	if outcome == State.OUTCOME_UNANSWERED then
		return UNANSWERED
	end

	return table.freeze({ ok = true, value = value })
end

-- A refused reply positioned at the handler that returned it, since the handler's frame is gone
-- when its reply is encoded.
local function repositioned(message: any, handler: (...any) -> ...any): any
	local body = if typeof(message) == "string" then string.match(message, LYNC_MESSAGE) else nil
	if body == nil then
		return message
	end

	local source, line = debug.info(handler, "sl")
	return `{source}:{line}: {body}`
end

local function runHandler(
	rt: State.Runtime,
	conn: State.Connection,
	answering: State.Answering,
	slot: number,
	handler: (...any) -> ...any,
	...: any
)
	local results = table.pack(handler(...))
	if answering.isAnswered then
		return
	end

	answering.isAnswered = true
	if conn.answering[slot] == answering then
		conn.answering[slot] = nil
	end

	local definition = answering.definition
	local player = conn.player
	if definition.ir.reply ~= nil and results.n == 0 then
		rt.answer(rt, definition, player, slot, answering.epoch, State.OUTCOME_UNANSWERED, nil)
		return
	end

	local ok, message = pcall(
		rt.answer,
		rt,
		definition,
		player,
		slot,
		answering.epoch,
		State.OUTCOME_VALUE,
		results[1]
	)
	if ok then
		return
	end

	rt.answer(rt, definition, player, slot, answering.epoch, State.OUTCOME_UNANSWERED, nil)
	error(repositioned(message, handler), 0)
end

local function giveUp(rt: State.Runtime, conn: State.Connection, slot: number)
	local answering = conn.answering[slot]
	answering.isAnswered = true
	conn.answering[slot] = nil
	rt.answer(
		rt,
		answering.definition,
		conn.player,
		slot,
		answering.epoch,
		State.OUTCOME_UNANSWERED,
		nil
	)
end

local function sweepConnection(rt: State.Runtime, conn: State.Connection, now: number)
	local expired = {}
	for _, request in conn.asking do
		if now >= request.deadline then
			table.insert(expired, request)
		end
	end
	for _, request in conn.queued do
		if now >= request.deadline then
			table.insert(expired, request)
		end
	end
	for _, request in expired do
		finish(rt, conn, request, TIMEOUT, true)
	end

	for slot, answering in conn.answering do
		local thread = answering.thread
		local isDead = thread ~= nil and coroutine.status(thread) == "dead"
		if isDead or now >= answering.deadline then
			giveUp(rt, conn, slot)
		end
	end
end

local function settleAll(rt: State.Runtime, conn: State.Connection, result: { [string]: any })
	for _, request in table.clone(conn.asking) do
		finish(rt, conn, request, result, false)
	end
	for _, request in table.clone(conn.queued) do
		finish(rt, conn, request, result, false)
	end
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Checks an ask this side read (v5.md §5.2): an ask for a slot in flight with its epoch is
	`slotConflict` case 3; with the other epoch, the abandoned ask's answer is discarded.

	@param  rt         the runtime
	@param  conn       the connection it came on
	@param  definition the request
	@param  slot       the ask's slot
	@param  epoch      the ask's epoch
	@return whether the ask goes on; when not, it is dropped unanswered
]=]
function Requests.admit(
	rt: State.Runtime,
	conn: State.Connection,
	definition: State.Definition,
	slot: number,
	epoch: number
): boolean
	local answering = conn.answering[slot]
	if answering == nil then
		return true
	end

	if answering.epoch == epoch then
		State.fact(rt, "slotConflict", conn.player, definition, slot, 3)
		return false
	end

	answering.isAnswered = true
	conn.answering[slot] = nil
	return true
end

--[=[
	Takes a slot for a request, waiting for one if all 16 are taken; the timeout runs while it
	waits. Yields.

	@param  rt         the runtime
	@param  conn       the connection to ask on
	@param  definition the request
	@param  player     the player asked, on a server
	@return the request: holding its slot, or settled when it timed out or the player left first
]=]
function Requests.begin(
	rt: State.Runtime,
	conn: State.Connection,
	definition: State.Definition,
	player: Player?
): State.Request
	local request: State.Request = {
		definition = definition,
		player = player,
		thread = coroutine.running(),
		deadline = rt.host.clock() + (definition.ir.timeout :: number),
		slot = -1,
		epoch = 0,
		result = nil,
	}

	local slot = freeSlotOf(conn)
	if slot ~= nil then
		take(conn, request, slot)
		return request
	end

	table.insert(conn.queued, request)
	while request.slot < 0 and request.result == nil do
		coroutine.yield()
	end

	return request
end

--[=[
	Frees a request's slot without sending anything, when its ask could not be encoded.

	@param rt      the runtime
	@param conn    the connection
	@param request the request
]=]
function Requests.cancel(rt: State.Runtime, conn: State.Connection, request: State.Request)
	request.result = UNANSWERED
	release(rt, conn, request, false)
end

--[=[
	Runs a request's handler for an admitted ask, in its own thread, and answers when it
	returns: `unanswered` when there is no handler, or it returns nothing for a request with a
	reply.

	@param rt         the runtime
	@param conn       the connection the ask came on
	@param definition the request
	@param slot       the ask's slot
	@param epoch      the ask's epoch
	@param ...        the handler's arguments
]=]
function Requests.handle(
	rt: State.Runtime,
	conn: State.Connection,
	definition: State.Definition,
	slot: number,
	epoch: number,
	...: any
)
	local handler = definition.handler
	if handler == nil then
		rt.answer(rt, definition, conn.player, slot, epoch, State.OUTCOME_UNANSWERED, nil)
		return
	end

	local answering: State.Answering = {
		definition = definition,
		epoch = epoch,
		thread = nil,
		deadline = rt.host.clock() + (definition.ir.timeout :: number),
		isAnswered = false,
	}
	conn.answering[slot] = answering
	answering.thread = rt.host.spawn(runHandler, rt, conn, answering, slot, handler, ...)
end

--[=[
	Settles a server's requests to a leaving player with `left`.

	@param rt   the server's runtime
	@param conn the player's connection
]=]
function Requests.leave(rt: State.Runtime, conn: State.Connection)
	settleAll(rt, conn, LEFT)
end

--[=[
	Checks an answer this side read (v5.md §5.2): an epoch other than its slot's is a late
	answer, discarded and counted; then an answer for a free slot is `slotConflict` case 1, and
	one for another request case 2.

	@param  rt         the runtime
	@param  conn       the connection it came on
	@param  definition the request the answer's id names
	@param  slot       the answer's slot
	@param  epoch      the answer's epoch
	@return the request it answers, or nil when it is dropped
]=]
function Requests.match(
	rt: State.Runtime,
	conn: State.Connection,
	definition: State.Definition,
	slot: number,
	epoch: number
): State.Request?
	if epoch ~= conn.epochs[slot + 1] then
		State.count(rt, "lateAnswers", conn.player, 1)
		return nil
	end

	local request = conn.asking[slot]
	if request == nil then
		State.fact(rt, "slotConflict", conn.player, definition, slot, 1)
		return nil
	end

	if request.definition ~= definition then
		State.fact(rt, "slotConflict", conn.player, definition, slot, 2)
		return nil
	end

	return request
end

--[=[
	Settles a request with its answer and wakes its caller.

	@param rt      the runtime
	@param conn    the connection it was asked on
	@param request the request, from `Requests.match`
	@param outcome 0 value, 1 rejected, 2 unanswered
	@param value   the reply, for outcome 0
]=]
function Requests.settle(
	rt: State.Runtime,
	conn: State.Connection,
	request: State.Request,
	outcome: number,
	value: any
)
	finish(rt, conn, request, resultOf(outcome, value), false)
end

--[=[
	Settles every request a server asked with `shutdown`, as `BindToClose` runs.

	@param rt the server's runtime
]=]
function Requests.shutdown(rt: State.Runtime)
	for _, conn in rt.connections do
		settleAll(rt, conn, SHUTDOWN)
	end
end

--[=[
	Times out requests past their deadline, and answers `unanswered` for handlers that threw or
	ran past the timeout. Called every step.

	@param rt the runtime
]=]
function Requests.sweep(rt: State.Runtime)
	local now = rt.host.clock()
	if rt.side == "client" then
		sweepConnection(rt, rt.connection, now)
		return
	end

	for _, conn in rt.connections do
		sweepConnection(rt, conn, now)
	end
end

--[=[
	Waits for a request's result. Yields.

	@param  request the request
	@return its result
]=]
function Requests.wait(request: State.Request): { [string]: any }
	while request.result == nil do
		coroutine.yield()
	end

	return request.result :: { [string]: any }
end

return table.freeze(Requests)
