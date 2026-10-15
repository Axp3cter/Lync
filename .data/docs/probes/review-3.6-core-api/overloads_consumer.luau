--!strict
local Net = require("./overloads_32")
Net:field("f3"):derive({ fn = function() return 1 end, policy = "drop" })
Net:field("f1"):derive({ fn = function() return 1 end, policy = "drop" }) -- EXPECT error: f1 is vector
Net:field("nope") -- EXPECT error
