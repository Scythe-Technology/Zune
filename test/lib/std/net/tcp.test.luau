--!strict
local task = zune.task;
local testing = zune.testing;

local expect = testing.expect;
local test = testing.test;

local tcp = require("@std/net/tcp");

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

    server = tcp.host({
        address = "127.0.0.1",
        port = 8088,
        reuseAddress = true,
        open = function(socket)
            expect(socket).toBe(expect.type("table"));
            pass_server.open = true;
        end,
        data = function(socket, msg)
            expect(socket).toBe(expect.type("table"));
            expect(msg).toBe("test from client");
            pass_server.message = true;
            socket:send("test from server");
        end,
        close = function(socket)
            expect(socket).toBe(expect.type("table"));
            pass_server.close = true;
        end
    });
    testing.defer(function()
        server:stop();
    end)
    expect(server.stopped).toBe(false);

    client = tcp.connect({
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
end)

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

    server = tcp.host({
        address = "127.0.0.1",
        port = 8088,
        reuseAddress = true,
        open = function(socket)
            expect(socket).toBe(expect.type("table"));
            pass_server.open += 1;
        end,
        data = function(socket, msg)
            expect(socket).toBe(expect.type("table"));
            expect(msg).toBe("test from client " .. pass_server.message + 1);
            pass_server.message += 1;
            socket:send("test from server");
        end,
        close = function(socket)
            expect(socket).toBe(expect.type("table"));
            pass_server.close += 1;
        end
    });
    testing.defer(function()
        server:stop();
    end)
    expect(server.stopped).toBe(false);

    client1 = tcp.connect({
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

    client2 = tcp.connect({
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
end)

return nil;
