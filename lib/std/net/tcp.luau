--!strict
--!native
--!optimize 2

local net = zune.net;
local task = zune.task;
local process = zune.process;

local SocketUtils = require("./sock_utils");

local LinkedList = require("../linked_list");
type LinkedList<T = any> = LinkedList.LinkedList<T>;

export type TCPServer = {
    socket: NetworkSocket,
    --- The address binded to.
    address: string,
    --- The port binded to.
    port: number,
    --- Whether the socket is active.
    stopped: boolean,
    --- Connections.
    connections: LinkedList<TCPConnection>,
    --- Stops the socket.
    stop: (self: TCPServer) -> (),
};

export type TCPConnection = {
    socket: NetworkSocket,
    --- Whether the socket is active
    stopped: boolean,
    --- Send a message to remote host.
    send: (self: TCPConnection, message: string | buffer) -> (),
    --- Stops the socket.
    stop: (self: TCPConnection) -> (),
};

export type TCPClientOptions = {
    --- The port to connect with.
    port: number,
    --- The address to bind to.
    address: string,
    --- The maximum body size to accept. Excess data will be on next cycle.
    --- - Default: `8192`
    maxDataRead: number?,
    --- Callbacks for open event.
    open: ((socket: TCPConnection) -> ())?,
    --- Callbacks for data event.
    data: ((socket: TCPConnection, data: string) -> ())?,
    --- Callbacks for close event.
    close: ((socket: TCPConnection) -> ())?,
}

export type TCPServerOptions = {
    ---The port to bind to.
    --- - Nil or None lets the system pick.
    port: number?,
    --- The address to bind to.
    --- - Default: `127.0.0.1`
    address: string?,
    --- Whether to reuse the address.
    --- - Useful for multi-threaded servers.
    --- - Default: `false`
    reuseAddress: boolean?,
    --- The maximum body size to accept. Excess data will be on next cycle.
    --- - Default: `8192`
    maxDataRead: number?,
    --- The maximum number of connections to accept.
    --- - Default: `512`
    maxConnections: number?,
    --- Callback for open event.
    open: ((socket: TCPConnection) -> ())?,
    --- Callback for data event.
    data: ((socket: TCPConnection, data: string) -> ())?,
    --- Callback for close event.
    close: ((socket: TCPConnection) -> ())?,
}

local function closeConnection(connection: TCPConnection): ()
    if (connection.stopped) then
        return;
    end
    connection.stopped = true;
    SocketUtils.close(connection.socket);
end

local function sendConnectionAsync(connection: TCPConnection, message: string | buffer): ()
    if (connection.stopped) then
        return;
    end
    local length = if (type(message) == "buffer") then buffer.len(message) else #message;
    local written = 0;
    while (written < length) do
        local ok, amount = pcall(function()
            return connection.socket:sendAsync(message, written);
        end)
        if (not ok) then
            local err = amount::any;
            closeConnection(connection);
            if (SocketUtils.SocketClosedError[err] or err == "BrokenPipe") then
                break; -- closed/disconnected
            end
            print("Error(Unhandled): ", err);
            break;
        end
        written += amount;
    end
end

local function newConnection(socket: NetworkSocket): TCPConnection
    local self: TCPConnection = {
        stopped = false,
        socket = socket,
        send = sendConnectionAsync,
        stop = closeConnection;
    };
    return self;
end

local function stopServer(server: TCPServer): ()
    if (server.stopped) then
        return;
    end
    server.stopped = true;
    for _, connection in server.connections:iterate() do
        connection:stop();
    end
    SocketUtils.close(server.socket);
end

local tcp = {};

-- local tcpServer = {
--     stop = stopServer;
-- };
-- tcpServer.__index = tcpServer;

-- local tcpConnection = {
--     send = sendConnectionAsync;
--     close = closeConnection;
-- };
-- tcpConnection.__index = tcpConnection;

function tcp.hostAsync(opts: TCPServerOptions): TCPServer
    assert(type(opts) == "table", "Expected opts to be a table");

    local address = opts.address or "127.0.0.1";
    local port = opts.port or 0;
    local reuseAddress = opts.reuseAddress or false;
    local maxDataRead = opts.maxDataRead or 8192;
    local maxConnections = opts.maxConnections or 512;

    local callback_open = opts.open;
    local callback_data = opts.data;
    local callback_close = opts.close;

    assert(type(address) == "string", "Expected address to be a string");
    assert(type(port) == "number", "Expected port to be a number");
    assert(type(reuseAddress) == "boolean", "Expected reuseAddress to be a boolean");
    assert(type(maxDataRead) == "number", "Expected maxDataRead to be a number");
    assert(type(maxConnections) == "number", "Expected maxConnections to be a number");
    assert(type(callback_open) == "function" or callback_open == nil, "Expected open to be a function");
    assert(type(callback_data) == "function" or callback_data == nil, "Expected data to be a function");
    assert(type(callback_close) == "function" or callback_close == nil, "Expected close to be a function");

        local socket = net.createSocketAsync(
            net.ADDRF.INET,
            bit32.bor(net.SOCKF.STREAM, net.SOCKF.CLOEXEC, net.SOCKF.NONBLOCK),
            net.IPPROTO.TCP
        );
    
        if (reuseAddress) then
            socket:setOption(net.SOCKOPTLV.SOCKET, net.SOCKOPT.REUSEADDR, true);
            if (net.SOCKOPT.REUSEPORT) then
                socket:setOption(net.SOCKOPTLV.SOCKET, net.SOCKOPT.REUSEPORT, true);
            end
        end
    
        socket:bindIp(address, port);
        socket:listen();

    local name = socket:getName();

    local self: TCPServer = {
        stopped = false,
        port = name.port,
        address = name.address,
        connections = LinkedList.new(),
        socket = socket,
        stop = stopServer,
    };

    task.spawn(function()
        while not self.stopped do
            if (self.connections.size >= maxConnections) then
                -- TODO: store coroutine, yield, and resume on another point in time.
                task.wait(1);
                continue;
            end
            local ok, client_socket = pcall(function()
                return socket:acceptAsync();
            end)
            if (not ok) then
                local err = client_socket::any;
                self:stop();
                if (SocketUtils.SocketClosedError[err]) then
                    break; -- closed/disconnected
                end
                print("Error(Unhandled): ", err);
                break;
            end
            local connection: LinkedList.Node<TCPConnection> = {
                value = newConnection(client_socket)
            };
            local tcp_connection = connection.value;
            self.connections:append(connection);
            if (callback_open) then
                task.spawn(callback_open, tcp_connection);
            end
            task.spawn(function()
                while not tcp_connection.stopped do
                    local ok, data = pcall(function()
                        return client_socket:recvAsync(maxDataRead);
                    end)
                    if (not ok) then
                        local err = data::any;
                        if (SocketUtils.SocketClosedError[err]) then
                            break; -- closed/disconnected
                        end
                        print("Error(Unhandled): ", err);
                        break;
                    end
                    if (buffer.len(data) == 0) then
                        break; -- closed/disconnected
                    end
                    if (callback_data) then
                        task.spawn(callback_data, tcp_connection, buffer.tostring(data));
                    end
                end
                closeConnection(tcp_connection);
                self.connections:remove(connection);
                if (callback_close) then
                    task.defer(callback_close, tcp_connection);
                end
            end)
        end
    end);

    return self;
end

local function connectToHostAsync(name: string, port: number): NetworkSocket
    local list = zune.net.getAddressList(name, port);
    if (#list == 0) then
        error("UnknownHostName");
    end
    for _, address in list do
        local socket = net.createSocketAsync(
            address.family,
            bit32.bor(
                net.SOCKF.STREAM,
                if (process.os == "windows") then 0 else net.SOCKF.CLOEXEC
            ),
            net.IPPROTO.TCP
        );
        local ok, err = pcall(function(): any?
            socket:connectAsync(address.address, address.port);
            return;
        end)
        if (not ok) then
            if (err == "ConnectionRefused") then
                continue;
            end
            error(err);
        end
        return socket;
    end
    error("ConnectionRefused");
end

function tcp.connectAsync(opts: TCPClientOptions): TCPConnection
    assert(type(opts) == "table", "Expected opts to be a table");

    local address = opts.address;
    local port = opts.port;

    local callback_open = opts.open;
    local callback_data = opts.data;
    local callback_close = opts.close;

    assert(type(address) == "string", "Expected address to be a string");
    assert(type(port) == "number", "Expected port to be a number");
    assert(type(callback_open) == "function" or callback_open == nil, "Expected open to be a function");
    assert(type(callback_data) == "function" or callback_data == nil, "Expected data to be a function");
    assert(type(callback_close) == "function" or callback_close == nil, "Expected close to be a function");

    local maxDataRead = opts.maxDataRead or 8192;

    local socket = connectToHostAsync(address, port);

    local self: TCPConnection = {
        stopped = false,
        socket = socket,
        send = sendConnectionAsync,
        stop = closeConnection,
    };

    if (callback_open) then
        task.defer(callback_open, self);
    end
    task.spawn(function()
        while not self.stopped do
            local ok, data = pcall(function()
                return socket:recvAsync(maxDataRead);
            end)
            if (not ok) then
                local err = data::any;
                if (SocketUtils.SocketClosedError[err]) then
                    break; -- closed/disconnected
                end
                print("Error(Unhandled): ", err);
                break;
            end
            if (buffer.len(data) == 0) then
                break; -- closed/disconnected
            end
            if (callback_data) then
                task.spawn(callback_data, self, buffer.tostring(data));
            end
        end
        closeConnection(self);
        if (callback_close) then
            task.defer(callback_close, self);
        end
    end);

    return self;
end

return tcp;
