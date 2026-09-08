--!strict
--!optimize 2
-- The remote folder: where a namespace's lanes sit, held apart from where the library sits.

local Transport = require("@src/channel/Transport")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

-- What default.project.json mounts the library as, which is the name a remote folder must not
-- share, or the server parents its remotes inside the module and the client finds them by luck.
local MOUNTED = "Lync"

return {
    Harness.case("transport.folder-is-not-the-module", function()
        Expect.holds(Transport.FOLDER ~= MOUNTED, `the remotes folder is named {Transport.FOLDER}`)
        Expect.holds(#Transport.FOLDER > 0, "the remotes folder has no name")
    end),

    -- An endpoint is made without touching the engine, so a namespace can compile before start.
    Harness.case("transport.new-touches-nothing", function()
        local of = Transport.new("probe", "server")
        for _, name in { "open", "fire", "onReceive", "close" } do
            Expect.equal(typeof((of :: any)[name]), "function")
        end
    end),
}
