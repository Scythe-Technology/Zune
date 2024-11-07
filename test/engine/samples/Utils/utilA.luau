local utilB = require("./utilB");

local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("utilB", function()
	test("Validating", function()
		expect(utilB).toBeNil();
	end)
end)

describe("utilA", function()
	test("Validating Context", function()
		expect(_FILE).never.toBeNil();
		expect(_FILE.name:find("utilA%.luau")).never.toBeNil();
	end)
end)

local util = {};

return util;