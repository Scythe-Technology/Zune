--!strict
--!native
--!optimize 2

local ClosedError = {
    ["SocketClosed"] = true,
    ["Unexpected"] = true,
    ["SocketNotConnected"] = true,
    --- ideally from Windows
    --- similar to "Unexpected", closed socket
    ["OperationAborted"] = true,
    ["ConnectionAborted"] = true,
};

local function isClosedError(err: any): boolean
    return ClosedError[err] == true;
end

return {
    isClosedError = isClosedError,
};