const std = @import("std");
const builtin = @import("builtin");

const Config = @import("config.zig");

const fs = std.fs;

const PathType = enum {
    RelativeToCurrent,
    RelativeToParent,
    Aliased,
    Unsupported,

    pub fn get(path: []const u8) PathType {
        if (std.mem.startsWith(u8, path, "./")) {
            return .RelativeToCurrent;
        } else if (std.mem.startsWith(u8, path, "../")) {
            return .RelativeToParent;
        } else if (std.mem.startsWith(u8, path, "@")) {
            return .Aliased;
        } else {
            return .Unsupported;
        }
    }
};

pub const INIT_SUFFIXES: []const [:0]const u8 = &.{
    "/init.luau",
    "/init.lua",
};
pub const SUFFIXES: []const [:0]const u8 = &.{
    ".luau",
    ".lua",
};

pub fn extractAlias(path: []const u8) ![]const u8 {
    std.debug.assert(path.len >= 1);
    const aliasStart = 1; // Ignore the '@' alias prefix
    const aliasEnd = std.mem.indexOfAny(u8, path[aliasStart..], "/\\") orelse (path.len - aliasStart);
    return path[aliasStart .. aliasStart + aliasEnd];
}

pub fn isInitSuffix(path: []const u8) bool {
    inline for (INIT_SUFFIXES) |suffix| {
        if (std.mem.eql(u8, path, suffix[1..]))
            return true;
    }
    return false;
}

pub fn removeSuffix(path: []const u8) []const u8 {
    for (INIT_SUFFIXES ++ SUFFIXES) |suffix| {
        if (std.mem.endsWith(u8, path, suffix)) {
            return path[0 .. path.len - suffix.len];
        }
    }
    return path;
}

pub fn getLuaurcPath(buf: []u8, path: []const u8) []const u8 {
    std.debug.assert(buf.len >= path.len + 8);
    var written: usize = 0;
    if (path.len > 0) {
        @memcpy(buf[0..path.len], path);
        written += path.len;
        switch (path[path.len - 1]) {
            '\\', '/' => written -= 1,
            else => {},
        }
    }
    const END = fs.path.sep_str ++ ".luaurc";
    @memcpy(buf[written .. written + END.len], END);
    const out = buf[0 .. written + END.len];
    if (comptime builtin.os.tag == .windows)
        _ = std.mem.replace(u8, out, "/", fs.path.sep_str, out);
    return out;
}

/// Resolves the `script` path from provided `from` path and `path`.
///
/// Features:
/// - result path would be OS-specific, i.e. it would use `/` on Unix-like systems and `\` on Windows.
///
/// This functions does not:
/// - resolve the file itself, but rather the path to the file.
/// - search for the file, such as `.luau`, `.lua`, `/init.luau` or `/init.lua`.
/// - check if the path has `.luau` or `.lua` suffixes, the caller is responsible redundant file extension checks accordance to the RFC.
///
/// The function would assume you are operating with `cwd` (current working directory) as the base path.
///
/// Examples:
/// - `src/main.luau` navigating to `./utils.luau` will result in `src/utils.luau`.
/// - `src/main.luau` navigating to `../utils.luau` will result in `utils.luau`.
/// - `src/main.luau` navigating to `@alias/utils.luau` will resolve the `@alias` alias from the `src/.luaurc` or `.luaurc` configuration file.
///
/// Designed with and for the luau specification:
/// - [Amended Require Syntax and Resolution Semantics](https://rfcs.luau.org/amended-require-resolution.html)
/// - [Abstract module paths and `init.luau`](https://rfcs.luau.org/abstract-module-paths-and-init-dot-luau.html)
/// - [Configure analysis via .luaurc](https://rfcs.luau.org/config-luaurc.html)
///
pub fn navigate(allocator: std.mem.Allocator, context: anytype, from: []const u8, path: []const u8, out_err: ?*?[]const u8) ![]u8 {
    if (from.len > fs.max_path_bytes or path.len > fs.max_path_bytes)
        return error.PathTooLong;

    const owned_path = try std.mem.replaceOwned(u8, allocator, path, "\\", "/");
    defer allocator.free(owned_path);

    const path_type = PathType.get(owned_path);
    if (path_type == .Unsupported)
        return error.PathUnsupported;

    var buf: [fs.max_path_bytes]u8 = undefined;
    const owned_from = try std.mem.replaceOwned(u8, allocator, from, "\\", "/");
    defer allocator.free(owned_from);

    switch (path_type) {
        .Aliased => {
            const alias = try std.ascii.allocLowerString(allocator, try extractAlias(owned_path));
            defer allocator.free(alias);

            const adjusted = removeSuffix(owned_from);
            var parent: ?[]const u8 = fs.path.dirname(adjusted) orelse
                if (isInitSuffix(owned_from)) ".." else null;

            const absolute = fs.path.isAbsolute(owned_from);
            if (absolute and parent == null)
                return error.PathNotFound;

            const start_parent = if (!absolute) try fs.path.join(allocator, &.{ ".", parent orelse "" }) else parent.?;
            defer if (!absolute) allocator.free(start_parent);

            parent = start_parent;

            var foundAlias: ?[]const u8 = null;
            var config: ?Config = null;
            defer if (config) |*c| c.deinit(allocator);
            while (parent) |parent_path| : (parent = fs.path.dirname(parent_path)) {
                blk: {
                    if (parent_path.len + 8 > buf.len)
                        return error.PathTooLong;
                    const config_path = getLuaurcPath(&buf, parent_path);
                    const data = context.getConfigAlloc(allocator, config_path) catch |err| switch (@as(anyerror, @errorCast(err))) {
                        error.NotPresent => break :blk,
                        else => return err,
                    };
                    defer allocator.free(data);

                    if (config) |*c|
                        c.deinit(allocator);
                    config = try Config.parse(allocator, data, out_err);
                    if (config.?.aliases.get(alias)) |value| {
                        foundAlias = value;
                        break;
                    }
                }
            }
            if (foundAlias == null) {
                if (!std.mem.eql(u8, alias, "self")) {
                    if (out_err) |ptr_out|
                        ptr_out.* = try std.fmt.allocPrint(allocator, "@{s} is not a valid alias", .{alias});
                    return error.AliasNotFound;
                }

                parent = fs.path.dirname(owned_from) orelse ".";

                const ext_path = try fs.path.join(allocator, &.{ ".", owned_path[alias.len + 1 ..] });
                defer allocator.free(ext_path);

                return try context.resolvePathAlloc(allocator, &.{ parent.?, ext_path });
            }
            const ext_path = try fs.path.join(allocator, &.{ foundAlias.?, owned_path[alias.len + 1 ..] });
            defer allocator.free(ext_path);

            return try context.resolvePathAlloc(allocator, &.{ if (parent) |dir| dir else owned_from, ext_path });
        },
        .RelativeToCurrent, .RelativeToParent => {
            const adjusted = removeSuffix(owned_from);
            const parent: ?[]const u8 = fs.path.dirname(adjusted) orelse
                if (isInitSuffix(owned_from)) ".." else null;

            const absolute = fs.path.isAbsolute(owned_from);
            if (absolute and parent == null)
                return error.PathNotFound;

            const start_parent = if (!absolute) try fs.path.join(allocator, &.{ ".", parent orelse "" }) else parent.?;
            defer if (!absolute) allocator.free(start_parent);
            return try context.resolvePathAlloc(allocator, &.{ start_parent, owned_path });
        },
        .Unsupported => unreachable,
    }
}

fn OSPath(comptime path: []const u8) []const u8 {
    var iter = std.mem.splitScalar(u8, path, '/');
    var static: []const u8 = iter.first();
    while (iter.next()) |component| {
        static = static ++ fs.path.sep_str ++ component;
    }
    return static;
}

fn navigateTest(allocator: std.mem.Allocator, comptime context: type, comptime expected: []const u8, from: []const u8, path: []const u8) !void {
    const result = try navigate(allocator, context, from, path, null);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(comptime OSPath(expected), result);
}

fn navigateTestError(allocator: std.mem.Allocator, comptime context: type, from: []const u8, path: []const u8, err: ?[]const u8) !void {
    var err_out: ?[]const u8 = null;
    defer if (err_out) |e| allocator.free(e);
    if (navigate(allocator, context, from, path, &err_out)) |_|
        unreachable
    else |caught| {
        if (err) |expected_err|
            try std.testing.expectEqualStrings(expected_err, err_out orelse @panic("Expected error not found"));
        return caught;
    }
}

test "empty context" {
    const allocator = std.testing.allocator;
    const EmptyContext = struct {
        pub fn getConfigAlloc(_: std.mem.Allocator, _: []const u8) ![]const u8 {
            unreachable;
        }
        pub const resolvePathAlloc = fs.path.resolve;
    };

    try navigateTest(allocator, EmptyContext, "test", "./script/init.luau", "./test");
    try navigateTest(allocator, EmptyContext, "test", "script/init.luau", "./test");
    try navigateTest(allocator, EmptyContext, "script/test", "script/main.luau", "./test");
    try navigateTest(allocator, EmptyContext, "script/test", "./script/main.luau", "./test");
    try navigateTest(allocator, EmptyContext, "../test", "init.luau", "./test");

    try navigateTest(allocator, EmptyContext, "/test", "/script/init.luau", "./test");
    try navigateTest(allocator, EmptyContext, "/script/test", "/script/main.luau", "./test");

    try std.testing.expectError(error.PathNotFound, navigateTestError(allocator, EmptyContext, "/init.luau", "./test", null));
    try std.testing.expectError(error.PathNotFound, navigateTestError(allocator, EmptyContext, "/", "./main", null));
    try std.testing.expectError(error.PathNotFound, navigateTestError(allocator, EmptyContext, "/", "@alias/", null));

    if (comptime builtin.os.tag == .windows) {
        try navigateTest(allocator, EmptyContext, "C:/test", "C:/script/init.luau", "./test");
        try navigateTest(allocator, EmptyContext, "C:/script/test", "C:/script/main.luau", "./test");

        try std.testing.expectError(error.PathNotFound, navigateTestError(allocator, EmptyContext, "C:/init.luau", "./test", null));
        try std.testing.expectError(error.PathNotFound, navigateTestError(allocator, EmptyContext, "C:/", "./main", null));
        try std.testing.expectError(error.PathNotFound, navigateTestError(allocator, EmptyContext, "C:/", "@alias/", null));
    }
}

test "home context" {
    const allocator = std.testing.allocator;
    const HomeContext = struct {
        pub fn getConfigAlloc(a: std.mem.Allocator, path: []const u8) ![]const u8 {
            if (!std.mem.eql(u8, path, comptime OSPath("./.luaurc")) and !std.mem.eql(u8, path, comptime OSPath("/.luaurc")))
                std.testing.expectEqualStrings(comptime OSPath("/.luaurc"), path) catch @panic("Path mismatch");

            return a.dupe(u8,
                \\{
                \\  "aliases": {
                \\    "packages": "./packages",
                \\  }
                \\}
            ) catch |err| return err;
        }
        pub const resolvePathAlloc = fs.path.resolve;
    };

    try navigateTest(allocator, HomeContext, "packages/json", "script/init.luau", "@packages/json");
    try navigateTest(allocator, HomeContext, "packages/json", "main.luau", "@packages/json");
    try navigateTest(allocator, HomeContext, "packages", "main.luau", "@packages");
    try navigateTest(allocator, HomeContext, "packages", "main.luau", "@packages/");

    try navigateTest(allocator, HomeContext, "/packages/json", "/script/init.luau", "@packages/json");
    try navigateTest(allocator, HomeContext, "/packages/json", "/main.luau", "@packages/json");
    try navigateTest(allocator, HomeContext, "/packages", "/main.luau", "@packages");
    try navigateTest(allocator, HomeContext, "/packages", "/main.luau", "@packages/");
}

test "broken config" {
    const allocator = std.testing.allocator;
    const BrokenConfig = struct {
        pub fn getConfigAlloc(a: std.mem.Allocator, _: []const u8) ![]const u8 {
            return a.dupe(u8,
                \\{
            ) catch |err| return err;
        }
        pub const resolvePathAlloc = fs.path.resolve;
    };
    try navigateTest(allocator, BrokenConfig, "/main", "/src", "./main");
    try navigateTest(allocator, BrokenConfig, "main", "src", "./main");

    try std.testing.expectError(error.SyntaxError, navigateTestError(allocator, BrokenConfig, "/src", "@alias/", ".luaurc: Expected field key at line 1"));
    try std.testing.expectError(error.SyntaxError, navigateTestError(allocator, BrokenConfig, "src", "@alias/", ".luaurc: Expected field key at line 1"));
}

test "config tree" {
    const allocator = std.testing.allocator;
    const ConfigTree = std.StaticStringMap([:0]const u8).initComptime(.{
        .{
            OSPath("./script/.luaurc"),
            \\{
            \\  "aliases": {
            \\    "packages": "./packages",
            \\  }
            \\}
        },
        .{
            OSPath("./foo/bar/.luaurc"),
            \\{
            \\  "aliases": {
            \\    "sample": "/sample",
            \\  }
            \\}
        },
        .{
            OSPath("./foo/.luaurc"),
            \\{
            \\  "aliases": {
            \\    "sample": "/unknown",
            \\  }
            \\}
        },
    });

    const ConfigContext = struct {
        pub fn getConfigAlloc(a: std.mem.Allocator, path: []const u8) ![]const u8 {
            return try a.dupe(u8, ConfigTree.get(path) orelse return error.NotPresent);
        }
        pub const resolvePathAlloc = fs.path.resolve;
    };

    try navigateTest(allocator, ConfigContext, "script/packages/main", "script/main.luau", "@packages/main");
    try navigateTest(allocator, ConfigContext, "script/packages/main", "script/very/long/child/tree/main.luau", "@packages/main");
    try navigateTest(allocator, ConfigContext, "/unknown", "foo/main.luau", "@sample");
    try navigateTest(allocator, ConfigContext, "/sample", "foo/bar/main.luau", "@sample");

    try std.testing.expectError(error.AliasNotFound, navigateTestError(allocator, ConfigContext, "script/main.luau", "@alias/", "@alias is not a valid alias"));
    try std.testing.expectError(error.AliasNotFound, navigateTestError(allocator, ConfigContext, "foo/bar/main.luau", "@packages/", "@packages is not a valid alias"));
    try std.testing.expectError(error.AliasNotFound, navigateTestError(allocator, ConfigContext, "foo/main.luau", "@packages/", "@packages is not a valid alias"));
}
