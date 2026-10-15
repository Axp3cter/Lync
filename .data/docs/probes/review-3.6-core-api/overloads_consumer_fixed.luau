--!strict
local Net = require("./overloads_shard_fixed")
Net:field("f3"):derive({ fn = function() return 1 end, policy = "drop" })
Net:field("f1"):derive({ fn = function() return 1 end, policy = "drop" }) -- EXPECT error: f1 is vector
Net:field("nope") -- EXPECT error
