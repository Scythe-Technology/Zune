--!strict
local testing = zune.testing;

local describe = testing.describe;

local _, version, _ = string.match(_VERSION, "(Zune) (%d+%.%d+%.%d+.*)+(%d+%.%d+)");
assert(version and #version > 0, "No version");

describe("Server", function()
    require("./http/server.test");
end)

describe("Requests", function()
    require("./http/request.test");
end)

describe("WebSockets", function()
    require("./http/websocket.test");
end)
