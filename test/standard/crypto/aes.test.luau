--!strict
local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("AES", function()
    describe("Aes128", function()
        test("Normal", function()
            local encrypted = crypto.aes.aes128.encrypt("zune+luau", "abcdefghijklmnop", "123456789012");
            expect(encrypted).toBe(expect.similar({
                cipher = "\xF1L\x8D\xD4MI\xE9\xAC\xFD",
                tag = "\xDB\x17\x10\xF8\xB6^\x0F\x8C\xBA\fA\xAEZ9\xF0\xA8",
            }));
            expect(crypto.aes.aes128.decrypt(encrypted.cipher, encrypted.tag, "abcdefghijklmnop", "123456789012")).toBe("zune+luau");

            local encrypted2 = crypto.aes.aes128.encrypt("runtime", "0000000000000000", "000000000000");
            expect(encrypted2).toBe(expect.similar({
                cipher = "\xFC\x02sm\x9C\x97\xF8",
                tag = "\xD74\x90\x9D\xA7\xEC\xD7|y\xFD\xB8\x9A\r\xB3\xDA\xA5",
            }));
            expect(crypto.aes.aes128.decrypt(encrypted2.cipher, encrypted2.tag, "0000000000000000", "000000000000")).toBe("runtime");
        end)
        test("Buffer", function()
            local key = buffer.create(16);
            local nonce = buffer.create(12);
            local encrypted = crypto.aes.aes128.encrypt("zune+luau", key, nonce);
            expect(encrypted).toBe(expect.similar({
                cipher = "y\xFD\xB4\xABK\xDA\xD6\xF3\x86",
                tag = "\xD6\xD7\xF8X\x88$q\x86$\xC0V54\x96\xA7<",
            }));
            expect(crypto.aes.aes128.decrypt(buffer.fromstring(encrypted.cipher), buffer.fromstring(encrypted.tag), key, nonce)).toBe("zune+luau");
        end)
    end)

    describe("Aes256", function()
        test("Normal", function()
            local encrypted = crypto.aes.aes256.encrypt("zune+luau", "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012");
            expect(encrypted).toBe(expect.similar({
                cipher = "\x84\x90\xF0\xCA\xDAp\xBF:[",
                tag = "\xC0K\xFAw[U\xDF\xA5i\xAA!\x8C\xD2\xC7\xF6k",
            }));
            expect(crypto.aes.aes256.decrypt(encrypted.cipher, encrypted.tag, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012")).toBe("zune+luau");

            local encrypted2 = crypto.aes.aes256.encrypt("runtime", "00000000000000000000000000000000", "000000000000");
            expect(encrypted2).toBe(expect.similar({
                cipher = "\xCB\xCA\xA9E\xCE\xE5\x91",
                tag = "\xB4\xB6\xF4\x93\xC5\xD6\x18\xDA\xC6y\x90\x0Ey.\xF4\xAC",
            }));
            expect(crypto.aes.aes256.decrypt(encrypted2.cipher, encrypted2.tag, "00000000000000000000000000000000", "000000000000")).toBe("runtime");
        end)
        test("Buffer", function()
            local key = buffer.create(32);
            local nonce = buffer.create(12);
            local encrypted = crypto.aes.aes256.encrypt("zune+luau", key, nonce);
            expect(encrypted).toBe(expect.similar({
                cipher = "\xB4\xD2.Xf\f\x1E\x0Fr",
                tag = "9\xC4\xF9h\xB1\xBAOH\n\x04\xB0\x25\x9B\xD8\x86T",
            }));
            expect(crypto.aes.aes256.decrypt(buffer.fromstring(encrypted.cipher), buffer.fromstring(encrypted.tag), key, nonce)).toBe("zune+luau");
        end)
    end)
end)

return nil;