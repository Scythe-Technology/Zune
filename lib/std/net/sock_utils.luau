--!strict
--!native
--!optimize 2

local task = zune.task;

return {
    SocketClosedError = {
        ["SocketClosed"] = true,
        ["Canceled"] = true,
        --- usually from recv operations
        --- client closed connection
        ["EOF"] = true,
    };
    close = function(socket: NetworkSocket)
        task.spawn(function(inner_socket)
            inner_socket:closeAsync()
        end, socket);
    end
};