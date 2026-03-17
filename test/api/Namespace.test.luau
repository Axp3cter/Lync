--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Registry = require (script.Parent.Parent.Parent.internal.Registry)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe ("Namespace.define", function (): ()
    it ("creates with packets", function (): ()
        expect (Lync.defineNamespace ("__ns01", { packets = { hp = { value = Lync.u8 } } })):toBeTruthy ()
    end)
    it ("creates empty", function (): ()
        expect (Lync.defineNamespace ("__ns02", {})):toBeTruthy ()
    end)
    it ("prefixes names", function (): ()
        Lync.defineNamespace ("__ns03", { packets = { dmg = { value = Lync.u8 } } })
        expect (Registry.getByName ("__ns03.dmg")):toBeTruthy ()
    end)
end)

describe ("Namespace validation", function (): ()
    it ("throws empty name", function (): ()
        expect (function (): ()
            Lync.defineNamespace ("", {})
        end):toThrow ()
    end)
    it ("throws duplicate", function (): ()
        Lync.defineNamespace ("__ns04", {})
        expect (function (): ()
            Lync.defineNamespace ("__ns04", {})
        end):toThrow ()
    end)
end)

describe ("Namespace disconnectAll", function (): ()
    it ("safe on empty", function (): ()
        Lync.defineNamespace ("__ns05", { packets = { x = { value = Lync.u8 } } }):disconnectAll ()
    end)
end)

return nil
