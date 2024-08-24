local testing = require("@zcore/testing");

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("CLI", function()
    test("Basic", function()
        expect(1).toBe(1);
    end)
end)
