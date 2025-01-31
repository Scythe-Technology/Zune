const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Common = @import("common.zig");

const Scheduler = @import("../../runtime/scheduler.zig");
const Response = @import("http/response.zig");
const WebSocket = @import("http/websocket.zig");

const zune_info = @import("zune-info");

const VM = luau.VM;

const context = Common.context;
const prepRefType = Common.prepRefType;

const Self = @This();

const RequestError = error{
    RedirectNotAllowed,
};

const ZUNE_CLIENT_HEADER = "Zune/" ++ zune_info.version;

start: f64,
client: *std.http.Client,
req: *std.http.Client.Request,
options: *std.http.Client.FetchOptions,
success: bool = false,
fds: []context.spollfd,
err: ?anyerror,

pub fn update(ctx: *Self, L: *VM.lua.State, scheduler: *Scheduler) Scheduler.TaskResult {
    _ = scheduler;
    _ = L;
    var req = ctx.req;
    const fds = ctx.fds;
    const connection = req.connection.?;

    const nums = context.spoll(fds, 1) catch std.debug.panic("Bad poll (1)", .{});
    if (nums == 0) {
        if (ctx.start < VM.lperf.clock()) {
            ctx.err = error.TimedOut;
            ctx.success = false;
            return .Stop;
        }
        return .Continue;
    }
    if (nums < 0)
        std.debug.panic("Bad poll (2)", .{});

    ctx.success = true;

    connection.fill() catch |err| {
        std.debug.print("Error filling connection: {}\n", .{err});
        ctx.success = false;
        ctx.err = err;
        return .Stop;
    }; // crash

    const nchecked = req.response.parser.checkCompleteHead(connection.peek()) catch |err| {
        std.debug.print("Error filling connection: {}\n", .{err});
        ctx.success = false;
        ctx.err = err;
        return .Stop;
    }; // crash
    connection.drop(@intCast(nchecked));

    if (!req.response.parser.state.isContent())
        return .ContinueFast;

    req.response.parse(req.response.parser.get()) catch |err| {
        std.debug.print("Error filling connection: {}\n", .{err});
        ctx.success = false;
        ctx.err = err;
        return .Stop;
    }; // crash

    if (req.response.status == .@"continue") {
        req.response.parser.done = true;
        req.response.parser.reset();

        if (req.handle_continue)
            return .ContinueFast;

        std.debug.print("cannot handle continue\n", .{});
        ctx.success = false;
        return .Stop;
    }

    if (req.method == .CONNECT and req.response.status.class() == .success) {
        connection.closing = false;
        req.response.parser.done = true;
        std.debug.print("connect method\n", .{});
        ctx.success = false;
        return .Stop;
    }

    connection.closing = !req.response.keep_alive or !req.keep_alive;

    if (req.method == .HEAD or req.response.status.class() == .informational or
        req.response.status == .no_content or req.response.status == .not_modified)
    {
        req.response.parser.done = true;
        ctx.success = false;
        return .Stop;
    }

    switch (req.response.transfer_encoding) {
        .none => {
            if (req.response.content_length) |cl| {
                req.response.parser.next_chunk_length = cl;

                if (cl == 0) req.response.parser.done = true;
            } else req.response.parser.next_chunk_length = std.math.maxInt(u64);
        },
        .chunked => {
            req.response.parser.next_chunk_length = 0;
            req.response.parser.state = .chunk_head_size;
        },
    }

    if (req.response.status.class() == .redirect and req.redirect_behavior != .unhandled) {
        req.response.skip = true;
        if (req.redirect_behavior == .not_allowed) {
            ctx.success = false;
            ctx.err = RequestError.RedirectNotAllowed;
            return .Stop;
        }
        std.debug.assert(transferRead(req, &.{}) catch {
            ctx.success = false;
            ctx.err = null;
            return .Stop;
        } == 0); // we're skipping, no buffer is necessary

        const location = req.response.location orelse {
            ctx.success = false;
            ctx.err = null;
            return .Stop;
        };

        redirect(req, req.uri.resolve_inplace(
            location,
            &req.response.parser.header_bytes_buffer,
        ) catch |err| {
            ctx.success = false;
            ctx.err = err;
            return .Stop;
        }) catch |err| {
            ctx.success = false;
            ctx.err = err;
            return .Stop;
        };
        fds[0].fd = req.connection.?.stream.handle;
        fds[0].events = context.POLLIN;
        req.send() catch |err| {
            ctx.success = false;
            ctx.err = err;
            return .Stop;
        };
        // ctx.success = false;
        // ctx.err = null;
        return .ContinueFast;
    }

    req.response.skip = false;
    return .Stop; // end
}

fn redirect(req: *std.http.Client.Request, uri: std.Uri) !void {
    std.debug.assert(req.response.parser.done);

    req.client.connection_pool.release(req.client.allocator, req.connection.?);
    req.connection = null;

    var server_header = std.heap.FixedBufferAllocator.init(req.response.parser.header_bytes_buffer);
    defer req.response.parser.header_bytes_buffer = server_header.buffer[server_header.end_index..];
    const protocol, const valid_uri = try validateUri(uri, server_header.allocator());

    const new_host = valid_uri.host.?.raw;
    const prev_host = req.uri.host.?.raw;
    const keep_privileged_headers =
        std.ascii.eqlIgnoreCase(valid_uri.scheme, req.uri.scheme) and
        std.ascii.endsWithIgnoreCase(new_host, prev_host) and
        (new_host.len == prev_host.len or new_host[new_host.len - prev_host.len - 1] == '.');
    if (!keep_privileged_headers) {
        // When redirecting to a different domain, strip privileged headers.
        req.privileged_headers = &.{};
    }

    if (switch (req.response.status) {
        .see_other => true,
        .moved_permanently, .found => req.method == .POST,
        else => false,
    }) {
        // A redirect to a GET must change the method and remove the body.
        req.method = .GET;
        req.transfer_encoding = .none;
        req.headers.content_type = .omit;
    }

    if (req.transfer_encoding != .none) {
        // The request body has already been sent. The request is
        // still in a valid state, but the redirect must be handled
        // manually.
        return error.RedirectRequiresResend;
    }

    req.uri = valid_uri;
    req.connection = try req.client.connect(new_host, uriPort(valid_uri, protocol), protocol);
    req.redirect_behavior.subtractOne();
    req.response.parser.reset();

    req.response = .{
        .version = undefined,
        .status = undefined,
        .reason = undefined,
        .keep_alive = undefined,
        .parser = req.response.parser,
    };
}

pub fn dtor(ctx: *Self, L: *VM.lua.State, scheduler: *Scheduler) void {
    _ = scheduler;
    const allocator = luau.getallocator(L);

    var req = ctx.req.*;
    const options = ctx.options.*;

    defer {
        ctx.req.deinit();
        ctx.client.deinit();
        allocator.free(ctx.fds);
        allocator.destroy(ctx.req);
        if (ctx.options.*.server_header_buffer) |serverBuffer| allocator.free(serverBuffer);
        allocator.destroy(ctx.options);
        allocator.destroy(ctx.client);
        allocator.destroy(ctx);
    }

    if (ctx.success) {
        var responseBody = std.ArrayList(u8).init(allocator);
        defer responseBody.deinit();

        const max_append_size = options.max_append_size orelse 2 * 1024 * 1024;
        req.reader().readAllArrayList(&responseBody, max_append_size) catch |err| {
            std.debug.print("Error reading response0: {}\n", .{err});
            L.pushstring(@errorName(err));
            _ = Scheduler.resumeStateError(L, null) catch {};
            return;
        };

        if (options.server_header_buffer == null) {
            std.debug.print("Server header buffer is null\n", .{});
            L.pushstring("InternalError (Header Buffer is null)");
            _ = Scheduler.resumeStateError(L, null) catch {};
            return;
        }

        const header_buffer = req.response.parser.header_bytes_buffer;

        var bufferStream = std.io.FixedBufferStream([]const u8){
            .buffer = header_buffer,
            .pos = 0,
        };

        var response = Response.init(allocator, bufferStream.reader().any(), .{
            .ignoreBody = true,
        }) catch |err| {
            L.pushstring(@errorName(err));
            _ = Scheduler.resumeStateError(L, null) catch {};
            return;
        };
        defer response.deinit();

        response.pushToStack(L, responseBody.items);

        _ = Scheduler.resumeState(L, null, 1) catch {};
    } else {
        // continue lua with error
        if (ctx.err) |err|
            L.pushstring(@errorName(err))
        else
            L.pushstring("Error");
        _ = Scheduler.resumeStateError(L, null) catch {};
    }
}

// based on std.http.Client
const TransferReadError = std.http.Client.Connection.ReadError || std.http.protocol.HeadersParser.ReadError;
const TransferReader = std.io.Reader(*std.http.Client.Request, TransferReadError, transferRead);

fn transferReader(req: *std.http.Client.Request) TransferReader {
    return .{ .context = req };
}

fn transferRead(req: *std.http.Client.Request, buf: []u8) TransferReadError!usize {
    if (req.response.parser.done) return 0;

    var index: usize = 0;
    while (index == 0) {
        const amt = try req.response.parser.read(req.connection.?, buf[index..], req.response.skip);
        if (amt == 0 and req.response.parser.done) break;
        index += amt;
    }

    return index;
}

// based on std.http.Client.uriPort
fn uriPort(uri: std.Uri, protocol: std.http.Client.Connection.Protocol) u16 {
    return uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
}

// based on std.http.Client.validateUri
pub fn validateUri(uri: std.Uri, arena: std.mem.Allocator) !struct { std.http.Client.Connection.Protocol, std.Uri } {
    const protocol_map = std.StaticStringMap(std.http.Client.Connection.Protocol).initComptime(.{
        .{ "http", .plain },
        .{ "https", .tls },
    });
    const protocol = protocol_map.get(uri.scheme) orelse return error.UnsupportedUriScheme;
    var valid_uri = uri;
    valid_uri.host = .{
        .raw = try (uri.host orelse return error.UriMissingHost).toRawMaybeAlloc(arena),
    };
    return .{ protocol, valid_uri };
}

pub fn prep(allocator: std.mem.Allocator, L: *VM.lua.State, scheduler: *Scheduler, options: std.http.Client.FetchOptions) !void {
    const client = std.http.Client{
        .allocator = allocator,
    };

    const uri = switch (options.location) {
        .url => |u| try std.Uri.parse(u),
        .uri => |u| u,
    };
    const server_header_buffer = try allocator.alloc(u8, 16 * 1024);
    errdefer allocator.free(server_header_buffer);

    const method: std.http.Method = options.method orelse
        if (options.payload != null) .POST else .GET;

    const clientPtr = try allocator.create(std.http.Client);
    errdefer allocator.destroy(clientPtr);
    clientPtr.* = client;

    var req = try std.http.Client.open(clientPtr, method, uri, .{
        .server_header_buffer = server_header_buffer,
        .redirect_behavior = options.redirect_behavior orelse @enumFromInt(3),
        .headers = options.headers,
        .extra_headers = options.extra_headers,
        .privileged_headers = options.privileged_headers,
        .keep_alive = options.keep_alive,
    });

    if (options.payload) |payload| req.transfer_encoding = .{ .content_length = payload.len };

    try req.send();

    if (options.payload) |payload| try req.writeAll(payload);

    try req.finish();

    if (req.connection == null) {
        std.debug.print("Connection is null\n", .{});
        return;
    }

    const requestPtr = try allocator.create(std.http.Client.Request);
    errdefer allocator.destroy(requestPtr);
    requestPtr.* = req;

    const optionsPtr = try allocator.create(std.http.Client.FetchOptions);
    errdefer allocator.destroy(optionsPtr);
    optionsPtr.* = options;

    optionsPtr.server_header_buffer = server_header_buffer;

    const netClientPtr = try allocator.create(Self);
    errdefer allocator.destroy(netClientPtr);

    var fds = try allocator.alloc(context.spollfd, 1);
    fds[0].fd = req.connection.?.stream.handle;
    fds[0].events = context.POLLIN;

    netClientPtr.* = .{
        .start = VM.lperf.clock() + 30,
        .fds = fds,
        .client = clientPtr,
        .req = requestPtr,
        .options = optionsPtr,
        .err = null,
    };

    scheduler.addTask(Self, netClientPtr, L, update, dtor);
}

pub fn lua_request(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);
    const uriString = L.Lcheckstring(1);
    const allocator = luau.getallocator(L);

    var method: std.http.Method = .GET;
    var payload: ?[]const u8 = null;
    var redirectBehavior: ?std.http.Client.Request.RedirectBehavior = null;
    var maxBodySize: ?usize = null;

    var headers = std.ArrayList(std.http.Header).init(allocator);
    defer headers.deinit();

    const optionsType = L.typeOf(2);
    if (!optionsType.isnoneornil()) {
        L.Lchecktype(2, .Table);
        if (L.getfield(2, "method") != .String)
            return L.Zerror("Expected field 'method' to be a string");
        const methodStr = L.Lcheckstring(-1);
        L.pop(1);
        const headersType = L.getfield(2, "headers");
        if (!headersType.isnoneornil()) {
            if (headersType != .Table)
                return L.Zerror("Expected field 'headers' to be a table");
            Common.read_headers(L, &headers, -1) catch |err| switch (err) {
                error.InvalidKeyType => {
                    L.pop(1);
                    return L.Zerror("Header key must be a string");
                },
                error.InvalidValueType => {
                    L.pop(1);
                    return L.Zerror("Header value must be a string");
                },
                else => return L.Zerror("UnknownError"),
            };
        }
        const allowRedirectsType = L.getfield(2, "allowRedirects");
        if (!allowRedirectsType.isnoneornil()) {
            if (allowRedirectsType != .Boolean)
                return L.Zerror("Expected field 'allowRedirects' to be a boolean");
            if (!L.toboolean(-1))
                redirectBehavior = .not_allowed;
        }
        const maxBodySizeType = L.getfield(2, "maxBodySize");
        if (!maxBodySizeType.isnoneornil()) {
            if (maxBodySizeType != .Number)
                return L.Zerror("Expected field 'maxBodySize' to be a number");
            maxBodySize = @intCast(L.tointeger(-1) orelse unreachable);
        }
        L.pop(1);
        if (std.mem.eql(u8, methodStr, "POST")) {
            method = .POST;
            if (L.getfield(2, "body") != .String)
                return L.Zerror("Expected field 'body' to be a string");
            payload = L.Lcheckstring(-1);
            L.pop(1);
        }
    }

    const uri = std.Uri.parse(uriString) catch |err| {
        L.pushstring(@errorName(err));
        L.raiseerror();
        return 1;
    };

    prep(allocator, L, scheduler, .{
        .redirect_behavior = redirectBehavior,
        .extra_headers = headers.items,
        .headers = .{
            .user_agent = .{ .override = ZUNE_CLIENT_HEADER },
            .connection = .omit,
            .accept_encoding = .omit,
        },
        .location = .{
            .uri = uri,
        },
        .max_append_size = maxBodySize,
        .payload = payload,
        .method = method,
    }) catch |err| {
        L.pushstring(@errorName(err));
        L.raiseerror();
        return 1;
    };

    return L.yield(0);
}
