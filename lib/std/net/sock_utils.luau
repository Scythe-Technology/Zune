--!strict
--!native
--!optimize 2

local task = zune.task;

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
    close = function(socket: NetworkSocket)
        task.spawn(function(inner_socket)
            inner_socket:closeAsync()
        end, socket);
    end
};