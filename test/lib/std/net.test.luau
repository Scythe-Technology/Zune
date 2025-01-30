--!strict
local testing = zune.testing;

local describe = testing.describe;

describe("UDP", function()
    require("./net/udp.test");
end)

describe("TCP", function()
    require("./net/tcp.test");
end)

return nil;
