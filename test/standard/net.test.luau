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
        local requests = {};
        local server = net.serve({
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

        local rRes = net.request("http://localhost:8080");
        expect(rRes).toBe(expect.type("table"));
        expect(rRes.ok).toBe(true);
        expect(rRes.statusCode).toBe(200);
        expect(rRes.body).toBe("Hello");
        expect(rRes.headers).toBe(expect.type("table"));
        expect(rRes.headers["content-length"]).toBe("5");
        expect(rRes.statusReason).toBe("OK");

        expect(requests).toHaveLength(1);

        local request = requests[1];
        expect(request).toBe(expect.type("table"));
        expect(request.method).toBe("GET");
        expect(request.path).toBe("/");
        expect(request.headers).toBe(expect.type("table"));
        expect(request.headers["host"]).toBe("localhost:8080");
        expect(request.headers["user-agent"]).toBe("Zune/" .. version);

        
        expect(function()
            local _ = net.request("http://localhost:8085");
        end).toThrow("ConnectionRefused");

        expect(requests).toHaveLength(1);

        expect(server.stopped).toBe(false);
        server:stop();
        expect(server.stopped).toBe(true);
        server:stop();
        expect(server.stopped).toBe(true);

        expect(requests);

        expect(function()
            local _ = net.request("http://localhost:8080");
        end).toThrow("ConnectionRefused");

        expect(requests).toHaveLength(1);
    end)

    test("Basic Table Buffer", function()
        local requests = {};
        local server = net.serve({
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

        local rRes = net.request("http://localhost:8080");
        expect(rRes).toBe(expect.type("table"));
        expect(rRes.ok).toBe(true);
        expect(rRes.statusCode).toBe(200);
        expect(rRes.body).toBe("Hello Table Buffer");
        expect(rRes.headers).toBe(expect.type("table"));
        expect(rRes.headers["content-length"]).toBe("18");
        expect(rRes.statusReason).toBe("OK");

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
        local server = net.serve({
            port = 8080,
            reuseAddress = true,
            request = function(req)
                table.insert(requests, req);
                return buffer.fromstring("Hello Buffer");
            end,
        });
        expect(server).toBe(expect.type("userdata"));

        local rRes = net.request("http://localhost:8080");
        expect(rRes).toBe(expect.type("table"));
        expect(rRes.ok).toBe(true);
        expect(rRes.statusCode).toBe(200);
        expect(rRes.body).toBe("Hello Buffer");
        expect(rRes.headers).toBe(expect.type("table"));
        expect(rRes.headers["content-length"]).toBe("12");
        expect(rRes.statusReason).toBe("OK");

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
        local server = net.serve({
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
            local rRes = net.request("http://localhost:8080");
            requestsMade += 1;

            expect(rRes).toBe(expect.type("table"));
            expect(rRes.ok).toBe(true);
            expect(rRes.statusCode).toBe(200);
            expect(rRes.body).toBe("Hello: " .. requestsMade);
            expect(rRes.headers).toBe(expect.type("table"));
            expect(rRes.headers["content-length"]).toBe(tostring(7 + #tostring(requestsMade)));
            expect(rRes.statusReason).toBe("OK");

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
            local _ = net.request("http://localhost:8085");
        end).toThrow("ConnectionRefused");

        expect(requests).toHaveLength(requestsMade);

        expect(server.stopped).toBe(false);
        server:stop();
        expect(server.stopped).toBe(true);
        server:stop();
        expect(server.stopped).toBe(true);

        expect(function()
            local _ = net.request("http://localhost:8080");
        end).toThrow("ConnectionRefused");

        expect(requests).toHaveLength(requestsMade);
    end)

    describe("Server Error", function()
        test("Immediate", function()
            local server = net.serve({
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
    
            local rRes = net.request("http://localhost:8080");
            expect(rRes).toBe(expect.type("table"));
            expect(rRes.ok).toBe(false);
            expect(rRes.statusCode).toBe(500);
            expect(rRes.body).toBe("An error occurred on the server");
            expect(rRes.headers).toBe(expect.type("table"));
            expect(rRes.headers["content-length"]).toBe("31");
            expect(rRes.headers["content-type"]).toBe("text/plain");
            expect(rRes.statusReason).toBe("Internal Server Error");
        end)
        test("Yielded", function()
            local server = net.serve({
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
    
            local rRes = net.request("http://localhost:8080");
            expect(rRes).toBe(expect.type("table"));
            expect(rRes.ok).toBe(false);
            expect(rRes.statusCode).toBe(500);
            expect(rRes.body).toBe("An error occurred on the server");
            expect(rRes.headers).toBe(expect.type("table"));
            expect(rRes.headers["content-length"]).toBe("31");
            expect(rRes.headers["content-type"]).toBe("text/plain");
            expect(rRes.statusReason).toBe("Internal Server Error");
        end)
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
        local server = net.serve({
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
        local socket = net.websocket("ws://localhost:8080", {
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
