const std = @import("std");
const luau = @import("luau");

const Luau = luau.Luau;

const Scheduler = @import("../../runtime/scheduler.zig");

const HttpServer = @import("httpserver.zig");
const HttpClient = @import("httpclient.zig");
const WebSocketClient = @import("websocket.zig");

pub fn loadLib(L: *Luau) !void {
    try HttpServer.lua_load(L);
    try WebSocketClient.lua_load(L);

    L.newTable();

    L.setFieldFn(-1, "serve", Scheduler.toSchedulerFn(HttpServer.lua_serve));
    L.setFieldFn(-1, "request", Scheduler.toSchedulerFn(HttpClient.lua_request));
    L.setFieldFn(-1, "websocket", Scheduler.toSchedulerFn(WebSocketClient.lua_websocket));

    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (L.getField(-1, "@zcore/net") != .table) {
        L.pop(1);
        L.pushValue(-2);
        L.setField(-2, "@zcore/net");
    } else L.pop(1);
    L.pop(2);
}

test {
    _ = @import("http/request.zig");
}
test {
    _ = @import("http/response.zig");
}

test "Net" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, "test/standard/net.test.luau", &.{});

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
