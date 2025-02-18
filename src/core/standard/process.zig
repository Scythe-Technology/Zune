const std = @import("std");
const builtin = @import("builtin");
const luau = @import("luau");

const Zune = @import("../../zune.zig");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");
const Parser = @import("../utils/parser.zig");

const luaHelper = @import("../utils/luahelper.zig");
const sysfd = @import("../utils/sysfd.zig");

const VM = luau.VM;

const process = std.process;

const native_os = builtin.os.tag;

pub const LIB_NAME = "process";

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

fn internal_process_term(L: *VM.lua.State, term: process.Child.Term) void {
    L.Zsetfield(-1, "status", @tagName(term));
    switch (term) {
        .Exited => |code| {
            L.Zsetfield(-1, "code", code);
            L.Zsetfield(-1, "ok", code == 0);
        },
        .Stopped, .Signal, .Unknown => |code| {
            L.Zsetfield(-1, "code", code);
            L.Zsetfield(-1, "ok", false);
        },
    }
}

const ProcessChildHandle = struct {
    options: ProcessChildOptions,
    child: process.Child,
    poller: ?std.io.Poller(PollEnum),
    dead: bool = false,

    pub const PollEnum = enum {
        stdout,
        stderr,
    };

    pub const META = "process_child_instance";

    fn method_kill(self: *ProcessChildHandle, L: *VM.lua.State) !i32 {
        const term = try self.child.kill();
        self.dead = true;
        L.createtable(0, 3);
        internal_process_term(L, term);
        return 1;
    }

    fn method_wait(self: *ProcessChildHandle, L: *VM.lua.State) !i32 {
        const term = try self.child.wait();
        self.dead = true;
        L.createtable(0, 3);
        internal_process_term(L, term);
        return 1;
    }

    fn method_readOut(self: *ProcessChildHandle, L: *VM.lua.State) !i32 {
        const maxBytes = L.tounsigned(2) orelse luaHelper.MAX_LUAU_SIZE;
        if (maxBytes == 0)
            return 0;

        if (self.poller) |*poller| {
            if (!try poller.pollTimeout(0)) {
                self.dead = true;
                return 0;
            }
            const fifo = poller.fifo(.stdout);
            if (fifo.count == 0)
                return 0;

            const read = @min(maxBytes, fifo.count);
            L.pushlstring(fifo.readableSliceOfLen(read));
            fifo.discard(read);

            return 1;
        }
        return 0;
    }

    fn method_readOutAsync(self: *ProcessChildHandle, L: *VM.lua.State, scheduler: *Scheduler) !i32 {
        const maxBytes = L.tounsigned(2) orelse luaHelper.MAX_LUAU_SIZE;
        if (maxBytes == 0)
            return 0;

        if (self.poller) |*poller| {
            if (!try poller.pollTimeout(0)) {
                self.dead = true;
                return 0;
            }
            const fifo = poller.fifo(.stdout);
            if (fifo.count == 0) {
                const TaskContext = struct { *ProcessChildHandle, usize };
                return try scheduler.addSimpleTask(TaskContext, .{ self, maxBytes }, L, struct {
                    fn inner(ctx: *TaskContext, l: *VM.lua.State, _: *Scheduler) !i32 {
                        const ptr, const max_bytes = ctx.*;
                        if (ptr.poller) |*p| {
                            if (!try p.pollTimeout(0)) {
                                ptr.dead = true;
                                return 0;
                            }
                            const sub_fifo = p.fifo(.stdout);
                            if (sub_fifo.count == 0)
                                return -1;

                            const read = @min(max_bytes, sub_fifo.count);
                            l.pushlstring(sub_fifo.readableSliceOfLen(read));
                            sub_fifo.discard(read);

                            return 1;
                        }
                        return 0;
                    }
                }.inner);
            }

            const read = @min(maxBytes, fifo.count);
            L.pushlstring(fifo.readableSliceOfLen(read));
            fifo.discard(read);
            return 1;
        }
        return 0;
    }

    fn method_readErr(self: *ProcessChildHandle, L: *VM.lua.State) !i32 {
        const maxBytes = L.tounsigned(2) orelse luaHelper.MAX_LUAU_SIZE;
        if (maxBytes == 0)
            return 0;

        if (self.poller) |*poller| {
            if (!try poller.pollTimeout(0)) {
                self.dead = true;
                return 0;
            }
            const fifo = poller.fifo(.stderr);
            if (fifo.count == 0)
                return 0;

            const read = @min(maxBytes, fifo.count);
            L.pushlstring(fifo.readableSliceOfLen(read));
            fifo.discard(read);

            return 1;
        }
        return 0;
    }

    fn method_readErrAsync(self: *ProcessChildHandle, L: *VM.lua.State, scheduler: *Scheduler) !i32 {
        const maxBytes = L.tounsigned(2) orelse luaHelper.MAX_LUAU_SIZE;
        if (maxBytes == 0)
            return 0;

        if (self.poller) |*poller| {
            if (!try poller.pollTimeout(0)) {
                self.dead = true;
                return 0;
            }
            const fifo = poller.fifo(.stderr);
            if (fifo.count == 0) {
                const TaskContext = struct { *ProcessChildHandle, usize };
                return try scheduler.addSimpleTask(TaskContext, .{ self, maxBytes }, L, struct {
                    fn inner(ctx: *TaskContext, l: *VM.lua.State, _: *Scheduler) !i32 {
                        const ptr, const max_bytes = ctx.*;
                        if (ptr.poller) |*p| {
                            if (!try p.pollTimeout(0)) {
                                ptr.dead = true;
                                return 0;
                            }
                            const sub_fifo = p.fifo(.stderr);
                            if (sub_fifo.count == 0)
                                return -1;

                            const read = @min(max_bytes, sub_fifo.count);
                            l.pushlstring(sub_fifo.readableSliceOfLen(read));
                            sub_fifo.discard(read);

                            return 1;
                        }
                        return 0;
                    }
                }.inner);
            }

            const read = @min(maxBytes, fifo.count);
            L.pushlstring(fifo.readableSliceOfLen(read));
            fifo.discard(read);

            return 1;
        }
        return 0;
    }

    fn method_writeIn(self: *ProcessChildHandle, L: *VM.lua.State) !i32 {
        if (self.child.stdin == null)
            return L.Zerror("InternalError (No stdin stream found)");
        if (self.child.stdin_behavior != .Pipe)
            return L.Zerror("InternalError (stdin stream is not a pipe)");
        const buffer = try L.Zcheckvalue([]const u8, 2, null);
        try self.child.stdin.?.writeAll(buffer);
        return 1;
    }

    pub const NamecallMap = std.StaticStringMap(enum {
        Kill,
        Wait,
        ReadOut,
        ReadOutAsync,
        ReadErr,
        ReadErrAsync,
        WriteIn,
    }).initComptime(.{
        .{ "kill", .Kill },
        .{ "wait", .Wait },
        .{ "readOut", .ReadOut },
        .{ "readOutAsync", .ReadOutAsync },
        .{ "readErr", .ReadErr },
        .{ "readErrAsync", .ReadErrAsync },
        .{ "writeIn", .WriteIn },
    });

    pub fn __namecall(L: *VM.lua.State) !i32 {
        const scheduler = Scheduler.getScheduler(L);

        try L.Zchecktype(1, .Userdata);
        const ptr = L.touserdata(ProcessChildHandle, 1) orelse unreachable;
        const namecall = L.namecallstr() orelse unreachable;

        return switch (NamecallMap.get(namecall) orelse return L.Zerrorf("Unknown method: {s}", .{namecall})) {
            .Kill => method_kill(ptr, L),
            .Wait => method_wait(ptr, L),
            .ReadOut => method_readOut(ptr, L),
            .ReadOutAsync => method_readOutAsync(ptr, L, scheduler),
            .ReadErr => method_readErr(ptr, L),
            .ReadErrAsync => method_readErrAsync(ptr, L, scheduler),
            .WriteIn => method_writeIn(ptr, L),
        };
    }

    pub const IndexMap = std.StaticStringMap(enum {
        Dead,
    }).initComptime(.{
        .{ "dead", .Dead },
    });

    pub fn __index(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const handlePtr = L.touserdata(ProcessChildHandle, 1) orelse unreachable;
        const index = L.Lcheckstring(2);

        switch (IndexMap.get(index) orelse return L.Zerrorf("Unknown index: {s}", .{index})) {
            .Dead => L.pushboolean(handlePtr.dead),
        }

        return 1;
    }

    pub fn __dtor(self: *ProcessChildHandle) void {
        var options = self.options;
        options.deinit();
        if (self.poller) |*poller| poller.deinit();
        self.poller = null;
    }
};

const ProcessChildOptions = struct {
    cmd: []const u8,
    cwd: ?[]const u8 = null,
    env: ?process.EnvMap = null,
    shell: ?[]const u8 = null,
    shell_inline: ?[]const u8 = "-c",
    argArray: std.ArrayList([]const u8),
    tagged: std.ArrayList([]const u8),

    pub fn init(L: *VM.lua.State) !ProcessChildOptions {
        const cmd = try L.Zcheckvalue([:0]const u8, 1, null);
        const useArgs = L.typeOf(2) == .Table;
        const options = !L.typeOf(3).isnoneornil();

        const allocator = luau.getallocator(L);

        var childOptions = ProcessChildOptions{
            .cmd = cmd,
            .argArray = std.ArrayList([]const u8).init(allocator),
            .tagged = std.ArrayList([]const u8).init(allocator),
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

            const shellType = L.getfield(3, "shell");
            if (!shellType.isnoneornil()) {
                if (shellType == .String) {
                    const shellOption = L.tostring(-1) orelse unreachable;

                    // TODO: prob should switch to static string map
                    if (std.mem.eql(u8, shellOption, "sh") or std.mem.eql(u8, shellOption, "/bin/sh")) {
                        childOptions.shell = "/bin/sh";
                    } else if (std.mem.eql(u8, shellOption, "bash")) {
                        childOptions.shell = "bash";
                    } else if (std.mem.eql(u8, shellOption, "powershell") or std.mem.eql(u8, shellOption, "ps")) {
                        childOptions.shell = "powershell";
                    } else if (std.mem.eql(u8, shellOption, "cmd")) {
                        childOptions.shell = "cmd";
                        childOptions.shell_inline = "/c";
                    } else {
                        childOptions.shell = shellOption;
                        childOptions.shell_inline = null;
                    }
                } else if (shellType == .Boolean) {
                    if (L.toboolean(-1)) {
                        switch (native_os) {
                            .windows => childOptions.shell = "powershell",
                            .macos, .linux => childOptions.shell = "/bin/sh",
                            else => childOptions.shell = "/bin/sh",
                        }
                    }
                } else return L.Zerrorf("Invalid shell (string or boolean expected, got {s})", .{VM.lapi.typename(shellType)});
            }
            L.pop(1);
        }

        if (useArgs)
            try internal_process_getargs(L, &childOptions.argArray, 2);

        try childOptions.argArray.insert(0, childOptions.cmd);
        if (childOptions.shell) |shell| {
            const joined = try std.mem.join(allocator, " ", childOptions.argArray.items);
            try childOptions.tagged.append(joined);
            childOptions.argArray.clearAndFree();
            try childOptions.argArray.append(shell);
            if (childOptions.shell_inline) |inlineCmd|
                try childOptions.argArray.append(inlineCmd);
            try childOptions.argArray.append(joined);
        }

        return childOptions;
    }

    fn deinit(self: *ProcessChildOptions) void {
        if (self.env) |*env|
            env.deinit();
        for (self.tagged.items) |mem|
            self.tagged.allocator.free(mem);
        self.argArray.deinit();
        self.tagged.deinit();
    }
};

const ProcessAsyncRun = struct {
    child: process.Child,
    poller: std.io.Poller(ProcessChildHandle.PollEnum),
    max_output_bytes: usize = 50 * 1024,

    pub fn update(ctx: *ProcessAsyncRun, L: *VM.lua.State, _: *Scheduler) !i32 {
        if (try ctx.poller.pollTimeout(0)) {
            errdefer _ = ctx.child.kill() catch {};
            errdefer ctx.poller.deinit();
            if (ctx.poller.fifo(.stdout).count > ctx.max_output_bytes)
                return error.StdoutStreamTooLong;
            if (ctx.poller.fifo(.stderr).count > ctx.max_output_bytes)
                return error.StderrStreamTooLong;
            return -1;
        }
        defer ctx.poller.deinit();

        const stdout_fifo = ctx.poller.fifo(.stdout);
        const stdout = stdout_fifo.readableSliceOfLen(stdout_fifo.count);
        const stderr_fifo = ctx.poller.fifo(.stderr);
        const stderr = stderr_fifo.readableSliceOfLen(stderr_fifo.count);

        const term = try ctx.child.wait();

        L.createtable(0, 5);

        L.Zsetfield(-1, "stdout", stdout);
        L.Zsetfield(-1, "stderr", stderr);

        internal_process_term(L, term);

        return 1;
    }
};

fn process_run(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);
    const allocator = luau.getallocator(L);

    var childOptions = try ProcessChildOptions.init(L);
    defer childOptions.deinit();

    var child = process.Child.init(childOptions.argArray.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = childOptions.cwd;
    child.env_map = if (childOptions.env) |env|
        &env
    else
        null;
    child.expand_arg0 = .no_expand;

    try child.spawn();

    const poller = std.io.poll(allocator, ProcessChildHandle.PollEnum, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });

    return scheduler.addSimpleTask(ProcessAsyncRun, .{
        .child = child,
        .poller = poller,
    }, L, ProcessAsyncRun.update);
}

fn process_create(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const childOptions = try ProcessChildOptions.init(L);

    const handlePtr = L.newuserdatadtor(ProcessChildHandle, ProcessChildHandle.__dtor);
    var childProcess = process.Child.init(childOptions.argArray.items, allocator);

    childProcess.id = undefined;
    childProcess.thread_handle = undefined;
    if (builtin.os.tag != .windows)
        childProcess.err_pipe = null;
    childProcess.term = null;
    childProcess.uid = if (native_os == .windows or native_os == .wasi) {} else null;
    childProcess.gid = if (native_os == .windows or native_os == .wasi) {} else null;
    childProcess.stdin = null;
    childProcess.stdout = null;
    childProcess.stderr = null;
    childProcess.expand_arg0 = .no_expand;

    childProcess.stdin_behavior = .Pipe;
    childProcess.stdout_behavior = .Pipe;
    childProcess.stderr_behavior = .Pipe;
    childProcess.cwd = childOptions.cwd;
    childProcess.env_map = if (childOptions.env) |env|
        &env
    else
        null;

    handlePtr.* = ProcessChildHandle{
        .options = childOptions,
        .child = childProcess,
        .poller = null,
    };

    {
        errdefer L.pop(2);
        try childProcess.spawn();
    }

    handlePtr.poller = std.io.poll(allocator, ProcessChildHandle.PollEnum, .{
        .stdout = childProcess.stdout.?,
        .stderr = childProcess.stderr.?,
    });

    handlePtr.child = childProcess;

    if (L.Lgetmetatable(ProcessChildHandle.META) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (ProcessChild Metatable not initialized)", .{});

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

    decodeEnvironment(L, bytes) catch |err| {
        std.debug.print("{}\n", .{err});
    };
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

fn lib__newindex(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Table);
    const index = L.Lcheckstring(2);
    const process_lib = VM.lua.upvalueindex(1);

    if (std.mem.eql(u8, index, "cwd")) {
        const allocator = luau.getallocator(L);

        const value = try L.Zcheckvalue([:0]const u8, 3, null);
        const dir = try std.fs.cwd().openDir(value, .{});
        const path = try dir.realpathAlloc(allocator, "./");
        defer allocator.free(path);

        try dir.setAsCwd();

        L.pushlstring(path);
        L.setfield(process_lib, "cwd");
    } else return L.Zerrorf("Cannot change field ({s})", .{index});

    return 0;
}

pub fn loadLib(L: *VM.lua.State, args: []const []const u8) !void {
    const allocator = luau.getallocator(L);

    {
        _ = L.Lnewmetatable(ProcessChildHandle.META);

        L.Zsetfieldfn(-1, luau.Metamethods.index, ProcessChildHandle.__index); // metatable.__index
        L.Zsetfieldfn(-1, luau.Metamethods.namecall, ProcessChildHandle.__namecall); // metatable.__namecall

        L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }

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

    {
        const path = try std.fs.cwd().realpathAlloc(allocator, "./");
        defer allocator.free(path);
        L.Zsetfield(-1, "cwd", path);
    }

    L.Zsetfieldfn(-1, "exit", process_exit);
    L.Zsetfieldfn(-1, "run", process_run);
    L.Zsetfieldfn(-1, "create", process_create);
    L.Zsetfieldfn(-1, "onSignal", process_onsignal);

    L.createtable(0, 0);
    {
        L.createtable(0, 3);

        L.pushvalue(-3);
        L.setfield(-2, luau.Metamethods.index); // metatable.__index

        L.pushvalue(-3);
        L.pushcclosure(VM.zapi.toCFn(lib__newindex), luau.Metamethods.newindex, 1);
        L.setfield(-2, luau.Metamethods.newindex); // metatable.__newindex

        L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");

        _ = L.setmetatable(-2);
    }

    L.remove(-2);

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test "Process" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"process.test", &.{ "Test", "someValue" }, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
