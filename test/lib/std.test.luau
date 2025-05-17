local testing = zune.testing;

local describe = testing.describe;

describe("@std", function()
    describe("Net", function()
        require("./std/net.test");
    end)
    describe("Mem", function()
        require("./std/mem.test");
    end)
    describe("Ansi", function()
        require("./std/ansi.test");
    end)
end)
