--!strict
local task = zune.task;
local testing = zune.testing;

local expect = testing.expect;
local test = testing.test;

local udp = require("@std/net/udp");

test("Generic", function()
    local server;
    local client;

    local pass_server = false;
    local pass_client = false;

    server = udp.createAsync({
        data = function(socket, msg, port, address)
            expect(socket).toBe(server);
            expect(buffer.tostring(msg)).toBe("test from client");
            expect(address).toBe("127.0.0.1");
            expect(port).toBe(client.port);
            socket:send("test from server", port, address);
            pass_server = true;
        end
    });
    testing.defer(function()
        server:stop();
    end)

    client = udp.createAsync({
        data = function(socket, msg, port, address)
            expect(socket).toBe(client);
            expect(buffer.tostring(msg)).toBe("test from server");
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
end)

test("Double Datagram", function()
    local server;
    local client1;
    local client2;

    local pass_server = false;
    local pass_client1 = false;
    local pass_client2 = false;

    server = udp.createAsync({
        data = function(socket, msg, port, address)
            expect(socket).toBe(server);
            expect(buffer.tostring(msg)).toBe("test from client");
            expect(address).toBe("127.0.0.1");
            socket:send("test from server ".. port, port, address);
            pass_server = true;
        end
    });
    testing.defer(function()
        server:stop();
    end)
    expect(server.stopped).toBe(false);

    client1 = udp.createAsync({
        data = function(socket, msg, port, address)
            expect(socket).toBe(client1);
            expect(buffer.tostring(msg)).toBe("test from server ".. client1.port);
            expect(address).toBe("127.0.0.1");
            expect(port).toBe(server.port);
            pass_client1 = true;
        end
    });
    testing.defer(function()
        client1:stop();
    end)
    expect(client1.stopped).toBe(false);

    client2 = udp.createAsync({
        data = function(socket, msg, port, address)
            expect(socket).toBe(client2);
            expect(buffer.tostring(msg)).toBe("test from server " .. client2.port);
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
end)

return nil;
