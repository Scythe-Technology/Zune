--!strict
--!native
--!optimize 2

local encoding = {};
encoding.url = {}

encoding.url.decode = function(data: string): string
    return data:gsub("%%(%x%x)", function(x: string)
        local num = tonumber(x, 16);
        if (not num) then
            error("InvalidHex", 0);
        end
        return string.char(num);
    end)
end

encoding.url.encode = function(data: string): string
    return data:gsub("([^%w%.%-_])", function(c: string)
        return string.format("%%%02X", string.byte(c));
    end)
end

return encoding;
