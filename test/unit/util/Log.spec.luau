--!strict
--!optimize 2
-- util.Log: warn (silenceable), error, assert + [Lync] file:line (func) prefix.

local Env = require(script:FindFirstAncestor("test").Env)

local Log = Env.Internal.Log
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

--[[
    Helper: capture the message Log.error throws by pcall'ing it. Returns the
    string error message (or nil if no throw).
]]
local function captureError(fn: () -> ()): string?
    local ok, err = pcall(fn)
    if ok then
        return nil
    end
    return tostring(err)
end

describe("util.Log", function(): ()
    beforeEach(function(): ()
        Sandbox.resetAll()
        Log.reset()
    end)

    describe("module shape", function(): ()
        it("Log is a frozen table", function(): ()
            expect(Log):toBeFrozen()
        end)
        it("exposes warn", function(): ()
            expect(Log.warn):toBeType("function")
        end)
        it("exposes error", function(): ()
            expect(Log.error):toBeType("function")
        end)
        it("exposes assert", function(): ()
            expect(Log.assert):toBeType("function")
        end)
        it("exposes setSilent", function(): ()
            expect(Log.setSilent):toBeType("function")
        end)
        it("exposes reset", function(): ()
            expect(Log.reset):toBeType("function")
        end)
    end)

    describe("Log.error", function(): ()
        it("throws when called", function(): ()
            expect(function(): ()
                Log.error("boom")
            end):toThrow()
        end)
        it("error message contains [Lync] prefix", function(): ()
            local msg = captureError(function(): ()
                Log.error("boom")
            end)
            expect(msg).never:toBe(nil)
            expect((msg :: string):find("[Lync]", 1, true) ~= nil):toBe(true)
        end)
        it("error message contains the user-supplied content", function(): ()
            local msg = captureError(function(): ()
                Log.error("specific phrase")
            end)
            expect((msg :: string):find("specific phrase", 1, true) ~= nil):toBe(true)
        end)
        it("error message contains a colon (file:line marker)", function(): ()
            local msg = captureError(function(): ()
                Log.error("x")
            end)
            -- Format: [Lync] Filename:Line ... or [Lync] Filename:Line (func) ...
            expect((msg :: string):find(":%d") ~= nil):toBe(true)
        end)
        it("level=2 means the runtime location prefix points at the caller", function(): ()
            -- The Lua VM prefixes errors with "<source>:<line>: ". With level=2,
            -- that points at the caller's line, not Log.luau.
            local msg = captureError(function(): ()
                Log.error("trace check")
            end)
            expect((msg :: string):find("Log%.spec") ~= nil):toBe(true)
        end)
        it("interpolated message preserves all args verbatim", function(): ()
            local n = 42
            local msg = captureError(function(): ()
                Log.error(`got value {n}`)
            end)
            expect((msg :: string):find("got value 42", 1, true) ~= nil):toBe(true)
        end)
    end)

    describe("Log.assert: truthy condition", function(): ()
        it("does not throw when cond is true", function(): ()
            expect(function(): ()
                Log.assert(true, "should not see")
            end).never:toThrow()
        end)
        it("does not throw when cond is a non-empty string", function(): ()
            expect(function(): ()
                Log.assert("x", "should not see")
            end).never:toThrow()
        end)
        it("does not throw when cond is 0 (truthy in Luau)", function(): ()
            expect(function(): ()
                Log.assert(0, "should not see")
            end).never:toThrow()
        end)
        it("does not throw when cond is empty string (truthy in Luau)", function(): ()
            expect(function(): ()
                Log.assert("", "should not see")
            end).never:toThrow()
        end)
        it("does not throw when cond is empty table", function(): ()
            expect(function(): ()
                Log.assert({}, "should not see")
            end).never:toThrow()
        end)
        it("returns the cond value on success (true)", function(): ()
            expect(Log.assert(true, "x")):toBe(true)
        end)
        it("returns the cond value on success (number)", function(): ()
            expect(Log.assert(42, "x")):toBe(42)
        end)
        it("returns the cond value on success (string)", function(): ()
            expect(Log.assert("hello", "x")):toBe("hello")
        end)
    end)

    describe("Log.assert: falsy condition", function(): ()
        it("throws when cond is false", function(): ()
            expect(function(): ()
                Log.assert(false, "explicit false")
            end):toThrow()
        end)
        it("throws when cond is nil", function(): ()
            expect(function(): ()
                Log.assert(nil, "nil cond")
            end):toThrow()
        end)
        it("error message contains [Lync] prefix on failure", function(): ()
            local msg = captureError(function(): ()
                Log.assert(false, "asserted")
            end)
            expect((msg :: string):find("[Lync]", 1, true) ~= nil):toBe(true)
        end)
        it("error message contains the user-supplied content on failure", function(): ()
            local msg = captureError(function(): ()
                Log.assert(false, "carry through")
            end)
            expect((msg :: string):find("carry through", 1, true) ~= nil):toBe(true)
        end)
    end)

    describe("Log.warn silenceable", function(): ()
        --[[
            All three branches assert "no throw"; we keep Log silenced
            throughout so the spec doesn't pollute the test output. There
            is no public introspection on the flag, so we can only verify
            the no-throw contract here.
        ]]
        it("setSilent(true) suppresses the underlying warn", function(): ()
            Log.setSilent(true)
            expect(function(): ()
                Log.warn("suppressed")
            end).never:toThrow()
        end)
        it("setSilent(false) does not throw", function(): ()
            Log.setSilent(true)
            Log.setSilent(false)
            Log.setSilent(true) -- re-silence before the warn that follows
            expect(function(): ()
                Log.warn("post-setSilent")
            end).never:toThrow()
        end)
        it("reset clears silent state without throwing", function(): ()
            Log.setSilent(true)
            Log.reset()
            Log.setSilent(true) -- re-silence after reset
            expect(function(): ()
                Log.warn("post-reset")
            end).never:toThrow()
        end)
    end)

    describe("format derivation", function(): ()
        --[[
            All format detail tests funnel through Log.error since it's the
            cleanest way to capture the actual emitted string. The same
            format() helper drives Log.warn and Log.assert.
        ]]
        it("source tail is just the filename, not the full Roblox dotted path", function(): ()
            local msg = captureError(function(): ()
                Log.error("path tail check")
            end)
            -- Should NOT contain "ServerScriptService" or other ancestor segments
            -- in the [Lync ...] portion (the runtime prefix may, but our tag is tight).
            local prefixStart = (msg :: string):find("[Lync]", 1, true) :: number
            local lyncPrefix = (msg :: string):sub(prefixStart, prefixStart + 60)
            expect(lyncPrefix:find("ServerScriptService", 1, true) == nil):toBe(true)
        end)
        it("file:line are concrete (no nil substitution)", function(): ()
            local msg = captureError(function(): ()
                Log.error("concrete check")
            end)
            -- After "[Lync] " we expect Word:Number, never "nil:nil".
            expect((msg :: string):find("nil:nil", 1, true) == nil):toBe(true)
        end)
    end)
end)

return nil
