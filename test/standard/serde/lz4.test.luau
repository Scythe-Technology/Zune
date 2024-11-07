--!strict
local serde = zune.serde;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Lz4", function()
    local sample = string.rep([[
        Lorem ipsum dolor sit amet, consectetur adipiscing elit.
    ]], 20);
    local compressed_sample_default = "d\x05\x00\x00\x04\"M\x18d@\xA7P\x00\x00\x00\x13 \x01\x00\xF4*Lorem ipsum dolor sit amet, consectetur adipiscing elit.\nA\x00\x0FE\x00\xFF\xFF\xFF\xFF\xFF\bP\n    \x00\x00\x00\x00\xC0rE3";
    local compressed_sample_level0  = "d\x05\x00\x00\x04\"M\x18d@\xA7S\x00\x00\x00\x13 \x01\x00\xF3*Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n@\x00\x01\x02\x00\x0FE\x00\xFF\xFF\xFF\xFF\xFF\x04P\n    \x00\x00\x00\x00\xC0rE3";

    describe("Compression", function()
        test("Default", function()
            expect(serde.lz4.compress(sample)).toBe(compressed_sample_default);
        end)
        test("Buffer (Default)", function()
            local buf = serde.lz4.compress(buffer.fromstring(sample));
            expect(buf).toBe(expect.type("buffer"));
            expect(buffer.tostring(buf)).toBe(compressed_sample_default);
        end)
        test("Level 0", function()
            expect(serde.lz4.compress(sample, {level = 0})).toBe(compressed_sample_level0);
        end)
        test("Level 1", function()
            expect(serde.lz4.compress(sample, {level = 1})).toBe(compressed_sample_level0);
        end)
        test("Level 10", function()
            expect(serde.lz4.compress(sample, {level = 10})).toBe(compressed_sample_default);
        end)
        test("Level 50", function()
            expect(serde.lz4.compress(sample, {level = 50})).toBe(compressed_sample_default);
        end)
        test("Level 100", function()
            expect(serde.lz4.compress(sample, {level = 100})).toBe(compressed_sample_default);
        end)
        test("Level 1000", function()
            expect(serde.lz4.compress(sample, {level = 1000})).toBe(compressed_sample_default);
        end)
        test("Fail", function()
            expect(function() serde.lz4.compress(sample, {level = -1}) end).toThrow("Options 'level' must not be less than 0");
            expect(function() serde.gzip.compress(true) end).toThrow("invalid argument #1 to 'compress' (string expected, got boolean)");
        end)
    end)

    describe("Decompression", function()
        test("Default", function()
            expect(serde.lz4.decompress(compressed_sample_default)).toBe(sample);
        end)
        test("Buffer (Default)", function()
            local buf = serde.lz4.decompress(buffer.fromstring(compressed_sample_default));
            expect(buf).toBe(expect.type("buffer"));
            expect(buffer.tostring(buf)).toBe(sample);
        end)
        test("Level 0", function()
            expect(serde.lz4.decompress(compressed_sample_level0)).toBe(sample);
        end)
        test("Fail", function()
            expect(function() serde.lz4.decompress("\x01\x00\x00") end).toThrow("InvalidHeader");
        end)
    end)
end)

return nil;
