local testing = zune.testing;

local describe = testing.describe;

describe("@std", function()
    describe("Net", function()
        require("./std/net.test");
    end)
end)
