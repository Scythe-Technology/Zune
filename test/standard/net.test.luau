--!strict
local net = zune.net;
local task = zune.task;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local _, version, _ = string.match(_VERSION, "(Zune) (%d+%.%d+%.%d+.*)+(%d+%.%d+)");
assert(version and #version > 0, "No version");

describe("Server", function()
    test("Basic", function()
        local requests: {ServerRequest} = {};
        local server = net.http.serve({
            port = 8080,
            reuseAddress = true,
            request = function(req)
                table.insert(requests, req);
                return {
                    statusCode = 200,
                    body = "Hello",
                }
            end,
        });
        expect(server).toBe(expect.type("userdata"));

        local res = net.http.request("http://localhost:8080");
        expect(res).toBe(expect.type("table"));
        expect(res.ok).toBe(true);
        expect(res.statusCode).toBe(200);
        expect(res.body).toBe("Hello");
        expect(res.headers).toBe(expect.type("table"));
        expect(res.headers["Content-Length"]).toBe("5");
        expect(res.statusReason).toBe("OK");

        expect(requests).toHaveLength(1);

        local request = requests[1];
        expect(request).toBe(expect.type("table"));
        expect(request.method).toBe("GET");
        expect(request.path).toBe("/");
        expect(request.headers).toBe(expect.type("table"));
        expect(request.headers["host"]).toBe("localhost:8080");
        expect(request.headers["user-agent"]).toBe("Zune/" .. version);
        
        expect(function()
            local _ = net.http.request("http://localhost:8085");
        end).toThrow("ConnectionRefused");

        expect(requests).toHaveLength(1);

        expect(server.stopped).toBe(false);
        server:stop();
        expect(server.stopped).toBe(true);
        server:stop();
        expect(server.stopped).toBe(true);

        expect(requests);

        expect(function()
            local _ = net.http.request("http://localhost:8080");
        end).toThrow("ConnectionRefused");

        expect(requests).toHaveLength(1);
    end)

    test("Other method", function()
        local requests: {ServerRequest} = {};
        local server = net.http.serve({
            port = 8080,
            reuseAddress = true,
            request = function(req)
                table.insert(requests, req);
                return {
                    statusCode = 200,
                    body = "Hello",
                }
            end,
        });
        testing.defer(function()
            server:stop();
        end)
        expect(server).toBe(expect.type("userdata"));

        local res = net.http.request("http://localhost:8080", {
            method = "PUT",
            headers = {
                ["Content-Type"] = "text/plain",
            },
            body = "test",
        });
        expect(res).toBe(expect.type("table"));
        expect(res.ok).toBe(true);
        expect(res.statusCode).toBe(200);
        expect(res.body).toBe("Hello");
        expect(res.headers).toBe(expect.type("table"));
        expect(res.headers["Content-Length"]).toBe("5");
        expect(res.statusReason).toBe("OK");

        expect(requests).toHaveLength(1);

        local request = requests[1];
        expect(request).toBe(expect.type("table"));
        expect(request.method).toBe("PUT");
        expect(request.path).toBe("/");
        expect(request.headers).toBe(expect.type("table"));
        expect(request.headers["host"]).toBe("localhost:8080");
        expect(request.headers["user-agent"]).toBe("Zune/" .. version);
        expect(request.headers["content-type"]).toBe("text/plain");
        expect(request.headers["content-length"]).toBe("4");
        expect(request.body).toBe("test");
    end)

    test("Basic Table Buffer", function()
        local requests = {};
        local server = net.http.serve({
            port = 8080,
            reuseAddress = true,
            request = function(req)
                table.insert(requests, req);
                return {
                    statusCode = 200,
                    body = buffer.fromstring("Hello Table Buffer"),
                }
            end,
        });
        expect(server).toBe(expect.type("userdata"));

        local res = net.http.request("http://localhost:8080");
        expect(res).toBe(expect.type("table"));
        expect(res.ok).toBe(true);
        expect(res.statusCode).toBe(200);
        expect(res.body).toBe("Hello Table Buffer");
        expect(res.headers).toBe(expect.type("table"));
        expect(res.headers["Content-Length"]).toBe("18");
        expect(res.statusReason).toBe("OK");

        expect(requests).toHaveLength(1);

        local request = requests[1];
        expect(request).toBe(expect.type("table"));
        expect(request.method).toBe("GET");
        expect(request.path).toBe("/");
        expect(request.headers).toBe(expect.type("table"));
        expect(request.headers["host"]).toBe("localhost:8080");
        expect(request.headers["user-agent"]).toBe("Zune/" .. version);

        expect(server.stopped).toBe(false);
        server:stop();
        expect(server.stopped).toBe(true);
    end)

    test("Basic Buffer", function()
        local requests = {};
        local server = net.http.serve({
            port = 8080,
            reuseAddress = true,
            request = function(req)
                table.insert(requests, req);
                return buffer.fromstring("Hello Buffer");
            end,
        });
        expect(server).toBe(expect.type("userdata"));

        local res = net.http.request("http://localhost:8080");
        expect(res).toBe(expect.type("table"));
        expect(res.ok).toBe(true);
        expect(res.statusCode).toBe(200);
        expect(res.body).toBe("Hello Buffer");
        expect(res.headers).toBe(expect.type("table"));
        expect(res.headers["Content-Length"]).toBe("12");
        expect(res.statusReason).toBe("OK");

        expect(requests).toHaveLength(1);

        local request = requests[1];
        expect(request).toBe(expect.type("table"));
        expect(request.method).toBe("GET");
        expect(request.path).toBe("/");
        expect(request.headers).toBe(expect.type("table"));
        expect(request.headers["host"]).toBe("localhost:8080");
        expect(request.headers["user-agent"]).toBe("Zune/" .. version);

        expect(server.stopped).toBe(false);
        server:stop();
        expect(server.stopped).toBe(true);
    end)

    test("Long Term", function()
        local requests = {};
        local server = net.http.serve({
            port = 8080,
            reuseAddress = true,
            request = function(req)
                table.insert(requests, req);
                return "Hello: " .. #requests;
            end,
        });
        expect(server).toBe(expect.type("userdata"));

        local requestsMade = 0;

        for _ = 1, 10 do
            local res = net.http.request("http://localhost:8080");
            requestsMade += 1;

            expect(res).toBe(expect.type("table"));
            expect(res.ok).toBe(true);
            expect(res.statusCode).toBe(200);
            expect(res.body).toBe("Hello: " .. requestsMade);
            expect(res.headers).toBe(expect.type("table"));
            expect(res.headers["Content-Length"]).toBe(tostring(7 + #tostring(requestsMade)));
            expect(res.statusReason).toBe("OK");

            expect(requests).toHaveLength(requestsMade);

            local request = requests[requestsMade];
            expect(request).toBe(expect.type("table"));
            expect(request.method).toBe("GET");
            expect(request.path).toBe("/");
            expect(request.headers).toBe(expect.type("table"));
            expect(request.headers["host"]).toBe("localhost:8080");
            expect(request.headers["user-agent"]).toBe("Zune/" .. version);

        end

        expect(function()
            local _ = net.http.request("http://localhost:8085");
        end).toThrow("ConnectionRefused");

        expect(requests).toHaveLength(requestsMade);

        expect(server.stopped).toBe(false);
        server:stop();
        expect(server.stopped).toBe(true);
        server:stop();
        expect(server.stopped).toBe(true);

        expect(function()
            local _ = net.http.request("http://localhost:8080");
        end).toThrow("ConnectionRefused");

        expect(requests).toHaveLength(requestsMade);
    end)

    describe("Server Error", function()
        test("Immediate", function()
            local server = net.http.serve({
                port = 8080,
                reuseAddress = true,
                request = function(req)
                    error("Server Error");
                end,
            });
            expect(server).toBe(expect.type("userdata"));

            testing.defer(function()
                server:stop();
            end)
    
            local res = net.http.request("http://localhost:8080");
            expect(res).toBe(expect.type("table"));
            expect(res.ok).toBe(false);
            expect(res.statusCode).toBe(500);
            expect(res.body).toBe("An error occurred on the server");
            expect(res.headers).toBe(expect.type("table"));
            expect(res.headers["Content-Length"]).toBe("31");
            expect(res.headers["Content-Type"]).toBe("text/plain");
            expect(res.statusReason).toBe("Internal Server Error");
        end)
        test("Yielded", function()
            local server = net.http.serve({
                port = 8080,
                reuseAddress = true,
                request = function(req)
                    task.wait();
                    error("Server Error");
                end,
            });
            expect(server).toBe(expect.type("userdata"));

            testing.defer(function()
                server:stop();
            end)
    
            local res = net.http.request("http://localhost:8080");
            expect(res).toBe(expect.type("table"));
            expect(res.ok).toBe(false);
            expect(res.statusCode).toBe(500);
            expect(res.body).toBe("An error occurred on the server");
            expect(res.headers).toBe(expect.type("table"));
            expect(res.headers["Content-Length"]).toBe("31");
            expect(res.headers["Content-Type"]).toBe("text/plain");
            expect(res.statusReason).toBe("Internal Server Error");
        end)
    end)
end)

describe("Requests", function()
    test("Basic", function()
        local server = net.http.serve({
            port = 8080,
            reuseAddress = true,
            request = function(req)
                return {
                    statusCode = 200,
                    body = "Hello",
                    headers = {
                        ["Content-Type"] = "text/plain",
                    },
                }
            end,
        });
        testing.defer(function()
            server:stop();
        end)
        local res = net.http.request("http://localhost:8080", {
            method = "GET",
            headers = {
                ["Content-Type"] = "text/plain",
            },
        });
        expect(res).toBe(expect.type("table"));
        expect(res.ok).toBe(true);
        expect(res.statusCode).toBe(200);
        expect(res.body).toBe("Hello");
        expect(res.headers).toBe(expect.type("table"));
        expect(res.headers["Content-Length"]).toBe("5");
        expect(res.headers["Content-Type"]).toBe("text/plain");
        expect(res.statusReason).toBe("OK");
    end)
    if (zune.process.args[1] ~= "allow") then
        return;
    end
    test("TLS", function()
        local res = net.http.request("https://github.com", {
            method = "GET",
            headers = {
                ["Content-Type"] = "text/plain",
            },
        });
        expect(res).toBe(expect.type("table"));
        expect(res.ok).toBe(true);
        expect(res.statusCode).toBe(200);
        expect(res.body).toBe(expect.type("string"));
        expect(res.headers).toBe(expect.type("table"));
        expect(res.headers["Content-Type"]).toBe(expect.type("string"));
    end)
end)

describe("Websockets", function()
    test("Generic", function()
        local upgradeCalled = false;
        local serverOpened = false;
        local serverClosed = false;
        local serverMessageCount = 0;
        local references = {};
        local reqCalled = false;
        local server = net.http.serve({
            port = 8080,
            reuseAddress = true,
            request = function(req)
                reqCalled = true;
                return "";
            end,
            websocket = {
                upgrade = function(req)
                    upgradeCalled = true;
                    task.wait();
                    return true;
                end,
                open = function(ws)
                    serverOpened = true;
                    ws:send("Hello");
                    if (not table.find(references, ws)) then
                        table.insert(references, ws);
                    end
                end,
                message = function(ws, message)
                    serverMessageCount += 1;
                    ws:send("Echo: " .. message);
                    if (not table.find(references, ws)) then
                        table.insert(references, ws);
                    end

                    if (serverMessageCount == 2) then
                        ws:close();
                    end
                end,
                close = function(ws)
                    serverClosed = true;
                    if (not table.find(references, ws)) then
                        table.insert(references, ws);
                    end
                end,
            },
        });
        expect(server).toBe(expect.type("userdata"));

        testing.defer(function()
            server:stop();
        end)

        local openCalled = false;
        local messageCount = 0;
        local closeCalled = false;
        local socket = net.http.websocket("ws://localhost:8080", {
            timeout = 1,
            open = function(socket)
                expect(upgradeCalled).toBe(true);
                openCalled = true;
            end,
            message = function(socket, message)
                print("Message", message);
                expect(openCalled).toBe(true);
                if (messageCount == 0) then
                    expect(message).toBe("Hello");
                elseif (messageCount == 1) then
                    expect(message).toBe("Echo: Test 1");
                elseif (messageCount == 2) then
                    expect(message).toBe("Echo: Test 2");
                else
                    error("Unexpected message: " .. message);
                end
                messageCount += 1;
            end,
            close = function(socket, closeCode)
                expect(openCalled).toBe(true);
                expect(messageCount).toBe(3);
                expect(closeCode).toBe(1000);
                closeCalled = true;
            end,
        });
        expect(socket).toBe(expect.type("userdata"));
        testing.defer(function()
            socket:close();
        end)

        expect(socket).toBe(expect.type("userdata"));
        expect(socket.connected).toBe(true);

        expect(serverOpened).toBe(true);
        expect(serverMessageCount).toBe(0);
        expect(serverClosed).toBe(false);

        expect(openCalled).toBe(true);
        expect(messageCount).toBe(0);
        task.wait();
        expect(openCalled).toBe(true);
        expect(messageCount).toBe(1);
        
        socket:send("Test 1");
        expect(messageCount).toBe(1);

        socket:send("Test 2");
        expect(messageCount).toBe(1);

        expect(upgradeCalled).toBe(true);
        expect(socket).toBe(expect.type("userdata"));

        repeat
            task.wait();
        until (not socket.connected)

        expect(closeCalled).toBe(true);

        expect(reqCalled).toBe(false);
    end)
end)

describe("UDP", function()
    test("Generic", function()
        local server;
        local client;

        local pass_server = false;
        local pass_client = false;

        server = net.udpSocket({
            data = function(socket, msg, port, address)
                expect(socket).toBe(server);
                expect(msg).toBe("test from client");
                expect(address).toBe("127.0.0.1");
                expect(port).toBe(client.port);
                socket:send("test from server", port, address);
                pass_server = true;
            end
        });
        testing.defer(function()
            server:stop();
        end)

        client = net.udpSocket({
            data = function(socket, msg, port, address)
                expect(socket).toBe(client);
                expect(msg).toBe("test from server");
                expect(address).toBe("127.0.0.1");
                expect(port).toBe(server.port);
                pass_client = true;
            end
        });
        testing.defer(function()
            client:stop();
        end)

        client:send("test from client", server.port, "127.0.0.1")

        task.wait(0.5);

        expect(pass_server).toBe(true);
        expect(pass_client).toBe(true);
    end);

    test("Double Datagram", function()
        local server;
        local client1;
        local client2;

        local pass_server = false;
        local pass_client1 = false;
        local pass_client2 = false;

        server = net.udpSocket({
            data = function(socket, msg, port, address)
                expect(socket).toBe(server);
                expect(msg).toBe("test from client");
                expect(address).toBe("127.0.0.1");
                socket:send("test from server ".. port, port, address);
                pass_server = true;
            end
        });
        testing.defer(function()
            server:stop();
        end)
        expect(server.stopped).toBe(false);

        client1 = net.udpSocket({
            data = function(socket, msg, port, address)
                expect(socket).toBe(client1);
                expect(msg).toBe("test from server ".. client1.port);
                expect(address).toBe("127.0.0.1");
                expect(port).toBe(server.port);
                pass_client1 = true;
            end
        });
        testing.defer(function()
            client1:stop();
        end)
        expect(client1.stopped).toBe(false);

        client2 = net.udpSocket({
            data = function(socket, msg, port, address)
                expect(socket).toBe(client2);
                expect(msg).toBe("test from server " .. client2.port);
                expect(address).toBe("127.0.0.1");
                expect(port).toBe(server.port);
                pass_client2 = true;
            end
        });
        testing.defer(function()
            client2:stop();
        end)
        expect(client2.stopped).toBe(false);

        client1:send("test from client", server.port, "127.0.0.1")
        client2:send("test from client", server.port, "127.0.0.1")

        task.wait(0.5);

        expect(pass_server).toBe(true);
        expect(pass_client1).toBe(true);
        expect(pass_client2).toBe(true);
    end);
end)

describe("TCP", function()
    test("Generic", function()
        local server;
        local client;

        local pass_server = {
            open = false,
            message = false,
            close = false,
        };
        local pass_client = {
            open = false,
            message = false,
            close = false,
        };

        server = net.tcpHost({
            address = "127.0.0.1",
            port = 8088,
            reuseAddress = true,
            open = function(socket)
                expect(socket).toBe(expect.type("userdata"));
                pass_server.open = true;
            end,
            data = function(socket, msg)
                expect(socket).toBe(expect.type("userdata"));
                expect(msg).toBe("test from client");
                pass_server.message = true;
                socket:send("test from server");
            end,
            close = function(socket)
                expect(socket).toBe(expect.type("userdata"));
                pass_server.close = true;
            end
        });
        testing.defer(function()
            server:stop();
        end)
        expect(server.stopped).toBe(false);

        client = net.tcpConnect({
            address = "127.0.0.1",
            port = 8088,
            open = function(socket)
                expect(socket).toBe(client);
                pass_client.open = true;
            end,
            data = function(socket, msg)
                expect(socket).toBe(client);
                expect(msg).toBe("test from server");
                pass_client.message = true;
            end,
            close = function(socket)
                expect(socket).toBe(client);
                pass_client.close = true;
            end
        });
        testing.defer(function()
            client:stop();
        end)
        expect(client.stopped).toBe(false);

        task.wait(0.2);

        expect(pass_server).toBe(expect.similar({ open = true, message = false, close = false }));
        expect(pass_client).toBe(expect.similar({ open = true, message = false, close = false }));

        client:send("test from client");

        task.wait(0.2);

        expect(pass_server).toBe(expect.similar({ open = true, message = true, close = false }));
        expect(pass_client).toBe(expect.similar({ open = true, message = true, close = false }));

        expect(client.stopped).toBe(false);
        client:stop();
        client:stop();
        client:stop();
        expect(client.stopped).toBe(true);

        expect(pass_server).toBe(expect.similar({ open = true, message = true, close = false }));
        expect(pass_client).toBe(expect.similar({ open = true, message = true, close = false }));

        task.wait(0.2);

        expect(pass_server).toBe(expect.similar({ open = true, message = true, close = true }));
        expect(pass_client).toBe(expect.similar({ open = true, message = true, close = true }));
    end);

    test("Double Client Socket", function()
        local server;
        local client1;
        local client2;

        local pass_server = {
            open = 0,
            message = 0,
            close = 0,
        };
        local pass_client1 = {
            open = false,
            message = false,
            close = false,
        };
        local pass_client2 = {
            open = false,
            message = false,
            close = false,
        };

        server = net.tcpHost({
            address = "127.0.0.1",
            port = 8088,
            reuseAddress = true,
            open = function(socket)
                expect(socket).toBe(expect.type("userdata"));
                pass_server.open += 1;
            end,
            data = function(socket, msg)
                expect(socket).toBe(expect.type("userdata"));
                expect(msg).toBe("test from client " .. pass_server.message + 1);
                pass_server.message += 1;
                socket:send("test from server");
            end,
            close = function(socket)
                expect(socket).toBe(expect.type("userdata"));
                pass_server.close += 1;
            end
        });
        testing.defer(function()
            server:stop();
        end)
        expect(server.stopped).toBe(false);

        client1 = net.tcpConnect({
            address = "127.0.0.1",
            port = 8088,
            open = function(socket)
                expect(socket).toBe(client1);
                pass_client1.open = true;
            end,
            data = function(socket, msg)
                expect(socket).toBe(client1);
                expect(msg).toBe("test from server");
                pass_client1.message = true;
            end,
            close = function(socket)
                expect(socket).toBe(client1);
                pass_client1.close = true;
            end
        });
        testing.defer(function()
            client1:stop();
        end)
        expect(client1.stopped).toBe(false);

        client2 = net.tcpConnect({
            address = "127.0.0.1",
            port = 8088,
            open = function(socket)
                expect(socket).toBe(client2);
                pass_client2.open = true;
            end,
            data = function(socket, msg)
                expect(socket).toBe(client2);
                expect(msg).toBe("test from server");
                pass_client2.message = true;
            end,
            close = function(socket)
                expect(socket).toBe(client2);
                pass_client2.close = true;
            end
        });
        testing.defer(function()
            client2:stop();
        end)
        expect(client2.stopped).toBe(false);

        task.wait(0.2);

        expect(pass_server).toBe(expect.similar({ open = 2, message = 0, close = 0 }));
        expect(pass_client1).toBe(expect.similar({ open = true, message = false, close = false }));
        expect(pass_client2).toBe(expect.similar({ open = true, message = false, close = false }));

        client1:send("test from client 1");
        client2:send("test from client 2");

        task.wait(0.2);

        expect(pass_server).toBe(expect.similar({ open = 2, message = 2, close = 0 }));
        expect(pass_client1).toBe(expect.similar({ open = true, message = true, close = false }));
        expect(pass_client2).toBe(expect.similar({ open = true, message = true, close = false }));

        expect(client2.stopped).toBe(false);
        expect(client2.stopped).toBe(false);
        client1:stop();
        client2:stop();
        client1:stop();
        client2:stop();
        expect(client1.stopped).toBe(true);
        expect(client2.stopped).toBe(true);

        expect(pass_server).toBe(expect.similar({ open = 2, message = 2, close = 0 }));
        expect(pass_client1).toBe(expect.similar({ open = true, message = true, close = false }));
        expect(pass_client2).toBe(expect.similar({ open = true, message = true, close = false }));

        task.wait(0.2);

        expect(pass_server).toBe(expect.similar({ open = 2, message = 2, close = 2 }));
        expect(pass_client1).toBe(expect.similar({ open = true, message = true, close = true }));
        expect(pass_client2).toBe(expect.similar({ open = true, message = true, close = true }));
    end);
end)
