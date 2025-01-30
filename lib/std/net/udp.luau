--!strict
--!native
--!optimize 2

local net = zune.net;
local task = zune.task;

local SocketUtils = require("./sock_utils");

export type UDPSocket = {
    socket: NetworkSocket,
    --- The address binded to
    address: string,
    --- Port used
    port: number,
    --- Whether the socket is active
    stopped: boolean,
    --- Send a UDP datagram message to remote host.
    send: (self: UDPSocket, message: string | buffer, port: number, address: string) -> (),
    --- Stops the Socket.
    stop: (self: UDPSocket) -> (),
}

export type UDPSocketOptions = {
    --- The port to bind to.
    --- - If port is `0`, the OS will choose a port.
    --- - Default: `0`
    port: number?,
    --- The address to bind to.
    --- - Default: `127.0.0.1`
    address: string?,
    --- The maximum size of the body.
    --- - Default: `65_507`
    maxBodySize: number?,
    --- Callback to handle UDP datagram
    data: ((socket: UDPSocket, buffer: buffer, port: number, address: string) -> ())?,
}

local udp = {};

local function stopSocket(self: UDPSocket): ()
    if (self.stopped) then
        return;
    end
    self.stopped = true;
    self.socket:close();
end

function udp.createAsync(opts: UDPSocketOptions): UDPSocket
    assert(type(opts) == "table", "Expected opts to be a table");

    local address = opts.address or "127.0.0.1";
    local port = opts.port or 0;
    local maxBodySize = opts.maxBodySize or 65_507;

    local callback_data = opts.data;

    assert(type(address) == "string", "Expected address to be a string");
    assert(type(port) == "number", "Expected port to be a number");
    assert(type(maxBodySize) == "number", "Expected maxBodySize to be a number");
    assert(maxBodySize > 0, "Expected maxBodySize to be greater than 0");
    
    assert(type(callback_data) == "function" or callback_data == nil, "Expected data to be a function");

    local socket = net.createSocketAsync(
        net.ADDRF.INET,
        bit32.bor(net.SOCKF.DGRAM, net.SOCKF.NONBLOCK),
        net.IPPROTO.UDP
    );

    socket:bindIp(address, port);

    local name = socket:getName();

    local self: UDPSocket = {
        socket = socket,
        address = name.address,
        port = name.port,
        stopped = false,
        send = function(self, message, port, address)
            local ok, err = pcall(function(): any?
                local _ = socket:sendMsgAsync(port, address, message);
                return;
            end)
            if (not ok) then
                if (SocketUtils.SocketClosedError[err]) then
                    self:stop();
                    return;
                end
                print("Error(Unhandled): ", err);
            end
        end,
        stop = stopSocket,
    };

    task.spawn(function()
        while not self.stopped do
            local ok, address, msg = pcall(function()
                return socket:recvMsgAsync(maxBodySize);
            end)
            if (not ok) then
                local err = address::any;
                if (SocketUtils.SocketClosedError[err]) then
                    self:stop();
                    break; -- closed
                end
                print("Error(Unhandled): ", address);
                break;
            end
            if (callback_data) then
                task.spawn(callback_data, self, msg, address.port, address.address);
            end
        end
        self:stop();
    end);

    return self;
end

return udp;
