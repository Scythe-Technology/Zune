--!strict
local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local function testPassword(password: string, options: any?)
    local hash = crypto.password.hash(password, options);
    local hash2 = crypto.password.hash(password, options);
    test("Hash", function()
        -- Hashes should be different
        expect(hash).never.toBe(hash2);
        if (options) then
            expect(hash:sub(1, #options.algorithm + 2)).toBe(`${options.algorithm}$`);
        end
    end)
    test("Verification", function()
        expect(crypto.password.verify(password, hash)).toBe(true);
        expect(crypto.password.verify(password .. 'other', hash)).toBe(false);
    end)
end

describe("Password", function()
    describe("Default", function()
        testPassword("zune+luau")
    end)

    describe("Argon2i", function()
        testPassword("zune+luau", {algorithm = "argon2i"})
    end)
    describe("Argon2id", function()
        testPassword("zune+luau", {algorithm = "argon2id"})
    end)
    describe("Bcrypt", function()
        testPassword("zune+luau", {algorithm = "bcrypt"})
    end)

    test("Fail", function()
        expect(function()
            crypto.password.hash("blank", {
                algorithm = "argon2b",
            })
        end).toThrow("Invalid Algorithm");
        expect(function()
            crypto.password.hash("blank", {
                algorithm = "argon2d",
                timeCost = "0",
            })
        end).toThrow("Invalid 'timeCost' (Number expected)");
        expect(function()
            crypto.password.hash("blank", {
                algorithm = "bcrypt",
                cost = "0",
            })
        end).toThrow("Invalid 'cost' (Number expected)");
    end)
end)

return nil;