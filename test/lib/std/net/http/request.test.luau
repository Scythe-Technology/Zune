--!strict
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local mem = require("@std/mem");

local Request = require("@std/net/http/request");

local function createMockParser(sample: string): (Request.Parser, buffer)
    local parser: Request.Parser = {
        pos = 0,
        size = #sample,
        state = {
            recv_more = false,
            headers_incomplete = false,
            headers_count = 0,
        },
    };
    return parser, buffer.fromstring(sample);
end

local function createTestParser(sample: string, handle, ...): () -> ()
    local parser, buf = createMockParser(sample);
    local args = {...};
    return function()
        return handle(parser, buf, unpack(args));
    end
end

describe("Parser", function()
    describe("Method", function()
        test("Parse", function()
            local function testMethod(method: string, pos: number)
                local parser, buf = createMockParser(method .. " ");
                Request.parseMethod(parser, buf);
                expect(parser.method).toBe(method);
                expect(parser.pos).toBe(pos);
            end
            testMethod("GET", 4);
            testMethod("PUT", 4);
            testMethod("POST", 5);
            testMethod("HEAD", 5);
            testMethod("PATCH", 6);
            testMethod("DELETE", 7);
            testMethod("OPTIONS", 8);
        end)
        test("Fail", function()
            expect(createTestParser("INVALID ", Request.parseMethod)).toThrow("InvalidMethod");
            expect(createTestParser("POST", Request.parseMethod)).toThrow("TooSmall");
            expect(createTestParser("POSTA", Request.parseMethod)).toThrow("InvalidMethod");
            expect(createTestParser("HEAD", Request.parseMethod)).toThrow("TooSmall");
            expect(createTestParser("HEAD\1", Request.parseMethod)).toThrow("InvalidMethod");
            expect(createTestParser("PATC", Request.parseMethod)).toThrow("TooSmall");
            expect(createTestParser("PATCH", Request.parseMethod)).toThrow("TooSmall");
            expect(createTestParser("PATCHA", Request.parseMethod)).toThrow("InvalidMethod");
            expect(createTestParser("PATCB ", Request.parseMethod)).toThrow("InvalidMethod");
            expect(createTestParser("DELE ", Request.parseMethod)).toThrow("TooSmall");
            expect(createTestParser("DELETE", Request.parseMethod)).toThrow("TooSmall");
            expect(createTestParser("DELETB ", Request.parseMethod)).toThrow("InvalidMethod");
            expect(createTestParser("OPTI", Request.parseMethod)).toThrow("TooSmall");
            expect(createTestParser("OPTIONS", Request.parseMethod)).toThrow("TooSmall");
            expect(createTestParser("OPTIONC ", Request.parseMethod)).toThrow("InvalidMethod");
        end)
    end)
    describe("Uri", function()
        test("Parse", function()
            local function testParse(uri: string, pos: number)
                local parser, buf = createMockParser(uri);
                Request.parseUri(parser, buf, 256);
                expect(parser.uri).toBe(uri:match("^[^%s]*"));
                expect(parser.pos).toBe(pos);
            end
            testParse("/ ", 2);
            testParse("* ", 2);
            testParse("/path ", 6);
            testParse("/path?query ", 12);
            testParse("/path?query#frag ", 17);
            testParse("/path?query#frag ", 17);
            testParse("/path?query#frag Some/Data", 17);
            testParse("* A", 2);
        end)
        test("Fail", function()
            expect(createTestParser("", Request.parseUri, 256)).toThrow("TooSmall");
            expect(createTestParser(" ", Request.parseUri, 256)).toThrow("TooSmall");
            expect(createTestParser("A", Request.parseUri, 256)).toThrow("TooSmall");
            expect(createTestParser("A B", Request.parseUri, 256)).toThrow("InvalidUri");
            expect(createTestParser("*", Request.parseUri, 256)).toThrow("TooSmall");
            expect(createTestParser("*/", Request.parseUri, 256)).toThrow("InvalidUri");
            expect(createTestParser("/", Request.parseUri, 256)).toThrow("TooSmall");
            expect(createTestParser("/path", Request.parseUri, 256)).toThrow("TooSmall");
            expect(createTestParser("/path\2 ", Request.parseUri, 256)).toThrow("InvalidUri");
        end)
    end)
    describe("Protocol", function()
        test("Parse", function()
            local function testParse(data: string, pos: number)
                local parser, buf = createMockParser(data);
                Request.parseProtocol(parser, buf);
                expect(parser.protocol).toBe(data:match("^[^%s]*"));
                expect(parser.pos).toBe(pos);
            end
            testParse("HTTP/1.0\r\n", 10);
            testParse("HTTP/1.1\r\n", 10);
            testParse("HTTP/1.0\r\n  ", 10);
            testParse("HTTP/1.1\r\n  ", 10);
        end)
        test("Fail", function()
            expect(createTestParser("", Request.parseProtocol)).toThrow("TooSmall");
            expect(createTestParser(" ", Request.parseProtocol)).toThrow("TooSmall");
            expect(createTestParser("AAAAAAAAA", Request.parseProtocol)).toThrow("TooSmall");
            expect(createTestParser("AAAAAAAAAA", Request.parseProtocol)).toThrow("InvalidProtocol");
            expect(createTestParser("HTTP/1.0", Request.parseProtocol)).toThrow("TooSmall");
            expect(createTestParser("HTTP/1.0\n\n", Request.parseProtocol)).toThrow("InvalidProtocol");
            expect(createTestParser("HTTP/1.0AB", Request.parseProtocol)).toThrow("InvalidProtocol");
            expect(createTestParser("HTTP/1.1", Request.parseProtocol)).toThrow("TooSmall");
            expect(createTestParser("HTTP/1.1\n\n", Request.parseProtocol)).toThrow("InvalidProtocol");
            expect(createTestParser("HTTP/1.1AB", Request.parseProtocol)).toThrow("InvalidProtocol");
        end)
    end)
    describe("Headers", function()
        test("Parse", function()
            local function testParse(data: string, pos: number, max: number)
                local parser, buf = createMockParser(data);
                Request.parseHeaders(parser, buf, max);
                expect(parser.pos).toBe(pos);
                return parser.headers;
            end
            expect(testParse("A:A\r\n\r\n", 7, 1)).toBe(expect.similar({
                a = "A",
            }));
            expect(testParse("A: A\r\n\r\n", 8, 1)).toBe(expect.similar({
                a = "A",
            }));
            expect(testParse("A:     A\r\n\r\n", 12, 1)).toBe(expect.similar({
                a = "A",
            }));
            expect(testParse("User-Agent: %20encoded\r\n\r\n", 26, 1)).toBe(expect.similar({
                ["user-agent"] = "%20encoded",
            }));
            local headers = {};
            local large = "";
            for i = 1, 100 do
                large ..= `Header-{i}:Value-{i}\r\n`;
                headers[`header-{i}`] = `Value-{i}`;
            end
            large ..= "\r\n";
            expect(testParse(large, #large, 100)).toBe(expect.similar(headers));
        end)
        test("Partial", function()
            local function testParse(data: string, fill: string, pos: number, max: number, incomplete: boolean)
                local parser, buf = createMockParser(data);
                expect(function()
                    Request.parseHeaders(parser, buf, max);
                end).toThrow("TooSmall");
                assert(parser.state.leftover);
                expect(buffer.tostring(parser.state.leftover)).toBe(data);
                expect(parser.state.headers_incomplete).toBe(incomplete);

                local new_buf = Request.withLeftover(parser, buffer.fromstring(fill));
                parser.size = buffer.len(new_buf);
                parser.pos = 0;
                Request.parseHeaders(parser, new_buf, max);
                expect(parser.pos).toBe(pos);

                return parser.headers;
            end
            expect(testParse("A:", "A\r\n\r\n", 7, 1, true)).toBe(expect.similar({
                a = "A",
            }));
            expect(testParse("A:A", "\r\n\r\n", 7, 1, true)).toBe(expect.similar({
                a = "A",
            }));
            expect(testParse("A", ":A\r\n\r\n", 7, 1, false)).toBe(expect.similar({
                a = "A",
            }));
            expect(testParse("A: A", "\r\n\r\n", 8, 1, true)).toBe(expect.similar({
                a = "A",
            }));
            expect(testParse("A:     A", "\r\n\r\n", 12, 1, true)).toBe(expect.similar({
                a = "A",
            }));
            expect(testParse("User-Agent: %20encoded", "\r\n\r\n", 26, 1, true)).toBe(expect.similar({
                ["user-agent"] = "%20encoded",
            }));
            expect(testParse("User-Agent: %20", "encoded\r\n\r\n", 26, 1, true)).toBe(expect.similar({
                ["user-agent"] = "%20encoded",
            }));
            expect(testParse("User-Agent", ": %20encoded\r\n\r\n", 26, 1, true)).toBe(expect.similar({
                ["user-agent"] = "%20encoded",
            }));
            expect(testParse("User-", "Agent: %20encoded\r\n\r\n", 26, 1, true)).toBe(expect.similar({
                ["user-agent"] = "%20encoded",
            }));

            local headers = {};
            local large = "";
            for i = 1, 100 do
                large ..= `Header-{i}:Value-{i}\r\n`;
                headers[`header-{i}`] = `Value-{i}`;
            end
            large ..= "\r\n";
            expect(testParse(large:sub(1, 100), large:sub(101), #large - 90, 100, true)).toBe(expect.similar(headers));
        end)
        test("Fail", function()
            expect(createTestParser("abc", Request.parseHeaders, 1)).toThrow("TooSmall");
            expect(createTestParser("A:A", Request.parseHeaders, 1)).toThrow("TooSmall");
            expect(createTestParser("A:\1\1A\r\n\r\n", Request.parseHeaders, 1)).toThrow("InvalidHeader");
            expect(createTestParser("A\1\1:A\r\n\r\n", Request.parseHeaders, 1)).toThrow("InvalidHeader");
            expect(createTestParser("A:A\r\n", Request.parseHeaders, 1)).toThrow("TooSmall");
            expect(createTestParser("A:A\r\nB", Request.parseHeaders, 1)).toThrow("TooSmall");
            expect(createTestParser("A:A\r\nB:B", Request.parseHeaders, 1)).toThrow("TooSmall");
            expect(createTestParser("A:A\r\nB:B\r\n", Request.parseHeaders, 1)).toThrow("TooSmall");
            expect(createTestParser("A:A\r\nB:B\r\n\r\n", Request.parseHeaders, 1)).toThrow("TooManyHeaders");
        end)
    end)
    describe("Body", function()
        test("Generic", function()
            local function testParse(data: string, pos: number, max: number)
                local parser, buf = createMockParser(data);
                parser.headers = {
                    ["content-length"] = tostring(#data),
                };
                Request.parseBody(parser, buf, max);
                expect(parser.pos).toBe(pos);
                expect(parser.body).toBe(expect.type("buffer"));
                expect(buffer.tostring(parser.body::any)).toBe(data);
            end
            testParse("TestBody", 8, 8192);
            local large = string.rep("A", 8192);
            testParse(large, 8192, 8192);
        end)
        test("Partial", function()

        end)
    end)
    describe("Full", function()
        test("Parse", function()
            local parser, buf = createMockParser("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n");
            expect(parser.state.leftover).toBe(nil);
            expect(parser.method).toBe(nil);
            expect(parser.protocol).toBe(nil);
            expect(parser.uri).toBe(nil);
            expect(parser.headers).toBe(nil);
            expect(parser.pos).toBe(0);
            expect(parser.size).toBe(buffer.len(buf));
            expect(parser.state.headers_incomplete).toBe(false);

            Request.parseMethod(parser, buf);
            expect(parser.method).toBe("GET");
            expect(parser.pos).toBe(4);

            Request.parseUri(parser, buf, 256);
            expect(parser.uri).toBe("/");
            expect(parser.pos).toBe(6);

            Request.parseProtocol(parser, buf);
            expect(parser.protocol).toBe("HTTP/1.1");
            expect(parser.pos).toBe(16);

            Request.parseHeaders(parser, buf, 1);
            expect(parser.pos).toBe(37);

            Request.parseBody(parser, buf, 1000);
            expect(parser.pos).toBe(37);
            
            expect(parser.method).toBe("GET");
            expect(parser.uri).toBe("/");
            expect(parser.protocol).toBe("HTTP/1.1");
            expect(parser.headers).toBe(expect.similar({
                host = "example.com",
            }));
            expect(parser.state.headers_incomplete).toBe(false);
        end)
        test("Partial Reader", function()
            local input = buffer.fromstring("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n");
            local parser, _ = createMockParser("");
            expect(parser.state.leftover).toBe(nil);
            expect(parser.method).toBe(nil);
            expect(parser.protocol).toBe(nil);
            expect(parser.uri).toBe(nil);
            expect(parser.headers).toBe(nil);
            expect(parser.pos).toBe(0);
            expect(parser.size).toBe(0);
            expect(parser.state.headers_incomplete).toBe(false);

            local offset = 0;
            while true do
                local part = mem.sliceOwned(input, offset, 1);
                offset += 1;
                local buf = Request.withLeftover(parser, part);
                parser.size = buffer.len(buf);
                parser.pos = 0;
                if (not parser.method) then
                    local ok, err: any = pcall(Request.parseMethod, parser, buf);
                    if (not ok) then
                        expect(err:find("TooSmall$")).never.toBeNil();
                        expect(parser.method).toBe(nil);
                        continue;
                    else
                        expect(parser.method).toBe("GET");
                    end
                end
                if (not parser.uri) then
                    local ok, err: any = pcall(Request.parseUri, parser, buf, 256);
                    if (not ok) then
                        expect(err:find("TooSmall$")).never.toBeNil();
                        expect(parser.uri).toBe(nil);
                        continue;
                    else
                        expect(parser.uri).toBe("/");
                    end
                end
                if (not parser.protocol) then
                    local ok, err: any = pcall(Request.parseProtocol, parser, buf);
                    if (not ok) then
                        expect(err:find("TooSmall$")).never.toBeNil();
                        expect(parser.protocol).toBe(nil);
                        continue;
                    else
                        expect(parser.protocol).toBe("HTTP/1.1");
                    end
                end
                if (not parser.headers or parser.state.headers_incomplete) then
                    local ok, err: any = pcall(Request.parseHeaders, parser, buf, 1);
                    if (not ok) then
                        expect(err:find("TooSmall$")).never.toBeNil();
                        continue;
                    else
                        expect(parser.headers).toBe(expect.similar({
                            host = "example.com",
                        }));
                    end
                end
                if (not parser.body and parser.method ~= "GET") then
                    local ok, err: any = pcall(Request.parseBody, parser, buf, 1000);
                    if (not ok) then
                        expect(err:find("TooSmall$")).never.toBeNil();
                        expect(parser.body).toBe(nil);
                        continue;
                    else
                        expect(parser.body).toBe(expect.type("buffer"));
                        expect(buffer.tostring(parser.body::any)).toBe("");
                    end
                end
                break;
            end
        end)
        test("Partial Reader (2)", function()
            local input = buffer.fromstring("POST /?id=2 HTTP/1.1\r\nContent-Length: 4\r\n\r\ntest");
            local parser, _ = createMockParser("");
            expect(parser.state.leftover).toBe(nil);
            expect(parser.method).toBe(nil);
            expect(parser.protocol).toBe(nil);
            expect(parser.uri).toBe(nil);
            expect(parser.headers).toBe(nil);
            expect(parser.pos).toBe(0);
            expect(parser.size).toBe(0);
            expect(parser.state.headers_incomplete).toBe(false);

            local offset = 0;
            while true do
                local part = mem.sliceOwned(input, offset, 1);
                offset += 1;
                local buf = Request.withLeftover(parser, part);
                parser.size = buffer.len(buf);
                parser.pos = 0;
                if (not parser.method) then
                    local ok, err: any = pcall(Request.parseMethod, parser, buf);
                    if (not ok) then
                        expect(err:find("TooSmall$")).never.toBeNil();
                        expect(parser.method).toBe(nil);
                        continue;
                    else
                        expect(parser.method).toBe("POST");
                    end
                end
                if (not parser.uri) then
                    local ok, err: any = pcall(Request.parseUri, parser, buf, 256);
                    if (not ok) then
                        expect(err:find("TooSmall$")).never.toBeNil();
                        expect(parser.uri).toBe(nil);
                        continue;
                    else
                        expect(parser.uri).toBe("/?id=2");
                    end
                end
                if (not parser.protocol) then
                    local ok, err: any = pcall(Request.parseProtocol, parser, buf);
                    if (not ok) then
                        expect(err:find("TooSmall$")).never.toBeNil();
                        expect(parser.protocol).toBe(nil);
                        continue;
                    else
                        expect(parser.protocol).toBe("HTTP/1.1");
                    end
                end
                if (not parser.headers or parser.state.headers_incomplete) then
                    local ok, err: any = pcall(Request.parseHeaders, parser, buf, 1);
                    if (not ok) then
                        expect(err:find("TooSmall$")).never.toBeNil();
                        continue;
                    else
                        expect(parser.headers).toBe(expect.similar({
                            ["content-length"] = "4",
                        }));
                    end
                end
                if (not parser.body and parser.method ~= "GET") then
                    local ok, err: any = pcall(Request.parseBody, parser, buf, 1000);
                    if (not ok) then
                        expect(err:find("TooSmall$")).never.toBeNil();
                        expect(parser.body).toBe(nil);
                        continue;
                    else
                        expect(parser.body).toBe(expect.type("buffer"));
                        expect(buffer.tostring(parser.body::any)).toBe("test");
                    end
                end
                break;
            end
        end)
    end)
end)

return nil;
