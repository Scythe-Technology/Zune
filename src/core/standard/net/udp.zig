const std = @import("std");
const luau = @import("luau");

const Common = @import("common.zig");

const Scheduler = @import("../../runtime/scheduler.zig");

const VM = luau.VM;

const prepRefType = Common.prepRefType;

const Self = @This();

ref: i32,
socket: std.posix.socket_t,
handlers: LuaMeta.Handlers,
port: u16,
stopped: bool,

pub const LuaMeta = struct {
    pub const META = "net_udp_instance";
    pub fn __index(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const self = L.touserdata(Self, 1) orelse unreachable;

        const arg = L.Lcheckstring(2);

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, arg, "port")) {
            L.pushinteger(@intCast(self.port));
            return 1;
        } else if (std.mem.eql(u8, arg, "stopped")) {
            L.pushboolean(self.stopped);
            return 1;
        }
        return 0;
    }

    pub fn __namecall(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const self = L.touserdata(Self, 1) orelse unreachable;

        const namecall = L.namecallstr() orelse return 0;

        var scheduler = Scheduler.getScheduler(L);

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "stop")) {
            if (self.stopped)
                return 0;
            self.stopped = true;
            scheduler.deferThread(L, null, 0); // resume on next task
            return L.yield(0);
        } else if (std.mem.eql(u8, namecall, "send")) {
            if (self.stopped)
                return 0;
            const data = try L.Zcheckvalue([]const u8, 2, null);
            const port = try L.Zcheckvalue(u16, 3, null);
            const address_name = try L.Zcheckvalue([]const u8, 4, null);
            const address = try std.net.Address.parseIp4(address_name, @intCast(port));

            _ = try std.posix.sendto(
                self.socket,
                data,
                0,
                &address.any,
                address.getOsSockLen(),
            );
        } else return L.Zerrorf("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub const Handlers = struct {
        message: ?i32,
    };
};

pub fn update(ctx: *Self, L: *VM.lua.State, _: *Scheduler) Scheduler.TaskResult {
    if (ctx.stopped)
        return .Stop;
    var buf: [8192]u8 = undefined;
    var address: std.net.Address = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    const read_len = std.posix.recvfrom(ctx.socket, &buf, 0, &address.any, &len) catch |err| switch (err) {
        error.WouldBlock => return .Continue,
        else => {
            std.debug.print("Udp Error: {}\n", .{err});
            return .Stop;
        },
    };
    if (ctx.handlers.message) |fnRef| {
        if (!prepRefType(.Function, L, fnRef))
            return .Stop;
        if (!prepRefType(.Userdata, L, ctx.ref)) {
            L.pop(1);
            return .Stop;
        }

        const allocator = luau.getallocator(L);

        const bytes = @as(*const [4]u8, @ptrCast(&address.in.sa.addr));
        const address_name = std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
        }) catch |err| {
            std.debug.print("Failed to format address: {}\n", .{err});
            return .Stop;
        };
        defer allocator.free(address_name);

        const thread = L.newthread();
        L.xpush(thread, -3); // push: Function
        L.xpush(thread, -2); // push: Userdata
        thread.pushlstring(buf[0..read_len]);
        thread.pushinteger(@intCast(address.getPort()));
        thread.pushlstring(address_name);
        L.pop(3); // drop thread, function & userdata

        _ = Scheduler.resumeState(thread, L, 4) catch {};
        return .ContinueFast;
    }
    return .Continue;
}

pub fn dtor(ctx: *Self, L: *VM.lua.State, _: *Scheduler) void {
    std.posix.close(ctx.socket);
    if (ctx.handlers.message) |ref|
        L.unref(ref);
    L.unref(ctx.ref);
}

pub fn lua_udpsocket(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);
    var data_ref: ?i32 = null;
    errdefer if (data_ref) |ref| L.unref(ref);

    try L.Zchecktype(1, .Table);

    const address_ip = try L.Zcheckfield(?[]const u8, 1, "address") orelse "127.0.0.1";

    const port = try L.Zcheckfield(?u16, 1, "port") orelse 0;
    L.pop(1);

    const dataType = L.getfield(1, "data");
    if (!dataType.isnoneornil()) {
        if (dataType != .Function)
            return L.Zerror("Field 'data' must be a function");
        data_ref = L.ref(-1) orelse unreachable;
    }
    L.pop(1);

    const address = try std.net.Address.parseIp4(address_ip, port);
    const sock: std.posix.socket_t = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, 0);
    _ = try std.posix.bind(sock, &address.any, address.getOsSockLen());

    var sys_address: std.net.Address = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    try std.posix.getsockname(sock, &sys_address.any, &len);

    const self = L.newuserdata(Self);

    self.* = .{
        .ref = L.ref(-1) orelse unreachable,
        .socket = sock,
        .port = sys_address.getPort(),
        .stopped = false,
        .handlers = .{
            .message = data_ref,
        },
    };

    if (L.Lgetmetatable(LuaMeta.META) == .Table) {
        _ = L.setmetatable(-2);
    } else std.debug.panic("InternalError (UDP Metatable not initialized)", .{});

    scheduler.addTask(Self, self, L, update, dtor);

    return 1;
}

pub fn lua_load(L: *VM.lua.State) void {
    _ = L.Znewmetatable(LuaMeta.META, .{
        .__index = LuaMeta.__index,
        .__namecall = LuaMeta.__namecall,
        .__metatable = "Metatable is locked",
    });
    L.setreadonly(-1, true);
    L.pop(1);
}
