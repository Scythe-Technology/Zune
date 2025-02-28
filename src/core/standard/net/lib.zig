const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

const Scheduler = @import("../../runtime/scheduler.zig");

const luaHelper = @import("../../utils/luahelper.zig");

const Socket = @import("../../objects/network/Socket.zig");

const UDP = @import("udp.zig");
const TCP = @import("tcp.zig");
const HttpServer = @import("httpserver.zig");
const HttpClient = @import("httpclient.zig");
const WebSocketClient = @import("websocket.zig");

pub const LIB_NAME = "net";

fn net_createSocket(L: *VM.lua.State) !i32 {
    if (!L.isyieldable())
        return L.Zyielderror();
    const domain = L.Lcheckunsigned(1);
    const flags = L.Lcheckunsigned(2);
    const protocol = L.Lcheckunsigned(3);

    const socket = try std.posix.socket(domain, flags, protocol);

    try Socket.push(L, socket);

    return 1;
}

fn net_getAddressList(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const name = L.Lcheckstring(1);
    const port = L.Lcheckunsigned(2);
    if (port > std.math.maxInt(u16))
        return L.Zerror("PortOutOfRange");
    const list = try std.net.getAddressList(allocator, name, @intCast(port));
    defer list.deinit();
    if (list.addrs.len > std.math.maxInt(i32))
        return L.Zerror("AddressListTooLarge");
    L.createtable(@intCast(list.addrs.len), 0);
    for (list.addrs, 1..) |address, i| {
        var buf: [Socket.LONGEST_ADDRESS]u8 = undefined;
        L.Zpushvalue(.{
            .family = address.any.family,
            .port = address.getPort(),
            .address = Socket.AddressToString(&buf, address),
        });
        L.rawseti(-2, @intCast(i));
    }
    return 1;
}

fn ImportConstants(L: *VM.lua.State, namespace: anytype, comptime name: [:0]const u8) void {
    L.createtable(0, @typeInfo(namespace).@"struct".decls.len);

    inline for (@typeInfo(namespace).@"struct".decls) |field|
        L.Zsetfield(-1, field.name, @as(i32, @field(namespace, field.name)));

    L.setreadonly(-1, true);
    L.setfield(-2, name);
}

pub fn loadLib(L: *VM.lua.State) void {
    HttpServer.lua_load(L);
    WebSocketClient.lua_load(L);
    UDP.lua_load(L);
    TCP.lua_load(L);

    L.createtable(0, 11);

    L.Zsetfieldfn(-1, "udpSocket", UDP.lua_udpsocket);
    L.Zsetfieldfn(-1, "tcpConnect", TCP.lua_tcp_client);
    L.Zsetfieldfn(-1, "tcpHost", TCP.lua_tcp_server);

    {
        L.createtable(0, 3);

        L.Zsetfieldfn(-1, "serve", HttpServer.lua_serve);
        L.Zsetfieldfn(-1, "request", HttpClient.lua_request);
        L.Zsetfieldfn(-1, "websocket", WebSocketClient.lua_websocket);

        L.setreadonly(-1, true);
        L.setfield(-2, "http");
    }

    L.Zsetfieldfn(-1, "createSocket", net_createSocket);
    L.Zsetfieldfn(-1, "getAddressList", net_getAddressList);

    ImportConstants(L, std.posix.AF, "ADDRF");
    ImportConstants(L, std.posix.SOCK, "SOCKF");
    ImportConstants(L, std.posix.IPPROTO, "IPPROTO");
    ImportConstants(L, std.posix.SO, "SOCKOPT");
    ImportConstants(L, std.posix.SOL, "SOCKOPTLV");

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
