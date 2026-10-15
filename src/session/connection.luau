--!strict

--[=[
	Connection

	One peer's connection state (m2-plan.md §3.4): a server keeps one per player, a client one
	to the server. It holds the tag key and counts, the replay window, the handshake's progress
	per namespace, holds, the 16 request slots each way with their epochs, and on a server the
	inbound and `limit` buckets. The type is `State.Connection`.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Buckets = require("./buckets")
local Replay = require("./replay")
local State = require("./state")

-- Module ------------------------------------------------------------------------------------------

local Connection = {}

-- Constants ---------------------------------------------------------------------------------------

const KEY_BYTES = 8

-- The inbound buckets' places in `buckets`, frames then bytes per lane (lane * 2 + 1 and + 2).
const ELEMENTS = 5

-- Private -----------------------------------------------------------------------------------------

local function limitsOf(config: State.Config): { State.Limit }
	return {
		config.reliableFrames,
		config.reliableBytes,
		config.unreliableFrames,
		config.unreliableBytes,
		config.elements,
	}
end

-- Public ------------------------------------------------------------------------------------------

--- Where `buckets` keeps the element bucket.
Connection.ELEMENTS = ELEMENTS

--[=[
	Creates a connection.

	@param  rt     the runtime
	@param  player the player on a server; nil on a client
	@return the connection: no key, every slot free, buckets full
]=]
function Connection.new(rt: State.Runtime, player: Player?): State.Connection
	local now = rt.host.clock()
	local buckets = {}
	if rt.side == "server" then
		for i, limit in limitsOf(rt.config) do
			buckets[i] = Buckets.new(limit.perSecond, limit.burst, now)
		end
	end

	return {
		player = player,
		key = nil,
		cover = 0,
		count = 0,
		pendingKey = nil,
		rekeyAt = -math.huge,
		failures = 0,
		hasTagged = false,
		isWelcomed = false,
		seq = 0,
		window = Replay.new(),
		waiting = {},
		asked = {},
		hashByName = {},
		welcomed = {},
		refused = {},
		sending = {},
		holds = {},
		holdBytes = 0,
		lastTick = -1,
		asking = {},
		queued = {},
		epochs = table.create(State.SLOT_COUNT, 0),
		answering = {},
		buckets = buckets,
		limits = {},
	}
end

--[=[
	Builds a tag key from its two words (v5.md §4.5).

	@param  low  the key's low u32
	@param  high the key's high u32
	@return the 8-byte key: both words little-endian, low first
]=]
function Connection.key(low: number, high: number): buffer
	local key = buffer.create(KEY_BYTES)
	buffer.writeu32(key, 0, low)
	buffer.writeu32(key, 4, high)
	return key
end

--[=[
	Applies the runtime's inbound budgets to a connection's buckets, keeping their tokens up to
	the new capacities.

	@param rt   the runtime
	@param conn the connection
]=]
function Connection.reconfigure(rt: State.Runtime, conn: State.Connection)
	for i, limit in limitsOf(rt.config) do
		local bucket = conn.buckets[i]
		bucket.rate = limit.perSecond
		bucket.capacity = limit.burst
		bucket.tokens = math.min(bucket.tokens, limit.burst)
	end
end

--[=[
	Returns a server's `limit` bucket for a definition, creating it full on first use: rate
	`perSecond`, capacity `burst` plus the slack (v5.md §5.4).

	@param  rt         the runtime
	@param  conn       the connection
	@param  definition a definition with a `limit`
	@return the bucket
]=]
function Connection.limitOf(
	rt: State.Runtime,
	conn: State.Connection,
	definition: State.Definition
): Buckets.Bucket
	local bucket = conn.limits[definition]
	if bucket ~= nil then
		return bucket
	end

	local limit = definition.ir.limit :: State.Limit
	local capacity = limit.burst + State.LIMIT_SLACK * limit.perSecond
	local created = Buckets.new(limit.perSecond, capacity, rt.host.clock())
	conn.limits[definition] = created
	return created
end

return table.freeze(Connection)
