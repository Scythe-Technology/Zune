const std = @import("std");
const luau = @import("luau");

const Luau = luau.Luau;

const Scheduler = @import("../../runtime/scheduler.zig");

const luaHelper = @import("../../utils/luahelper.zig");

const UDP = @import("udp.zig");
const TCP = @import("tcp.zig");
const HttpServer = @import("httpserver.zig");
const HttpClient = @import("httpclient.zig");
const WebSocketClient = @import("websocket.zig");

pub const LIB_NAME = "net";

pub fn loadLib(L: *Luau) void {
    HttpServer.lua_load(L);
    WebSocketClient.lua_load(L);
    UDP.lua_load(L);
    TCP.lua_load(L);

    L.newTable();

    L.setFieldFn(-1, "udpSocket", Scheduler.toSchedulerEFn(UDP.lua_udpsocket));
    L.setFieldFn(-1, "tcpConnect", Scheduler.toSchedulerEFn(TCP.lua_tcp_client));
    L.setFieldFn(-1, "tcpHost", Scheduler.toSchedulerEFn(TCP.lua_tcp_server));

    {
        L.newTable();

        L.setFieldFn(-1, "serve", Scheduler.toSchedulerEFn(HttpServer.lua_serve));
        L.setFieldFn(-1, "request", Scheduler.toSchedulerEFn(HttpClient.lua_request));
        L.setFieldFn(-1, "websocket", Scheduler.toSchedulerEFn(WebSocketClient.lua_websocket));

        L.setReadOnly(-1, true);
        L.setField(-2, "http");
    }

    L.setReadOnly(-1, true);
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
