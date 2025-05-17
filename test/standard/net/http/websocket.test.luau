--!strict
local net = zune.net;
local task = zune.task;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local _, version, _ = string.match(_VERSION, "(Zune) (%d+%.%d+%.%d+.*)+(%d+%.%d+)");
assert(version and #version > 0, "No version");

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
        task.wait(0.5);
    until (not socket.connected)

    expect(closeCalled).toBe(true);

    expect(reqCalled).toBe(false);
end)

return nil;
