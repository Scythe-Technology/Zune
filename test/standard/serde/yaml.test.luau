--!strict
local serde = require("@zcore/serde");
local testing = require("@zcore/testing");

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Yaml", function()
    describe("Encoding", function()
        test("Number", function()
            expect(serde.yaml.encode(123)).toBe("123");
            expect(serde.yaml.encode(123.123)).toBe("123.123");
        end)
        test("String", function()
            expect(serde.yaml.encode("foo bar")).toBe(`"foo bar"`);
            expect(serde.yaml.encode("foobar")).toBe(`"foobar"`);
        end)
        test("Map", function()
            expect(serde.yaml.encode({a = 1, b = 2, c = 3}))
                .toBe("a: 1\nc: 3\nb: 2");
            expect(serde.yaml.encode({a = {b = {c = 3}}}))
                .toBe("a: \n    b: \n        c: 3");
            expect(serde.yaml.encode({a = {b = {}}}))
                .toBe("a: \n    b: \n");
        end)
    end)

    describe("Decoding", function()
        test("Number", function()
            expect(serde.yaml.decode("123")).toBe(123);
            expect(serde.yaml.decode("123.123")).toBe(123.123);
        end)
        test("String", function()
            expect(serde.yaml.decode("foo bar")).toBe("foo bar");
        end)
        test("Map", function()
            expect(serde.yaml.decode("a: 1\nb: 2\nc: 3")).toBe(expect.similar({
                a = 1,
                b = 2,
                c = 3
            }));
            expect(serde.yaml.decode("a:\n  b:\n    c: 3")).toBe(expect.similar({
                a = {
                    b = {
                        c = 3
                    }
                },
            }));
            expect(serde.yaml.decode("a:\n  b: []")).toBe(expect.similar({
                a = {
                    b = {}
                },
            }));
        end)
        test("List", function()
            expect(serde.yaml.decode("a: [1,2,3]")).toBe(expect.similar({
                a = {1,2,3}
            }));
            expect(serde.yaml.decode("a: [\"foo\"]")).toBe(expect.similar({
                a = { "foo" },
            }));
            expect(serde.yaml.decode("a:\n  b: []")).toBe(expect.similar({
                a = {
                    b = {}
                },
            }));
        end)
    end)
end)

return nil;
