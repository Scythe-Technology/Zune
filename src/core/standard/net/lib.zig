const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

const Scheduler = @import("../../runtime/scheduler.zig");

const luaHelper = @import("../../utils/luahelper.zig");

const UDP = @import("udp.zig");
const TCP = @import("tcp.zig");
const HttpServer = @import("httpserver.zig");
const HttpClient = @import("httpclient.zig");
const WebSocketClient = @import("websocket.zig");

pub const LIB_NAME = "net";

pub fn loadLib(L: *VM.lua.State) void {
    HttpServer.lua_load(L);
    WebSocketClient.lua_load(L);
    UDP.lua_load(L);
    TCP.lua_load(L);

    L.newtable();

    L.Zsetfieldc(-1, "udpSocket", UDP.lua_udpsocket);
    L.Zsetfieldc(-1, "tcpConnect", TCP.lua_tcp_client);
    L.Zsetfieldc(-1, "tcpHost", TCP.lua_tcp_server);

    {
        L.newtable();

        L.Zsetfieldc(-1, "serve", HttpServer.lua_serve);
        L.Zsetfieldc(-1, "request", HttpClient.lua_request);
        L.Zsetfieldc(-1, "websocket", WebSocketClient.lua_websocket);

        L.setreadonly(-1, true);
        L.setfield(-2, "http");
    }

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test {
    _ = @import("http/request.zig");
}
test {
    _ = @import("http/response.zig");
}

test "Net" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"net.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
