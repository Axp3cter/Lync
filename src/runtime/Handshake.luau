--!strict
--!optimize 2
-- The two messages the handshake lane carries, and the judgement each one earns.

local Catalog = require ("@src/kernel/Catalog")
local Log = require ("@src/kernel/Log")
local Protocol = require ("@src/wire/Protocol")
local Wide = require ("@src/kernel/Wide")

local Handshake = {}

-- Constants -----------------------------------------------------------

-- What each message weighs, which is the whole of what tells the two apart, and where a field sits.
const HELLO = Protocol.HELLO_BYTES
const VERDICT = Protocol.VERDICT_BYTES
const FIELD = Protocol.VERDICT_FIELD

-- Private -------------------------------------------------------------

--[[
    One code for both sides. A hello reaching a client and a verdict reaching a server are one event
    told from two ends, and neither end has anything to say about the bytes past that.
]]
local function unspoken ()
    local facts: Log.Facts = { code = Catalog.HELLO }
    Log.warn (Log.line (Catalog.HELLO, facts), facts)
end

-- Two builds that cannot speak to one another, as the one sentence both machines read it as.
local function mismatch (ours: Wide.Word, theirs: Wide.Word): (string, Log.Facts)
    local facts: Log.Facts =
        { code = Catalog.MISMATCH, ours = Wide.text (ours), theirs = Wide.text (theirs) }
    return Log.line (Catalog.MISMATCH, facts), facts
end

-- Public --------------------------------------------------------------

function Handshake.hello (ours: Wide.Word): buffer
    local out = buffer.create (HELLO)
    Wide.write (out, 0, ours)
    return out
end

-- The verdict a hello has earned, and whether the machine that sent it may be spoken to.
function Handshake.verdict (ours: Wide.Word, epoch: number, bytes: buffer): (buffer?, boolean)
    if buffer.len (bytes) ~= HELLO then
        unspoken ()
        return nil, false
    end

    local theirs = Wide.read (bytes, 0)
    local out = buffer.create (VERDICT)

    if Wide.same (theirs, ours) then
        buffer.writeu8 (out, 0, Protocol.VERDICT_ACCEPT)
        buffer.writef64 (out, FIELD, epoch)
        return out, true
    end

    Log.warn (mismatch (ours, theirs))

    buffer.writeu8 (out, 0, Protocol.VERDICT_REJECT)
    Wide.write (out, FIELD, ours)
    return out, false
end

--[[
    The namespace epoch, or nothing where what arrived was no verdict this build can read. A
    refusal is the third way out and never comes back: two builds that disagree cannot be made to
    agree at run time, so it raises where a message nobody can read only warns.
]]
function Handshake.judged (ours: Wide.Word, bytes: buffer): number?
    if buffer.len (bytes) ~= VERDICT then
        unspoken ()
        return nil
    end

    local said = buffer.readu8 (bytes, 0)
    if said == Protocol.VERDICT_ACCEPT then return buffer.readf64 (bytes, FIELD) end

    if said ~= Protocol.VERDICT_REJECT then
        unspoken ()
        return nil
    end

    return Log.error (mismatch (ours, Wide.read (bytes, FIELD)))
end

return table.freeze (Handshake)
