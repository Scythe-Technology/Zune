const std = @import("std");
const xev = @import("xev").Dynamic;
const luau = @import("luau");
const builtin = @import("builtin");

const Scheduler = @import("../../../runtime/scheduler.zig");
const Response = @import("../http/response.zig");
const WebSocket = @import("../http/websocket.zig");
const luaHelper = @import("../../../utils/luahelper.zig");

const zune_info = @import("zune-info");

const VM = luau.VM;

const Self = @This();

const ZUNE_CLIENT_HEADER = "Zune/" ++ zune_info.version;

const RequestAsyncContext = struct {
    completion: xev.Completion,
    task: xev.ThreadPool.Task,

    ref: Scheduler.ThreadRef,
    client: std.http.Client,
    request: std.http.Client.Request,
    payload: ?[]const u8 = null,
    server_header_buffer: []u8,
    err: anyerror = error.TimedOut,

    fn doWork(self: *RequestAsyncContext) !void {
        try self.request.send();
        if (self.payload) |p|
            try self.request.writeAll(p);
        try self.request.finish();

        self.request.wait() catch |err| switch (err) {
            error.RedirectRequiresResend => return error.Retry,
            else => return err,
        };
    }

    pub fn task_thread_main(task: *xev.ThreadPool.Task) void {
        const self: *RequestAsyncContext = @fieldParentPtr("task", task);

        const scheduler = Scheduler.getScheduler(self.ref.value);

        while (true) {
            self.doWork() catch |err| switch (err) {
                error.Retry => continue,
                else => {
                    self.err = err;
                    break;
                },
            };
            self.err = error.Completed;
            break;
        }

        scheduler.synchronize(self);
    }

    pub fn complete(self: *RequestAsyncContext) void {
        const L = self.ref.value;

        const allocator = luau.getallocator(L);

        defer allocator.free(self.server_header_buffer);
        defer if (self.payload) |p| allocator.free(p);
        defer self.ref.deref();
        defer self.client.deinit();
        defer self.request.deinit();
        defer if (self.request.extra_headers.len > 0) {
            for (self.request.extra_headers) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }
            allocator.free(self.request.extra_headers);
        };

        if (L.status() != .Yield)
            return;

        switch (self.err) {
            error.Completed => {
                const status = @as(u10, @intFromEnum(self.request.response.status));
                L.Zpushvalue(.{
                    .ok = status >= 200 and status < 300,
                    .statusCode = status,
                    .statusReason = self.request.response.reason,
                });
                L.createtable(0, 0);
                var iter = self.request.response.iterateHeaders();
                while (iter.next()) |header| {
                    L.pushlstring(header.name);
                    L.pushlstring(header.value);
                    L.settable(-3);
                }
                L.setfield(-2, "headers");

                var responseBody = std.ArrayList(u8).init(allocator);
                defer responseBody.deinit();

                self.request.reader().readAllArrayList(&responseBody, luaHelper.MAX_LUAU_SIZE) catch |err| {
                    L.pushstring(@errorName(err));
                    _ = Scheduler.resumeStateError(L, null) catch {};
                    return;
                };

                L.pushlstring(responseBody.items);
                L.setfield(-2, "body");

                _ = Scheduler.resumeState(L, null, 1) catch {};
            },
            else => {
                L.pushstring(@errorName(self.err));
                _ = Scheduler.resumeStateError(L, null) catch {};
            },
        }
    }
};

pub fn lua_request(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);

    const uri_string = try L.Zcheckvalue([]const u8, 1, null);

    var payload: ?[]const u8 = null;
    errdefer if (payload) |p| allocator.free(p);

    var method: std.http.Method = .GET;
    var redirectBehavior: ?std.http.Client.Request.RedirectBehavior = null;
    var headers: ?[]const std.http.Header = null;
    const server_header_buffer_size: usize = 16 * 1024;

    const uri = try std.Uri.parse(uri_string);

    if (!L.typeOf(2).isnoneornil()) {
        if (try L.Zcheckfield(?[]const u8, 2, "body")) |body|
            payload = try allocator.dupe(u8, body);

        const headers_type = L.getfield(2, "headers");
        if (headers_type == .Table) {
            var headers_list = std.ArrayListUnmanaged(std.http.Header){};
            defer headers_list.deinit(allocator);
            errdefer {
                for (headers_list.items) |header| {
                    allocator.free(header.name);
                    allocator.free(header.value);
                }
            }
            var i: i32 = L.rawiter(-1, 0);
            while (i >= 0) : (i = L.rawiter(-1, i)) {
                if (L.typeOf(-2) != .String) return L.Zerror("invalid header key (expected string)");
                if (L.typeOf(-1) != .String) return L.Zerror("invalid header value (expected string)");
                const key = try allocator.dupe(u8, L.tostring(-2).?);
                errdefer allocator.free(key);
                const value = try allocator.dupe(u8, L.tostring(-1).?);
                errdefer allocator.free(value);
                try headers_list.append(allocator, .{
                    .name = key,
                    .value = value,
                });
                L.pop(2);
            }
            headers = try headers_list.toOwnedSlice(allocator);
        } else if (!headers_type.isnoneornil()) return L.Zerror("invalid headers (expected table)");
        L.pop(1);

        if (try L.Zcheckfield(?bool, 2, "allowRedirects")) |option| {
            if (!option)
                redirectBehavior = .not_allowed;
        }

        const methodStr = try L.Zcheckfield([]const u8, 2, "method");
        inline for (@typeInfo(std.http.Method).@"enum".fields) |field| {
            if (std.mem.eql(u8, methodStr, field.name))
                method = @field(std.http.Method, field.name);
        }
    }

    const server_header_buffer = try allocator.alloc(u8, server_header_buffer_size);
    errdefer allocator.free(server_header_buffer);

    const self = try scheduler.createSync(RequestAsyncContext, RequestAsyncContext.complete);
    errdefer scheduler.freeSync(self);

    self.client = .{ .allocator = allocator };
    errdefer self.client.deinit();

    var req = try std.http.Client.open(&self.client, method, uri, .{
        .redirect_behavior = redirectBehavior orelse @enumFromInt(3),
        .extra_headers = headers orelse &.{},
        .keep_alive = false,
        .server_header_buffer = server_header_buffer,
        .headers = .{
            .user_agent = .{ .override = ZUNE_CLIENT_HEADER },
            .connection = .omit,
            .accept_encoding = .omit,
        },
    });
    errdefer req.deinit();

    if (payload) |p|
        req.transfer_encoding = .{ .content_length = p.len };

    self.* = .{
        .task = .{ .callback = RequestAsyncContext.task_thread_main },
        .payload = payload,
        .server_header_buffer = server_header_buffer,
        .completion = .init(),
        .ref = .init(L),
        .request = req,
        .client = self.client,
    };

    scheduler.asyncWaitForSync(self);

    scheduler.pools.general.schedule(&self.task);

    return L.yield(0);
}
