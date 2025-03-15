--!strict
local task = zune.task;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local mem = require("@std/mem");

local Server = require("@std/net/http/server");

local _, version, _ = string.match(_VERSION, "(Zune) (%d+%.%d+%.%d+.*)+(%d+%.%d+)");
assert(version and #version > 0, "No version");

describe("Server", function()
    test("Basic", function()
        local requests: {Server.Request} = {};
        local server = Server.serve({
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
        expect(server).toBe(expect.type("table"));

        local rRes = zune.net.http.request("http://localhost:8080");
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
            local _ = zune.net.http.request("http://localhost:8085");
        end).toThrow("ConnectionRefused");

        expect(requests).toHaveLength(1);

        expect(server.stopped).toBe(false);
        server:stop();
        expect(server.stopped).toBe(true);
        server:stop();
        expect(server.stopped).toBe(true);

        expect(requests);

        task.wait(1); -- wait for the server to stop

        expect(function()
            local _ = zune.net.http.request("http://localhost:8080");
        end).toThrow("ConnectionRefused");

        expect(requests).toHaveLength(1);
    end)

    test("Basic Table Buffer", function()
        local requests = {};
        local server = Server.serve({
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
        expect(server).toBe(expect.type("table"));

        local rRes = zune.net.http.request("http://localhost:8080");
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
        local server = Server.serve({
            port = 8080,
            reuseAddress = true,
            request = function(req)
                table.insert(requests, req);
                return buffer.fromstring("Hello Buffer");
            end,
        });
        expect(server).toBe(expect.type("table"));

        local rRes = zune.net.http.request("http://localhost:8080");
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
        local server = Server.serve({
            port = 8080,
            reuseAddress = true,
            request = function(req)
                table.insert(requests, req);
                return "Hello: " .. #requests;
            end,
        });
        expect(server).toBe(expect.type("table"));

        local requestsMade = 0;

        for _ = 1, 10 do
            local rRes = zune.net.http.request("http://localhost:8080");
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
            local _ = zune.net.http.request("http://localhost:8085");
        end).toThrow("ConnectionRefused");

        expect(requests).toHaveLength(requestsMade);

        expect(server.stopped).toBe(false);
        server:stop();
        expect(server.stopped).toBe(true);
        server:stop();
        expect(server.stopped).toBe(true);

        task.wait(1); -- wait for the server to stop

        expect(function()
            local _ = zune.net.http.request("http://localhost:8080");
        end).toThrow("ConnectionRefused");

        expect(requests).toHaveLength(requestsMade);
    end)

    describe("Server Error", function()
        test("Immediate", function()
            local server = Server.serve({
                port = 8080,
                reuseAddress = true,
                request = function(req)
                    error("Server Error");
                end,
            });
            expect(server).toBe(expect.type("table"));

            testing.defer(function()
                server:stop();
            end)
    
            local rRes = zune.net.http.request("http://localhost:8080");
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
            local server = Server.serve({
                port = 8080,
                reuseAddress = true,
                request = function(req)
                    task.wait();
                    error("Server Error");
                end,
            });
            expect(server).toBe(expect.type("table"));

            testing.defer(function()
                server:stop();
            end)
    
            local rRes = zune.net.http.request("http://localhost:8080");
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