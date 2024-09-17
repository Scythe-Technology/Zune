--!strict
local datetime = require("@zcore/datetime");
local testing = require("@zcore/testing");

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("DateTime", function()
    test("Now", function()
        local date = datetime.now();

        expect({
            UnixTimestamp = date.UnixTimestamp,
            UnixTimestampMillis = date.UnixTimestampMillis,
        }).toBe(expect.similar({
            UnixTimestamp = expect.type("number"),
            UnixTimestampMillis = expect.type("number"),
        }));
    end)

    describe("parse", function()
        test("GMT", function()
            local date = datetime.parse("04 Dec 1995 00:12:00 GMT");
    
            expect({
                UnixTimestamp = date.UnixTimestamp,
                UnixTimestampMillis = date.UnixTimestampMillis,
            }).toBe(expect.similar({
                UnixTimestamp = 818035920,
                UnixTimestampMillis = 818035920000,
            }));
        end)
        test("EST", function()
            local date = datetime.parse("04 Dec 1995 00:12:00 EST");
    
            expect({
                UnixTimestamp = date.UnixTimestamp,
                UnixTimestampMillis = date.UnixTimestampMillis,
            }).toBe(expect.similar({
                UnixTimestamp = 818053920,
                UnixTimestampMillis = 818053920000,
            }));
        end)
        test("GMT Long", function()
            local date = datetime.parse("Mon, 04 Dec 1995 00:12:00 GMT");
    
            expect({
                UnixTimestamp = date.UnixTimestamp,
                UnixTimestampMillis = date.UnixTimestampMillis,
            }).toBe(expect.similar({
                UnixTimestamp = 818035920,
                UnixTimestampMillis = 818035920000,
            }));
        end)
        test("EST Long", function()
            local date = datetime.parse("Mon, 04 Dec 1995 00:12:00 EST");
    
            expect({
                UnixTimestamp = date.UnixTimestamp,
                UnixTimestampMillis = date.UnixTimestampMillis,
            }).toBe(expect.similar({
                UnixTimestamp = 818053920,
                UnixTimestampMillis = 818053920000,
            }));
        end)
        test("ISO8601 UTC", function()
            local date = datetime.parse("1995-12-04T00:12:00Z");
    
            expect({
                UnixTimestamp = date.UnixTimestamp,
                UnixTimestampMillis = date.UnixTimestampMillis,
            }).toBe(expect.similar({
                UnixTimestamp = 818035920,
                UnixTimestampMillis = 818035920000,
            }));
        end)
    end)

    test("fromIsoDate", function()
        local date = datetime.fromIsoDate("1995-12-04T00:12:00Z");

        expect({
            UnixTimestamp = date.UnixTimestamp,
            UnixTimestampMillis = date.UnixTimestampMillis,
        }).toBe(expect.similar({
            UnixTimestamp = 818035920,
            UnixTimestampMillis = 818035920000,
        }));
    end)

    test("toLocalTime", function()
        local date = datetime.fromUnixTimestamp(818035920);

        expect(date:toLocalTime()).toBe(expect.similar({
            year = 1995,
            month = 12,
            day = expect.type("number"),
            hour = expect.type("number"),
            minute = expect.type("number"),
            second = 0,
            millisecond = 0,
        }));
    end)

    test("toUniversalTime", function()
        local date = datetime.fromUnixTimestamp(818035920);

        expect(date:toUniversalTime()).toBe(expect.similar({
            year = 1995,
            month = 12,
            day = 4,
            hour = 0,
            minute = 12,
            second = 0,
            millisecond = 0,
        }));

        local now = datetime.now();

        expect(now:toUniversalTime()).toBe(expect.similar({
            year = expect.type("number"),
            month = expect.type("number"),
            day = expect.type("number"),
            hour = expect.type("number"),
            minute = expect.type("number"),
            second = expect.type("number"),
            millisecond = expect.type("number"),
        }));
    end)

    describe("Format", function()
        test("toIsoDate", function()
            local date = datetime.fromUnixTimestamp(818035920);

            expect(date:toIsoDate()).toBe("1995-12-04T00:12:00Z");
        end)
        test("formatLocalTime", function()
            local date = datetime.fromUnixTimestamp(818035920);

            expect(date:formatLocalTime("%Y-%m-%d %H:%M:%S")).toBe(expect.type("string"));
        end)
        test("formatUniversalTime", function()
            local date = datetime.fromUnixTimestamp(818035920);

            expect(date:formatUniversalTime("%Y-%m-%d %H:%M:%S")).toBe("1995-12-04 00:12:00");
            expect(date:formatUniversalTime("%Y-%m-%d %H:%M:%S %z")).toBe("1995-12-04 00:12:00 +00:00");
            expect(date:formatUniversalTime("%T")).toBe("1995-12-04T00:12:00+00:00");
        end)
    end)

    describe("UnixTimestamp", function()
        test("Seconds", function()
            local date = datetime.fromUnixTimestamp(818035920);
    
            expect({
                UnixTimestamp = date.UnixTimestamp,
                UnixTimestampMillis = date.UnixTimestampMillis,
            }).toBe(expect.similar({
                UnixTimestamp = 818035920,
                UnixTimestampMillis = 818035920000,
            }));
        end)
        test("Milliseconds", function()
            local date = datetime.fromUnixTimestampMillis(818035920000);
    
            expect({
                UnixTimestamp = date.UnixTimestamp,
                UnixTimestampMillis = date.UnixTimestampMillis,
            }).toBe(expect.similar({
                UnixTimestamp = 818035920,
                UnixTimestampMillis = 818035920000,
            }));
        end)
    end)
end)
