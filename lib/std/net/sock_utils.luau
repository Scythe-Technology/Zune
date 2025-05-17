--!strict
--!native
--!optimize 2

local task = zune.task;

return {
    SocketClosedError = {
        ["SocketClosed"] = true,
        ["Canceled"] = true,
        ["ConnectionResetByPeer"] = true,
        --- usually from recv operations
        --- client closed connection
        ["EOF"] = true,
    };
    close = function(socket: NetworkSocket)
        task.spawn(socket.close, socket);
    end
};