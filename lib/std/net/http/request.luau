--!strict
--!native
--!optimize 2

local mem = require("../../mem");

type ParserState = {
    leftover: buffer?,
    headers_count: number,
    headers_incomplete: boolean,
}

export type Parser = {
    pos: number,
    size: number,
    method: "GET" | "PUT" | "POST" | "HEAD" | "PATCH" | "DELETE" | "OPTIONS" | nil,
    uri: string?,
    protocol: string?,
    headers: {[string]: string}?,
    body: buffer?,
    state: ParserState,
}

local function as_u32(str: string): number
    return buffer.readu32(buffer.fromstring(str), 0);
end
local function as_u16(str: string): number
    return buffer.readu16(buffer.fromstring(str), 0);
end

local HTTP = as_u32("HTTP");
local GET_ = as_u32("GET ");
local PUT_ = as_u32("PUT ");
local POST = as_u32("POST");
local HEAD = as_u32("HEAD");
local PATC = as_u32("PATC");
local DELE = as_u32("DELE");
local ETE_ = as_u32("ETE ");
local OPTI = as_u32("OPTI");
local ONS_ = as_u32("ONS ");
local V1P0 = as_u32("/1.0");
local V1P1 = as_u32("/1.1");

local RETURN_LINE = as_u16("\r\n");

local function canRead(self: Parser, amount: number): boolean
    return self.pos + amount <= self.size;
end

local function isReturnLine(self: Parser, buf: buffer): boolean
    return buffer.readu16(buf, self.pos) == RETURN_LINE -- '\r\n'
end

local MethodParsers = {
    [GET_] = function(self: Parser, buf: buffer): ()
        self.method = "GET";
        self.pos += 4;
    end,
    [PUT_] = function(self: Parser, buf: buffer): ()
        self.method = "PUT";
        self.pos += 4;
    end,
    [POST] = function(self: Parser, buf: buffer): ()
        if (not canRead(self, 5)) then
            self.state.leftover = buf;
            error("TooSmall", 0);
        end
        if (buffer.readu8(buf, 4) ~= 0x20) then
            error("InvalidMethod", 0);
        end
        self.method = "POST";
        self.pos += 5;
    end,
    [HEAD] = function(self: Parser, buf: buffer): ()
        if (not canRead(self, 5)) then
            self.state.leftover = buf;
            error("TooSmall", 0);
        end
        if (buffer.readu8(buf, 4) ~= 0x20) then
            error("InvalidMethod", 0);
        end
        self.method = "HEAD";
        self.pos += 5;
    end,
    [PATC] = function(self: Parser, buf: buffer): ()
        if (not canRead(self, 6)) then
            self.state.leftover = buf;
            error("TooSmall", 0);
        end
        if (buffer.readu8(buf, 4) ~= 0x48 or buffer.readu8(buf, 5) ~= 0x20) then
            error("InvalidMethod", 0);
        end
        self.method = "PATCH";
        self.pos += 6;
    end,
    [DELE] = function(self: Parser, buf: buffer): ()
        if (not canRead(self, 7)) then
            self.state.leftover = buf;
            error("TooSmall", 0);
        end
        if (buffer.readu32(buf, 3) ~= ETE_) then
            error("InvalidMethod", 0);
        end
        self.method = "DELETE";
        self.pos += 7;
    end,
    [OPTI] = function(self: Parser, buf: buffer): ()
        if (not canRead(self, 8)) then
            self.state.leftover = buf;
            error("TooSmall", 0);
        end
        if (buffer.readu32(buf, self.pos + 4) ~= ONS_) then
            error("InvalidMethod", 0);
        end
        self.method = "OPTIONS";
        self.pos += 8;
    end,
}

local function parseMethod(self: Parser, buf: buffer): ()
    if (not canRead(self, 4)) then
        self.state.leftover = buf;
        error("TooSmall", 0);
    end
    local parser = MethodParsers[buffer.readu32(buf, self.pos)];
    if (not parser) then
        error("InvalidMethod", 0);
    end
    parser(self, buf);
end

local function isValidUri(url: string): boolean
    return url:find("[^\32-\126]") == nil;
end
local function parseUri(self: Parser, buf: buffer, maxSize: number): ()
    if (not canRead(self, 2)) then
        self.state.leftover = buf;
        error("TooSmall", 0);
    end

    local front = buffer.readu8(buf, self.pos);
    if (front == 0x2F) then -- '/'
        local end_index = mem.indexOfCharAt(buf, self.pos, 0x20) or self.size - 1;
        local uri = buffer.readstring(buf, self.pos, end_index - self.pos);
        if (#uri > maxSize) then
            error("UriTooLarge", 0);
        end
        if (not isValidUri(uri)) then
            error("InvalidUri", 0);
        end
        if (buffer.readu8(buf, end_index) ~= 0x20) then -- ' '
            if (end_index == self.size - 1) then
                self.state.leftover = buf;
                error("TooSmall", 0);
            end
            error("InvalidUri", 0);
        end
        self.uri = uri;
        self.pos = end_index + 1;
        return;
    elseif (front == 0x2A) then -- '*'
        if (buffer.readu8(buf, self.pos + 1) ~= 0x20) then
            error("InvalidUri", 0);
        end
        self.uri = "*";
        self.pos += 2;
        return;
    else
        error("InvalidUri", 0);
    end
end

local function parseProtocol(self: Parser, buf: buffer): ()
    if (not canRead(self, 10)) then
        self.state.leftover = buf;
        error("TooSmall", 0);
    end

    if (buffer.readu32(buf, self.pos) ~= HTTP) then
        error("InvalidProtocol", 0);
    end
    
    local version = buffer.readu32(buf, self.pos + 4);
    if (version == V1P0) then
        self.protocol = "HTTP/1.0";
    elseif (version == V1P1) then
        self.protocol = "HTTP/1.1";
    else
        error("InvalidProtocol", 0);
    end
    self.pos += 8;
    
    if (not isReturnLine(self, buf)) then
        error("InvalidProtocol", 0);
    end
    self.pos += 2;
end

local VALID_HEADER_VALUE = {};
VALID_HEADER_VALUE[0x09] = true; -- \t
VALID_HEADER_VALUE[0x20] = true; -- ' '
for i = 0x21, 0x7E do
    VALID_HEADER_VALUE[i] = true; -- '!'...'~'
end

local function skipWhitespace(buf: buffer, size: number, pos: number): number
    while (pos < size and buffer.readu8(buf, pos) == 0x20) do
        pos += 1;
    end
    return pos;
end
local function parseHeaders(self: Parser, buf: buffer, maxHeaders: number): ()
    if (not canRead(self, 2)) then
        self.state.leftover = buf;
        error("TooSmall", 0);
        return;
    end
    if (isReturnLine(self, buf)) then
        self.pos += 2;
        self.state.headers_incomplete = false;
        return;
    end

    local headers: {[string]: string} = if (self.state.headers_incomplete) then self.headers::{[string]: string} else {};
    local headers_count = self.state.headers_count;
    local pos = self.pos;
    local size = self.size;
    self.headers = headers;
    self.state.headers_incomplete = true;
    while (size > pos) do
        local _jp = false;
        for i = pos, size - 1 do
            local b = buffer.readu8(buf, i);
            if (
                (b >= 0x41 and b <= 0x5a) -- 'A'...'Z'
                or (b >= 0x30 and b <= 0x39) -- '0'...'9'
                or b == 45 -- '-'
                or b == 95 -- '_'
                or (b >= 0x61 and b <= 0x7a) -- 'a'...'z'
            ) then
                continue;
            elseif (b == 0x3a) then -- ':'
                local header_pos = i;
                local trim_pos = skipWhitespace(buf, size, i + 1);
                local value_pos = nil;
                for j = trim_pos, size - 1 do
                    local b2 = buffer.readu8(buf, j);
                    if (VALID_HEADER_VALUE[b2]) then
                        continue;
                    end
                    if (b2 ~= 0x0d) then -- '\r'
                        self.state.headers_incomplete = false;
                        error("InvalidHeader", 0);
                    end
                    if (size - 1 <= j + 1) then
                        self.pos = pos;
                        self.state.leftover = buf;
                        error("TooSmall", 0);
                    end
                    if (buffer.readu8(buf, j + 1) ~= 0x0a) then -- '\n'
                        self.state.headers_incomplete = false;
                        error("InvalidHeader", 0);
                    end
                    value_pos = j;
                    break;
                end
                if (value_pos == nil) then
                    self.pos = pos;
                    self.state.leftover = buf;
                    error("TooSmall", 0);
                end
                local name = buffer.readstring(buf, pos, header_pos - pos):lower();
                if (headers_count >= maxHeaders) then
                    self.state.headers_incomplete = false;
                    error("TooManyHeaders", 0);
                end
                headers_count += 1;
                headers[name] = buffer.readstring(buf, trim_pos, value_pos - trim_pos);
                -- TODO: make this customizable?
                if (#name > 64 or #headers[name] >= 2048) then
                    error("HeaderTooLarge", 0);
                end
                pos = value_pos + 2;
                _jp = true;
                break;
            elseif (b == 0x0d) then  -- '\r'
                if (size - i <= 1) then
                    self.pos = pos;
                    self.state.leftover = buf;
                    error("TooSmall", 0);
                end
                if (buffer.readu8(buf, i + 1) == 0x0a) then -- '\n'
                    self.pos = i + 2;
                    self.state.headers_incomplete = false;
                    return;
                else
                    self.state.headers_incomplete = false;
                    error("InvalidHeader", 0);
                end
            else
                self.state.headers_incomplete = false;
                error("InvalidHeader", 0);
            end
        end
        if (not _jp) then
            break;
        end
    end
    self.pos = pos;
    self.state.leftover = buf;
    error("TooSmall", 0);
end

local function parseBody(self: Parser, buf: buffer, maxBodySize: number): ()
    if (not self.headers) then
        return;
    end
    local content_length = self.headers["content-length"];
    if (content_length) then
        local content_length_num = tonumber(content_length);
        if (not content_length_num) then
            error("InvalidContentLength", 0);
        end
        if (content_length_num > maxBodySize) then
            error("TooLarge", 0);
        end
        if (self.pos + content_length_num > self.size) then
            self.state.leftover = buf;
            error("TooSmall", 0);
        end
        self.body = mem.sliceOwned(buf, self.pos, content_length_num);
        self.pos += content_length_num;
        return;
    elseif (self.headers["transfer-encoding"] == "chunked") then
        error("NotImplemented", 0);
    else
        return;
    end
end

local function canKeepAlive(self: Parser): boolean
    if (not self.headers) then
        return false;
    end
    local connection = self.headers["connection"];
    if (not connection) then
        return true;
    end
    if (connection == "close") then
        return false;
    end
    if (self.protocol == "HTTP/1.0") then
        return false;
    end
    return true;
end

local function newParser(): Parser
    return {
        pos = 0,
        size = 0,
        method = nil,
        uri = nil,
        protocol = nil,
        headers = nil,
        body = nil,
        state = {
            leftover = nil,
            recv_more = false,
            headers_count = 0,
            headers_incomplete = false,
        },
    }
end

local function withLeftover(self: Parser, target: buffer): buffer
    if (self.state.leftover) then
        local joined = mem.joinOwned(nil, {
            mem.sliceOwned(self.state.leftover, self.pos, self.size - self.pos),
            target
        });
        self.state.leftover = nil;
        return joined;
    end
    return target
end

local function resetParser(self: Parser): ()
    self.pos = 0;
    self.size = 0;
    self.method = nil;
    self.uri = nil;
    self.state.leftover = nil;
    self.state.headers_count = 0;
    self.state.headers_incomplete = false;
end

local request = {};

request.parseMethod = parseMethod;
request.parseUri = parseUri;
request.parseProtocol = parseProtocol;
request.parseHeaders = parseHeaders;
request.parseBody = parseBody;
request.canKeepAlive = canKeepAlive;
request.newParser = newParser;
request.withLeftover = withLeftover;
request.resetParser = resetParser;

return request;
