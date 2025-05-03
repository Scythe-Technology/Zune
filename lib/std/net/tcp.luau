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
    waiting: boolean,
    thread: thread?,
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

type TCPClientOpenCallback = ((socket: TCPConnection) -> ());
type TCPClientDataCallback = ((socket: TCPConnection, data: string) -> ());
type TCPClientCloseCallback = ((socket: TCPConnection) -> ());

export type TCPClientOptions = {
    --- The port to connect with.
    port: number,
    --- The address to bind to.
    address: string,
    --- The maximum body size to accept. Excess data will be on next cycle.
    --- - Default: `8192`
    maxDataRead: number?,
    --- Callbacks for open event.
    open: TCPClientOpenCallback?,
    --- Callbacks for data event.
    data: TCPClientDataCallback?,
    --- Callbacks for close event.
    close: TCPClientCloseCallback?,
}

type TCPServerOpenCallback = ((socket: TCPConnection) -> ());
type TCPServerDataCallback = ((socket: TCPConnection, data: string) -> ());
type TCPServerCloseCallback = ((socket: TCPConnection) -> ());

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
    open: TCPServerOpenCallback?,
    --- Callback for data event.
    data: TCPServerDataCallback?,
    --- Callback for close event.
    close: TCPServerCloseCallback?,
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
        local ok, amount = pcall(connection.socket.send, connection.socket, message, written);
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

local function listenServerConnection(
    server: TCPServer,
    node: LinkedList.Node<TCPConnection>,
    maxDataRead: number,
    callback_data: TCPServerDataCallback?,
    callback_close: TCPServerCloseCallback?
): ()
    local connection = node.value;
    while not connection.stopped do
        local ok, data = pcall(connection.socket.recv, connection.socket, maxDataRead);
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
            task.spawn(callback_data, connection, buffer.tostring(data));
        end
    end
    closeConnection(connection);
    server.connections:remove(node);
    if (callback_close) then
        task.defer(callback_close, connection);
    end
    if (server.waiting) then
        server.waiting = false;
        assert(server.thread);
        task.spawn(server.thread);
    end
end

local function stopServer(server: TCPServer): ()
    if (server.stopped) then
        return;
    end
    server.stopped = true;
    for _, connection in server.connections:iterate() do
        closeConnection(connection);
    end
    SocketUtils.close(server.socket);
end

local function startServer(
    server: TCPServer,
    maxConnections: number,
    maxDataRead: number,
    callback_open: TCPServerOpenCallback?,
    callback_data: TCPServerDataCallback?,
    callback_close: TCPServerCloseCallback?
): ()
    server.thread = coroutine.running();
    server.waiting = false;
    while not server.stopped do
        if (maxConnections >= 0 and server.connections.size >= maxConnections) then
            server.waiting = true;
            coroutine.yield();
            continue;
        end
        local ok, client_socket = pcall(server.socket.accept, server.socket);
        if (not ok) then
            local err = client_socket::any;
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
        server.connections:append(connection);
        if (callback_open) then
            task.spawn(callback_open, tcp_connection);
        end
        task.spawn(
            listenServerConnection,
            server,
            connection,
            maxDataRead,
            callback_data,
            callback_close
        );
    end
    stopServer(server);
end

local tcp = {};

function tcp.host(opts: TCPServerOptions): TCPServer
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

    local socket = net.createSocket(
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
    socket:listen(math.clamp(maxConnections, 0, 128));

    local name = socket:getName();

    local self: TCPServer = {
        stopped = false,
        waiting = false,
        port = name.port,
        address = name.address,
        connections = LinkedList.new(),
        socket = socket,
        stop = stopServer,
    };

    task.spawn(
        startServer,
        self,
        maxConnections,
        maxDataRead,
        callback_open,
        callback_data,
        callback_close
    );

    return self;
end

local function connectToHost(name: string, port: number): NetworkSocket
    local list = zune.net.getAddressList(name, port);
    if (#list == 0) then
        error("UnknownHostName");
    end
    for _, address in list do
        local socket = net.createSocket(
            address.family,
            bit32.bor(
                net.SOCKF.STREAM,
                if (process.os == "windows") then 0 else net.SOCKF.CLOEXEC
            ),
            net.IPPROTO.TCP
        );
        local ok, err = pcall(function(): any?
            socket:connect(address.address, address.port);
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

local function startClient(
    client: TCPConnection,
    maxDataRead: number,
    callback_data: TCPClientDataCallback?,
    callback_close: TCPClientCloseCallback?
)
    while not client.stopped do
        local ok, data = pcall(client.socket.recv, client.socket, maxDataRead);
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
            task.spawn(callback_data, client, buffer.tostring(data));
        end
    end
    closeConnection(client);
    if (callback_close) then
        task.defer(callback_close, client);
    end
end

function tcp.connect(opts: TCPClientOptions): TCPConnection
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

    local socket = connectToHost(address, port);

    local self: TCPConnection = newConnection(socket);

    if (callback_open) then
        task.defer(callback_open, self);
    end
    
    task.spawn(
        startClient,
        self,
        maxDataRead,
        callback_data,
        callback_close
    );

    return self;
end

return tcp;
