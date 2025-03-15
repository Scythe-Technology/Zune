--!strict
--!native
--!optimize 2

local Encoding = require("./encoding");

export type Response = {
    headers: {[string]: string}?,
    statusCode: number?,
    statusReason: string?,
    body: (buffer | string)?,
}

local response = {};

local function toStringHeaders(info: Response, body: string?): string
    local headers: {[string]: string} = info.headers or {};
    if (body) then
        headers["Content-Length"] = tostring(#body);
    end
    local result = "";
    for key, value in headers do
        result ..= `{key}: {value}\r\n`;
    end
    return result;
end

function response.from(info: Response): string
    local body = if (type(info.body) == "buffer") then buffer.tostring(info.body) else info.body;
    return `HTTP/1.1 {
        info.statusCode or 200
    }{
        if (info.statusReason) then ` {info.statusReason}` else ""
    }\r\n{
        toStringHeaders(info, body)
    }\r\n{body or ""}`;
end

return response;
