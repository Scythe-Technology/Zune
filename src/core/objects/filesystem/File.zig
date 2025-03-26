const std = @import("std");
const xev = @import("xev").Dynamic;
const luau = @import("luau");
const builtin = @import("builtin");

const tagged = @import("../../../tagged.zig");
const MethodMap = @import("../../utils/method_map.zig");
const luaHelper = @import("../../utils/luahelper.zig");
const sysfd = @import("../../utils/sysfd.zig");

const Scheduler = @import("../../runtime/scheduler.zig");

const VM = luau.VM;

const File = @This();

const TAG_FS_FILE = tagged.Tags.get("FS_FILE").?;
pub fn PlatformSupported() bool {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows, .wasi => true,
        else => false,
    };
}

pub const FileKind = enum {
    File,
    Tty,
};

handle: std.fs.File,
open: bool = true,
kind: FileKind = .File,

pub const AsyncReadContext = struct {
    completion: xev.Completion = .{},
    ref: Scheduler.ThreadRef,
    limit: usize = luaHelper.MAX_LUAU_SIZE,
    array: std.ArrayList(u8) = undefined,
    lua_type: VM.lua.Type = .String,
    buffer_len: usize = 0,
    auto_close: bool = true,
    resumed: bool = false,
    file_kind: FileKind = .File,

    const This = @This();

    pub fn end(
        self: *This,
        L: *VM.lua.State,
        scheduler: *Scheduler,
        file: xev.File,
        err: ?anyerror,
    ) xev.CallbackAction {
        if (self.auto_close)
            file.close(&scheduler.loop, &self.completion, This, self, finished);

        if (err) |e| {
            L.pushstring(@errorName(e));
            self.resumeResult(L, .Bad);
        }

        if (!self.auto_close) {
            if (err == null)
                self.resumeResult(L, .Ok);
            self.cleanup(scheduler);
        }

        return .disarm;
    }

    pub fn cleanup(self: *This, scheduler: *Scheduler) void {
        self.ref.deref();
        self.array.deinit();
        scheduler.completeAsync(self);
    }

    const Kind = enum {
        Ok,
        Bad,
    };
    fn resumeResult(self: *This, L: *VM.lua.State, comptime kind: Kind) void {
        if (self.resumed)
            return;
        self.resumed = true;
        switch (kind) {
            .Ok => {
                self.array.shrinkAndFree(@min(self.buffer_len, self.limit));
                switch (self.lua_type) {
                    .Buffer => L.Zpushbuffer(self.array.items),
                    .String => L.pushlstring(self.array.items),
                    else => unreachable,
                }
                _ = Scheduler.resumeState(L, null, 1) catch {};
            },
            .Bad => _ = Scheduler.resumeStateError(L, null) catch {},
        }
    }

    pub fn finished(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        c: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;
        const scheduler = Scheduler.getScheduler(L);
        defer self.cleanup(scheduler);

        c catch |err| {
            if (!self.resumed) {
                L.pushstring(@errorName(err));
                self.resumeResult(L, .Bad);
            }
            return .disarm;
        };

        self.resumeResult(L, .Ok);
        return .disarm;
    }

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        completion: *xev.Completion,
        file: xev.File,
        _: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const scheduler = Scheduler.getScheduler(L);
        if (L.status() != .Yield) {
            if (self.auto_close) {
                self.resumed = true;
                file.close(&scheduler.loop, completion, This, self, finished);
            } else self.cleanup(scheduler);
            return .disarm;
        }

        const read_len = r catch |err| switch (err) {
            xev.ReadError.EOF => 0,
            else => return self.end(L, scheduler, file, err),
        };

        self.buffer_len += read_len;

        if (read_len == 0 or self.buffer_len > self.limit) {
            return self.end(L, scheduler, file, null);
        }

        switch (self.file_kind) {
            .File => {
                self.array.ensureTotalCapacity(self.buffer_len + 1) catch |err| return self.end(L, scheduler, file, err);
                if (self.array.capacity > self.limit)
                    self.array.shrinkAndFree(self.limit);
                self.array.expandToCapacity();

                file.pread(
                    &scheduler.loop,
                    completion,
                    .{ .slice = self.array.items[self.buffer_len..] },
                    self.buffer_len,
                    This,
                    self,
                    This.complete,
                );
            },
            .Tty => return self.end(L, scheduler, file, null),
        }

        return .disarm;
    }

    pub fn queue(
        L: *VM.lua.State,
        f: std.fs.File,
        useBuffer: bool,
        pre_alloc_size: usize,
        max_size: usize,
        auto_close: bool,
        file_kind: FileKind,
    ) !i32 {
        if (!L.isyieldable())
            return L.Zyielderror();
        const scheduler = Scheduler.getScheduler(L);
        const allocator = luau.getallocator(L);

        const file = xev.File.init(f) catch unreachable;

        const array = try std.ArrayList(u8).initCapacity(allocator, @min(pre_alloc_size, max_size));
        errdefer array.deinit();

        const ctx = try scheduler.createAsyncCtx(This);

        ctx.* = .{
            .ref = Scheduler.ThreadRef.init(L),
            .lua_type = if (useBuffer) .Buffer else .String,
            .array = array,
            .limit = max_size,
            .auto_close = auto_close,
            .file_kind = file_kind,
        };

        ctx.array.expandToCapacity();

        switch (file_kind) {
            .File => file.pread(
                &scheduler.loop,
                &ctx.completion,
                .{ .slice = ctx.array.items },
                0,
                This,
                ctx,
                This.complete,
            ),
            .Tty => file.read(
                &scheduler.loop,
                &ctx.completion,
                .{ .slice = ctx.array.items },
                This,
                ctx,
                This.complete,
            ),
        }

        return L.yield(0);
    }
};

pub const AsyncWriteContext = struct {
    completion: xev.Completion = .{},
    ref: Scheduler.ThreadRef,
    data: []u8,
    auto_close: bool = true,
    resumed: bool = false,

    const This = @This();

    pub fn end(
        self: *This,
        L: *VM.lua.State,
        scheduler: *Scheduler,
        file: xev.File,
        err: ?anyerror,
    ) xev.CallbackAction {
        if (self.auto_close) {
            file.close(&scheduler.loop, &self.completion, This, self, finished);
        }

        if (err) |e| {
            L.pushstring(@errorName(e));
            self.resumeResult(L, .Bad);
        }

        if (!self.auto_close) {
            if (err == null)
                self.resumeResult(L, .Ok);
            self.cleanup(L, scheduler);
        }

        return .disarm;
    }

    pub fn cleanup(self: *This, L: *VM.lua.State, scheduler: *Scheduler) void {
        const allocator = luau.getallocator(L);
        allocator.free(self.data);
        self.ref.deref();
        scheduler.completeAsync(self);
    }

    const Kind = enum {
        Ok,
        Bad,
    };
    fn resumeResult(self: *This, L: *VM.lua.State, comptime kind: Kind) void {
        if (self.resumed)
            return;
        self.resumed = true;
        switch (kind) {
            .Ok => _ = Scheduler.resumeState(L, null, 0) catch {},
            .Bad => _ = Scheduler.resumeStateError(L, null) catch {},
        }
    }

    pub fn finished(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        c: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;
        const scheduler = Scheduler.getScheduler(L);
        defer self.cleanup(L, scheduler);

        c catch |err| {
            if (!self.resumed) {
                L.pushstring(@errorName(err));
                self.resumeResult(L, .Bad);
            }
            return .disarm;
        };

        self.resumeResult(L, .Ok);
        return .disarm;
    }

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        completion: *xev.Completion,
        file: xev.File,
        b: xev.WriteBuffer,
        w: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;

        const L = self.ref.value;
        const scheduler = Scheduler.getScheduler(L);

        if (L.status() != .Yield) {
            if (self.auto_close) {
                self.resumed = true;
                file.close(&scheduler.loop, completion, This, self, finished);
            } else self.cleanup(L, scheduler);
            return .disarm;
        }

        const written = w catch |err| return self.end(L, scheduler, file, err);

        if (written == 0 or written == b.slice.len)
            return self.end(L, scheduler, file, null);

        file.write(
            &scheduler.loop,
            &self.completion,
            .{ .slice = b.slice[written..] },
            This,
            self,
            This.complete,
        );
        return .disarm;
    }

    pub fn queue(L: *VM.lua.State, f: std.fs.File, data: []const u8, auto_close: bool) !i32 {
        if (!L.isyieldable())
            return L.Zyielderror();
        const scheduler = Scheduler.getScheduler(L);
        const allocator = luau.getallocator(L);

        const copy = try allocator.dupe(u8, data);
        errdefer allocator.free(copy);

        const file = try xev.File.init(f);
        const ctx = try scheduler.createAsyncCtx(This);

        ctx.* = .{
            .ref = Scheduler.ThreadRef.init(L),
            .data = copy,
            .auto_close = auto_close,
        };

        file.write(
            &scheduler.loop,
            &ctx.completion,
            .{ .slice = data },
            This,
            ctx,
            This.complete,
        );

        return L.yield(0);
    }
};

pub fn __index(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Userdata);
    // const index = L.Lcheckstring(2);
    // const ptr = L.touserdata(FileObject, 1) catch return 0;

    return 0;
}

fn write(self: *File, L: *VM.lua.State) !i32 {
    const data = try L.Zcheckvalue([]const u8, 2, null);

    return File.AsyncWriteContext.queue(L, self.handle, data, false);
}

fn writeSync(self: *File, L: *VM.lua.State) !i32 {
    const data = try L.Zcheckvalue([]const u8, 2, null);

    try self.handle.writeAll(data);

    return 0;
}

fn append(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotAppendable,
    }
    const string = try L.Zcheckvalue([]const u8, 2, null);

    try self.handle.seekFromEnd(0);

    return File.AsyncWriteContext.queue(L, self.handle, string, false);
}

fn appendSync(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotAppendable,
    }
    const string = try L.Zcheckvalue([]const u8, 2, null);

    try self.handle.seekFromEnd(0);
    try self.handle.writeAll(string);

    return 0;
}

fn getSeekPosition(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    L.pushnumber(@floatFromInt(try self.handle.getPos()));
    return 1;
}

fn getSize(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    L.pushnumber(@floatFromInt(try self.handle.getEndPos()));
    return 1;
}

fn seekFromEnd(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    try self.handle.seekFromEnd(@intFromFloat(@max(0, L.Loptnumber(2, 0))));
    return 0;
}

fn seekTo(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    try self.handle.seekTo(@intFromFloat(@max(0, L.Loptnumber(2, 0))));
    return 0;
}

fn seekBy(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    try self.handle.seekBy(@intFromFloat(L.Loptnumber(2, 1)));
    return 0;
}

fn read(self: *File, L: *VM.lua.State) !i32 {
    const size = L.Loptunsigned(2, luaHelper.MAX_LUAU_SIZE);
    return AsyncReadContext.queue(L, self.handle, L.Loptboolean(3, false), 1024, @intCast(size), false, self.kind);
}

fn readSync(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return L.Zerror("readSync for TTY should be done with readTtySync"),
    }
    const allocator = luau.getallocator(L);
    const size = L.Loptunsigned(2, luaHelper.MAX_LUAU_SIZE);
    const useBuffer = L.Loptboolean(3, false);

    const data = try self.handle.readToEndAlloc(allocator, @intCast(size));
    defer allocator.free(data);

    if (useBuffer)
        L.Zpushbuffer(data)
    else
        L.pushlstring(data);

    return 1;
}

fn readTtySync(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => return error.NotTty,
        .Tty => {},
    }
    const allocator = luau.getallocator(L);
    const maxBytes = L.Loptunsigned(2, 1);
    const useBuffer = L.Loptboolean(3, false);

    var fds = [1]sysfd.context.pollfd{.{
        .events = sysfd.context.POLLIN,
        .fd = self.handle.handle,
        .revents = 0,
    }};

    const poll = try sysfd.context.poll(&fds, 0);
    if (poll < 0)
        std.debug.panic("InternalError (Bad Poll)", .{});
    if (poll == 0)
        return 0;

    var buffer = try allocator.alloc(u8, maxBytes);
    defer allocator.free(buffer);

    const amount = try self.handle.read(buffer);

    const data = buffer[0..amount];
    if (useBuffer)
        L.Zpushbuffer(data)
    else
        L.pushlstring(data);

    return 1;
}

fn lock(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotFile,
    }
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        else => return error.UnsupportedPlatform,
    }
    var lockOpt: std.fs.File.Lock = .exclusive;
    if (L.typeOf(2) == .String) {
        const lockType = L.tostring(2) orelse unreachable;
        if (std.mem.eql(u8, lockType, "shared")) {
            lockOpt = .shared;
        } else if (!std.mem.eql(u8, lockType, "exclusive")) {
            lockOpt = .exclusive;
        } else if (!std.mem.eql(u8, lockType, "none")) {
            lockOpt = .none;
        }
    }
    if (builtin.os.tag == .windows) {
        switch (lockOpt) {
            .none => {},
            .shared, .exclusive => {
                var io_status_block: std.os.windows.IO_STATUS_BLOCK = undefined;
                const range_off: std.os.windows.LARGE_INTEGER = 0;
                const range_len: std.os.windows.LARGE_INTEGER = 1;
                std.os.windows.LockFile(
                    self.handle.handle,
                    null,
                    null,
                    null,
                    &io_status_block,
                    &range_off,
                    &range_len,
                    null,
                    std.os.windows.FALSE, // non-blocking=false
                    @intFromBool(lockOpt == .exclusive),
                ) catch |err| switch (err) {
                    error.WouldBlock => unreachable, // non-blocking=false
                    else => |e| return e,
                };
            },
        }
        L.pushboolean(true);
    } else {
        L.pushboolean(try self.handle.tryLock(lockOpt));
    }
    return 1;
}

fn unlock(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotFile,
    }
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        else => return error.UnsupportedPlatform,
    }
    _ = L;
    self.handle.unlock();
    return 0;
}

fn sync(self: *File, _: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotFile,
    }
    try self.handle.sync();

    return 0;
}

fn readonly(self: *File, L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        else => return error.UnsupportedPlatform,
    }
    const meta = try self.handle.metadata();
    var permissions = meta.permissions();
    const enabled = if (L.typeOf(2) != .Boolean) {
        L.pushboolean(permissions.readOnly());
        return 1;
    } else L.toboolean(2);
    permissions.setReadOnly(enabled);
    try self.handle.setPermissions(permissions);
    return 0;
}

pub const AsyncCloseContext = struct {
    completion: xev.Completion = .{},
    ref: Scheduler.ThreadRef,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        _: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer self.ref.deref();

        if (L.status() != .Yield)
            return .disarm;

        _ = Scheduler.resumeState(L, null, 0) catch {};
        return .disarm;
    }
};

fn closeAsync(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotCloseable,
    }
    if (self.open) {
        self.open = false;
        const scheduler = Scheduler.getScheduler(L);
        const file = xev.File.init(self.handle) catch unreachable;

        const ctx = try scheduler.createAsyncCtx(AsyncCloseContext);
        ctx.* = .{
            .ref = Scheduler.ThreadRef.init(L),
        };

        file.close(
            &scheduler.loop,
            &ctx.completion,
            AsyncCloseContext,
            ctx,
            AsyncCloseContext.complete,
        );

        return L.yield(0);
    }
    return 0;
}

fn before_method(self: *File, L: *VM.lua.State) !void {
    if (!self.open)
        return L.Zerror("File is closed");
}

const __namecall = MethodMap.CreateNamecallMap(File, TAG_FS_FILE, .{
    .{ "write", MethodMap.WithFn(File, write, before_method) },
    .{ "writeSync", MethodMap.WithFn(File, writeSync, before_method) },
    .{ "append", MethodMap.WithFn(File, append, before_method) },
    .{ "appendSync", MethodMap.WithFn(File, appendSync, before_method) },
    .{ "getSeekPosition", MethodMap.WithFn(File, getSeekPosition, before_method) },
    .{ "getSize", MethodMap.WithFn(File, getSize, before_method) },
    .{ "seekFromEnd", MethodMap.WithFn(File, seekFromEnd, before_method) },
    .{ "seekTo", MethodMap.WithFn(File, seekTo, before_method) },
    .{ "seekBy", MethodMap.WithFn(File, seekBy, before_method) },
    .{ "read", MethodMap.WithFn(File, read, before_method) },
    .{ "readSync", MethodMap.WithFn(File, readSync, before_method) },
    .{ "readTtySync", MethodMap.WithFn(File, readTtySync, before_method) },
    .{ "lock", MethodMap.WithFn(File, lock, before_method) },
    .{ "unlock", MethodMap.WithFn(File, unlock, before_method) },
    .{ "sync", MethodMap.WithFn(File, sync, before_method) },
    .{ "readonly", MethodMap.WithFn(File, readonly, before_method) },
    .{ "close", closeAsync },
});

pub fn __dtor(L: *VM.lua.State, self: *File) void {
    _ = L;
    if (self.open and self.kind == .File)
        self.handle.close();
}

pub inline fn load(L: *VM.lua.State) void {
    _ = L.Lnewmetatable(@typeName(@This()));

    L.Zsetfieldfn(-1, luau.Metamethods.index, __index); // metatable.__index
    L.Zsetfieldfn(-1, luau.Metamethods.namecall, __namecall); // metatable.__namecall

    L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");

    L.setuserdatametatable(TAG_FS_FILE);
    L.setuserdatadtor(File, TAG_FS_FILE, __dtor);
}

pub fn push(L: *VM.lua.State, file: std.fs.File, kind: FileKind) void {
    const ptr = L.newuserdatataggedwithmetatable(File, TAG_FS_FILE);
    ptr.* = .{
        .handle = file,
        .kind = kind,
    };
}
