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

pub const OpenMode = packed struct {
    read: bool = false,
    write: bool = false,

    pub const closed: OpenMode = .{ .read = false, .write = false };
    pub const writable: OpenMode = .{ .read = false, .write = true };
    pub const readable: OpenMode = .{ .read = true, .write = false };
    pub const readwrite: OpenMode = .{ .read = true, .write = true };

    pub inline fn isOpen(self: OpenMode) bool {
        return self.read or self.write;
    }
    pub inline fn canRead(self: OpenMode) bool {
        return self.read;
    }
    pub inline fn canWrite(self: OpenMode) bool {
        return self.write;
    }
};

file: std.fs.File,
mode: OpenMode = .{},
kind: FileKind = .File,
list: *Scheduler.CompletionLinkedList,

pub const AsyncReadContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .data = .{},
    },
    ref: Scheduler.ThreadRef,
    limit: usize = luaHelper.MAX_LUAU_SIZE,
    array: std.ArrayList(u8) = undefined,
    lua_type: VM.lua.Type = .String,
    buffer_len: usize = 0,
    auto_close: bool = true,
    resumed: bool = false,
    file_kind: FileKind = .File,
    list: ?*Scheduler.CompletionLinkedList = null,

    const This = @This();

    pub fn end(
        self: *This,
        L: *VM.lua.State,
        scheduler: *Scheduler,
        file: xev.File,
        err: ?anyerror,
    ) xev.CallbackAction {
        if (self.auto_close)
            file.close(&scheduler.loop, &self.completion.data, This, self, finished);

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
        defer scheduler.completeAsync(self);
        self.ref.deref();
        self.array.deinit();
        if (self.list) |l|
            l.remove(&self.completion);
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
        list: ?*Scheduler.CompletionLinkedList,
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
                &ctx.completion.data,
                .{ .slice = ctx.array.items },
                0,
                This,
                ctx,
                This.complete,
            ),
            .Tty => file.read(
                &scheduler.loop,
                &ctx.completion.data,
                .{ .slice = ctx.array.items },
                This,
                ctx,
                This.complete,
            ),
        }
        if (list) |l|
            l.append(&ctx.completion);

        return L.yield(0);
    }
};

pub const AsyncWriteContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .data = .{},
    },
    ref: Scheduler.ThreadRef,
    data: []u8,
    auto_close: bool = true,
    resumed: bool = false,
    list: ?*Scheduler.CompletionLinkedList = null,

    const This = @This();

    pub fn end(
        self: *This,
        L: *VM.lua.State,
        scheduler: *Scheduler,
        file: xev.File,
        err: ?anyerror,
    ) xev.CallbackAction {
        if (self.auto_close) {
            file.close(&scheduler.loop, &self.completion.data, This, self, finished);
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
        defer scheduler.completeAsync(self);
        const allocator = luau.getallocator(L);
        allocator.free(self.data);
        self.ref.deref();
        if (self.list) |l|
            l.remove(&self.completion);
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
            completion,
            .{ .slice = b.slice[written..] },
            This,
            self,
            This.complete,
        );
        return .disarm;
    }

    pub fn queue(
        L: *VM.lua.State,
        f: std.fs.File,
        data: []const u8,
        auto_close: bool,
        list: ?*Scheduler.CompletionLinkedList,
    ) !i32 {
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
            &ctx.completion.data,
            .{ .slice = data },
            This,
            ctx,
            This.complete,
        );
        if (list) |l|
            l.append(&ctx.completion);

        return L.yield(0);
    }
};

fn write(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.canWrite())
        return error.NotOpenForWriting;
    const data = try L.Zcheckvalue([]const u8, 2, null);

    return File.AsyncWriteContext.queue(L, self.file, data, false, self.list);
}

fn writeSync(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.canWrite())
        return error.NotOpenForWriting;
    const data = try L.Zcheckvalue([]const u8, 2, null);

    try self.file.writeAll(data);

    return 0;
}

fn append(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotAppendable,
    }
    if (!self.mode.canWrite())
        return error.NotOpenForWriting;
    const string = try L.Zcheckvalue([]const u8, 2, null);

    try self.file.seekFromEnd(0);

    return File.AsyncWriteContext.queue(L, self.file, string, false, self.list);
}

fn appendSync(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotAppendable,
    }
    if (!self.mode.canWrite())
        return error.NotOpenForWriting;
    const string = try L.Zcheckvalue([]const u8, 2, null);

    try self.file.seekFromEnd(0);
    try self.file.writeAll(string);

    return 0;
}

fn getSeekPosition(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    L.pushnumber(@floatFromInt(try self.file.getPos()));
    return 1;
}

fn getSize(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    L.pushnumber(@floatFromInt(try self.file.getEndPos()));
    return 1;
}

fn seekFromEnd(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    try self.file.seekFromEnd(@intFromFloat(@max(0, L.Loptnumber(2, 0))));
    return 0;
}

fn seekTo(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    try self.file.seekTo(@intFromFloat(@max(0, L.Loptnumber(2, 0))));
    return 0;
}

fn seekBy(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    try self.file.seekBy(@intFromFloat(L.Loptnumber(2, 1)));
    return 0;
}

fn read(self: *File, L: *VM.lua.State) !i32 {
    const size = L.Loptunsigned(2, luaHelper.MAX_LUAU_SIZE);
    if (!self.mode.canRead())
        return error.NotOpenForReading;
    return AsyncReadContext.queue(
        L,
        self.file,
        L.Loptboolean(3, false),
        1024,
        @intCast(size),
        false,
        self.kind,
        self.list,
    );
}

fn readSync(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return L.Zerror("readSync for TTY should be done with readTtySync"),
    }
    if (!self.mode.canRead())
        return error.NotOpenForReading;
    const allocator = luau.getallocator(L);
    const size = L.Loptunsigned(2, luaHelper.MAX_LUAU_SIZE);
    const useBuffer = L.Loptboolean(3, false);

    const data = try self.file.readToEndAlloc(allocator, @intCast(size));
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
    if (!self.mode.canRead())
        return error.NotOpenForReading;
    const allocator = luau.getallocator(L);
    const maxBytes = L.Loptunsigned(2, 1);
    const useBuffer = L.Loptboolean(3, false);

    var fds = [1]sysfd.context.pollfd{.{
        .events = sysfd.context.POLLIN,
        .fd = self.file.handle,
        .revents = 0,
    }};

    const poll = try sysfd.context.poll(&fds, 0);
    if (poll < 0)
        std.debug.panic("InternalError (Bad Poll)", .{});
    if (poll == 0)
        return 0;

    var buffer = try allocator.alloc(u8, maxBytes);
    defer allocator.free(buffer);

    const amount = try self.file.read(buffer);

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
                    self.file.handle,
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
        L.pushboolean(try self.file.tryLock(lockOpt));
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
    self.file.unlock();
    return 0;
}

fn sync(self: *File, _: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotFile,
    }
    try self.file.sync();

    return 0;
}

fn readonly(self: *File, L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        else => return error.UnsupportedPlatform,
    }
    const meta = try self.file.metadata();
    var permissions = meta.permissions();
    const enabled = if (L.typeOf(2) != .Boolean) {
        L.pushboolean(permissions.readOnly());
        return 1;
    } else L.toboolean(2);
    permissions.setReadOnly(enabled);
    try self.file.setPermissions(permissions);
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
    if (self.mode.isOpen()) {
        self.mode = .closed;
        const scheduler = Scheduler.getScheduler(L);
        const file = xev.File.init(self.file) catch unreachable;

        const ctx = try scheduler.createAsyncCtx(AsyncCloseContext);
        ctx.* = .{
            .ref = Scheduler.ThreadRef.init(L),
        };

        switch (comptime builtin.os.tag) {
            .windows => _ = std.os.windows.kernel32.CancelIoEx(self.file.handle, null),
            else => {
                var node = self.list.first;
                while (node) |n| {
                    scheduler.cancelAsyncTask(&n.data);
                    node = n.next;
                }
            },
        }

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
    if (!self.mode.isOpen())
        return L.Zerror("File is closed");
}

pub fn __index(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Userdata);
    // const index = L.Lcheckstring(2);
    // const ptr = L.touserdata(FileObject, 1) catch return 0;

    return 0;
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
    const allocator = luau.getallocator(L);
    if (self.mode.isOpen() and self.kind == .File)
        self.file.close();
    allocator.destroy(self.list);
}

pub inline fn load(L: *VM.lua.State) void {
    _ = L.Znewmetatable(@typeName(@This()), .{
        .__index = __index,
        .__namecall = __namecall,
        .__metatable = "Metatable is locked",
        .__type = "FileHandle",
    });
    L.setreadonly(-1, true);
    L.setuserdatametatable(TAG_FS_FILE);
    L.setuserdatadtor(File, TAG_FS_FILE, __dtor);
}

pub fn push(L: *VM.lua.State, file: std.fs.File, kind: FileKind, mode: OpenMode) !void {
    const allocator = luau.getallocator(L);
    const self = L.newuserdatataggedwithmetatable(File, TAG_FS_FILE);
    const list = try allocator.create(Scheduler.CompletionLinkedList);
    list.* = .{};
    self.* = .{
        .file = file,
        .kind = kind,
        .mode = mode,
        .list = list,
    };
}
