--!strict
local regex = require("@zcore/regex");
local testing = require("@zcore/testing");

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Regex", function()
    test("match", function()
        local re = regex.new("a(b+)c");

        expect(re:match("abbc")).toBe(expect.similar({
            {
                string = "abbc",
                index = 0,
            },
            {
                string = "bb",
                index = 1,
            },
        }));

        expect(re:match("  abbc")).toBeNil();
    end)

    test("search", function()
        local re = regex.new("a(b+)c");

        expect(re:search("abbc")).toBe(expect.similar({
            {
                string = "abbc",
                index = 0,
            },
            {
                string = "bb",
                index = 1,
            },
        }));

        expect(re:search("  abbc")).toBe(expect.similar({
            {
                string = "abbc",
                index = 2,
            },
            {
                string = "bb",
                index = 3,
            },
        }));
    end)

    test("isMatch", function()
        local re = regex.new("a(b+)c");

        expect(re:isMatch("abbc")).toBe(true);
        expect(re:isMatch("  abbc")).toBe(false);
        expect(re:isMatch("abc")).toBe(true);
    end)

    test("Format", function()
        local re = regex.new("(b+)");

        expect(re:format("abbc", "1=$1")).toBe("1=bb");
    end)

    test("Replace", function()
        local re = regex.new("b+");

        expect(re:replace("abbc", "")).toBe("ac");
        expect(re:replace("  abbc", "")).toBe("  ac");
        expect(re:replace("abc", "bb")).toBe("abbc");
        expect(re:replace("abc abc", "bb")).toBe("abbc abc");
    end)

    test("ReplaceAll", function()
        local re = regex.new("b+");

        expect(re:replaceAll("abbc", "")).toBe("ac");
        expect(re:replaceAll("  abbc", "")).toBe("  ac");
        expect(re:replaceAll("abc", "bb")).toBe("abbc");
        expect(re:replaceAll("abc abc", "bb")).toBe("abbc abbc");
    end)
end)
