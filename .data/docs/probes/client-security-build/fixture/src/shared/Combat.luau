-- A namespace as a game would write it. The generator evaluates this file with a recording stand-in for Lync.
local Lync = require("./Lync")

return Lync.namespace({
	shoot = Lync.event({ target = Lync.integer(0, 65535), aim = Lync.vector3(-1024, 1024, 0.01), charge = Lync.number(0, 1, 1 / 255) }):unreliable(),
	hit = Lync.event({ target = Lync.integer(0, 65535), damage = Lync.integer(0, 1000) }),
	reload = Lync.event(),
	adminGrant = Lync.event({ userId = Lync.integer(0, 2 ^ 40), amount = Lync.integer(0, 1e6) }),
	inventory = Lync.request({ page = Lync.integer(0, 255) }, { items = Lync.array(Lync.string(32), 64) }),
})
