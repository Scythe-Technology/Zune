--!strict
--!native
--!optimize 2

local net = zune.net;
local task = zune.task;

local Request = require("./request");
local Response = require("./response");
local Encoding = require("./encoding");
local SocketUtils = require("../sock_utils");

local LinkedList = require("../../linked_list");
type LinkedList<T = any> = LinkedList.LinkedList<T>;

export type Response = Response.Response;

export type Request = {
    method: string,
    path: string,
    headers: {[string]: string},
    body: string?,
}

export type ServeOptions = {
    --- The port to bind to.
    port: number,
    --- The address to bind to.
    --- - Default: `127.0.0.1`
    address: string?,
    --- Whether to reuse the address.
    --- - Useful for multi-threaded servers.
    --- - Default: `false`
    reuseAddress: boolean?,
    --- The maximum body size to accept.
    --- - Default: `4096`
    maxBodySize: number?,
    --- The maximum number of connections.
    --- - Default: `1024`
    maxConnections: number?,
    --- The amount of backlog for the socket.
    --- - Default: `512`
    maxBacklog: number?,
    --- The timeout for the client.
    --- - Default: `60`
    clientTimeout: number?,
    --- The configuration for keep-alive connections.
    keepAlive: {
        --- - Default: `true`
        enabled: boolean?,
        timeout: number,
    }?,
    --- The function to handle requests.
    request: (request: Request) ->  string | Response,
    --- Functions to handle websockets.
    -- websocket: ServerWebSocketHandlers?,
}

type Server = {
    thread: thread?,
    waiting: boolean,
    socket: NetworkSocket,
    stopped: boolean,
    connections: LinkedList<NetworkSocket>,
    stop: (self: Server) -> (),
}

local function sendSocketAsync(socket: NetworkSocket, message: string | buffer): ()
    local length = if (type(message) == "buffer") then buffer.len(message) else #message;
    local written = 0;
    while (written < length) do
        local ok, amount = pcall(socket.send, socket, message, written);
        if (not ok) then
            local err = amount::any;
            SocketUtils.close(socket);
            if (SocketUtils.SocketClosedError[err] or err == "BrokenPipe") then
                break; -- closed/disconnected
            end
            print("Error(Unhandled): ", err);
            break;
        end
        written += amount;
    end
end

local sendQueue = {};
local waitEvents = {};
local function sendMessage(socket: NetworkSocket, message: string | buffer): ()
    if (not socket:isOpen()) then
        return;
    end
    local queue = sendQueue[socket] or {};
    table.insert(queue, message);
    if (not sendQueue[socket]) then
        -- process the queue
        sendQueue[socket] = queue;
        task.spawn(function(socket: NetworkSocket)
            while (#queue > 0 and socket:isOpen()) do
                local message = table.remove(queue, 1);
                if (message) then
                    sendSocketAsync(socket, message);
                end
            end
            sendQueue[socket] = nil;
            if (waitEvents[socket]) then
                task.spawn(waitEvents[socket]);
            end
        end, socket);
    end
end

local function waitForMessages(socket: NetworkSocket)
    local queue = sendQueue[socket];
    if (queue) then
        waitEvents[socket] = coroutine.running();
        coroutine.yield();
    end
end

local function closeClientTimedoutAsync(socket: NetworkSocket)
    sendMessage(
        socket,
        Response.from({
            statusCode = 408,
            statusReason = "Request Timeout",
            headers = {
                ["Connection"] = "close",
            },
        })
    );
    waitForMessages(socket);
    socket:close();
end

local function stopServer(server: Server): ()
    if (server.stopped) then
        return;
    end
    server.stopped = true;
    SocketUtils.close(server.socket);
end

local function listenHttpClient(
    server: Server,
    socket: NetworkSocket,
    maxBodySize: number,
    clientTimeout: number,
    keepAlive: {enabled: boolean?, timeout: number},
    callback_request: (request: Request) -> string | Response,
    connection: LinkedList.Node<NetworkSocket>
): ()
    local parser: Request.Parser = Request.newParser();
    local requests = 0;
    local request_header_read = 0;
    while socket:isOpen() do
        local open_timeout: thread;
        if (requests > 0) then
            if (not keepAlive.enabled) then
                break; -- end request
            end
            if (keepAlive.timeout > 0) then
                open_timeout = task.delay(keepAlive.timeout, closeClientTimedoutAsync, socket);
            else
                open_timeout = task.delay(clientTimeout, closeClientTimedoutAsync, socket);
            end
        else
            open_timeout = task.delay(clientTimeout, closeClientTimedoutAsync, socket);
        end
        if (request_header_read >= 8192) then
            break; -- too much client data
        end
        local stream_ok, data = pcall(socket.recv, socket, 8192);
        if (open_timeout) then
            task.cancel(open_timeout);
        end
        if (not stream_ok) then
            local err = data::any;
            if (SocketUtils.SocketClosedError[err]) then
                break; -- closed/disconnected
            end
            print("Error(Unhandled): ", err);
            break;
        end
        local data_len = buffer.len(data);
        if (data_len == 0) then
            break; -- closed/disconnected
        end
        if (true) then
            sendMessage(
                socket,
                Response.from({
                    statusCode = 200,
                    statusReason = "OK",
                    body = "Hello World",
                })
            );
            continue;
        end
        request_header_read += data_len;
        local buf = Request.withLeftover(parser, data);
        parser.size = buffer.len(buf);
        parser.pos = 0;
        if (not parser.method) then
            local ok, err: any = pcall(Request.parseMethod, parser, buf);
            if (not ok) then
                if (err == "TooSmall") then
                    continue;
                elseif (err == "InvalidMethod") then
                    break; -- end request
                else
                    error("unreachable");
                end
            end
        end
        if (not parser.uri) then
            local ok, err: any = pcall(Request.parseUri, parser, buf, 256);
            if (not ok) then
                if (err == "TooSmall") then
                    continue;
                elseif (err == "InvalidUri") then
                    break; -- end request
                elseif (err == "UriTooLarge") then
                    sendMessage(
                        socket,
                        Response.from({
                            statusCode = 414,
                            statusReason = "URI Too Large",
                        })
                    );
                    break; -- end request
                else
                    error("unreachable");
                end
            end
        end
        if (not parser.protocol) then
            local ok, err: any = pcall(Request.parseProtocol, parser, buf);
            if (not ok) then
                if (err == "TooSmall") then
                    continue;
                elseif (err == "InvalidProtocol") then
                    break; -- end request
                else
                    error("unreachable");
                end
            end
        end
        if (not parser.headers or parser.state.headers_incomplete) then
            local ok, err: any = pcall(Request.parseHeaders, parser, buf, 100);
            if (not ok) then
                if (err == "TooSmall") then
                    continue;
                elseif (err == "InvalidHeader") then
                    break; -- end request
                elseif (err == "TooManyHeaders" or err == "HeaderTooLarge") then
                    sendMessage(
                        socket,
                        Response.from({
                            statusCode = 431,
                            statusReason = "Request Header Fields Too Large",
                        })
                    );
                    break; -- end request
                else
                    error("unreachable");
                end
            end
        end
        if (not parser.body and parser.method ~= "GET") then
            local ok, err: any = pcall(Request.parseBody, parser, buf, maxBodySize);
            request_header_read = -maxBodySize;
            if (not ok) then
                if (err == "TooSmall") then
                    continue;
                elseif (err == "NotImplemented" or err == "InvalidContentLength") then
                    break; -- end request
                elseif (err == "TooLarge") then
                    sendMessage(
                        socket,
                        Response.from({
                            statusCode = 413,
                            statusReason = "Content Too Large",
                        })
                    );
                    break; -- end request
                else
                    error("unreachable");
                end
            end
        end
        requests += 1;
        if (callback_request) then
            local ok, response = xpcall(callback_request, function(err)
                print(`error: {debug.traceback(err, 2)}`);
            end, {
                body = parser.body,
                method = parser.method,
                path = Encoding.url.decode(parser.uri :: any),
                headers = parser.headers,
            } :: any);
            if (not ok) then
                local msg = "An error occurred on the server";
                sendMessage(
                    socket,
                    Response.from({
                        statusCode = 500,
                        statusReason = "Internal Server Error",
                        headers = {
                            ["Content-Type"] = "text/plain",
                        },
                        body = msg,
                    })
                );
                break;
            end
            sendMessage(
                socket,
                if (type(response) == "table") then
                    Response.from(response)
                else
                    Response.from({
                        statusCode = 200,
                        statusReason = "OK",
                        headers = {
                            ["Content-Type"] = "text/plain",
                        },
                        body = response,
                    })
            );
        end
        if (not Request.canKeepAlive(parser)) then
            break;
        end
    end
    waitForMessages(socket);
    SocketUtils.close(socket);
    server.connections:remove(connection);
    if (server.waiting) then
        server.waiting = false;
        assert(server.thread)
        task.spawn(server.thread);
    end
end

local function startServer(
    server: Server,
    maxBodySize: number,
    maxConnections: number,
    clientTimeout: number,
    keepAlive: {enabled: boolean?, timeout: number},
    callback_request: (request: Request) -> string | Response
): ()
    local socket = server.socket;
    server.thread = coroutine.running();
    while not server.stopped do
        if (server.connections.size >= maxConnections) then
            server.waiting = true;
            coroutine.yield();
            continue;
        end
        local ok, client_socket = pcall(socket.accept, socket);
        if (not ok) then
            local err = client_socket::any;
            server:stop();
            if (SocketUtils.SocketClosedError[err]) then
                break; -- closed/disconnected
            end
            print("Error(Unhandled): ", err);
            break;
        end
        local connection: LinkedList.Node<NetworkSocket> = {
            value = client_socket
        };
        server.connections:append(connection);
        
        task.spawn(
            listenHttpClient,
            server,
            client_socket,
            maxBodySize,
            clientTimeout,
            keepAlive,
            callback_request,
            connection
        )
    end
end

local server = {};

function server.serve(opts: ServeOptions): Server
    assert(type(opts) == "table", "Expected opts to be a table");

    local port = opts.port or 80;
    local address = opts.address or "127.0.0.1";
    local maxBacklog = opts.maxBacklog or 512;
    local maxBodySize = opts.maxBodySize or 4096;
    local reuseAddress = opts.reuseAddress or false;
    local clientTimeout = opts.clientTimeout or 60;
    local maxConnections = opts.maxConnections or 1024;
    -- local websocket_handlers = opts.websocket or {};
    local keepAlive = opts.keepAlive or { enabled = true, timeout = 0 };

    local callback_request = opts.request;

    assert(type(port) == "number", "Expected port to be a number");
    assert(type(address) == "string", "Expected address to be a string");
    assert(type(maxBacklog) == "number", "Expected maxBacklog to be a number");
    assert(type(maxBodySize) == "number", "Expected maxBodySize to be a number");
    assert(type(reuseAddress) == "boolean", "Expected reuseAddress to be a boolean");
    assert(type(clientTimeout) == "number", "Expected clientTimeout to be a number");
    assert(type(maxConnections) == "number", "Expected maxConnections to be a number");
    -- assert(type(websocket_handlers) == "table", "Expected websocket to be a table");
    assert(type(keepAlive) == "table", "Expected keepAlive to be a table");

    local keepAliveTimeout = keepAlive.timeout;
    local keepAliveEnabled = keepAlive.enabled or true;
    assert(type(keepAliveTimeout) == "number", "Expected keepAlive.timeout to be a number");
    assert(type(keepAliveEnabled) == "boolean", "Expected keepAlive.enabled to be a boolean");

    assert(type(callback_request) == "function", "Expected request to be a function");

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
    socket:listen(maxBacklog);

    local self: Server = {
        waiting = false,
        socket = socket,
        stopped = false,
        connections = LinkedList.new(),
        stop = stopServer,
    };

    task.spawn(
        startServer,
        self,
        maxBodySize,
        maxConnections,
        clientTimeout,
        {
            enabled = keepAliveEnabled,
            timeout = keepAliveTimeout,
        },
        callback_request
    );

    return self;
end

return server;
