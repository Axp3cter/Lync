--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Reader = require(script.Parent.Parent.Parent.transport.Reader)
local Registry = require(script.Parent.Parent.Parent.internal.Registry)
local Runner = require(script.Parent.Parent.Runner)
local Signal = require(script.Parent.Parent.Parent.api.Signal)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("query request write+read", function(): ()
    local reqSig = Signal.create()
    local respSig = Signal.create()
    local reqReg, respReg =
        Registry.registerQueryPair("__qpipe1", Lync.u8, Lync.string, reqSig, respSig, nil, nil)

    it("request arrives through pipeline", function(): ()
        local ch = Channel.create()
        Channel.writeQuery(ch, reqReg.id, "__qpipe1:req", 1, Lync.u8, 42)
        local raw, refs = Channel.sealAndDump(ch)

        local got: any
        local conn = reqSig:connect(function(v: any): ()
            got = v
        end)
        Reader.process(raw, refs, nil, 0)
        expect(got):toBe(42)
        conn:disconnect()
    end)
end)

describe("query response write+read", function(): ()
    local reqSig = Signal.create()
    local respSig = Signal.create()
    local reqReg, respReg =
        Registry.registerQueryPair("__qpipe2", Lync.u8, Lync.string, reqSig, respSig, nil, nil)

    it("response arrives through pipeline", function(): ()
        local ch = Channel.create()
        Channel.writeQuery(ch, respReg.id, "__qpipe2:resp", 1, Lync.string, "hello")
        local raw, refs = Channel.sealAndDump(ch)

        local got: any
        local conn = respSig:connect(function(v: any): ()
            got = v
        end)
        Reader.process(raw, refs, nil, 0)
        expect(got):toBe("hello")
        conn:disconnect()
    end)
end)

return nil
