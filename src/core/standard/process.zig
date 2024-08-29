const std = @import("std");
const builtin = @import("builtin");
const luau = @import("luau");

const Scheduler = @import("../runtime/scheduler.zig");
const Parser = @import("../utils/parser.zig");

const luaHelper = @import("../utils/luahelper.zig");

const Luau = luau.Luau;

const process = std.process;

const native_os = builtin.os.tag;

const MAX_LUAU_SIZE = 1073741824; // 1 GB

const ProcessArgsError = error{
    InvalidArgType,
    NotArray,
};

const ProcessEnvError = error{
    InvalidKeyType,
    InvalidValueType,
};

fn outputError(L: *Luau, status: [:0]const u8, args: anytype) noreturn {
    L.raiseErrorStr(status, args);
}

fn internal_process_getargs(L: *Luau, array: *std.ArrayList([]const u8), idx: i32) !void {
    L.checkType(idx, luau.LuaType.table);
    L.pushValue(idx);
    L.pushNil();

    var i: i32 = 1;
    while (L.next(-2)) {
        const keyType = L.typeOf(-2);
        const valueType = L.typeOf(-1);
        if (keyType != luau.LuaType.number) return ProcessArgsError.NotArray;
        const num = L.toInteger(-2) catch return ProcessArgsError.NotArray;
        if (num != i) return ProcessArgsError.NotArray;
        if (valueType != luau.LuaType.string) return ProcessArgsError.InvalidArgType;
        const value = L.toString(-1) catch return ProcessArgsError.InvalidArgType;

        try array.append(value);
        L.pop(1);
        i += 1;
    }
    L.pop(1);
}

fn internal_process_envmap(L: *Luau, envMap: *std.process.EnvMap, idx: i32) !void {
    L.checkType(idx, luau.LuaType.table);
    L.pushValue(idx);
    L.pushNil();

    while (L.next(-2)) {
        const keyType = L.typeOf(-2);
        const valueType = L.typeOf(-1);
        if (keyType != luau.LuaType.string) return ProcessEnvError.InvalidKeyType;
        if (valueType != luau.LuaType.string) return ProcessEnvError.InvalidValueType;
        const key = L.toString(-2) catch return ProcessEnvError.InvalidKeyType;
        const value = L.toString(-1) catch return ProcessEnvError.InvalidValueType;
        try envMap.put(key, value);
        L.pop(1);
    }
    L.pop(1);
}

fn internal_process_term(L: *Luau, term: process.Child.Term) void {
    switch (term) {
        .Exited => |code| {
            L.setFieldString(-1, "status", "Exited");
            L.setFieldInteger(-1, "code", @intCast(code));
            L.setFieldBoolean(-1, "ok", code == 0);
        },
        .Stopped => |code| {
            L.setFieldString(-1, "status", "Stopped");
            L.setFieldInteger(-1, "code", @intCast(code));
            L.setFieldBoolean(-1, "ok", false);
        },
        .Signal => |code| {
            L.setFieldString(-1, "status", "Signal");
            L.setFieldInteger(-1, "code", @intCast(code));
            L.setFieldBoolean(-1, "ok", false);
        },
        .Unknown => |code| {
            L.setFieldString(-1, "status", "Unknown");
            L.setFieldInteger(-1, "code", @intCast(code));
            L.setFieldBoolean(-1, "ok", false);
        },
    }
}

const ProcessChildHandle = struct {
    options: ProcessChildOptions,
    child: process.Child,
};

const ProcessChildOptions = struct {
    cmd: []const u8,
    cwd: ?[]const u8 = null,
    env: ?process.EnvMap = null,
    shell: ?[]const u8 = null,
    shell_inline: ?[]const u8 = "-c",
    argArray: std.ArrayList([]const u8),
    tagged: std.ArrayList([]const u8),

    pub fn init(L: *Luau) !ProcessChildOptions {
        const cmd = L.checkString(1);
        const useArgs = L.typeOf(2) == .table;
        const options = L.typeOf(3) != .none;

        const allocator = L.allocator();

        var childOptions = ProcessChildOptions{
            .cmd = cmd,
            .argArray = std.ArrayList([]const u8).init(allocator),
            .tagged = std.ArrayList([]const u8).init(allocator),
        };
        errdefer childOptions.argArray.deinit();

        if (options) {
            L.checkType(3, .table);

            const cwdType = L.getField(3, "cwd");
            if (!luau.isNoneOrNil(cwdType)) {
                if (cwdType == .string) {
                    childOptions.cwd = L.toString(-1) catch null;
                } else outputError(L, "invalid cwd (string expected, got %s)", .{L.typeName(cwdType).ptr});
            }
            L.pop(1);

            const envType = L.getField(3, "env");
            if (!luau.isNoneOrNil(envType)) {
                if (envType == .table) {
                    childOptions.env = std.process.EnvMap.init(allocator);
                    internal_process_envmap(L, &childOptions.env.?, -1) catch |err| switch (err) {
                        ProcessEnvError.InvalidKeyType => outputError(L, "Invalid environment key", .{}),
                        ProcessEnvError.InvalidValueType => outputError(L, "Invalid environment value", .{}),
                        else => outputError(L, "Unknown Error", .{}),
                    };
                } else outputError(L, "Invalid environment (table expected, got %s)", .{L.typeName(envType).ptr});
            }
            L.pop(1);

            const shellType = L.getField(3, "shell");
            if (!luau.isNoneOrNil(shellType)) {
                if (shellType == .string) {
                    const shellOption = L.toString(-1) catch unreachable;
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
                } else if (shellType == .boolean) {
                    if (L.toBoolean(-1)) {
                        switch (native_os) {
                            .windows => childOptions.shell = "powershell",
                            .macos, .linux => childOptions.shell = "/bin/sh",
                            else => childOptions.shell = "/bin/sh",
                        }
                    }
                } else outputError(L, "Invalid shell (string or boolean expected, got %s)", .{L.typeName(shellType).ptr});
            }
            L.pop(1);
        }

        if (useArgs) try internal_process_getargs(L, &childOptions.argArray, 2);

        try childOptions.argArray.insert(0, childOptions.cmd);
        if (childOptions.shell) |shell| {
            const joined = try std.mem.join(allocator, " ", childOptions.argArray.items);
            try childOptions.tagged.append(joined);
            childOptions.argArray.clearAndFree();
            try childOptions.argArray.append(shell);
            if (childOptions.shell_inline) |inlineCmd| try childOptions.argArray.append(inlineCmd);
            try childOptions.argArray.append(joined);
        }

        return childOptions;
    }

    pub fn __dtor(self: *ProcessChildHandle) void {
        var options = self.options;
        options.deinit();
    }

    pub fn __namecall(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const namecall = L.nameCallAtom() catch return 0;
        var handlePtr = L.toUserdata(ProcessChildHandle, 1) catch return 0;
        var childProcess = &handlePtr.child;

        if (std.mem.eql(u8, namecall, "kill")) {
            const term = childProcess.kill() catch |err| {
                std.debug.print("Error: {}\n", .{err});
                outputError(L, "Error killing process", .{});
                unreachable;
            };
            L.newTable();
            internal_process_term(L, term);
            return 1;
        } else if (std.mem.eql(u8, namecall, "wait")) {
            const term = childProcess.wait() catch |err| {
                std.debug.print("Error: {}\n", .{err});
                outputError(L, "Error waiting for process", .{});
                unreachable;
            };
            L.newTable();
            internal_process_term(L, term);
            return 1;
        } else if (std.mem.eql(u8, namecall, "readOut")) {
            if (childProcess.stdout == null) return outputError(L, "InternalError (No stdout stream found, did you spawn?)", .{});
            if (childProcess.stdout_behavior != .Pipe) return outputError(L, "InternalError (stdout stream is not a pipe)", .{});
            const allocator = L.allocator();
            const maxBytes = L.optUnsigned(2) orelse MAX_LUAU_SIZE;

            var buffer = allocator.alloc(u8, maxBytes) catch outputError(L, "OutOfMemory", .{});
            defer allocator.free(buffer);

            const read_bytes = childProcess.stdout.?.read(buffer) catch |err| {
                std.debug.print("Error: {}\n", .{err});
                allocator.free(buffer);
                outputError(L, "Error reading process output", .{});
            };
            L.pushLString(buffer[0..read_bytes]);
            return 1;
        } else if (std.mem.eql(u8, namecall, "readErr")) {
            if (childProcess.stderr == null) return outputError(L, "InternalError (No stdout stream found, did you spawn?)", .{});
            if (childProcess.stderr_behavior != .Pipe) return outputError(L, "InternalError (stderr stream is not a pipe)", .{});
            const allocator = L.allocator();
            const maxBytes = L.optUnsigned(2) orelse MAX_LUAU_SIZE;

            var buffer = allocator.alloc(u8, maxBytes) catch outputError(L, "OutOfMemory", .{});
            defer allocator.free(buffer);

            const read_bytes = childProcess.stderr.?.read(buffer) catch |err| {
                std.debug.print("Error: {}\n", .{err});
                allocator.free(buffer);
                outputError(L, "Error reading process output", .{});
            };

            L.pushLString(buffer[0..read_bytes]);
            return 1;
        } else if (std.mem.eql(u8, namecall, "writeIn")) {
            if (childProcess.stdin == null) return outputError(L, "InternalError (No stdout stream found, did you spawn?)", .{});
            if (childProcess.stdin_behavior != .Pipe) return outputError(L, "InternalError (stderr stream is not a pipe)", .{});
            const buffer = L.checkString(2);

            childProcess.stdin.?.writeAll(buffer) catch |err| {
                std.debug.print("Error: {}\n", .{err});
                outputError(L, "Error writing to process input", .{});
            };
            return 1;
        }
        outputError(L, "Unknown method: %s\n", .{namecall.ptr});
        return 0;
    }

    fn deinit(self: *ProcessChildOptions) void {
        if (self.env) |env| @constCast(&env).deinit();
        for (self.tagged.items) |mem| self.tagged.allocator.free(mem);
        self.argArray.deinit();
        self.tagged.deinit();
    }
};

fn process_run(L: *Luau) !i32 {
    const allocator = L.allocator();

    var childOptions = try ProcessChildOptions.init(L);
    defer childOptions.deinit();

    const proc = try process.Child.run(.{
        .allocator = allocator,
        .argv = childOptions.argArray.items,
        .env_map = if (childOptions.env) |env| &env else null,
        .cwd = childOptions.cwd,
    });
    defer allocator.free(proc.stdout);
    defer allocator.free(proc.stderr);

    L.pushBoolean(true);
    L.newTable();

    L.setFieldLString(-1, "stdout", proc.stdout);
    L.setFieldLString(-1, "stderr", proc.stderr);

    internal_process_term(L, proc.term);

    return 2;
}

fn process_create(L: *Luau) !i32 {
    const allocator = L.allocator();

    const childOptions = try ProcessChildOptions.init(L);

    L.pushBoolean(true);
    const handlePtr = L.newUserdataDtor(ProcessChildHandle, ProcessChildOptions.__dtor);
    var childProcess = process.Child.init(childOptions.argArray.items, allocator);

    childProcess.id = undefined;
    childProcess.thread_handle = undefined;
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
    childProcess.env_map = if (childOptions.env) |env| &env else null;

    handlePtr.* = ProcessChildHandle{
        .options = childOptions,
        .child = childProcess,
    };

    {
        errdefer L.pop(2);
        try childProcess.spawn();
    }

    handlePtr.child = childProcess;

    if (L.getMetatableRegistry("process_child_instance") == .table) {
        L.setMetatable(-2);
    } else std.debug.panic("InternalError (ProcessChild Metatable not initialized)", .{});

    return 2;
}

fn process_exit(L: *Luau) i32 {
    const code = L.checkUnsigned(1);
    Scheduler.KillSchedulers();
    std.process.exit(@intCast(code));
    return 0;
}

const DotEnvError = error{
    InvalidString,
    InvalidCharacter,
};

fn decodeString(L: *Luau, slice: []const u8) !usize {
    var buf = std.ArrayList(u8).init(L.allocator());
    defer buf.deinit();

    if (slice.len < 2) return DotEnvError.InvalidString;
    if (slice[0] == slice[1]) {
        L.pushString("");
        return 2;
    }

    const stringQuote: u8 = slice[0];
    var pos: usize = 1;
    var eof: bool = false;
    while (pos <= slice.len) {
        switch (slice[pos]) {
            '\\' => if (stringQuote != '\'') {
                pos += 1;
                if (pos >= slice.len) return DotEnvError.InvalidString;
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
        L.pushLString(buf.items);
        return pos;
    } else L.pushString("");
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

fn decodeEnvironment(L: *Luau, string: []const u8) !void {
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
            if (pos >= string.len) break;
            try validateWord(variableName);
            pos += Parser.nextNonCharacter(string[pos..], &WHITESPACE);
            L.pushLString(variableName);
            errdefer L.pop(1);
            if (string[pos] == '"' or string[pos] == '\'' or string[pos] == '`') {
                const stringEof = try decodeString(L, string[pos..]);
                const remaining_slice = string[pos + stringEof ..];
                const eof = Parser.nextCharacter(remaining_slice, &DECODE_BREAK);
                if (Parser.trimSpace(remaining_slice[0..eof]).len == 0) {
                    L.setTable(-3);
                    pos += stringEof;
                    pos += eof;
                    continue;
                }
                L.pop(1);
            }
            const eof = Parser.nextCharacter(string[pos..], &DECODE_BREAK);
            L.pushLString(Parser.trimSpace(string[pos .. pos + eof]));
            L.setTable(-3);
            pos += eof;
        },
        else => pos += 1,
    };
}

fn tryLoadEnvironment(L: *Luau, allocator: std.mem.Allocator, file: []const u8) void {
    const bytes: []const u8 = std.fs.cwd().readFileAlloc(allocator, file, std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => L.raiseErrorStr("InternalError (%s)", .{@errorName(err).ptr}),
    };
    defer allocator.free(bytes);

    decodeEnvironment(L, bytes) catch |err| {
        std.debug.print("{}\n", .{err});
    };
}

fn process_loadEnv(L: *Luau) i32 {
    const allocator = L.allocator();
    L.newTable();

    const env_map = allocator.create(std.process.EnvMap) catch outputError(L, "OutOfMemory", .{});
    env_map.* = std.process.getEnvMap(allocator) catch outputError(L, "OutOfMemory", .{});
    defer {
        env_map.deinit();
        allocator.destroy(env_map);
    }

    var iterator = env_map.iterator();
    while (iterator.next()) |entry| {
        const zkey = allocator.dupeZ(u8, entry.key_ptr.*) catch outputError(L, "OutOfMemory", .{});
        const zvalue = allocator.dupeZ(u8, entry.value_ptr.*) catch outputError(L, "OutOfMemory", .{});
        defer {
            allocator.free(zkey);
            allocator.free(zvalue);
        }
        L.setFieldString(-1, zkey, zvalue);
    }

    tryLoadEnvironment(L, allocator, ".env");
    if (env_map.get("LUAU_ENV")) |value| {
        if (std.mem.eql(u8, value, "PRODUCTION")) {
            tryLoadEnvironment(L, allocator, ".env.production");
        } else if (std.mem.eql(u8, value, "DEVELOPMENT")) {
            tryLoadEnvironment(L, allocator, ".env.development");
        } else if (std.mem.eql(u8, value, "TEST")) {
            tryLoadEnvironment(L, allocator, ".env.test");
        }
    }
    tryLoadEnvironment(L, allocator, ".env.local");

    return 1;
}

pub fn loadLib(L: *Luau, args: []const []const u8) !void {
    const allocator = L.allocator();

    {
        try L.newMetatable("process_child_instance");
        L.pushValue(-1);
        L.setField(-2, luau.Metamethods.index); // metatable.__index = metatable

        L.setFieldFn(-1, luau.Metamethods.namecall, ProcessChildOptions.__namecall); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }

    L.newTable();

    L.setFieldString(-1, "arch", @tagName(builtin.cpu.arch));
    L.setFieldString(-1, "os", @tagName(native_os));

    {
        L.newTable();
        for (args, 1..) |arg, i| {
            const zarg = try allocator.dupeZ(u8, arg);
            defer allocator.free(zarg);
            L.pushString(zarg);
            L.rawSetIndex(-2, @intCast(i));
        }
        L.setReadOnly(-1, true);
        L.setField(-2, "args");
    }

    _ = process_loadEnv(L);
    L.setField(-2, "env");
    L.setFieldFn(-1, "loadEnv", process_loadEnv);

    {
        const path = try std.fs.cwd().realpathAlloc(allocator, "./");
        defer allocator.free(path);
        L.setFieldLString(-1, "cwd", path);
    }

    L.setFieldFn(-1, "exit", process_exit);
    L.setFieldFn(-1, "run", luaHelper.toSafeZigFunction(process_run));
    L.setFieldFn(-1, "create", luaHelper.toSafeZigFunction(process_create));

    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (L.getField(-1, "@zcore/process") != .table) {
        L.pop(1);
        L.pushValue(-2);
        L.setField(-2, "@zcore/process");
    } else L.pop(1);
    L.pop(2);
}

test "Process" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"process.test", &.{ "Test", "someValue" }, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
