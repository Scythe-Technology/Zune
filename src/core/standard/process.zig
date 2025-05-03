const std = @import("std");
const xev = @import("xev").Dynamic;
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("../../zune.zig");
const tagged = @import("../../tagged.zig");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");
const Parser = @import("../utils/parser.zig");

const File = @import("../objects/filesystem/File.zig");
const ProcessChild = @import("../objects/process//Child.zig");

const luaHelper = @import("../utils/luahelper.zig");
const sysfd = @import("../utils/sysfd.zig");
const EnumMap = @import("../utils/enum_map.zig");
const MethodMap = @import("../utils/method_map.zig");

const VM = luau.VM;

const process = std.process;

const native_os = builtin.os.tag;

const TAG_PROCESS_CHILD = tagged.Tags.get("PROCESS_CHILD").?;

pub const LIB_NAME = "process";
pub fn PlatformSupported() bool {
    return true;
}

pub var SIGINT_LUA: ?LuaSigHandler = null;

const LuaSigHandler = struct {
    state: *VM.lua.State,
    ref: i32,
};

const ProcessArgsError = error{
    InvalidArgType,
    NotArray,
};

const ProcessEnvError = error{
    InvalidKeyType,
    InvalidValueType,
};

fn internal_process_getargs(L: *VM.lua.State, array: *std.ArrayList([]const u8), idx: i32) !void {
    try L.Zchecktype(idx, .Table);
    L.pushvalue(idx);
    L.pushnil();

    var i: i32 = 1;
    while (L.next(-2)) {
        const keyType = L.typeOf(-2);
        const valueType = L.typeOf(-1);
        if (keyType != .Number)
            return ProcessArgsError.NotArray;

        const num = L.tointeger(-2) orelse return ProcessArgsError.NotArray;
        if (num != i)
            return ProcessArgsError.NotArray;
        if (valueType != .String)
            return ProcessArgsError.InvalidArgType;

        const value = L.tostring(-1) orelse return ProcessArgsError.InvalidArgType;

        try array.append(value);
        L.pop(1);
        i += 1;
    }
    L.pop(1);
}

fn internal_process_envmap(L: *VM.lua.State, envMap: *std.process.EnvMap, idx: i32) !void {
    try L.Zchecktype(idx, .Table);
    L.pushvalue(idx);
    L.pushnil();

    while (L.next(-2)) {
        const keyType = L.typeOf(-2);
        const valueType = L.typeOf(-1);
        if (keyType != .String)
            return ProcessEnvError.InvalidKeyType;
        if (valueType != .String)
            return ProcessEnvError.InvalidValueType;
        const key = L.tostring(-2) orelse return ProcessEnvError.InvalidKeyType;
        const value = L.tostring(-1) orelse return ProcessEnvError.InvalidValueType;
        try envMap.put(key, value);
        L.pop(1);
    }
    L.pop(1);
}

const ProcessChildOptions = struct {
    cwd: ?[]const u8 = null,
    env: ?process.EnvMap = null,
    joined: ?[]const u8 = null,
    argArray: std.ArrayList([]const u8),
    stdio: enum { inherit, pipe, ignore } = .pipe,

    pub fn init(L: *VM.lua.State) !ProcessChildOptions {
        const cmd = try L.Zcheckvalue([:0]const u8, 1, null);
        const options = !L.typeOf(3).isnoneornil();

        const allocator = luau.getallocator(L);

        var shell: ?[]const u8 = null;
        var shell_inline: ?[]const u8 = "-c";

        var childOptions: ProcessChildOptions = .{
            .argArray = std.ArrayList([]const u8).init(allocator),
        };
        errdefer childOptions.argArray.deinit();

        if (options) {
            try L.Zchecktype(3, .Table);

            childOptions.cwd = try L.Zcheckfield(?[]const u8, 3, "cwd");

            const envType = L.getfield(3, "env");
            if (!envType.isnoneornil()) {
                if (envType == .Table) {
                    childOptions.env = std.process.EnvMap.init(allocator);
                    internal_process_envmap(L, &childOptions.env.?, -1) catch |err| switch (err) {
                        ProcessEnvError.InvalidKeyType => return L.Zerror("Invalid environment key"),
                        ProcessEnvError.InvalidValueType => return L.Zerror("Invalid environment value"),
                        else => return L.Zerror("Unknown Error"),
                    };
                } else return L.Zerrorf("Invalid environment (table expected, got {s})", .{VM.lapi.typename(envType)});
            }
            L.pop(1);

            switch (L.getfield(3, "stdio")) {
                .None, .Nil => {},
                .String => {
                    const stdioOption = L.tostring(-1) orelse unreachable;
                    if (std.mem.eql(u8, stdioOption, "inherit")) {
                        childOptions.stdio = .inherit;
                    } else if (std.mem.eql(u8, stdioOption, "pipe")) {
                        childOptions.stdio = .pipe;
                    } else if (std.mem.eql(u8, stdioOption, "ignore")) {
                        childOptions.stdio = .ignore;
                    } else return L.Zerrorf("Invalid stdio option (inherit/pipe/ignore expected, got {s})", .{stdioOption});
                },
                else => return L.Zerrorf("Invalid stdio option (string expected, got {s})", .{VM.lapi.typename(L.typeOf(-1))}),
            }
            L.pop(1);

            switch (L.getfield(3, "shell")) {
                .None, .Nil => {},
                .String => blk: {
                    const shellOption = L.tostring(-1) orelse unreachable;

                    switch (std.StaticStringMap(enum { shell, bash, powershell, cmd }).initComptime(.{
                        .{ "sh", .shell },
                        .{ "/bin/sh", .shell },
                        .{ "bash", .bash },
                        .{ "powershell", .powershell },
                        .{ "ps", .powershell },
                        .{ "cmd", .cmd },
                    }).get(shellOption) orelse {
                        shell = shellOption;
                        shell_inline = null;
                        break :blk;
                    }) {
                        .shell => shell = "/bin/sh",
                        .bash => shell = "bash",
                        .powershell => shell = "powershell",
                        .cmd => {
                            shell = "cmd";
                            shell_inline = "/c";
                        },
                    }
                },
                .Boolean => {
                    if (L.toboolean(-1)) {
                        switch (native_os) {
                            .windows => shell = "powershell",
                            .macos, .linux => shell = "/bin/sh",
                            else => shell = "/bin/sh",
                        }
                    }
                },
                else => |t| return L.Zerrorf("Invalid shell (string or boolean expected, got {s})", .{VM.lapi.typename(t)}),
            }
            L.pop(1);
        }

        try childOptions.argArray.append(cmd);

        if (L.typeOf(2) == .Table)
            try internal_process_getargs(L, &childOptions.argArray, 2);

        if (shell) |s| {
            const joined = try std.mem.join(allocator, " ", childOptions.argArray.items);
            errdefer allocator.free(joined);
            childOptions.joined = joined;
            childOptions.argArray.clearRetainingCapacity();
            try childOptions.argArray.append(s);
            if (shell_inline) |inlineCmd|
                try childOptions.argArray.append(inlineCmd);
            try childOptions.argArray.append(joined);
        }

        return childOptions;
    }

    fn deinit(self: *ProcessChildOptions) void {
        if (self.env) |*env|
            env.deinit();
        if (self.joined) |mem|
            self.argArray.allocator.free(mem);
        self.argArray.deinit();
    }
};

const ProcessAsyncRunContext = struct {
    completion: xev.Completion,
    ref: Scheduler.ThreadRef,
    proc: xev.Process,
    poller: ?std.io.Poller(ProcessAsyncRunContext.PollEnum),

    stdout: ?std.fs.File,
    stderr: ?std.fs.File,

    pub const PollEnum = enum {
        stdout,
        stderr,
    };

    pub fn complete(
        ud: ?*ProcessAsyncRunContext,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Process.WaitError!u32,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        if (self.poller) |*poller|
            _ = poller.poll() catch {};

        const scheduler = Scheduler.getScheduler(L);
        defer scheduler.completeAsync(self);
        defer self.ref.deref();
        defer self.proc.deinit();
        defer if (self.poller) |*poller| poller.deinit();
        defer {
            if (self.stdout) |stdout|
                stdout.close();
            if (self.stderr) |stderr|
                stderr.close();
        }

        if (L.status() != .Yield)
            return .disarm;

        const code: u32 = r catch |err| switch (@as(anyerror, err)) {
            error.NoSuchProcess => 0, // kqueue
            else => blk: {
                std.debug.print("[Process Wait Error: {}]\n", .{err});
                break :blk 1;
            },
        };

        if (self.poller) |*poller| {
            const stdout_fifo = poller.fifo(.stdout);
            const stdout = stdout_fifo.readableSliceOfLen(@min(stdout_fifo.count, luaHelper.MAX_LUAU_SIZE));
            const stderr_fifo = poller.fifo(.stderr);
            const stderr = stderr_fifo.readableSliceOfLen(@min(stderr_fifo.count, luaHelper.MAX_LUAU_SIZE));

            L.Zpushvalue(.{
                .code = code,
                .ok = code == 0,
                .stdout = stdout,
                .stderr = stderr,
            });
        } else {
            L.Zpushvalue(.{
                .code = code,
                .ok = code == 0,
            });
        }

        _ = Scheduler.resumeState(L, null, 1) catch {};

        return .disarm;
    }
};

fn process_run(L: *VM.lua.State) !i32 {
    if (comptime !std.process.can_spawn)
        return error.UnsupportedPlatform;
    const scheduler = Scheduler.getScheduler(L);
    const allocator = luau.getallocator(L);

    var options = try ProcessChildOptions.init(L);
    defer options.deinit();

    var child = process.Child.init(options.argArray.items, allocator);
    child.stdin_behavior = if (options.stdio == .inherit) .Inherit else .Ignore;
    child.stdout_behavior = switch (options.stdio) {
        .inherit => .Inherit,
        .pipe => .Pipe,
        .ignore => .Ignore,
    };
    child.stderr_behavior = switch (options.stdio) {
        .inherit => .Inherit,
        .pipe => .Pipe,
        .ignore => .Ignore,
    };
    child.cwd = options.cwd;
    child.env_map = if (options.env) |env|
        &env
    else
        null;
    child.expand_arg0 = .no_expand;

    try child.spawn();
    try child.waitForSpawn();
    errdefer _ = child.kill() catch {};

    const poller = if (options.stdio == .pipe) std.io.poll(allocator, ProcessAsyncRunContext.PollEnum, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    }) else null;

    var proc = try xev.Process.init(child.id);
    errdefer proc.deinit();

    const self = try scheduler.createAsyncCtx(ProcessAsyncRunContext);

    self.* = .{
        .completion = .init(),
        .proc = proc,
        .stdout = child.stdout,
        .stderr = child.stderr,
        .poller = poller,
        .ref = .init(L),
    };

    proc.wait(
        &scheduler.loop,
        &self.completion,
        ProcessAsyncRunContext,
        self,
        ProcessAsyncRunContext.complete,
    );

    scheduler.loop.submit() catch {};

    return L.yield(0);
}

fn process_create(L: *VM.lua.State) !i32 {
    if (comptime !std.process.can_spawn)
        return error.UnsupportedPlatform;
    const allocator = luau.getallocator(L);

    var options = try ProcessChildOptions.init(L);
    defer options.deinit();

    var child = process.Child.init(options.argArray.items, allocator);
    child.expand_arg0 = .no_expand;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = options.cwd;
    child.env_map = if (options.env) |env|
        &env
    else
        null;

    switch (comptime builtin.os.tag) {
        .windows => try @import("../utils/os/windows.zig").spawnWindows(&child),
        else => try child.spawn(),
    }
    try child.waitForSpawn();
    errdefer _ = child.kill() catch {};

    try ProcessChild.push(L, child);

    return 1;
}

fn process_exit(L: *VM.lua.State) i32 {
    const code = L.Lcheckunsigned(1);
    Scheduler.KillSchedulers();
    Engine.stateCleanUp();
    std.process.exit(@truncate(code));
    return 0;
}

const DotEnvError = error{
    InvalidString,
    InvalidCharacter,
};

fn decodeString(L: *VM.lua.State, slice: []const u8) !usize {
    var buf = std.ArrayList(u8).init(luau.getallocator(L));
    defer buf.deinit();

    if (slice.len < 2)
        return DotEnvError.InvalidString;
    if (slice[0] == slice[1]) {
        L.pushstring("");
        return 2;
    }

    const stringQuote: u8 = slice[0];
    var pos: usize = 1;
    var eof: bool = false;
    while (pos <= slice.len) {
        switch (slice[pos]) {
            '\\' => if (stringQuote != '\'') {
                pos += 1;
                if (pos >= slice.len)
                    return DotEnvError.InvalidString;
                switch (slice[pos]) {
                    'n' => try buf.append('\n'),
                    '"', '`', '\'' => |b| try buf.append(b),
                    else => return DotEnvError.InvalidString,
                }
            } else try buf.append('\\'),
            '"', '`', '\'' => |c| if (c == stringQuote) {
                eof = true;
                pos += 1;
                break;
            } else try buf.append(c),
            '\r' => {},
            else => |b| try buf.append(b),
        }
        pos += 1;
    }
    if (eof) {
        L.pushlstring(buf.items);
        return pos;
    } else L.pushstring("");
    return 0;
}

const WHITESPACE = [_]u8{ 32, '\t' };
const DECODE_BREAK = [_]u8{ '#', '\n' };

fn validateWord(slice: []const u8) !void {
    for (slice) |b| switch (b) {
        0...32 => return DotEnvError.InvalidCharacter,
        else => {},
    };
}

fn decodeEnvironment(L: *VM.lua.State, string: []const u8) !void {
    var pos: usize = 0;
    var scan: usize = 0;
    while (pos < string.len) switch (string[pos]) {
        '\n' => {
            pos += 1;
            scan = pos;
        },
        '#' => {
            pos += std.mem.indexOfScalar(u8, string[pos..], '\n') orelse string.len - pos;
            scan = pos;
        },
        '=' => {
            const variableName = Parser.trimSpace(string[scan..pos]);
            pos += 1;
            if (pos >= string.len)
                break;
            try validateWord(variableName);
            pos += Parser.nextNonCharacter(string[pos..], &WHITESPACE);
            L.pushlstring(variableName);
            errdefer L.pop(1);
            if (string[pos] == '"' or string[pos] == '\'' or string[pos] == '`') {
                const stringEof = try decodeString(L, string[pos..]);
                const remaining_slice = string[pos + stringEof ..];
                const eof = Parser.nextCharacter(remaining_slice, &DECODE_BREAK);
                if (Parser.trimSpace(remaining_slice[0..eof]).len == 0) {
                    L.settable(-3);
                    pos += stringEof;
                    pos += eof;
                    continue;
                }
                L.pop(1);
            }
            const eof = Parser.nextCharacter(string[pos..], &DECODE_BREAK);
            L.pushlstring(Parser.trimSpace(string[pos .. pos + eof]));
            L.settable(-3);
            pos += eof;
        },
        else => pos += 1,
    };
}

fn loadEnvironment(L: *VM.lua.State, allocator: std.mem.Allocator, file: []const u8) !void {
    const bytes: []const u8 = std.fs.cwd().readFileAlloc(allocator, file, std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return L.Zerrorf("InternalError ({s})", .{@errorName(err)}),
    };
    defer allocator.free(bytes);

    decodeEnvironment(L, bytes) catch {};
}

fn process_loadEnv(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    L.newtable();

    var iterator = Zune.EnvironmentMap.iterator();
    while (iterator.next()) |entry| {
        const zkey = try allocator.dupeZ(u8, entry.key_ptr.*);
        defer allocator.free(zkey);
        L.Zsetfield(-1, zkey, entry.value_ptr.*);
    }

    try loadEnvironment(L, allocator, ".env");
    if (Zune.EnvironmentMap.get("LUAU_ENV")) |value| {
        if (std.mem.eql(u8, value, "PRODUCTION")) {
            try loadEnvironment(L, allocator, ".env.production");
        } else if (std.mem.eql(u8, value, "DEVELOPMENT")) {
            try loadEnvironment(L, allocator, ".env.development");
        } else if (std.mem.eql(u8, value, "TEST")) {
            try loadEnvironment(L, allocator, ".env.test");
        }
    }
    try loadEnvironment(L, allocator, ".env.local");

    return 1;
}

fn process_onsignal(L: *VM.lua.State) !i32 {
    const sig = try L.Zcheckvalue([:0]const u8, 1, null);
    try L.Zchecktype(2, .Function);

    if (std.mem.eql(u8, sig, "INT")) {
        const GL = L.mainthread();
        if (GL != L)
            L.xpush(GL, 2);

        const ref = GL.ref(if (GL != L) -1 else 2) orelse return L.Zerror("Failed to create reference");
        if (GL != L)
            GL.pop(1);

        if (SIGINT_LUA) |handler|
            handler.state.unref(handler.ref);

        SIGINT_LUA = .{
            .state = GL,
            .ref = ref,
        };
    } else return L.Zerrorf("Unknown signal: {s}", .{sig});

    return 0;
}

fn process_getCwd(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(path);
    L.pushlstring(path);
    return 1;
}

pub fn loadLib(L: *VM.lua.State, args: []const []const u8) !void {
    L.createtable(0, 10);

    L.Zsetfield(-1, "arch", @tagName(builtin.cpu.arch));
    L.Zsetfield(-1, "os", @tagName(native_os));

    {
        L.Zpushvalue(args);
        L.setfield(-2, "args");
    }

    _ = try process_loadEnv(L);
    L.setfield(-2, "env");
    L.Zsetfieldfn(-1, "loadEnv", process_loadEnv);

    L.Zsetfieldfn(-1, "getCwd", process_getCwd);

    L.Zsetfieldfn(-1, "exit", process_exit);
    L.Zsetfieldfn(-1, "run", process_run);
    L.Zsetfieldfn(-1, "create", process_create);
    L.Zsetfieldfn(-1, "onSignal", process_onsignal);

    L.setreadonly(-1, true);

    luaHelper.registerModule(L, LIB_NAME);
}

test "process" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/process.test.luau"),
        &.{ "Test", "someValue" },
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
