--!strict
--!optimize 2
-- Round-trip helpers that drive a fresh channel through write/read for a codec.

local Lync = script.Parent.Parent.Parent

local InternalChannel = require(Lync.internal.Channel)

-- Public types -----------------------------------------------------------

export type EncodeResult = {
    buffer: buffer,
    length: number,
    refs: { Instance },
    refCount: number,
}

-- Public -----------------------------------------------------------------

local Helpers = {}

--[[
    Encode `value` through `codec` into a fresh channel. Returns the
    resulting buffer (sized exactly to the written cursor), the byte
    length, the refs sidecar, and the ref count.
]]
function Helpers.encode(codec: any, value: any): EncodeResult
    local ch = InternalChannel.create()
    codec.write(ch, value)
    local len = ch.cursor
    local out = buffer.create(len)
    if len > 0 then
        buffer.copy(out, 0, ch.buff, 0, len)
    end
    local refs = if ch.refCount > 0 then table.clone(ch.refs) else {}
    return {
        buffer = out,
        length = len,
        refs = refs,
        refCount = ch.refCount,
    }
end

--[[
    Decode `value` from `result.buffer` using `codec`. Returns the decoded
    value and the consumed byte count. Pulls refs from the encode result so
    Instance and Unknown codecs work.
]]
function Helpers.decode(codec: any, result: EncodeResult): (any, number)
    local value, consumed = codec.read(result.buffer, 0, result.refs)
    return value, consumed
end

--[[
    Full round-trip: encode then decode. Returns
    (decodedValue, writtenBytes, consumedBytes, encodeResult).
    Tests can compare written and consumed independently rather than
    asserting equality inside the helper.
]]
function Helpers.roundTrip(codec: any, value: any): (any, number, number, EncodeResult)
    local result = Helpers.encode(codec, value)
    local decoded, consumed = Helpers.decode(codec, result)
    return decoded, result.length, consumed, result
end

--[[
    Round-trip with strict equality between written and consumed. Throws
    if they diverge so the failure surfaces inside the test rather than
    being swallowed.
]]
function Helpers.roundTripStrict(codec: any, value: any): (any, number)
    local decoded, written, consumed, _ = Helpers.roundTrip(codec, value)
    if written ~= consumed then
        error(`[Helpers.roundTripStrict] wrote {written} bytes, consumed {consumed}`)
    end
    return decoded, written
end

--[[
    Encode N copies of `value` through the same channel state. Tests the
    multi-fire batching path. Returns the same shape as encode().
]]
function Helpers.encodeMany(codec: any, values: { any }): EncodeResult
    local ch = InternalChannel.create()
    for _, v in values do
        codec.write(ch, v)
    end
    local len = ch.cursor
    local out = buffer.create(len)
    if len > 0 then
        buffer.copy(out, 0, ch.buff, 0, len)
    end
    local refs = if ch.refCount > 0 then table.clone(ch.refs) else {}
    return {
        buffer = out,
        length = len,
        refs = refs,
        refCount = ch.refCount,
    }
end

--[[
    Bypass the codec entirely; build an EncodeResult from raw bytes.
    Useful for adversarial tests that craft malformed input.
]]
function Helpers.fromBytes(bytes: { number }, refs: { Instance }?): EncodeResult
    local len = #bytes
    local b = buffer.create(len)
    for i = 1, len do
        buffer.writeu8(b, i - 1, bytes[i])
    end
    return {
        buffer = b,
        length = len,
        refs = refs or {},
        refCount = if refs then #refs else 0,
    }
end

return table.freeze(Helpers)
