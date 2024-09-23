const std = @import("std");
const builtin = @import("builtin");

const MAX_EVENTS = 1024 * 2;

const WatchEvent = struct {
    name: []const u8,
    event: Event,

    pub const Event = packed struct {
        created: bool = false,
        delete: bool = false,
        modify: bool = false,
        rename: bool = false,
        move_to: bool = false,
        move_from: bool = false,
        metadata: bool = false,
    };
};

const WatchInfo = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(WatchEvent),

    pub fn deinit(self: WatchInfo) void {
        for (self.list.items) |e| self.allocator.free(e.name);
        self.list.deinit();
    }
};

const LinuxAttributes = struct {
    fd: ?i32 = null,
    fds: [1]std.posix.pollfd = undefined,

    const INotifyEventSize = @sizeOf(INotifyEvent);
    pub const INotifyEvent = extern struct {
        wd: c_int,
        mask: u32,
        cookie: u32,
        name_len: u32,

        pub fn name(this: *const INotifyEvent) [*:0]u8 {
            return @as([*:0]u8, @ptrFromInt(@intFromPtr(&this.name_len) + @sizeOf(u32)))[0.. :0];
        }
    };

    pub fn deinit(self: *LinuxAttributes) void {
        if (self.fd) |fd|
            std.posix.close(fd);
    }
};

const DarwinAttributes = struct {
    const kevent = std.c.Kevent;

    fd: ?i32 = null,
    dir: ?std.fs.Dir = null,
    map: ?std.AutoArrayHashMap(usize, kevent) = null,
    names: ?std.AutoArrayHashMap(usize, []const u8) = null,
    files: ?std.StringArrayHashMap(FileInfo) = null,

    const FileInfo = struct {
        id: usize,
        kind: std.fs.File.Kind,
        modified: i128,
    };

    const FileDifference = struct {
        name: []const u8,
        state: enum {
            created,
            deleted,
            modified,
            renamed,
        },

        fn deinit(self: *FileDifference, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
        }
    };

    pub fn scanDirectory(self: *DarwinAttributes) ![]FileDifference {
        const dir = &(self.dir orelse return error.WatcherNotStarted);
        const map = &(self.map orelse return error.WatcherNotStarted);
        const names = &(self.names orelse return error.WatcherNotStarted);
        const files = &(self.files orelse return error.WatcherNotStarted);

        const allocator = map.allocator;

        var diff = std.ArrayList(FileDifference).init(allocator);
        errdefer diff.deinit();
        errdefer for (diff.items) |item| allocator.free(item.name);

        {
            var temp_files = std.StringArrayHashMap(FileInfo).init(allocator);
            errdefer temp_files.deinit();
            errdefer for (temp_files.keys()) |key| allocator.free(key);

            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                const exists = files.get(entry.name);
                if (entry.kind == .file) {
                    const copy_path = try allocator.dupe(u8, entry.name);
                    errdefer allocator.free(copy_path);
                    if (exists == null) {
                        const sub_file = try dir.openFile(entry.name, .{});
                        const stat = try sub_file.stat();
                        try names.put(@intCast(sub_file.handle), copy_path);
                        try map.put(@intCast(sub_file.handle), .{
                            .data = 0,
                            .udata = @intCast(sub_file.handle),
                            .ident = @intCast(sub_file.handle),
                            .filter = std.c.EVFILT_VNODE,
                            .flags = std.c.EV_ADD | std.c.EV_ONESHOT | std.c.EV_ENABLE,
                            .fflags = std.c.NOTE_DELETE | std.c.NOTE_WRITE | std.c.NOTE_EXTEND | std.c.NOTE_ATTRIB | std.c.NOTE_RENAME | std.c.NOTE_LINK,
                        });
                        try temp_files.put(copy_path, .{
                            .id = @intCast(sub_file.handle),
                            .kind = .file,
                            .modified = stat.ctime,
                        });
                    } else {
                        try temp_files.put(copy_path, exists.?);
                        try names.put(exists.?.id, copy_path);
                    }
                } else if (entry.kind == .directory) {
                    const copy_path = try allocator.dupe(u8, entry.name);
                    errdefer allocator.free(copy_path);
                    if (exists == null) {
                        const sub_dir = try dir.openDir(entry.name, .{
                            .iterate = false,
                        });
                        try names.put(@intCast(sub_dir.fd), copy_path);
                        try map.put(@intCast(sub_dir.fd), .{
                            .data = 0,
                            .udata = @intCast(sub_dir.fd),
                            .ident = @intCast(sub_dir.fd),
                            .filter = std.c.EVFILT_VNODE,
                            .flags = std.c.EV_ADD | std.c.EV_ONESHOT | std.c.EV_ENABLE,
                            .fflags = std.c.NOTE_DELETE | std.c.NOTE_RENAME | std.c.NOTE_ATTRIB,
                        });
                        try temp_files.put(copy_path, .{
                            .id = @intCast(sub_dir.fd),
                            .kind = .directory,
                            .modified = 0,
                        });
                    } else {
                        try temp_files.put(copy_path, exists.?);
                        try names.put(exists.?.id, copy_path);
                    }
                }
            }

            var file_iter = files.iterator();
            while (file_iter.next()) |entry| {
                const info = temp_files.get(entry.key_ptr.*);
                if (info == null) {
                    const name = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(name);
                    try diff.append(.{
                        .name = name,
                        .state = .deleted,
                    });
                    if (map.get(entry.value_ptr.id)) |handle| std.posix.close(@intCast(handle.ident));
                    _ = map.orderedRemove(entry.value_ptr.id);
                    _ = names.orderedRemove(entry.value_ptr.id);
                } else {
                    if (entry.value_ptr.kind == .file) {
                        const file = std.fs.File{
                            .handle = @intCast(info.?.id),
                        };
                        const stat = try file.stat();
                        if (stat.ctime != info.?.modified) {
                            const name = try allocator.dupe(u8, entry.key_ptr.*);
                            errdefer allocator.free(name);
                            try diff.append(.{
                                .name = name,
                                .state = .modified,
                            });
                        }
                    }
                }
            }

            var temp_files_iter = temp_files.iterator();
            while (temp_files_iter.next()) |entry| {
                if (files.get(entry.key_ptr.*) != null) continue;
                const name = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(name);
                try diff.append(.{
                    .name = name,
                    .state = .created,
                });
            }

            for (files.keys()) |key| allocator.free(key);
            files.deinit();

            self.files = temp_files;
        }

        return diff.toOwnedSlice();
    }

    pub fn deinit(self: *DarwinAttributes, allocator: std.mem.Allocator) void {
        if (self.fd) |fd|
            std.posix.close(fd);
        if (self.dir) |*dir|
            dir.close();
        if (self.names) |*names| {
            for (names.values()) |name|
                allocator.free(name);
            names.deinit();
        }
        if (self.map) |*map| {
            if (map.values().len > 1)
                for (map.values()[1..]) |*i|
                    std.posix.close(@intCast(i.ident));
            map.deinit();
        }
        if (self.files) |*files|
            files.deinit();
    }
};

const WindowsAttributes = struct {
    handle: ?std.os.windows.HANDLE = null,
    iocp: ?std.os.windows.HANDLE = null,
    overlapped: std.os.windows.OVERLAPPED = std.mem.zeroes(std.os.windows.OVERLAPPED),
    buf: [64 * 1024]u8 align(@alignOf(std.os.windows.FILE_NOTIFY_INFORMATION)) = undefined,
    active: bool = true,
    monitoring: bool = false,

    pub const Action = enum(std.os.windows.DWORD) {
        Added = std.os.windows.FILE_ACTION_ADDED,
        Removed = std.os.windows.FILE_ACTION_REMOVED,
        Modified = std.os.windows.FILE_ACTION_MODIFIED,
        RenamedOld = std.os.windows.FILE_ACTION_RENAMED_OLD_NAME,
        RenamedNew = std.os.windows.FILE_ACTION_RENAMED_NEW_NAME,
    };

    pub fn monitor(self: *WindowsAttributes) !void {
        const handle = self.handle orelse return error.WatcherNotStarted;
        if (self.monitoring)
            return;
        if (!self.active)
            return;
        if (std.os.windows.kernel32.ReadDirectoryChangesW(
            handle,
            &self.buf,
            self.buf.len,
            0,
            std.os.windows.FILE_NOTIFY_CHANGE_FILE_NAME | std.os.windows.FILE_NOTIFY_CHANGE_DIR_NAME | std.os.windows.FILE_NOTIFY_CHANGE_LAST_WRITE | std.os.windows.FILE_NOTIFY_CHANGE_CREATION,
            null,
            &self.overlapped,
            null,
        ) == 0) {
            const err = std.os.windows.kernel32.GetLastError();
            std.debug.print("[Win32] Failed to start watcher: {s}\n", .{@tagName(err)});
            switch (err) {
                .PRIVILEGE_NOT_HELD, .ACCESS_DENIED => return error.AccessDenied,
                .INVALID_PARAMETER => @panic("[ReadDirectoryChangesW] Invalid parameter"),
                else => return error.UnknownError,
            }
        }
        self.monitoring = true;
    }

    pub fn deinit(self: *WindowsAttributes) void {
        if (self.handle) |handle|
            _ = std.os.windows.kernel32.CloseHandle(handle);
        if (self.iocp) |iocp|
            _ = std.os.windows.kernel32.CloseHandle(iocp);
    }
};

pub const FileSystemWatcher = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,

    linux: if (builtin.os.tag == .linux) LinuxAttributes else void,
    darwin: if (builtin.os.tag == .macos) DarwinAttributes else void,
    windows: if (builtin.os.tag == .windows) WindowsAttributes else void,

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8) FileSystemWatcher {
        return FileSystemWatcher{
            .allocator = allocator,
            .dir_path = dir_path,
            .linux = if (builtin.os.tag == .linux) .{},
            .darwin = if (builtin.os.tag == .macos) .{},
            .windows = if (builtin.os.tag == .windows) .{},
        };
    }

    pub fn start(self: *FileSystemWatcher) !void {
        switch (builtin.os.tag) {
            .linux => try self.startLinux(),
            .macos => try self.startDarwin(),
            .windows => try self.startWindows(),
            else => return error.UnsupportedPlatform,
        }
    }

    pub fn next(self: *FileSystemWatcher) !?WatchInfo {
        switch (builtin.os.tag) {
            .linux => return self.nextLinux(),
            .macos => return self.nextDarwin(),
            .windows => return self.nextWindows(),
            else => return error.UnsupportedPlatform,
        }
    }

    fn nextLinux(self: *FileSystemWatcher) !?WatchInfo {
        if (comptime builtin.os.tag != .linux)
            @compileError("Cannot call nextLinux on non-Linux platforms");

        const fd = self.linux.fd orelse return error.WatcherNotStarted;
        const nums = try std.posix.poll(&self.linux.fds, 0);
        if (nums == 0)
            return null;
        if (nums < 0)
            std.debug.panic("Bad poll (2)", .{});

        var buffer: [8096]u8 = undefined;
        const bytes_read = std.posix.system.read(fd, @ptrCast(@alignCast(&buffer)), 8096);
        if (bytes_read == 0)
            return null;

        var watchInfo: WatchInfo = .{
            .allocator = self.allocator,
            .list = std.ArrayList(WatchEvent).init(self.allocator),
        };
        errdefer watchInfo.deinit();

        var i: u32 = 0;
        while (i < bytes_read) : (i += LinuxAttributes.INotifyEventSize) {
            const event: *LinuxAttributes.INotifyEvent = @ptrCast(@alignCast(buffer[i..][0..LinuxAttributes.INotifyEventSize]));
            i += event.name_len;

            try watchInfo.list.append(.{
                .event = WatchEvent.Event{
                    .created = (event.mask & std.os.linux.IN.CREATE) > 0,
                    .delete = (event.mask & std.os.linux.IN.DELETE_SELF) > 0 or (event.mask & std.os.linux.IN.DELETE) > 0,
                    .modify = (event.mask & std.os.linux.IN.MODIFY) > 0,
                    .rename = (event.mask & std.os.linux.IN.MOVE_SELF) > 0,
                    .move_to = (event.mask & std.os.linux.IN.MOVED_TO) > 0,
                    .move_from = (event.mask & std.os.linux.IN.MOVED_FROM) > 0,
                },
                .name = try self.allocator.dupe(u8, std.mem.span(event.name())),
            });
            if (watchInfo.list.items.len >= MAX_EVENTS)
                break;
        }

        return watchInfo;
    }

    fn nextDarwin(self: *FileSystemWatcher) !?WatchInfo {
        if (comptime builtin.os.tag != .macos)
            @compileError("Cannot call nextDarwin on non-Darwin platforms");

        const fd = self.darwin.fd orelse return error.WatcherNotStarted;
        const map = self.darwin.map orelse return error.WatcherNotStarted;
        const names = self.darwin.names orelse return error.WatcherNotStarted;
        const files = self.darwin.files orelse return error.WatcherNotStarted;

        var list_arr: [128]DarwinAttributes.kevent = std.mem.zeroes([128]DarwinAttributes.kevent);
        var list = &list_arr;

        const kevents = map.values();
        var timespec = std.posix.timespec{ .tv_sec = 0, .tv_nsec = 0 };
        const count = std.posix.system.kevent(
            fd,
            @as([*]DarwinAttributes.kevent, kevents.ptr),
            @intCast(kevents.len),
            @as([*]DarwinAttributes.kevent, list),
            128,
            &timespec,
        );
        if (count == 0)
            return null;
        if (count < 0)
            std.debug.panic("Bad kevent", .{});

        var watchInfo: WatchInfo = .{
            .allocator = self.allocator,
            .list = std.ArrayList(WatchEvent).init(self.allocator),
        };
        errdefer watchInfo.deinit();

        var root = false;
        var changes = list[0..@as(usize, @intCast(count))];
        if (changes.len > 0) {
            try watchInfo.list.ensureTotalCapacity(@intCast(count));
            for (changes[0..]) |event| {
                if (watchInfo.list.items.len >= MAX_EVENTS)
                    break;
                if (event.udata == 0) {
                    if (root)
                        continue;
                    root = true;
                    const scandiff = try self.darwin.scanDirectory();
                    defer self.allocator.free(scandiff);
                    defer for (scandiff) |change| self.allocator.free(change.name);
                    for (scandiff) |change| {
                        try watchInfo.list.append(.{
                            .event = WatchEvent.Event{
                                .created = change.state == .created,
                                .delete = change.state == .deleted,
                                .modify = change.state == .modified,
                                .rename = change.state == .renamed,
                            },
                            .name = try self.allocator.dupe(u8, change.name),
                        });
                        if (watchInfo.list.items.len >= MAX_EVENTS)
                            break;
                    }
                    continue;
                }
                const name = names.get(event.udata) orelse continue;
                const info = files.get(name) orelse continue;
                if (info.kind == .file) {
                    const file = std.fs.File{
                        .handle = @intCast(event.ident),
                    };
                    const stat = try file.stat();
                    if (stat.ctime == info.modified) continue;
                    try watchInfo.list.append(.{
                        .event = WatchEvent.Event{ .modify = true },
                        .name = try self.allocator.dupe(u8, name),
                    });
                }
            }
        }

        return watchInfo;
    }

    fn nextWindows(self: *FileSystemWatcher) !?WatchInfo {
        if (comptime builtin.os.tag != .windows)
            @compileError("Cannot call nextWindows on non-Windows platforms");

        const iocp = self.windows.iocp orelse return error.WatcherNotStarted;
        if (!self.windows.active)
            return error.WatcherNotActive;

        if (!self.windows.monitoring)
            try self.windows.monitor();

        var nbytes: std.os.windows.DWORD = 0;
        var key: std.os.windows.ULONG_PTR = 0;
        var overlapped: ?*std.os.windows.OVERLAPPED = null;
        const rc = std.os.windows.kernel32.GetQueuedCompletionStatus(iocp, &nbytes, &key, &overlapped, 0);
        if (rc == 0) {
            const err = std.os.windows.kernel32.GetLastError();
            if (err == .TIMEOUT or err == .WAIT_TIMEOUT) return null else {
                std.debug.print("[Win32] Status failed: {s}\n", .{@tagName(err)});
                return error.UnknownError;
            }
        }

        self.windows.monitoring = false;

        if (overlapped) |ptr| {
            if (ptr != &self.windows.overlapped)
                return null;
            if (nbytes == 0) {
                self.windows.active = false;
                return error.Shutdown;
            }
            var watchInfo: WatchInfo = .{
                .allocator = self.allocator,
                .list = std.ArrayList(WatchEvent).init(self.allocator),
            };
            errdefer watchInfo.deinit();

            var n = true;
            var offset: usize = 0;
            while (n) {
                const info: *std.os.windows.FILE_NOTIFY_INFORMATION = @alignCast(@ptrCast(self.windows.buf[offset..].ptr));
                const name_ptr: [*]u16 = @alignCast(@ptrCast(self.windows.buf[offset + @sizeOf(std.os.windows.FILE_NOTIFY_INFORMATION) ..]));
                const filename: []u16 = name_ptr[0 .. info.FileNameLength / @sizeOf(u16)];

                const name = try std.unicode.utf16LeToUtf8Alloc(self.allocator, filename);
                errdefer self.allocator.free(name);

                const action: WindowsAttributes.Action = @enumFromInt(info.Action);

                if (info.NextEntryOffset == 0)
                    n = false
                else
                    offset += @as(usize, info.NextEntryOffset);

                try watchInfo.list.append(.{
                    .event = WatchEvent.Event{
                        .created = action == .Added,
                        .delete = action == .Removed,
                        .modify = action == .Modified,
                        .rename = action == .RenamedOld or action == .RenamedNew,
                    },
                    .name = name,
                });
                if (watchInfo.list.items.len >= MAX_EVENTS)
                    break;
            }

            return watchInfo;
        }
        return error.INVAL;
    }

    fn startLinux(self: *FileSystemWatcher) !void {
        const fd = try std.posix.inotify_init1(std.os.linux.IN.CLOEXEC);
        errdefer std.posix.close(fd);

        const wd = try std.posix.inotify_add_watch(
            fd,
            self.dir_path,
            std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.MOVED_TO | std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVE_SELF,
        );

        if (wd < 0)
            return error.InotifyAddWatchFailed;

        self.linux.fd = fd;
        self.linux.fds[0] = std.posix.pollfd{
            .fd = fd,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR,
            .revents = 0,
        };
    }

    fn startDarwin(self: *FileSystemWatcher) !void {
        const fd = try std.posix.kqueue();
        if (fd == 0)
            return error.KQueueError;
        errdefer std.posix.close(fd);

        const dir = try std.fs.cwd().openDir(self.dir_path, .{
            .access_sub_paths = false,
            .iterate = true,
        });

        var map = std.AutoArrayHashMap(usize, DarwinAttributes.kevent).init(self.allocator);
        errdefer map.deinit();
        var names = std.AutoArrayHashMap(usize, []const u8).init(self.allocator);
        errdefer names.deinit();
        var files = std.StringArrayHashMap(DarwinAttributes.FileInfo).init(self.allocator);
        errdefer files.deinit();

        const copy_path = try self.allocator.dupe(u8, self.dir_path);
        errdefer self.allocator.free(copy_path);
        try names.put(@intCast(dir.fd), copy_path);
        try map.put(@intCast(dir.fd), .{
            .data = 0,
            .udata = 0,
            .ident = @intCast(dir.fd),
            .filter = std.c.EVFILT_VNODE,
            .flags = std.c.EV_ADD | std.c.EV_ONESHOT | std.c.EV_ENABLE,
            .fflags = std.c.NOTE_DELETE | std.c.NOTE_WRITE | std.c.NOTE_RENAME | std.c.NOTE_EXTEND | std.c.NOTE_ATTRIB,
        });

        self.darwin.files = files;
        self.darwin.names = names;
        self.darwin.map = map;
        self.darwin.fd = fd;
        self.darwin.dir = dir;

        self.allocator.free(try self.darwin.scanDirectory());
    }

    fn startWindows(self: *FileSystemWatcher) !void {
        const wpath = try std.os.windows.sliceToPrefixedFileW(std.fs.cwd().fd, self.dir_path);

        const ptr = wpath.span().ptr;
        const path_len_bytes = @as(u16, @intCast(std.mem.sliceTo(ptr, 0).len * 2));

        var nt_name = std.os.windows.UNICODE_STRING{
            .Length = path_len_bytes,
            .MaximumLength = path_len_bytes,
            .Buffer = @constCast(ptr),
        };
        var attr = std.os.windows.OBJECT_ATTRIBUTES{
            .Length = @sizeOf(std.os.windows.OBJECT_ATTRIBUTES),
            .RootDirectory = std.fs.cwd().fd,
            .Attributes = 0,
            .ObjectName = &nt_name,
            .SecurityDescriptor = null,
            .SecurityQualityOfService = null,
        };
        var handle: std.os.windows.HANDLE = std.os.windows.INVALID_HANDLE_VALUE;
        var io: std.os.windows.IO_STATUS_BLOCK = undefined;

        // This code is based on https://github.com/oven-sh/bun/blob/c2c204807242340b7dfe6537d84771bdff7bb85e/src/watcher.zig#L335
        const rc = std.os.windows.ntdll.NtCreateFile(
            &handle,
            std.os.windows.FILE_LIST_DIRECTORY,
            &attr,
            &io,
            null,
            0,
            std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE | std.os.windows.FILE_SHARE_DELETE,
            std.os.windows.FILE_OPEN,
            std.os.windows.FILE_DIRECTORY_FILE | std.os.windows.FILE_OPEN_FOR_BACKUP_INTENT,
            null,
            0,
        );
        if (rc != .SUCCESS) {
            std.debug.print("[Win32] Failed to open directory for watching: {s}\n", .{@tagName(rc)});
            return error.CreateFileFailed;
        }
        errdefer _ = std.os.windows.kernel32.CloseHandle(handle);

        const iocp = try std.os.windows.CreateIoCompletionPort(handle, null, 0, 1);
        errdefer _ = std.os.windows.kernel32.CloseHandle(iocp);

        self.windows.handle = handle;
        self.windows.iocp = iocp;

        try self.windows.monitor();
    }

    pub fn deinit(self: *FileSystemWatcher) void {
        switch (builtin.os.tag) {
            .linux => self.linux.deinit(),
            .macos => self.darwin.deinit(self.allocator),
            else => {},
        }
    }
};

test "Platform Watch" {
    const allocator = std.testing.allocator;

    const temporaryDir = std.testing.tmpDir(std.fs.Dir.OpenDirOptions{
        .access_sub_paths = true,
    });

    const tempPath = try std.mem.join(allocator, "/", &.{
        ".zig-cache/tmp",
        &temporaryDir.sub_path,
        "fs-watch-test",
    });
    defer allocator.free(tempPath);

    const tempFile = try std.mem.join(allocator, "/", &.{
        tempPath,
        "test.txt",
    });
    defer allocator.free(tempFile);

    try std.fs.cwd().makePath(tempPath);
    defer std.fs.cwd().deleteDir(tempPath) catch std.debug.panic("Failed to delete test directory", .{});

    var watcher = FileSystemWatcher.init(allocator, tempPath);
    defer watcher.deinit();

    try watcher.start();

    {
        const info = try watcher.next();
        if (info) |i| {
            i.deinit();
            return error.UnexpectedEvent;
        }
    }

    // TODO: Renable test for macOs, cannot detect file modification in tests.
    if (builtin.os.tag == .macos)
        return;

    { // Create file
        const file = try std.fs.cwd().createFile(tempFile, .{});
        errdefer std.fs.cwd().deleteFile(tempFile) catch std.debug.panic("Failed to delete test.txt", .{});
        defer file.close();

        {
            const info = try watcher.next() orelse return error.ExpectedEvent;
            defer info.deinit();
            try std.testing.expectEqual(1, info.list.items.len);
            try std.testing.expectEqualStrings("test.txt", info.list.items[0].name);
            try std.testing.expect(info.list.items[0].event.created);
            try std.testing.expect(!info.list.items[0].event.delete);
            try std.testing.expect(!info.list.items[0].event.modify);
            try std.testing.expect(!info.list.items[0].event.rename);
            try std.testing.expect(!info.list.items[0].event.move_to);
        }

        // Modify file
        try file.writeAll("Hello, world!\n");
        try file.sync();

        {
            const info = try watcher.next() orelse return error.ExpectedEvent;
            defer info.deinit();
            try std.testing.expectEqual(1, info.list.items.len);
            try std.testing.expectEqualStrings("test.txt", info.list.items[0].name);
            try std.testing.expect(!info.list.items[0].event.created);
            try std.testing.expect(!info.list.items[0].event.delete);
            try std.testing.expect(info.list.items[0].event.modify);
            try std.testing.expect(!info.list.items[0].event.rename);
            try std.testing.expect(!info.list.items[0].event.move_to);
        }
    }

    // Delete file
    try std.fs.cwd().deleteFile(tempFile);

    {
        const info = try watcher.next() orelse return error.ExpectedEvent;
        defer info.deinit();
        try std.testing.expectEqual(1, info.list.items.len);
        try std.testing.expectEqualStrings("test.txt", info.list.items[0].name);
        try std.testing.expect(!info.list.items[0].event.created);
        try std.testing.expect(info.list.items[0].event.delete);
        try std.testing.expect(!info.list.items[0].event.modify);
        try std.testing.expect(!info.list.items[0].event.rename);
        try std.testing.expect(!info.list.items[0].event.move_to);
    }
}
