--!strict
local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("aes_gcm", function()
    describe("Aes128", function()
        test("Normal", function()
            local encrypted = crypto.aes_gcm.aes128.encrypt("zune+luau", "abcdefghijklmnop", "123456789012");
            expect(encrypted).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted.cipher)).toBe("\xF1L\x8D\xD4MI\xE9\xAC\xFD");
            expect(buffer.tostring(encrypted.tag)).toBe("\xDB\x17\x10\xF8\xB6^\x0F\x8C\xBA\fA\xAEZ9\xF0\xA8");
            expect(crypto.aes_gcm.aes128.decrypt(encrypted.cipher, encrypted.tag, "abcdefghijklmnop", "123456789012")).toBe("zune+luau");

            local encrypted2 = crypto.aes_gcm.aes128.encrypt("runtime", "0000000000000000", "000000000000");
            expect(encrypted2).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted2.cipher)).toBe("\xFC\x02sm\x9C\x97\xF8");
            expect(buffer.tostring(encrypted2.tag)).toBe("\xD74\x90\x9D\xA7\xEC\xD7|y\xFD\xB8\x9A\r\xB3\xDA\xA5");
            expect(crypto.aes_gcm.aes128.decrypt(encrypted2.cipher, encrypted2.tag, "0000000000000000", "000000000000")).toBe("runtime");
        end)
        test("With Associated Data", function()
            local encrypted = crypto.aes_gcm.aes128.encrypt("zune+luau", "abcdefghijklmnop", "123456789012", "Some Associated Data");
            expect(encrypted).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted.cipher)).toBe("\xF1L\x8D\xD4MI\xE9\xAC\xFD");
            expect(buffer.tostring(encrypted.tag)).toBe("\xCC\xBD5e\v`*0\x1C\xAF\xE1\xFB\x99\x0F\x25<");
            expect(crypto.aes_gcm.aes128.decrypt(encrypted.cipher, encrypted.tag, "abcdefghijklmnop", "123456789012", "Some Associated Data")).toBe("zune+luau");

            local encrypted2 = crypto.aes_gcm.aes128.encrypt("runtime", "0000000000000000", "000000000000", "Some Associated Data");
            expect(encrypted2).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted2.cipher)).toBe("\xFC\x02sm\x9C\x97\xF8");
            expect(buffer.tostring(encrypted2.tag)).toBe("\x8B\x91\xB5\xA52W\xBA\r\xD3\x82\x03\xA3\x15\x11\xCB\xB4");
            expect(crypto.aes_gcm.aes128.decrypt(encrypted2.cipher, encrypted2.tag, "0000000000000000", "000000000000", "Some Associated Data")).toBe("runtime");
            expect(function()
                crypto.aes_gcm.aes128.decrypt(encrypted2.cipher, encrypted2.tag, "0000000000000000", "000000000000");
            end).toThrow("AuthenticationFailed");
        end)
        test("Strings", function()
            local key = buffer.create(16);
            local nonce = buffer.create(12);
            local encrypted = crypto.aes_gcm.aes128.encrypt("zune+luau", key, nonce);
            expect(encrypted).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted.cipher)).toBe("y\xFD\xB4\xABK\xDA\xD6\xF3\x86");
            expect(buffer.tostring(encrypted.tag)).toBe("\xD6\xD7\xF8X\x88$q\x86$\xC0V54\x96\xA7<");
            expect(crypto.aes_gcm.aes128.decrypt(buffer.tostring(encrypted.cipher), buffer.tostring(encrypted.tag), key, nonce)).toBe("zune+luau");
        end)
    end)

    describe("Aes256", function()
        test("Normal", function()
            local encrypted = crypto.aes_gcm.aes256.encrypt("zune+luau", "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012");
            expect(encrypted).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted.cipher)).toBe("\x84\x90\xF0\xCA\xDAp\xBF:[");
            expect(buffer.tostring(encrypted.tag)).toBe("\xC0K\xFAw[U\xDF\xA5i\xAA!\x8C\xD2\xC7\xF6k");
            expect(crypto.aes_gcm.aes256.decrypt(encrypted.cipher, encrypted.tag, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012")).toBe("zune+luau");

            local encrypted2 = crypto.aes_gcm.aes256.encrypt("runtime", "00000000000000000000000000000000", "000000000000");
            expect(encrypted2).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted2.cipher)).toBe("\xCB\xCA\xA9E\xCE\xE5\x91");
            expect(buffer.tostring(encrypted2.tag)).toBe("\xB4\xB6\xF4\x93\xC5\xD6\x18\xDA\xC6y\x90\x0Ey.\xF4\xAC");
            expect(crypto.aes_gcm.aes256.decrypt(encrypted2.cipher, encrypted2.tag, "00000000000000000000000000000000", "000000000000")).toBe("runtime");
        end)
        test("With Associated Data", function()
            local encrypted = crypto.aes_gcm.aes256.encrypt("zune+luau", "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", "Some Associated Data");
            expect(encrypted).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted.cipher)).toBe("\x84\x90\xF0\xCA\xDAp\xBF:[");
            expect(buffer.tostring(encrypted.tag)).toBe("\xE0\x11\x98\xB3\xCC\xB8y\xB0\xA0\xB4;\xAF\xADY\xF0\xCE");
            expect(crypto.aes_gcm.aes256.decrypt(encrypted.cipher, encrypted.tag, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", "Some Associated Data")).toBe("zune+luau");

            local encrypted2 = crypto.aes_gcm.aes256.encrypt("runtime", "00000000000000000000000000000000", "000000000000", "Some Associated Data");
            expect(encrypted2).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted2.cipher)).toBe("\xCB\xCA\xA9E\xCE\xE5\x91");
            expect(buffer.tostring(encrypted2.tag)).toBe("\xD3\xB9\xD0\xFF\xFB\xF0\xC8\xD2\x8F\x85O\xFE\xEB\x9C-\xCF");
            expect(crypto.aes_gcm.aes256.decrypt(encrypted2.cipher, encrypted2.tag, "00000000000000000000000000000000", "000000000000", "Some Associated Data")).toBe("runtime");
        end)
        test("Strings", function()
            local key = buffer.create(32);
            local nonce = buffer.create(12);
            local encrypted = crypto.aes_gcm.aes256.encrypt("zune+luau", key, nonce);
            expect(encrypted).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted.cipher)).toBe("\xB4\xD2.Xf\f\x1E\x0Fr");
            expect(buffer.tostring(encrypted.tag)).toBe("9\xC4\xF9h\xB1\xBAOH\n\x04\xB0\x25\x9B\xD8\x86T");
            expect(crypto.aes_gcm.aes256.decrypt(buffer.tostring(encrypted.cipher), buffer.tostring(encrypted.tag), key, nonce)).toBe("zune+luau");
        end)
    end)
end)

describe("aes_ocb", function()
    describe("Aes128", function()
        test("Normal", function()
            local encrypted = crypto.aes_ocb.aes128.encrypt("zune+luau", "abcdefghijklmnop", "123456789012");
            expect(encrypted).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted.cipher)).toBe("\x8E,1\x95\xDF\xE8\xE6\x8A^");
            expect(buffer.tostring(encrypted.tag)).toBe("\xF6\n\xDE\xD0\x89\x03\xB4\x8F\xC9\x18R\x9B]\xE7\x99\xC9");
            expect(crypto.aes_ocb.aes128.decrypt(encrypted.cipher, encrypted.tag, "abcdefghijklmnop", "123456789012")).toBe("zune+luau");

            local encrypted2 = crypto.aes_ocb.aes128.encrypt("runtime", "0000000000000000", "000000000000");
            expect(encrypted2).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted2.cipher)).toBe("\x02o\xA8pI+\xCA");
            expect(buffer.tostring(encrypted2.tag)).toBe("\x87\xB4\aCt@\xC1\xC4\xAC\xD5\xECo\xBF\x91\x1C\x97");
            expect(crypto.aes_ocb.aes128.decrypt(encrypted2.cipher, encrypted2.tag, "0000000000000000", "000000000000")).toBe("runtime");
        end)
        test("With Associated Data", function()
            local encrypted = crypto.aes_ocb.aes128.encrypt("zune+luau", "abcdefghijklmnop", "123456789012", "Some Associated Data");
            expect(encrypted).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted.cipher)).toBe("\x8E,1\x95\xDF\xE8\xE6\x8A^");
            expect(buffer.tostring(encrypted.tag)).toBe("\x1A\a\x05\x97\xA107C\xC6X\xB9\xC0\xC3{\xD4\x93");
            expect(crypto.aes_ocb.aes128.decrypt(encrypted.cipher, encrypted.tag, "abcdefghijklmnop", "123456789012", "Some Associated Data")).toBe("zune+luau");

            local encrypted2 = crypto.aes_ocb.aes128.encrypt("runtime", "0000000000000000", "000000000000", "Some Associated Data");
            expect(encrypted2).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted2.cipher)).toBe("\x02o\xA8pI+\xCA");
            expect(buffer.tostring(encrypted2.tag)).toBe("\xC7\xA1\xB79\x99H\x88qD\x10Q\xAB-\x88@\x25");
            expect(crypto.aes_ocb.aes128.decrypt(encrypted2.cipher, encrypted2.tag, "0000000000000000", "000000000000", "Some Associated Data")).toBe("runtime");
            expect(function()
                crypto.aes_ocb.aes128.decrypt(encrypted2.cipher, encrypted2.tag, "0000000000000000", "000000000000");
            end).toThrow("AuthenticationFailed");
        end)
        test("Strings", function()
            local key = buffer.create(16);
            local nonce = buffer.create(12);
            local encrypted = crypto.aes_ocb.aes128.encrypt("zune+luau", key, nonce);
            expect(encrypted).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted.cipher)).toBe("\x01\xA7nyM\xA6\x12<\xD5");
            expect(buffer.tostring(encrypted.tag)).toBe("\xC1\n\x89[\xEA\xB4\xA6\x92\xB8\xE0\r:\x15x2\x00");
            expect(crypto.aes_ocb.aes128.decrypt(buffer.tostring(encrypted.cipher), buffer.tostring(encrypted.tag), key, nonce)).toBe("zune+luau");
        end)
    end)

    describe("Aes256", function()
        test("Normal", function()
            local encrypted = crypto.aes_ocb.aes256.encrypt("zune+luau", "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012");
            expect(encrypted).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted.cipher)).toBe("\xA5\xF9\xF4\x056\x1A\xCD\xD2\xA5");
            expect(buffer.tostring(encrypted.tag)).toBe("\x9B\xBD\xB0\xF7C\x1C\xC6\x8DZ\xCE\n\xA7\xC9\xC1\xDA\xC4");
            expect(crypto.aes_ocb.aes256.decrypt(encrypted.cipher, encrypted.tag, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012")).toBe("zune+luau");

            local encrypted2 = crypto.aes_ocb.aes256.encrypt("runtime", "00000000000000000000000000000000", "000000000000");
            expect(encrypted2).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted2.cipher)).toBe("\b\a\xA0\x05$\xC2\\");
            expect(buffer.tostring(encrypted2.tag)).toBe("\xA8&\xF4\xED\x1B\x1C\xCFR\xE5\xEF\x17:Q\t\x88\xFB");
            expect(crypto.aes_ocb.aes256.decrypt(encrypted2.cipher, encrypted2.tag, "00000000000000000000000000000000", "000000000000")).toBe("runtime");
        end)
        test("With Associated Data", function()
            local encrypted = crypto.aes_ocb.aes256.encrypt("zune+luau", "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", "Some Associated Data");
            expect(encrypted).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted.cipher)).toBe("\xA5\xF9\xF4\x056\x1A\xCD\xD2\xA5");
            expect(buffer.tostring(encrypted.tag)).toBe("\xC7j\x82\xFE\x181\xA3\x13i\x96\xFD\xBD\x9F\xAA\x1F\xCD");
            expect(crypto.aes_ocb.aes256.decrypt(encrypted.cipher, encrypted.tag, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", "Some Associated Data")).toBe("zune+luau");

            local encrypted2 = crypto.aes_ocb.aes256.encrypt("runtime", "00000000000000000000000000000000", "000000000000", "Some Associated Data");
            expect(encrypted2).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted2.cipher)).toBe("\b\a\xA0\x05$\xC2\\");
            expect(buffer.tostring(encrypted2.tag)).toBe("y\x88qz\x04\xCD\xA29\xA1\x1E}3zl\xAA\xBE");
            expect(crypto.aes_ocb.aes256.decrypt(encrypted2.cipher, encrypted2.tag, "00000000000000000000000000000000", "000000000000", "Some Associated Data")).toBe("runtime");
        end)
        test("Strings", function()
            local key = buffer.create(32);
            local nonce = buffer.create(12);
            local encrypted = crypto.aes_ocb.aes256.encrypt("zune+luau", key, nonce);
            expect(encrypted).toBe(expect.similar({
                cipher = expect.type("buffer"),
                tag = expect.type("buffer"),
            }));
            expect(buffer.tostring(encrypted.cipher)).toBe(":\x82\x04\xCCh\x98\xD3\xBF\x8D");
            expect(buffer.tostring(encrypted.tag)).toBe("T\xD3\xFC\x0E\xC2I!$\x87 \xFA\xC9\xA4\xA2H\x00");
            expect(crypto.aes_ocb.aes256.decrypt(buffer.tostring(encrypted.cipher), buffer.tostring(encrypted.tag), key, nonce)).toBe("zune+luau");
        end)
    end)
end)

return nil;