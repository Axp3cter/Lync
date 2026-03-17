--!strict
--!native
-- Discriminated union codec. u8 variant tag + variant payload.

local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

-- Public -----------------------------------------------------------------

local Tagged = {}

-- Read injects data[tagField] = variantName into the decoded table.
-- Variant codecs must return a mutable table (not frozen).
function Tagged.define (tagField: string, variants: { [string]: Codec<any> }): Codec<any>
    if #tagField == 0 then
        error ("[Lync] Tagged union tagField must not be empty")
    end

    local names = {} :: { string }
    for name in variants do
        if #name == 0 then
            error ("[Lync] Tagged union variant name must not be empty")
        end
        table.insert (names, name)
    end
    table.sort (names)

    local count = #names
    if count == 0 then
        error ("[Lync] Tagged union requires at least one variant")
    end
    if count > 256 then
        error (`[Lync] Tagged union exceeds 256 variants: {count}`)
    end

    local nameToTag = {} :: { [string]: number }
    local tagCodecs = table.create (count) :: { Codec<any> }
    local tagNames = table.create (count) :: { string }
    local tagSizes = table.create (count) :: { number? }

    -- Probe for direct dispatch
    local allDirect = true
    local uniformSize: number? = (variants[names[1]] :: any)._size
    local directWrites = table.create (count) :: { any }
    local directReads = table.create (count) :: { any }

    for i, name in names do
        local codec = variants[name] :: any
        nameToTag[name] = i
        tagCodecs[i] = codec
        tagNames[i] = name

        local size = codec._size
        tagSizes[i] = size

        if size ~= uniformSize then
            uniformSize = nil
        end

        local dw = codec._directWrite
        local dr = codec._directRead
        if dw and dr and size then
            directWrites[i] = dw
            directReads[i] = dr
        else
            allDirect = false
        end
    end

    table.freeze (nameToTag)
    table.freeze (tagCodecs)
    table.freeze (tagNames)
    table.freeze (tagSizes)

    local fixedSize: number? = if uniformSize then 1 + uniformSize else nil

    -- Specialized path: all variants have direct + known size
    if allDirect then
        table.freeze (directWrites)
        table.freeze (directReads)

        -- If uniform size, expose _directWrite/_directRead for parent struct/array
        if fixedSize then
            local variantBytes = uniformSize :: number

            return table.freeze ({
                _size = fixedSize,
                _directWrite = function (b: buffer, offset: number, value: any): ()
                    local tag = nameToTag[value[tagField]]
                    if not tag then
                        error (`[Lync] Unknown variant: {value[tagField]}`)
                    end
                    buffer.writeu8 (b, offset, tag - 1)
                    directWrites[tag] (b, offset + 1, value)
                end,
                _directRead = function (b: buffer, offset: number): any
                    local tag = buffer.readu8 (b, offset) + 1
                    local name = tagNames[tag]
                    if not name then
                        error (`[Lync] Unknown variant index: {tag - 1}`)
                    end
                    local data = directReads[tag] (b, offset + 1)
                    if type (data) == "table" then
                        data[tagField] = name
                    end
                    return data
                end,
                write = function (ch: ChannelState, value: any): ()
                    local tag = nameToTag[value[tagField]]
                    if not tag then
                        error (`[Lync] Unknown variant: {value[tagField]}`)
                    end
                    local c = ch.cursor
                    if c + (fixedSize :: number) > ch.size then
                        alloc (ch, fixedSize :: number)
                    end
                    local b = ch.buff
                    buffer.writeu8 (b, c, tag - 1)
                    directWrites[tag] (b, c + 1, value)
                    ch.cursor = c + (fixedSize :: number)
                end,
                read = function (src: buffer, pos: number, _refs: { Instance }?): (any, number)
                    local tag = buffer.readu8 (src, pos) + 1
                    local name = tagNames[tag]
                    if not name then
                        error (`[Lync] Unknown variant index: {tag - 1}`)
                    end
                    local data = directReads[tag] (src, pos + 1)
                    if type (data) == "table" then
                        data[tagField] = name
                    end
                    return data, fixedSize :: number
                end,
            })
        end

        -- Non-uniform sizes but all have direct: use direct dispatch internally
        local fieldSizes = table.clone (tagSizes) :: { number }
        table.freeze (fieldSizes)

        return table.freeze ({
            _size = nil,
            write = function (ch: ChannelState, value: any): ()
                local tag = nameToTag[value[tagField]]
                if not tag then
                    error (`[Lync] Unknown variant: {value[tagField]}`)
                end
                local varSize = fieldSizes[tag]
                local totalNeeded = 1 + varSize
                local c = ch.cursor
                if c + totalNeeded > ch.size then
                    alloc (ch, totalNeeded)
                end
                local b = ch.buff
                buffer.writeu8 (b, c, tag - 1)
                directWrites[tag] (b, c + 1, value)
                ch.cursor = c + totalNeeded
            end,
            read = function (src: buffer, pos: number, _refs: { Instance }?): (any, number)
                local tag = buffer.readu8 (src, pos) + 1
                local name = tagNames[tag]
                if not name then
                    error (`[Lync] Unknown variant index: {tag - 1}`)
                end
                local data = directReads[tag] (src, pos + 1)
                if type (data) == "table" then
                    data[tagField] = name
                end
                return data, 1 + fieldSizes[tag]
            end,
        })
    end

    -- Generic fallback: extract write/read into parallel arrays
    local writeFns = table.create (count) :: { any }
    local readFns = table.create (count) :: { any }
    for i = 1, count do
        writeFns[i] = tagCodecs[i].write
        readFns[i] = tagCodecs[i].read
    end
    table.freeze (writeFns)
    table.freeze (readFns)

    return table.freeze ({
        _size = fixedSize,
        write = function (ch: ChannelState, value: any): ()
            local tag = nameToTag[value[tagField]]
            if not tag then
                error (`[Lync] Unknown variant: {value[tagField]}`)
            end

            local variantSize = tagSizes[tag]
            if variantSize then
                alloc (ch, 1 + variantSize)
            else
                alloc (ch, 1)
            end

            local c = ch.cursor
            buffer.writeu8 (ch.buff, c, tag - 1)
            ch.cursor = c + 1
            writeFns[tag] (ch, value)
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): (any, number)
            local tag = buffer.readu8 (src, pos) + 1
            local name = tagNames[tag]
            if not name then
                error (`[Lync] Unknown variant index: {tag - 1}`)
            end

            local data, bytes = readFns[tag] (src, pos + 1, refs)

            if type (data) == "table" then
                data[tagField] = name
            end

            return data, 1 + bytes
        end,
    })
end

return table.freeze (Tagged)
