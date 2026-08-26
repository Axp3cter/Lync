--!strict
--!optimize 2
-- The one home of every wire constant. Nothing else in the repository may state one.

local Protocol = {}

-- What both machines have to agree on before either spends a byte on the other's schema.
Protocol.VERSION = 6

--[[
    The handshake lane's whole grammar: what each of the two messages weighs, where a verdict keeps
    its one field, what a verdict says first, and the whole of what one can say.
]]
Protocol.HELLO_BYTES = 8
Protocol.VERDICT_BYTES = 9
Protocol.VERDICT_FIELD = 1
Protocol.VERDICT_REJECT = 0
Protocol.VERDICT_ACCEPT = 1

-- How a bit is addressed, which is the whole of what a byte means to this format.
Protocol.BYTE_BITS = 8

--[[
    The number domain. A signed varint folds its sign into the value it carries, so it reaches half
    as far in each direction and its edge sits a bit below the one a double counts exactly to.
]]
Protocol.EXACT = 2 ^ 53

--[[
    How deep a value nobody declared may nest, since a frame stating its own nesting is a sender
    picking the reader's stack depth. Past anything written by hand and under what a walk costs.
]]
Protocol.UNKNOWN_DEPTH = 8

--[[
    What each part of one is spelled as, which is all a reader knows before it reads one. A tag
    apiece is what buys saying nothing about the shape in the schema.
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
    The room a frame keeps past such a value's own bound, which is the widest a tag and the number
    behind it can come to. A writer discovers a varint's width by writing it, so the slack is what
    it lands in when the bound is what refuses it.
]]
Protocol.UNKNOWN_SLACK = Protocol.VARINT_GROUPS + 1
Protocol.BIT_CEILING = 24

--[[
    A varint group: the bit that says another follows, the seven under it, and half of those.

    The format's own and not the encoder's, since a reader who has the bytes and not the source
    has to be able to take one apart, and half a group is where a signed value's sign folds.
]]
Protocol.VARINT_BITS = 7
Protocol.VARINT_MORE = 0x80
Protocol.VARINT_GROUP = 0x7F
Protocol.VARINT_HALF = 0x40

-- Schema legality.
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
    A stamp is unwrapped against the reader's own count, so the field holds the disagreement
    between two machines rather than the age of the session. Hours of it, where what they can
    disagree by is a lane's latency, and a session of any length wraps through this unharmed.
]]
Protocol.STAMP_BITS = 24
Protocol.STAMP_RATE = 1000

-- A packed colour's channel widths, least significant first.
Protocol.RGB565_RED = 5
Protocol.RGB565_GREEN = 6
Protocol.RGB565_BLUE = 5

--[[
    Which component a turn left behind, in the order they are counted. The tag a frame carries is
    one of these four, which is also why it is two bits wide.
]]
Protocol.QUAT_X = 0
Protocol.QUAT_Y = 1
Protocol.QUAT_Z = 2
Protocol.QUAT_W = 3

--[[
    How far one component of the octahedral fold runs, in degrees, which is what a precision stated
    for one is read against.
]]
Protocol.QUARTER_TURN = 90

--[[
    How far the three that were kept can reach, which is the root of a half. The tag names the one
    left out and it is the largest, so a kept component is no larger than that one and the two of
    them squared cannot pass one, which puts both at this exactly where they are equal.
]]
Protocol.QUAT_BOUND = 2 ^ -0.5

-- The response header's outcome, which is one bit and decides whether a payload follows it.
Protocol.OUTCOME_BITS = 1

-- What a section header says it is, and how it names the fields it carries.
Protocol.SECTION_KEYFRAME = 0
Protocol.SECTION_DELTA = 1
Protocol.SECTION_REMOVAL = 2
Protocol.SECTION_CLEAR = 3
Protocol.FIELDSET_LIST = 0
Protocol.FIELDSET_MASK = 1

return table.freeze (Protocol)
