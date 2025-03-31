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
    --- @return `number` bytes sent
    send: (self: UDPSocket, message: string | buffer, port: number, address: string) -> number,
    --- Stops the Socket.
    stop: (self: UDPSocket) -> (),
}

type UDPDataCallback = ((socket: UDPSocket, buffer: buffer, port: number, address: string) -> ());

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
    data: UDPDataCallback?,
}

local udp = {};

local function sendSocketAsync(
    self: UDPSocket,
    message: buffer | string,
    port: number,
    address: string
): number
    local ok, amount = pcall(self.socket.sendMsg, self.socket, port, address, message);
    if (not ok) then
        local err = amount::any;
        self:stop();
        if (SocketUtils.SocketClosedError[err]) then
            return 0;
        end
        print("Error(Unhandled): ", err);
    end
    return amount;
end

local function stopSocket(self: UDPSocket): ()
    if (self.stopped) then
        return;
    end
    self.stopped = true;
    SocketUtils.close(self.socket);
end

local function startSocket(
    self: UDPSocket,
    maxBodySize: number,
    callback_data: UDPDataCallback?
): ()
    local socket = self.socket;
    while not self.stopped do
        local ok, address, msg = pcall(socket.recvMsg, socket, maxBodySize);
        if (not ok) then
            local err = address::any;
            if (SocketUtils.SocketClosedError[err]) then
                break; -- closed
            end
            print("Error(Unhandled): ", address);
            break;
        end
        if (callback_data) then
            task.spawn(callback_data, self, msg, address.port, address.address);
        end
    end
    stopSocket(self);
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

    local socket = net.createSocket(
        net.ADDRF.INET,
        bit32.bor(net.SOCKF.DGRAM, net.SOCKF.NONBLOCK, net.SOCKF.CLOEXEC),
        net.IPPROTO.UDP
    );

    socket:bindIp(address, port);

    local name = socket:getName();

    local self: UDPSocket = {
        socket = socket,
        address = name.address,
        port = name.port,
        stopped = false,
        send = sendSocketAsync,
        stop = stopSocket,
    };

    task.spawn(
        startSocket,
        self,
        maxBodySize,
        callback_data
    );

    return self;
end

return udp;
