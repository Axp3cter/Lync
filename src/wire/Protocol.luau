--!strict
--!optimize 2
-- The one home of every wire constant. Nothing else in the repository may state one.

local Protocol = {}

-- What both machines have to agree on before either spends a byte on the other's schema.
Protocol.VERSION = 13

--[[
    Every byte the handshake spends. Until these agree, neither machine has learned anything about
    the other that it is entitled to act on.
]]
Protocol.HELLO_BYTES = 8
Protocol.VERDICT_BYTES = 9
Protocol.VERDICT_FIELD = 1
Protocol.VERDICT_REJECT = 0
Protocol.VERDICT_ACCEPT = 1

-- The width the bit packing counts in.
Protocol.BYTE_BITS = 8

--[[
    How far a double counts without losing a step. A signed varint folds its sign into the value it
    carries, so it reaches half this far in each direction.
]]
Protocol.EXACT = 2 ^ 53

--[[
    How deep an undeclared value may nest. A frame allowed to state its own depth would be a sender
    choosing how far the reader recurses.
]]
Protocol.UNKNOWN_DEPTH = 8

--[[
    One tag a value, paid on every value. That is the price of a schema that declares no shape for
    a reader to expect.
]]
Protocol.UNKNOWN_NOTHING = 0
Protocol.UNKNOWN_FALSE = 1
Protocol.UNKNOWN_TRUE = 2
Protocol.UNKNOWN_WHOLE = 3
Protocol.UNKNOWN_REAL = 4
Protocol.UNKNOWN_TEXT = 5
Protocol.UNKNOWN_BYTES = 6
Protocol.UNKNOWN_LIST = 7
Protocol.UNKNOWN_PAIRS = 8
Protocol.VLI_EDGE = 2 ^ 52 - 1
Protocol.VARINT_GROUPS = 8

--[[
    Room kept past the bound for a tag and the number behind it. A writer learns how wide a varint
    is by writing it, so one that runs over lands here and is refused afterwards.
]]
Protocol.UNKNOWN_SLACK = Protocol.VARINT_GROUPS + 1
Protocol.BIT_CEILING = 24

--[[
    A varint group, stated by the format and not by whoever encodes it. Somebody holding the bytes
    and none of this source still has to take one apart, and the half is where a sign folds.
]]
Protocol.VARINT_BITS = 7
Protocol.VARINT_MORE = 0x80
Protocol.VARINT_GROUP = 0x7F
Protocol.VARINT_HALF = 0x40

-- The most fields one record may declare.
Protocol.MAX_FIELDS = 64

--[[
    The unreliable lane. The margin is not measured and carries no date, because nothing has
    measured it: zero is the documented engine threshold taken at its word, and a margin above it
    is a number somebody would have to put a real network behind before writing down.
]]
Protocol.UNRELIABLE_CEILING = 1000
Protocol.UNRELIABLE_MARGIN = 0
Protocol.UNRELIABLE_CAP = Protocol.UNRELIABLE_CEILING - Protocol.UNRELIABLE_MARGIN
Protocol.MAX_FIRE = 1000000

-- Budgets, in bytes, and the detector window in seconds.
Protocol.BUDGET_RATE = 32768
Protocol.BUDGET_FLOOR = 1024
Protocol.SECTION_BYTES = Protocol.BUDGET_FLOOR
Protocol.DETECTOR_WINDOW = 1

-- Queries, the timeout in seconds.
Protocol.QUERY_TIMEOUT = 10
Protocol.QUERY_CAP = 32768

-- Sequences and stamps.
Protocol.NEWEST_WINDOW = 32768
Protocol.NEWEST_GENS = 4

--[[
    A stamp is unwrapped against the reader's own count, so this field holds how far two machines
    disagree and not how long the session has run. Hours of room against a lane's latency, which
    any length of session wraps through unharmed.
]]
Protocol.STAMP_BITS = 24
Protocol.STAMP_RATE = 1000

-- A packed colour's channel widths, least significant first.
Protocol.RGB565_RED = 5
Protocol.RGB565_GREEN = 6
Protocol.RGB565_BLUE = 5

--[[
    Which component a turn left behind, in the order they are counted. Four of them, so the tag a
    frame carries to name one costs two bits.
]]
Protocol.QUAT_X = 0
Protocol.QUAT_Y = 1
Protocol.QUAT_Z = 2
Protocol.QUAT_W = 3

-- How far one component of the octahedral fold runs, and what a precision for it is read against.
Protocol.QUARTER_TURN = 90

--[[
    How far the three kept components reach, the root of a half. The tag names the one left out and
    that one is the largest, so no kept component passes it, and two whose squares cannot exceed one
    meet exactly here.
]]
Protocol.QUAT_BOUND = 2 ^ -0.5

-- The response header's outcome. One bit, and it decides whether a payload follows.
Protocol.OUTCOME_BITS = 1

-- What a section header says it is, and how it names the fields it carries.
Protocol.SECTION_KEYFRAME = 0
Protocol.SECTION_DELTA = 1
Protocol.SECTION_REMOVAL = 2
Protocol.SECTION_CLEAR = 3
Protocol.FIELDSET_LIST = 0
Protocol.FIELDSET_MASK = 1

return table.freeze (Protocol)
