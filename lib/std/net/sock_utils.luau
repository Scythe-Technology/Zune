--!strict
--!native
--!optimize 2

return {
    SocketClosedError = {
        ["SocketClosed"] = true,
        ["Unexpected"] = true,
        ["SocketNotConnected"] = true,
        --- ideally from Windows
        --- similar to "Unexpected", closed socket
        ["OperationAborted"] = true,
        ["ConnectionAborted"] = true,
    };
};